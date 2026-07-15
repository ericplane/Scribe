--!nonstrict
-- Receipt and gift handling. Receipts are fail-closed: PurchaseGranted only
-- after a durable commit; Robux are never eaten.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

	local promptLog

	local function makeHarness(extraOptions)
		promptLog = {}
		local options = {
			Products = {
				Coins1000 = {
					Id = 111,
					Category = "Currency",
					Grant = function(data)
						data.Coins.Increment(1000)
					end,
				},
				GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
			},
			GiftCooldown = 0,
			PromptProductPurchase = function(player, productId)
				table.insert(promptLog, { Player = player, ProductId = productId })
			end,
		}
		for key, value in extraOptions or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options })
	end

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

	it("grants, logs, dedupes, and auto-flushes a consumable purchase", function()
		local harness = makeHarness()
		local player, entry, data = harness.Join()

		local decision = harness.Data.HandleReceipt(receipt(entry.UserId, 111, "p-1"))
		expect(decision).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(1000)

		-- Auto-flush after the grant: already durably persisted.
		local persisted = harness.Fake.Persisted[`Default/PLAYER_{entry.UserId}`]
		expect(persisted.Coins).to.equal(1000)

		-- Tamper-proof Robux log entry.
		local purchases = harness.Data.GetPurchases(player, { Kind = "Robux" })
		expect(#purchases).to.equal(1)
		expect(purchases[1].PurchaseId).to.equal("p-1")
		expect(purchases[1].Product).to.equal("Coins1000")
		expect(purchases[1].PriceInRobux).to.equal(99)

		-- Duplicate receipt (retry) -> ack, no double grant.
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "p-1"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(1000)
		expect(#harness.Data.GetPurchases(player, { Kind = "Robux" })).to.equal(1)

		harness.Cleanup()
	end)

	it("returns NotProcessedYet while the grant cannot be durably committed", function()
		local harness = makeHarness()
		local _, entry, data = harness.Join()

		harness.Fake.FailSaves = true
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "p-2"))).to.equal(NOT_PROCESSED)

		-- The retry succeeds once saves recover — and stays exactly-once.
		harness.Fake.FailSaves = false
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "p-2"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(1000)

		harness.Cleanup()
	end)

	it("handles receipts after the player left: offline grant if expressible, else retry", function()
		local harness = makeHarness()

		-- Unknown profile: nothing to grant against.
		expect(harness.Data.HandleReceipt(receipt(31337, 222, "p-3"))).to.equal(NOT_PROCESSED)

		-- Perk products are safely expressible offline via UpdateOffline.
		local player = harness.Join(9001)
		harness.Data.Flush(player)
		harness.Leave(player)
		local key = `Default/PLAYER_9001`

		expect(harness.Data.HandleReceipt(receipt(9001, 222, "p-4"))).to.equal(GRANTED)
		local persisted = harness.Fake.Persisted[key]
		expect(persisted._Scribe.Perks.VIP).to.equal(true)

		-- Idempotent offline too.
		expect(harness.Data.HandleReceipt(receipt(9001, 222, "p-4"))).to.equal(GRANTED)

		-- Consumable Grant functions need a live tree -> NotProcessedYet;
		-- Roblox retries on their next session.
		expect(harness.Data.HandleReceipt(receipt(9001, 111, "p-5"))).to.equal(NOT_PROCESSED)
		expect(harness.Fake.Persisted[key].Coins).to.equal(0)

		-- ...and on the next session the retry grants.
		local player2, _, data2 = harness.Join(9001)
		expect(harness.Data.HandleReceipt(receipt(9001, 111, "p-5"))).to.equal(GRANTED)
		expect(data2.Coins.Get()).to.equal(1000)
		expect(harness.Data.Owns(player2, "VIP")).to.equal(true) -- offline perk arrived

		harness.Cleanup()
	end)

	it("refuses the gift prompt when the intent cannot be recorded", function()
		local harness = makeHarness()
		local buyer, entry = harness.Join()

		harness.Fake.FailSaves = true
		local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 777)
		expect(ok).to.equal(false)
		expect(string.find(tostring(reason), "intent") ~= nil).to.equal(true)
		expect(#promptLog).to.equal(0) -- PromptProductPurchase was never called
		expect(next(entry.LiveData._Scribe.PendingGifts)).to.equal(nil)
		harness.Fake.FailSaves = false

		harness.Cleanup()
	end)

	it("retries when gift delivery fails, keeping the intent, then delivers via mailbox", function()
		local harness = makeHarness()
		local buyer, entry = harness.Join()

		-- Record a durable intent for an offline recipient.
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 424242)).to.equal(true)
		expect(#promptLog).to.equal(1)
		expect(entry.LiveData._Scribe.PendingGifts["222"]).to.be.ok()

		harness.Fake.FailMessages = true
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "gift-1"))).to.equal(NOT_PROCESSED)
		expect(entry.LiveData._Scribe.PendingGifts["222"]).to.be.ok() -- intent persists

		-- Retry once delivery recovers.
		harness.Fake.FailMessages = false
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "gift-1"))).to.equal(GRANTED)
		expect(entry.LiveData._Scribe.PendingGifts["222"]).to.equal(nil)

		-- Buyer's side of the double-entry log.
		local sent = harness.Data.GetPurchases(buyer, { Kind = "Robux" })
		expect(sent[1].From.Type).to.equal("GiftSent")
		expect(sent[1].From.ToUserId).to.equal(424242)

		-- The offline recipient's mailbox delivers on their next load.
		local recipient = harness.Join(424242)
		expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)
		local received = harness.Data.GetPurchases(recipient, { Kind = "Robux" })
		expect(received[1].From.Type).to.equal("GiftReceived")
		expect(received[1].From.FromUserId).to.equal(entry.UserId)

		harness.Cleanup()
	end)

	it("delivers same-server gifts directly and fires OnGiftReceived", function()
		local harness = makeHarness()
		local buyer = harness.Join(2001)
		local recipient = harness.Join(2002)

		local giftEvent = nil
		harness.Data.OnGiftReceived:Connect(function(toPlayer, info)
			giftEvent = { Player = toPlayer, Info = info }
		end)

		expect(harness.Data.PromptGift(buyer, "GiftVIP", 2002)).to.equal(true)
		expect(harness.Data.HandleReceipt(receipt(2001, 222, "gift-2"))).to.equal(GRANTED)

		expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)
		task.wait()
		expect(giftEvent).to.be.ok()
		expect(giftEvent.Player).to.equal(recipient)
		expect(giftEvent.Info.FromUserId).to.equal(2001)

		harness.Cleanup()
	end)

	it("handles receipts with no gift intent: grant to buyer, or a gift credit when already owned", function()
		local harness = makeHarness()
		local buyer, _, _ = harness.Join()

		-- Buyer does not own the perk: grant to buyer (real value received).
		expect(harness.Data.HandleReceipt(receipt(harness.Ctx.Persistence.EntryFor(buyer).UserId, 222, "ni-1"))).to.equal(GRANTED)
		expect(harness.Data.Owns(buyer, "VIP")).to.equal(true)

		-- Buyer already owns it: a no-op grant would burn Robux — issue a
		-- durable gift credit instead.
		local creditEvent = nil
		harness.Data.OnGiftCredit:Connect(function(player, productName)
			creditEvent = { Player = player, Product = productName }
		end)
		local entry = harness.Ctx.Persistence.EntryFor(buyer)
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "ni-2"))).to.equal(GRANTED)
		expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(1)
		task.wait()
		expect(creditEvent).to.be.ok()
		expect(creditEvent.Product).to.equal("GiftVIP")

		-- A later PromptGift consumes the credit — no prompt, no charge.
		local recipient = harness.Join(3003)
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 3003)).to.equal(true)
		expect(#promptLog).to.equal(0)
		expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)
		expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(nil)

		harness.Cleanup()
	end)

	it("declines a no-intent purchase while an unused gift credit is pending", function()
		local harness = makeHarness()
		local buyer, entry = harness.Join()
		harness.Data.GrantPerk(buyer, "VIP")

		-- First no-intent purchase converts to a credit (buyer owns the perk).
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "pc-1"))).to.equal(GRANTED)
		expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(1)

		-- A second purchase while that credit is unused could only stack
		-- another credit: declined, nothing stacked, logged, or marked
		-- processed — the unprocessed purchase is refunded by Roblox.
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "pc-2"))).to.equal(NOT_PROCESSED)
		expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(1)
		expect(#harness.Data.GetPurchases(buyer, { Kind = "Robux" })).to.equal(1)
		expect(#Scribe.GetRecentLogs({ Code = "RECEIPT_DECLINED_PENDING_CREDIT", Limit = 3 }) > 0).to.equal(true)

		-- Once the credit is spent, the retried receipt processes normally
		-- and converts to a fresh credit.
		harness.Join(6001)
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 6001)).to.equal(true)
		expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(nil)
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "pc-2"))).to.equal(GRANTED)
		expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(1)

		harness.Cleanup()
	end)

	it("declines an offline no-intent purchase while a credit is pending", function()
		local harness = makeHarness()
		local buyer = harness.Join(6100)
		harness.Data.GrantPerk(buyer, "VIP")
		expect(harness.Data.HandleReceipt(receipt(6100, 222, "pc-3"))).to.equal(GRANTED) -- credit issued
		harness.Data.Flush(buyer)
		harness.Leave(buyer)

		expect(harness.Data.HandleReceipt(receipt(6100, 222, "pc-4"))).to.equal(NOT_PROCESSED)
		local persisted = harness.Fake.Persisted["Default/PLAYER_6100"]
		expect(persisted._Scribe.GiftCredits.GiftVIP).to.equal(1) -- unchanged
		expect(table.find(persisted._Scribe.ProcessedPurchaseIds, "pc-4")).to.equal(nil)

		harness.Cleanup()
	end)

	it("keeps retrying unresolved gift receipts under the Hold policy", function()
		local harness = makeHarness({ NoGiftIntentPolicy = "Hold" })
		local buyer, entry = harness.Join()
		harness.Data.GrantPerk(buyer, "VIP")

		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "hold-1"))).to.equal(NOT_PROCESSED)
		expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(nil)

		harness.Cleanup()
	end)

	it("expires stale gift intents; the purchase follows the no-intent policy", function()
		local harness = makeHarness({ GiftIntentTTL = 60 })
		local buyer, entry = harness.Join()

		expect(harness.Data.PromptGift(buyer, "GiftVIP", 555555)).to.equal(true)
		-- Abandoned prompt: backdate the intent past the TTL.
		entry.LiveData._Scribe.PendingGifts["222"].Ts = os.time() - 120

		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "stale-1"))).to.equal(GRANTED)
		-- Fell back to grant-to-buyer; the stale recipient got nothing.
		expect(harness.Data.Owns(buyer, "VIP")).to.equal(true)
		expect(entry.LiveData._Scribe.PendingGifts["222"]).to.equal(nil)
		local logs = Scribe.GetRecentLogs({ Code = "GIFT_INTENT_EXPIRED", Limit = 3 })
		expect(#logs > 0).to.equal(true)

		harness.Cleanup()
	end)

	it("refuses gifts to recipients who already own the perk", function()
		local harness = makeHarness()
		local buyer = harness.Join(4001)
		local recipient = harness.Join(4002)
		harness.Data.GrantPerk(recipient, "VIP")

		local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 4002)
		expect(ok).to.equal(false)
		expect(reason).to.equal("recipient already owns this")
		expect(#promptLog).to.equal(0)

		harness.Cleanup()
	end)

	it("converts a gift to a buyer credit when the recipient acquires the perk before the receipt", function()
		local harness = makeHarness()
		local buyer, buyerEntry = harness.Join(4101)
		local recipient = harness.Join(4102)

		-- Intent recorded while the recipient does NOT own the perk.
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 4102)).to.equal(true)
		expect(#promptLog).to.equal(1)

		-- The recipient acquires the perk while the buyer sits on the prompt.
		harness.Data.GrantPerk(recipient, "VIP")

		local creditEvent = nil
		harness.Data.OnGiftCredit:Connect(function(player, productName)
			creditEvent = { Player = player, Product = productName }
		end)

		expect(harness.Data.HandleReceipt(receipt(4101, 222, "cv-1"))).to.equal(GRANTED)

		-- No no-op delivery: the recipient has no GiftReceived entry.
		expect(#harness.Data.GetPurchases(recipient, { Kind = "Robux" })).to.equal(0)
		-- The buyer's payment became a re-aimable credit; the intent is gone.
		expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(1)
		expect(buyerEntry.LiveData._Scribe.PendingGifts["222"]).to.equal(nil)
		local logEntry = harness.Data.GetPurchases(buyer, { Kind = "Robux" })[1]
		expect(logEntry.From.Type).to.equal("GiftCredit")
		expect(logEntry.From.IntendedFor).to.equal(4102)
		task.wait()
		expect(creditEvent).to.be.ok()
		expect(creditEvent.Product).to.equal("GiftVIP")

		harness.Cleanup()
	end)

	it("converts to a credit offline too when the buyer left before the receipt", function()
		local harness = makeHarness()
		local buyer = harness.Join(4201)
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 4202)).to.equal(true)
		harness.Data.Flush(buyer)
		harness.Leave(buyer)

		-- Recipient acquires the perk before the buyer's receipt lands.
		local recipient = harness.Join(4202)
		harness.Data.GrantPerk(recipient, "VIP")

		expect(harness.Data.HandleReceipt(receipt(4201, 222, "cv-2"))).to.equal(GRANTED)
		local persisted = harness.Fake.Persisted["Default/PLAYER_4201"]
		expect(persisted._Scribe.GiftCredits.GiftVIP).to.equal(1)
		expect(next(persisted._Scribe.PendingGifts)).to.equal(nil)
		expect(#harness.Data.GetPurchases(recipient, { Kind = "Robux" })).to.equal(0)

		harness.Cleanup()
	end)

	it("still delivers to an owning recipient when AllowDuplicateGifts is on", function()
		local harness = makeHarness({ AllowDuplicateGifts = true })
		local buyer = harness.Join(4301)
		local recipient = harness.Join(4302)
		harness.Data.GrantPerk(recipient, "VIP")

		-- The prompt-time guard is skipped too under this option.
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 4302)).to.equal(true)
		expect(harness.Data.HandleReceipt(receipt(4301, 222, "cv-3"))).to.equal(GRANTED)

		-- Delivered as a real gift, no credit conversion.
		expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(nil)
		local received = harness.Data.GetPurchases(recipient, { Kind = "Robux" })
		expect(#received).to.equal(1)
		expect(received[1].From.Type).to.equal("GiftReceived")

		harness.Cleanup()
	end)

	it("refuses receipts for unregistered products (fail-closed)", function()
		local harness = makeHarness()
		local _, entry = harness.Join()
		expect(harness.Data.HandleReceipt(receipt(entry.UserId, 99999, "u-1"))).to.equal(NOT_PROCESSED)
		harness.Cleanup()
	end)

	it("Data.Purchase debits, grants, and logs atomically — full rollback on failure", function()
		local harness = makeHarness()
		local player, _, data = harness.Join()
		data.Coins.Set(500)

		-- Insufficient funds: nothing changes.
		local ok, reason = harness.Data.Purchase(player, {
			Cost = { Path = "Coins", Amount = 900 },
			Category = "Vehicle",
			ItemId = "Police01",
		})
		expect(ok).to.equal(false)
		expect(reason).to.equal("insufficient funds")
		expect(data.Coins.Get()).to.equal(500)
		expect(#harness.Data.GetPurchases(player, { Kind = "InGame" })).to.equal(0)

		-- A throwing Grant rolls back the debit and the log entry.
		local ok2 = harness.Data.Purchase(player, {
			Cost = { Path = "Coins", Amount = 100 },
			Category = "Vehicle",
			ItemId = "Broken",
			Grant = function()
				error("grant exploded")
			end,
		})
		expect(ok2).to.equal(false)
		expect(data.Coins.Get()).to.equal(500)
		expect(#harness.Data.GetPurchases(player, { Kind = "InGame" })).to.equal(0)

		-- Success: debit + grant + one log entry.
		local ok3 = harness.Data.Purchase(player, {
			Cost = { Path = "Coins", Amount = 100 },
			Category = "Vehicle",
			ItemId = "Police01",
			Grant = function(grantData)
				grantData.Quests.Insert("delivered")
			end,
			Meta = { Livery = "Standard" },
		})
		expect(ok3).to.equal(true)
		expect(data.Coins.Get()).to.equal(400)
		expect(data.Quests.Has("delivered")).to.equal(true)
		local logEntries = harness.Data.GetPurchases(player, { Kind = "InGame" })
		expect(#logEntries).to.equal(1)
		expect(logEntries[1].ItemId).to.equal("Police01")
		expect(logEntries[1].Amount).to.equal(100)
		expect(logEntries[1].Meta.Livery).to.equal("Standard")

		harness.Cleanup()
	end)
end
