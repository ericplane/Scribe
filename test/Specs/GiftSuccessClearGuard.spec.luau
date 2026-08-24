--!nonstrict
-- F2's CONSEQUENCE SPEC: the online success arm clears only ITS OWN intent.
--
-- handleGiftReceipt's success arm runs AFTER deliverGift, which yields on a
-- cross-server MessageAsync round trip. Intents are one slot per product Id, so a
-- second PromptGift landing inside that yield -- legal once the slot is older than
-- giftPromptWindow (120s) and younger than giftIntentTTL (3600s) -- replaces the
-- slot with a different gift. Clearing it blind deletes a gift the receipt does not
-- own: that second gift's receipt then finds no intent, falls to the no-intent
-- policy, and grants the perk to the BUYER while its recipient gets nothing. No
-- log, no metric, no failed save.
--
-- The identity of an intent is its GiftId, never the slot. The guard added here is
-- the same one the failure arm eight lines above already carries.
--
-- SCOPE: this fix stops the DELETION only. PromptGift's silent same-product
-- overwrite (gift A's receipt delivering to gift B's recipient) is untouched, and
-- is still pinned unchanged by GiftIntentNet.spec's overwrite block.
--
-- Recipients are deliberately OFFLINE wherever the spec has to act mid-delivery:
-- deliverGift short-circuits to deliverGiftLocal for a Ready recipient on this
-- server and never reaches MessageAsync, which is the only seam that reaches into
-- the yield. Online delivery is covered by the ordinary-success block, which needs
-- no seam.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

	local function makeHarness(extraOptions)
		local options = {
			Products = {
				GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
			},
			GiftCooldown = 0,
			PromptProductPurchase = function() end,
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

	local function slot(entry, productId: number): any
		return entry.LiveData._Scribe.PendingGifts[tostring(productId)]
	end

	local function mailbox(harness, userId: number)
		return harness.Fake.Mailboxes["Default/" .. harness.Ctx.Persistence.KeyFor(userId)] or {}
	end

	local function withClock(startAt: number, body: (advance: (n: number) -> ()) -> ())
		local now = startAt
		Clock.Install({
			Now = function()
				return now
			end,
			Monotonic = function()
				return now
			end,
		})
		local ok, err = pcall(body, function(n: number)
			now += n
		end)
		Clock.Reset()
		if not ok then
			error(err, 0)
		end
	end

	--- The one seam that reaches the middle of a cross-server delivery: deliverGift
	--- indexes `ctx.Persistence.Store:MessageAsync` at call time.
	local function interceptDelivery(harness, hook: (key: string, message: any) -> boolean)
		local store = harness.Ctx.Persistence.Store
		local real = store.MessageAsync
		store.MessageAsync = function(selfStore, key, message)
			if hook(key, message) then
				return real(selfStore, key, message)
			end
			return false
		end
		return function()
			store.MessageAsync = real
		end
	end

	it("does not delete a second gift's intent when the first gift's receipt succeeds", function()
		-- THE F2 CONSEQUENCE. Gift A is paid for and delivered; gift B's intent is
		-- written into the same slot while A's delivery is yielding. A's success arm
		-- must leave B alone, so B's own receipt still finds B's intent and reaches
		-- B's recipient rather than granting the perk to the buyer.
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			local buyer, entry = harness.Join(82001)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", 82002)).to.equal(true)
			local giftA = slot(entry, 222).GiftId

			-- Roblox delivers the receipt well after the prompt, which is normal: the
			-- slot is now older than giftPromptWindow, so a second prompt may take it.
			advance(200)

			local giftB
			local restore = interceptDelivery(harness, function()
				if giftB == nil then
					-- The buyer prompts a second gift of the same product WHILE A's
					-- delivery is in flight. A real PromptGift, not a planted record:
					-- it is the only writer allowed to create a slot.
					expect(harness.Data.PromptGift(buyer, "GiftVIP", 82003)).to.equal(true)
					giftB = slot(entry, 222).GiftId
					expect(giftB ~= giftA).to.equal(true)
				end
				return true -- ...and A's delivery still succeeds
			end)
			expect(harness.Data.HandleReceipt(receipt(82001, 222, "F2-A"))).to.equal(GRANTED)
			restore()

			-- A reached A's recipient, and B's intent is untouched.
			local live = slot(entry, 222)
			expect(
				("survived=%s isB=%s to=%s box1=%d box2=%d"):format(
					tostring(live ~= nil),
					tostring(live ~= nil and live.GiftId == giftB),
					tostring(live ~= nil and live.RecipientId),
					#mailbox(harness, 82002),
					#mailbox(harness, 82003)
				)
			).to.equal("survived=true isB=true to=82003 box1=1 box2=0")

			-- B's receipt now arrives. With the intent intact it is a gift; without it
			-- the no-intent policy grants VIP to the BUYER and 82003 gets nothing.
			expect(harness.Data.HandleReceipt(receipt(82001, 222, "F2-B"))).to.equal(GRANTED)

			expect(
				("box2=%d buyer=%s pending=%s"):format(
					#mailbox(harness, 82003),
					tostring(harness.Data.Owns(buyer, "VIP")),
					tostring(slot(entry, 222) ~= nil)
				)
			).to.equal("box2=1 buyer=false pending=false")

			-- ...and the queued gifts really do land when the recipients next log in.
			local r1 = harness.Join(82002)
			local r2 = harness.Join(82003)
			expect(
				("r1=%s r2=%s"):format(tostring(harness.Data.Owns(r1, "VIP")), tostring(harness.Data.Owns(r2, "VIP")))
			).to.equal("r1=true r2=true")

			harness.Cleanup()
		end)
	end)

	it("still clears the intent on an ordinary success, so capacity is not lost", function()
		-- The other half of the guard: when the slot IS still ours the clear must
		-- happen exactly as before. An intent no path clears is a permanent loss of
		-- gift capacity (PromptGift refuses at GiftMaxPending) with no diagnostic.
		-- Same-server delivery, so this is the deliverGiftLocal arm.
		withClock(1700000000, function()
			local harness = makeHarness({ GiftMaxPending = 1 })
			local buyer, entry = harness.Join(82011)
			local r1 = harness.Join(82012)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", 82012)).to.equal(true)
			expect(harness.Data.HandleReceipt(receipt(82011, 222, "F2-plain"))).to.equal(GRANTED)

			expect(
				("pending=%s r1=%s regift=%s"):format(
					tostring(slot(entry, 222) ~= nil),
					tostring(harness.Data.Owns(r1, "VIP")),
					tostring((harness.Data.PromptGift(buyer, "GiftVIP", 82013)))
				)
			).to.equal("pending=false r1=true regift=true")

			harness.Cleanup()
		end)
	end)

	it("leaves a mid-flight cleared slot empty rather than resurrecting anything", function()
		-- The phantom trap, on the success arm this time. If the slot is gone by the
		-- time the delivery returns, the guarded clear is a no-op and must not bring a
		-- half-built record into existence.
		withClock(1700000000, function()
			local harness = makeHarness()
			local buyer, entry = harness.Join(82021)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", 82022)).to.equal(true)

			local restore = interceptDelivery(harness, function()
				entry.Tree.Reserved.PendingGifts["222"].Set(nil)
				return true
			end)
			expect(harness.Data.HandleReceipt(receipt(82021, 222, "F2-cleared"))).to.equal(GRANTED)
			restore()

			local census = {}
			for productIdStr in entry.LiveData._Scribe.PendingGifts do
				table.insert(census, productIdStr)
			end
			expect(("pending=[%s] box=%d"):format(table.concat(census, ","), #mailbox(harness, 82022))).to.equal(
				"pending=[] box=1"
			)

			harness.Cleanup()
		end)
	end)

	it("stays silent on the guarded path, emitting no gift warning of its own", function()
		-- The guard is deliberately quiet: declining to clear a slot that is not ours
		-- is the normal outcome, not an incident, and the second gift's own receipt is
		-- the thing that reports. check-log-codes is pinned, so a diagnostic smuggled
		-- in here would drift it.
		local seen = {}
		local unsubscribe = Scribe.AddLogSink(function(logEntry)
			seen[logEntry.Code] = (seen[logEntry.Code] or 0) + 1
		end)
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			local buyer, entry = harness.Join(82031)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", 82032)).to.equal(true)
			advance(200)
			local done = false
			local restore = interceptDelivery(harness, function()
				if not done then
					done = true
					expect(harness.Data.PromptGift(buyer, "GiftVIP", 82033)).to.equal(true)
				end
				return true
			end)
			expect(harness.Data.HandleReceipt(receipt(82031, 222, "F2-log"))).to.equal(GRANTED)
			restore()
			expect(slot(entry, 222)).to.be.ok() -- the guard declined to clear
			harness.Cleanup()
		end)
		task.wait()
		unsubscribe()

		local gifty = {}
		for code, count in seen do
			if code:sub(1, 5) == "GIFT_" or code:sub(1, 8) == "MESSAGE_" then
				table.insert(gifty, ("%s=%d"):format(code, count))
			end
		end
		table.sort(gifty)
		-- Exactly the one receipt log the success arm always writes: no expiry, no
		-- credit conversion, no delivery retry, nothing new.
		expect(table.concat(gifty, " ")).to.equal("GIFT_RECEIPT_GRANTED=1")
	end)

	it("keeps the failure arm's behaviour untouched", function()
		-- NOT_PROCESSED with the intent surviving, complete and refreshed. F2 changed
		-- the arm eight lines below that one; if it reached back up, the fix did more
		-- than it was scoped to.
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			local buyer, entry = harness.Join(82041)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", 82042)).to.equal(true)
			local giftA = slot(entry, 222).GiftId

			advance(50)
			harness.Fake.FailMessages = true
			expect(harness.Data.HandleReceipt(receipt(82041, 222, "F2-fail"))).to.equal(NOT_PROCESSED)
			harness.Fake.FailMessages = false

			local live = slot(entry, 222)
			expect(
				("gift=%s ts=%s to=%s box=%d"):format(
					tostring(live.GiftId == giftA),
					tostring(live.Ts),
					tostring(live.RecipientId),
					#mailbox(harness, 82042)
				)
			).to.equal("gift=true ts=1700000050 to=82042 box=0")

			harness.Cleanup()
		end)
	end)
end
