--!nonstrict
-- F1's NET: the expired-intent double-grant, and everything a durable per-purchaseId
-- gift record must not break on its way to closing it.
--
-- THE DEFECT. `GiftIntentTTL` (default 3600) is ONE NUMBER DOING TWO JOBS. It bounds
-- how long a buyer may sit at the Robux dialog, and -- because the intent is the only
-- record of who the gift was aimed at -- it also bounds how long the RECIPIENT'S
-- IDENTITY survives a receipt that has not settled yet. The second window is Roblox's,
-- not ours, and it is not 3600 seconds. Past the TTL the intent is swept, the receipt
-- lands looking like an ordinary self-purchase, and the buyer is granted the thing they
-- paid to give away -- recorded in their own ledger as `From.Type = "Purchase"`, so it
-- is not even identifiable as a mis-settled gift afterwards.
--
-- `giftAlreadyDelivered` (Monetization.luau:1428) already asks the right question --
-- "did we already deliver THIS purchaseId to that recipient?" -- but its only caller is
-- inside the branch that requires the intent to still exist, which is exactly the
-- branch that is gone when this fires. The fix shape is to make that question
-- answerable WITHOUT the intent, from a durable per-purchaseId record on the buyer's
-- key, consulted on the no-intent path BEFORE the buyer is granted.
--
-- WHAT THIS FILE IS. Three kinds of spec, and the difference is load-bearing:
--
--   * CONTROLS and INVARIANTS -- correct behaviour today that must still be correct
--     after the fix. These must never be edited to make a fix pass. The F1-D controls
--     are the sharpest: they are the F1-A/B/C setups two seconds of virtual time
--     earlier, and they settle correctly.
--   * CHARACTERISATIONS OF THE CURRENT WRONG BEHAVIOUR -- marked `MUST FLIP` with the
--     exact post-fix expectation written out. These are the only specs in this file
--     that may be changed when F1 lands, and only into what their comment says.
--   * BLAST-RADIUS specs for the fix itself -- the legitimate no-intent paths a
--     durable gift record could most easily break (an ordinary self-purchase must
--     still work), the storage cap the record must respect, and proof that the
--     existing dedupe ring is NOT a place to park it.
--
-- TWO SECONDS IS THE ENTIRE DISCRIMINATOR: every F1 spec below runs at 3601 s and its
-- control runs at 3599 s, against the DEFAULT GiftIntentTTL. Nothing else differs.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Metrics = require(Root.Scribe.Internal.Metrics)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

	local BUYER = 94101
	local RECIPIENT = 94102

	local T0 = 1700000000
	-- The default GiftIntentTTL, spelled out so the two-second discriminator below is
	-- readable. No spec here sets the option: the defect is about the DEFAULT.
	local TTL = 3600
	local JUST_INSIDE = TTL - 1 -- 3599
	local JUST_PAST = TTL + 1 -- 3601

	--- THE CAP THIS NET PINS for a durable gift record. Two numbers, and they are
	--- separate on purpose:
	---
	---   * NO CONTAINER on the buyer's key may exceed 200 entries. That is the same
	---     ceiling the receipt-dedupe ring already lives under, and it is what stops a
	---     heavy gifter's profile from growing without bound. A record keyed by
	---     purchaseId is ~80 bytes; 200 of them is ~16 KB, which a profile can carry.
	---   * DOUBLING the purchases adds no nodes at all, and the whole reserved root
	---     stays under a 3000-node ceiling -- so the fix cannot satisfy the
	---     per-container rule by adding several capped containers instead of one.
	---
	--- Both hold today and both must still hold after the fix; neither is a
	--- characterisation. See the storage spec for what the budget is measured against.
	local MAX_CONTAINER_ENTRIES = 200
	local MAX_RESERVED_NODES = 3000

	local function makeHarness(extraOptions)
		local options = {
			Products = {
				-- A consumable: real value, no perk. This is the one that shows the
				-- double grant as an ARITHMETIC fact -- 2000 coins from a 1000-coin
				-- purchase -- rather than as a boolean flag set twice.
				Coins1000 = {
					Id = 111,
					Category = "Currency",
					Grant = function(data)
						data.Coins.Increment(1000)
					end,
				},
				-- A pure perk product: the giftable shape, and the only shape the
				-- OFFLINE receipt path can settle at all.
				GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
				-- A SECOND perk product, so a spec can ask whether a gift of one
				-- product wrongly blocks an ordinary purchase of another.
				GiftPRO = { Id = 333, Category = "Gamepass", Grants = "PRO" },
			},
			GiftCooldown = 0,
			PromptProductPurchase = function() end,
		}
		for key, value in extraOptions or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options })
	end

	local function receipt(productId: number, purchaseId: string, userId: number?)
		return {
			PlayerId = userId or BUYER,
			ProductId = productId,
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

	--- The PERSISTED reserved root for a user, or an empty stand-in when that user has
	--- no profile on disk at all (a recipient who never joined and was never written
	--- to must read as "has nothing", not as an index error).
	local function storedReserved(harness, userId: number)
		local profile = harness.Fake.Persisted[keyOf(harness, userId)]
		return (profile and profile._Scribe) or {}
	end

	local function mailbox(harness, userId: number): number
		return #(harness.Fake.Mailboxes[keyOf(harness, userId)] or {})
	end

	local function owns(reserved, perk: string): boolean
		return type(reserved.Perks) == "table" and reserved.Perks[perk] == true
	end

	local function coinsOf(harness, userId: number): number
		local profile = harness.Fake.Persisted[keyOf(harness, userId)]
		return tonumber(profile and profile.Coins) or 0
	end

	--- Every `From.Type` in the buyer's Robux ledger, in order. This is the surface an
	--- operator would have to reconcile a mis-settled purchase from, so a defect that
	--- is invisible here is worse than one that is not.
	local function ledger(reserved): string
		local out = {}
		for _, line in (reserved.PurchaseLogs and reserved.PurchaseLogs.Robux) or {} do
			table.insert(out, tostring(line.From and line.From.Type))
		end
		return table.concat(out, ",")
	end

	--- Which product slots still hold a gift intent, and whether each is well-formed.
	local function pending(reserved): string
		local out = {}
		for productIdStr, intent in reserved.PendingGifts or {} do
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

	local function processedCount(reserved, purchaseId: string?): number
		local n = 0
		for _, item in reserved.ProcessedPurchaseIds or {} do
			local id = if type(item) == "string" then item else item.Id
			if purchaseId == nil or id == purchaseId then
				n += 1
			end
		end
		return n
	end

	--- The one seam that reaches into a cross-server delivery, ONE SHOT. `hook` runs
	--- before the send and decides whether it goes through; returning true means the
	--- gift really is durably delivered, which is the precondition every F1-A/B spec
	--- needs before it can break the BUYER's leg.
	local function onceOnDelivery(harness, hook: (key: string, message: any) -> boolean)
		local store = harness.Ctx.Persistence.Store
		local real = store.MessageAsync
		store.MessageAsync = function(selfStore, key, message)
			store.MessageAsync = real
			if hook(key, message) then
				return real(selfStore, key, message)
			end
			return false
		end
		return function()
			store.MessageAsync = real
		end
	end

	--- Buyer joins, aims a gift, flushes it durably, and leaves. Afterwards the intent
	--- is on disk and every receipt takes the offline path until they rejoin.
	local function armGiftAndLeave(harness, productName: string, recipientId: number?)
		local buyer = harness.Join(BUYER)
		expect(harness.Data.PromptGift(buyer, productName, recipientId or RECIPIENT)).to.equal(true)
		harness.Data.Flush(buyer)
		harness.Leave(buyer)
	end

	--- The recipient joins, which drains their mailbox through the gift handler, and
	--- leaves with the result flushed. This is how a queued gift becomes REAL.
	local function recipientCollects(harness, userId: number?)
		local player = harness.Join(userId or RECIPIENT)
		harness.Data.Flush(player)
		harness.Leave(player)
	end

	----------------------------------------------------------------------------------
	-- F1-D: THE CONTROLS. Correct behaviour, two seconds before the cliff.
	-- These are NOT characterisations. They must pass before AND after the fix, and
	-- editing one to make a fix pass is the exact failure this net exists to catch.
	----------------------------------------------------------------------------------

	it("F1-D control: at 3599s a clean deferred receipt still settles to the RECIPIENT", function()
		-- The F1-C setup exactly, one second inside the TTL. Nothing fails: the buyer
		-- arms the gift, flushes, leaves, and Roblox does not invoke ProcessReceipt
		-- until their next session. The intent survives the OnLoad sweep, the receipt
		-- finds it, and the gift goes where it was aimed.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			advance(JUST_INSIDE)
			local rejoined = harness.Join(BUYER) -- OnLoad's sweep runs here
			local decision = harness.Data.HandleReceipt(receipt(222, "f1-d-clean"))
			harness.Data.Flush(rejoined)

			local buyer = storedReserved(harness, BUYER)
			expect(
				("d=%s buyerVIP=%s queued=%d ledger=[%s] pending=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(buyer, "VIP")),
					mailbox(harness, RECIPIENT),
					ledger(buyer),
					pending(buyer)
				)
			).to.equal("d=GRANTED buyerVIP=false queued=1 ledger=[GiftSent] pending=[]")

			harness.Cleanup()
		end)
	end)

	it("F1-D control: at 3599s a retry after a failed buyer-commit does NOT re-grant", function()
		-- The F1-B setup exactly, one second inside the TTL, and the sharper of the two
		-- controls: the recipient has ALREADY been paid. The intent is still readable,
		-- so the retry settles as the gift it was -- the re-send dedupes on the
		-- recipient's own ring and the buyer is granted nothing.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			-- Attempt 1: the gift IS durably delivered; the buyer's own commit is what
			-- fails. This is the split that F1 turns into a double grant.
			local restore = onceOnDelivery(harness, function()
				harness.Fake.FailSaves = true
				return true
			end)
			expect(harness.Data.HandleReceipt(receipt(222, "f1-d-retry"))).to.equal(NOT_PROCESSED)
			restore()
			harness.Fake.FailSaves = false

			recipientCollects(harness)
			advance(JUST_INSIDE)
			local decision = harness.Data.HandleReceipt(receipt(222, "f1-d-retry"))

			local buyer = storedReserved(harness, BUYER)
			local recipient = storedReserved(harness, RECIPIENT)
			expect(
				("d=%s buyerVIP=%s rcpVIP=%s ledger=[%s] pending=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(buyer, "VIP")),
					tostring(owns(recipient, "VIP")),
					ledger(buyer),
					pending(buyer)
				)
			).to.equal("d=GRANTED buyerVIP=false rcpVIP=true ledger=[GiftSent] pending=[]")

			harness.Cleanup()
		end)
	end)

	----------------------------------------------------------------------------------
	-- F1-A / F1-B / F1-C: CHARACTERISATIONS OF THE CURRENT WRONG BEHAVIOUR.
	-- Each says what it becomes when the fix lands. These are the only specs in this
	-- file that may be rewritten, and only into the expectation their comment names.
	----------------------------------------------------------------------------------

	it("F1-A: past the TTL an ONLINE retry settles to the RECIPIENT -- 1000 coins from a 1000-coin purchase", function()
		-- FLIPPED when F1 landed, into exactly the value this comment named.
		--   before the fix: buyerCoins=1000 rcpCoins=1000 total=2000 ledger=[Purchase]
		--   now:            buyerCoins=0    rcpCoins=1000 total=1000, and the decision is
		--                   GRANTED (the durable gift record proves this purchaseId was
		--                   already delivered to the recipient, so the receipt settles
		--                   without granting the buyer anything and Roblox stops retrying).
		--
		-- The record here is the AIM: the buyer rejoined, so the load sweep archived
		-- the stale intent into _Scribe.GiftAims instead of deleting it, and the
		-- no-intent path found the recipient there.
		--
		-- The timeline, and every step of it is ordinary:
		--   1. the buyer aims a consumable gift and pays
		--   2. delivery to the recipient's key commits DURABLY
		--   3. the buyer's own commit does not land, and their server dies with it --
		--      so the dedupe marker and the cleared intent never reach disk
		--   4. the recipient collects: they now hold the paid value
		--   5. more than GiftIntentTTL later the buyer rejoins; OnLoad sweeps the
		--      intent as an abandoned prompt
		--   6. Roblox retries the receipt. No intent, so it looks like a self-purchase
		--
		-- Consumable, not perk, so the damage is countable rather than idempotent: a
		-- boolean perk granted twice still reads `true`, but coins add up.
		withClock(T0, function(advance)
			local harness = makeHarness()
			local buyer = harness.Join(BUYER)
			expect(harness.Data.PromptGift(buyer, "Coins1000", RECIPIENT)).to.equal(true)
			harness.Data.Flush(buyer)

			-- Delivery lands; the buyer's leg is severed immediately afterwards, and
			-- stays severed through the session end, so nothing this receipt wrote to
			-- the buyer's tree ever reaches disk.
			local restore = onceOnDelivery(harness, function()
				harness.Fake.FailSaves = true
				return true
			end)
			expect(harness.Data.HandleReceipt(receipt(111, "f1-a"))).to.equal(NOT_PROCESSED)
			restore()
			harness.Leave(buyer)
			harness.Fake.FailSaves = false

			recipientCollects(harness)

			advance(JUST_PAST)
			local rejoined = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(111, "f1-a"))
			harness.Data.Flush(rejoined)

			expect(
				("d=%s buyerCoins=%d rcpCoins=%d total=%d ledger=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					coinsOf(harness, BUYER),
					coinsOf(harness, RECIPIENT),
					coinsOf(harness, BUYER) + coinsOf(harness, RECIPIENT),
					ledger(storedReserved(harness, BUYER))
				)
			).to.equal("d=GRANTED buyerCoins=0 rcpCoins=1000 total=1000 ledger=[GiftSent]")

			harness.Cleanup()
		end)
	end)

	it("F1-B: past the TTL an OFFLINE retry does NOT also grant the perk to the buyer", function()
		-- FLIPPED when F1 landed, into exactly the value this comment named.
		--   before the fix: buyerVIP=true  rcpVIP=true ledger=[Purchase]
		--   now:            buyerVIP=false rcpVIP=true, decision GRANTED, and the buyer's
		--                   ledger records the settlement as the GIFT it was, never as
		--                   `Purchase`.
		--
		-- The buyer never rejoins, so there is no archived aim here and no load sweep
		-- ever ran: the stale intent is still in its slot, and what settles this is
		-- the PROOF leg -- the recipient's own dedupe ring already holds this
		-- PurchaseId, which a self-purchase's id could never be in.
		--
		-- Same split as F1-A -- recipient paid, buyer's commit lost -- but the buyer
		-- never comes back, so the retry takes handleOfflineReceipt. This is the arm
		-- that matters most in production: a buyer who purchases and closes the game
		-- is the ordinary case, not the exotic one.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			local restore = onceOnDelivery(harness, function()
				harness.Fake.FailSaves = true
				return true
			end)
			expect(harness.Data.HandleReceipt(receipt(222, "f1-b"))).to.equal(NOT_PROCESSED)
			restore()
			harness.Fake.FailSaves = false

			recipientCollects(harness)
			advance(JUST_PAST)
			local decision = harness.Data.HandleReceipt(receipt(222, "f1-b"))

			local buyer = storedReserved(harness, BUYER)
			local recipient = storedReserved(harness, RECIPIENT)
			expect(
				("d=%s buyerVIP=%s rcpVIP=%s ledger=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(buyer, "VIP")),
					tostring(owns(recipient, "VIP")),
					ledger(buyer)
				)
			).to.equal("d=GRANTED buyerVIP=false rcpVIP=true ledger=[GiftSent]")

			harness.Cleanup()
		end)
	end)

	it("F1-C: with NO failure anywhere, a deferred receipt still reaches the recipient", function()
		-- FLIPPED when F1 landed, into exactly the value this comment named.
		--   before the fix: buyerVIP=true  queued=0 ledger=[Purchase]
		--   now:            buyerVIP=false queued=1 ledger=[GiftSent] -- the durable gift
		--                   record still names the recipient, so the receipt delivers where
		--                   it was aimed however long Roblox took to invoke it.
		--
		-- THE ONE WITH NO INFRASTRUCTURE FAILURE AT ALL. No save fails, no message is
		-- dropped, no server dies. The buyer arms the gift, flushes cleanly, leaves
		-- cleanly, and Roblox simply does not call ProcessReceipt until their next
		-- session -- which is the documented retry point. Before the fix the recipient
		-- got nothing, the buyer silently kept the item they paid to give away, and the
		-- ledger called it a purchase. Nothing here PROVES the gift was aimed anywhere
		-- -- no prior attempt, no delivery, nothing on the recipient's key -- so this
		-- is the case the archived aim's PRESUMPTION carries on its own.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			advance(JUST_PAST)
			local rejoined = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(222, "f1-c"))
			harness.Data.Flush(rejoined)

			local buyer = storedReserved(harness, BUYER)
			expect(
				("d=%s buyerVIP=%s queued=%d rcpProfile=%s ledger=[%s] pending=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(buyer, "VIP")),
					mailbox(harness, RECIPIENT),
					tostring(harness.Fake.Persisted[keyOf(harness, RECIPIENT)] ~= nil),
					ledger(buyer),
					pending(buyer)
				)
			).to.equal("d=GRANTED buyerVIP=false queued=1 rcpProfile=false ledger=[GiftSent] pending=[]")

			harness.Cleanup()
		end)
	end)

	it("F1: the settlement names the recipient, so it is distinguishable afterwards", function()
		-- FLIPPED when F1 landed, into exactly what this comment named: the settlement
		-- names the recipient, so `intendedFor` is 94102 rather than nil.
		--
		-- Worth its own spec because it decides whether F1 is RECOVERABLE. A studio
		-- that discovers this defect can only compensate the players it can identify,
		-- and before the fix the buyer's own ledger line carried no recipient, no
		-- GiftId, and the same `From.Type` an ordinary self-purchase writes -- the gift
		-- was gone with no trace on either key that it was ever aimed anywhere. The
		-- line now carries all three. `IntendedFor` is deliberately on the aim-settled
		-- line and not on an ordinary in-window GiftSent: it is what marks the
		-- population an operator has to reconcile.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			advance(JUST_PAST)
			local rejoined = harness.Join(BUYER)
			expect(harness.Data.HandleReceipt(receipt(222, "f1-trace"))).to.equal(GRANTED)
			harness.Data.Flush(rejoined)

			local line
			for _, entry in storedReserved(harness, BUYER).PurchaseLogs.Robux do
				if entry.PurchaseId == "f1-trace" then
					line = entry
				end
			end
			expect(("type=%s intendedFor=%s to=%s giftId=%s"):format(
				tostring(line.From.Type),
				tostring(line.From.IntendedFor),
				tostring(line.From.ToUserId),
				-- The GiftId is a fresh guid, so its PRESENCE is the assertion.
				tostring(line.From.GiftId ~= nil)
			)).to.equal("type=GiftSent intendedFor=94102 to=94102 giftId=true")

			harness.Cleanup()
		end)
	end)

	it("F1: the outcome no longer depends on NoGiftIntentPolicy at all", function()
		-- Not a characterisation of the defect so much as of a RULED-OUT fix, pinned so
		-- nobody spends the fix budget on it a second time. The Hold branch sits inside
		-- `product.Grants and not product.Grant and self.Owns(buyer, perk)`, and a gift
		-- buyer is precisely someone who does NOT own the perk they are buying. Hold
		-- never ran; the buyer was granted exactly as under the default policy.
		--
		-- FLIPPED as this comment named it: the aim is consulted BEFORE the no-intent
		-- policy is reached at all, so buyerVIP=false under either policy and the
		-- option no longer has anything to do with this timeline.
		withClock(T0, function(advance)
			local harness = makeHarness({ NoGiftIntentPolicy = "Hold" })
			armGiftAndLeave(harness, "GiftVIP")

			advance(JUST_PAST)
			local rejoined = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(222, "f1-hold"))
			harness.Data.Flush(rejoined)

			expect(
				("d=%s buyerVIP=%s"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(storedReserved(harness, BUYER), "VIP"))
				)
			).to.equal("d=GRANTED buyerVIP=false")

			harness.Cleanup()
		end)
	end)

	----------------------------------------------------------------------------------
	-- THE BUYER'S LEGITIMATE NO-INTENT PATHS.
	-- The blast radius of the fix. A durable gift record consulted too broadly -- by
	-- buyer, by product, by "has this player ever gifted" -- turns ordinary purchases
	-- into refusals, which is a worse defect than the one being closed because it hits
	-- every player instead of a timing window. None of these may change.
	----------------------------------------------------------------------------------

	it("a genuine online self-purchase of a consumable still grants, with no gift anywhere", function()
		withClock(T0, function()
			local harness = makeHarness()
			local buyer = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(111, "self-consumable"))
			harness.Data.Flush(buyer)

			local reserved = storedReserved(harness, BUYER)
			expect(
				("d=%s coins=%d ledger=[%s] marks=%d"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					coinsOf(harness, BUYER),
					ledger(reserved),
					processedCount(reserved, "self-consumable")
				)
			).to.equal("d=GRANTED coins=1000 ledger=[Purchase] marks=1")

			harness.Cleanup()
		end)
	end)

	it("a genuine online self-purchase of a perk product still grants", function()
		withClock(T0, function()
			local harness = makeHarness()
			local buyer = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(222, "self-perk"))
			harness.Data.Flush(buyer)

			expect(
				("d=%s vip=%s"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(storedReserved(harness, BUYER), "VIP"))
				)
			).to.equal("d=GRANTED vip=true")

			harness.Cleanup()
		end)
	end)

	it("a genuine OFFLINE self-purchase of a perk product still grants", function()
		-- The offline no-intent arm is where a gift record would be cheapest to consult
		-- and easiest to over-consult: it is already reading the buyer's whole profile.
		withClock(T0, function()
			local harness = makeHarness()
			local buyer = harness.Join(BUYER)
			harness.Data.Flush(buyer)
			harness.Leave(buyer)

			local decision = harness.Data.HandleReceipt(receipt(222, "self-perk-offline"))

			local reserved = storedReserved(harness, BUYER)
			expect(
				("d=%s vip=%s ledger=[%s] marks=%d"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(reserved, "VIP")),
					ledger(reserved),
					processedCount(reserved, "self-perk-offline")
				)
			).to.equal("d=GRANTED vip=true ledger=[Purchase] marks=1")

			harness.Cleanup()
		end)
	end)

	it("a buyer who gifted product A can still buy product B for themselves past the TTL", function()
		-- The record is per-PURCHASE, never per-player. A gift of GiftVIP that is still
		-- unsettled must not make GiftPRO unbuyable.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			advance(JUST_PAST)
			local rejoined = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(333, "other-product"))
			harness.Data.Flush(rejoined)

			expect(
				("d=%s pro=%s"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(storedReserved(harness, BUYER), "PRO"))
				)
			).to.equal("d=GRANTED pro=true")

			harness.Cleanup()
		end)
	end)

	it("a SETTLED gift of a product does not block a later self-purchase of that same product", function()
		-- THE SHARPEST BLAST-RADIUS CASE, and the one an over-broad record breaks
		-- silently. Gift #1 settles perfectly: delivered, marked, intent cleared. Long
		-- past the TTL the same buyer buys the same product for themselves under a NEW
		-- purchaseId. A record keyed by (buyer, product) would answer "already
		-- delivered" and refuse a purchase Roblox has already taken money for; only a
		-- record keyed by purchaseId gets this right.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")
			expect(harness.Data.HandleReceipt(receipt(222, "settled-gift"))).to.equal(GRANTED)
			recipientCollects(harness)

			advance(JUST_PAST)
			local rejoined = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(222, "later-self-buy"))
			harness.Data.Flush(rejoined)

			local buyer = storedReserved(harness, BUYER)
			expect(
				("d=%s buyerVIP=%s rcpVIP=%s ledger=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(buyer, "VIP")),
					tostring(owns(storedReserved(harness, RECIPIENT), "VIP")),
					ledger(buyer)
				)
			).to.equal("d=GRANTED buyerVIP=true rcpVIP=true ledger=[GiftSent,Purchase]")

			harness.Cleanup()
		end)
	end)

	it("an UNDELIVERED gift's receipt still settles to the recipient inside the TTL after a failed send", function()
		-- The other direction of the same rule: a record must not be written (and
		-- believed) before the delivery is durable. Here the first send genuinely
		-- fails, so the retry has to deliver -- not settle silently as "already done".
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			harness.Fake.FailMessages = true
			expect(harness.Data.HandleReceipt(receipt(222, "undelivered"))).to.equal(NOT_PROCESSED)
			harness.Fake.FailMessages = false

			advance(60)
			local decision = harness.Data.HandleReceipt(receipt(222, "undelivered"))
			recipientCollects(harness)

			local buyer = storedReserved(harness, BUYER)
			expect(
				("d=%s buyerVIP=%s rcpVIP=%s ledger=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(buyer, "VIP")),
					tostring(owns(storedReserved(harness, RECIPIENT), "VIP")),
					ledger(buyer)
				)
			).to.equal("d=GRANTED buyerVIP=false rcpVIP=true ledger=[GiftSent]")

			harness.Cleanup()
		end)
	end)

	----------------------------------------------------------------------------------
	-- THE EXISTING DEDUPE RING: still works, and is NOT the mechanism.
	----------------------------------------------------------------------------------

	it("the dedupe ring still absorbs a retried receipt without granting twice", function()
		withClock(T0, function()
			local harness = makeHarness()
			local buyer = harness.Join(BUYER)
			expect(harness.Data.HandleReceipt(receipt(111, "ring-retry"))).to.equal(GRANTED)
			local second = harness.Data.HandleReceipt(receipt(111, "ring-retry"))
			harness.Data.Flush(buyer)

			local reserved = storedReserved(harness, BUYER)
			expect(
				("d=%s coins=%d marks=%d ledger=[%s]"):format(
					if second == GRANTED then "GRANTED" else "NOT_PROCESSED",
					coinsOf(harness, BUYER),
					processedCount(reserved, "ring-retry"),
					ledger(reserved)
				)
			).to.equal("d=GRANTED coins=1000 marks=1 ledger=[Purchase]")

			harness.Cleanup()
		end)
	end)

	it("a re-sent gift message with the same purchase id is a no-op on the recipient", function()
		-- The recipient's own ring is what makes a gift re-send safe, and F1's fix must
		-- not disturb it: the buyer-side record answers a different question (who was
		-- this aimed at) and cannot replace this one (was this already applied here).
		withClock(T0, function()
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")
			expect(harness.Data.HandleReceipt(receipt(222, "resend"))).to.equal(GRANTED)

			-- A second, identical delivery of the same paid gift.
			harness.Ctx.Persistence.Store:MessageAsync(harness.Ctx.Persistence.KeyFor(RECIPIENT), {
				ScribeGift = true,
				GiftId = "whatever",
				PurchaseId = "resend",
				Product = "GiftVIP",
				FromUserId = BUYER,
			})
			recipientCollects(harness)

			local recipient = storedReserved(harness, RECIPIENT)
			expect(
				("vip=%s marks=%d ledger=[%s] queued=%d"):format(
					tostring(owns(recipient, "VIP")),
					processedCount(recipient, "resend"),
					ledger(recipient),
					mailbox(harness, RECIPIENT)
				)
			).to.equal("vip=true marks=1 ledger=[GiftReceived] queued=0")

			harness.Cleanup()
		end)
	end)

	it("the ring's COUNT eviction can still double-grant, which is why F1's record cannot live in it", function()
		-- CONSTRAINT (c), measured rather than asserted in prose. The ring evicts by age
		-- first, but its count backstop drops the OLDEST un-expired entry, and a receipt
		-- Roblox retries for that entry is granted a second time. Parking a durable gift
		-- record inside this structure would inherit exactly the flaw F1 is closing.
		--
		-- Loud, at least: PurchaseIdsEvicted counts it. That is what makes it a
		-- documented backstop rather than a silent corruption -- and still not somewhere
		-- to store the identity of a paid gift.
		withClock(T0, function()
			local harness = makeHarness({ MaxProcessedPurchaseIds = 3 })
			local buyer = harness.Join(BUYER)

			local evictedBefore = Metrics.Get().PurchaseIdsEvicted or 0
			for i = 1, 3 do
				expect(harness.Data.HandleReceipt(receipt(111, `ring-{i}`))).to.equal(GRANTED)
			end
			expect((Metrics.Get().PurchaseIdsEvicted or 0) - evictedBefore).to.equal(0)

			-- One more purchase pushes the first id out while it is still well inside
			-- PurchaseIdTTL, and says so.
			expect(harness.Data.HandleReceipt(receipt(111, "ring-4"))).to.equal(GRANTED)
			local evicted = (Metrics.Get().PurchaseIdsEvicted or 0) - evictedBefore

			-- Roblox retries the forgotten one. It is granted AGAIN.
			expect(harness.Data.HandleReceipt(receipt(111, "ring-1"))).to.equal(GRANTED)
			harness.Data.Flush(buyer)

			expect(("evicted=%d coins=%d"):format(evicted, coinsOf(harness, BUYER))).to.equal("evicted=1 coins=5000")

			harness.Cleanup()
		end)
	end)

	----------------------------------------------------------------------------------
	-- STORAGE. The buyer's key must not grow without bound.
	----------------------------------------------------------------------------------

	it("the buyer's key does not grow with the number of gift purchases", function()
		-- THE STORAGE RULE THIS NET PINS, and it holds before and after the fix:
		--   * no single container under the buyer's reserved root exceeds 200 entries
		--   * doubling the number of purchases does not add a single node
		--   * the whole reserved root stays under a 3000-node ceiling
		--
		-- The middle one is the real assertion, and it is the one a magic byte budget
		-- cannot make: 300 settled gift purchases and 600 settled gift purchases must
		-- leave the profile the SAME SIZE. A record that is merely small still fails it
		-- if it is uncapped, which is exactly the failure mode worth catching -- the
		-- profile of a whale who gifts every day is where it would surface, months after
		-- the fix shipped and nowhere near the change.
		--
		-- The 3000 ceiling exists so the per-container rule cannot be satisfied by adding
		-- several capped containers instead of one. It is sized from what is there today
		-- (1602 nodes: a 199-entry dedupe ring at ~3 nodes each, a 100-entry Robux ledger
		-- at ~10) plus room for ONE 200-entry gift record carrying a recipient, a giftId,
		-- a product, a delivered flag and a timestamp (~1200).
		--
		-- WHY A COUNT CAP AND NOT A TTL ALONE, for the record F1 introduces: it must
		-- outlive the intent by the whole Roblox receipt-retry window, and that window is
		-- not knowable from this repo. If Roblox only re-invokes ProcessReceipt on rejoin,
		-- the record has to survive until the buyer's next session, which may be months --
		-- so it cannot be sized by time alone. A count cap with age pruning underneath it
		-- (the shape the dedupe ring already uses) bounds the bytes without putting a
		-- clock on the recipient's identity.
		withClock(T0, function(advance)
			local harness = makeHarness()
			local buyer = harness.Join(BUYER)

			--- Every table under the buyer's PERSISTED reserved root: the largest one, and
			--- the total number of entries across all of them.
			local function census(): (string, number, number)
				local biggestName, biggest, nodes = "<none>", 0, 0
				local function walk(name: string, value: any)
					if type(value) ~= "table" then
						return
					end
					local count = 0
					for _ in value do
						count += 1
					end
					nodes += count
					if count > biggest then
						biggestName, biggest = name, count
					end
					for key, child in value do
						walk(`{name}.{tostring(key)}`, child)
					end
				end
				for key, value in storedReserved(harness, BUYER) do
					walk(tostring(key), value)
				end
				return biggestName, biggest, nodes
			end

			local function gift(from: number, to: number)
				for i = from, to do
					expect(harness.Data.PromptGift(buyer, "GiftVIP", 950000 + i)).to.equal(true)
					expect(harness.Data.HandleReceipt(receipt(222, `bulk-{i}`))).to.equal(GRANTED)
					advance(1) -- distinct timestamps; still far inside PurchaseIdTTL
				end
				harness.Data.Flush(buyer)
			end

			-- 300 is already past every cap in play (the 200-entry dedupe ring, the
			-- 100-entry ledger), so the first census is a STEADY STATE, not a ramp.
			gift(1, 300)
			local firstBiggest, firstNodes = select(2, census()), select(3, census())
			gift(301, 600)
			local biggestName, biggest, nodes = census()

			expect(
				("biggest=%s over=%s grew=%s underCeiling=%s"):format(
					biggestName,
					tostring(biggest > MAX_CONTAINER_ENTRIES or firstBiggest > MAX_CONTAINER_ENTRIES),
					tostring(nodes ~= firstNodes),
					tostring(nodes <= MAX_RESERVED_NODES)
				)
			).to.equal("biggest=ProcessedPurchaseIds over=false grew=false underCeiling=true")

			harness.Cleanup()
		end)
	end)
end
