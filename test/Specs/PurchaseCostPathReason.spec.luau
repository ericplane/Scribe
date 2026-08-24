--!nonstrict
-- "invalid cost path" has to mean the path is invalid.
--
-- `Data.Purchase` refuses with that string in two very different situations. One
-- is a typo: the accessor walk throws because nothing is declared there, and the
-- message is exactly right. The other is a path that RESOLVED to a real declared
-- field whose value simply is not a spendable number -- a `Scribe.Big`, a
-- `Scribe.String`, an enum -- and there the message sends the developer hunting
-- for a misspelling that does not exist.
--
-- `Scribe.Big` is the one that actually bites: it is the library's own big-number
-- currency type, its whole purpose is holding a balance, and `Cost.Path` naming
-- one is the most reasonable mistake in the API. The guide says `Cost.Path` "names
-- any numeric field", so the refusal is correct -- Purchase does plain arithmetic
-- and a Big is a table -- but the REASON was not.
--
-- This changes only which of two refusal strings comes back. Nothing that was
-- accepted is now refused, and nothing that was refused is now accepted, which is
-- why the accept-side controls below matter as much as the reason assertions.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local NOT_SPENDABLE = Scribe.PurchaseReason.CostPathNotSpendable
	local INVALID_PATH = Scribe.PurchaseReason.InvalidCostPath

	local function makeHarness()
		return TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Score = Scribe.Number(0, { Min = 0 }),
				Prestige = Scribe.Big(1000, { Min = 0 }),
				Nick = Scribe.String("hello", { MaxLength = 8 }),
				Team = Scribe.Enum("Red", { "Red", "Blue" }),
				Bag = {}, -- dynamic dictionary: undeclared elements
			},
		})
	end

	local function buy(harness, player, path, amount)
		return harness.Data.Purchase(player, {
			Cost = { Path = path, Amount = amount or 10 },
			Category = "Test",
			ItemId = "Widget",
			Grant = function() end,
		})
	end

	describe("Purchase cost-path refusals", function()
		it("still spends from an int and a number path", function()
			-- THE CONTROL, and the one that must not move: the paths that work.
			local harness = makeHarness()
			local player = harness.Join(94001)
			local data = harness.Data.Get(player)
			data.Coins.Set(100)
			data.Score.Set(100)

			expect(buy(harness, player, "Coins")).to.equal(true)
			expect(data.Coins.Get()).to.equal(90)
			expect(buy(harness, player, "Score")).to.equal(true)
			expect(data.Score.Get()).to.equal(90)

			harness.Cleanup()
		end)

		it("still says 'invalid cost path' for a path that names nothing", function()
			-- The other control: the string keeps its meaning for the case it was
			-- written for. A fix that renamed every refusal would fail here.
			local harness = makeHarness()
			local player = harness.Join(94002)

			local ok, reason = buy(harness, player, "NoSuchField")
			expect(ok).to.equal(false)
			expect(reason).to.equal(INVALID_PATH)

			harness.Cleanup()
		end)

		it("says the path is not SPENDABLE for a declared Scribe.Big", function()
			-- The defect. The field exists, is declared, holds a balance, and the
			-- refusal blamed the path for not existing.
			local harness = makeHarness()
			local player, entry = harness.Join(94003)

			local ok, reason = buy(harness, player, "Prestige")
			expect(ok).to.equal(false)
			expect(reason).to.equal(NOT_SPENDABLE)
			-- And nothing was debited on the way to saying so.
			expect(tostring(harness.Data.Get(player).Prestige.Get())).to.equal("1000")
			expect(entry.Tree.Dead).to.equal(false)

			harness.Cleanup()
		end)

		it("says the same for other declared non-numeric fields", function()
			-- Big is the case that bites, but the conflation is general, and a fix
			-- keyed on the Big declarator alone would leave the rest lying.
			local harness = makeHarness()
			local player = harness.Join(94004)

			for _, path in { "Nick", "Team" } do
				local ok, reason = buy(harness, player, path)
				expect(ok).to.equal(false)
				expect(reason).to.equal(NOT_SPENDABLE)
			end

			harness.Cleanup()
		end)

		it("leaves an UNDECLARED dynamic ELEMENT answering exactly as before", function()
			-- The boundary, and it is a boundary in the schema rather than in the
			-- value. A declared CONTAINER has a ValueType of its own ("table"), so
			-- naming one as a cost path is a thing the library can describe: it is not
			-- spendable. An ELEMENT inside it has no declaration at all, and there the
			-- only honest answer is still the old one -- the balance read was not a
			-- number, and the library does not know why. The new reason must not leak
			-- into that arm, or it starts asserting knowledge it does not have.
			local harness = makeHarness()
			local player = harness.Join(94005)
			local data = harness.Data.Get(player)

			-- The container itself: declared, and declared as not a number.
			local okContainer, reasonContainer = buy(harness, player, "Bag")
			expect(okContainer).to.equal(false)
			expect(reasonContainer).to.equal(NOT_SPENDABLE)

			-- Written with a NUMBER: a dynamic element IS spendable, and stays so.
			data.Bag.Set({ Gold = 50 })
			expect(buy(harness, player, "Bag.Gold")).to.equal(true)
			expect(data.Bag.Gold.Get()).to.equal(40)

			-- Written with something that is NOT a number. The library has no declared
			-- ValueType here, so all it can honestly say is that the balance it read
			-- was not a number -- the old string, unchanged.
			data.Bag.Set({ Gold = 50, Sigil = "rune" })
			local okText, reasonText = buy(harness, player, "Bag.Sigil")
			expect(okText).to.equal(false)
			expect(reasonText).to.equal(INVALID_PATH)

			harness.Cleanup()
		end)

		it("keeps insufficient funds distinct from both", function()
			-- Last control: the three refusals stay three refusals.
			local harness = makeHarness()
			local player = harness.Join(94006)
			harness.Data.Get(player).Coins.Set(5)

			local ok, reason = buy(harness, player, "Coins")
			expect(ok).to.equal(false)
			expect(reason).to.equal(Scribe.PurchaseReason.InsufficientFunds)

			harness.Cleanup()
		end)
	end)
end
