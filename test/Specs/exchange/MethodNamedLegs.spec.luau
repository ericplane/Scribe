--!nonstrict
-- Exchange item keys and stack fields can share names with accessor methods.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any
local TestCtx = require(Root.Test.Helpers.TestCtx)

local TEMPLATE = {
	Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
	Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 6 }),
	Materials = Scribe.DictOf(Scribe.Int(0, { Min = 0 })),
}

local EXCHANGEABLE = {
	Item = { Path = { "Inventory" }, Kind = "Key" },
	Mat = { Path = { "Materials" }, Kind = "Stack" },
	Money = { Path = { "Coins" }, Kind = "Qty" },
}

describe("an exchange leg keyed by an accessor method name", function()
	for _, key in { "blade", "Count", "Get", "Max" } do
		it(`moves the Key leg "{key}"`, function()
			local harness = TestCtx.make({ Template = TEMPLATE, Options = { Exchangeable = EXCHANGEABLE } })
			local ok, err = pcall(function()
				local pa = harness.Join(92301)
				local pb = harness.Join(92302)
				local da, db = harness.Data.Get(pa), harness.Data.Get(pb)
				da.Inventory.Child(key).Set({ Qty = 1 })
				db.Coins.Set(100)
				local outcome, _why = harness.Data.Exchange.Attempt(
					pa,
					{ { Path = { "Inventory" }, Kind = "Key", Key = key } },
					pb,
					{ { Path = { "Coins" }, Kind = "Qty", Amount = 50 } }
				)
				local aHas = da.Inventory.Child(key).Get() ~= nil
				local bHas = db.Inventory.Child(key).Get() ~= nil
				expect(`{tostring(outcome)} aHas={aHas} bHas={bHas}`).toBe("Committed aHas=false bHas=true")
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end)
	end
end)

describe("a Stack leg whose key or count field is an accessor method name", function()
	for _, case in
		{
			{ Label = "scalar key ore", Path = "Materials", Key = "ore" },
			{ Label = "scalar key Max", Path = "Materials", Key = "Max" },
			{ Label = "record count field Qty", Path = "Bag", Key = "ore" },
			{ Label = "record count field Count", Path = "Crate", Key = "ore" },
		}
	do
		it(`splits a stack: {case.Label}`, function()
			local harness = TestCtx.make({
				Template = {
					Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
					Materials = Scribe.DictOf(Scribe.Int(0, { Min = 0, Max = 999 })),
					Bag = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }),
					Crate = Scribe.DictOf({ Count = Scribe.Int(1, { Min = 1, Max = 99 }) }),
				},
				Options = {
					Exchangeable = {
						Mat = { Path = { "Materials" }, Kind = "Stack" },
						BagStack = { Path = { "Bag" }, Kind = "Stack", Count = "Qty" },
						CrateStack = { Path = { "Crate" }, Kind = "Stack", Count = "Count" },
						Money = { Path = { "Coins" }, Kind = "Qty" },
					},
				},
			})
			local ok, err = pcall(function()
				local pa = harness.Join(92311)
				local pb = harness.Join(92312)
				local da, db = harness.Data.Get(pa), harness.Data.Get(pb)
				if case.Path == "Materials" then
					da.Materials.Child(case.Key).Set(10)
				elseif case.Path == "Bag" then
					da.Bag.Child(case.Key).Set({ Qty = 10 })
				else
					da.Crate.Child(case.Key).Set({ Count = 10 })
				end
				db.Coins.Set(100)
				local outcome, _why = harness.Data.Exchange.Attempt(
					pa,
					{ { Path = { case.Path }, Kind = "Stack", Key = case.Key, Amount = 4 } },
					pb,
					{ { Path = { "Coins" }, Kind = "Qty", Amount = 50 } }
				)
				expect(tostring(outcome)).toBe("Committed")
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end)
	end
end)

describe("a whole-stack move onto a held stack whose count field is named Count", function()
	for _, case in
		{
			{ Label = "Qty", Path = "Bag", Field = "Qty" },
			{ Label = "Count", Path = "Crate", Field = "Count" },
		}
	do
		it(`merges into the receiver's stack: count field {case.Label}`, function()
			local harness = TestCtx.make({
				Template = {
					Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
					Bag = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }),
					Crate = Scribe.DictOf({ Count = Scribe.Int(1, { Min = 1, Max = 99 }) }),
				},
				Options = {
					Exchangeable = {
						BagStack = { Path = { "Bag" }, Kind = "Stack", Count = "Qty" },
						CrateStack = { Path = { "Crate" }, Kind = "Stack", Count = "Count" },
						Money = { Path = { "Coins" }, Kind = "Qty" },
					},
				},
			})
			local ok, err = pcall(function()
				local pa = harness.Join(92321)
				local pb = harness.Join(92322)
				local da, db = harness.Data.Get(pa), harness.Data.Get(pb)
				da[case.Path].Child("ore").Set({ [case.Field] = 10 })
				db[case.Path].Child("ore").Set({ [case.Field] = 3 })
				db.Coins.Set(100)
				local outcome, _why = harness.Data.Exchange.Attempt(
					pa,
					{ { Path = { case.Path }, Kind = "Stack", Key = "ore", Amount = 10 } },
					pb,
					{ { Path = { "Coins" }, Kind = "Qty", Amount = 50 } }
				)
				local aOre = da[case.Path].Child("ore").Get()
				local bOre = db[case.Path].Child("ore").Get()
				local aHeld = if aOre then aOre[case.Field] else nil
				local bHeld = if bOre then bOre[case.Field] else nil
				local entryA = harness.Ctx.Persistence.EntryFor(pa)
				local entryB = harness.Ctx.Persistence.EntryFor(pb)
				local inboxB = 0
				for _ in entryB.LiveData._Scribe.ExchangeInbox do
					inboxB += 1
				end
				local escrowA = 0
				for _ in entryA.LiveData._Scribe.Exchange do
					escrowA += 1
				end
				expect(`{tostring(outcome)} aOre={tostring(aHeld)} bOre={tostring(bHeld)}`).toBe(
					"Committed aOre=nil bOre=13"
				)
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end)
	end
end)

describe("an exchange leg whose container sits under a field named like a method", function()
	it("moves a Key leg out of Bags.Max", function()
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
				Bags = { Max = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 6 }) },
			},
			Options = {
				Exchangeable = {
					Item = { Path = { "Bags", "Max" }, Kind = "Key" },
					Money = { Path = { "Coins" }, Kind = "Qty" },
				},
			},
		})
		local ok, err = pcall(function()
			local pa = harness.Join(92401)
			local pb = harness.Join(92402)
			local da, db = harness.Data.Get(pa), harness.Data.Get(pb)
			da.Bags.Child("Max").Child("blade").Set({ Qty = 1 })
			db.Coins.Set(100)
			local outcome = harness.Data.Exchange.Attempt(
				pa,
				{ { Path = { "Bags", "Max" }, Kind = "Key", Key = "blade" } },
				pb,
				{ { Path = { "Coins" }, Kind = "Qty", Amount = 50 } }
			)
			local bHas = db.Bags.Child("Max").Child("blade").Get() ~= nil
			expect(`{tostring(outcome)} bHas={bHas}`).toBe("Committed bHas=true")
		end)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end)
end)
