--!strict
-- TTL and cooldowns. Absolute expiry timestamps (os.time) live under
-- _Scribe.Timed (server-only), evaluated lazily on read so they survive
-- rejoins; a 1 Hz sweep auto-clears lapsed fields back to their template
-- default, firing Changed and replicating.

local Internal = script.Parent.Parent.Internal
local Util = require(Internal.Util)
local Template = require(Internal.Template)
local Log = require(Internal.Log)

local Timed = {}

-- Shared with Template, which rejects a root field using this prefix so a template
-- field can never alias a cooldown slot in the flat _Scribe.Timed dict.
local COOLDOWN_PREFIX = Template.COOLDOWN_PREFIX
local ONLINE_PREFIX = Template.ONLINE_COOLDOWN_PREFIX
local SWEEP_INTERVAL = 1
-- Finite ceiling (~126 years) so SetTimed(value, math.huge) is a safe way to say
-- "effectively permanent": expiries are written RAW into the persisted _Scribe.Timed
-- store, and an infinite expiry would break the DataStore JSON round trip.
local MAX_TIMED_SECONDS = 4e9

-- Whole seconds, floored to at least 1 and capped finite.
local function clampSeconds(seconds: number): number
	return math.max(1, math.floor(math.min(seconds, MAX_TIMED_SECONDS)))
end

function Timed.new(ctx: any)
	local self = {} :: any
	local compiled: Template.Compiled = ctx.Compiled

	local function timedStore(entry: any): { [string]: number }?
		-- While a save is in flight the profile carries a converted COPY (see
		-- BeforeSave) and the live deadlines move here. Every reader and writer stays
		-- on the live table, so nothing observes the persisted form.
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

	-- Write an internal expiry (or clear it, with value == nil) directly into the
	-- ServerOnly _Scribe.Timed dict. This deliberately bypasses the accessor tree:
	-- the store is a FLAT dict keyed by each field's full pathKey, and a NESTED
	-- Scribe.Timed field's pathKey embeds the \31 path separator, which the
	-- accessor's dictionary-key guard rejects (Node.luau). The store is ServerOnly
	-- and lives in profile.Data, so a raw write persists on the next save; flag
	-- Dirty so that save happens promptly rather than only on the autosave tick.
	local function setTimed(entry: any, pathKey: string, value: number?)
		local store = timedStore(entry)
		if not store then
			return
		end
		-- If a transaction is open, record the pre-write expiry so a rollback reverts
		-- it in lockstep with the field's value (which rolls back via the accessor).
		-- Without this the value would revert but the timer would not, or a cooldown
		-- armed inside an aborted transaction would persist. No-op outside a txn.
		local tree = entry.Tree
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
		-- Only treat node.Default as the field default when Resolve FULLY consumed the
		-- path (the field still has a static schema). If a template version removed the
		-- field, Resolve stops at a surviving ancestor whose Default is that whole
		-- container -- writing THAT into the removed field's path would fabricate a
		-- phantom sub-table. A dynamic (non-static) key has no template default either.
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
				local pathKey = rawget(accessor, "_key") :: string
				setTimed(entry, pathKey, os.time() + clampSeconds(seconds))
			end,
			ExtendTimed = function(accessor: any, seconds: number, replicate: boolean?)
				if type(seconds) ~= "number" or seconds <= 0 then
					error("Scribe: ExtendTimed seconds must be a positive number", 3)
				end
				local pathKey = rawget(accessor, "_key") :: string
				local store = timedStore(entry)
				local now = os.time()
				local current = if store then store[pathKey] else nil
				-- Stack onto a running timer; if expired/inactive, behave like
				-- SetTimed from now (the value itself is left untouched).
				local base = if current and current > now then current else now
				setTimed(entry, pathKey, base + clampSeconds(seconds))
				local _ = replicate
			end,
			Active = function(accessor: any): (boolean, number?)
				local pathKey = rawget(accessor, "_key") :: string
				local store = timedStore(entry)
				local expiry = if store then store[pathKey] else nil
				local now = os.time()
				if expiry and now < expiry then
					return true, expiry - now
				end
				return false, nil
			end,
		}
	end

	-- Keyed cooldowns: checks and — when off cooldown — ARMS it. Call this only
	-- at the grant/claim moment; use PeekCooldown for display checks.
	function self.OnCooldown(entry: any, key: string, seconds: number, options: any?): (boolean, number)
		-- Zero/negative seconds means "no cooldown": report off-cooldown WITHOUT
		-- arming. (clampSeconds floors to 1, which would otherwise silently turn a
		-- computed 0 into a real 1-second gate.)
		if type(seconds) ~= "number" or seconds <= 0 then
			return false, 0
		end
		-- The cooldown key becomes a persisted table key in the raw _Scribe.Timed
		-- dict, bypassing Node.validateWrite, so an invalid-UTF-8 key would fail the
		-- whole profile save (error 104). Reject it loudly at the call site, matching
		-- the accessor write guard and the other raw-write boundaries.
		if not Util.isUtf8(key) then
			error("Scribe: cooldown key contains invalid UTF-8 bytes (would corrupt the profile save)", 2)
		end
		local includeOffline = if options and options.IncludeOfflineTime ~= nil
			then options.IncludeOfflineTime == true
			else true
		local pathKey = (if includeOffline then COOLDOWN_PREFIX else ONLINE_PREFIX) .. key
		local otherKey = (if includeOffline then ONLINE_PREFIX else COOLDOWN_PREFIX) .. key
		local store = timedStore(entry)
		if not store then
			return false, 0
		end
		local now = os.time()
		-- Both slots hold an ABSOLUTE deadline for the whole session, saves included;
		-- the online one is converted to remaining seconds only in the copy the
		-- DataStore receives, so reads here are identical for the two modes.
		-- Check BOTH slots, not just this call's mode. A key holds one cooldown, so a
		-- caller that flips IncludeOfflineTime while the other slot is still running
		-- must be told it is on cooldown rather than handed a fresh one.
		for _, prefix in { COOLDOWN_PREFIX, ONLINE_PREFIX } do
			local running = store[prefix .. key]
			if running and now < running then
				return true, running - now
			end
		end
		-- Flipping the flag for a key must not strand the old slot, which would hand
		-- the player a second, independent cooldown of the other kind.
		if store[otherKey] ~= nil then
			setTimed(entry, otherKey, nil)
		end
		setTimed(entry, pathKey, now + clampSeconds(seconds))
		return false, 0
	end

	-- Read-only cooldown check: never arms. Returns (onCooldown, remaining).
	function self.PeekCooldown(entry: any, key: string): (boolean, number)
		if not Util.isUtf8(key) then
			error("Scribe: cooldown key contains invalid UTF-8 bytes", 2)
		end
		local store = timedStore(entry)
		if not store then
			return false, 0
		end
		local now = os.time()
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
		if not Util.isUtf8(key) then
			error("Scribe: cooldown key contains invalid UTF-8 bytes", 2)
		end
		if timedStore(entry) then
			setTimed(entry, COOLDOWN_PREFIX .. key, nil)
			setTimed(entry, ONLINE_PREFIX .. key, nil)
		end
	end

	-- Clear lapsed entries; timed fields reset to their template default,
	-- which fires Changed and replicates — client Observe covers "booster
	-- ended" with no separate expiry event.
	-- `notify` gates the OnCooldownEnded signal. The load sweep passes false: those
	-- cooldowns lapsed while the player was away, so "ended" would be misleading,
	-- the entry is not Ready yet so listeners may not be attached, and a joining
	-- client reads PeekCooldown for its initial state anyway.
	local function sweepEntry(entry: any, notify: boolean?)
		local store = timedStore(entry)
		if not store or not entry.Tree or entry.Tree.Dead then
			return
		end
		local now = os.time()
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
			-- EARLIER lapsed field may have re-armed (SetTimed) or cleared this one.
			-- Processing the stale precollected entry would wipe that fresh expiry and
			-- reset the field, silently destroying the listener's write.
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
				ctx.Signals.OnCooldownEnded:Fire(entry.Player, string.sub(pathKey, prefixLength + 1))
			end
		end
	end

	local function toDeadline(entry: any, remainingByKey: { [string]: number })
		local store = timedStore(entry)
		if not store then
			return
		end
		local now = os.time()
		for pathKey, remaining in remainingByKey do
			store[pathKey] = now + remaining
		end
	end

	-- Online-only cooldowns are DEADLINES in memory (so every read, the sweep, and
	-- Peek work exactly as they do for a wall-clock one) and REMAINING SECONDS on
	-- disk. Converting on the way out is what makes offline time not count, and doing
	-- it on every save rather than only on leave is what makes a crash safe: whatever
	-- the DataStore caught is already a remaining, so the worst case is a cooldown
	-- that resumes slightly long, never one that resumes as a deadline in 1970.
	--
	-- The conversion goes into a COPY that the profile carries for the save, and the
	-- live deadlines move to entry.TimedLive, which timedStore hands to everyone
	-- else. Converting the shared table in place instead would leave every reader
	-- looking at remaining seconds for the whole DataStore round trip: a live
	-- cooldown reads as a 1970 deadline, so Peek and OnCooldown report it expired,
	-- the 1 Hz sweep deletes it, and a write landing in the window is overwritten on
	-- the way back out. A save that never completes leaves only the throwaway copy
	-- stale, and the next BeforeSave re-points it.
	function self.BeforeSave(entry: any)
		local store = timedStore(entry)
		if not store then
			return nil
		end
		local now = os.time()
		local persisted: { [string]: number } = {}
		for pathKey, value in store do
			if string.sub(pathKey, 1, #ONLINE_PREFIX) == ONLINE_PREFIX and type(value) == "number" then
				-- Whole seconds only: a fractional value roughly quadruples the JSON for
				-- this entry and feeds the profile-size and wipe-guard checks.
				persisted[pathKey] = math.max(0, math.floor(value - now))
			else
				persisted[pathKey] = value
			end
		end
		entry.TimedLive = store
		-- ProfileStore task.spawns every save and holds no per-profile lock, so an
		-- autosave tick can start while a Data.Flush is still in flight. Count the
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
		-- Only the last save out closes the window. Restoring while another is still
		-- in flight would point the profile back at the live DEADLINES, and that save
		-- would then serialize them as remaining seconds: a rejoin turns 1.78e9
		-- "remaining" into a deadline decades away, and every later save re-mints it.
		--
		-- A save that FAILS never fires OnAfterSave, so its count is never given back
		-- and the window stays open for the rest of the session. That is inert on
		-- purpose: the live table is still what timedStore hands out, and BeforeSave
		-- rebuilds the persisted copy on every save, so the only lasting effect is
		-- that LiveData keeps carrying a copy rather than the live table. Closing it
		-- from the failure path is what cannot be done safely, because ProfileStore
		-- cannot tell us which call failed (see the OnError handler in Persistence).
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

	-- Clear one field's expiry in the live store. DebugHook's ClearTimed needs the
	-- flat dict directly, because a NESTED Scribe.Timed field's pathKey embeds \31,
	-- which the accessor tree rejects; routing it here keeps it off the throwaway
	-- copy a save is holding.
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

	-- One pass of the periodic sweep, including the OnCooldownEnded signal. Named
	-- so the 1 Hz loop below and the tests drive the same code path.
	function self.Sweep(entry: any)
		sweepEntry(entry, true)
	end

	function self.OnUnload(_entry: any) end

	-- Called by Server.build once the full ctx is assembled, so the sweep
	-- never runs against a half-constructed context.
	function self.Start()
		task.spawn(function()
			while true do
				task.wait(SWEEP_INTERVAL)
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

	return self
end

return Timed
