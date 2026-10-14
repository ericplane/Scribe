--!nonstrict
-- Pass, perk and gift-credit names must not resolve to accessor methods.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Clock = require(Root.Scribe.Internal.Clock)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local harness: any = nil

afterEach(function()
	if harness then
		harness.Cleanup()
		harness = nil
	end
end)

describe("a pass or perk named like an accessor method", function()
	it("is cached as owned, and the ownership sync completes", function()
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = {
				Passes = { Count = { Id = 9001 }, VIP = { Id = 9002 } },
				UserOwnsGamePassAsync = function()
					return true
				end,
			},
		})
		local player, entry = harness.Join(88901)
		task.wait()
		local session = entry.SessionStore._ScribeSession
		expect(
			`Count={harness.Data.Owns(player, "Count")} VIP={harness.Data.Owns(player, "VIP")} `
				.. `cached={session.OwnsCache.Count} synced={session.OwnsSynced}`
		).toBe("Count=true VIP=true cached=true synced=true")
	end)

	it("completes the ownership sync when the player does not own it", function()
		-- A false ownership response also reads the cache; both lookups must use Child.
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = {
				Passes = { Count = { Id = 9003 } },
				UserOwnsGamePassAsync = function()
					return false
				end,
			},
		})
		local player, entry = harness.Join(88903)
		task.wait()
		local session = entry.SessionStore._ScribeSession
		expect(`owns={harness.Data.Owns(player, "Count")} synced={session.OwnsSynced}`).toBe("owns=false synced=true")
	end)

	it("is granted by a product's Grants on purchase", function()
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = {
				Perks = { "Count" },
				Products = { CountPass = { Id = 9004, Category = "Gamepass", Grants = "Count" } },
				PromptProductPurchase = function() end,
			},
		})
		local player, entry = harness.Join(88904)
		local decision = harness.Data.HandleReceipt({
			PlayerId = entry.UserId,
			ProductId = 9004,
			PurchaseId = "count-1",
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		})
		expect(
			`granted={decision == Enum.ProductPurchaseDecision.PurchaseGranted} owns={harness.Data.Owns(player, "Count")}`
		).toBe("granted=true owns=true")
	end)

	it("spends a gift credit for a product named like a method", function()
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = {
				Products = {
					Clear = {
						Id = 9005,
						Category = "Currency",
						Grant = function(data)
							data.Coins.Increment(1000)
						end,
					},
				},
				GiftCooldown = 0,
				PromptProductPurchase = function() end,
			},
		})
		local buyer, buyerEntry = harness.Join(88905)
		buyerEntry.Tree.Reserved.GiftCredits.Child("Clear").Set(1)
		expect(harness.Data.Flush(buyer, { Force = true })).toBe(true)
		local _recipient, _recipientEntry, recipientData = harness.Join(88906)
		local ok, reason = harness.Data.PromptGift(buyer, "Clear", 88906)
		local left = tonumber(harness.Data.GetGiftCredits(buyer).Clear) or 0
		expect(`ok={ok} reason={reason} credits={left} coins={recipientData.Coins.Get()}`).toBe(
			"ok=true reason=nil credits=0 coins=1000"
		)
	end)

	it("credits a perk product named like a method that the buyer already owns", function()
		-- An already-owned perk becomes a gift credit instead of a no-op grant.
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = {
				Perks = { "VIP" },
				Products = { Clear = { Id = 9006, Category = "Gamepass", Grants = "VIP" } },
				PromptProductPurchase = function() end,
			},
		})
		local player, entry = harness.Join(88907)
		harness.Data.GrantPerk(player, "VIP")
		local decision = harness.Data.HandleReceipt({
			PlayerId = entry.UserId,
			ProductId = 9006,
			PurchaseId = "clear-1",
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		})
		local credits = tonumber(harness.Data.GetGiftCredits(player).Clear) or 0
		expect(`granted={decision == Enum.ProductPurchaseDecision.PurchaseGranted} credits={credits}`).toBe(
			"granted=true credits=1"
		)
	end)

	it("converts a gift to a credit for a product named like a method", function()
		-- An already-owned gift becomes a credit for the buyer.
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = {
				Products = { Clear = { Id = 9007, Category = "Gamepass", Grants = "VIP" } },
				GiftCooldown = 0,
				PromptProductPurchase = function() end,
			},
		})
		local function receipt(userId: number, purchaseId: string)
			return {
				PlayerId = userId,
				ProductId = 9007,
				PurchaseId = purchaseId,
				CurrencySpent = 99,
				CurrencyType = Enum.CurrencyType.Robux,
				PlaceIdWherePurchased = 0,
			}
		end
		local buyer, buyerEntry = harness.Join(88908)
		buyerEntry.Tree.Reserved.PendingGifts["9007"].Set({
			RecipientId = 88909,
			GiftId = "gift-clear",
			Ts = Clock.Now(),
			Product = "Clear",
		})
		-- The recipient already owns the perk, durably, and is offline.
		local recipient = harness.Join(88909)
		harness.Data.HandleReceipt(receipt(88909, "seed-recipient-perk"))
		harness.Data.Flush(recipient)
		harness.Leave(recipient)
		local decision = harness.Data.HandleReceipt(receipt(88908, "gift-1"))
		local credits = tonumber(harness.Data.GetGiftCredits(buyer).Clear) or 0
		expect(`granted={decision == Enum.ProductPurchaseDecision.PurchaseGranted} credits={credits}`).toBe(
			"granted=true credits=1"
		)
	end)

	it("is granted and revoked as a perk", function()
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { Perks = { "Get", "Clear" } },
		})
		local player = harness.Join(88902)
		local granted = pcall(harness.Data.GrantPerk, player, "Get")
		local owned = harness.Data.Owns(player, "Get")
		local revoked = pcall(harness.Data.RevokePerk, player, "Get")
		expect(`granted={granted} owned={owned} revoked={revoked} after={harness.Data.Owns(player, "Get")}`).toBe(
			"granted=true owned=true revoked=true after=false"
		)
	end)
end)
