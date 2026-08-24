--!nonstrict
-- OrderedDataStore: the only DataStore surface Scribe reaches directly.
--
-- Everything else goes through ProfileStore, but Leaderboards calls
-- DataStoreService:GetOrderedDataStore itself -- and captures the service table
-- into a module upvalue at load time, which is why the harness shim has to be
-- mutated in place rather than replaced.
--
-- ORDERED WRITES ARE THE TIGHTEST REAL CONSTRAINT AT HIGH CCU. They accrue at
-- 30 + n*5 per minute against 60 + n*40 for standard writes -- eight times
-- scarcer per player. A leaderboard that updates per score change will saturate
-- this long before anything else in the system notices pressure.
--
-- Deliberately narrower than the standard store, because the real thing is:
--   * values are int64 ONLY -- no tables, no floats, no strings;
--   * there is no versioning and no metadata, so KeyInfo is genuinely nil rather
--     than an empty stand-in;
--   * only page one of a sorted query is modelled, because Leaderboards reads
--     GetCurrentPage once and never advances;
--   * the documented budget for OrderedList reads is zero.

local Errors = require(script.Parent.Errors)

local Ordered = {}
Ordered.__index = Ordered

-- OrderedDataStore stores a signed 64-bit integer. Luau numbers are doubles, so
-- anything past 2^53 is already unrepresentable exactly -- the check that matters
-- in practice is integrality, which is what Scribe's score packing has to respect.
local MAX_INT64 = 9223372036854775807

function Ordered.new(disk, name: string, scope: string?)
	return setmetatable({
		_disk = disk,
		_name = name,
		_scope = scope,
		_entries = {}, -- key -> integer
	}, Ordered)
end

local function validateKey(key: any)
	if type(key) ~= "string" or key == "" then
		Errors.Raise("KeyEmpty")
	end
	if #key > 50 then
		Errors.Raise("KeyTooLong")
	end
end

--- Write a score. Integers only.
---
--- A non-integer is rejected EVERY time, permanently -- which matters because a
--- caller that re-enqueues on failure would retry forever. Scribe guards against
--- exactly this by clamping before it writes.
function Ordered.SetAsync(self, key: string, value: any)
	validateKey(key)
	if type(value) ~= "number" or value % 1 ~= 0 or value ~= value or math.abs(value) > MAX_INT64 then
		Errors.Raise("ValueNotAllowed", "OrderedDataStore values must be 64-bit integers")
	end

	local disk = self._disk
	disk:Admit(self._jobId or disk._defaultJob, "OrderedWrite", "SetAsync")
	disk:Wait(disk.Latency:Draw("Write"))

	local fault = disk:NextFault("SetAsync", self._name, key)
	if fault ~= nil and fault ~= "Indeterminate" and fault ~= "Lost" then
		disk:Release()
		disk.Faults:Raise(fault)
	end

	self._entries[key] = value
	disk.Stats.Writes += 1
	disk:Release()
	-- Real ordered stores carry no version and no metadata.
	return nil
end

function Ordered.GetAsync(self, key: string): number?
	validateKey(key)
	local disk = self._disk
	disk:Admit(self._jobId or disk._defaultJob, "OrderedRead", "GetAsync")
	disk:Wait(disk.Latency:Draw("Read"))
	disk:Release()
	return self._entries[key]
end

function Ordered.RemoveAsync(self, key: string): number?
	validateKey(key)
	local disk = self._disk
	disk:Admit(self._jobId or disk._defaultJob, "OrderedRemove", "RemoveAsync")
	disk:Wait(disk.Latency:Draw("Write"))

	local previous = self._entries[key]
	self._entries[key] = nil
	disk.Stats.Removes += 1
	disk:Release()
	return previous
end

--- A sorted page of entries.
---
--- Ties break on key so the ordering is total: `table.sort` is not stable, and two
--- players on the same score would otherwise swap places between runs and break
--- replay for no reason anyone could see.
function Ordered.GetSortedAsync(self, ascending: boolean, pageSize: number)
	if type(pageSize) ~= "number" or pageSize < 1 or pageSize > 100 then
		Errors.Raise("PageSizeInvalid")
	end

	local disk = self._disk
	disk:Admit(self._jobId or disk._defaultJob, "OrderedList", "GetAsync")
	disk:Wait(disk.Latency:Draw("Read"))

	local rows = {}
	for key, value in self._entries do
		table.insert(rows, { key = key, value = value })
	end
	table.sort(rows, function(a, b)
		if a.value ~= b.value then
			return if ascending then a.value < b.value else a.value > b.value
		end
		return a.key < b.key
	end)
	while #rows > pageSize do
		table.remove(rows)
	end

	disk.Stats.Reads += 1
	disk:Release()

	return {
		IsFinished = true,
		GetCurrentPage = function()
			return rows
		end,
		-- Leaderboards reads page one and stops, so advancing is unreachable by
		-- construction rather than unimplemented by omission.
		AdvanceToNextPageAsync = function()
			error("sim: OrderedDataStore pagination past page 1 is not modelled", 0)
		end,
	}
end

Ordered.MAX_INT64 = MAX_INT64

return Ordered
