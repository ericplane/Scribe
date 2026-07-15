--!strict
-- Server-authoritative command RPC: named, validated, rate-limited
-- client -> server calls over the buffer channel. Sender identity is always the
-- player provided by the transport callback — never payload contents.

local Internal = script.Parent.Parent.Internal
local Wire = require(Internal.Wire)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)

local Commands = {}

local MAX_ARGS = 16
local MAX_RETURNS = 8

type Handler = (player: Player, ...any) -> ...any
type Registered = {
	Handler: Handler,
	Args: { string }?,
}

function Commands.new(ctx: any)
	local self = {} :: any
	local options = ctx.Options
	local rateLimit: number = options.CommandRateLimit or 20

	local registry: { [string]: Registered } = {}

	function self.Register(name: string, specOrHandler: any, handler: Handler?)
		if type(name) ~= "string" or name == "" then
			error("Scribe: command name must be a non-empty string", 2)
		end
		if registry[name] then
			error(`Scribe: command "{name}" is already registered`, 2)
		end
		local spec: { Args: { string }? }? = nil
		local fn: Handler
		if handler ~= nil then
			spec = specOrHandler
			fn = handler
		else
			fn = specOrHandler
		end
		if type(fn) ~= "function" then
			error(`Scribe: command "{name}" handler must be a function`, 2)
		end
		registry[name] = {
			Handler = fn,
			Args = if spec then spec.Args else nil,
		}
	end

	local function encodeReply(correlation: number, ok: boolean, results: { any }): buffer
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.CommandReply)
		Wire.U32(w, correlation)
		Wire.U8(w, if ok then 1 else 0)
		local n = math.min(#results, MAX_RETURNS)
		Wire.U8(w, n)
		for i = 1, n do
			Wire.EncodeGeneric(w, results[i])
		end
		return Wire.Finish(w)
	end

	local function reply(entry: any, correlation: number, ok: boolean, results: { any })
		local encoded, bytes = pcall(encodeReply, correlation, ok, results)
		if not encoded then
			-- The handler returned something the wire can't carry (Instance,
			-- function, ...). Fail the request cleanly instead of stranding
			-- the client until its timeout.
			Log.Warn("Commands", "COMMAND_REPLY_ENCODE_FAIL", tostring(bytes), { Player = entry.Player })
			bytes = encodeReply(correlation, false, { "reply-encode-failed" })
		end
		ctx.Replication.SendTo(entry, bytes)
	end

	local function takeToken(entry: any): boolean
		local now = os.clock()
		local elapsed = now - entry.RateLast
		entry.RateLast = now
		entry.RateTokens = math.min(rateLimit, entry.RateTokens + elapsed * rateLimit)
		if entry.RateTokens >= 1 then
			entry.RateTokens -= 1
			return true
		end
		return false
	end

	local function typeMatches(expected: string, value: any): boolean
		local optional = string.sub(expected, -1) == "?"
		local base = if optional then string.sub(expected, 1, -2) else expected
		if value == nil then
			return optional
		end
		if base == "any" then
			return true
		end
		return typeof(value) == base
	end

	-- Decode and dispatch a Command frame (called from Replication's inbound
	-- dispatcher; decode errors propagate to its pcall).
	function self.HandleFrame(entry: any, reader: Wire.Reader)
		local correlation = Wire.RU32(reader)
		local name = Wire.RStr(reader)
		local argc = Wire.RU8(reader)
		if argc > MAX_ARGS then
			error("too many command arguments")
		end
		local args = table.create(argc)
		for i = 1, argc do
			args[i] = Wire.DecodeGeneric(reader)
		end

		Metrics.Add("CommandsReceived")

		if not takeToken(entry) then
			Metrics.Add("CommandsRateLimited")
			Log.Warn("Commands", "COMMAND_RATE_LIMITED", `player exceeded {rateLimit}/s`, { Player = entry.Player })
			reply(entry, correlation, false, { "rate-limited" })
			return
		end

		local registered = registry[name]
		if not registered then
			Metrics.Add("CommandsRejected")
			Log.Warn("Commands", "COMMAND_UNKNOWN", `unknown command "{name}"`, { Player = entry.Player })
			reply(entry, correlation, false, { "unknown-command" })
			return
		end

		if entry.State ~= "Ready" then
			reply(entry, correlation, false, { "not-ready" })
			return
		end

		-- Optional argument schema: shape rejection before the handler runs;
		-- semantic validation remains the handler's job.
		if registered.Args then
			if argc > #registered.Args then
				Metrics.Add("CommandsRejected")
				reply(entry, correlation, false, { "bad-args" })
				return
			end
			for i, expected in registered.Args do
				if not typeMatches(expected, args[i]) then
					Metrics.Add("CommandsRejected")
					Log.Warn("Commands", "COMMAND_BAD_ARGS", `argument {i} of "{name}" is not {expected}`, {
						Player = entry.Player,
					})
					reply(entry, correlation, false, { "bad-args" })
					return
				end
			end
		end

		local results: { any } = {}
		local ok, err = xpcall(function()
			results = table.pack(registered.Handler(entry.Player, table.unpack(args, 1, argc))) :: any
		end, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		if not ok then
			Metrics.Add("CommandErrors")
			Log.Error("Commands", "COMMAND_ERROR", `command "{name}" handler threw: {err}`, { Player = entry.Player })
			reply(entry, correlation, false, { "error" })
			return
		end
		Metrics.Add("CommandsHandled")
		reply(entry, correlation, true, results)
	end

	return self
end

return Commands
