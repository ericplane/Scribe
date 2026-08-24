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
		local make: { [string]: any } = { Options = options }
		if extraOptions and extraOptions.Fake then
			make.Fake = extraOptions.Fake
			options.Fake = nil
		end
		return TestCtx.make(make)
	end

	-- The dedupe ring stores `{ Id, At }`, and still has to read bare strings
	-- written before age-based eviction shipped.
	local function processedIds(list)
		local out = {}
		for _, item in list or {} do
			table.insert(out, if type(item) == "string" then item else item.Id)
		end
		return out
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

	it("grants an offline receipt once when another server commits between the two reads", function()
		-- The offline path decides from a GetOffline snapshot and then commits through
		-- UpdateOffline, which takes its OWN read inside the compare-and-set. Two
		-- reads, and the ordering that bites is the one in between:
		--
		--   B reads to decide      -> no marker, so B will grant
		--   A grants and commits   -> marker written, fingerprint moved
		--   B reads to commit      -> the marker IS in B's draft, and the fingerprint
		--                             B compares against is the FRESH one, so the CAS
		--                             passes and B grants again
		--
		-- The compare-and-set cannot catch this: B's fingerprint is current by the
		-- time it commits. Only re-reading the dedupe marker INSIDE the transaction
		-- can. (The other ordering -- B taking its commit read BEFORE A lands -- IS
		-- caught by the CAS, refuses, and Roblox retries into the snapshot check.)
		--
		-- The second grant is not a second perk: the in-transaction check that DOES
		-- exist sees the perk already set and mints a GIFT CREDIT instead. So the
		-- damage is a credit the player never paid for, which is what this asserts.
		--
		-- Only a perk product is expressible offline at all -- a Grant callback needs
		-- a live accessor tree -- so 222 rather than 111.
		local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
		local fake = FakeProfileStore.new()
		local a = makeHarness({ Fake = fake })
		local b = makeHarness({ Fake = fake })

		local seeded = a.Join(70013)
		a.Data.Flush(seeded)
		a.Leave(seeded)

		local reads = 0
		fake.MidRead = function()
			reads += 1
			if reads == 2 then
				-- B is about to take its COMMIT read. A's whole receipt lands first.
				fake.MidRead = nil
				a.Data.HandleReceipt(receipt(70013, 222, "pid-offline-race"))
			end
		end
		local decision = b.Data.HandleReceipt(receipt(70013, 222, "pid-offline-race"))
		fake.MidRead = nil

		local reserved = fake.Persisted["Default/PLAYER_70013"]._Scribe
		local credits = 0
		for _, n in reserved.GiftCredits or {} do
			credits += tonumber(n) or 0
		end
		local markers = 0
		for _, id in processedIds(reserved.ProcessedPurchaseIds) do
			if id == "pid-offline-race" then
				markers += 1
			end
		end

		expect(`granted={decision == GRANTED} credits={credits} markers={markers}`).to.equal(
			"granted=true credits=0 markers=1"
		)

		b.Cleanup()
		a.Cleanup()
	end)

	-- The same race, on the two GIFT commit closures. The test above drives only the
	-- PERK closure -- a gift needs a live intent, which it never creates -- so
	-- dropping the re-check from either gift closure alone left the suite green.
	-- Measured, both individually: 1351/0.
	--
	-- Shared setup: the buyer creates a live gift intent and then LEAVES, so the
	-- receipt arrives on the offline path with an intent waiting for it.
	local function offlineGiftRace(purchaseId: string, buyerId: number, recipientId: number, seedRecipient: boolean?)
		local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
		local fake = FakeProfileStore.new()
		local a = makeHarness({ Fake = fake })
		local b = makeHarness({ Fake = fake })

		local buyer = a.Join(buyerId)
		if a.Data.PromptGift(buyer, "GiftVIP", recipientId) ~= true then
			error("offlineGiftRace: PromptGift did not create an intent", 2)
		end
		a.Data.Flush(buyer)
		a.Leave(buyer)

		if seedRecipient then
			-- The recipient acquires the perk AFTER the intent exists -- which is the
			-- only order that reaches the already-owns branch, because PromptGift
			-- refuses to create an intent for something the recipient already has.
			local recipient = a.Join(recipientId)
			a.Data.HandleReceipt(receipt(recipientId, 222, `{purchaseId}-seed`))
			a.Data.Flush(recipient)
			a.Leave(recipient)
		end

		-- Fire A's identical receipt on B's COMMIT read of the buyer's key -- the one
		-- ordering the compare-and-set cannot catch, because by then B's fingerprint
		-- is the fresh one.
		local key = `PLAYER_{buyerId}`
		local reads = 0
		fake.MidRead = function(profileKey: string)
			if profileKey ~= key then
				return
			end
			reads += 1
			if reads == 2 then
				fake.MidRead = nil
				a.Data.HandleReceipt(receipt(buyerId, 222, purchaseId))
			end
		end
		local decision = b.Data.HandleReceipt(receipt(buyerId, 222, purchaseId))
		fake.MidRead = nil

		local reserved = fake.Persisted[`Default/PLAYER_{buyerId}`]._Scribe
		local markers = 0
		for _, id in processedIds(reserved.ProcessedPurchaseIds) do
			if id == purchaseId then
				markers += 1
			end
		end
		local credits = 0
		for _, n in reserved.GiftCredits or {} do
			credits += tonumber(n) or 0
		end
		local sends = 0
		for _, line in reserved.PurchaseLogs and reserved.PurchaseLogs.Robux or {} do
			if line.PurchaseId == purchaseId then
				sends += 1
			end
		end
		b.Cleanup()
		a.Cleanup()
		return decision, markers, credits, sends
	end

	it("grants an offline GIFT receipt once when another server commits between the two reads", function()
		-- Pins the in-transaction re-check in the gift DELIVERY closure.
		local decision, markers, credits, sends = offlineGiftRace("pid-gift-race", 70021, 70022)
		expect(`granted={decision == GRANTED} markers={markers} credits={credits} logged={sends}`).to.equal(
			"granted=true markers=1 credits=0 logged=1"
		)
	end)

	it("mints one gift credit, not two, when the recipient already owns it and two servers race", function()
		-- Pins the in-transaction re-check in the already-owns closure. Without it the
		-- buyer is handed a second credit they never paid for -- the same damage the
		-- perk-path test above measures, on a different closure.
		local decision, markers, credits, sends = offlineGiftRace("pid-owned-race", 70031, 70032, true)
		expect(`granted={decision == GRANTED} markers={markers} credits={credits} logged={sends}`).to.equal(
			"granted=true markers=1 credits=1 logged=1"
		)
	end)

	it("TryHandleReceipt falls through on an unknown product, HandleReceipt does not", function()
		local harness = makeHarness({ OwnReceipts = false })
		local _, entry, data = harness.Join(77001)
		local uid = entry.UserId

		-- An UNREGISTERED product. HandleReceipt is for the case where Scribe owns
		-- ProcessReceipt, so an unknown product is a config error: it answers
		-- NotProcessedYet, which makes Roblox retry rather than eat the Robux.
		expect(harness.Data.HandleReceipt(receipt(uid, 999, "p-unknown-1"))).to.equal(NOT_PROCESSED)

		-- TryHandleReceipt is for an external router, where an unknown product just
		-- is not ours. Returning nil lets the router fall through to its own
		-- handler; NotProcessedYet there would stall the router's own purchase in a
		-- permanent retry loop.
		expect(harness.Data.TryHandleReceipt(receipt(uid, 999, "p-unknown-2"))).to.equal(nil)

		-- A REGISTERED product behaves identically through both entry points.
		expect(harness.Data.TryHandleReceipt(receipt(uid, 111, "p-known-1"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(1000)
		expect(harness.Data.HandleReceipt(receipt(uid, 111, "p-known-2"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(2000)

		harness.Cleanup()
	end)

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
		expect(harness.Data.HandleReceipt(receipt(harness.Ctx.Persistence.EntryFor(buyer).UserId, 222, "ni-1"))).to.equal(
			GRANTED
		)
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
		expect(table.find(processedIds(persisted._Scribe.ProcessedPurchaseIds), "pc-4")).to.equal(nil)

		harness.Cleanup()
	end)

	describe("dedupe ring eviction", function()
		it("still dedupes a receipt whose id was stored as a bare legacy string", function()
			local harness = makeHarness()
			local _, entry, data = harness.Join(6300)
			-- Exactly what a profile written before age-based eviction carries.
			entry.LiveData._Scribe.ProcessedPurchaseIds = { "legacy-1" }

			-- A retry of that purchase must be recognised as already granted, not
			-- re-granted: this is the whole reason the ring exists.
			local before = data.Coins.Get()
			expect(harness.Data.HandleReceipt(receipt(6300, 111, "legacy-1"))).to.equal(GRANTED)
			expect(data.Coins.Get()).to.equal(before)

			harness.Cleanup()
		end)

		it("stamps a legacy entry rather than assuming it is old enough to drop", function()
			local harness = makeHarness()
			local _, entry, data = harness.Join(6301)
			entry.LiveData._Scribe.ProcessedPurchaseIds = { "legacy-1" }

			harness.Data.HandleReceipt(receipt(6301, 111, "new-1"))

			local list = data._Scribe.ProcessedPurchaseIds.Get()
			expect(#list).to.equal(2) -- legacy survived; guessing "old" is what double-grants
			expect(list[1].Id).to.equal("legacy-1")
			expect(type(list[1].At)).to.equal("number")

			harness.Cleanup()
		end)

		it("drops entries past PurchaseIdTTL and keeps the ones still inside it", function()
			local harness = makeHarness({ PurchaseIdTTL = 100 })
			local _, entry, data = harness.Join(6302)
			local now = os.time()
			entry.LiveData._Scribe.ProcessedPurchaseIds = {
				{ Id = "expired", At = now - 500 },
				{ Id = "fresh", At = now - 10 },
			}

			harness.Data.HandleReceipt(receipt(6302, 111, "new-1"))

			local ids = processedIds(data._Scribe.ProcessedPurchaseIds.Get())
			expect(table.find(ids, "expired")).to.equal(nil)
			expect(table.find(ids, "fresh")).never.to.equal(nil)
			expect(table.find(ids, "new-1")).never.to.equal(nil)

			harness.Cleanup()
		end)

		it("warns when the count backstop evicts an un-expired id", function()
			-- A cap of 3 with a long TTL: nothing ages out, so the backstop is the
			-- only thing that can make room -- the one eviction that can double-grant.
			local harness = makeHarness({ MaxProcessedPurchaseIds = 3, PurchaseIdTTL = 999999 })
			local _, entry, data = harness.Join(6303)
			local now = os.time()
			entry.LiveData._Scribe.ProcessedPurchaseIds = {
				{ Id = "a", At = now },
				{ Id = "b", At = now },
				{ Id = "c", At = now },
			}
			local before = Scribe.GetMetrics().PurchaseIdsEvicted or 0

			harness.Data.HandleReceipt(receipt(6303, 111, "new-1"))

			local ids = processedIds(data._Scribe.ProcessedPurchaseIds.Get())
			expect(table.find(ids, "a")).to.equal(nil) -- oldest dropped
			expect(table.find(ids, "new-1")).never.to.equal(nil)
			-- Silence here was the actual defect: the dangerous eviction now reports.
			expect((Scribe.GetMetrics().PurchaseIdsEvicted or 0) - before).to.equal(1)

			harness.Cleanup()
		end)
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

	it("keeps a paid gift retryable when the recipient's message queue is full", function()
		-- The escrow protocol's whole point, and the half that was broken: delivery to
		-- an offline recipient goes through MessageAsync, which used to answer TRUE
		-- after silently dropping the recipient's OLDEST queued message. deliverGift
		-- treats that true as durable and CLEARS the buyer's escrow intent -- so a
		-- gift the player paid Robux for was destroyed, with nothing anywhere
		-- recording it.
		--
		-- The brief asks for this to be verified rather than assumed, so it is: the
		-- intent must SURVIVE the refusal, the receipt must answer NotProcessedYet
		-- (which is what makes Roblox retry -- `Monetization.OnLoad` only EXPIRES
		-- intents, it does not re-send), and the retry must then deliver.
		local harness = makeHarness()
		harness.Fake.Constants.MAX_MESSAGE_QUEUE = 1

		local buyer = harness.Join(4501)
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 4502)).to.equal(true)

		-- Fill the (offline) recipient's inbox to the cap with something else.
		expect(harness.Data.SendMessage(4502, { Kind = "Filler" })).to.equal(true)
		expect(harness.Data.SendMessage(4502, { Kind = "Overflow" })).to.equal(false)

		local refused = harness.Data.HandleReceipt(receipt(4501, 222, "gift-queue-full"))
		local escrow = harness.Ctx.Persistence.EntryForUserId(4501).LiveData._Scribe.PendingGifts["222"]
		expect(`decision={refused == NOT_PROCESSED} escrowKept={escrow ~= nil}`).to.equal(
			"decision=true escrowKept=true"
		)

		-- The inbox drains, and Roblox retries the same receipt.
		harness.Fake.Mailboxes["Default/PLAYER_4502"] = {}
		local retried = harness.Data.HandleReceipt(receipt(4501, 222, "gift-queue-full"))
		local mailbox = harness.Fake.Mailboxes["Default/PLAYER_4502"] or {}
		local escrowAfter = harness.Ctx.Persistence.EntryForUserId(4501).LiveData._Scribe.PendingGifts["222"]
		expect(
			`decision={retried == GRANTED} queued={#mailbox} isGift={mailbox[1] ~= nil and mailbox[1].ScribeGift == true} `
				.. `escrowCleared={escrowAfter == nil}`
		).to.equal("decision=true queued=1 isGift=true escrowCleared=true")

		harness.Cleanup()
	end)

	it("does not degrade service health when a recipient's queue is full", function()
		-- A full inbox belongs to ONE player's profile; it is not a DataStore fault.
		-- Reporting it through Failure.Report would call Health.ReportFailure, and a
		-- server pushed to Outage refuses every Robux grant -- including the retry
		-- that is the only thing that ever delivers the blocked gift. Persistence
		-- draws the same line with updateOfflineProfile's `dataStoreFailed` return.
		local Health = require(Root.Scribe.Internal.Health)
		local harness = makeHarness()
		harness.Fake.Constants.MAX_MESSAGE_QUEUE = 1

		expect(harness.Data.SendMessage(5601, { Kind = "Filler" })).to.equal(true)
		local before = Health.GetStatus()
		local failuresBefore = Scribe.GetMetrics().HealthFailures or 0

		-- Enough refusals to cross any reasonable failure threshold.
		local refusals = 0
		for _ = 1, 12 do
			if harness.Data.SendMessage(5601, { Kind = "Overflow" }) == false then
				refusals += 1
			end
		end
		local buyer = harness.Join(5602)
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 5601)).to.equal(true)
		expect(harness.Data.HandleReceipt(receipt(5602, 222, "gift-health"))).to.equal(NOT_PROCESSED)

		expect(
			`refusals={refusals} status={Health.GetStatus()} was={before} `
				.. `healthFailures={(Scribe.GetMetrics().HealthFailures or 0) - failuresBefore} `
				.. `queueFull={(Scribe.GetMetrics().MessageQueueFull or 0) > 0}`
		).to.equal("refusals=12 status=Healthy was=Healthy healthFailures=0 queueFull=true")

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
