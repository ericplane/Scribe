--!nonstrict
-- Scribe.Short: the abbreviation a Big already carried, for every numeric field.
--
-- A Big has had `:Short()` since it shipped, because a Big cannot be shown to a player
-- any other way. An Int and a Number had nothing, so code that displayed both had to
-- branch on which numeric type the field happened to be declared as. That is the
-- inconsistency this closes, and it is why the function takes EITHER: a balance label
-- should not care.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Big = require(Root.Scribe.Internal.Big)

	local DEFAULT_SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

	--- Put the defaults back, so a suffix test cannot leak into its neighbours.
	local function restore()
		Scribe.SetShortSuffixes(DEFAULT_SUFFIXES)
	end

	describe("it renders a plain number", function()
		it("abbreviates at each tier the way a player reads it", function()
			restore()
			expect(`{Scribe.Short(999)} {Scribe.Short(1500, 0)} {Scribe.Short(100000000)} {Scribe.Short(2400000000)}`).to.equal(
				"999 2K 100.00M 2.40B"
			)
		end)

		it("rounds rather than truncates, which is what makes 1500 read as 2K", function()
			-- Stated in the doc block, so it is asserted rather than assumed: a truncating
			-- implementation gives "1K" here and looks correct at every other tier.
			expect(`{Scribe.Short(1500, 0)} {Scribe.Short(1499, 0)}`).to.equal("2K 1K")
		end)

		it("keeps a small number intact, because the units tier is empty", function()
			expect(`{Scribe.Short(0)} {Scribe.Short(42)}`).to.equal("0 42")
		end)
	end)

	describe("it renders a Scribe.Big the same way", function()
		it("takes a Big value, so a label does not branch on the numeric type", function()
			restore()
			local big = Big.from("2500000")
			expect(`{Scribe.Short(big)} {tostring(Scribe.Short(big) == big:Short())}`).to.equal("2.50M true")
		end)

		it("goes past the double range, which is the whole reason Big exists", function()
			expect(Scribe.Short(Big.from("1e30"), 0)).to.equal("1No")
		end)
	end)

	describe("the suffix table is replaceable", function()
		it("uses the table a game supplies", function()
			-- The conventions diverge past T, and a game that cannot supply its own table
			-- writes its own formatter instead and stops using this one.
			-- Both tiers, because the table is read POSITIONALLY: index 6 is 10^15 and
			-- index 7 is 10^18. Asserting one alone passes on an off-by-one table.
			Scribe.SetShortSuffixes({ "", "K", "M", "B", "T", "aa", "ab" })
			local rendered = `{Scribe.Short(1e15, 0)} {Scribe.Short(1e18, 0)}`
			restore()
			expect(rendered).to.equal("1aa 1ab")
		end)

		it("COPIES the table, so a caller editing theirs afterwards changes nothing", function()
			-- Keeping the caller's table would make every later edit to it silently
			-- re-suffix the whole game, at whatever moment they happened to make it.
			local mine = { "", "K", "M", "B", "T", "aa" }
			Scribe.SetShortSuffixes(mine)
			mine[6] = "VANDALISED"
			local rendered = Scribe.Short(1e15, 0)
			restore()
			expect(rendered).to.equal("1aa")
		end)

		it("REFUSES a table whose units tier is not empty", function()
			-- Index 1 renders a small number, so a non-empty entry there would suffix
			-- every value in the game.
			local ok, err = pcall(Scribe.SetShortSuffixes, { "u", "K", "M" })
			restore()
			expect(`ok={tostring(ok)} named={tostring(string.find(tostring(err), "units tier", 1, true) ~= nil)}`).to.equal(
				"ok=false named=true"
			)
		end)

		it("REFUSES a table that is empty or holds a non-string", function()
			local emptyOk = pcall(Scribe.SetShortSuffixes, {})
			local wrongOk, wrongErr = pcall(Scribe.SetShortSuffixes, { "", 5 })
			restore()
			expect(
				`empty={tostring(emptyOk)} wrong={tostring(wrongOk)} named={tostring(
					string.find(tostring(wrongErr), "must be a string", 1, true) ~= nil
				)}`
			).to.equal("empty=false wrong=false named=true")
		end)
	end)

	describe("it refuses what it cannot render", function()
		it("REFUSES a value that is not numeric, rather than rendering nil", function()
			restore()
			local ok, err = pcall(Scribe.Short, "not a number at all")
			expect(
				`ok={tostring(ok)} named={tostring(string.find(tostring(err), "expected a number", 1, true) ~= nil)}`
			).to.equal("ok=false named=true")
		end)

		it("REFUSES fractional or negative decimals", function()
			local fracOk = pcall(Scribe.Short, 1000, 1.5)
			local negOk, negErr = pcall(Scribe.Short, 1000, -1)
			expect(
				`frac={tostring(fracOk)} neg={tostring(negOk)} named={tostring(
					string.find(tostring(negErr), "non-negative whole number", 1, true) ~= nil
				)}`
			).to.equal("frac=false neg=false named=true")
		end)
	end)
end
