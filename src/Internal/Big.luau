--!strict
-- Mantissa/exponent numbers for values past 2^53, where Luau doubles stop being
-- exact and, past ~1.8e308, stop existing at all.
--
-- This trades PRECISION for RANGE on purpose. A value carries exactly 15
-- significant digits regardless of magnitude, so `1e20 + 1 == 1e20`. That is the
-- right trade for the case it exists to serve, an idle or simulator currency,
-- where the magnitude is the whole point and nobody can observe the ones digit of
-- 1e20. Anything that must be exact belongs in Scribe.Int.
--
-- Exactly 15, not roughly: normalize snaps the mantissa there, because scaling by a
-- power of ten is inexact and the canonical form has to be reproducible. Without the
-- snap, 100 - 30 and the literal 70 store different mantissas.
--
-- Stored form is the two-element array { mantissa, exponent }, which is compact and
-- survives a DataStore JSON round trip unchanged. Normalized so that a value is
-- either exactly { 0, 0 } or has 1 <= |mantissa| < 10, which makes comparison a
-- matter of looking at the exponent first and keeps one value per number.

local Big = {}

export type Big = {
	M: number, -- mantissa, 0 or 1 <= |M| < 10
	E: number, -- exponent, an integer
}

-- Doubles hold ~15-17 significant digits, so once two values are this far apart in
-- magnitude the smaller one cannot affect the sum at all. Adding it anyway would
-- burn cycles to change nothing.
local PRECISION_GAP = 18
-- Exponent ceiling, matching the wire's own limit rather than the double's. The
-- exponent rides a ZIGZAG varint, which doubles its input, and the varint writer
-- stops at 2^53 because that is the last exact integer a reader can recover. So the
-- exponent caps at 2^52, the same bound canSchemaEncode puts on a plain int for the
-- same reason. A value out here is unusable anyway (a leaderboard caps at 1e9006),
-- so saturating beats storing an infinity that fails the whole profile save.
local MAX_EXPONENT = 2 ^ 52

local SUFFIXES = {
	"",
	"K",
	"M",
	"B",
	"T",
	"Qa",
	"Qi",
	"Sx",
	"Sp",
	"Oc",
	"No",
	"Dc",
	"UDc",
	"DDc",
	"TDc",
	"QaDc",
	"QiDc",
	"SxDc",
	"SpDc",
	"OcDc",
	"NoDc",
	"Vg",
	"UVg",
	"DVg",
	"TVg",
	"QaVg",
	"QiVg",
	"SxVg",
	"SpVg",
	"OcVg",
	"NoVg",
	"Tg",
}

local BIG_MT = {}
BIG_MT.__index = BIG_MT

local function raw(m: number, e: number): Big
	return (setmetatable({ M = m, E = e }, BIG_MT) :: any) :: Big
end

-- Pull a value back into the canonical 1 <= |M| < 10 window. Uses log10 rather than
-- a divide loop so a mantissa arriving as 1e300 (from a multiply) costs the same as
-- one arriving as 12.
local function normalize(m: number, e: number): Big
	if m == 0 or m ~= m then
		return raw(0, 0)
	end
	if m == math.huge or m == -math.huge then
		-- Only reachable from a caller handing us an infinite double; treat it as the
		-- largest representable rather than propagating inf into stored data, which
		-- would not survive the JSON round trip.
		return raw(if m > 0 then 1 else -1, 308)
	end
	local shift = math.floor(math.log10(math.abs(m)))
	if shift ~= 0 then
		if shift < -323 then
			-- 10^shift is exactly 0 at shift <= -324 (a subnormal input) and nonzero
			-- at -323, and m/0 is inf, which would put an infinity into stored data
			-- that no JSON round trip survives. Scale in two steps so the divisor
			-- stays representable. ONLY here, and not one exponent wider: 10^n is
			-- inexact for most n, so splitting compounds two roundings and drifts the
			-- mantissa off canonical form (1e60 came back as {9.999999999999998, 59}).
			m = m * 1e300 / 10 ^ (shift + 300)
		else
			m /= 10 ^ shift
		end
		e += shift
	end
	-- Snap to the module's own precision. Scaling by a power of ten is exact for
	-- almost none of them, so 100 - 30 landed on 6.9999999999999991 where the literal
	-- 70 is 7: two stored forms for one value, agreeing to sixteen significant
	-- digits. Everything built on the canonical form then splits on it, because they
	-- all compare the mantissa exactly: compare/__eq, the structural entry search
	-- behind Has/Find/RemoveValue, toShort's whole-number test, and the leaderboard
	-- packing. Must run BEFORE the window fixup below, which is what catches the
	-- 9.9999999999999998 -> 10 promotion this can produce and rewrites it as 1e+1.
	m = tonumber(string.format("%.15g", m)) :: number
	-- log10 rounding can leave the mantissa a hair outside the window.
	if math.abs(m) >= 10 then
		m /= 10
		e += 1
	elseif math.abs(m) < 1 then
		m *= 10
		e -= 1
	end
	-- The EXPONENT needs the same domain guard the mantissa gets above. Without it a
	-- long chain of multiplies (exponents add) or a hand-built { m, math.huge } pair
	-- put a non-finite exponent into stored data, which a real DataStore refuses, so
	-- every save for that session failed and the end-of-session retry loop never let
	-- the profile go. The wire encoder was worse: zigzag doubles the exponent, and a
	-- varint loop over inf never terminates.
	if e ~= e then
		return raw(0, 0)
	end
	return raw(m, math.clamp(math.floor(e), -MAX_EXPONENT, MAX_EXPONENT))
end

Big.normalize = normalize

-- Accepts a Big, the stored { m, e } array, a plain number, or a string like
-- "1.5e100" or "1500". Returns nil for anything else, so callers can produce their
-- own error with the path in it.
function Big.from(value: any): Big?
	local t = type(value)
	if t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		return normalize(value, 0)
	end
	if t == "table" then
		-- A hand-built pair is refused when either half is non-finite, mirroring the
		-- number branch above, so the caller gets the normal path-named write error
		-- rather than a silently saturated value.
		local function finite(n: number): boolean
			return n == n and n ~= math.huge and n ~= -math.huge
		end
		local asBig = value :: any
		if type(asBig.M) == "number" and type(asBig.E) == "number" then
			return if finite(asBig.M) and finite(asBig.E) then normalize(asBig.M, asBig.E) else nil
		end
		if type(asBig[1]) == "number" and type(asBig[2]) == "number" then
			return if finite(asBig[1]) and finite(asBig[2]) then normalize(asBig[1], asBig[2]) else nil
		end
		return nil
	end
	if t ~= "string" then
		return nil
	end
	local text = (value :: string):gsub("%s", "")
	-- A plain double is the common case and covers everything under ~1.8e308.
	-- A zero result only counts when the text really IS zero: tonumber underflows
	-- "1e-400" to 0 exactly as it overflows "1e400" to inf, and accepting that
	-- silently turned a real value into nothing. Both ends fall through to the
	-- manual split below, which a big represents either way.
	local plain = tonumber(text)
	if
		plain ~= nil
		and plain == plain
		and plain ~= math.huge
		and plain ~= -math.huge
		and (plain ~= 0 or string.match(text, "^[%+%-]?0*%.?0*$") ~= nil)
	then
		return normalize(plain, 0)
	end
	-- Past either end, split the exponent off by hand: tonumber("1e400") is inf and
	-- tonumber("1e-400") is 0.
	local mantissaText, exponentText = string.match(text, "^([%+%-]?[%d%.]+)[eE]([%+%-]?%d+)$")
	if mantissaText == nil then
		return nil
	end
	local m = tonumber(mantissaText)
	local e = tonumber(exponentText)
	if m == nil or e == nil or m ~= m or e % 1 ~= 0 then
		return nil
	end
	return normalize(m, e)
end

-- The persisted shape: a two-element array, not the metatable-carrying object.
function Big.toStored(a: Big): { number }
	return { a.M, a.E }
end

function Big.isBig(value: any): boolean
	return type(value) == "table" and getmetatable(value :: any) == BIG_MT
end

function Big.add(a: Big, b: Big): Big
	if a.M == 0 then
		return b
	end
	if b.M == 0 then
		return a
	end
	local high, low = a, b
	if b.E > a.E then
		high, low = b, a
	end
	local gap = high.E - low.E
	if gap > PRECISION_GAP then
		return high -- the smaller term cannot move a digit we can represent
	end
	return normalize(high.M + low.M / 10 ^ gap, high.E)
end

function Big.negate(a: Big): Big
	return raw(-a.M, a.E)
end

function Big.sub(a: Big, b: Big): Big
	return Big.add(a, Big.negate(b))
end

function Big.mul(a: Big, b: Big): Big
	if a.M == 0 or b.M == 0 then
		return raw(0, 0)
	end
	return normalize(a.M * b.M, a.E + b.E)
end

function Big.div(a: Big, b: Big): Big?
	if b.M == 0 then
		return nil -- the caller decides whether that is an error or a clamp
	end
	if a.M == 0 then
		return raw(0, 0)
	end
	return normalize(a.M / b.M, a.E - b.E)
end

-- -1, 0, or 1. Sign first, then magnitude, so a comparison never has to subtract.
function Big.compare(a: Big, b: Big): number
	if a.M == 0 and b.M == 0 then
		return 0
	end
	local aNeg = a.M < 0
	local bNeg = b.M < 0
	if aNeg ~= bNeg then
		return if aNeg then -1 else 1
	end
	if a.M == 0 then
		return if bNeg then 1 else -1
	end
	if b.M == 0 then
		return if aNeg then -1 else 1
	end
	local flip = if aNeg then -1 else 1
	if a.E ~= b.E then
		return if a.E > b.E then flip else -flip
	end
	if a.M == b.M then
		return 0
	end
	return if a.M > b.M then 1 else -1
end

-- Lossy on purpose: everything past the double range saturates to inf, which is
-- what a caller asking for a plain number has to accept.
function Big.toNumber(a: Big): number
	if a.M == 0 then
		return 0
	end
	return a.M * 10 ^ a.E
end

function Big.toString(a: Big): string
	if a.M == 0 then
		return "0"
	end
	-- Below the precision limit a plain decimal is exact and far more readable.
	if a.E < 15 and a.E >= 0 then
		return string.format("%.0f", Big.toNumber(a))
	end
	if a.E < 0 and a.E >= -307 then
		return tostring(Big.toNumber(a))
	end
	-- %.4f can round 9.99998 up to "10", which is outside the canonical window and
	-- reads as a different magnitude. Carry it into the exponent instead.
	local mantissa, exponent = string.format("%.4f", a.M), a.E
	if mantissa == "10.0000" or mantissa == "-10.0000" then
		mantissa = if a.M < 0 then "-1.0000" else "1.0000"
		exponent += 1
	end
	return `{(mantissa:gsub("%.?0+$", ""))}e{exponent}`
end

-- The display form an idle game actually shows: "1.72 Dtg". Falls back to
-- scientific once the suffix table runs out, rather than inventing names.
function Big.toShort(a: Big, decimals: number?): string
	if a.M == 0 then
		return "0"
	end
	local places = decimals or 2
	if a.E < 3 then
		-- Past the double's low end toNumber saturates to 0, which would render a
		-- real value as "0". Scientific is the honest form there, matching how the
		-- high end falls back once the suffix table runs out.
		if a.E < -307 then
			return Big.toString(a)
		end
		local n = Big.toNumber(a)
		return if n % 1 == 0 then string.format("%.0f", n) else string.format(`%.{places}f`, n)
	end
	local tier = math.floor(a.E / 3)
	local suffix = SUFFIXES[tier + 1]
	if suffix == nil then
		return Big.toString(a)
	end
	local scaled = a.M * 10 ^ (a.E - tier * 3)
	return string.format(`%.{places}f{suffix}`, scaled)
end

BIG_MT.__add = function(a, b)
	return Big.add(Big.from(a) :: Big, Big.from(b) :: Big)
end
BIG_MT.__sub = function(a, b)
	return Big.sub(Big.from(a) :: Big, Big.from(b) :: Big)
end
BIG_MT.__mul = function(a, b)
	return Big.mul(Big.from(a) :: Big, Big.from(b) :: Big)
end
BIG_MT.__div = function(a, b)
	return Big.div(Big.from(a) :: Big, Big.from(b) :: Big) :: Big
end
BIG_MT.__unm = function(a)
	return Big.negate(a)
end
BIG_MT.__eq = function(a, b)
	return Big.compare(a, b) == 0
end
BIG_MT.__lt = function(a, b)
	return Big.compare(Big.from(a) :: Big, Big.from(b) :: Big) < 0
end
BIG_MT.__le = function(a, b)
	return Big.compare(Big.from(a) :: Big, Big.from(b) :: Big) <= 0
end
BIG_MT.__tostring = function(a)
	return Big.toString(a)
end

function BIG_MT.Short(self: Big, decimals: number?): string
	return Big.toShort(self, decimals)
end
function BIG_MT.ToNumber(self: Big): number
	return Big.toNumber(self)
end

return Big
