--!nonstrict
-- THE OFFLINE MIRROR of F2 and of the credit-arm guard: handleOfflineReceipt clears
-- only ITS OWN intent, on BOTH of its clearing arms.
--
-- WHAT WAS AUDITED AND WHAT WAS FOUND. handleOfflineReceipt has three writes into
-- the buyer's PendingGifts slot. One -- the delivery-failure Ts refresh -- already
-- re-reads the slot inside its transform and compares GiftIds (F3's fix, pinned by
-- GiftOfflineIntentRefresh.spec). The other two did not:
--
--   * the CREDIT CONVERSION arm, reached after recipientAlreadyOwns and
--     giftAlreadyDelivered have each spent a GetOffline round trip;
--   * the DELIVERY SUCCESS arm, reached after deliverGift's cross-server
--     MessageAsync round trip.
--
-- Both are POST-YIELD. Re-reading the slot inside the UpdateOffline transform is not
-- the same guard: the transform reads the CURRENT slot, but the decision about which
-- gift this receipt owns was made from a GetOffline snapshot taken three yields
-- earlier. The compare-and-set protects the write from a racing writer; it says
-- nothing about whether the row being deleted is the one this receipt paid for.
--
-- THE WINDOW, concretely. A receipt for an absent buyer is retried by Roblox for
-- days. Inside one retry's yields the buyer joins another server, prompts a second
-- gift of the same product (legal once the slot is older than giftPromptWindow), and
-- that server saves and releases the key. The transform then opens on a profile with
-- no live session -- so UpdateOffline does not refuse and the CAS does not fail --
-- holding gift B's intent, and deletes it. B's receipt lands with no intent, falls to
-- the no-intent policy, and grants the perk to the BUYER while B's recipient gets
-- nothing.
--
-- Both arms are fixed with the guard their two siblings already carry: identity is
-- the GiftId, never the slot.
--
-- The mid-flight writer is modelled by writing the persisted slot directly, which is
-- the same idiom GiftOfflineIntentRefresh.spec uses for the arm above these two:
-- offline there is no live tree to prompt into, and what the arm actually reacts to
-- is the bytes on the key.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local BUYER = 84001
	local OWNER = 84002 -- acquires the perk between prompt and receipt: the credit arm
	local SECOND = 84003 -- gift B's recipient
	local THIRD = 84004 -- gift B's recipient on the success-arm run

	local function makeHarness(extraOptions)
		local options = {
			Products = {
				GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
			},
			GiftCooldown = 0,
			GiftIntentTTL = 3600,
			PromptProductPurchase = function() end,
		}
		for key, value in extraOptions or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options })
	end

	local function receipt(purchaseId)
		return {
			PlayerId = BUYER,
			ProductId = 222,
			PurchaseId = purchaseId,
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		}
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

	local function keyOf(harness, userId: number): string
		return "Default/" .. harness.Ctx.Persistence.KeyFor(userId)
	end

	--- The buyer's PERSISTED reserved root. The offline arm never touches a live
	--- tree, so this is the only place its work is visible.
	local function storedReserved(harness)
		return harness.Fake.Persisted[keyOf(harness, BUYER)]._Scribe
	end

	local function storedSlot(harness): any
		return storedReserved(harness).PendingGifts["222"]
	end

	local function storedCredits(harness): number
		local n = 0
		for _, count in storedReserved(harness).GiftCredits or {} do
			n += tonumber(count) or 0
		end
		return n
	end

	local function boxLen(harness, userId: number): number
		return #(harness.Fake.Mailboxes[keyOf(harness, userId)] or {})
	end

	--- Every slot that exists must carry BOTH halves of an intent's identity; a slot
	--- missing either is a phantom that later resolves to userId 0.
	local function census(harness): string
		local out = {}
		for productIdStr, intent in storedReserved(harness).PendingGifts do
			if type(intent) ~= "table" then
				table.insert(out, productIdStr .. "=NOT_A_TABLE")
			elseif intent.RecipientId == nil or intent.GiftId == nil then
				table.insert(out, productIdStr .. "=PHANTOM")
			else
				table.insert(out, productIdStr)
			end
		end
		table.sort(out)
		return table.concat(out, ",")
	end

	--- Seed a buyer with a live gift intent and leave them offline, so every receipt
	--- afterwards takes handleOfflineReceipt.
	local function seedOfflineBuyer(harness, recipientId: number): string
		local buyer = harness.Join(BUYER)
		expect(harness.Data.PromptGift(buyer, "GiftVIP", recipientId)).to.equal(true)
		harness.Data.Flush(buyer)
		harness.Leave(buyer)
		return tostring(storedSlot(harness).GiftId)
	end

	--- The recipient acquires the perk AFTER the prompt: the only order that reaches
	--- the credit arm, because PromptGift refuses for a recipient who already owns.
	local function ownerAcquiresPerk(harness)
		harness.Fake.Persisted[keyOf(harness, OWNER)] = { _Scribe = { Perks = { VIP = true } } }
	end

	--- What another server would have left on the key: a different gift, in the same
	--- one-per-product slot, with a different GiftId.
	local function plantSecondGift(harness, recipientId: number)
		storedReserved(harness).PendingGifts["222"] = {
			RecipientId = recipientId,
			GiftId = "gift-B",
			Ts = 1700000150,
			Product = "GiftVIP",
		}
	end

	--- Fire `hook` once, inside the first live GetAsync of `userId`'s key -- the round
	--- trip recipientAlreadyOwns spends on an offline recipient. Guarded against
	--- re-entry, since the hook's own work can read too.
	local function onceReading(harness, userId: number, hook: () -> ())
		local wanted = harness.Ctx.Persistence.KeyFor(userId)
		local fired = false
		harness.Fake.MidRead = function(profileKey: string)
			if fired or profileKey ~= wanted then
				return
			end
			fired = true
			hook()
		end
		return function(): boolean
			harness.Fake.MidRead = nil
			return fired
		end
	end

	--- The one seam that reaches the middle of a cross-server delivery. Returning
	--- true lets the send through, so the receipt lands on the SUCCESS arm.
	local function interceptDelivery(harness, hook: () -> ())
		local store = harness.Ctx.Persistence.Store
		local real = store.MessageAsync
		local fired = false
		store.MessageAsync = function(selfStore, key, message)
			if not fired then
				fired = true
				hook()
			end
			return real(selfStore, key, message)
		end
		return function(): boolean
			store.MessageAsync = real
			return fired
		end
	end

	--------------------------------------------------------------------------------
	-- The offline CREDIT CONVERSION arm
	--------------------------------------------------------------------------------

	it("the offline credit arm does not delete a second gift's intent", function()
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			local giftA = seedOfflineBuyer(harness, OWNER)
			ownerAcquiresPerk(harness)
			advance(200)

			local restore = onceReading(harness, OWNER, function()
				plantSecondGift(harness, SECOND)
			end)
			local decisionA = harness.Data.HandleReceipt(receipt("O1off-credit-A"))
			expect(restore()).to.equal(true) -- the window really did open

			local live = storedSlot(harness)
			expect(
				("dA=%s giftA=%s credits=%d survived=%s isB=%s to=%s ownerBox=%d"):format(
					if decisionA == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(giftA ~= "gift-B"),
					storedCredits(harness),
					tostring(live ~= nil),
					tostring(live ~= nil and live.GiftId == "gift-B"),
					tostring(live ~= nil and live.RecipientId),
					boxLen(harness, OWNER)
				)
			).to.equal("dA=GRANTED giftA=true credits=1 survived=true isB=true to=84003 ownerBox=0")

			-- B's receipt now arrives, still offline. With the intent intact it is a
			-- gift; without it the no-intent policy grants VIP to the BUYER.
			local decisionB = harness.Data.HandleReceipt(receipt("O1off-credit-B"))
			expect(
				("dB=%s secondBox=%d buyerVIP=%s credits=%d pending=[%s]"):format(
					if decisionB == GRANTED then "GRANTED" else "NOT_PROCESSED",
					boxLen(harness, SECOND),
					tostring(storedReserved(harness).Perks.VIP == true),
					storedCredits(harness),
					census(harness)
				)
			).to.equal("dB=GRANTED secondBox=1 buyerVIP=false credits=1 pending=[]")

			harness.Cleanup()
		end)
	end)

	it("the offline credit arm still clears its OWN intent, so capacity is not lost", function()
		withClock(1700000000, function()
			local harness = makeHarness()
			seedOfflineBuyer(harness, OWNER)
			ownerAcquiresPerk(harness)

			local decision = harness.Data.HandleReceipt(receipt("O1off-credit-plain"))

			expect(
				("d=%s pending=[%s] credits=%d ownerBox=%d"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					census(harness),
					storedCredits(harness),
					boxLen(harness, OWNER)
				)
			).to.equal("d=GRANTED pending=[] credits=1 ownerBox=0")

			harness.Cleanup()
		end)
	end)

	it("the offline credit arm resurrects nothing when the slot is cleared mid-flight", function()
		-- The phantom trap. Offline there is no accessor tree to raise on a write into
		-- an absent slot, so a guard that half-writes leaves a {Ts}-only record that a
		-- later retry delivers to userId 0.
		withClock(1700000000, function()
			local harness = makeHarness()
			seedOfflineBuyer(harness, OWNER)
			ownerAcquiresPerk(harness)

			local restore = onceReading(harness, OWNER, function()
				storedReserved(harness).PendingGifts["222"] = nil
			end)
			local decision = harness.Data.HandleReceipt(receipt("O1off-credit-cleared"))
			expect(restore()).to.equal(true)

			expect(
				("d=%s pending=[%s] credits=%d zeroBox=%d"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					census(harness),
					storedCredits(harness),
					boxLen(harness, 0)
				)
			).to.equal("d=GRANTED pending=[] credits=1 zeroBox=0")

			harness.Cleanup()
		end)
	end)

	--------------------------------------------------------------------------------
	-- The offline DELIVERY SUCCESS arm
	--------------------------------------------------------------------------------

	it("the offline success arm does not delete a second gift's intent", function()
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			local giftA = seedOfflineBuyer(harness, SECOND)
			advance(200)

			local restore = interceptDelivery(harness, function()
				plantSecondGift(harness, THIRD)
			end)
			local decisionA = harness.Data.HandleReceipt(receipt("O1off-sent-A"))
			expect(restore()).to.equal(true)

			local live = storedSlot(harness)
			expect(
				("dA=%s giftA=%s secondBox=%d survived=%s isB=%s to=%s"):format(
					if decisionA == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(giftA ~= "gift-B"),
					boxLen(harness, SECOND),
					tostring(live ~= nil),
					tostring(live ~= nil and live.GiftId == "gift-B"),
					tostring(live ~= nil and live.RecipientId)
				)
			).to.equal("dA=GRANTED giftA=true secondBox=1 survived=true isB=true to=84004")

			local decisionB = harness.Data.HandleReceipt(receipt("O1off-sent-B"))
			expect(
				("dB=%s thirdBox=%d buyerVIP=%s credits=%d pending=[%s]"):format(
					if decisionB == GRANTED then "GRANTED" else "NOT_PROCESSED",
					boxLen(harness, THIRD),
					tostring(storedReserved(harness).Perks.VIP == true),
					storedCredits(harness),
					census(harness)
				)
			).to.equal("dB=GRANTED thirdBox=1 buyerVIP=false credits=0 pending=[]")

			harness.Cleanup()
		end)
	end)

	it("the offline success arm still clears its OWN intent, so capacity is not lost", function()
		withClock(1700000000, function()
			local harness = makeHarness()
			seedOfflineBuyer(harness, SECOND)

			local decision = harness.Data.HandleReceipt(receipt("O1off-sent-plain"))

			expect(
				("d=%s pending=[%s] secondBox=%d credits=%d"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					census(harness),
					boxLen(harness, SECOND),
					storedCredits(harness)
				)
			).to.equal("d=GRANTED pending=[] secondBox=1 credits=0")

			harness.Cleanup()
		end)
	end)

	it("the offline success arm resurrects nothing when the slot is cleared mid-flight", function()
		withClock(1700000000, function()
			local harness = makeHarness()
			seedOfflineBuyer(harness, SECOND)

			local restore = interceptDelivery(harness, function()
				storedReserved(harness).PendingGifts["222"] = nil
			end)
			local decision = harness.Data.HandleReceipt(receipt("O1off-sent-cleared"))
			expect(restore()).to.equal(true)

			expect(
				("d=%s pending=[%s] secondBox=%d zeroBox=%d"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					census(harness),
					boxLen(harness, SECOND),
					boxLen(harness, 0)
				)
			).to.equal("d=GRANTED pending=[] secondBox=1 zeroBox=0")

			harness.Cleanup()
		end)
	end)
end
