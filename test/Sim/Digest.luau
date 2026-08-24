--!strict
-- A stable fingerprint of everything a simulation run observed.
--
-- This is what makes "deterministic" a checkable claim rather than an assertion:
-- run a seed twice, digest both, and demand they match. Without it a simulation
-- that quietly depended on a hash order or a real timer would look fine until a
-- failure appeared on one machine and not another.
--
-- Stability is the whole requirement, so the serialization is canonical:
--   * table keys are visited in SORTED order, never in `pairs` order, which Luau
--     does not promise is stable between runs;
--   * numbers are formatted with %.14g, so a value that differs only in the last
--     representable bit does not read as a different run;
--   * types are tagged, so 1 and "1" cannot collide.

local Digest = {}

local function typeRank(value: any): number
	local t = type(value)
	if t == "boolean" then
		return 1
	elseif t == "number" then
		return 2
	elseif t == "string" then
		return 3
	end
	return 4
end

-- Mixed-type keys are legal in Lua and must still order deterministically, so
-- rank by type first and only compare within a type.
local function keyLess(a: any, b: any): boolean
	local ra, rb = typeRank(a), typeRank(b)
	if ra ~= rb then
		return ra < rb
	end
	if ra == 2 or ra == 3 then
		return a < b
	end
	return tostring(a) < tostring(b)
end

local function write(out: { string }, value: any, depth: number)
	if depth > 32 then
		table.insert(out, "…") -- cyclic or absurdly deep; the cap keeps this total
		return
	end
	local t = type(value)
	if t == "table" then
		local keys = {}
		for key in value do
			table.insert(keys, key)
		end
		table.sort(keys, keyLess)
		table.insert(out, "{")
		for _, key in keys do
			table.insert(out, tostring(key))
			table.insert(out, "=")
			write(out, value[key], depth + 1)
			table.insert(out, ";")
		end
		table.insert(out, "}")
	elseif t == "number" then
		table.insert(out, string.format("n%.14g", value))
	elseif t == "string" then
		table.insert(out, "s" .. value)
	elseif t == "boolean" then
		table.insert(out, if value then "T" else "F")
	elseif t == "nil" then
		table.insert(out, "-")
	else
		-- A buffer or datatype: fingerprint what is stable about it, never its
		-- address, which differs every run and would defeat the whole check.
		if t == "buffer" then
			table.insert(out, "b" .. tostring(buffer.len(value)))
		else
			table.insert(out, "u" .. typeof(value))
		end
	end
end

--- Canonical string form of a value. Exposed because a mismatching digest is
--- useless on its own -- you want to diff the two renderings to find where.
function Digest.Render(value: any): string
	local out: { string } = {}
	write(out, value, 0)
	return table.concat(out)
end

--- 32-bit FNV-1a of the canonical form, as 8 hex digits.
function Digest.Of(value: any): string
	local text = Digest.Render(value)
	local hash = 2166136261
	for i = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, i))
		-- FNV prime 16777619, folded through bit32 so it stays in 32 bits.
		hash = bit32.band(hash * 16777619, 0xFFFFFFFF)
	end
	return string.format("%08x", hash)
end

return Digest
