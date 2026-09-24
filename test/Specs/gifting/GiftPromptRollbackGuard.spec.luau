--!nonstrict
-- Prompt failures clear only their own intent.
-- Legacy writers may replace the slot while a save or marketplace call yields.
-- These fixtures preserve the GiftId guard independently of prompt serialization.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local BUYER = 90301
	local FIRST = 90302 -- the recipient of the gift whose PromptGift fails
	local SECOND = 90303 -- the recipient of the gift that takes the slot over
	local T0 = 1700000000
	local PRODUCT_ID = 222
	-- Advance beyond the former prompt window in legacy-interleave fixtures.
	local PROMPT_WINDOW = 120

	local function makeHarness(extraOptions)
		local finished = require(Root.Scribe.Internal.Signal).new()
		local options = {
			Products = {
				GiftVIP = { Id = PRODUCT_ID, Category = "Gamepass", Grants = "VIP" },
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

	local function receipt(purchaseId: string)
		return {
			PlayerId = BUYER,
			ProductId = PRODUCT_ID,
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

	local function slot(entry): any
		return entry.LiveData._Scribe.PendingGifts[tostring(PRODUCT_ID)]
	end

	local function slotState(entry, expectedGiftId: string?): string
		local live = slot(entry)
		if live == nil then
			return "empty"
		end
		return ("to=%s isExpected=%s"):format(
			tostring(live.RecipientId),
			tostring(expectedGiftId ~= nil and tostring(live.GiftId) == expectedGiftId)
		)
	end

	local function keyOf(harness, userId: number): string
		return "Default/" .. harness.Ctx.Persistence.KeyFor(userId)
	end

	local function mailbox(harness, userId: number): number
		return #(harness.Fake.Mailboxes[keyOf(harness, userId)] or {})
	end

	local function owns(harness, userId: number, perk: string): boolean
		local profile = harness.Fake.Persisted[keyOf(harness, userId)]
		local reserved = (profile and profile._Scribe) or {}
		return type(reserved.Perks) == "table" and reserved.Perks[perk] == true
	end

	--- THE ONE SEAM. PromptGift reaches its yield through
	--- `ctx.Persistence.AwaitSave(entry, 10)`, indexed off the ctx table at call
	--- time, so wrapping the field puts a spec exactly where the coroutine yield is:
	--- after the intent has been written, before the rollback can run.
	---
	--- One-shot so the replacement writer cannot recursively re-enter the seam.
	local function onceInsideTheSaveYield(harness, hook: (real: () -> boolean) -> boolean)
		local persistence = harness.Ctx.Persistence
		local real = persistence.AwaitSave
		local armed = true
		persistence.AwaitSave = function(entry, timeout)
			if not armed then
				return real(entry, timeout)
			end
			armed = false
			return hook(function()
				return real(entry, timeout)
			end)
		end
		return function()
			persistence.AwaitSave = real
		end
	end

	--------------------------------------------------------------------------------
	-- 1. ROLLBACK PATH ONE: the durable-intent save did not confirm.
	--    src/Server/Monetization.luau:2565
	--------------------------------------------------------------------------------

	it(
		"GUARD (was a DEFECT; flipped when D1's GiftId guard landed): a failed intent save leaves the NEXT gift's intent alone",
		function()
			-- A legacy writer replaces the slot while the intent save is unconfirmed.
			-- Rollback must preserve that replacement's identity and delivery.
			withClock(T0, function(advance)
				local harness = makeHarness()
				local buyer, entry = harness.Join(BUYER)

				-- A legacy writer will replace this prompt's intent during its save.

				local giftC
				local restore = onceInsideTheSaveYield(harness, function(real)
					-- Replace the slot during the first prompt's save.
					advance(PROMPT_WINDOW + 80)
					entry.Tree.Reserved.PendingGifts[tostring(PRODUCT_ID)].Set({
						RecipientId = SECOND,
						GiftId = "legacy-replacement",
						Ts = Clock.Now(),
						Product = "GiftVIP",
					})
					giftC = tostring(slot(entry).GiftId)
					-- ...and only now does B's save come back, unconfirmed. Driven through
					-- the real save path so the `false` is the production one.
					harness.Fake.FailSaves = true
					local answer = real()
					harness.Fake.FailSaves = false
					return answer
				end)
				local promptB, reasonB = harness.Data.PromptGift(buyer, "GiftVIP", SECOND + 1)
				restore()

				-- The replacement survives and remains deliverable.
				local afterRollback = slotState(entry, giftC)
				local decision = harness.Data.HandleReceipt(receipt("D1-path1"))
				harness.Data.Flush(buyer)
				task.wait()

				expect(
					("promptB=%s reason=%s slot=%s d=%s buyerVIP=%s rcpQueued=%d"):format(
						tostring(promptB),
						tostring(reasonB),
						afterRollback,
						if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(owns(harness, BUYER, "VIP")),
						mailbox(harness, SECOND)
					)
				).to.equal(
					"promptB=false reason=could not record gift intent; try again later "
						.. "slot=to=90303 isExpected=true d=GRANTED buyerVIP=false rcpQueued=1"
				)

				harness.Cleanup()
			end)
		end
	)

	it(
		"GUARD (was a DEFECT; flipped when D1's GiftId guard landed): nothing is deleted, so no line has to name it",
		function()
			-- The half that decides whether an operator could ever reconcile this. BEFORE
			-- THE GUARD this pinned "slot=empty anyLineNamesTheLostRecipient=false": the
			-- only line the failing call emitted was GIFT_INTENT_WRITE_FAIL, naming the
			-- gift that FAILED and not the unrelated gift it had just deleted.
			--
			-- PINNED NOW: the slot still holds C, and still nothing names C -- because
			-- there is nothing to name. That is what stops the fix being "log it and
			-- carry on": a rollback that deleted C and warned about it would fail the
			-- slot half of every block in this file, and would flip this half to true.
			--
			-- THE SCAN IS SCOPED TO THIS BLOCK. Log's ring is process-wide and survives
			-- harness.Cleanup, so an unscoped scan reads the blocks above it too -- and
			-- the now-guarded block 1 leaves a GIFT_RECEIPT_GRANTED naming exactly this
			-- recipient in the ring, which is what made an unscoped `named` true for a
			-- reason that has nothing to do with a deletion. Entries are compared by
			-- table identity: one present before the interleave can only fall OUT of the
			-- newest-200 window, never into it, so "not in `seen`" is exactly "emitted
			-- here".
			withClock(T0, function(advance)
				local harness = makeHarness()
				local buyer, entry = harness.Join(BUYER)

				-- A legacy writer will replace this prompt's intent during its save.

				local seen = {}
				for _, line in Scribe.GetRecentLogs({ Limit = 200 }) do
					seen[line] = true
				end

				local giftC
				local restore = onceInsideTheSaveYield(harness, function(real)
					advance(PROMPT_WINDOW + 80)
					entry.Tree.Reserved.PendingGifts[tostring(PRODUCT_ID)].Set({
						RecipientId = SECOND,
						GiftId = "legacy-replacement",
						Ts = Clock.Now(),
						Product = "GiftVIP",
					})
					giftC = tostring(slot(entry).GiftId)
					harness.Fake.FailSaves = true
					local answer = real()
					harness.Fake.FailSaves = false
					return answer
				end)
				harness.Data.PromptGift(buyer, "GiftVIP", SECOND + 1)
				restore()
				task.wait()

				local named = false
				for _, line in Scribe.GetRecentLogs({ Limit = 200 }) do
					if seen[line] then
						continue
					end
					local context = line.Context or {}
					if tonumber(context.RecipientId) == SECOND then
						named = true
					end
				end
				expect(("slot=%s anyLineNamesTheLostRecipient=%s"):format(slotState(entry, giftC), tostring(named))).to.equal(
					"slot=to=90303 isExpected=true anyLineNamesTheLostRecipient=false"
				)

				harness.Cleanup()
			end)
		end
	)

	--------------------------------------------------------------------------------
	-- 2. ROLLBACK PATH TWO: the purchase prompt itself threw.
	--    src/Server/Monetization.luau:2575
	--------------------------------------------------------------------------------

	it(
		"GUARD (was a DEFECT; flipped when D1's GiftId guard landed): a throwing purchase prompt leaves the NEXT gift's intent alone",
		function()
			-- The marketplace call replaces the slot before raising.
			-- Prompt-failure cleanup must preserve the replacement too.
			withClock(T0, function()
				local entry, giftC
				local harness = makeHarness({
					PromptProductPurchase = function()
						entry.Tree.Reserved.PendingGifts[tostring(PRODUCT_ID)].Set({
							RecipientId = SECOND,
							GiftId = "legacy-replacement",
							Ts = Clock.Now(),
							Product = "GiftVIP",
						})
						giftC = tostring(slot(entry).GiftId)
						error("MarketplaceService is down", 0)
					end,
				})
				local buyer
				buyer, entry = harness.Join(BUYER)
				local promptB, reasonB = harness.Data.PromptGift(buyer, "GiftVIP", SECOND + 1)

				local afterRollback = slotState(entry, giftC)
				local decision = harness.Data.HandleReceipt(receipt("D1-path2"))
				harness.Data.Flush(buyer)
				task.wait()

				expect(
					("promptB=%s reasonPrefix=%s slot=%s d=%s buyerVIP=%s rcpQueued=%d"):format(
						tostring(promptB),
						tostring(reasonB):sub(1, 22),
						afterRollback,
						if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(owns(harness, BUYER, "VIP")),
						mailbox(harness, SECOND)
					)
				).to.equal(
					"promptB=false reasonPrefix=purchase prompt failed slot=to=90303 isExpected=true "
						.. "d=GRANTED buyerVIP=false rcpQueued=1"
				)

				harness.Cleanup()
			end)
		end
	)

	--------------------------------------------------------------------------------
	-- 3. THE CONTROLS. Everything the guard must leave exactly as it is.
	--------------------------------------------------------------------------------

	it("CONTROL: an UNCONTESTED failed intent save still clears its own intent, and still refuses", function()
		-- The guard is a GiftId comparison, not an existence test, and the cheap wrong
		-- fix is to make the rollback conditional on something that also skips this
		-- case. A prompt that fails and leaves its own intent standing is a slot the
		-- buyer cannot re-use for giftPromptWindow, and a record a later receipt could
		-- settle against for a purchase that was never prompted.
		withClock(T0, function()
			local harness = makeHarness()
			local buyer, entry = harness.Join(BUYER)

			harness.Fake.FailSaves = true
			local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", FIRST)
			harness.Fake.FailSaves = false

			expect(("ok=%s reason=%s slot=%s"):format(tostring(ok), tostring(reason), slotState(entry))).to.equal(
				"ok=false reason=could not record gift intent; try again later slot=empty"
			)

			harness.Cleanup()
		end)
	end)

	it("CONTROL: an UNCONTESTED throwing purchase prompt still clears its own intent, and still refuses", function()
		withClock(T0, function()
			local harness = makeHarness({
				PromptProductPurchase = function()
					error("MarketplaceService is down", 0)
				end,
			})
			local buyer, entry = harness.Join(BUYER)

			local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", FIRST)

			expect(
				("ok=%s reasonPrefix=%s slot=%s"):format(tostring(ok), tostring(reason):sub(1, 22), slotState(entry))
			).to.equal("ok=false reasonPrefix=purchase prompt failed slot=empty")

			harness.Cleanup()
		end)
	end)

	it("CONTROL: the happy path leaves exactly ONE intent, holding the gift it just armed", function()
		-- The other cheap wrong fix: a guard that reads the slot wrongly and clears
		-- nothing, or clears on the success path too.
		withClock(T0, function()
			local harness = makeHarness()
			local buyer, entry = harness.Join(BUYER)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", FIRST)).to.equal(true)
			local armed = tostring(slot(entry).GiftId)
			local count = 0
			for _ in entry.LiveData._Scribe.PendingGifts do
				count += 1
			end

			expect(("count=%d slot=%s"):format(count, slotState(entry, armed))).to.equal(
				"count=1 slot=to=90302 isExpected=true"
			)

			harness.Cleanup()
		end)
	end)

	it("refuses a replaced intent before opening a dialog and preserves its new owner", function()
		withClock(T0, function(advance)
			local harness = makeHarness()
			local buyer, entry = harness.Join(BUYER)

			-- A legacy writer replaces the slot while the first intent save yields.

			local giftC
			local restore = onceInsideTheSaveYield(harness, function(real)
				advance(PROMPT_WINDOW + 80)
				entry.Tree.Reserved.PendingGifts[tostring(PRODUCT_ID)].Set({
					RecipientId = SECOND,
					GiftId = "legacy-replacement",
					Ts = Clock.Now(),
					Product = "GiftVIP",
				})
				giftC = tostring(slot(entry).GiftId)
				return real()
			end)
			local promptB = harness.Data.PromptGift(buyer, "GiftVIP", SECOND + 1)
			restore()

			local afterPrompt = slotState(entry, giftC)
			local decision = harness.Data.HandleReceipt(receipt("D1-control"))
			harness.Data.Flush(buyer)
			task.wait()

			-- C wrote its record AFTER B did (B's write is pre-yield), so the slot holds
			-- C and C's receipt is C's. Nothing was deleted, and the money routed to a
			-- recipient rather than back to the buyer. That is the destination state
			-- both defect blocks above must reach once the rollbacks are guarded.
			expect(
				("promptB=%s slotIsC=%s d=%s buyerVIP=%s queued=%d"):format(
					tostring(promptB),
					afterPrompt,
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(harness, BUYER, "VIP")),
					mailbox(harness, SECOND)
				)
			).to.equal("promptB=false slotIsC=to=90303 isExpected=true d=GRANTED buyerVIP=false queued=1")

			harness.Cleanup()
		end)
	end)
end
