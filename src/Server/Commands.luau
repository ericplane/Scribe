--!strict
-- Server-authoritative command RPC: named, validated, rate-limited
-- client -> server calls over the buffer channel. Sender identity is always the
-- player provided by the transport callback — never payload contents.

local Internal = script.Parent.Parent.Internal
local Wire = require(Internal.Wire)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Marker = require(Internal.Marker)

local Commands = {}

local MAX_ARGS = Wire.MAX_COMMAND_ARGS
local MAX_RETURNS = 8
-- Nesting cap for an opt-in table-argument shape (see specMatches).
local MAX_SHAPE_DEPTH = 8
-- Declarator kinds meaningful for a COMMAND ARGUMENT. The rest describe how a field
-- is stored or replicated (Timed, ServerOnly, Shared, Session, Dynamic) or carry a
-- value the wire cannot even represent (Datatype, Big), so accepting them would
-- promise a check that could never pass.
local ARG_MARKERS: { [string]: boolean } = {
	Int = true,
	Number = true,
	String = true,
	Enum = true,
	Flags = true,
	Optional = true,
	ArrayOf = true,
	SetOf = true,
	DictOf = true,
	MapOf = true,
}
-- Rate-limited frames still cost a log line and an outbound reply each, so a flood
-- is throttled: at most one log per interval per player, and past a sustained-flood
-- cutoff the reply is dropped too. The count decays after a quiet window so an
-- occasional legitimate burst never accumulates toward the cutoff.
local RATE_LOG_INTERVAL = 1 -- seconds between COMMAND_RATE_LIMITED logs per player
local RATE_RESET_WINDOW = 10 -- seconds of no rate-limiting that resets the counter
local RATE_LIMIT_MAX = 256 -- sustained rate-limited frames before replies stop

type Handler = (player: Player, ...any) -> ...any
type Registered = {
	Handler: Handler,
	Args: { any }?, -- type strings and/or shape tables
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
		local spec: { Args: { any }? }? = nil
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
		local args = if spec then spec.Args else nil
		if args ~= nil then
			if type(args) ~= "table" then
				error(`Scribe: command "{name}" Args must be an array of type strings or shapes`, 2)
			end
			-- Reject a malformed spec at REGISTER time, not on the first client call.
			-- A spec that silently never matches turns every request into "bad-args",
			-- which reads as a client bug and is a miserable thing to chase in prod.
			local function checkSpec(entry: any, where: string, depth: number)
				if type(entry) == "string" then
					return
				end
				if type(entry) ~= "table" then
					error(
						`Scribe: command "{name}" {where} must be a type string, a Scribe declarator, or a shape table`,
						3
					)
				end
				if depth > MAX_SHAPE_DEPTH then
					error(`Scribe: command "{name}" {where} nests deeper than {MAX_SHAPE_DEPTH}`, 3)
				end
				local kind, default, meta = Marker.inspect(entry)
				if kind ~= nil then
					if not ARG_MARKERS[kind] then
						-- Naming the kind matters: without it the recursion below walks the
						-- marker's internals and reports something like "Args[1].Meta.Min",
						-- which is Scribe's own structure leaking into the caller's error.
						error(
							`Scribe: command "{name}" {where} is a Scribe.{kind}, which describes stored data rather `
								.. `than a wire argument. Command arguments accept `
								.. `Int/Number/String/Enum/Flags/Optional/ArrayOf/SetOf/DictOf/MapOf.`,
							3
						)
					end
					if kind == "Optional" then
						checkSpec(default, `{where} (Optional inner)`, depth + 1)
					elseif meta ~= nil and meta.Element ~= nil then
						checkSpec(meta.Element, `{where} (element)`, depth + 1)
					end
					return
				end
				if entry[1] ~= nil then
					checkSpec(entry[1], `{where}[1]`, depth + 1)
					for key in entry do
						if key ~= 1 then
							error(
								`Scribe: command "{name}" {where} mixes an array element spec at [1] with the key `
									.. `"{tostring(key)}"; a shape is either an array or a set of named fields`,
								3
							)
						end
					end
					return
				end
				for key, field in entry do
					checkSpec(field, `{where}.{tostring(key)}`, depth + 1)
				end
			end
			for i, entry in args do
				checkSpec(entry, `Args[{i}]`, 0)
			end
		end
		registry[name] = {
			Handler = fn,
			Args = args,
		}
	end

	local function encodeReply(correlation: number, ok: boolean, results: { any }): buffer
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.CommandReply)
		Wire.U32(w, correlation)
		Wire.U8(w, if ok then 1 else 0)
		-- results.n (from table.pack) is the true count and survives an embedded
		-- nil that `#` would stop short at; fall back to `#` for the plain-array
		-- caller above, which has no holes.
		local n = math.min((results :: any).n or #results, MAX_RETURNS)
		Wire.U8(w, n)
		for i = 1, n do
			Wire.EncodeGeneric(w, results[i])
		end
		return Wire.Finish(w)
	end

	local function reply(entry: any, correlation: number, ok: boolean, results: { any })
		-- encodeReply clamps to MAX_RETURNS. Silently dropping the extras contradicts
		-- the documented "the handler's return values ARE the Request results", and the
		-- caller just sees trailing nils, so say so. Only meaningful on a success
		-- reply; the internal failure replies are always single-value.
		local resultCount = (results :: any).n or #results
		if ok and resultCount > MAX_RETURNS then
			Log.Warn(
				"Commands",
				"COMMAND_REPLY_TRUNCATED",
				`handler returned {resultCount} values; only the first {MAX_RETURNS} are sent`,
				{ Player = entry.Player }
			)
		end
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

	-- Same reasoning as the throttled COMMAND_RATE_LIMITED log below: these fire on
	-- client-controlled input that sits UNDER the rate limit, so an exploiter can
	-- drive them at the full allowance and evict the whole diagnostic ring, erasing
	-- the evidence of everything else. One entry per interval per player per code
	-- is enough to see the pattern.
	local function throttledWarn(entry: any, code: any, message: string, context: { [string]: any })
		local now = os.clock()
		local seen = entry.LastCommandWarnAt
		if not seen then
			seen = {}
			entry.LastCommandWarnAt = seen
		end
		if now - (seen[code] or -math.huge) < RATE_LOG_INTERVAL then
			return
		end
		seen[code] = now
		Log.Warn("Commands", code, message, context)
	end

	-- An arg spec is one of three things:
	--
	--   "string", "number?", "any"                  a type string
	--   Scribe.Int(0, { Min = 0, Max = 99 })        a declarator, with its constraints
	--   { Id = "string", Qty = "number?" }          a shape, nestable, mixable with both
	--
	-- Declarators are accepted because the alternative was a second vocabulary for
	-- saying what the template vocabulary already says, and because their CONSTRAINTS
	-- come along: Min/Max, MaxLength, Enum members, MaxItems/MaxKeys. A type string
	-- can only say "a number arrived", which is the half of the check that never
	-- catches anything interesting.
	--
	-- All of it stays opt-in. A bare "table" is exactly as permissive as it was --
	-- `typeof` says table and the handler owns everything after that -- because most
	-- commands take scalars and forcing a shape on them would be noise.
	local markerMatches: (string, any, any, any, number) -> boolean
	local function specMatches(expected: any, value: any, depth: number): boolean
		if type(expected) == "string" then
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
		if type(expected) ~= "table" then
			return false -- unreachable: Register rejects any other spec form
		end
		local kind, default, meta = Marker.inspect(expected)
		if kind ~= nil then
			return markerMatches(kind, default, meta, value, depth)
		end
		-- A shape is always required. The vocabulary stays deliberately small: a
		-- command that wants an optional table declares "table?" and validates the
		-- contents itself, rather than growing an optional-shape form here.
		if type(value) ~= "table" or depth > MAX_SHAPE_DEPTH then
			return false
		end
		local elementSpec = expected[1]
		if elementSpec ~= nil then
			-- Array form: every element matches, and there are no extra keys hiding
			-- alongside them (a payload is a shape, not a shape plus attachments).
			for key, item in value do
				if type(key) ~= "number" or not specMatches(elementSpec, item, depth + 1) then
					return false
				end
			end
			return true
		end
		for key, fieldSpec in expected do
			if not specMatches(fieldSpec, value[key], depth + 1) then
				return false
			end
		end
		-- Reject unknown keys. A payload carrying fields the command never declared
		-- is either version skew or someone probing, and silently passing them into
		-- the handler is how an unvalidated field reaches game logic.
		for key in value do
			if expected[key] == nil then
				return false
			end
		end
		return true
	end

	-- Declarator constraints, checked against a value that arrived over the wire.
	-- Deliberately a REJECTION, never a clamp: a template write clamps because the
	-- server chose the value and losing precision beats losing the write, but a
	-- command argument is the client's claim about what it wants, and silently
	-- clamping it to something legal is how "buy 999999 items" becomes "buy 99".
	function markerMatches(kind, default, meta, value, depth)
		meta = meta or {}
		if kind == "Optional" then
			-- Scribe.Optional wraps its inner shape in the marker's Default, not Meta.
			return value == nil or specMatches(default, value, depth)
		end
		if kind == "Int" or kind == "Number" then
			if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
				return false
			end
			if kind == "Int" and value % 1 ~= 0 then
				return false
			end
			if meta.Min ~= nil and value < meta.Min then
				return false
			end
			if meta.Max ~= nil and value > meta.Max then
				return false
			end
			return true
		end
		if kind == "String" then
			if type(value) ~= "string" or not utf8.len(value) then
				return false -- invalid UTF-8 cannot be persisted, so refuse it at the door
			end
			return meta.MaxLength == nil or #value <= meta.MaxLength
		end
		if kind == "Enum" then
			return type(value) == "string" and table.find(meta.Members or {}, value) ~= nil
		end
		if kind == "Flags" then
			if type(value) ~= "table" then
				return false
			end
			local count = 0
			for key, member in value do
				if type(key) ~= "number" or table.find(meta.Members or {}, member) == nil then
					return false
				end
				count += 1
			end
			return count == #value
		end
		if kind == "ArrayOf" or kind == "SetOf" then
			if type(value) ~= "table" then
				return false
			end
			local count = 0
			for key, item in value do
				if type(key) ~= "number" or not specMatches(meta.Element, item, depth + 1) then
					return false
				end
				count += 1
			end
			if count ~= #value then
				return false -- holes or string keys hiding in an array
			end
			return meta.MaxItems == nil or count <= meta.MaxItems
		end
		if kind == "DictOf" or kind == "MapOf" then
			if type(value) ~= "table" then
				return false
			end
			local wantInteger = meta.KeyType == "integer"
			local count = 0
			for key, item in value do
				if wantInteger then
					if type(key) ~= "number" or key % 1 ~= 0 then
						return false
					end
				else
					if type(key) ~= "string" then
						return false
					end
					if meta.MaxKeyLength ~= nil and #key > meta.MaxKeyLength then
						return false
					end
				end
				if not specMatches(meta.Element, item, depth + 1) then
					return false
				end
				count += 1
			end
			return meta.MaxKeys == nil or count <= meta.MaxKeys
		end
		return false -- unreachable: Register rejects every other kind
	end

	local function typeMatches(expected: any, value: any): boolean
		return specMatches(expected, value, 0)
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

		Metrics.Add("CommandsReceived")

		-- The token check sits BEFORE the argument decode, and has to stay there.
		-- Arguments are attacker-sized: MAX_ARGS generic values, each able to nest to
		-- the wire's depth cap and fill the whole MaxInboundBytes frame. Decoding
		-- first meant the rate limit protected the HANDLERS but not the DECODER,
		-- which is where the CPU actually goes -- a flood of well-formed, oversized
		-- Command frames was paid for in full and only then thrown away. These frames
		-- are valid, so the malformed-frame budget never catches them either.
		-- The header read above (correlation, name, argc) is fixed-cost and is all
		-- the rejection reply needs; the undecoded tail dies with the reader.
		if not takeToken(entry) then
			Metrics.Add("CommandsRateLimited")
			local now = os.clock()
			-- Decay first: a player who stopped flooding starts fresh, so a rare
			-- legitimate burst never creeps toward the sustained-flood cutoff.
			if now - (entry.LastRateLimitAt or -math.huge) > RATE_RESET_WINDOW then
				entry.RateLimitedCount = 0
			end
			entry.LastRateLimitAt = now
			entry.RateLimitedCount = (entry.RateLimitedCount or 0) + 1
			-- Throttle the LOG. Unthrottled this is the one command path an exploiter
			-- can drive without bound, and it would evict the whole log ring, erasing
			-- the evidence of the flood itself.
			if now - (entry.LastRateLimitLog or -math.huge) >= RATE_LOG_INTERVAL then
				entry.LastRateLimitLog = now
				Log.Warn("Commands", "COMMAND_RATE_LIMITED", `player exceeded {rateLimit}/s`, {
					Player = entry.Player,
					Count = entry.RateLimitedCount,
				})
			end
			-- Keep replying up to the cutoff so a well-behaved client that briefly
			-- overruns is not stranded until its request timeout; past it, a client is
			-- clearly not waiting on answers and each reply is just outbound cost.
			if entry.RateLimitedCount < RATE_LIMIT_MAX then
				reply(entry, correlation, false, { "rate-limited" })
			end
			return
		end

		-- Above the registry lookup, so a session that is not Ready answers
		-- "not-ready" for EVERY name. Below it, the two replies differed by whether
		-- the name was registered, which let an unauthenticated client enumerate the
		-- whole command surface by diffing "unknown-command" against "not-ready".
		-- Nothing real is lost: Client.Request goes through waitForLoaded, which only
		-- returns once an Init frame arrived, so a genuine Scribe client cannot send
		-- a command in this window at all -- anything arriving here is a client Scribe
		-- did not write, and COMMAND_UNKNOWN would be describing it wrongly anyway.
		if entry.State ~= "Ready" then
			reply(entry, correlation, false, { "not-ready" })
			return
		end

		local registered = registry[name]
		if not registered then
			Metrics.Add("CommandsRejected")
			throttledWarn(entry, "COMMAND_UNKNOWN", `unknown command "{name}"`, { Player = entry.Player })
			reply(entry, correlation, false, { "unknown-command" })
			return
		end

		-- The arity half of the argument schema needs only the header, so it runs
		-- before the decode and rejects an over-long call without paying for it.
		if registered.Args and argc > #registered.Args then
			Metrics.Add("CommandsRejected")
			reply(entry, correlation, false, { "bad-args" })
			return
		end

		-- Decode last. Every rejection above is answered from the fixed-cost header
		-- alone, so only a frame that cleared the rate limit, named a registered
		-- command, arrived on a Ready session, and declared a plausible argument
		-- count ever costs a decode.
		local args = table.create(argc)
		for i = 1, argc do
			args[i] = Wire.DecodeGeneric(reader)
		end

		-- Optional argument schema: shape rejection before the handler runs;
		-- semantic validation remains the handler's job.
		if registered.Args then
			for i, expected in registered.Args do
				if not typeMatches(expected, args[i]) then
					Metrics.Add("CommandsRejected")
					throttledWarn(entry, "COMMAND_BAD_ARGS", `argument {i} of "{name}" is not {expected}`, {
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
