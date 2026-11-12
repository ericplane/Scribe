--!nonstrict
-- Grant receives the buyer's data and Player for purchases, the recipient's for gifts.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local TestCtx = require(Root.Test.Helpers.TestCtx)

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local PACK = 551
local GIFT = 552
local BUYER = 95501
local RECIPIENT = 95502

local function receipt(userId, productId, purchaseId)
	return {
		PlayerId = userId,
		ProductId = productId,
		PurchaseId = purchaseId,
		CurrencySpent = 99,
		CurrencyType = Enum.CurrencyType.Robux,
		PlaceIdWherePurchased = 0,
	}
end

local function makeHarness()
	local calls = {}
	local harness
	local function record(label)
		return function(data, player)
			local who = if player then player.UserId else "nil"
			local owner = if player then harness.Data.Get(player) else nil
			table.insert(calls, `{label}:{who}:{owner ~= nil and rawequal(owner, data)}`)
			data.Coins.Increment(1)
		end
	end
	harness = TestCtx.make({
		Options = {
			Products = {
				Pack = { Id = PACK, Grant = record("pack") },
				Gift = { Id = GIFT, Grant = record("gift") },
			},
			GiftCooldown = 0,
			PromptProductPurchase = function() end,
		},
	})
	harness.Calls = calls
	harness.Record = record
	return harness
end

describe("Grant receives the player", function()
	it("is the buyer for a product receipt", function()
		local harness = makeHarness()
		harness.Join(BUYER)
		local decision = harness.Data.HandleReceipt(receipt(BUYER, PACK, "pid-pack"))
		expect(`{decision == GRANTED} {table.concat(harness.Calls, ",")}`).toBe(`true pack:{BUYER}:true`)
		harness.Cleanup()
	end)

	it("is the recipient for a gift, not the buyer", function()
		local harness = makeHarness()
		local buyer, entry = harness.Join(BUYER)
		entry.Tree.Reserved.GiftCredits.Gift.Set(1)
		expect(harness.Data.Flush(buyer, { Force = true })).toBe(true)
		harness.Join(RECIPIENT)
		expect((harness.Data.PromptGift(buyer, "Gift", RECIPIENT))).toBe(true)
		expect(table.concat(harness.Calls, ",")).toBe(`gift:{RECIPIENT}:true`)
		harness.Cleanup()
	end)

	it("is the buyer for a Data.Purchase spec", function()
		local harness = makeHarness()
		local player, _, data = harness.Join(BUYER)
		data.Coins.Set(10)
		local ok = harness.Data.Purchase(player, {
			Cost = { Path = "Coins", Amount = 5 },
			ItemId = "Sword",
			Grant = harness.Record("purchase"),
		})
		expect(`{ok} {table.concat(harness.Calls, ",")}`).toBe(`true purchase:{BUYER}:true`)
		harness.Cleanup()
	end)

	it("still runs a Grant that takes only the data", function()
		local harness = TestCtx.make({
			Options = {
				Products = {
					Pack = {
						Id = PACK,
						Grant = function(data)
							data.Coins.Increment(7)
						end,
					},
				},
			},
		})
		local _, _, data = harness.Join(BUYER)
		local decision = harness.Data.HandleReceipt(receipt(BUYER, PACK, "pid-one-arg"))
		expect(`{decision == GRANTED} {data.Coins.Get()}`).toBe("true 7")
		harness.Cleanup()
	end)
end)
