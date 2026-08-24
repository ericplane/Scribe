--!nonstrict
-- The six-method `data_store` surface the real ProfileStore is written against.
--
-- This is the most fidelity-critical file in the simulation: everything above it
-- is the unmodified vendored library, so any divergence here is a divergence the
-- rest of the run silently inherits.
--
-- PER-KEY SERIALIZATION IS DELIBERATELY ABSENT, and that is not an oversight.
-- Real UpdateAsync is OPTIMISTIC, not locking: concurrent updates to one key all
-- proceed, and losers re-run their transform against fresh data. ProfileStore
-- already serializes per key IN-PROCESS through its own update queue, so each
-- server presents at most one in-flight UpdateAsync per key by construction. A
-- lock here would over-serialize -- hiding exactly the cross-server conflicts the
-- simulation exists to find -- while a disk-global lock would invent orderings
-- production cannot produce.

local Errors = require(script.Parent.Errors)
local Size = require(script.Parent.Size)

local Store = {}
Store.__index = Store

local KEY_LIMIT = 50

--- A fresh deep copy. Recursive, because a shallow copy would leave nested tables
--- aliased and every invariant below depends on nothing being shared.
local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in value do
		out[key] = deepCopy(item)
	end
	return out
end

--- The DataStoreKeyInfo shape ProfileStore reads.
local function keyInfoFor(record): any
	return {
		Version = record.VersionId,
		CreatedTime = record.CreatedTime * 1000,
		UpdatedTime = record.UpdatedTime * 1000,
		GetUserIds = function()
			return deepCopy(record.UserIds)
		end,
		GetMetadata = function()
			return deepCopy(record.Metadata)
		end,
	}
end

--- Apply an injected fault that fails the request outright.
---
--- "Lost" parks the caller forever on purpose: it models a request that never
--- returns, which is what the scheduler's deadlock detector exists to catch. A
--- fault that merely raised would be caught by a pcall and prove nothing.
local function applyFailingFault(disk, kind: string)
	if kind == "Lost" then
		disk.Faults.Stats.Lost += 1
		coroutine.yield() -- never resumed
		return
	end
	disk:Wait(disk.Latency:Draw("Read")) -- a failure still costs a round trip
	disk.Faults:Raise(kind)
end

--- Wait out a per-key throughput breach rather than failing.
---
--- The real backend queues the request and passes over it until the window has
--- room, so the caller experiences LATENCY, not an error. Modelled here as an
--- in-place wait, which has the same effect without a shared queue: each request
--- has its own thread, so one hot key delays only its own writers and cannot
--- block unrelated traffic behind it.
local function awaitKeyWindow(disk, store: string, key: string, direction: string, bytes: number)
	local waited = 0
	while disk:WouldThrottleKey(store, key, direction, bytes) do
		disk.Throughput.Stats.Throttles += 1
		disk:Wait(1)
		waited += 1
		if waited > 120 then
			-- Two virtual minutes is longer than the window; if it still will not
			-- fit, this single value exceeds the per-minute allowance outright and
			-- waiting will never help.
			break
		end
	end
end
function Store.new(disk, name: string, scope: string?)
	return setmetatable({
		_disk = disk,
		_name = name,
		_scope = scope,
	}, Store)
end

--- Reject a bad key locally, synchronously, before any latency or budget charge.
--- Roblox validates client-side, so a malformed key costs nothing and fails fast.
local function validateKey(key: any)
	if type(key) ~= "string" or key == "" then
		Errors.Raise("KeyEmpty")
	end
	if #key > KEY_LIMIT then
		Errors.Raise("KeyTooLong")
	end
end

--------------------------------------------------------------------------------
-- UpdateAsync
--------------------------------------------------------------------------------

--- Read-modify-write under optimistic concurrency.
---
--- THE ORDER OF THE STEPS BELOW IS THE SPECIFICATION. Each numbered comment marks
--- a point another server can (or deliberately cannot) interleave.
function Store.UpdateAsync(self, key: string, transform: (any, any) -> ...any): (any, any)
	-- (1) Validate locally, free.
	validateKey(key)
	local disk = self._disk

	-- (2) Charge budget. UpdateAsync both reads and writes, so it pays for both.
	-- May yield waiting for budget; raises only if the queue overflows.
	disk:Admit(self._jobId or self._disk._defaultJob, "StandardRead", "UpdateAsync")
	disk:Admit(self._jobId or self._disk._defaultJob, "StandardWrite", "UpdateAsync")

	-- Decided ONCE per request, not per attempt: a retry driven by contention is
	-- the same request, and re-rolling would make an unlucky key fail forever.
	local fault = disk:NextFault("UpdateAsync", self._name, key)
	if fault ~= nil and fault ~= "Indeterminate" then
		disk:Release()
		applyFailingFault(disk, fault)
	end

	local attempts = 0

	while true do
		-- (3) Read latency. THE CONFLICT WINDOW -- the reason the model exists.
		disk:Wait(disk.Latency:Draw("Read"))

		-- (4) Snapshot the CAS token, and hand the transform a FRESH copy. Fresh on
		-- every attempt, including re-invocations: ProfileStore mutates what it is
		-- given and returns the same table, so a retry that saw the previous
		-- attempt's partial mutation would diverge silently. (DC-IN)
		local record = disk.Keyspace:Read(self._name, key)
		local seen = disk.Keyspace:Version(self._name, key)
		local input = deepCopy(record and record.Value or nil)
		local info = if record and record.Value ~= nil then keyInfoFor(record) else nil

		-- (5) Invoke the transform and PROVE it did not yield.
		--
		-- A coroutine rather than a flag. A flag only trips when the transform
		-- yields through this file's own wait; a transform yielding on anything
		-- else would slip past unnoticed. Roblox forbids yielding here, and it
		-- matters concretely: ProfileStore's release of its per-key update queue
		-- sits outside the pcall wrapping this call, so a yielding transform would
		-- hold that queue across the yield and manufacture interleavings
		-- production cannot reach.
		local runner = coroutine.create(transform)
		local ok, newValue, userIds, metadata = coroutine.resume(runner, input, info)
		if not ok then
			error(newValue, 0)
		end
		if disk.Config.StrictTransform ~= false and coroutine.status(runner) ~= "dead" then
			Errors.Raise("SimTransformYielded")
		end

		-- (6) A nil return aborts the write. Real ProfileStore never takes this
		-- branch, but the contract has it and a store that ignored it would be
		-- wrong for anyone else.
		if newValue == nil then
			return nil, nil
		end

		-- (7) Write latency. A second window, and the one a competing commit
		-- usually lands in.
		disk:Wait(disk.Latency:Draw("Write"))

		-- (8) Version check. Someone committed while we were away: discard this
		-- attempt and re-run the transform against fresh data, exactly as a real
		-- optimistic update does.
		if disk.Keyspace:Version(self._name, key) ~= seen then
			disk.Stats.Conflicts += 1
			attempts += 1
			if attempts > (disk.Config.MaxTransformAttempts or 100) then
				Errors.Raise("SimTransformLivelock")
			end
			continue
		end

		-- (9) Caps, checked before the write and never after. A rejected write
		-- must leave the key exactly as it was.
		local serialized = Size.Serialized(newValue)
		if serialized > (disk.Config.ValueBytes or Size.VALUE_BYTES) then
			Errors.Raise("ValueTooLarge")
		end
		if userIds ~= nil and #userIds > (disk.Config.UserIdLimit or 200) then
			Errors.Raise("UserIdLimitExceeded")
		end

		-- Both size measures recorded per commit. They disagree on purpose: the
		-- gap is what Scribe's oversize heuristic has to bridge, and a model where
		-- they agreed would never exercise it.
		disk.Stats.SizeDivergence = {
			Serialized = serialized,
			Approx = Size.Approx(newValue),
		}

		-- (9b) Wait out the key's throughput window if this write would breach it.
		-- Before the version check is re-confirmed, because waiting is a yield and
		-- anything can commit during it.
		awaitKeyWindow(disk, self._name, key, "Write", serialized)
		if disk.Keyspace:Version(self._name, key) ~= seen then
			disk.Stats.Conflicts += 1
			attempts += 1
			if attempts > (disk.Config.MaxTransformAttempts or 100) then
				Errors.Raise("SimTransformLivelock")
			end
			continue
		end

		-- (10) Commit. NOTHING between step (8) and here yields, which is what
		-- makes this atomic under a cooperative scheduler with no lock.
		local stored = deepCopy(newValue) -- (DC-OUT)
		local committed = disk.Keyspace:Commit(self._name, key, stored, {
			Now = disk:Now(),
			VersionId = disk:MintVersionId(),
			UserIds = if userIds ~= nil then deepCopy(userIds) else nil,
			Metadata = if metadata ~= nil then deepCopy(metadata) else nil,
		})
		disk.Stats.Writes += 1
		disk:ChargeThroughput(self._name, key, "Write", serialized)

		disk:Release()

		-- The write LANDED and now the call fails. The caller cannot tell whether
		-- it happened, and ProfileStore assumes it did not -- so an ending-session
		-- save retries and applies it twice. No Roblox mock models this outcome,
		-- and it is where the expensive bugs live.
		if fault == "Indeterminate" then
			disk.Faults.Stats.IndeterminateCommits += 1
			disk:Wait(disk.Latency:Draw("Write"))
			disk.Faults:Raise("Indeterminate")
		end

		-- (11) A THIRD distinct copy. ProfileStore publishes this as
		-- Profile.LastSavedData, and Scribe restores Data from it on a blocked
		-- save -- returning the stored table would alias saved state to live state.
		-- (DC-RET)
		return deepCopy(stored), keyInfoFor(committed)
	end
end

--------------------------------------------------------------------------------
-- GetAsync / SetAsync / RemoveAsync
--------------------------------------------------------------------------------

--- Read a key.
---
--- A missing key returns (nil, nil) -- BOTH nil. ProfileStore decides a key has
--- never been written by testing the KEY INFO, not the value, so a helpfully
--- non-nil keyInfo here would silently break new-profile detection and make every
--- first load look like a returning player.
function Store.GetAsync(self, key: string, versionId: string?): (any, any)
	validateKey(key)
	local disk = self._disk
	disk:Admit(self._jobId or disk._defaultJob, "StandardRead", "GetAsync")
	disk:Wait(disk.Latency:Draw("Read"))

	if versionId ~= nil then
		for _, backup in disk.Keyspace:Versions(self._name, key) do
			if backup.VersionId == versionId then
				-- A REAL keyInfo. Returning nil here blanked Scribe's entire version
				-- surface in the simulation: ProfileStore:GetAsync bails on a nil
				-- key_info, so ProfileVersionQuery:NextAsync answered nil for every
				-- entry, Persistence.ListVersions broke on the first one and returned
				-- {}, and RestoreVersion could only ever say "version not found".
				-- Measured: ListVersions returned n=0 after a seeded write.
				--
				-- The caveat in this function's own header is about the LIVE read
				-- below, where a non-nil keyInfo would make a never-written key look
				-- like a returning player. A version read is the opposite case: the
				-- version demonstrably exists, and ProfileStore requires the keyInfo.
				local live = disk.Keyspace:Read(self._name, key)
				disk:Release()
				return deepCopy(backup.Value),
					keyInfoFor({
						VersionId = backup.VersionId,
						CreatedTime = backup.UpdatedTime,
						UpdatedTime = backup.UpdatedTime,
						UserIds = if live then live.UserIds else {},
						Metadata = if live then live.Metadata else {},
					})
			end
		end
		-- ProfileStore string-matches "not valid" here.
		disk:Release()
		Errors.Raise("VersionNotValid")
	end

	local record = disk.Keyspace:Read(self._name, key)
	if record == nil or record.Value == nil then
		-- Released on this path too: it was admitted above, and returning without
		-- releasing leaks a budget slot for every read of an absent key.
		disk:Release()
		return nil, nil
	end
	disk.Stats.Reads += 1
	disk:ChargeThroughput(self._name, key, "Read", Size.Serialized(record.Value))
	disk:Release()
	return deepCopy(record.Value), keyInfoFor(record)
end

--- Unconditional overwrite, no CAS.
---
--- Present for surface completeness. Nothing on the profile path reaches it:
--- Profile:SetAsync routes through UpdateAsync, and the only real callers are the
--- Studio API probe (unreachable, IsStudio is pinned false) and OrderedDataStore.
function Store.SetAsync(self, key: string, value: any, userIds: { number }?): any
	validateKey(key)
	local disk = self._disk
	disk:Admit(self._jobId or disk._defaultJob, "StandardWrite", "SetAsync")
	disk:Wait(disk.Latency:Draw("Write"))

	local serialized = Size.Serialized(value)
	if serialized > (disk.Config.ValueBytes or Size.VALUE_BYTES) then
		Errors.Raise("ValueTooLarge")
	end

	local committed = disk.Keyspace:Commit(self._name, key, deepCopy(value), {
		Now = disk:Now(),
		VersionId = disk:MintVersionId(),
		UserIds = if userIds ~= nil then deepCopy(userIds) else nil,
	})
	disk.Stats.Writes += 1
	disk:ChargeThroughput(self._name, key, "Write", serialized)
	return keyInfoFor(committed)
end

function Store.RemoveAsync(self, key: string): (any, any)
	validateKey(key)
	local disk = self._disk
	disk:Admit(self._jobId or disk._defaultJob, "StandardRemove", "RemoveAsync")
	disk:Wait(disk.Latency:Draw("Write"))

	local record = disk.Keyspace:Read(self._name, key)
	if record == nil or record.Value == nil then
		return nil, nil
	end
	local info = keyInfoFor(record)
	local previous = disk.Keyspace:Remove(self._name, key, {
		Now = disk:Now(),
		VersionId = disk:MintVersionId(),
	})
	disk.Stats.Removes += 1
	return deepCopy(previous), info
end

--------------------------------------------------------------------------------
-- Versions
--------------------------------------------------------------------------------

function Store.ListVersionsAsync(self, key: string, _sortDirection: any?, _minDate: number?, _maxDate: number?): any
	validateKey(key)
	local disk = self._disk
	disk:Admit(self._jobId or disk._defaultJob, "StandardList", "ListVersionsAsync")
	disk:Wait(disk.Latency:Draw("Read"))

	local page = {}
	for _, backup in disk.Keyspace:Versions(self._name, key) do
		table.insert(page, {
			Version = backup.VersionId,
			CreatedTime = backup.UpdatedTime * 1000,
			IsDeleted = false,
		})
	end

	return {
		IsFinished = true,
		GetCurrentPage = function()
			return page
		end,
		-- Only page one is modelled: nothing in ProfileStore or Scribe advances.
		AdvanceToNextPageAsync = function() end,
	}
end

function Store.GetVersionAsync(self, key: string, versionId: string): (any, any)
	return self:GetAsync(key, versionId)
end

return Store
