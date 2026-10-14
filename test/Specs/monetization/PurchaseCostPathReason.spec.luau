--!nonstrict
-- Distinguish invalid paths from unspendable fields. Big currencies are spendable.
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
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

		expect((buy(harness, player, "Coins"))).toBe(true)
		expect(data.Coins.Get()).toBe(90)
		expect((buy(harness, player, "Score"))).toBe(true)
		expect(data.Score.Get()).toBe(90)

		harness.Cleanup()
	end)

	it("still says 'invalid cost path' for a path that names nothing", function()
		-- The other control: the string keeps its meaning for the case it was
		-- written for. A fix that renamed every refusal would fail here.
		local harness = makeHarness()
		local player = harness.Join(94002)

		local ok, reason = buy(harness, player, "NoSuchField")
		expect(ok).toBe(false)
		expect(reason).toBe(INVALID_PATH)

		harness.Cleanup()
	end)

	it("spends from a declared Scribe.Big, which is no longer refused at all", function()
		-- Big currencies must pass both path and spendability checks.
		local harness = makeHarness()
		local player, entry = harness.Join(94003)

		local ok, reason = buy(harness, player, "Prestige")
		local observed = `ok={tostring(ok)} reason={tostring(reason)} `
			.. `prestige={tostring(harness.Data.Get(player).Prestige.Get())} dead={tostring(entry.Tree.Dead)}`
		harness.Cleanup()
		expect(observed).toBe("ok=true reason=nil prestige=990 dead=false")
	end)

	it("says the path is not SPENDABLE for declared non-numeric fields", function()
		-- Check each supported nonnumeric field type.
		local harness = makeHarness()
		local player = harness.Join(94004)

		for _, path in { "Nick", "Team" } do
			local ok, reason = buy(harness, player, path)
			expect(ok).toBe(false)
			expect(reason).toBe(NOT_SPENDABLE)
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
		expect(okContainer).toBe(false)
		expect(reasonContainer).toBe(NOT_SPENDABLE)

		-- Written with a NUMBER: a dynamic element IS spendable, and stays so.
		data.Bag.Set({ Gold = 50 })
		expect((buy(harness, player, "Bag.Gold"))).toBe(true)
		expect(data.Bag.Gold.Get()).toBe(40)

		-- Written with something that is NOT a number. The library has no declared
		-- ValueType here, so all it can honestly say is that the balance it read
		-- was not a number -- the old string, unchanged.
		data.Bag.Set({ Gold = 50, Sigil = "rune" })
		local okText, reasonText = buy(harness, player, "Bag.Sigil")
		expect(okText).toBe(false)
		expect(reasonText).toBe(INVALID_PATH)

		harness.Cleanup()
	end)

	it("keeps insufficient funds distinct from both", function()
		-- Last control: the three refusals stay three refusals.
		local harness = makeHarness()
		local player = harness.Join(94006)
		harness.Data.Get(player).Coins.Set(5)

		local ok, reason = buy(harness, player, "Coins")
		expect(ok).toBe(false)
		expect(reason).toBe(Scribe.PurchaseReason.InsufficientFunds)

		harness.Cleanup()
	end)
end)
