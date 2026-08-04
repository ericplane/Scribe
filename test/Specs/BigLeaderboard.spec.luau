--!nonstrict
-- Ranking a Scribe.Big on an OrderedDataStore, whose key is an integer that a Luau
-- number only represents exactly up to 2^53.
--
-- A big is already normalized to 1 <= |m| < 10 with an integer exponent, so packing
-- exponent-major preserves the ordering exactly and needs no logarithm. The
-- mantissa slot cannot spill into the next exponent, so ties break correctly.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function makeHarness()
		return TestCtx.make({
			Template = { Coins = Scribe.Big(0, { Min = 0 }) },
			Options = { Leaderboards = { Top = { Stat = "Coins" } } },
		})
	end

	local function board(harness)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow("Top")
		return harness.Data.GetLeaderboard("Top", 10)
	end

	it("ranks values across magnitudes a double cannot hold", function()
		local harness = makeHarness()
		for _, pair in { { 1, "5e40" }, { 2, "1e400" }, { 3, "9.9e39" } } do
			local _p, _e, data = harness.Join(99100 + pair[1])
			data.Coins.Set(pair[2])
		end

		local entries = board(harness)
		expect(#entries).to.equal(3)
		expect(entries[1].UserId).to.equal(99102) -- 1e400
		expect(entries[2].UserId).to.equal(99101) -- 5e40
		expect(entries[3].UserId).to.equal(99103) -- 9.9e39

		harness.Cleanup()
	end)

	it("breaks a tie on the mantissa at the same exponent", function()
		-- The case a log-scaled or exponent-only key would collapse into a tie.
		local harness = makeHarness()
		local _p1, _e1, low = harness.Join(99110)
		low.Coins.Set("5e40")
		local _p2, _e2, high = harness.Join(99111)
		high.Coins.Set("5.0000001e40")

		local entries = board(harness)
		expect(entries[1].UserId).to.equal(99111)
		expect(entries[2].UserId).to.equal(99110)

		harness.Cleanup()
	end)

	it("hands back a big Score, not the packed key", function()
		local harness = makeHarness()
		local _p, _e, data = harness.Join(99120)
		data.Coins.Set("9.87e250")

		local entries = board(harness)
		expect(tostring(entries[1].Score)).to.equal("9.87e250")
		-- Round-tripped through the key, so the exponent has to come back intact.
		expect(entries[1].Score.E).to.equal(250)

		harness.Cleanup()
	end)

	it("refuses a Scale on a big board", function()
		-- The packing already maps the value into the key space, so a Scale would
		-- read as a multiplier that does nothing.
		expect(function()
			TestCtx.make({
				Template = { Coins = Scribe.Big(0) },
				Options = { Leaderboards = { Bad = { Stat = "Coins", Scale = 100 } } },
			}).Cleanup()
		end).to.throw()
	end)

	it("refuses a replicated big board rather than breaking the client handshake", function()
		-- The board frame writes Score as an f64 and a big Score is a table, so
		-- broadcasting one throws. That throw happens under the inbound frame pcall
		-- during a Hello, so a JOINING player is counted as a malformed frame and
		-- loses every other player's Shared data. Refuse the config instead.
		expect(function()
			TestCtx.make({
				Template = { Coins = Scribe.Big(0) },
				Options = { Leaderboards = { Bad = { Stat = "Coins", Replicate = true } } },
			}).Cleanup()
		end).to.throw()
		-- Server-side reads are unaffected, which is the supported shape today.
		expect(function()
			TestCtx.make({
				Template = { Coins = Scribe.Big(0) },
				Options = { Leaderboards = { Ok = { Stat = "Coins" } } },
			}).Cleanup()
		end).never.to.throw()
	end)

	it("drops a score the packing cannot rank instead of misordering it", function()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Big(0) }, -- no Min, so negatives are storable
			Options = { Leaderboards = { Top = { Stat = "Coins" } } },
		})
		local _p1, _e1, negative = harness.Join(99130)
		negative.Coins.Set(-5)
		local _p2, _e2, positive = harness.Join(99131)
		positive.Coins.Set(10)

		-- The packing has no room for a sign; ranking the negative anyway would put
		-- it above every positive value. The refused write leaves the value enqueued
		-- when the player loaded, which is 0, rather than removing them.
		local entries = board(harness)
		expect(#entries).to.equal(2)
		expect(entries[1].UserId).to.equal(99131)
		expect(tostring(entries[1].Score)).to.equal("10")
		expect(entries[2].UserId).to.equal(99130)
		expect(tostring(entries[2].Score)).to.equal("0") -- NOT -5

		harness.Cleanup()
	end)

	it("ranks a zero balance below a fractional one", function()
		-- A value in (0, 1) normalizes to a NEGATIVE exponent and therefore a negative
		-- key, so mapping zero to key 0 put an empty balance above every fractional
		-- one. Zero has to sit under the whole representable range, not at its middle.
		local harness = makeHarness()
		local _p1, _e1, empty = harness.Join(99190)
		empty.Coins.Set(0)
		local _p2, _e2, tiny = harness.Join(99191)
		tiny.Coins.Set(0.5)
		local _p3, _e3, small = harness.Join(99192)
		small.Coins.Set("1e-8")

		local entries = board(harness)
		expect(#entries).to.equal(3)
		expect(entries[1].UserId).to.equal(99191) -- 0.5
		expect(entries[2].UserId).to.equal(99192) -- 1e-8
		expect(entries[3].UserId).to.equal(99190) -- 0
		expect(tostring(entries[3].Score)).to.equal("0")

		harness.Cleanup()
	end)

	it("gives a non-default SigFigs its own store, so key formats never mix", function()
		-- SigFigs defines the key LAYOUT. Reading a key written at one setting with
		-- another splits the exponent and mantissa at the wrong digit, which inverts
		-- ranks and moves scores by orders of magnitude. Isolating the store means
		-- changing SigFigs restarts the board rather than corrupting it.
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Big(0, { Min = 0 }), Gems = Scribe.Int(0) },
			Options = {
				Leaderboards = {
					Plain = { Stat = "Gems" },
					Default = { Stat = "Coins" },
					Fine = { Stat = "Coins", SigFigs = 14 },
					Coarse = { Stat = "Coins", SigFigs = 6 },
					Named = { Stat = "Coins", SigFigs = 6, StoreName = "LB_Shared" },
				},
			},
		})
		local boards = harness.Ctx.Leaderboards
		-- Even at the DEFAULT SigFigs a big board is namespaced, because exponent-major
		-- and plain-numeric are two layouts and a board name is all that separates one
		-- store from another. Retyping a stat from Scribe.Int to Scribe.Big needs no
		-- migration and emits no warning, so sharing LB_<name> silently reinterpreted
		-- every legacy key: 9e11 decodes as 9, and 3.5e12 is bit-identical to the new
		-- key for 5000, which no repair pass could separate.
		expect(boards.BoardStoreName("Default")).to.equal("LB_Default_big12")
		expect(boards.BoardStoreName("Fine")).to.equal("LB_Fine_big14")
		expect(boards.BoardStoreName("Coarse")).to.equal("LB_Coarse_big6")
		-- A plain numeric board keeps the unadorned name, which is what a big board
		-- must never collide with.
		expect(boards.BoardStoreName("Plain")).to.equal("LB_Plain")
		-- An explicit StoreName still wins: that caller manages the namespace.
		expect(boards.BoardStoreName("Named")).to.equal("LB_Shared")
		harness.Cleanup()
	end)

	it("ranks two players who hold the same value identically", function()
		-- One reached by arithmetic, one written as a literal. If normalize leaves
		-- two stored forms for one value, packBig turns that into two different keys
		-- and the two players get different ranks holding the same balance.
		local harness = makeHarness()
		local _p1, _e1, viaLiteral = harness.Join(99180)
		viaLiteral.Coins.Set(70)
		local _p2, _e2, viaMath = harness.Join(99181)
		viaMath.Coins.Set(100)
		viaMath.Coins.Decrement(30)

		local entries = board(harness)
		expect(#entries).to.equal(2)
		expect(tostring(entries[1].Score)).to.equal(tostring(entries[2].Score))
		expect(entries[1].Score:Short()).to.equal(entries[2].Score:Short())

		harness.Cleanup()
	end)

	it("carries more significant figures on a board that asks for them", function()
		-- The ranking key is one integer under 2^53 shared by the exponent and the
		-- mantissa, so SigFigs is where a board spends that budget. Two values that
		-- agree to 12 figures tie at the default and separate at 14. Exponent 8 so
		-- the same pair fits every setting under test (14 figures caps it at 89).
		local a, b = "5.00000000000012e8", "5.00000000000034e8"
		local function rank(sigFigs)
			local harness = TestCtx.make({
				Template = { Coins = Scribe.Big(0, { Min = 0 }) },
				Options = {
					Leaderboards = {
						Top = if sigFigs then { Stat = "Coins", SigFigs = sigFigs } else { Stat = "Coins" },
					},
				},
			})
			local _p1, _e1, low = harness.Join(99150)
			low.Coins.Set(a)
			local _p2, _e2, high = harness.Join(99151)
			high.Coins.Set(b)
			local entries = board(harness)
			harness.Cleanup()
			return entries
		end

		-- Default (12 figures): both round to the same key, so the order is a tie the
		-- store resolves arbitrarily and neither Score keeps the distinguishing digits.
		local coarse = rank(nil)
		expect(coarse[1].Score.M).to.equal(coarse[2].Score.M)

		-- 14 figures: the digits survive the round trip and the ordering is real.
		local fine = rank(14)
		expect(fine[1].UserId).to.equal(99151)
		expect(fine[2].UserId).to.equal(99150)
		expect(fine[1].Score.M > fine[2].Score.M).to.equal(true)

		-- And a board that wants range instead of resolution can go the other way.
		local coarser = rank(4)
		expect(#coarser).to.equal(2)
		expect(coarser[1].Score.E).to.equal(8)
		expect(coarser[1].Score.M).to.equal(5)
	end)

	it("moves the exponent cap with SigFigs, and drops what no longer fits", function()
		-- Every extra significant figure costs a factor of ten of exponent range,
		-- because the two halves share one integer under 2^53. A score past the
		-- board's own cap is dropped and logged rather than ranked wrongly.
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Big(0, { Min = 0 }) },
			Options = { Leaderboards = { Top = { Stat = "Coins", SigFigs = 15 } } },
		})
		local _p1, _e1, tooBig = harness.Join(99160)
		tooBig.Coins.Set("1e40") -- fine at the default 12, past the cap of 8 at 15
		local _p2, _e2, fits = harness.Join(99161)
		fits.Coins.Set("1e8")

		local entries = board(harness)
		expect(#entries).to.equal(2)
		expect(entries[1].UserId).to.equal(99161)
		expect(tostring(entries[1].Score)).to.equal("100000000")
		-- The refused write leaves the value enqueued at load, which is 0.
		expect(tostring(entries[2].Score)).to.equal("0")

		harness.Cleanup()
	end)

	it("refuses a SigFigs that is out of range or not on a big stat", function()
		local function build(boardConfig, template)
			return function()
				TestCtx.make({
					Template = template or { Coins = Scribe.Big(0) },
					Options = { Leaderboards = { B = boardConfig } },
				}).Cleanup()
			end
		end

		expect(build({ Stat = "Coins", SigFigs = 0 })).to.throw()
		expect(build({ Stat = "Coins", SigFigs = 16 })).to.throw()
		expect(build({ Stat = "Coins", SigFigs = 12.5 })).to.throw()
		expect(build({ Stat = "Coins", SigFigs = "twelve" })).to.throw()
		-- On a plain numeric stat the key IS the value and Scale is the dial, so
		-- accepting SigFigs there would silently do nothing.
		expect(build({ Stat = "Gems", SigFigs = 12 }, { Gems = Scribe.Int(0) })).to.throw()
		-- The endpoints and the default-shaped config all still build.
		expect(build({ Stat = "Coins", SigFigs = 1 })).never.to.throw()
		expect(build({ Stat = "Coins", SigFigs = 15 })).never.to.throw()
		expect(build({ Stat = "Coins" })).never.to.throw()
	end)

	it("round-trips a score exactly at every SigFigs setting", function()
		-- The packed key is decoded back into the Score handed to the developer, so a
		-- stride or mantissa-scale mistake at any setting shows up as a wrong
		-- magnitude rather than a wrong low digit.
		for sigFigs = 1, 15 do
			local harness = TestCtx.make({
				Template = { Coins = Scribe.Big(0, { Min = 0 }) },
				Options = { Leaderboards = { Top = { Stat = "Coins", SigFigs = sigFigs } } },
			})
			local _p, _e, data = harness.Join(99170)
			data.Coins.Set("5e8") -- inside the cap even at 15 figures
			local entries = board(harness)
			expect(entries[1].Score.E).to.equal(8)
			expect(entries[1].Score.M).to.equal(5)
			harness.Cleanup()
		end
	end)

	it("refuses a plain score past the exact integer range", function()
		-- 2^53, not 2^63: past that a Luau number is no longer an exact integer, so
		-- the key is written with silently wrong low digits and scores tie.
		local harness = TestCtx.make({
			Template = { Gems = Scribe.Int(0, { Min = 0 }) },
			Options = { Leaderboards = { G = { Stat = "Gems", Scale = 1000 } } },
		})
		local _p, _e, data = harness.Join(99140)
		data.Gems.Set(1e15) -- x1000 = 1e18, past 2^53 but under 2^63

		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow("G")
		local entries = harness.Data.GetLeaderboard("G", 10)
		-- The out-of-range write is dropped, so the board still shows the value from
		-- load rather than a key with silently wrong low digits.
		expect(#entries).to.equal(1)
		expect(entries[1].Score).to.equal(0)

		harness.Cleanup()
	end)
end
