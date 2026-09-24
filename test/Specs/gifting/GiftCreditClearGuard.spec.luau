--!nonstrict
-- Gift-credit conversion must clear only the original GiftId.
-- A legacy writer replaces the slot during the recipient ownership lookup.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local BUYER = 83001
	local OWNER = 83002 -- offline, already owns VIP: the reason the credit arm runs
	local SECOND = 83003 -- offline, owns nothing: gift B's intended recipient

	local function makeHarness(extraOptions)
		local finished = require(Root.Scribe.Internal.Signal).new()
		local options = {
			Products = {
				GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
			},
			GiftCooldown = 0,
			PromptProductPurchaseFinished = finished,
			PromptProductPurchase = function(player, productId)
				finished:Fire(player.UserId, productId, true)
			end,
		}
		for key, value in extraOptions or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options })
	end

	--- The recipient acquires the perk AFTER the prompt and BEFORE the receipt --
	--- the exact window the credit arm exists for, and the only order that reaches
	--- it: PromptGift refuses outright for a recipient who already owns the perk.
	--- Seeded into the durable store rather than played, so the read the credit arm
	--- makes is a real offline GetAsync.
	local function ownerAcquiresPerk(harness)
		harness.Fake.Persisted["Default/PLAYER_" .. OWNER] = { _Scribe = { Perks = { VIP = true } } }
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

	local function credits(entry, productName: string): number
		return tonumber(entry.LiveData._Scribe.GiftCredits[productName]) or 0
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

	--- Run `hook` ONCE, inside the first offline read the credit arm makes. Guarded
	--- against re-entry because whatever the hook does (PromptGift reads the new
	--- recipient's profile) goes through GetAsync too.
	local function onceMidRead(harness, hook: () -> ())
		local fired = false
		harness.Fake.MidRead = function()
			if fired then
				return
			end
			fired = true
			hook()
		end
		return function()
			harness.Fake.MidRead = nil
			return fired
		end
	end

	it("does not delete a second gift's intent when the first converts to a gift credit", function()
		-- THE CONSEQUENCE. Gift A is aimed at someone who already owns the perk, so
		-- its receipt mints a credit; gift B's intent lands in the same slot while
		-- that decision is reading A's recipient off the DataStore. A's credit
		-- conversion must leave B alone.
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			local buyer, entry = harness.Join(BUYER)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", OWNER)).to.equal(true)
			local giftA = slot(entry, 222).GiftId
			ownerAcquiresPerk(harness)

			-- Simulate a legacy writer replacing the slot during receipt delivery.
			advance(200)

			local giftB
			local restore = onceMidRead(harness, function()
				entry.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = SECOND,
					GiftId = "legacy-replacement",
					Ts = Clock.Now(),
					Product = "GiftVIP",
				})
				giftB = slot(entry, 222).GiftId
				expect(giftB ~= giftA).to.equal(true)
			end)
			local decisionA = harness.Data.HandleReceipt(receipt(BUYER, 222, "O1-A"))
			expect(restore()).to.equal(true) -- the window really did open

			-- A settled as a credit, delivered nothing, and left B's intent intact.
			local live = slot(entry, 222)
			expect(
				("dA=%s credits=%d survived=%s isB=%s to=%s ownerBox=%d secondBox=%d"):format(
					if decisionA == GRANTED then "GRANTED" else "NOT_PROCESSED",
					credits(entry, "GiftVIP"),
					tostring(live ~= nil),
					tostring(live ~= nil and live.GiftId == giftB),
					tostring(live ~= nil and live.RecipientId),
					#mailbox(harness, OWNER),
					#mailbox(harness, SECOND)
				)
			).to.equal("dA=GRANTED credits=1 survived=true isB=true to=83003 ownerBox=0 secondBox=0")

			-- B's receipt now arrives. With the intent intact it is a gift; without it
			-- the no-intent policy grants VIP to the BUYER and 83003 gets nothing.
			local decisionB = harness.Data.HandleReceipt(receipt(BUYER, 222, "O1-B"))

			expect(
				("dB=%s secondBox=%d buyerVIP=%s pending=%s credits=%d"):format(
					if decisionB == GRANTED then "GRANTED" else "NOT_PROCESSED",
					#mailbox(harness, SECOND),
					tostring(harness.Data.Owns(buyer, "VIP")),
					tostring(slot(entry, 222) ~= nil),
					credits(entry, "GiftVIP")
				)
			).to.equal("dB=GRANTED secondBox=1 buyerVIP=false pending=false credits=1")

			-- ...and the queued gift really does land when its recipient next logs in.
			local second = harness.Join(SECOND)
			expect(tostring(harness.Data.Owns(second, "VIP"))).to.equal("true")

			harness.Cleanup()
		end)
	end)

	it("still clears the intent on an ordinary credit conversion, so capacity is not lost", function()
		-- The other half of the guard. When the slot IS still ours the clear must
		-- happen exactly as before: an intent no path clears is a permanent loss of
		-- gift capacity (PromptGift refuses at GiftMaxPending) with no diagnostic.
		withClock(1700000000, function()
			local harness = makeHarness({ GiftMaxPending = 1 })
			local buyer, entry = harness.Join(BUYER)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", OWNER)).to.equal(true)
			ownerAcquiresPerk(harness)
			local decision = harness.Data.HandleReceipt(receipt(BUYER, 222, "O1-plain"))

			expect(
				("d=%s pending=%s credits=%d ownerBox=%d regift=%s"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(slot(entry, 222) ~= nil),
					credits(entry, "GiftVIP"),
					#mailbox(harness, OWNER),
					tostring((harness.Data.PromptGift(buyer, "GiftVIP", SECOND)))
				)
			).to.equal("d=GRANTED pending=false credits=1 ownerBox=0 regift=true")

			harness.Cleanup()
		end)
	end)

	it("leaves a mid-flight cleared slot empty rather than resurrecting anything", function()
		-- The phantom trap. If the slot is gone by the time the ownership read
		-- returns, the guarded clear is a no-op and must not bring a half-built
		-- record into existence -- a stray {Ts} intent with no RecipientId is
		-- delivered to userId 0 by the next retry.
		withClock(1700000000, function()
			local harness = makeHarness()
			local buyer, entry = harness.Join(BUYER)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", OWNER)).to.equal(true)
			ownerAcquiresPerk(harness)

			local restore = onceMidRead(harness, function()
				entry.Tree.Reserved.PendingGifts["222"].Set(nil)
			end)
			local decision = harness.Data.HandleReceipt(receipt(BUYER, 222, "O1-cleared"))
			expect(restore()).to.equal(true)

			local census = {}
			for productIdStr in entry.LiveData._Scribe.PendingGifts do
				table.insert(census, productIdStr)
			end
			table.sort(census)
			expect(
				("d=%s pending=[%s] credits=%d ownerBox=%d"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					table.concat(census, ","),
					credits(entry, "GiftVIP"),
					#mailbox(harness, OWNER)
				)
			).to.equal("d=GRANTED pending=[] credits=1 ownerBox=0")

			harness.Cleanup()
		end)
	end)

	it("stays silent on the guarded path, emitting only the credit conversion's own warning", function()
		-- Declining to clear a slot that is not ours is the normal outcome, not an
		-- incident: the second gift's own receipt is the thing that reports.
		-- check-log-codes is pinned, so a diagnostic smuggled in here would drift it.
		local seen = {}
		local unsubscribe = Scribe.AddLogSink(function(logEntry)
			seen[logEntry.Code] = (seen[logEntry.Code] or 0) + 1
		end, { Level = "Warn" })
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			local buyer, entry = harness.Join(BUYER)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", OWNER)).to.equal(true)
			ownerAcquiresPerk(harness)
			advance(200)
			local restore = onceMidRead(harness, function()
				entry.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = SECOND,
					GiftId = "legacy-replacement",
					Ts = Clock.Now(),
					Product = "GiftVIP",
				})
			end)
			expect(harness.Data.HandleReceipt(receipt(BUYER, 222, "O1-log"))).to.equal(GRANTED)
			expect(restore()).to.equal(true)
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
		-- Exactly the one warning the credit arm always writes: no expiry, no
		-- delivery, no retry, nothing new.
		expect(table.concat(gifty, " ")).to.equal("GIFT_RECIPIENT_ALREADY_OWNS=1")
	end)

	it("keeps the two already-guarded arms untouched", function()
		-- The credit arm sits directly above the delivery arms. If a fix to it reached
		-- down, the failure arm's refreshed-and-complete intent is where it would
		-- show: the recipient here does NOT own the perk, so the credit arm is skipped
		-- entirely and delivery is attempted and fails.
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			local buyer, entry = harness.Join(BUYER)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", SECOND)).to.equal(true)
			local giftA = slot(entry, 222).GiftId

			advance(50)
			harness.Fake.FailMessages = true
			local decision = harness.Data.HandleReceipt(receipt(BUYER, 222, "O1-fail"))
			harness.Fake.FailMessages = false

			local live = slot(entry, 222)
			expect(
				("d=%s gift=%s ts=%s to=%s credits=%d box=%d"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(live.GiftId == giftA),
					tostring(live.Ts),
					tostring(live.RecipientId),
					credits(entry, "GiftVIP"),
					#mailbox(harness, SECOND)
				)
			).to.equal("d=NOT_PROCESSED gift=true ts=1700000050 to=83003 credits=0 box=0")

			harness.Cleanup()
		end)
	end)
end
