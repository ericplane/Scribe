--!strict
-- Mantissa/exponent numbers for values past 2^53. Trades precision for range: a value
-- carries exactly 15 significant digits at any magnitude, so `1e20 + 1 == 1e20`, and
-- anything that must be exact belongs in Scribe.Int. Stored as the two-element array
-- { mantissa, exponent }, normalized to either { 0, 0 } or 1 <= |mantissa| < 10, so
-- there is one stored form per value.

local Big = {}

export type Big = {
	M: number, -- mantissa, 0 or 1 <= |M| < 10
	E: number, -- exponent, an integer
}

-- Past this magnitude gap the smaller term cannot affect the sum at all.
local PRECISION_GAP = 18
-- Exponent ceiling set by the wire, not the double: the exponent rides a zigzag
-- varint, which doubles it, and the varint writer stops at 2^53. Saturating here
-- beats storing an infinity that fails the whole profile save.
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

-- Pull a value back into the canonical 1 <= |M| < 10 window. log10 rather than a
-- divide loop, so a mantissa arriving as 1e300 costs the same as one arriving as 12.
local function normalize(m: number, e: number): Big
	if m == 0 or m ~= m then
		return raw(0, 0)
	end
	if m == math.huge or m == -math.huge then
		-- Saturate rather than let an infinity into stored data; no JSON round trip
		-- survives one.
		return raw(if m > 0 then 1 else -1, 308)
	end
	local shift = math.floor(math.log10(math.abs(m)))
	if shift ~= 0 then
		if shift < -323 then
			-- 10^shift is exactly 0 at shift <= -324, and m/0 is inf. Scale in two steps
			-- so the divisor stays representable, but only here: splitting compounds two
			-- roundings and drifts the mantissa off canonical form.
			m = m * 1e300 / 10 ^ (shift + 300)
		else
			m /= 10 ^ shift
		end
		e += shift
	end
	-- Snap to 15 digits, or 100 - 30 and the literal 70 store different mantissas and
	-- everything comparing mantissas exactly splits on it. Must run before the window
	-- fixup below, which catches the 9.99...8 -> 10 promotion this can produce.
	m = tonumber(string.format("%.15g", m)) :: number
	-- log10 rounding can leave the mantissa a hair outside the window.
	if math.abs(m) >= 10 then
		m /= 10
		e += 1
	elseif math.abs(m) < 1 then
		m *= 10
		e -= 1
	end
	-- The exponent needs the same domain guard the mantissa gets above: a non-finite
	-- exponent makes every save for the session fail, and the wire encoder's varint
	-- loop over inf never terminates.
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
		-- Refuse a non-finite half rather than saturating, so the caller gets the normal
		-- path-named write error.
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
	-- A zero result only counts when the text really is zero: tonumber underflows
	-- "1e-400" to 0 exactly as it overflows "1e400" to inf. Both ends fall through to
	-- the manual split below.
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
	-- Past either end, split the exponent off by hand.
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

-- The mantissa's 15 significant digits as text, with the decimal point's position
-- returned rather than applied, so the renders below move the point by counting
-- characters and never round a second time through a double. `%.14f` is exact because
-- normalize already snapped the mantissa to 15 digits. Returns the sign, the digits, and
-- how many of them belong left of the point: sign .. "0." .. digits .. "e" .. point.
local function significand(a: Big): (string, string, number)
	local body = string.format("%.14f", math.abs(a.M))
	local whole = string.match(body, "^%d+") :: string
	return (if a.M < 0 then "-" else ""), whole .. string.sub(body, #whole + 2), a.E + #whole
end

-- Under this exponent a plain decimal is more leading zeros than digits. Matches where
-- Luau's own tostring switches to exponent form, which the branch below delegates to.
local MIN_DECIMAL_EXPONENT = -6

-- Place the decimal point inside (or outside) a digit string, padding with the zeros
-- the point ran past. Returns the halves separately because only the fractional one
-- may have its trailing zeros trimmed.
local function split(digits: string, point: number): (string, string)
	if point <= 0 then
		return "0", string.rep("0", -point) .. digits
	elseif point >= #digits then
		return digits .. string.rep("0", point - #digits), ""
	end
	return string.sub(digits, 1, point), string.sub(digits, point + 1)
end

function Big.toString(a: Big): string
	if a.M == 0 then
		return "0"
	end
	-- Below the precision limit a plain decimal is exact and far more readable.
	if a.E < 15 and a.E >= MIN_DECIMAL_EXPONENT then
		local sign, digits, point = significand(a)
		local whole, fraction = split(digits, point)
		-- Only the fraction is trimmed: a whole number's trailing zeros are the value.
		fraction = (fraction:gsub("0+$", ""))
		return if fraction == "" then sign .. whole else `{sign}{whole}.{fraction}`
	end
	if a.E < 0 and a.E >= -307 then
		return tostring(Big.toNumber(a))
	end
	-- Four decimals, not the full 15 the branch above renders: out here the mantissa is
	-- usually a reconstruction (a leaderboard key unpacks at SigFigs = 12), so the extra
	-- digits would only show the packing's rounding error. %.4f can round 9.99998 up to
	-- "10", outside the canonical window, so carry that into the exponent.
	local mantissa, exponent = string.format("%.4f", a.M), a.E
	if mantissa == "10.0000" or mantissa == "-10.0000" then
		mantissa = if a.M < 0 then "-1.0000" else "1.0000"
		exponent += 1
	end
	return `{(mantissa:gsub("%.?0+$", ""))}e{exponent}`
end

--- Replace the suffix table `toShort` renders with.
---
--- Overridable because the conventions diverge past "T": plenty of idle games run
--- aa, ab, ac rather than Qa, Qi, Sx. Index 1 is the units tier and must be empty,
--- because it is what renders a plain number unchanged.
function Big.SetSuffixes(suffixes: { string }): ()
	if type(suffixes) ~= "table" or #suffixes == 0 then
		error("Scribe: suffixes must be a non-empty list of strings", 3)
	end
	for index, suffix in suffixes do
		if type(suffix) ~= "string" then
			error(`Scribe: suffix {index} must be a string, got {typeof(suffix)}`, 3)
		end
	end
	if suffixes[1] ~= "" then
		error('Scribe: the first suffix is the units tier and must be ""', 3)
	end
	SUFFIXES = table.clone(suffixes)
end

function Big.toShort(a: Big, decimals: number?): string
	if a.M == 0 then
		return "0"
	end
	local places = decimals or 2
	if a.E < 3 then
		-- Past the double's low end toNumber saturates to 0, which would render a real
		-- value as "0".
		if a.E < -307 then
			return Big.toString(a)
		end
		local n = Big.toNumber(a)
		if n % 1 == 0 then
			return string.format("%.0f", n)
		end
		local text = string.format(`%.{places}f`, n)
		-- A value smaller than the requested precision formats as a literal zero, so a
		-- real balance would render as "0.00". Test the rendered text rather than the
		-- exponent: that keeps 0.00999 rounding to "0.01" and overrides only a render
		-- with no digit left in it.
		if string.match(text, "[1-9]") == nil then
			return Big.toString(a)
		end
		return text
	end
	local tier = math.floor(a.E / 3)
	local suffix = SUFFIXES[tier + 1]
	if suffix == nil then
		return Big.toString(a)
	end
	local scaled = a.M * 10 ^ (a.E - tier * 3)
	return string.format(`%.{places}f{suffix}`, scaled)
end

-- Coerce an operand of an arithmetic metamethod, erroring at level 3 so the blame
-- lands on the line holding the operator rather than inside this module.
--
-- __lt/__le are not routed through this: Luau rejects a mixed pair before the
-- metamethod runs and requires both sides to carry this metatable, so their `Big.from`
-- cannot fail.
local function operand(value: any, verb: string): Big
	local coerced = Big.from(value)
	if coerced == nil then
		error(
			`Scribe: cannot {verb} a Scribe.Big by a {type(value)}; expected a number, numeric string, or Scribe.Big`,
			3
		)
	end
	return coerced
end

BIG_MT.__add = function(a, b)
	return Big.add(operand(a, "add to"), operand(b, "add to"))
end
BIG_MT.__sub = function(a, b)
	return Big.sub(operand(a, "subtract from"), operand(b, "subtract from"))
end
BIG_MT.__mul = function(a, b)
	return Big.mul(operand(a, "multiply"), operand(b, "multiply"))
end
BIG_MT.__div = function(a, b)
	-- `Big.div` returns nil on a zero divisor so its callers can choose what that means;
	-- the operator has nobody to hand that choice to, so it raises like Divide does.
	local result = Big.div(operand(a, "divide"), operand(b, "divide"))
	if result == nil then
		error("Scribe: divided a Scribe.Big by zero", 2)
	end
	return result
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

-- Integer exponentiation carries the mantissa in two doubles (Dekker) so the 15-digit snap
-- runs once, at the end. Squaring over Big.mul instead compounds one rounding per pass and
-- produces wrong leaderboard ranking keys well before n = 1000.
--
-- Both operands stay in [1, 10) throughout this schedule, so every product lands in
-- [1, 100) and the window fixup is at most one divide by ten; a general rescale loop would
-- be dead code for the only caller.
local SPLIT = 134217729 -- 2^27 + 1, the Dekker splitter for a 53-bit significand

-- The exact product of two doubles as an unevaluated sum (hi + lo).
local function twoProd(x: number, y: number): (number, number)
	local p = x * y
	local cx = SPLIT * x
	local hx = cx - (cx - x)
	local lx = x - hx
	local cy = SPLIT * y
	local hy = cy - (cy - y)
	local ly = y - hy
	return p, ((hx * hy - p) + hx * ly + lx * hy) + lx * ly
end

local function ddMul(ah: number, al: number, bh: number, bl: number): (number, number)
	local p, e = twoProd(ah, bh)
	e += ah * bl + al * bh
	local s = p + e
	local bb = s - p
	return s, (p - (s - bb)) + (e - bb)
end

-- Divide a double-double by ten. Ten is exact, so the only error is the final renormalize.
local function ddTenth(ah: number, al: number): (number, number)
	local q1 = ah / 10
	local p, e = twoProd(q1, 10)
	local q2 = ((ah - p) + (al - e)) / 10
	local s = q1 + q2
	local bb = s - q1
	return s, (q1 - (s - bb)) + (q2 - bb)
end

-- Past 2^53 an exponent is not an exact integer, so the squaring schedule cannot iterate it.
local MAX_POW_EXPONENT = 2 ^ 53

-- Non-negative integer exponents only, and the guard is not optional: the schedule cannot
-- detect a bad one and silently returns 9 for 3^2.5 and 1 for 3^-3. Returns nil rather than
-- raising, matching div, so the caller decides. 0^0 is 1.
function Big.pow(a: Big, n: number): Big?
	if type(n) ~= "number" or n % 1 ~= 0 or n < 0 or n > MAX_POW_EXPONENT then
		return nil
	end
	local rh, rl, re = 1, 0, 0
	local bh, bl, be = a.M, 0, a.E
	local k = n
	while k > 0 do
		if k % 2 == 1 then
			local h, l = ddMul(rh, rl, bh, bl)
			re += be
			if math.abs(h) >= 10 then
				h, l = ddTenth(h, l)
				re += 1
			end
			rh, rl = h, l
		end
		k = math.floor(k / 2)
		if k > 0 then
			local h, l = ddMul(bh, bl, bh, bl)
			be += be
			if math.abs(h) >= 10 then
				h, l = ddTenth(h, l)
				be += 1
			end
			bh, bl = h, l
		end
	end
	-- Only the high part: the double-double invariant is |lo| <= ulp(hi)/2, so rh + rl is rh.
	-- Exiting through normalize applies the 15-digit snap and the exponent clamp, so pow
	-- saturates exactly as mul does.
	return normalize(rh, re)
end

-- Base-10 logarithm; `a.E` is already the exact integer part and this adds the fraction.
-- Total and unguarded on purpose: 0 gives -inf and a negative value nan, matching the
-- same call on a plain number, so a fresh {0, 0} balance needs no nil check at the call
-- site. Precision decays as E grows: the integer part and the fraction share 53 bits.
function Big.log10(a: Big): number
	return a.E + math.log10(a.M)
end

--[=[
	@class BigValue

	The object a [Scribe.Big] field hands back from `Get`: a mantissa and an
	exponent, carrying about 15 significant digits at any magnitude. There is no
	public constructor, so you get one from a big field and write one back through
	that field.

	It supports `+`, `-`, `*`, `/`, unary `-` and `tostring`. Each binary operator
	takes a number, a numeric string like `"1.5e100"`, or another big value on
	either side, so `essence + 5` and `5 + essence` both work. Any other operand
	errors naming its type, and dividing by zero errors rather than handing back an
	infinity that no save would survive.

	!!! warning "Comparisons need a big on both sides"
	    Luau picks `<` and `<=` by metatable identity, so `Get() < 2000` throws. `==` is
	    consulted only when both sides are tables, so `Get() == 5` is silently `false`
	    rather than an error. Compare two big values directly, or convert with
	    [`ToNumber`](#tonumber) first.

	Methods are called with a colon, `essence:Short()`, so the signatures below drop
	the implicit `self`. The [Big Numbers](../big-numbers.md) guide covers the rest.
]=]

--[=[
	@method Pow
	@within BigValue
	@tag Methods
	@param n number
	@return BigValue
	Raises the value to the power `n` and returns a new big. `x:Pow(0)` is `1` for
	every `x`, zero included.

	```lua
	data.Essence.Set(data.Essence.Get():Pow(2))   -- square the balance
	```

	`n` must be a non-negative integer no larger than `2^53`. Anything else errors,
	so `Pow(2.5)`, `Pow(-3)` and `Pow(math.huge)` raise instead of returning a
	plausible wrong answer; for a negative power, divide by the positive one. A
	result past the exponent ceiling saturates, exactly as `*` does.

	Prefer it to a chain of `Multiply` calls whenever the result has to rank. `Pow`
	rounds once at the end where a chain rounds at every step; the measured
	difference is in the [Big Numbers](../big-numbers.md) guide.
]=]
function BIG_MT.Pow(self: Big, n: number): Big
	local result = Big.pow(self, n)
	if result == nil then
		error(`Scribe: Pow needs a non-negative integer exponent no larger than 2^53, got {tostring(n)}`, 2)
	end
	return result
end

--[=[
	@method Log10
	@within BigValue
	@tag Methods
	@return number
	The base-10 logarithm, as a plain number. [`E`](#e) is its exact integer part
	and this adds the fraction, which makes it the cheap way to turn a magnitude
	into a tier:

	```lua
	local tier = math.floor(data.Essence.Get():Log10() / 3)
	```

	Total and unguarded, matching what the same call on a plain number does: zero
	gives `-inf` and a negative value gives `nan`, so a fresh `0` balance needs no
	special case at the call site. Precision decays as the value grows, from about
	17 significant digits at `1e0` to 10 at `1e1000000` and none near the exponent
	ceiling, so read [`E`](#e) when you need the integer part exactly.
]=]
function BIG_MT.Log10(self: Big): number
	return Big.log10(self)
end

--[=[
	@method Short
	@within BigValue
	@tag Methods
	@param decimals number?
	@return string
	The display form. Uses a letter suffix while there is one and falls back to
	scientific notation once it runs out, so `1500` is `"1.50K"`, `1e40` is
	`"10.00DDc"` and `1.5e100` is `"1.5e100"`. A negative value keeps its sign.

	```lua
	data.Essence.Observe(function(essence)
	    essenceLabel.Text = essence:Short()
	end)
	```

	`decimals` defaults to 2 and rounds rather than truncates, so `Short(0)` on
	`1500` gives `"2K"`. The full suffix table is in the
	[Big Numbers](../big-numbers.md#showing-it-to-a-player) guide.
]=]
function BIG_MT.Short(self: Big, decimals: number?): string
	return Big.toShort(self, decimals)
end

--[=[
	@method ToNumber
	@within BigValue
	@tag Methods
	@return number
	The value as a plain Luau number. Lossy on purpose: digits past the 53rd bit are
	gone, and anything past `1.8e308` saturates to `math.huge`.

	This is how you test a big against a constant, since `<` and `==` both need a
	big on the other side:

	```lua
	if data.Essence.Get():ToNumber() >= price then
	    data.Essence.Decrement(price)
	end
	```

	A read, not a round trip. Writing the result back through the field rounds the
	balance to what a double can hold, which is the ceiling the field exists to
	escape.
]=]
function BIG_MT.ToNumber(self: Big): number
	return Big.toNumber(self)
end

--[=[
	@within BigValue
	@tag Fields
	@prop M number
	The mantissa: exactly `0`, or in `[1, 10)` carrying the value's sign and its ~15
	significant digits. `1.5e100` has `M = 1.5`.

	Read it, do not write it. `Get` builds a fresh object on every call, detached
	from the stored form, so assigning to `M` changes a copy nothing will save.
]=]

--[=[
	@within BigValue
	@tag Fields
	@prop E number
	The exponent: the exact integer part of the base-10 logarithm. `1.5e100` has
	`E = 100`, and zero has `E = 0`. Use it rather than [`Log10`](#log10) when you
	need that integer exactly at any magnitude.

	It caps at `2^52`, the largest exponent the wire encoding can carry back, and a
	value that would exceed it saturates there rather than storing an infinity the
	save could not round-trip. Assigning to it is the same no-op as assigning to `M`.
]=]

return Big
