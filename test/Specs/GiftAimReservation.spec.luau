--!nonstrict
-- D2's NET: THE GIFT-AIM CAP'S ACCOUNTING, AND THE PAID GIFT IT CAN LOSE.
--
-- WHAT THE CODE PROMISES. src/Server/Monetization.luau:80-88, on the cap:
--
--   "at the cap it refuses INTAKE instead, at PromptGift, before any money moves
--    (the same fail-closed move the Outage check makes two lines above it). A
--    refused prompt costs a gift that was never paid for; an evicted aim would cost
--    a gift that was."
--
-- WHAT IT ACTUALLY COUNTS. src/Server/Monetization.luau:610-613:
--
--     local function aimStoreIsFull(): boolean
--         local aims = reservedRaw(entry.LiveData).GiftAims
--         return aims[tostring(product.Id)] == nil and Util.count(aims) >= giftAimCap
--     end
--
-- ARCHIVED aims only. It never counts the live `PendingGifts` intents, every one of
-- which will need an aim slot of its own at the next load sweep. So the intake it
-- refuses is not the intake it is about to receive: with 60 aims stored -- four free
-- slots -- a buyer may arm twenty more prompts in one session, pay for all twenty,
-- and have sixteen of the aims dropped by `archiveGiftAim` at the next load.
--
-- WHY THAT IS F1-C REOPENED. A dropped aim is the record of WHO the gift was for.
-- Without it a receipt Roblox retries on the next session has nothing to
-- distinguish it from a self-purchase, so it falls to the no-intent policy and the
-- perk is granted to the BUYER. The recipient gets nothing, and the buyer silently
-- keeps what they paid to give away. That is exactly the failure the aim store was
-- built to close, arriving through the cap instead of through the sweep.
--
-- THE SECOND EFFECT, same root, lower severity: an aim is created by ANY prompt that
-- goes stale, paid or not. Sixty-four dismissed dialogs -- no money moved at all --
-- fill the store and deny the buyer gifting.
--
-- WHAT EACH BLOCK IS.
--   * DEFECT, MUST FLIP: the measured 65-product case, end to end, in money.
--   * DEFECT, MUST FLIP: the same bug stated at the prompt, without money -- four
--     free slots accept twenty prompts.
--   * CONTROLS the accounting change must not break, and they are the reason this
--     file is longer than the two defects:
--       - a genuinely full store still refuses, and the refusal still costs nothing
--         paid and nothing prompted;
--       - an aim already in the store is NEVER evicted to make room. This is the
--         property that stops the cap becoming a double-grant source, and the
--         accounting change reaches the same function that enforces it;
--       - ordinary gifting under the cap is untouched -- a normal catalogue armed
--         in one session gains no refusals;
--       - the dismissed-dialog store, pinned as it stands today so the fix's effect
--         on it is visible rather than inferred.
--
-- SCOPE. Nothing here proposes redesigning the aim store, changing its cap, its TTL,
-- or what it evicts. GiftAimHorizon.spec owns the mechanism; this file owns the two
-- numbers the mechanism is driven by.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Metrics = require(Root.Scribe.Internal.Metrics)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local BUYER = 91401
	local RECIPIENT = 91402
	local OTHER_RECIPIENT = 91403
	local T0 = 1700000000

	-- Spelled out rather than imported, so a silent change to either constant fails
	-- here instead of quietly making these scenarios unreachable.
	local INTENT_TTL = 3600 -- GiftIntentTTL default
	local AIM_CAP = 64 -- GIFT_AIM_CAP
	local MAX_PENDING = 20 -- GiftMaxPending default: the per-session arming budget

	local function manyProducts(n: number)
		local products = {}
		for i = 1, n do
			products["P" .. i] = { Id = 1000 + i, Category = "Gamepass", Grants = "PK" .. i }
		end
		return products
	end

	local function makeHarness(productCount: number, extraOptions)
		local options = {
			Products = manyProducts(productCount),
			GiftCooldown = 0,
			PromptProductPurchase = function() end,
		}
		for key, value in extraOptions or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options })
	end

	local function receipt(index: number, purchaseId: string)
		return {
			PlayerId = BUYER,
			ProductId = 1000 + index,
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

	local function storedReserved(harness, userId: number)
		local profile = harness.Fake.Persisted[keyOf(harness, userId)]
		return (profile and profile._Scribe) or {}
	end

	local function mailbox(harness, userId: number): number
		return #(harness.Fake.Mailboxes[keyOf(harness, userId)] or {})
	end

	local function countOf(container): number
		local n = 0
		for _ in container or {} do
			n += 1
		end
		return n
	end

	local function aimFor(harness, index: number): any
		return (storedReserved(harness, BUYER).GiftAims or {})[tostring(1000 + index)]
	end

	local function ownsPerk(harness, index: number): boolean
		local perks = storedReserved(harness, BUYER).Perks
		return type(perks) == "table" and perks["PK" .. index] == true
	end

	--- Every stored aim as "<productId>=<recipient>|<giftId>", sorted. Identity, not
	--- just a count: an eviction that replaced one aim with another would keep the
	--- count and change this.
	local function aimCensus(harness): { [string]: string }
		local out = {}
		for productIdStr, aim in storedReserved(harness, BUYER).GiftAims or {} do
			out[productIdStr] = ("%s|%s"):format(tostring(aim.RecipientId), tostring(aim.GiftId))
		end
		return out
	end

	--- Arm one gift per named product, at most MAX_PENDING per session (the buyer's
	--- own pending-gift budget), leaving each session's intents to go stale so the
	--- NEXT join sweeps them into the aim store.
	---
	--- Returns how many prompts were accepted and the first refusal reason, and
	--- leaves the buyer OFF the server with the last batch still pending: the caller
	--- decides when the final sweep happens, because for the defect blocks the sweep
	--- IS the event under test.
	local function armAcrossSessions(harness, advance, indices: { number }): (number, number, string?)
		local accepted, refused, firstReason = 0, 0, nil
		local at = 1
		while at <= #indices do
			local buyer = harness.Join(BUYER)
			for _ = 1, MAX_PENDING do
				if at > #indices then
					break
				end
				local ok, reason = harness.Data.PromptGift(buyer, "P" .. indices[at], RECIPIENT)
				if ok then
					accepted += 1
				else
					refused += 1
					firstReason = firstReason or reason
				end
				at += 1
			end
			harness.Data.Flush(buyer)
			harness.Leave(buyer)
			advance(INTENT_TTL + 1)
		end
		return accepted, refused, firstReason
	end

	local function range(from: number, to: number): { number }
		local out = {}
		for i = from, to do
			table.insert(out, i)
		end
		return out
	end

	--- Fill the aim store to exactly `count` aims and leave the buyer ON the server
	--- with an empty pending slate.
	local function storeWith(harness, advance, count: number)
		armAcrossSessions(harness, advance, range(1, count))
		local buyer = harness.Join(BUYER) -- this join is the sweep for the last batch
		harness.Data.Flush(buyer)
		return buyer
	end

	--------------------------------------------------------------------------------
	-- 1. THE DEFECT, IN MONEY. The measured 65-product case.
	--------------------------------------------------------------------------------

	it(
		"GUARD (was a DEFECT, flipped when the cap began reserving against pending intents): no paid gift loses its aim",
		function()
			-- THE SMALLEST CATALOGUE THAT REACHES IT IS 65. Aims are keyed by product Id,
			-- one per product, so overrunning a 64-slot store takes 65 distinct giftable
			-- products; and the buyer may only hold GiftMaxPending (20) intents at once, so
			-- they are armed across sessions.
			--
			-- TIMELINE.
			--   sessions 1-3   P1..P60 armed and left to go stale -> 60 aims stored.
			--   session 4      P61..P65 armed. `aimStoreIsFull` sees 60 < 64 and 60 < 64
			--                  and 60 < 64 and 60 < 64 and 60 < 64 -- it never counts the
			--                  intents piling up beside it -- so all five are accepted and
			--                  the buyer can pay for all five.
			--   next load      the sweep archives four and DROPS one.
			--
			-- THEN THE MONEY. Roblox retries the dropped gift's receipt on the buyer's next
			-- session. There is no live intent and no aim, so it falls to the no-intent
			-- policy: the perk is granted to the BUYER and the recipient is sent nothing.
			-- The kept aim beside it is measured in the same breath as the contrast --
			-- identical purchase, identical timing, and it routes correctly.
			--
			-- AFTER THE FIX the fifth prompt is refused before the dialog opens, so there
			-- is no fifth receipt at all, dropped=0, and the pin becomes
			--   "armed=64 refused=1 aims=64 dropped=0".
			withClock(T0, function(advance)
				local harness = makeHarness(AIM_CAP + 1, { PurchaseLog = {} })

				local droppedBefore = Metrics.Get().GiftAimsDropped or 0
				local armed, refused = armAcrossSessions(harness, advance, range(1, AIM_CAP + 1))

				-- The sweep that loses the aim.
				local buyer = harness.Join(BUYER)
				harness.Data.Flush(buyer)
				task.wait()

				-- Nothing is dropped any more, so there is no lost aim to find. What must be
				-- true instead: every product that was ARMED kept its aim, and the one the
				-- cap refused was never armed at all. Finding them separately keeps the
				-- assertion honest if the accounting ever regresses, because a dropped aim
				-- would show up here as an armed product with no aim.
				local overflowIndex = AIM_CAP + 1
				local keptIndex, lostIndex
				for i = 61, AIM_CAP do
					if aimFor(harness, i) ~= nil then
						keptIndex = keptIndex or i
					else
						lostIndex = lostIndex or i
					end
				end

				local aimsAfterSweep = countOf(storedReserved(harness, BUYER).GiftAims)
				local droppedCount = (Metrics.Get().GiftAimsDropped or 0) - droppedBefore
				local capLogged = #Scribe.GetRecentLogs({ Code = "GIFT_AIM_CAP_REACHED", Limit = 5 }) > 0

				-- An armed gift settles to its recipient, as it always should have.
				local d2 = harness.Data.HandleReceipt(receipt(keptIndex, "D2-kept"))
				harness.Data.Flush(buyer)
				local ownsKept, queuedAfterKept = ownsPerk(harness, keptIndex), mailbox(harness, RECIPIENT)

				expect(
					("armed=%d refused=%d aims=%d dropped=%d capLogged=%s | armedWithNoAim=%s | overflowArmed=%s | kept: d=%s buyerOwns=%s rcpQueued=%d"):format(
						armed,
						refused,
						aimsAfterSweep,
						droppedCount,
						tostring(capLogged),
						tostring(lostIndex),
						tostring(aimFor(harness, overflowIndex) ~= nil),
						if d2 == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(ownsKept),
						queuedAfterKept
					)
				).to.equal(
					"armed=64 refused=1 aims=64 dropped=0 capLogged=true "
						.. "| armedWithNoAim=nil | overflowArmed=false "
						.. "| kept: d=GRANTED buyerOwns=false rcpQueued=1"
				)

				harness.Cleanup()
			end)
		end
	)

	--------------------------------------------------------------------------------
	-- 2. THE SAME DEFECT AT THE PROMPT, with no money in it at all.
	--------------------------------------------------------------------------------

	it("GUARD (was a DEFECT, flipped with the same fix): four free slots accept four prompts, not twenty", function()
		-- The accounting bug stated as a pure counting property, so a fix can be
		-- checked without driving receipts. The store holds 60 aims; four slots are
		-- free; the buyer arms their whole pending budget of twenty in one session and
		-- every single one is accepted, because `aimStoreIsFull` re-reads only the
		-- archived container and the twenty intents beside it are invisible to it.
		--
		-- AFTER THE FIX: "free=4 accepted=4 refused=16", and the first refusal is the
		-- existing cap reason ("too many unsettled gift purchases; try again later").
		withClock(T0, function(advance)
			local harness = makeHarness(AIM_CAP + MAX_PENDING)
			local buyer = storeWith(harness, advance, AIM_CAP - 4) -- 60 aims, 4 slots free

			local accepted, refused = 0, 0
			for i = AIM_CAP - 3, AIM_CAP - 3 + MAX_PENDING - 1 do
				local ok = harness.Data.PromptGift(buyer, "P" .. i, RECIPIENT)
				if ok then
					accepted += 1
				else
					refused += 1
				end
			end
			harness.Data.Flush(buyer)

			expect(
				("free=%d accepted=%d refused=%d pending=%d"):format(
					AIM_CAP - countOf(storedReserved(harness, BUYER).GiftAims),
					accepted,
					refused,
					countOf(storedReserved(harness, BUYER).PendingGifts)
				)
			).to.equal("free=4 accepted=4 refused=16 pending=4")

			harness.Cleanup()
		end)
	end)

	--------------------------------------------------------------------------------
	-- 3. THE CONTROLS. Everything the accounting change must leave standing.
	--------------------------------------------------------------------------------

	it("CONTROL: a genuinely full store still refuses the prompt, and the refusal costs nothing paid", function()
		-- The fail-closed half of the cap, and the half a reservation change is most
		-- likely to weaken on the way past: if reserving against pending intents were
		-- implemented as a REPLACEMENT for the archived count rather than an addition,
		-- a store full of aims with no pending intents would suddenly accept.
		--
		-- "Costs nothing" is asserted, not asserted-by-comment: no Robux ledger line,
		-- no GiftPrompts metric, and the store is byte-identical afterwards.
		withClock(T0, function(advance)
			local harness = makeHarness(AIM_CAP + 1)
			local buyer = storeWith(harness, advance, AIM_CAP)

			local before = aimCensus(harness)
			local promptsBefore = Metrics.Get().GiftPrompts or 0
			local ok, reason = harness.Data.PromptGift(buyer, "P" .. (AIM_CAP + 1), RECIPIENT)
			harness.Data.Flush(buyer)

			local after = aimCensus(harness)
			local same = countOf(before) == countOf(after)
			for productIdStr, value in before do
				if after[productIdStr] ~= value then
					same = false
				end
			end

			expect(
				("ok=%s reason=%s aims=%d unchanged=%s pending=%d robuxLines=%d prompts=%d"):format(
					tostring(ok),
					tostring(reason),
					countOf(after),
					tostring(same),
					countOf(storedReserved(harness, BUYER).PendingGifts),
					countOf((storedReserved(harness, BUYER).PurchaseLogs or {}).Robux),
					(Metrics.Get().GiftPrompts or 0) - promptsBefore
				)
			).to.equal(
				"ok=false reason=too many unsettled gift purchases; try again later "
					.. "aims=64 unchanged=true pending=0 robuxLines=0 prompts=0"
			)

			harness.Cleanup()
		end)
	end)

	it("CONTROL: an aim already in the store is never evicted to make room", function()
		-- THE PROPERTY THAT STOPS THE CAP BECOMING A DOUBLE-GRANT SOURCE, and the one
		-- the accounting change reaches directly -- both `aimStoreIsFull` bodies live
		-- one function away from `archiveGiftAim`'s write. An aim inside the horizon
		-- may be the last durable record of a gift ALREADY PAID FOR; dropping it to
		-- seat a newer one is the receipt-dedupe ring's documented count-eviction flaw
		-- rebuilt in a container that routes real money.
		--
		-- Three pressures in one block: a refused new product, a re-arm of a product
		-- that already holds an aim (which needs no new room and must still work), and
		-- the SWEEP that follows it -- the write that would do the evicting.
		withClock(T0, function(advance)
			local harness = makeHarness(AIM_CAP + 1)
			local buyer = storeWith(harness, advance, AIM_CAP)
			local before = aimCensus(harness)

			local refusedNew = not harness.Data.PromptGift(buyer, "P" .. (AIM_CAP + 1), RECIPIENT)
			-- Re-aimed at someone else, so its aim is DISTINGUISHABLE after the sweep.
			local reArmed = harness.Data.PromptGift(buyer, "P1", OTHER_RECIPIENT)
			harness.Data.Flush(buyer)
			harness.Leave(buyer)
			advance(INTENT_TTL + 1)
			local rejoined = harness.Join(BUYER) -- the sweep: P1's new intent archives
			harness.Data.Flush(rejoined)

			local after = aimCensus(harness)
			local survived, lost = 0, 0
			for productIdStr, value in before do
				if productIdStr == "1001" then
					continue -- P1, deliberately replaced by its own re-arm
				end
				if after[productIdStr] == value then
					survived += 1
				else
					lost += 1
				end
			end

			expect(
				("refusedNew=%s reArmed=%s aims=%d survived=%d lost=%d p1Rewritten=%s"):format(
					tostring(refusedNew),
					tostring(reArmed),
					countOf(after),
					survived,
					lost,
					tostring(after["1001"] ~= nil and after["1001"] ~= before["1001"])
				)
			).to.equal("refusedNew=true reArmed=true aims=64 survived=63 lost=0 p1Rewritten=true")

			harness.Cleanup()
		end)
	end)

	it("CONTROL: the SWEEP hitting the cap refuses the new aim -- it never evicts a stored one", function()
		-- The other door onto the same property, and the one the prompt-side block
		-- above cannot reach: `archiveGiftAim` has its OWN `aimStoreIsFull`, and it is
		-- the function that actually WRITES to the store. A full store at the prompt
		-- means no intent is ever armed, so the sweep's cap branch is never entered
		-- from there. It is entered from exactly the D2 shape -- more pending intents
		-- than free slots -- which is why this control has to be driven through the
		-- defect's own setup.
		--
		-- The pin is deliberately written to hold on BOTH sides of the accounting fix.
		-- Today five intents compete for four slots and four are archived; after the
		-- fix only four are ever armed and the same four are archived. Either way the
		-- sixty aims already in the store are untouched, which is the whole assertion:
		-- an aim inside the horizon may be the last durable record of a gift already
		-- paid for, and seating a newer one on top of it is the receipt-dedupe ring's
		-- count-eviction flaw rebuilt where it routes money.
		withClock(T0, function(advance)
			local harness = makeHarness(AIM_CAP + 1)
			local buyer = storeWith(harness, advance, AIM_CAP - 4) -- 60 aims
			local before = aimCensus(harness)

			for i = AIM_CAP - 3, AIM_CAP + 1 do -- five products, four free slots
				harness.Data.PromptGift(buyer, "P" .. i, OTHER_RECIPIENT)
			end
			harness.Data.Flush(buyer)
			harness.Leave(buyer)
			advance(INTENT_TTL + 1)
			local rejoined = harness.Join(BUYER) -- the sweep, at the cap
			harness.Data.Flush(rejoined)

			local after = aimCensus(harness)
			local survived, lost = 0, 0
			for productIdStr, value in before do
				if after[productIdStr] == value then
					survived += 1
				else
					lost += 1
				end
			end
			local newlyArchived = 0
			for i = AIM_CAP - 3, AIM_CAP + 1 do
				if after[tostring(1000 + i)] ~= nil then
					newlyArchived += 1
				end
			end

			expect(
				("storedBefore=%d survived=%d lost=%d aims=%d newlyArchived=%d"):format(
					countOf(before),
					survived,
					lost,
					countOf(after),
					newlyArchived
				)
			).to.equal("storedBefore=60 survived=60 lost=0 aims=64 newlyArchived=4")

			harness.Cleanup()
		end)
	end)

	it("CONTROL: ordinary gifting under the cap gains no refusals, and every gift reaches its recipient", function()
		-- The regression a reservation change buys its safety with if it is written
		-- carelessly: counting pending intents against the cap must not start refusing
		-- a normal catalogue. Eight products, eight gifts, one session, an empty aim
		-- store -- the shape of essentially every real game.
		withClock(T0, function()
			local harness = makeHarness(8)
			local buyer = harness.Join(BUYER)

			local refusals, granted = 0, 0
			for i = 1, 8 do
				local ok = harness.Data.PromptGift(buyer, "P" .. i, RECIPIENT + i)
				if not ok then
					refusals += 1
				end
				if harness.Data.HandleReceipt(receipt(i, `ordinary-{i}`)) == GRANTED then
					granted += 1
				end
			end
			harness.Data.Flush(buyer)

			local delivered = 0
			local buyerPerks = 0
			for i = 1, 8 do
				delivered += mailbox(harness, RECIPIENT + i)
				if ownsPerk(harness, i) then
					buyerPerks += 1
				end
			end

			expect(
				("refusals=%d granted=%d delivered=%d buyerPerks=%d aims=%d pending=%d"):format(
					refusals,
					granted,
					delivered,
					buyerPerks,
					countOf(storedReserved(harness, BUYER).GiftAims),
					countOf(storedReserved(harness, BUYER).PendingGifts)
				)
			).to.equal("refusals=0 granted=8 delivered=8 buyerPerks=0 aims=0 pending=0")

			harness.Cleanup()
		end)
	end)

	it("CONTROL: sixty-four DISMISSED dialogs -- no money moved -- fill the store and deny gifting", function()
		-- THE SECOND EFFECT, pinned as it stands so the accounting fix's effect on it
		-- is visible rather than argued. Every aim here came from a prompt that was
		-- armed and abandoned: not one receipt was ever processed, the Robux ledger is
		-- empty, and the store is nonetheless full and the buyer cannot gift a product
		-- it does not already hold an aim for.
		--
		-- WHAT THE D2 FIX DOES TO THIS BLOCK: nothing. Reserving against pending
		-- intents changes WHEN a prompt is refused, not whether an abandoned prompt
		-- becomes an aim; these 64 are archived across sessions, four at most in flight
		-- at a time, so every prompt above is still accepted and the store still fills.
		-- Closing this one needs the intent DROPPED when the dialog is dismissed
		-- (PromptProductPurchaseFinished with isPurchased=false), which is a different
		-- change and out of scope here. If this block flips, the fix did more than the
		-- accounting.
		withClock(T0, function(advance)
			local harness = makeHarness(AIM_CAP + 1)
			local buyer = storeWith(harness, advance, AIM_CAP)

			local refusedNew = select(2, harness.Data.PromptGift(buyer, "P" .. (AIM_CAP + 1), RECIPIENT))
			-- The one gift still available to them: a product whose aim they already
			-- hold. Proof the denial is the cap and not a broken buyer.
			local reArmOk = harness.Data.PromptGift(buyer, "P2", RECIPIENT)
			harness.Data.Flush(buyer)

			local reserved = storedReserved(harness, BUYER)
			expect(
				("aims=%d robuxLines=%d processed=%d refusedNew=%s reArmOk=%s"):format(
					countOf(reserved.GiftAims),
					countOf((reserved.PurchaseLogs or {}).Robux),
					countOf(reserved.ProcessedPurchaseIds),
					tostring(refusedNew),
					tostring(reArmOk)
				)
			).to.equal(
				"aims=64 robuxLines=0 processed=0 refusedNew=too many unsettled gift purchases; try again later reArmOk=true"
			)

			harness.Cleanup()
		end)
	end)
end
