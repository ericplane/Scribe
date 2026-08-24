--!strict
-- TTL and cooldowns. Absolute expiry timestamps live under _Scribe.Timed
-- (server-only), evaluated lazily on read so they survive rejoins; a 1 Hz sweep
-- clears lapsed fields back to their template default, firing Changed.

local Internal = script.Parent.Parent.Internal
local Util = require(Internal.Util)
local Node = require(Internal.Node)
local Template = require(Internal.Template)
local Log = require(Internal.Log)
local Clock = require(Internal.Clock)
local Sched = require(Internal.Sched)
local Rng = require(Internal.Rng)

local Timed = {}

-- Shared with Template, which rejects a root field using this prefix so a template
-- field can never alias a cooldown slot in the flat _Scribe.Timed dict.
local COOLDOWN_PREFIX = Template.COOLDOWN_PREFIX
local ONLINE_PREFIX = Template.ONLINE_COOLDOWN_PREFIX
local SWEEP_INTERVAL = 1

-- Keys under this prefix are Scribe's, not the game's. Scribe keeps its own
-- once-guards in the same flat cooldown dict a game's cooldowns live in, so the
-- namespace is reserved in both directions: the sweep does not announce a lapsed
-- claim through OnCooldownEnded, and the public entry points refuse the prefix
-- loudly, because Data.ClearCooldown on a purchase idempotency claim is exactly
-- what lets a retry apply the same purchase twice.
local RESERVED_KEY_PREFIX = "@"

--- Is `key` in Scribe's reserved claim namespace?
local function isReserved(key: string): boolean
	return string.sub(key, 1, #RESERVED_KEY_PREFIX) == RESERVED_KEY_PREFIX
end

--- Guard for the public cooldown API. Internal callers (Claim/IsClaimed) skip it:
--- they are the ones that own the reserved namespace.
local function checkPublicKey(key: string, what: string)
	if not Util.isUtf8(key) then
		error(`Scribe: {what} key contains invalid UTF-8 bytes (would corrupt the profile save)`, 3)
	end
	if isReserved(key) then
		error(
			`Scribe: {what} key "{key}" starts with "{RESERVED_KEY_PREFIX}", which is reserved for Scribe's own `
				.. "idempotency claims; pick another prefix",
			3
		)
	end
end

-- Finite ceiling (~126 years) so SetTimed(value, math.huge) means "effectively
-- permanent": expiries are written raw into the persisted _Scribe.Timed store, and
-- an infinite expiry would break the DataStore JSON round trip.
local MAX_TIMED_SECONDS = 4e9

-- Whole seconds, floored to at least 1 and capped finite.
local function clampSeconds(seconds: number): number
	return math.max(1, math.floor(math.min(seconds, MAX_TIMED_SECONDS)))
end

function Timed.new(ctx: any)
	local self = {} :: any
	local compiled: Template.Compiled = ctx.Compiled

	local function timedStore(entry: any): { [string]: number }?
		-- While a save is in flight the profile carries a converted copy (see
		-- BeforeSave) and the live deadlines move here, so no reader or writer ever
		-- observes the persisted form.
		if entry.TimedLive then
			return entry.TimedLive
		end
		local live = entry.LiveData
		local reserved = if live then live[Template.RESERVED_ROOT] else nil
		if type(reserved) ~= "table" then
			return nil
		end
		if type(reserved.Timed) ~= "table" then
			reserved.Timed = {}
		end
		return reserved.Timed
	end

	-- Write an internal expiry, or clear it with value == nil, straight into the
	-- ServerOnly _Scribe.Timed dict. It bypasses the accessor tree on purpose: the
	-- store is a flat dict keyed by full pathKey, and a nested Scribe.Timed field's
	-- pathKey embeds the \31 separator, which Node's dictionary-key guard rejects. The
	-- store lives in profile.Data, so a raw write persists on the next save; Dirty is
	-- what makes that save prompt rather than the next autosave tick.
	local function setTimed(entry: any, pathKey: string, value: number?)
		local store = timedStore(entry)
		if not store then
			return
		end
		local tree = entry.Tree
		-- Cross-tree check first: refuse while a transaction is open on another player.
		-- RecordRawWrite below can only roll a raw timed write back for the tree that
		-- owns the transaction, so on any other tree it is a no-op and the write would
		-- outlive the rollback. Through Node's own check rather than a copy of it, so
		-- the rule has one home. Level 4: AssertSameTreeWrite (1) -> setTimed (2) ->
		-- the Timed entry point (3) -> its public caller (4).
		Node.AssertSameTreeWrite(tree, `{Template.RESERVED_ROOT}.Timed.{pathKey}`, 4)
		-- Record the pre-write expiry so a rollback reverts it in lockstep with the
		-- field's value; without it the value reverts but the timer does not, and a
		-- cooldown armed inside an aborted transaction persists. No-op outside a txn.
		if tree then
			tree:RecordRawWrite(store, pathKey)
		end
		store[pathKey] = value
		if entry.SaveInfo then
			entry.SaveInfo.Dirty = true
		end
	end

	local function fieldAccessorFromKey(entry: any, pathKey: string): (any, Template.SchemaNode?)
		local segments = string.split(pathKey, "\31")
		local accessor = entry.Tree.Accessor
		for _, segment in segments do
			accessor = accessor[segment]
		end
		-- node.Default is only the field's default when Resolve fully consumed the path.
		-- For a field a newer template removed, Resolve stops at a surviving ancestor
		-- whose Default is that whole container, and writing it into the removed
		-- field's path would fabricate a phantom sub-table.
		local node, dynStart = Template.Resolve(compiled, segments)
		if dynStart <= #segments then
			return accessor, nil
		end
		return accessor, node
	end

	-- Node.luau hooks for accessors of Scribe.Timed fields.
	function self.HooksFor(entry: any)
		return {
			SetTimed = function(accessor: any, value: any, seconds: number, replicate: boolean?)
				if type(seconds) ~= "number" or seconds <= 0 then
					error("Scribe: SetTimed seconds must be a positive number", 3)
				end
				accessor.Set(value, replicate)
				local pathKey = Node.PathKeyOf(accessor)
				setTimed(entry, pathKey, Clock.Now() + clampSeconds(seconds))
			end,
			ExtendTimed = function(accessor: any, seconds: number, replicate: boolean?)
				if type(seconds) ~= "number" or seconds <= 0 then
					error("Scribe: ExtendTimed seconds must be a positive number", 3)
				end
				local pathKey = Node.PathKeyOf(accessor)
				local store = timedStore(entry)
				local now = Clock.Now()
				local current = if store then store[pathKey] else nil
				-- Stack onto a running timer; if expired, behave like SetTimed from
				-- now, leaving the value itself untouched.
				local base = if current and current > now then current else now
				setTimed(entry, pathKey, base + clampSeconds(seconds))
				local _ = replicate
			end,
			Active = function(accessor: any): (boolean, number?)
				local pathKey = Node.PathKeyOf(accessor)
				local store = timedStore(entry)
				local expiry = if store then store[pathKey] else nil
				local now = Clock.Now()
				if expiry and now < expiry then
					return true, expiry - now
				end
				return false, nil
			end,
		}
	end

	-- A once-guard: has this key been claimed, and is the claim still live? Separate
	-- from OnCooldown, which re-arms on every use, because a claim must not be
	-- re-armed by the act of checking it.
	function self.IsClaimed(entry: any, key: string): boolean
		local store = timedStore(entry)
		if not store then
			return false
		end
		local deadline = store[COOLDOWN_PREFIX .. key]
		return type(deadline) == "number" and deadline > Clock.Now()
	end

	--- Drop the nearest-to-expiring claims under `prefix` until at most `cap - 1`
	--- remain, so the caller's own claim lands inside the cap. Returns how many were
	--- dropped, and how many are live afterwards.
	---
	--- Claims expire, but nothing bounds how many are live at once: with a seven-day
	--- TTL every keyed purchase a player makes in a week rides in every save and is
	--- walked by the 1 Hz sweep. Nearest-to-expiring goes first, since claims share a
	--- TTL and that one's retry window is closest to over. It is still an eviction, so
	--- the caller logs it loudly: a retry under a dropped claim applies again.
	function self.PruneClaims(entry: any, prefix: string, cap: number): (number, number)
		local store = timedStore(entry)
		if not store then
			return 0, 0
		end
		local full = COOLDOWN_PREFIX .. prefix
		local live: { { Key: string, At: number } } = {}
		for pathKey, expiry in store do
			if type(expiry) == "number" and string.sub(pathKey, 1, #full) == full then
				table.insert(live, { Key = pathKey, At = expiry })
			end
		end
		-- Shrink to the current cap rather than only trimming by one, so a profile
		-- carrying more than a cap lowered between deploys comes back under it.
		local target = math.max(0, math.floor(cap) - 1)
		if #live <= target then
			return 0, #live
		end
		table.sort(live, function(a, b)
			-- Ties broken on the key so eviction is deterministic: two claims taken in
			-- the same second are otherwise ordered by table layout.
			if a.At == b.At then
				return a.Key < b.Key
			end
			return a.At < b.At
		end)
		local dropped = #live - target
		for i = 1, dropped do
			-- Through setTimed, so an open transaction rolls the eviction back with the
			-- claim it made room for; otherwise a rolled-back purchase would still have
			-- thrown away another claim's protection.
			setTimed(entry, live[i].Key, nil)
		end
		return dropped, target
	end

	-- Record that `key` happened, for `seconds`. Re-claiming a live claim does not push
	-- its deadline out, so a retrying caller cannot keep one alive indefinitely.
	function self.Claim(entry: any, key: string, seconds: number)
		if not Util.isUtf8(key) then
			error("Scribe: claim key contains invalid UTF-8 bytes (would corrupt the profile save)", 2)
		end
		local store = timedStore(entry)
		if not store then
			return
		end
		local pathKey = COOLDOWN_PREFIX .. key
		local existing = store[pathKey]
		local now = Clock.Now()
		if type(existing) == "number" and existing > now then
			return
		end
		-- clampSeconds for the finite ceiling: math.floor(inf) is inf, so a
		-- PurchaseClaimTTL of math.huge would write an unserializable expiry into the
		-- persisted dict, which the profile's guards read as unpersistable and then
		-- refuse offline receipts forever.
		setTimed(entry, pathKey, now + clampSeconds(seconds))
	end
	-- Keyed cooldowns: checks and, when off cooldown, arms it. Call it at the grant
	-- moment only; PeekCooldown is the read-only check.
	function self.OnCooldown(entry: any, key: string, seconds: number, options: any?): (boolean, number)
		-- Zero or negative seconds means "no cooldown": report off-cooldown without
		-- arming, since clampSeconds floors to 1 and would turn a computed 0 into a
		-- real one-second gate.
		if type(seconds) ~= "number" or seconds <= 0 then
			return false, 0
		end
		-- The key becomes a persisted table key in the raw _Scribe.Timed dict, bypassing
		-- Node.validateWrite, so invalid UTF-8 would fail the whole profile save (error
		-- 104). Rejected loudly here, along with Scribe's reserved claim namespace.
		checkPublicKey(key, "cooldown")
		local includeOffline = if options and options.IncludeOfflineTime ~= nil
			then options.IncludeOfflineTime == true
			else true
		local pathKey = (if includeOffline then COOLDOWN_PREFIX else ONLINE_PREFIX) .. key
		local otherKey = (if includeOffline then ONLINE_PREFIX else COOLDOWN_PREFIX) .. key
		local store = timedStore(entry)
		if not store then
			return false, 0
		end
		local now = Clock.Now()
		-- Both slots hold an absolute deadline in memory; only the copy the DataStore
		-- receives carries the online one as remaining seconds. Check both slots, not
		-- just this call's mode: a key holds one cooldown, so a caller that flips
		-- IncludeOfflineTime mid-cooldown must be told it is still on it.
		for _, prefix in { COOLDOWN_PREFIX, ONLINE_PREFIX } do
			local running = store[prefix .. key]
			if running and now < running then
				return true, running - now
			end
		end
		-- Flipping the flag must not strand the old slot, which would hand the player a
		-- second, independent cooldown of the other kind.
		if store[otherKey] ~= nil then
			setTimed(entry, otherKey, nil)
		end
		setTimed(entry, pathKey, now + clampSeconds(seconds))
		return false, 0
	end

	-- Read-only cooldown check: never arms. Returns (onCooldown, remaining).
	function self.PeekCooldown(entry: any, key: string): (boolean, number)
		checkPublicKey(key, "cooldown")
		local store = timedStore(entry)
		if not store then
			return false, 0
		end
		local now = Clock.Now()
		for _, prefix in { COOLDOWN_PREFIX, ONLINE_PREFIX } do
			local expiry = store[prefix .. key]
			if expiry and now < expiry then
				return true, expiry - now
			end
		end
		return false, 0
	end

	-- Clear a cooldown (support/testing resets).
	function self.ClearCooldown(entry: any, key: string)
		-- The reserved check matters most here: clearing a purchase idempotency claim
		-- is exactly what lets a retry apply the same purchase a second time.
		checkPublicKey(key, "cooldown")
		if timedStore(entry) then
			setTimed(entry, COOLDOWN_PREFIX .. key, nil)
			setTimed(entry, ONLINE_PREFIX .. key, nil)
		end
	end

	-- Clear lapsed entries. Timed fields reset to their template default, which fires
	-- Changed and replicates, so a client Observe covers expiry with no separate
	-- event. `notify` gates OnCooldownEnded; the load sweep passes false, because
	-- those cooldowns lapsed while the player was away and listeners are not attached
	-- yet.
	local function sweepEntry(entry: any, notify: boolean?)
		local store = timedStore(entry)
		if not store or not entry.Tree or entry.Tree.Dead then
			return
		end
		local now = Clock.Now()
		local lapsed: { { Key: string, Expiry: number } }? = nil
		for pathKey, expiry in store do
			if type(expiry) == "number" and now >= expiry then
				lapsed = lapsed or {}
				table.insert(lapsed :: { { Key: string, Expiry: number } }, { Key = pathKey, Expiry = expiry })
			end
		end
		if not lapsed then
			return
		end
		for _, item in lapsed :: { { Key: string, Expiry: number } } do
			local pathKey = item.Key
			-- Re-check before processing: a Changed listener fired while resetting an
			-- earlier lapsed field may have re-armed or cleared this one, and the stale
			-- precollected entry would wipe that fresh expiry.
			if store[pathKey] ~= item.Expiry then
				continue
			end
			setTimed(entry, pathKey, nil)
			local isOnline = string.sub(pathKey, 1, #ONLINE_PREFIX) == ONLINE_PREFIX
			if not isOnline and string.sub(pathKey, 1, #COOLDOWN_PREFIX) ~= COOLDOWN_PREFIX then
				local ok, err = pcall(function()
					local accessor, node = fieldAccessorFromKey(entry, pathKey)
					accessor.Set(if node then Util.deepClone(node.Default) else nil)
				end)
				if not ok then
					Log.Warn("Integrity", "TIMED_SWEEP_FAIL", tostring(err), { Player = entry.Player })
				end
			elseif notify then
				-- A cooldown holds no value, so clearing it fires no Changed. This
				-- signal is the only expiry notification cooldowns get.
				local prefixLength = if isOnline then #ONLINE_PREFIX else #COOLDOWN_PREFIX
				local bareKey = string.sub(pathKey, prefixLength + 1)
				-- Game cooldowns only: Scribe's idempotency claims share this dict, and
				-- announcing one puts a key the game never set through its handler.
				if not isReserved(bareKey) then
					ctx.Signals.OnCooldownEnded:Fire(entry.Player, bareKey)
				end
			end
		end
	end

	local function toDeadline(entry: any, remainingByKey: { [string]: number })
		local store = timedStore(entry)
		if not store then
			return
		end
		local now = Clock.Now()
		for pathKey, remaining in remainingByKey do
			store[pathKey] = now + remaining
		end
	end

	-- Online-only cooldowns are deadlines in memory and remaining seconds on disk, so
	-- every read works as it does for a wall-clock one. Converting on every save
	-- rather than only on leave makes a crash safe: whatever the DataStore caught is
	-- already a remaining, so the worst case is a cooldown that resumes slightly long.
	--
	-- The conversion goes into a copy the profile carries for the save, while the live
	-- deadlines move to entry.TimedLive. Converting the shared table in place would
	-- leave every reader on remaining seconds for the whole round trip: a live
	-- cooldown would read as a 1970 deadline, Peek and OnCooldown would report it
	-- expired, and the sweep would delete it.
	function self.BeforeSave(entry: any)
		local store = timedStore(entry)
		if not store then
			return nil
		end
		local now = Clock.Now()
		local persisted: { [string]: number } = {}
		for pathKey, value in store do
			if string.sub(pathKey, 1, #ONLINE_PREFIX) == ONLINE_PREFIX and type(value) == "number" then
				-- Whole seconds only: a fractional value roughly quadruples the JSON for
				-- this entry, which feeds the profile-size and wipe-guard checks.
				persisted[pathKey] = math.max(0, math.floor(value - now))
			else
				persisted[pathKey] = value
			end
		end
		entry.TimedLive = store
		-- ProfileStore task.spawns every save and holds no per-profile lock, so an
		-- autosave tick can start while a Data.Flush is still in flight; count the
		-- open windows rather than assuming one.
		entry.TimedSaves = (entry.TimedSaves or 0) + 1
		local reserved = entry.LiveData and entry.LiveData[Template.RESERVED_ROOT]
		if type(reserved) == "table" then
			reserved.Timed = persisted
		end
		return store
	end

	function self.AfterSave(entry: any, held: { [string]: number }?)
		if held == nil then
			return
		end
		-- Only the last save out closes the window. Restoring while another is still in
		-- flight would point the profile back at the live deadlines, and that save
		-- would serialize them as remaining seconds: a rejoin then turns 1.78e9
		-- "remaining" into a deadline decades away, re-minted by every later save.
		--
		-- A failed save never fires OnAfterSave, so its count is never given back and
		-- the window stays open for the session. That is inert: timedStore still hands
		-- out the live table and BeforeSave rebuilds the persisted copy every save.
		-- Closing it from the failure path is not possible, because ProfileStore cannot
		-- say which call failed.
		local remaining = (entry.TimedSaves or 1) - 1
		entry.TimedSaves = math.max(0, remaining)
		if remaining > 0 then
			return
		end
		entry.TimedLive = nil
		local reserved = entry.LiveData and entry.LiveData[Template.RESERVED_ROOT]
		if type(reserved) == "table" then
			reserved.Timed = held
		end
	end

	-- Clear one field's expiry in the live store. DebugHook's ClearTimed needs the flat
	-- dict directly, since a nested field's pathKey embeds \31 and the accessor tree
	-- rejects it; routing it here keeps it off the throwaway copy a save is holding.
	function self.ClearField(entry: any, pathKey: string)
		setTimed(entry, pathKey, nil)
	end

	-- On load the stored value is a remaining, so turn it back into a deadline before
	-- anything reads it.
	local function restoreDeadlines(entry: any)
		local store = timedStore(entry)
		if not store then
			return
		end
		local remaining: { [string]: number } = {}
		for pathKey, value in store do
			if string.sub(pathKey, 1, #ONLINE_PREFIX) == ONLINE_PREFIX and type(value) == "number" then
				remaining[pathKey] = value
			end
		end
		toDeadline(entry, remaining)
	end

	function self.OnLoad(entry: any)
		restoreDeadlines(entry)
		sweepEntry(entry)
	end

	-- One pass of the periodic sweep, including the OnCooldownEnded signal. Named so
	-- the 1 Hz loop below and the tests drive the same code path.
	function self.Sweep(entry: any)
		sweepEntry(entry, true)
	end

	function self.OnUnload(_entry: any) end

	local stopped = false
	local sweepThread: thread? = nil
	-- Called by Server.build once the full ctx is assembled, so the sweep never runs
	-- against a half-constructed context.
	function self.Start()
		sweepThread = Sched.Spawn(function()
			while not stopped do
				-- Jittered so every server in the place does not sweep on one shared
				-- metronome tick.
				Clock.Wait(Rng.Jitter(SWEEP_INTERVAL))
				local persistence = ctx.Persistence
				if persistence then
					for _, entry in persistence.Entries do
						if entry.State == "Ready" then
							self.Sweep(entry)
						end
					end
				end
			end
		end)
	end

	-- Release the sweep so the bundle can be discarded. The flag alone would leave the
	-- thread parked in task.wait for up to SWEEP_INTERVAL, so many bundles in one
	-- process (a multi-server simulation, or the test harnesses) would pile up.
	function self.Stop()
		if stopped then
			return
		end
		stopped = true
		if sweepThread ~= nil then
			pcall(task.cancel, sweepThread)
			sweepThread = nil
		end
	end

	return self
end

return Timed
