--!strict
-- Server-authoritative command RPC: named, validated, rate-limited client to
-- server calls over the buffer channel. Sender identity is always the player the
-- transport callback provided, never payload contents.

local Internal = script.Parent.Parent.Internal
local Wire = require(Internal.Wire)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Marker = require(Internal.Marker)
local Clock = require(Internal.Clock)

local Commands = {}

local MAX_ARGS = Wire.MAX_COMMAND_ARGS
local MAX_RETURNS = 8
-- Nesting cap for an opt-in table-argument shape (see specMatches).
local MAX_SHAPE_DEPTH = 8
-- Declarator kinds meaningful for a command argument. The rest describe storage or
-- replication (Timed, ServerOnly, Shared, Session, Dynamic) or carry a value the
-- wire cannot represent (Datatype, Big), so accepting them would promise a check
-- that could never pass.
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
-- is throttled: one log per interval per player, and past a sustained-flood cutoff
-- the reply is dropped too. The count decays after a quiet window so a legitimate
-- burst never accumulates toward the cutoff.
local RATE_LOG_INTERVAL = 1 -- seconds between COMMAND_RATE_LIMITED logs per player
local RATE_RESET_WINDOW = 10 -- seconds of no rate-limiting that resets the counter
-- Seconds between COMMAND_ERROR lines: log the first, count the rest, say how many
-- were suppressed.
local COMMAND_ERROR_LOG_INTERVAL = 5
local lastCommandErrorLog: number? = nil
local commandErrorsSinceLog = 0

local RATE_LIMIT_MAX = 256 -- sustained rate-limited frames before replies stop

local MAX_IDEMPOTENCY_KEY_BYTES = Wire.MAX_IDEMPOTENCY_KEY_BYTES
-- Live idempotency records held per player. The cache is the protection, so evicting
-- an unexpired record means a retry under that key runs the handler a second time.
-- It is bounded anyway: unlike a Data.Purchase key this one is named by the client,
-- so without a ceiling a player at the full CommandRateLimit mints records forever.
local MAX_IDEMPOTENT_RECORDS = 64
-- Duplicates parked on one in-flight call. Client-driven, so bounded.
local MAX_IDEMPOTENT_WAITERS = 32

type Handler = (player: Player, ...any) -> ...any
type Registered = {
	Handler: Handler,
	Args: { any }?, -- type strings and/or shape tables
	Idempotent: boolean, -- requires a per-call key, and runs at most once per key
}
-- One in-flight or settled call under an idempotency key.
type IdemRecord = {
	CacheKey: string,
	At: number, -- Clock.Monotonic() at creation; drives expiry and eviction order
	Done: boolean,
	Ok: boolean,
	Results: { any }?, -- the packed reply, `.n` intact (see settleIdempotent)
	Waiters: { number }, -- correlations of duplicates that arrived while in flight
}

function Commands.new(ctx: any)
	local self = {} :: any
	local options = ctx.Options
	local rateLimit: number = options.CommandRateLimit or 20
	-- How long a settled idempotency record answers repeats. Derived rather than
	-- configured: the window only has to outlast the client's own retry window, which
	-- RequestTimeout defines. The floor keeps a short RequestTimeout from shortening
	-- the protection to something a human reconnecting could outrun.
	local idempotencyTTL: number = math.max(120, (tonumber(options.RequestTimeout) or 10) * 4)

	local registry: { [string]: Registered } = {}
	-- The longest name any command is registered under, floored so an ordinary typo
	-- still reaches the registry and gets an `unknown-command` reply rather than being
	-- charged as malformed. It bounds the one attacker-sized read the rate limit does
	-- not cover: the name is read above takeToken, so it runs at the raw frame rate.
	local COMMAND_NAME_FLOOR = 64
	local maxNameBytes = COMMAND_NAME_FLOOR

	function self.Register(name: string, specOrHandler: any, handler: Handler?)
		if type(name) ~= "string" or name == "" then
			error("Scribe: command name must be a non-empty string", 2)
		end
		if registry[name] then
			error(`Scribe: command "{name}" is already registered`, 2)
		end
		local spec: { Args: { any }?, Idempotent: boolean? }? = nil
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
		-- Rejected at register time: a truthy-but-not-boolean value here would read as
		-- opted in on one line and opted out on the `== true` comparison below, and the
		-- difference only shows up as commands silently running twice.
		local idempotent = if spec then spec.Idempotent else nil
		if idempotent ~= nil and type(idempotent) ~= "boolean" then
			error(`Scribe: command "{name}" Idempotent must be a boolean`, 2)
		end
		local args = if spec then spec.Args else nil
		if args ~= nil then
			if type(args) ~= "table" then
				error(`Scribe: command "{name}" Args must be an array of type strings or shapes`, 2)
			end
			-- Reject a malformed spec at register time, not on the first client call: a
			-- spec that never matches turns every request into "bad-args", which reads
			-- as a client bug.
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
						-- Name the kind: without it the recursion below walks the marker's
						-- internals and reports something like "Args[1].Meta.Min", leaking
						-- Scribe's own structure into the caller's error.
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
		maxNameBytes = math.max(maxNameBytes, #name)
		registry[name] = {
			Handler = fn,
			Args = args,
			Idempotent = idempotent == true,
		}
	end

	local function encodeReply(correlation: number, ok: boolean, results: { any }): buffer
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.CommandReply)
		Wire.U32(w, correlation)
		Wire.U8(w, if ok then 1 else 0)
		-- results.n is the true count and survives an embedded nil that `#` stops short
		-- at; fall back to `#` for the plain-array callers, which have no holes.
		local n = math.min((results :: any).n or #results, MAX_RETURNS)
		Wire.U8(w, n)
		for i = 1, n do
			Wire.EncodeGeneric(w, results[i])
		end
		return Wire.Finish(w)
	end

	-- Send one reply frame. `replayed` marks a reply reconstructed from the idempotency
	-- cache and suppresses the truncation warning only: the handler ran once, and a
	-- client may repeat a key indefinitely, which would be an unthrottled path into the
	-- log ring.
	local function reply(entry: any, correlation: number, ok: boolean, results: { any }, replayed: boolean?)
		-- encodeReply clamps to MAX_RETURNS, and the caller just sees trailing nils, so
		-- say so. Only meaningful on success; failure replies are single-value.
		local resultCount = (results :: any).n or #results
		if ok and not replayed and resultCount > MAX_RETURNS then
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

	-- Idempotency cache --------------------------------------------------------
	--
	-- Per entry, in memory, deliberately not the persisted claim Data.Purchase takes
	-- through Timed.Claim: a command key is named by the client, so persisting it lets
	-- a player at the full CommandRateLimit push their own profile past the DataStore
	-- ceiling and fail every save. The cached reply has nowhere durable to go either,
	-- since a handler may return values the wire carries and a DataStore refuses.
	--
	-- Session scope is also the honest scope: a request's correlation id, parked thread
	-- and RequestTimeout are all session-lived, so the cache dies with the session.
	local function idemStore(entry: any): { [string]: IdemRecord }
		local store = entry.CommandIdem
		if not store then
			store = {}
			entry.CommandIdem = store
		end
		return store
	end

	-- Finish an in-flight record: answer every duplicate parked on it, and decide
	-- whether it survives to answer later retries.
	local function settleIdempotent(entry: any, record: IdemRecord?, ok: boolean, results: { any })
		if record == nil then
			return
		end
		local waiters = record.Waiters
		record.Waiters = {}
		record.Done = true
		record.Ok = ok
		-- Stored as is, still packed: `.n` is the true arity and the only thing that
		-- survives an embedded nil, so a replay is identical to the original reply.
		record.Results = results
		if not ok then
			-- Dropped before the parked duplicates are answered. A handler that threw
			-- did not happen, so the key stays retryable, and a reply can re-enter this
			-- path through a synchronous transport: a failed record left in place even
			-- for the length of these replies would answer that retry from the cache.
			local store = entry.CommandIdem
			if store then
				store[record.CacheKey] = nil
			end
		end
		for _, correlation in waiters do
			reply(entry, correlation, ok, results, true)
		end
	end

	local function takeToken(entry: any): boolean
		local now = Clock.Monotonic()
		local elapsed = now - entry.RateLast
		entry.RateLast = now
		entry.RateTokens = math.min(rateLimit, entry.RateTokens + elapsed * rateLimit)
		if entry.RateTokens >= 1 then
			entry.RateTokens -= 1
			return true
		end
		return false
	end

	-- Warn at most once per interval per player per code. These fire on client input
	-- that sits under the rate limit, so unthrottled an exploiter could drive them at
	-- the full allowance and evict the whole diagnostic ring.
	local function throttledWarn(entry: any, code: any, message: string, context: { [string]: any })
		local now = Clock.Monotonic()
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

	-- Does one argument match its spec? A spec is one of three things:
	--
	--   "string", "number?", "any"                  a type string
	--   Scribe.Int(0, { Min = 0, Max = 99 })        a declarator, with its constraints
	--   { Id = "string", Qty = "number?" }          a shape, nestable, mixable with both
	--
	-- Declarators are accepted so their constraints come along (Min/Max, MaxLength,
	-- Enum members, MaxItems/MaxKeys); a type string can only say a number arrived.
	-- All of it is opt-in: a bare "table" stays as permissive as `typeof`.
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
		-- A shape is always required: a command that wants an optional table declares
		-- "table?" and validates the contents itself.
		if type(value) ~= "table" or depth > MAX_SHAPE_DEPTH then
			return false
		end
		local elementSpec = expected[1]
		if elementSpec ~= nil then
			-- Array form: every element matches and no extra keys hide alongside them.
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
		-- Reject unknown keys: passing an undeclared field through is how an
		-- unvalidated value reaches game logic.
		for key in value do
			if expected[key] == nil then
				return false
			end
		end
		return true
	end

	-- Declarator constraints, checked against a value that arrived over the wire.
	-- A rejection, never a clamp: a command argument is the client's claim about what
	-- it wants, and clamping it to something legal turns "buy 999999" into "buy 99".
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
		-- Bounded from the length prefix, so an over-long name costs the varint rather
		-- than the allocation. A name longer than every registered command could not
		-- have matched one anyway.
		local name = Wire.RStrBounded(reader, maxNameBytes)
		local argc = Wire.RU8(reader)
		if argc > MAX_ARGS then
			error("too many command arguments")
		end

		Metrics.Add("CommandsReceived")

		-- The token check has to stay above the argument decode. Arguments are
		-- attacker-sized and the decode is where the CPU goes, so decoding first
		-- protects the handlers but not the decoder, and these frames are valid so the
		-- malformed-frame budget never catches them. The header read above is
		-- fixed-cost and all the rejection reply needs.
		if not takeToken(entry) then
			Metrics.Add("CommandsRateLimited")
			local now = Clock.Monotonic()
			-- Decay first, so a player who stopped flooding starts fresh and a rare
			-- legitimate burst never creeps toward the cutoff.
			if now - (entry.LastRateLimitAt or -math.huge) > RATE_RESET_WINDOW then
				entry.RateLimitedCount = 0
			end
			entry.LastRateLimitAt = now
			entry.RateLimitedCount = (entry.RateLimitedCount or 0) + 1
			-- Throttle the log: unthrottled this is the one command path an exploiter
			-- can drive without bound, and it would evict the whole log ring.
			if now - (entry.LastRateLimitLog or -math.huge) >= RATE_LOG_INTERVAL then
				entry.LastRateLimitLog = now
				Log.Warn("Commands", "COMMAND_RATE_LIMITED", `player exceeded {rateLimit}/s`, {
					Player = entry.Player,
					Count = entry.RateLimitedCount,
				})
			end
			-- Keep replying up to the cutoff so a client that briefly overruns is not
			-- stranded until its request timeout; past it each reply is only cost.
			if entry.RateLimitedCount < RATE_LIMIT_MAX then
				reply(entry, correlation, false, { "rate-limited" })
			end
			return
		end

		-- Above the registry lookup, so a session that is not Ready answers "not-ready"
		-- for every name. Below it, an unauthenticated client could enumerate the whole
		-- command surface by diffing "unknown-command" against "not-ready". Nothing
		-- real is lost: Client.Request waits for Init, so a genuine Scribe client
		-- cannot send a command in this window at all.
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

		-- The arity check needs only the header, so it runs before the decode and
		-- rejects an over-long call without paying for it.
		if registered.Args and argc > #registered.Args then
			Metrics.Add("CommandsRejected")
			reply(entry, correlation, false, { "bad-args" })
			return
		end

		-- The idempotency key sits between the header and the arguments so an unusable
		-- one is settled before anything attacker-sized is decoded. Empty means the
		-- caller sent none, so Request and RequestOnce share one frame layout.
		local idemKey = Wire.RStr(reader)
		local hasKey = idemKey ~= ""
		-- Refused rather than downgraded in both directions: a key sent to a command
		-- that does not honour it would promise protection that does not exist, and a
		-- keyless call to one that does is the same mistake from the other side.
		--
		-- The length is checked here rather than at the read, which MaxInboundBytes
		-- already bounds; this cap is about what may become a retained table key.
		if
			hasKey ~= registered.Idempotent
			or (hasKey and (#idemKey > MAX_IDEMPOTENCY_KEY_BYTES or utf8.len(idemKey) == nil))
		then
			Metrics.Add("CommandsRejected")
			throttledWarn(
				entry,
				"COMMAND_BAD_IDEMPOTENCY_KEY",
				if registered.Idempotent
					then `"{name}" requires an idempotency key (call it with Client.RequestOnce)`
					else `"{name}" is not registered Idempotent, so it does not accept an idempotency key`,
				{ Player = entry.Player }
			)
			reply(entry, correlation, false, { "bad-idempotency-key" })
			return
		end

		-- Decode last: every rejection above is answered from the fixed-cost header
		-- alone, so only a frame that cleared all of them costs a decode.
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

		-- Idempotency is claimed before the handler runs, not after. A handler may
		-- yield, so two identical requests can be in flight at once; a check after the
		-- call would dedupe a sequential retry while letting concurrent duplicates both
		-- execute. Parking the duplicate on the same record is what makes "at most
		-- once" true for both shapes.
		local record: IdemRecord? = nil
		if registered.Idempotent then
			local store = idemStore(entry)
			local now = Clock.Monotonic()
			-- Namespaced by command: two commands sharing a key are two operations, so
			-- replaying one's reply for the other would be a wrong answer. \0 is the
			-- cheapest unambiguous separator and cannot occur in a registered name.
			local cacheKey = `{name}\0{idemKey}`
			local existing = store[cacheKey]
			if existing ~= nil and existing.Done and now - existing.At > idempotencyTTL then
				store[cacheKey] = nil
				existing = nil
			end
			if existing ~= nil then
				if existing.Done then
					Metrics.Add("CommandsDeduped")
					reply(entry, correlation, existing.Ok, existing.Results :: { any }, true)
				elseif #existing.Waiters < MAX_IDEMPOTENT_WAITERS then
					-- Still running, so park this correlation on it: the first call's
					-- outcome answers every duplicate. Nothing is replied here;
					-- settleIdempotent does it when the handler returns.
					Metrics.Add("CommandsDeduped")
					table.insert(existing.Waiters, correlation)
				else
					Metrics.Add("CommandsRejected")
					reply(entry, correlation, false, { "rate-limited" })
				end
				return
			end

			-- Sweep the settled-and-expired and measure what is left, in one pass.
			-- In-flight records are never swept or evicted: dropping one would strand
			-- the duplicates parked on it with no reply at all.
			local live = 0
			local oldestKey: string? = nil
			local oldestAt = math.huge
			for key, held in store do
				if held.Done and now - held.At > idempotencyTTL then
					store[key] = nil
				else
					live += 1
					if held.Done and held.At < oldestAt then
						oldestAt, oldestKey = held.At, key
					end
				end
			end
			if live >= MAX_IDEMPOTENT_RECORDS then
				if oldestKey == nil then
					-- Every record is in flight, so there is nothing safe to drop. It
					-- takes a client deliberately holding that many handlers open, and it
					-- already knows how to back off from "rate-limited".
					Metrics.Add("CommandsRejected")
					throttledWarn(
						entry,
						"COMMAND_IDEM_SATURATED",
						`{MAX_IDEMPOTENT_RECORDS} idempotent commands are in flight for this player; refusing more`,
						{ Player = entry.Player }
					)
					reply(entry, correlation, false, { "rate-limited" })
					return
				end
				-- Evicting an unexpired record means a retry under that key runs the
				-- handler a second time, the one thing this cache exists to prevent, so
				-- it is said out loud.
				store[oldestKey] = nil
				Metrics.Add("CommandIdemEvicted")
				throttledWarn(
					entry,
					"COMMAND_IDEM_EVICTED",
					`dropped an unexpired idempotency record to stay under {MAX_IDEMPOTENT_RECORDS} per player; `
						.. "a retry under that key would run the handler again",
					{ Player = entry.Player }
				)
			end

			record = { CacheKey = cacheKey, At = now, Done = false, Ok = false, Results = nil, Waiters = {} }
			store[cacheKey] = record
		end

		local results: { any } = {}
		local ok, err = xpcall(function()
			results = table.pack(registered.Handler(entry.Player, table.unpack(args, 1, argc))) :: any
		end, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		if not ok then
			Metrics.Add("CommandErrors")
			-- Throttled: a handler that throws on a given input is a bug the player can
			-- replay at their full command rate, and each entry costs a JSONEncode, a
			-- console write and a Sched.Spawn per sink. The suppressed count carries the
			-- rest, and the metric above is unthrottled.
			local nowMono = Clock.Monotonic()
			commandErrorsSinceLog += 1
			if lastCommandErrorLog == nil or nowMono - lastCommandErrorLog >= COMMAND_ERROR_LOG_INTERVAL then
				local suppressed = commandErrorsSinceLog - 1
				lastCommandErrorLog = nowMono
				commandErrorsSinceLog = 0
				Log.Error("Commands", "COMMAND_ERROR", `command "{name}" handler threw: {err}`, {
					Player = entry.Player,
					Suppressed = if suppressed > 0 then suppressed else nil,
				})
			end
			local failure = { "error" }
			reply(entry, correlation, false, failure)
			settleIdempotent(entry, record, false, failure)
			return
		end
		Metrics.Add("CommandsHandled")
		reply(entry, correlation, true, results)
		settleIdempotent(entry, record, true, results)
	end

	return self
end

return Commands
