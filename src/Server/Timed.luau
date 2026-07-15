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

	local function timedAccessor(entry: any, pathKey: string): any
		return entry.Tree.Accessor[Template.RESERVED_ROOT].Timed[pathKey]
	end

	local function fieldAccessorFromKey(entry: any, pathKey: string): (any, Template.SchemaNode?)
		local segments = string.split(pathKey, "\31")
		local accessor = entry.Tree.Accessor
		for _, segment in segments do
			accessor = accessor[segment]
		end
		local node = Template.Resolve(compiled, segments)
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
				timedAccessor(entry, pathKey).Set(os.time() + math.floor(seconds), false)
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
				timedAccessor(entry, pathKey).Set(base + math.floor(seconds), false)
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
		timedAccessor(entry, pathKey).Set(now + math.floor(seconds), false)
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
			timedAccessor(entry, COOLDOWN_PREFIX .. key).Set(nil, false)
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
		local lapsed: { string }? = nil
		for pathKey, expiry in store do
			if type(expiry) == "number" and now >= expiry then
				lapsed = lapsed or {}
				table.insert(lapsed :: { string }, pathKey)
			end
		end
		if not lapsed then
			return
		end
		for _, pathKey in lapsed :: { string } do
			timedAccessor(entry, pathKey).Set(nil, false)
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
