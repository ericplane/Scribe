--!nonstrict
-- CHARACTERISATION. The money contract that sits on top of `Persistence.AwaitSave`.
--
-- WHY THIS FILE EXISTS. AwaitSave was rewritten so that it stops yielding when the
-- store settles inline (the defer-depth ratchet fix). Its INTERNAL shape -- one
-- yield, a deferred wake, a resumeWaiter helper -- changed deliberately, and these
-- specs were written first to pin what must NOT change: the answer it gives, because
-- `Monetization.handleReceipt` returns `PurchaseGranted` off that boolean and
-- Roblox never retries a granted receipt: a wrong `true` is paid Robux for data
-- that was never stored, and a wrong `false` is a purchase refused forever.
--
-- So every assertion below is written against OBSERVABLE CONTRACT -- the receipt
-- decision, what reached the DataStore, what the recipient owns, what the buyer
-- still holds -- and never against how many times a thread yielded on the way
-- there. A spec that pinned "AwaitSave yields exactly once" would be red by
-- design and would be the wrong spec.
--
-- These pass on the tree as it stands, BEFORE the fix. They are the contract the
-- fix must not break.
--
-- THE FAILURE SEAM is `fake.FailSaves`, which makes `profile:SaveAwait()` answer
-- "Failed". Each failing-save spec also asserts Health is not in Outage, because
-- Outage refuses receipts at the TOP of handleReceipt -- so without that check a
-- NotProcessedYet could be arriving from the wrong gate entirely and the spec
-- would still be green.
--
-- ONE SPEC NEEDS A SECOND SEAM: the gift-credit refund is about a failing DELIVERY
-- rather than a failing save, and delivery has two failures that must not be
-- confused. It sets `MAX_MESSAGE_QUEUE` to zero, the one that provably wrote
-- nothing; the note on that spec says why the bare-`false` seam cannot stand in
-- for it.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Health = require(Root.Scribe.Internal.Health)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

	local COINS_PRODUCT = 111
	local GIFT_PRODUCT = 222

	local promptLog

	local function makeHarness()
		promptLog = {}
		return TestCtx.make({
			Options = {
				Products = {
					Coins1000 = {
						Id = COINS_PRODUCT,
						Category = "Currency",
						Grant = function(data)
							data.Coins.Increment(1000)
						end,
					},
					GiftVIP = { Id = GIFT_PRODUCT, Category = "Gamepass", Grants = "VIP" },
				},
				GiftCooldown = 0,
				PromptProductPurchase = function(player, productId)
					table.insert(promptLog, { Player = player, ProductId = productId })
				end,
			},
		})
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

	local function stored(harness, userId: number)
		return harness.Fake.Persisted[`Default/PLAYER_{userId}`]
	end

	--- The dedupe ring holds `{ Id, At }` and, on profiles written before age-based
	--- eviction, bare strings. Count OCCURRENCES rather than test membership: "the
	--- recipient was marked once" and "the recipient was marked twice" are the two
	--- outcomes that separate one delivery from two.
	local function markerCount(list, purchaseId: string): number
		local n = 0
		for _, item in list or {} do
			local id = if type(item) == "string" then item else item.Id
			if id == purchaseId then
				n += 1
			end
		end
		return n
	end

	local function liveMarkers(entry, purchaseId: string): number
		return markerCount(entry.LiveData._Scribe.ProcessedPurchaseIds, purchaseId)
	end

	local function storedMarkers(harness, userId: number, purchaseId: string): number
		local data = stored(harness, userId)
		return markerCount(data and data._Scribe and data._Scribe.ProcessedPurchaseIds, purchaseId)
	end

	local function intentSlot(entry)
		return entry.LiveData._Scribe.PendingGifts[tostring(GIFT_PRODUCT)]
	end

	local function credits(harness, player): number
		return tonumber(harness.Data.GetGiftCredits(player).GiftVIP) or 0
	end

	describe("the online receipt path, when the confirming save answers", function()
		it("grants once and puts the paid value on disk before acknowledging", function()
			-- The baseline the two failure specs below are measured against. GRANTED
			-- is a promise that the Robux bought something durable, so the persisted
			-- copy -- not just the live tree -- has to carry both the grant and the
			-- dedupe marker at the moment the decision is returned.
			local harness = makeHarness()
			local player, entry, data = harness.Join(94001)

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "money-1"))).to.equal(GRANTED)
			expect(data.Coins.Get()).to.equal(1000)
			expect(stored(harness, 94001).Coins).to.equal(1000)
			expect(storedMarkers(harness, 94001, "money-1")).to.equal(1)
			expect(player).to.be.ok()

			harness.Cleanup()
		end)

		it("refuses the receipt when the save cannot be confirmed, so Roblox keeps the retry alive", function()
			-- The whole reason AwaitSave returns a boolean. The grant is in memory and
			-- nothing on disk backs it, so answering GRANTED here would hand Roblox a
			-- terminal acknowledgement for a purchase that a crash erases.
			local harness = makeHarness()
			local _, entry, data = harness.Join(94002)

			harness.Fake.FailSaves = true
			local decision = harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "money-2"))
			harness.Fake.FailSaves = false

			expect(decision).to.equal(NOT_PROCESSED)
			-- Not the outage gate at the top of handleReceipt: this refusal came from
			-- the durability gate at the bottom.
			expect(Health.GetStatus() ~= "Outage").to.equal(true)
			-- Applied in memory (that is what makes the retry a duplicate), absent on
			-- disk (that is what makes refusing it correct).
			expect(data.Coins.Get()).to.equal(1000)
			expect(stored(harness, 94002) == nil or stored(harness, 94002).Coins ~= 1000).to.equal(true)
			expect(storedMarkers(harness, 94002, "money-2")).to.equal(0)

			harness.Cleanup()
		end)

		it("settles the retried receipt as ONE grant once the store recovers", function()
			-- The retry Roblox issues after the refusal above. It must acknowledge and
			-- it must not pay twice: 1000 coins, never 2000, and one marker on disk.
			local harness = makeHarness()
			local _, entry, data = harness.Join(94003)

			harness.Fake.FailSaves = true
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "money-3"))).to.equal(NOT_PROCESSED)
			harness.Fake.FailSaves = false

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "money-3"))).to.equal(GRANTED)
			expect(data.Coins.Get()).to.equal(1000)
			expect(stored(harness, 94003).Coins).to.equal(1000)
			expect(storedMarkers(harness, 94003, "money-3")).to.equal(1)
			expect(liveMarkers(entry, "money-3")).to.equal(1)

			harness.Cleanup()
		end)
	end)

	describe("the duplicate-receipt acknowledgement", function()
		it("acknowledges a duplicate whose grant is already durable, without touching the store", function()
			-- `(not Dirty and SavesInFlight == 0) or AwaitSave(...)`. The left term is
			-- the point: once the grant is on disk the answer needs no round trip, and
			-- must not be held hostage to a store that is failing RIGHT NOW. Robux
			-- already paid for bytes already stored.
			local harness = makeHarness()
			local _, entry, data = harness.Join(94004)

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "dupe-1"))).to.equal(GRANTED)
			expect(stored(harness, 94004).Coins).to.equal(1000)

			harness.Fake.FailSaves = true
			local decision = harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "dupe-1"))
			harness.Fake.FailSaves = false

			expect(decision).to.equal(GRANTED)
			expect(data.Coins.Get()).to.equal(1000) -- not granted a second time
			expect(liveMarkers(entry, "dupe-1")).to.equal(1)

			harness.Cleanup()
		end)

		it("refuses a duplicate whose covering save is unconfirmed", function()
			-- The right term. A dirty entry means the marker's covering write has not
			-- landed, so a crash after GRANTED would lose the grant AND the marker --
			-- the retry that would have fixed it never comes.
			local harness = makeHarness()
			local _, entry, data = harness.Join(94005)

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "dupe-2"))).to.equal(GRANTED)
			data.Gems.Set(7) -- dirty again, so the short circuit above cannot fire
			expect(entry.SaveInfo.Dirty).to.equal(true)

			harness.Fake.FailSaves = true
			local decision = harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "dupe-2"))
			harness.Fake.FailSaves = false

			expect(decision).to.equal(NOT_PROCESSED)
			expect(Health.GetStatus() ~= "Outage").to.equal(true)
			expect(data.Coins.Get()).to.equal(1000)

			harness.Cleanup()
		end)

		it("acknowledges a duplicate on a dirty entry only after a save that really lands", function()
			-- The same right term, answered true. The acknowledgement is backed by an
			-- actual write, which is observable: the value that made the entry dirty is
			-- on disk by the time GRANTED comes back.
			local harness = makeHarness()
			local _, entry, data = harness.Join(94006)

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "dupe-3"))).to.equal(GRANTED)
			data.Gems.Set(7)
			expect(entry.SaveInfo.Dirty).to.equal(true)
			expect(stored(harness, 94006).Gems).to.never.equal(7)

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, COINS_PRODUCT, "dupe-3"))).to.equal(GRANTED)
			expect(stored(harness, 94006).Gems).to.equal(7)
			expect(data.Coins.Get()).to.equal(1000)
			expect(storedMarkers(harness, 94006, "dupe-3")).to.equal(1)

			harness.Cleanup()
		end)
	end)

	describe("same-server gift delivery", function()
		--- Buyer and recipient both live on this server, with a durable intent
		--- recorded and the purchase prompted -- the state a gift receipt lands in.
		local function promptedGift(harness, buyerId: number, recipientId: number)
			local buyer = harness.Join(buyerId)
			local recipient = harness.Join(recipientId)
			local entry = harness.Ctx.Persistence.EntryFor(buyer)
			expect(harness.Data.PromptGift(buyer, "GiftVIP", recipientId)).to.equal(true)
			expect(#promptLog).to.equal(1)
			local slot = intentSlot(entry)
			expect(slot).to.be.ok()
			return buyer, recipient, entry, slot.GiftId
		end

		it("prompts only after the intent is durable, and aims it at the named recipient", function()
			-- Money moves at the prompt, so the recipient has to be recorded on disk
			-- BEFORE the prompt fires. Otherwise a crash between the two leaves a
			-- receipt with nowhere to go, and the no-intent policy pays the buyer.
			local harness = makeHarness()
			local _, _, _, giftId = promptedGift(harness, 94010, 94011)

			local persistedIntent = stored(harness, 94010)._Scribe.PendingGifts[tostring(GIFT_PRODUCT)]
			expect(persistedIntent).to.be.ok()
			expect(persistedIntent.RecipientId).to.equal(94011)
			expect(persistedIntent.GiftId).to.equal(giftId)
			expect(promptLog[1].ProductId).to.equal(GIFT_PRODUCT)

			harness.Cleanup()
		end)

		it("acknowledges the buyer's receipt once the RECIPIENT's save is confirmed", function()
			-- The paid value lives in the recipient's profile, so the buyer's receipt
			-- is answered off the recipient's durability, not the buyer's.
			local harness = makeHarness()
			local buyer, recipient, entry = promptedGift(harness, 94012, 94013)

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, GIFT_PRODUCT, "gift-1"))).to.equal(GRANTED)
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)
			expect(stored(harness, 94013)._Scribe.Perks.VIP).to.equal(true)
			expect(storedMarkers(harness, 94013, "gift-1")).to.equal(1)
			expect(intentSlot(entry)).to.equal(nil) -- settled, so the escrow is released
			expect(credits(harness, buyer)).to.equal(0) -- delivered, so nothing converted to a credit

			harness.Cleanup()
		end)

		it("refuses the receipt while the recipient's save is unconfirmed, and keeps the escrow aimed", function()
			-- The grant is in the recipient's memory only. The intent must survive, and
			-- must still name the SAME recipient and gift: a retry that lost its aim
			-- would fall to the no-intent policy and pay the buyer instead.
			local harness = makeHarness()
			local buyer, recipient, entry, giftId = promptedGift(harness, 94014, 94015)

			harness.Fake.FailSaves = true
			local decision = harness.Data.HandleReceipt(receipt(entry.UserId, GIFT_PRODUCT, "gift-2"))
			harness.Fake.FailSaves = false

			expect(decision).to.equal(NOT_PROCESSED)
			expect(Health.GetStatus() ~= "Outage").to.equal(true)
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(true) -- memory only
			local recipientStored = stored(harness, 94015)
			expect(
				recipientStored == nil
					or recipientStored._Scribe == nil
					or recipientStored._Scribe.Perks == nil
					or recipientStored._Scribe.Perks.VIP ~= true
			).to.equal(true)
			local slot = intentSlot(entry)
			expect(slot).to.be.ok()
			expect(slot.GiftId).to.equal(giftId)
			expect(slot.RecipientId).to.equal(94015)
			expect(credits(harness, buyer)).to.equal(0) -- nothing converted to a credit

			harness.Cleanup()
		end)

		it("refuses a retry that arrives while the store is still down, without delivering twice", function()
			-- Second pass through deliverGiftLocal, this time on the already-processed
			-- branch: the recipient carries the marker from the first attempt, so the
			-- answer is purely "is it durable yet". It is not, so nothing is added.
			local harness = makeHarness()
			local buyer, _, entry = promptedGift(harness, 94016, 94017)
			local recipientEntry = harness.Ctx.Persistence.EntryForUserId(94017)

			harness.Fake.FailSaves = true
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, GIFT_PRODUCT, "gift-3"))).to.equal(NOT_PROCESSED)
			expect(liveMarkers(recipientEntry, "gift-3")).to.equal(1)
			local retry = harness.Data.HandleReceipt(receipt(entry.UserId, GIFT_PRODUCT, "gift-3"))
			harness.Fake.FailSaves = false

			expect(retry).to.equal(NOT_PROCESSED)
			expect(Health.GetStatus() ~= "Outage").to.equal(true)
			expect(liveMarkers(recipientEntry, "gift-3")).to.equal(1) -- still one delivery
			expect(credits(harness, buyer)).to.equal(0)
			expect(intentSlot(entry)).to.be.ok()

			harness.Cleanup()
		end)

		it("settles the retried gift as ONE delivery once the store recovers", function()
			-- The terminal state. The recipient owns it, on disk, marked once; the
			-- buyer's escrow is released and no credit was minted on top of a gift that
			-- did arrive.
			local harness = makeHarness()
			local buyer, recipient, entry = promptedGift(harness, 94018, 94019)

			harness.Fake.FailSaves = true
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, GIFT_PRODUCT, "gift-4"))).to.equal(NOT_PROCESSED)
			harness.Fake.FailSaves = false

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, GIFT_PRODUCT, "gift-4"))).to.equal(GRANTED)
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)
			expect(stored(harness, 94019)._Scribe.Perks.VIP).to.equal(true)
			expect(storedMarkers(harness, 94019, "gift-4")).to.equal(1)
			expect(intentSlot(entry)).to.equal(nil)
			expect(credits(harness, buyer)).to.equal(0)

			harness.Cleanup()
		end)
	end)

	describe("the gift-credit refunds", function()
		it("refunds the credit and prompts nothing when the reservation cannot be made durable", function()
			-- The credit is spent through the accessor BEFORE delivery, deliberately,
			-- so a crash can never restore a credit whose gift already went out. That
			-- makes the failure path a refund: the spend must not stick when the write
			-- confirming it never landed.
			local harness = makeHarness()
			local buyer = harness.Join(94020)
			local recipient = harness.Join(94021)
			harness.Ctx.Persistence.EntryFor(buyer).Tree.Reserved.GiftCredits.GiftVIP.Set(1)

			harness.Fake.FailSaves = true
			local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 94021)
			harness.Fake.FailSaves = false

			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "reserve") ~= nil).to.equal(true)
			expect(credits(harness, buyer)).to.equal(1) -- refunded, not consumed
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(false)
			expect(#promptLog).to.equal(0) -- a credit gift never charges Robux
			expect(Health.GetStatus() ~= "Outage").to.equal(true)

			harness.Cleanup()
		end)

		it("refunds the credit when the reservation IS durable but delivery fails", function()
			-- Reservation lands, delivery does not. The buyer paid for this credit
			-- once; leaving it spent with nothing delivered is the money lost.
			--
			-- THE SEAM MOVED; NOT ONE ASSERTION DID. This used to inject the failure
			-- with `Fake.FailMessages`, which answers a BARE `false`. Real
			-- MessageAsync returns that same bare `false` from two places -- the
			-- IsClosing guard at entry, which attempted nothing, and the end of its
			-- retry loop, whose attempts may each have committed before erroring --
			-- so no caller can read it as "did not deliver". Handing a paid credit
			-- back there returns it for a gift that IS queued, and the re-spend mints
			-- a FRESH giftId the recipient's dedupe ring has never seen: one payment,
			-- two grants. A full inbox is the delivery failure that provably wrote
			-- nothing -- MessageAsync ran its transform, saw the cap and aborted the
			-- write in band, then said so -- which is what this spec always meant by
			-- "delivery fails", and every assertion below still holds under it. The
			-- unconfirmed half is pinned in GiftCreditSpendContract.spec.
			local harness = makeHarness()
			local buyer = harness.Join(94022)
			harness.Ctx.Persistence.EntryFor(buyer).Tree.Reserved.GiftCredits.GiftVIP.Set(1)

			-- Recipient 94023 never joined, so delivery goes out over MessageAsync.
			harness.Fake.SetConstant("MAX_MESSAGE_QUEUE", 0)
			local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 94023)
			harness.Fake.SetConstant("MAX_MESSAGE_QUEUE", 1000)

			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "deliver") ~= nil).to.equal(true)
			expect(credits(harness, buyer)).to.equal(1)
			expect(#(harness.Fake.Mailboxes[`Default/PLAYER_94023`] or {})).to.equal(0)
			expect(#promptLog).to.equal(0)

			harness.Cleanup()
		end)

		it("consumes the credit exactly once when reservation and delivery both succeed", function()
			-- The counterpart the two refunds are only meaningful against: a working
			-- run spends the credit and the recipient really gets the perk.
			local harness = makeHarness()
			local buyer = harness.Join(94024)
			local recipient = harness.Join(94025)
			harness.Ctx.Persistence.EntryFor(buyer).Tree.Reserved.GiftCredits.GiftVIP.Set(1)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", 94025)).to.equal(true)
			expect(credits(harness, buyer)).to.equal(0)
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)
			expect(#promptLog).to.equal(0)

			harness.Cleanup()
		end)
	end)

	describe("the gift intent write", function()
		it("refuses the prompt and leaves no intent behind when the intent write fails", function()
			-- No prompt means no money taken, so there must be nothing left in
			-- PendingGifts for a later receipt to settle against.
			local harness = makeHarness()
			local buyer = harness.Join(94030)
			harness.Join(94031)
			local entry = harness.Ctx.Persistence.EntryFor(buyer)

			harness.Fake.FailSaves = true
			local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 94031)
			harness.Fake.FailSaves = false

			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "intent") ~= nil).to.equal(true)
			expect(intentSlot(entry)).to.equal(nil)
			expect(#promptLog).to.equal(0)
			expect(Health.GetStatus() ~= "Outage").to.equal(true)

			harness.Cleanup()
		end)
	end)

	describe("Data.Flush, the same boolean by its public name", function()
		it("answers false when the write is refused and true when the bytes land", function()
			-- Flush is AwaitSave with a durability short circuit in front of it, and it
			-- is the documented way a game forces its own money-adjacent write. The
			-- boolean has to mean the same thing here as it does on the receipt path.
			local harness = makeHarness()
			local player, _, data = harness.Join(94040)

			data.Coins.Set(500)
			harness.Fake.FailSaves = true
			local refused = harness.Data.Flush(player)
			harness.Fake.FailSaves = false

			expect(refused).to.equal(false)
			expect(stored(harness, 94040) == nil or stored(harness, 94040).Coins ~= 500).to.equal(true)

			expect(harness.Data.Flush(player)).to.equal(true)
			expect(stored(harness, 94040).Coins).to.equal(500)
			expect(Health.GetStatus() ~= "Outage").to.equal(true)

			harness.Cleanup()
		end)
	end)
end
