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

local COOLDOWN_PREFIX = "@cd|"
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
	function self.OnCooldown(entry: any, key: string, seconds: number): (boolean, number)
		-- Zero/negative seconds means "no cooldown": report off-cooldown WITHOUT
		-- arming. (clampSeconds floors to 1, which would otherwise silently turn a
		-- computed 0 into a real 1-second gate.)
		if type(seconds) ~= "number" or seconds <= 0 then
			return false, 0
		end
		local pathKey = COOLDOWN_PREFIX .. key
		local store = timedStore(entry)
		if not store then
			return false, 0
		end
		local now = os.time()
		local expiry = store[pathKey]
		if expiry and now < expiry then
			return true, expiry - now
		end
		setTimed(entry, pathKey, now + clampSeconds(seconds))
		return false, 0
	end

	-- Read-only cooldown check: never arms. Returns (onCooldown, remaining).
	function self.PeekCooldown(entry: any, key: string): (boolean, number)
		local store = timedStore(entry)
		if not store then
			return false, 0
		end
		local expiry = store[COOLDOWN_PREFIX .. key]
		local now = os.time()
		if expiry and now < expiry then
			return true, expiry - now
		end
		return false, 0
	end

	-- Clear a cooldown (support/testing resets).
	function self.ClearCooldown(entry: any, key: string)
		if timedStore(entry) then
			setTimed(entry, COOLDOWN_PREFIX .. key, nil)
		end
	end

	-- Clear lapsed entries; timed fields reset to their template default,
	-- which fires Changed and replicates — client Observe covers "booster
	-- ended" with no separate expiry event.
	local function sweepEntry(entry: any)
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
			if string.sub(pathKey, 1, #COOLDOWN_PREFIX) ~= COOLDOWN_PREFIX then
				local ok, err = pcall(function()
					local accessor, node = fieldAccessorFromKey(entry, pathKey)
					accessor.Set(if node then Util.deepClone(node.Default) else nil)
				end)
				if not ok then
					Log.Warn("Integrity", "TIMED_SWEEP_FAIL", tostring(err), { Player = entry.Player })
				end
			end
		end
	end

	function self.OnLoad(entry: any)
		sweepEntry(entry)
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
							sweepEntry(entry)
						end
					end
				end
			end
		end)
	end

	return self
end

return Timed
