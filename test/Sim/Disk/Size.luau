--!nonstrict
-- Two ways to measure a value's size, which deliberately disagree.
--
-- `Serialized` is what the real DataStore enforces: the byte length of the JSON
-- encoding, against a 4 MB ceiling. It is computed WITHOUT building the string,
-- because a high-CCU run serializes on every save and materialising megabytes per
-- write would dominate the simulation.
--
-- `Approx` mirrors Scribe's own Util.approxSize -- flat 10 bytes per number,
-- #s + 2 per string, +2 per entry -- which is a cheap estimate it uses to decide
-- when to warn a profile is getting large.
--
-- The gap between them is not an inconvenience to be papered over; it is a thing
-- worth modelling. Scribe's PROFILE_TOO_LARGE handling is a HEURISTIC bridging
-- exactly this gap: an oversize save fails with an undifferentiated DataStore
-- error, and Scribe guesses at the cause by comparing its own approximation to a
-- warn threshold. If both measures agreed, that guess would always be right and
-- the code path would never be exercised as it is in production.

local Size = {}

-- 4 MB, the documented per-key serialized limit.
Size.VALUE_BYTES = 4194304

-- JSON overhead constants, named so the arithmetic below reads as intent.
local QUOTES = 2 -- "..."
local BRACES = 2 -- {...} or [...]
local COLON = 1
local COMMA = 1
local NULL_BYTES = 4 -- null
local TRUE_BYTES = 4 -- true
local FALSE_BYTES = 5 -- false

--- Bytes a JSON string literal costs, including quotes and escaping.
local function stringBytes(text: string): number
	local total = #text + QUOTES
	-- Escaped characters cost one extra byte each. Control characters below 0x20
	-- cost more (\u00XX), but Scribe never stores them and counting them exactly
	-- would mean a second pass for no behavioural difference.
	for _ in string.gmatch(text, '["\\\n\r\t]') do
		total += 1
	end
	return total
end

--- Bytes a JSON number costs. Formatted the way an encoder would, because 1e300
--- and 1.5 are wildly different lengths and a flat constant would make the cap
--- unreachable for one and trivially reachable for the other.
local function numberBytes(value: number): number
	if value ~= value or value == math.huge or value == -math.huge then
		-- Not representable in JSON. Real encoders reject the whole value; the
		-- caller validates for this separately, so charge `null` and move on.
		return NULL_BYTES
	end
	if value % 1 == 0 and math.abs(value) < 1e15 then
		return #string.format("%d", value)
	end
	return #string.format("%.14g", value)
end

local measure

--- Byte length of `value`'s JSON encoding, without building it.
function Size.Serialized(value: any): number
	return measure(value, 0)
end

function measure(value: any, depth: number): number
	if depth > 64 then
		-- Cyclic or absurdly deep. Real encoders throw; the caller's validation
		-- catches that case, so stop counting rather than recurse forever.
		return 0
	end

	local kind = type(value)
	if kind == "nil" then
		return NULL_BYTES
	elseif kind == "boolean" then
		return if value then TRUE_BYTES else FALSE_BYTES
	elseif kind == "number" then
		return numberBytes(value)
	elseif kind == "string" then
		return stringBytes(value)
	elseif kind ~= "table" then
		-- buffers and datatypes: not JSON-encodable. Validation rejects them.
		return 0
	end

	local arrayLength = #value
	local total = BRACES
	local entries = 0

	if arrayLength > 0 then
		for index = 1, arrayLength do
			total += measure(value[index], depth + 1)
			entries += 1
		end
	end

	for key, item in value do
		-- Array part already counted above.
		if not (type(key) == "number" and key % 1 == 0 and key >= 1 and key <= arrayLength) then
			total += (if type(key) == "string" then stringBytes(key) else numberBytes(key) + QUOTES) + COLON
			total += measure(item, depth + 1)
			entries += 1
		end
	end

	if entries > 1 then
		total += (entries - 1) * COMMA
	end
	return total
end

--- Scribe's own cheap estimate, mirroring Util.approxSize.
---
--- Kept as a separate implementation on purpose rather than calling Scribe's:
--- the point is to have an INDEPENDENT second opinion, and importing the one
--- under test would make the two agree by construction.
function Size.Approx(value: any, depth: number?): number
	local at = depth or 0
	if at > 64 then
		return 0
	end
	local kind = type(value)
	if kind == "number" then
		return 10
	elseif kind == "string" then
		return #value + 2
	elseif kind == "boolean" then
		return 1
	elseif kind == "buffer" then
		return buffer.len(value)
	elseif kind ~= "table" then
		return 0
	end
	local total = 0
	for key, item in value do
		total += 2
		if type(key) == "string" then
			total += #key + 2
		else
			total += 10
		end
		total += Size.Approx(item, at + 1)
	end
	return total
end

return Size
