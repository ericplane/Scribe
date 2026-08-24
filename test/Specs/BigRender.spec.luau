--!nonstrict
-- Scribe.Big's two rendering paths and its arithmetic operators.
--
-- `tostring` (Big.toString) and `:Short` (Big.toShort) are both public, and they
-- have to describe the SAME value. toString is also the metamethod every bounds
-- diagnostic interpolates, so a wrong render there is what the developer reads
-- when a write is refused.
--
-- Fractional bigs are ordinary, not exotic: `Divide` is a shipped accessor, so
-- any balance split three ways is one.

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function makeHarness()
		return TestCtx.make({
			AutoPump = true,
			Template = {
				Coins = Scribe.Big(0, { Min = 0 }),
				Bank = Scribe.Big(0),
			},
		})
	end

	it("renders a fractional value as itself rather than rounding it to an integer", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(98301)

		data.Coins.Set(10)
		expect(tostring(data.Coins.Divide(3))).to.equal("3.33333333333333")

		data.Bank.Set(1.5)
		expect(tostring(data.Bank.Get())).to.equal("1.5")
		data.Bank.Set(3.14159)
		expect(tostring(data.Bank.Get())).to.equal("3.14159")
		data.Bank.Set(99.999)
		expect(tostring(data.Bank.Get())).to.equal("99.999")
		data.Bank.Set(-2.25)
		expect(tostring(data.Bank.Get())).to.equal("-2.25")
		data.Bank.Set(0.5)
		expect(tostring(data.Bank.Get())).to.equal("0.5")

		-- Whole numbers keep the form they already had.
		data.Bank.Set(1500)
		expect(tostring(data.Bank.Get())).to.equal("1500")
		data.Bank.Set(70)
		expect(tostring(data.Bank.Get())).to.equal("70")
		data.Bank.Set(0)
		expect(tostring(data.Bank.Get())).to.equal("0")

		harness.Cleanup()
	end)

	it("makes tostring and :Short name the same number", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(98302)

		-- All under 1e3, where :Short renders digits rather than a letter suffix.
		for _, value in { 1.5, 3.14159, 99.999, 0.5, 0.001, 123.456 } do
			data.Bank.Set(value)
			local big = data.Bank.Get()
			-- :Short rounds for display; tostring must agree with it to that many
			-- places rather than describing a different magnitude.
			expect(tonumber(tostring(big))).to.near(tonumber(big:Short()), 0.005)
		end

		harness.Cleanup()
	end)

	it("round-trips its own rendering back through a write", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(98303)

		for _, value in { 1.5, 3.14159, 99.999, 0.5, -2.25, 1500, 0.001, 1e-5, 1234.5678 } do
			data.Bank.Set(value)
			local original = data.Bank.Get()
			local rendered = tostring(original)
			data.Bank.Set(0)
			data.Bank.Set(rendered)
			expect(tostring(data.Bank.Get())).to.equal(rendered)
			expect(data.Bank.Get() == original).to.equal(true)
		end

		-- The exponent forms have to survive the same trip.
		for _, text in { "1e400", "9.87e250", "1.6e100", "1e800" } do
			data.Bank.Set(text)
			local rendered = tostring(data.Bank.Get())
			expect(rendered).to.equal(text)
			data.Bank.Set(0)
			data.Bank.Set(rendered)
			expect(tostring(data.Bank.Get())).to.equal(text)
		end

		harness.Cleanup()
	end)

	it("reports a fractional bound as itself in the write it refuses", function()
		local harness = TestCtx.make({
			AutoPump = true,
			Options = { BoundsPolicy = "Reject" },
			Template = { Bounded = Scribe.Big(2, { Min = 1.5, Max = 10.25 }) },
		})
		local _player, _entry, data = harness.Join(98304)

		local okLow, low = pcall(function()
			data.Bounded.Set(1)
		end)
		expect(okLow).to.equal(false)
		expect(string.find(tostring(low), "1.5", 1, true)).to.be.ok()
		expect(string.find(tostring(low), "Min 2", 1, true)).never.to.be.ok()

		local okHigh, high = pcall(function()
			data.Bounded.Set(50)
		end)
		expect(okHigh).to.equal(false)
		expect(string.find(tostring(high), "10.25", 1, true)).to.be.ok()

		harness.Cleanup()
	end)

	it("never shows a nonzero balance as a bare zero in :Short", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(98305)

		data.Bank.Set(1e-5)
		expect(data.Bank.Get():Short()).never.to.equal("0.00")
		expect(tonumber(data.Bank.Get():Short())).never.to.equal(0)
		data.Bank.Set(0.001)
		expect(tonumber(data.Bank.Get():Short())).never.to.equal(0)
		data.Bank.Set(-0.001)
		expect(tonumber(data.Bank.Get():Short())).never.to.equal(0)

		-- A real zero still reads as zero.
		data.Bank.Set(0)
		expect(data.Bank.Get():Short()).to.equal("0")
		-- And a value the requested precision can hold is untouched.
		data.Bank.Set(1.5)
		expect(data.Bank.Get():Short()).to.equal("1.50")

		harness.Cleanup()
	end)

	it("raises on division by zero through the operator, not just the accessor", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(98306)

		data.Coins.Set(10)
		local value = data.Coins.Get()

		local ok, err = pcall(function()
			-- selene: allow(divide_by_zero) -- the literal zero divisor IS the test input
			return value / 0
		end)
		expect(ok).to.equal(false)
		expect(string.find(tostring(err), "Scribe:", 1, true)).to.be.ok()

		-- The accessor already raised; the operator now matches it.
		expect(function()
			data.Coins.Divide(0)
		end).to.throw("Scribe:")

		-- Dividing by anything else still works.
		expect(tostring(value / 2)).to.equal("5")

		harness.Cleanup()
	end)

	it("names Scribe when an operand cannot be read as a big", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(98307)

		data.Coins.Set(10)
		local value = data.Coins.Get()

		expect(function()
			return value + "not a number"
		end).to.throw("Scribe:")
		expect(function()
			return value - {}
		end).to.throw("Scribe:")
		expect(function()
			return value * "not a number"
		end).to.throw("Scribe:")
		expect(function()
			return value / "not a number"
		end).to.throw("Scribe:")

		harness.Cleanup()
	end)
end
