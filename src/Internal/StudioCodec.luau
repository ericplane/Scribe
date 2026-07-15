--!strict
-- Studio debug-hook codec: self-describing text encoding for arbitrary Luau
-- data tables crossing the plugin<->game VM boundary. Length-prefixed (no
-- escaping); handles string/number/boolean/nil/buffer values and
-- string/number keys, including mixed and sparse tables that neither JSON nor
-- cross-VM reflection can carry.
--
-- Shared by the server hook (Server/DebugHook.luau) and the client hook
-- (Client/DebugHook.luau). Byte-compatible with the Scribe Studio plugin's
-- copy (src/Codec.luau) and versioned by the hooks' PROTOCOL_VERSIONs —
-- change them together.

local StudioCodec = {}

local function encodeNumber(n: number): string
	if n ~= n then
		return "N!"
	elseif n == math.huge then
		return "N+"
	elseif n == -math.huge then
		-- "~" — a "-" sentinel would collide with negative number literals.
		return "N~"
	elseif n % 1 == 0 and math.abs(n) < 2 ^ 53 then
		return `I{n};`
	end
	return `N{string.format("%.17g", n)};`
end

local function encodeValue(out: { string }, value: any, depth: number)
	if depth > 32 then
		error("Scribe: value too deep to encode")
	end
	local t = type(value)
	if value == nil then
		table.insert(out, "z")
	elseif t == "boolean" then
		table.insert(out, if value then "T" else "F")
	elseif t == "number" then
		table.insert(out, encodeNumber(value))
	elseif t == "string" then
		table.insert(out, `S{#value}:`)
		table.insert(out, value)
	elseif t == "buffer" then
		local bytes = buffer.tostring(value)
		table.insert(out, `B{#bytes}:`)
		table.insert(out, bytes)
	elseif t == "table" then
		local count = 0
		for _ in value do
			count += 1
		end
		table.insert(out, `t{count}:`)
		for k, v in value do
			local kt = type(k)
			if kt == "string" then
				table.insert(out, `S{#k}:`)
				table.insert(out, k)
			elseif kt == "number" then
				table.insert(out, encodeNumber(k))
			else
				table.insert(out, "S9:<badkey?>")
			end
			encodeValue(out, v, depth + 1)
		end
	else
		local s = tostring(value)
		table.insert(out, `S{#s}:`)
		table.insert(out, s)
	end
end

function StudioCodec.Encode(value: any): string
	local out: { string } = {}
	encodeValue(out, value, 0)
	return table.concat(out)
end

type Cursor = { s: string, pos: number }

local function decodeValue(cur: Cursor, depth: number): any
	if depth > 34 then
		error("Scribe: encoded value too deep")
	end
	local s = cur.s
	local tag = string.sub(s, cur.pos, cur.pos)
	cur.pos += 1
	if tag == "z" then
		return nil
	elseif tag == "T" then
		return true
	elseif tag == "F" then
		return false
	elseif tag == "N" or tag == "I" then
		local head = string.sub(s, cur.pos, cur.pos)
		if tag == "N" and head == "!" then
			cur.pos += 1
			return 0 / 0
		elseif tag == "N" and head == "+" then
			cur.pos += 1
			return math.huge
		elseif tag == "N" and head == "~" then
			cur.pos += 1
			return -math.huge
		end
		local stop = string.find(s, ";", cur.pos, true)
		if not stop then
			error("Scribe: malformed number")
		end
		local n = tonumber(string.sub(s, cur.pos, stop - 1))
		if n == nil then
			error("Scribe: malformed number")
		end
		cur.pos = stop + 1
		return n
	elseif tag == "S" or tag == "B" then
		local stop = string.find(s, ":", cur.pos, true)
		if not stop then
			error("Scribe: malformed string")
		end
		local len = tonumber(string.sub(s, cur.pos, stop - 1))
		if len == nil or len < 0 then
			error("Scribe: malformed string length")
		end
		local value = string.sub(s, stop + 1, stop + len)
		cur.pos = stop + 1 + len
		if tag == "B" then
			return buffer.fromstring(value)
		end
		return value
	elseif tag == "t" then
		local stop = string.find(s, ":", cur.pos, true)
		if not stop then
			error("Scribe: malformed table")
		end
		local count = tonumber(string.sub(s, cur.pos, stop - 1))
		if count == nil then
			error("Scribe: malformed table count")
		end
		cur.pos = stop + 1
		local out = {}
		for _ = 1, count do
			local key = decodeValue(cur, depth + 1)
			local value = decodeValue(cur, depth + 1)
			if key ~= nil then
				out[key] = value
			end
		end
		return out
	end
	error(`Scribe: unknown codec tag "{tag}"`)
end

function StudioCodec.Decode(encoded: string): any
	return decodeValue({ s = encoded, pos = 1 }, 0)
end

return StudioCodec
