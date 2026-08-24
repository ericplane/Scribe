--!nonstrict
-- Scribe.Big integer exponentiation and base-10 logarithm.
--
-- The reference values below were generated from the module and then checked against a
-- 400-digit Python `decimal` reference of the EXACT stored double -- not of the number the
-- caller passed, because Big.from already snaps its input to 15 digits and charging the
-- algorithm for that measures the representation instead. All eleven rows land within one
-- unit of the 15th significant digit, and none disagrees about the exponent.
--
-- Three rows sit exactly one ulp from the ideal 15-digit round, and that is normalize's
-- scaling rather than Pow drifting: for 1.5^13 and (-2.2096)^13 the single-operation route
-- `Big.normalize(base ^ n, 0)` produces the identical mantissa, so the value asserted here
-- IS the module's canonical form. The naive route does not agree -- at 9.99^255 a 255-step
-- Big.mul chain lands on 7.74817636497004 against Pow's ...009, six units further from the
-- truth -- which is the whole reason for the double-double kernel.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Big = require(ScribeRoot.Internal.Big)
	local Wire = require(ScribeRoot.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	--- The house idiom: fold the pair into one string so a single equal() covers both halves.
	local function form(v: any): string
		return string.format("%.15g|%d", v.M, v.E)
	end

	it("matches a 400-digit reference of the stored double, to the module's 15 digits", function()
		local CASES = {
			{ 3, 35, "5.00315450989997|16" },
			{ 1.5, 13, "1.94619506835937|2" },
			{ 2, 100, "1.26765060022823|30" },
			{ 1.7, 1000, "2.81139182902733|230" },
			{ 1.0000001, 1000000, "1.10517091261432|0" },
			{ 6.02214076, 1000, "5.6351098315515|779" },
			{ 9.99, 255, "7.74817636497009|254" },
			{ 1.15, 500, "2.23316173065811|30" },
			-- Negative bases. These are what make the result accumulator's window test
			-- two-sided: with `h >= 10` instead of `math.abs(h) >= 10` these three move.
			{ -2.2096, 13, "-2.99279931680248|4" },
			{ -2.0976, 15, "-6.69638037873165|4" },
			{ -2.6352, 129, "-1.92731213339096|54" },
		}
		for _, case in CASES do
			local got = Big.pow(Big.from(case[1]), case[2])
			expect(`{case[1]}^{case[2]} = {form(got)}`).to.equal(`{case[1]}^{case[2]} = {case[3]}`)
		end
	end)

	it("holds the exponent identities, including the empty product", function()
		-- x^0 is 1 unconditionally -- that is the whole reason 0^0 is 1 rather than 0.
		expect(form(Big.pow(Big.from("1e400"), 0))).to.equal("1|0")
		expect(form(Big.pow(Big.from(0), 0))).to.equal("1|0")
		expect(form(Big.pow(Big.from(0), 7))).to.equal("0|0")
		expect(form(Big.pow(Big.from("1e400"), 1))).to.equal(form(Big.from("1e400")))
		expect(form(Big.pow(Big.from(-2), 3))).to.equal("-8|0")
		expect(form(Big.pow(Big.from(-2), 2))).to.equal("4|0")
	end)

	it("refuses every exponent that is not a non-negative integer, and returns nil like div", function()
		-- Each of these is a plausible-looking WRONG answer without the guard, because the
		-- squaring schedule cannot detect a bad exponent: unguarded, 3^2.5 returns 9 and
		-- 3^-3 returns 1. The -1 case is separate from -3 on purpose -- `n < 0` weakened to
		-- `n < -1` survives a -3-only list.
		expect(Big.pow(Big.from(3), 2.5)).to.equal(nil)
		expect(Big.pow(Big.from(3), -1)).to.equal(nil)
		expect(Big.pow(Big.from(3), -3)).to.equal(nil)
		expect(Big.pow(Big.from(3), 2 ^ 53 + 2)).to.equal(nil)
		expect(Big.pow(Big.from(3), 0 / 0)).to.equal(nil)
		expect(Big.pow(Big.from(3), math.huge)).to.equal(nil)
		expect(Big.pow(Big.from(3), "4" :: any)).to.equal(nil)
		expect(Big.pow(Big.from(3), {} :: any)).to.equal(nil)
	end)

	itRunning("raises a NAMED error from the value method, for every refused kind", function()
		-- Asserting the message rather than merely that something threw: with the
		-- `type(n) ~= "number"` guard removed, ("4") % 1 coerces to 0 and control reaches
		-- `"4" < 0`, which raises a raw Luau comparison error. A bare throw check cannot
		-- tell that mutant from the original.
		local harness = TestCtx.make({ AutoPump = true, Template = { Coins = Scribe.Big(3) } })
		local _player, _entry, data = harness.Join(920401)
		local value = data.Coins.Get()

		for _, bad in { 2.5, -1, -3, 2 ^ 53 + 2, 0 / 0, math.huge, "4" :: any, {} :: any } do
			local ok, err = pcall(function()
				return value:Pow(bad)
			end)
			expect(
				`{tostring(bad)} ok={ok} named={string.match(tostring(err), "Pow needs a non%-negative integer") ~= nil}`
			).to.equal(`{tostring(bad)} ok=false named=true`)
		end
		-- and the value is still usable afterwards
		expect(form(value:Pow(3))).to.equal("2.7|1")

		harness.Cleanup()
	end)

	it("saturates at MAX_EXPONENT the way a chain of multiplies already does", function()
		-- One rule, not two. Pow exits through normalize, which is what clamps -- so a
		-- Pow that overflows lands exactly where an overflowing mul chain lands.
		local huge = Big.pow(Big.normalize(9.99, 2 ^ 52), 2 ^ 50)
		expect(huge.E).to.equal(2 ^ 52)

		local chained = Big.normalize(5, 2 ^ 52)
		for _ = 1, 1060 do
			chained = Big.mul(chained, chained)
		end
		expect(`pow={huge.E} chain={chained.E}`).to.equal(`pow={2 ^ 52} chain={2 ^ 52}`)
	end)

	it("answers Log10 totally, including where the answer is not a number", function()
		-- Deliberately unguarded: math.log10(0) is -inf and math.log10(-5) is nan, and
		-- adding E propagates both, exactly as the equivalent plain number does. A guard
		-- returning nil would fire on a fresh player's {0, 0} balance.
		expect(Big.log10(Big.from("1e400"))).to.equal(400)
		expect(Big.log10(Big.from(1))).to.equal(0)
		expect(Big.log10(Big.from(0))).to.equal(-math.huge)
		local negative = Big.log10(Big.normalize(-5, 0))
		expect(negative ~= negative).to.equal(true)
		expect(Big.log10(Big.normalize(1, -400))).to.equal(-400)
	end)

	it("pins Log10's precision decay as the contract, and a.E as the exact integer part", function()
		-- The integer part and the fraction share one double's 53 bits. This freezes the
		-- decay so a later "simplification" to math.log10(Big.toNumber(a)) -- which
		-- saturates to inf past 1.8e308 -- fails here rather than in a game.
		expect(string.format("%.17g", Big.log10(Big.normalize(1.7, 1e6)))).to.equal("1000000.2304489213")
		local atCeiling = Big.normalize(1.7, 2 ^ 52)
		expect(Big.log10(atCeiling)).to.equal(atCeiling.E)
	end)

	itRunning("stores, reloads and re-encodes a Pow result as a canonical big", function()
		-- The composition the docs recommend, end to end: it routes through applySet, so
		-- bounds, replication and Changed are byte-identical to any other write.
		local harness = TestCtx.make({ AutoPump = true, Template = { Coins = Scribe.Big(0) } })
		local _player, _entry, data = harness.Join(920402)

		data.Coins.Set(1.7)
		data.Coins.Set(data.Coins.Get():Pow(500))
		local stored = data.Coins.Get()
		expect(form(stored)).to.equal("1.67672055782331|115")

		-- canonical form, which is what every exact-mantissa consumer downstream assumes
		local canonical = (stored.M == 0 or (math.abs(stored.M) >= 1 and math.abs(stored.M) < 10))
			and stored.E % 1 == 0
			and math.abs(stored.E) <= 2 ^ 52
		expect(canonical).to.equal(true)

		-- and it survives the wire unchanged
		local node = { ValueType = "big" }
		local writer = Wire.NewWriter()
		Wire.EncodeValue(writer, node, Big.toStored(stored))
		local decoded = Wire.DecodeValue(Wire.NewReader(Wire.Finish(writer)), node)
		expect(`{decoded[1]}|{decoded[2]}`).to.equal(`{stored.M}|{stored.E}`)

		harness.Cleanup()
	end)

	it("absorbs a hostile big on the decode side without ever producing a non-canonical value", function()
		-- The decode-side fuzz case. A big arrives as two raw wire fields -- an f64 mantissa
		-- and a zigzag varint exponent -- neither of which the decoder constrains, so a
		-- hostile or corrupt frame can hand Big.from a pair no writer would produce. What
		-- must hold is that every value reaching storage is canonical or refused: a
		-- non-finite exponent is what previously made a profile unsavable and hung the
		-- varint writer.
		local node = { ValueType = "big" }
		local HOSTILE = {
			{ 0 / 0, 0 },
			{ math.huge, 0 },
			{ -math.huge, 0 },
			{ 1, 0 / 0 },
			{ 1, math.huge },
			{ 1, -math.huge },
			{ 1e308, 2 ^ 53 },
			{ 5e-324, -(2 ^ 53) },
			{ 0, 2 ^ 52 },
			{ 1234567.891011, 7.5 },
			{ -0, -0 },
			{ 9.999999999999999, 2 ^ 52 - 1 },
		}
		local accepted, refused = 0, 0
		for _, pair in HOSTILE do
			-- Round-trip the pair through the real codec first, so this tests what a frame
			-- can actually deliver rather than what a spec can construct in memory.
			local writer = Wire.NewWriter()
			local encodeOk = pcall(Wire.EncodeValue, writer, node, pair)
			if not encodeOk then
				refused += 1
				continue
			end
			local decodeOk, decoded = pcall(function()
				return Wire.DecodeValue(Wire.NewReader(Wire.Finish(writer)), node)
			end)
			if not decodeOk then
				refused += 1
				continue
			end
			local value = Big.from(decoded)
			if value == nil then
				refused += 1
				continue
			end
			accepted += 1
			local finite = value.M == value.M
				and value.M ~= math.huge
				and value.M ~= -math.huge
				and value.E == value.E
				and value.E ~= math.huge
				and value.E ~= -math.huge
			local canonical = (value.M == 0 or (math.abs(value.M) >= 1 and math.abs(value.M) < 10))
				and value.E % 1 == 0
				and math.abs(value.E) <= 2 ^ 52
			expect(`finite={finite} canonical={canonical}`).to.equal("finite=true canonical=true")
			-- and whatever it became must survive a second trip, or the stored form is not
			-- a fixed point and a reload can differ from a save
			local w2 = Wire.NewWriter()
			Wire.EncodeValue(w2, node, Big.toStored(value))
			local again = Big.from(Wire.DecodeValue(Wire.NewReader(Wire.Finish(w2)), node))
			expect(form(again)).to.equal(form(value))
		end
		-- Both outcomes have to be a real share of the run, or this passes vacuously.
		expect(`accepted>0={accepted > 0} refused>0={refused > 0} total={accepted + refused}`).to.equal(
			`accepted>0=true refused>0=true total={#HOSTILE}`
		)
	end)

	it("snaps the mantissa to exactly 15 significant digits, not 14 and not 17", function()
		-- Big.luau's header says "Exactly 15, not roughly", and until this spec the suite
		-- pinned it only from above: %.16g and %.17g failed three existing specs while
		-- %.14g left all 1241 green. Pow is the operation that makes the lower bound
		-- matter, because it is the one that can move the 15th digit on purpose.
		expect(form(Big.normalize(1.234567890123457, 0))).to.equal("1.23456789012346|0")
		-- Two inputs agreeing to 15 digits and differing at the 17th must land on the same
		-- stored mantissa, bit for bit -- that is what makes one value have one stored form.
		expect(Big.normalize(1.2345678901234567, 0).M).to.equal(Big.normalize(1.2345678901234561, 0).M)
		-- and the module's own worked example from the header
		expect(form(Big.sub(Big.from(100), Big.from(30)))).to.equal(form(Big.from(70)))
	end)
end
