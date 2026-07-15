--!strict
-- Small shared utilities.

local HttpService = game:GetService("HttpService")

local Util = {}

function Util.cloneBuffer(value: buffer): buffer
	local out = buffer.create(buffer.len(value))
	buffer.copy(out, 0, value)
	return out
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
			if index + 1 < length then string.sub(BASE64, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) else "=",
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
