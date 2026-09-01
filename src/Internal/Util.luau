--!strict
-- Small shared utilities.

local HttpService = game:GetService("HttpService")

-- Datatypes requires nothing, so this cannot cycle back into Util. Used only to
-- tell a raw-but-packable datatype apart from a genuinely unstorable value.
local Datatypes = require(script.Parent.Datatypes)

local Util = {}

-- Deepest nesting a written value may have, counted from the root. Enforced by
-- Node.validateWrite at write time and against ArrayOf/DictOf element shapes at compile
-- time, so an unsatisfiable template fails at startup rather than on every write.
Util.MAX_VALUE_DEPTH = 24

function Util.cloneBuffer(value: buffer): buffer
	local out = buffer.create(buffer.len(value))
	buffer.copy(out, 0, value)
	return out
end

-- True when `s` is valid UTF-8, the only strings (and JSON object keys) a DataStore
-- will persist. Anything else fails the whole profile save with DataStore error 104.
function Util.isUtf8(s: string): boolean
	return utf8.len(s) ~= nil
end

export type Unpersistable = {
	Path: { string | number }, -- ancestor keys are all valid UTF-8, so safe to log
	Kind: string, -- stable anomaly reason: "InvalidUtf8" or "Unserializable"
	Detail: string, -- human-readable message
}

-- Depth-first scan for the first value or key a DataStore cannot store: invalid UTF-8
-- (error 104) or an unserializable leaf. Used by the raw-table save boundaries that
-- bypass Node.validateWrite, where the alternative is the whole save failing opaquely.
-- A bad key is reported before recursing under it, so the offender's ancestors are all
-- valid. The path rides a scratch stack: `n` is the live count, passed by value, so a
-- frame only reads `stack[1..n]` and nothing is popped.
local function snapshotPath(stack: { string | number }, n: number, extra: (string | number)?): { string | number }
	local out: { string | number } = {}
	table.move(stack, 1, n, 1, out)
	if extra ~= nil then
		out[n + 1] = extra
	end
	return out
end

local function scanUnpersistable(
	value: any,
	stack: { string | number },
	n: number,
	d: number,
	stats: { MaxDepth: number }?
): Unpersistable?
	if stats and d > stats.MaxDepth then
		stats.MaxDepth = d
	end
	-- Checked first, and on typeof rather than type: a Roblox datatype is storable but not
	-- raw, and it is userdata on Roblox yet a plain table under the headless shim, so
	-- recursing into one reports a confusing key-type error instead of the real problem.
	-- Do not gate it on `type(value)` to skip the typeof call: a miss here is a false
	-- negative, and every future save then fails with no path in the log.
	local typeName = typeof(value)
	if Datatypes.IsSupported(typeName) then
		return {
			Path = snapshotPath(stack, n),
			Kind = "Unserializable",
			Detail = `a raw {typeName}, which only the accessor packs; write `
				.. `Scribe.Datatypes.Pack("{typeName}", value) here, or store a plain number instead`,
		}
	end
	local t = type(value)
	if t == "string" then
		if Util.isUtf8(value :: string) then
			return nil
		end
		return {
			Path = snapshotPath(stack, n),
			Kind = "InvalidUtf8",
			Detail = "string contains invalid UTF-8 bytes",
		}
	elseif t == "boolean" or t == "buffer" then
		return nil
	elseif t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return { Path = snapshotPath(stack, n), Kind = "Unserializable", Detail = "NaN/inf number" }
		end
		return nil
	elseif t == "table" then
		-- A cyclic table would recurse forever, and this scan runs unprotected inside the
		-- load path, so an overflow kills the player's load. Capped well past
		-- MAX_VALUE_DEPTH; nothing this deep is writable or wire-encodable anyway.
		if d > 64 then
			return {
				Path = snapshotPath(stack, n),
				Kind = "Unserializable",
				Detail = "nested deeper than 64 levels (or cyclic)",
			}
		end
		local hasNum, hasStr = false, false
		-- One pass, and the order is load-bearing: splitting this into a key pass and a
		-- value pass would report a different offender for the same data, and would leave
		-- stats.MaxDepth short, since the recursion is what deepens it.
		for k, v in value :: any do
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then
				return {
					Path = snapshotPath(stack, n, "<key>"),
					Kind = "Unserializable",
					Detail = `unsupported key type "{kt}"`,
				}
			end
			hasNum = hasNum or kt == "number"
			hasStr = hasStr or kt == "string"
			if hasNum and hasStr then
				-- JSON cannot encode a table mixing array indices and object keys;
				-- the whole profile save fails.
				return {
					Path = snapshotPath(stack, n),
					Kind = "Unserializable",
					Detail = "table mixes array indices and string keys",
				}
			end
			if kt == "string" and not Util.isUtf8(k :: string) then
				return {
					Path = snapshotPath(stack, n, "<invalid-key>"),
					Kind = "InvalidUtf8",
					Detail = "object key contains invalid UTF-8 bytes",
				}
			end
			stack[n + 1] = k
			local found = scanUnpersistable(v, stack, n + 1, d + 1, stats)
			if found ~= nil then
				return found
			end
		end
		return nil
	end
	-- userdata (Instance), function, thread, native vector, etc. A packable
	-- datatype never reaches here: it is caught by the typeof check at the top.
	return {
		Path = snapshotPath(stack, n),
		Kind = "Unserializable",
		Detail = `unsupported type "{typeName}"`,
	}
end

function Util.findUnpersistable(
	value: any,
	path: { string | number }?,
	depth: number?,
	stats: { MaxDepth: number }?
): Unpersistable?
	-- Cloned, not adopted: the caller still owns `path`, and the scratch stack would
	-- otherwise leave its bookkeeping behind in someone else's table.
	local stack: { string | number } = if path then table.clone(path) else {}
	return scanUnpersistable(value, stack, #stack, depth or 0, stats)
end

-- Deep copy of a plain data value. Buffers are mutable, so they are copied
-- too; other non-table values are returned as-is.
function Util.deepClone<T>(value: T): T
	local t = type(value)
	if t == "buffer" then
		return Util.cloneBuffer(value :: any) :: any
	elseif t ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		local vt = type(v)
		if vt == "table" then
			out[k] = Util.deepClone(v)
		elseif vt == "buffer" then
			out[k] = Util.cloneBuffer(v)
		else
			out[k] = v
		end
	end
	return out :: any
end

-- Recursively freeze a table (template safety).
function Util.deepFreeze<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	for _, v in value :: any do
		if type(v) == "table" and not table.isfrozen(v) then
			Util.deepFreeze(v)
		end
	end
	if not table.isfrozen(value :: any) then
		table.freeze(value :: any)
	end
	return value
end

-- Sorted list of string keys of a table. Deterministic traversal for schema derivation.
function Util.sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		if type(k) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	return keys
end

function Util.hasNumericKeys(t: { [any]: any }): boolean
	for k in t do
		if type(k) == "number" then
			return true
		end
	end
	return false
end

function Util.count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- What each byte costs beyond the raw one it already occupies, indexed by `byte + 1` so
-- every lookup lands in the array part.
--
-- Non-ASCII is free: the encoder emits raw UTF-8, not \uXXXX escapes. \b \t \n \f \r have
-- two-byte escapes and cost one extra; every other control character below 0x20 is
-- written as \u00XX, so five extra. A quote and a backslash cost one each.
local ESCAPE_COST: { number } = table.create(256, 0)
for b = 0, 31 do
	ESCAPE_COST[b + 1] = 5
end
for _, b in { 8, 9, 10, 12, 13 } do
	ESCAPE_COST[b + 1] = 1
end
ESCAPE_COST[35] = 1 -- byte 34, a double quote
ESCAPE_COST[93] = 1 -- byte 92, a backslash

-- Bytes JSON spends on a string literal, quotes included. No `string.find` fast path in
-- front of the byte walk: Luau's pattern matcher tests a character class per byte with no
-- vectorised path, and measured 2.6x slower than `string.byte` plus an array-part index.
local function jsonStringBytes(s: string): number
	local n = #s
	local total = n + 2
	for i = 1, n do
		total += ESCAPE_COST[string.byte(s, i) + 1]
	end
	return total
end

-- Digits in a non-negative integral double below 1e21.
local function decimalDigits(n: number): number
	if n < 10 then
		return 1
	elseif n < 100 then
		return 2
	elseif n < 1000 then
		return 3
	elseif n < 10000 then
		return 4
	elseif n < 100000 then
		return 5
	elseif n < 1000000 then
		return 6
	end
	-- Past a million the comparison ladder stops paying for itself. %.0f prints
	-- the double's exact integer value, so this stays exact rather than fitted.
	return #string.format("%.0f", n)
end

local function jsonNumberBytes(v: number): number
	if v ~= v or v == math.huge or v == -math.huge then
		-- Not encodable at all; findUnpersistable rejects these separately, so
		-- charge `null` and move on rather than inventing a size.
		return 4
	end
	-- The encoder writes integral values in full decimal all the way to 1e20 and only
	-- switches to exponent form at 1e21, so %.17g alone renders 1e20 as "1e+20" and
	-- under-counts it by sixteen bytes.
	if v % 1 == 0 and v > -1e21 and v < 1e21 then
		local digits = decimalDigits(if v < 0 then -v else v)
		return if v < 0 then digits + 1 else digits
	end
	return #string.format("%.17g", v)
end

-- Approximate serialized size in bytes, as an upper bound on what the DataStore would
-- store, which is the number the ~4 MB per-key ceiling is measured against. Buffer-aware
-- (DataStores store buffers as base64, 4/3 of their raw length rounded up to a 4-byte
-- group), so it works where JSONEncode would throw.
--
-- Upper bound rather than best guess: PROFILE_SIZE warns before saves start failing at the
-- ceiling, so an under-count is silent while an over-count only costs an early warning. It
-- never builds the string, and only array positions inside 1..#t are free: the encoder
-- writes {[123]="a"} as {"123":"a"} (hence Template.CoerceMapKeys), so a numeric key
-- outside the array part is charged like a string one.
function Util.approxSize(value: any, depth: number?): number
	local d = depth or 0
	local t = type(value)
	if t == "string" then
		return jsonStringBytes(value :: string)
	elseif t == "number" then
		return jsonNumberBytes(value :: number)
	elseif t == "boolean" then
		return if value then 4 else 5
	elseif t == "buffer" then
		return 4 * math.ceil(buffer.len(value :: buffer) / 3) + 2
	elseif t == "table" then
		-- This also measures live data from the raw-write boundaries, which can be cyclic,
		-- and it runs unprotected on the save path, so a cycle here would kill the save
		-- rather than fail it. Cap exactly where findUnpersistable does.
		if d > 64 then
			return 2
		end
		local arrayLength = #(value :: any)
		local total, entries = 2, 0 -- {} / []
		for k, v in value :: any do
			entries += 1
			if type(k) == "number" and k >= 1 and k <= arrayLength and k % 1 == 0 then
				total += Util.approxSize(v, d + 1)
			else
				-- The key dispatch tests the key type rather than asserting it. Casting a
				-- key to number here raises on a boolean or table key, and approxSize runs
				-- inside a save-path Signal handler that swallows the raise, so the
				-- PROFILE_SIZE warning silently stops firing. The 6 for an unencodable key
				-- measures nothing (findUnpersistable reports it); what matters is that the
				-- walk continues past it.
				local kt = type(k)
				local keyBytes = if kt == "string"
					then jsonStringBytes(k :: string)
					elseif kt == "number" then jsonNumberBytes(k :: number) + 2 -- quoted, as the encoder writes it
					else 6
				total += keyBytes + 1 + Util.approxSize(v, d + 1) -- + ':'
			end
		end
		if entries > 1 then
			total += entries - 1 -- separating commas, not one per entry
		end
		return total
	end
	return 4
end

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Base64 for JSON exports of buffer fields.
function Util.base64FromBuffer(value: buffer): string
	local length = buffer.len(value)
	local out = table.create(math.ceil(length / 3))
	local index = 0
	while index < length do
		local a = buffer.readu8(value, index)
		local b = if index + 1 < length then buffer.readu8(value, index + 1) else 0
		local c = if index + 2 < length then buffer.readu8(value, index + 2) else 0
		local n = a * 65536 + b * 256 + c
		local chunk = {
			string.sub(BASE64, math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1),
			string.sub(BASE64, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1),
			if index + 1 < length
				then string.sub(BASE64, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
				else "=",
			if index + 2 < length then string.sub(BASE64, n % 64 + 1, n % 64 + 1) else "=",
		}
		table.insert(out, table.concat(chunk))
		index += 3
	end
	return table.concat(out)
end

function Util.guid(): string
	return HttpService:GenerateGUID(false)
end

-- Byte equality for two buffers, for the array search accessors. Buffers compare by
-- identity under `==`, so a packed datatype in the store never equals a freshly packed
-- needle even when they hold the same value.
function Util.bufferEquals(a: buffer, b: buffer): boolean
	local len = buffer.len(a)
	if len ~= buffer.len(b) then
		return false
	end
	local i = 0
	while i + 4 <= len do
		if buffer.readu32(a, i) ~= buffer.readu32(b, i) then
			return false
		end
		i += 4
	end
	while i < len do
		if buffer.readu8(a, i) ~= buffer.readu8(b, i) then
			return false
		end
		i += 1
	end
	return true
end

-- Shallow equality for "did this leaf change" checks. Tables and buffers always count as
-- changes: both are mutable, so a re-Set of the same reference may carry in-place edits
-- that must replicate.
function Util.leafEquals(a: any, b: any): boolean
	local t = type(a)
	return a == b and t ~= "table" and t ~= "buffer"
end

-- table.concat that tolerates numeric segments.
function Util.pathKey(path: { string | number }): string
	if #path == 0 then
		return ""
	end
	local parts = table.create(#path)
	for i, seg in path do
		parts[i] = tostring(seg)
	end
	return table.concat(parts, "\31")
end

function Util.pathString(path: { string | number }): string
	local parts = table.create(#path)
	for i, seg in path do
		parts[i] = tostring(seg)
	end
	return table.concat(parts, ".")
end

-- Split a dotted path string ("Attributes.Money") into segments.
function Util.parsePath(s: string): { string }
	local out = {}
	for seg in string.gmatch(s, "[^%.]+") do
		table.insert(out, seg)
	end
	return out
end

-- Call `fn` through xpcall with a logged traceback; never throws. Returns ok plus
-- whatever `fn` returned.
function Util.safeCall(onError: (err: string) -> (), fn: (...any) -> ...any, ...: any): (boolean, ...any)
	local args = table.pack(...)
	local results: any
	local traceback: string?
	local ok = xpcall(function()
		results = table.pack(fn(table.unpack(args, 1, args.n)))
	end, function(e)
		traceback = debug.traceback(tostring(e), 2)
	end)
	if not ok then
		onError(tostring(traceback))
		return false
	end
	return true, table.unpack(results, 1, results.n)
end

-- FNV-1a 32-bit hash over a string; used for the schema handshake checksum.
function Util.fnv32(s: string, seed: number?): number
	local hash = seed or 2166136261
	for i = 1, #s do
		hash = bit32.bxor(hash, string.byte(s, i))
		hash = bit32.band(hash * 16777619, 0xFFFFFFFF)
	end
	return hash
end

-- Sanitize a context table for logging: Instances become names, Players become
-- {UserId, Name}, depth-limited, JSON-safe.
function Util.sanitizeContext(context: any, depth: number?): any
	local d = depth or 0
	if d > 4 then
		return "<deep>"
	end
	local t = typeof(context)
	if t == "Instance" then
		if context:IsA("Player") then
			return { UserId = context.UserId, Name = context.Name }
		end
		return context:GetFullName()
	elseif t == "table" then
		local out = {}
		for k, v in context do
			out[tostring(k)] = Util.sanitizeContext(v, d + 1)
		end
		return out
	elseif t == "string" or t == "number" or t == "boolean" or t == "nil" then
		return context
	end
	return tostring(context)
end

--- The first missing index in what is meant to be a dense array, or nil. `#` cannot
--- answer this alone: it counts past a constructor hole (`{ "a", nil, "b" }` is 3) and
--- stops short of an assigned one (t[1], t[3] is 1), and iteration skips either. Named
--- keys are not gaps.
function Util.firstGap(list: { any }): number?
	local count, highest = 0, 0
	for key in list do
		count += 1
		if type(key) == "number" and key > highest then
			highest = key
		end
	end
	if count == highest then
		return nil
	end
	for i = 1, highest do
		if list[i] == nil then
			return i
		end
	end
	return nil
end

return Util
