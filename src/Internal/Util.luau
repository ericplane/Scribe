--!strict
-- Small shared utilities.

local HttpService = game:GetService("HttpService")

local Util = {}

-- Deepest nesting a written value may have, counted from the root. Enforced at
-- write time by Node.validateWrite and at compile time against an ArrayOf/DictOf
-- element shape, so a template that declares a tree no write could ever satisfy
-- fails at startup instead of on every write.
Util.MAX_VALUE_DEPTH = 24

function Util.cloneBuffer(value: buffer): buffer
	local out = buffer.create(buffer.len(value))
	buffer.copy(out, 0, value)
	return out
end

-- True when `s` is valid UTF-8 -- the only strings (and JSON object keys) a
-- DataStore will persist. `utf8.len` returns nil at the first malformed byte;
-- an empty string is valid (len 0). Any string that fails this cannot be
-- JSON-encoded and would fail the whole profile save with DataStore error 104.
function Util.isUtf8(s: string): boolean
	return utf8.len(s) ~= nil
end

export type Unpersistable = {
	Path: { string | number }, -- ancestor keys are all valid UTF-8, so safe to log
	Kind: string, -- stable anomaly reason: "InvalidUtf8" or "Unserializable"
	Detail: string, -- human-readable message
}

-- Depth-first scan for the first value or key in a persistable data structure
-- that a DataStore cannot store. The raw-table save boundaries that bypass
-- Node.validateWrite (OnPlayerInit, UpdateOffline, migrations, Dynamic seeds)
-- use this to catch data that would otherwise fail the ENTIRE profile save (or
-- replication) opaquely -- invalid UTF-8 (error 104), or an unserializable leaf
-- (userdata/Instance/function/thread/native vector, or a NaN/inf number).
--
-- Returns the first offender (its ancestor keys are all valid UTF-8, since a bad
-- key is reported before recursing under it, so `Path` never embeds bad bytes),
-- or nil when the whole structure is DataStore-safe. Buffers and finite
-- numbers/booleans/strings are DataStore-safe and pass.
function Util.findUnpersistable(value: any, path: { string | number }?, depth: number?): Unpersistable?
	local at = path or {}
	local d = depth or 0
	local t = type(value)
	if t == "string" then
		if Util.isUtf8(value :: string) then
			return nil
		end
		return { Path = at, Kind = "InvalidUtf8", Detail = "string contains invalid UTF-8 bytes" }
	elseif t == "boolean" or t == "buffer" then
		return nil
	elseif t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return { Path = at, Kind = "Unserializable", Detail = "NaN/inf number" }
		end
		return nil
	elseif t == "table" then
		-- A cyclic table (OnPlayerInit/migration data can carry one) would recurse
		-- forever; this scan runs UNPROTECTED inside the load path, so an overflow
		-- kills the player's load. Depth-cap well past MAX_VALUE_DEPTH: anything
		-- this deep cannot be written or wire-encoded either.
		if d > 64 then
			return { Path = at, Kind = "Unserializable", Detail = "nested deeper than 64 levels (or cyclic)" }
		end
		local hasNum, hasStr = false, false
		for k, v in value :: any do
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then
				local kp = table.clone(at)
				table.insert(kp, "<key>")
				return { Path = kp, Kind = "Unserializable", Detail = `unsupported key type "{kt}"` }
			end
			hasNum = hasNum or kt == "number"
			hasStr = hasStr or kt == "string"
			if hasNum and hasStr then
				-- JSON cannot encode a table mixing array indices and object keys;
				-- the whole profile save fails.
				return { Path = at, Kind = "Unserializable", Detail = "table mixes array indices and string keys" }
			end
			if kt == "string" and not Util.isUtf8(k :: string) then
				local kp = table.clone(at)
				table.insert(kp, "<invalid-key>")
				return { Path = kp, Kind = "InvalidUtf8", Detail = "object key contains invalid UTF-8 bytes" }
			end
			local childPath = table.clone(at)
			table.insert(childPath, k)
			local found = Util.findUnpersistable(v, childPath, d + 1)
			if found ~= nil then
				return found
			end
		end
		return nil
	end
	-- userdata (Instance, EnumItem), function, thread, native vector, etc.
	return { Path = at, Kind = "Unserializable", Detail = `unsupported type "{typeof(value)}"` }
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

-- Whether the table has any array-part (numeric key) entries.
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

-- Approximate serialized size in bytes. Buffer-aware (DataStores store
-- buffers as base64, ~4/3 of their raw length), so it works where JSONEncode
-- would throw. Used for the wipe guard and profile-size monitoring, where
-- only magnitudes and ratios matter.
function Util.approxSize(value: any): number
	local t = type(value)
	if t == "string" then
		return #value + 2
	elseif t == "number" then
		return 10
	elseif t == "boolean" then
		return 5
	elseif t == "buffer" then
		return math.ceil(buffer.len(value) * 4 / 3) + 2
	elseif t == "table" then
		local total = 2
		for k, v in value do
			total += Util.approxSize(k) + Util.approxSize(v) + 2
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

-- Shallow equality suitable for "did this leaf change" checks. Tables and
-- buffers always count as changes: both are mutable, so a re-Set of the same
-- reference may carry in-place edits that must replicate.
-- Byte equality for two buffers. Buffers compare by IDENTITY under `==`, so a
-- packed datatype sitting in the store never equals a freshly packed needle even
-- when they hold the same value. Used by the array search accessors.
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

-- Call `fn` through xpcall with a logged traceback; never throws.
-- Returns ok plus up to four results.
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

return Util
