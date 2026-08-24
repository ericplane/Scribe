--!nonstrict
-- THE GIFT-INTENT SAFETY NET.
--
-- Characterisation specs for the invariants the gift-escrow path already holds,
-- written BEFORE any fix touches it and green on the unmodified tree. Their job
-- is not to describe a defect; it is to make a fix that breaks something eight
-- lines away fail loudly instead of silently.
--
-- The identity rule every block below rests on: a PendingGifts slot is keyed by
-- `tostring(product.Id)`, which is an ADDRESS, not an identity. `Ts` is mutable
-- (the failure arm rewrites it), `RecipientId` is not unique, and the slot can be
-- overwritten by a later PromptGift. The only stable identity of an intent is its
-- `GiftId`, minted fresh per prompt. So every read-modify-write of a slot that
-- spans a yield has to compare GiftId -- never test existence, never compare Ts.
--
-- Blocks explicitly labelled DEFECT CHARACTERISATION record behaviour that is
-- WRONG today and is expected to change. Everything else must stay green.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)

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

	local function pending(entry): { [string]: any }
		return entry.LiveData._Scribe.PendingGifts
	end

	local function slot(entry, productId: number): any
		return pending(entry)[tostring(productId)]
	end

	--- Every slot that exists must carry BOTH halves of an intent's identity. A
	--- slot missing either is a phantom: `tonumber(intent.RecipientId) or 0`
	--- resolves it to userId 0 and deliverGift MessageAsyncs a paid gift to the
	--- DataStore key for user 0, which answers true.
	local function describePending(entry): string
		local keys = {}
		for productIdStr, intent in pending(entry) do
			if type(intent) ~= "table" then
				table.insert(keys, productIdStr .. "=NOT_A_TABLE")
			else
				local missing = {}
				if intent.RecipientId == nil then
					table.insert(missing, "RecipientId")
				end
				if intent.GiftId == nil then
					table.insert(missing, "GiftId")
				end
				if #missing > 0 then
					table.insert(keys, productIdStr .. "=MISSING:" .. table.concat(missing, "+"))
				else
					table.insert(keys, productIdStr)
				end
			end
		end
		table.sort(keys)
		return table.concat(keys, ",")
	end

	--- Run `body` with wall time and the monotonic timer both frozen at a value the
	--- body advances by hand. Restores the real clock even when the body throws --
	--- a leaked virtual clock silently reshapes every spec that runs after it.
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

	--- Replace the store's MessageAsync so a spec can act DURING the window
	--- deliverGift is yielding in. The production call is
	--- `ctx.Persistence.Store:MessageAsync(...)`, indexed at call time, so this is
	--- the one seam that reaches the middle of a cross-server delivery.
	--- `hook` returns true to let the real send through, false to fail it.
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

	local function codeCounter(wanted: string)
		local n = 0
		local unsubscribe = Scribe.AddLogSink(function(entry)
			if entry.Code == wanted then
				n += 1
			end
		end)
		return function(): number
			return n
		end, unsubscribe
	end

	--------------------------------------------------------------------------------
	-- INVARIANT 1 / 8: the failure arm's guarded Ts refresh
	--------------------------------------------------------------------------------

	describe("the failure arm's guarded Ts refresh", function()
		it("refreshes the intent when the slot is still the SAME gift", function()
			-- The refresh is what keeps PromptGift's short overwrite window refusing a
			-- second same-product gift while THIS paid purchase is still retrying.
			-- Without it a long retry drifts past giftPromptWindow, a second prompt
			-- overwrites the slot, and the first purchase's value is routed to the
			-- second recipient.
			withClock(1700000000, function(advance)
				local harness = makeHarness()
				local buyer, entry = harness.Join(80101)

				expect(harness.Data.PromptGift(buyer, "GiftVIP", 80102)).to.equal(true)
				local giftId = slot(entry, 222).GiftId
				expect(slot(entry, 222).Ts).to.equal(1700000000)

				advance(50)
				harness.Fake.FailMessages = true
				expect(harness.Data.HandleReceipt(receipt(80101, 222, "refresh-1"))).to.equal(NOT_PROCESSED)
				harness.Fake.FailMessages = false

				expect(
					("gift=%s ts=%s"):format(tostring(slot(entry, 222).GiftId == giftId), tostring(slot(entry, 222).Ts))
				).to.equal("gift=true ts=1700000050")
				harness.Cleanup()
			end)
		end)

		it("leaves the slot alone when a SECOND gift took it over during the delivery yield", function()
			-- deliverGift yields. If the buyer prompted a second gift of the same
			-- product on another thread while this receipt was in flight, the slot no
			-- longer belongs to this purchase, and stamping Ts onto it would extend a
			-- stranger's intent -- and, worse, teach the next reader that the second
			-- gift is newer than it is.
			withClock(1700000000, function(advance)
				local harness = makeHarness()
				local buyer, entry = harness.Join(80111)

				expect(harness.Data.PromptGift(buyer, "GiftVIP", 80112)).to.equal(true)

				local restore = interceptDelivery(harness, function()
					-- The second gift lands mid-flight, with an OLDER stamp than "now"
					-- so a blind refresh would be visible.
					entry.Tree.Reserved.PendingGifts["222"].Set({
						RecipientId = 80113,
						GiftId = "gift-B",
						Ts = 1700000010,
						Product = "GiftVIP",
					})
					return false -- ...and this purchase's delivery fails
				end)
				advance(90)
				expect(harness.Data.HandleReceipt(receipt(80111, 222, "reassigned-1"))).to.equal(NOT_PROCESSED)
				restore()

				local live = slot(entry, 222)
				expect(
					("gift=%s to=%s ts=%s"):format(tostring(live.GiftId), tostring(live.RecipientId), tostring(live.Ts))
				).to.equal("gift=gift-B to=80113 ts=1700000010")
				harness.Cleanup()
			end)
		end)

		it("cannot materialise a phantom {Ts} intent when the slot was cleared mid-flight", function()
			-- The trap a one-line "just refresh the timestamp" fix falls into.
			-- PendingGifts is a free-form dynamic node, so `PendingGifts[id].Ts.Set(x)`
			-- on an ABSENT slot creates `{Ts = n}` -- no RecipientId, no GiftId. A later
			-- retry reads `tonumber(intent.RecipientId) or 0` and MessageAsyncs a paid
			-- gift to the DataStore key for userId 0, which answers true.
			withClock(1700000000, function(advance)
				local harness = makeHarness()
				local buyer, entry = harness.Join(80121)

				expect(harness.Data.PromptGift(buyer, "GiftVIP", 80122)).to.equal(true)

				local restore = interceptDelivery(harness, function()
					entry.Tree.Reserved.PendingGifts["222"].Set(nil)
					return false
				end)
				advance(30)
				expect(harness.Data.HandleReceipt(receipt(80121, 222, "phantom-1"))).to.equal(NOT_PROCESSED)
				restore()

				expect(describePending(entry)).to.equal("")
				harness.Cleanup()
			end)
		end)
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 2: the only creator of a slot is PromptGift
	--------------------------------------------------------------------------------

	it("leaves no half-built intent behind on ANY receipt arm", function()
		-- One sweep across every arm a receipt can take, asserting the same thing
		-- after each: whatever occupies PendingGifts is either absent or complete.
		-- A `{Ts = n}` phantom is invisible at creation and only surfaces later as a
		-- paid gift delivered to userId 0.
		withClock(1700000000, function(advance)
			local harness = makeHarness({ GiftIntentTTL = 300 })
			local buyer, entry = harness.Join(80201)
			local recipient = harness.Join(80202)

			-- Arm 1: successful same-server delivery.
			expect(harness.Data.PromptGift(buyer, "GiftVIP", 80202)).to.equal(true)
			expect(harness.Data.HandleReceipt(receipt(80201, 222, "arm-success"))).to.equal(GRANTED)
			expect(describePending(entry)).to.equal("")

			-- Arm 2: failed delivery (intent must SURVIVE, and survive complete).
			local other = harness.Join(80203)
			harness.Leave(other)
			expect(harness.Data.PromptGift(buyer, "GiftVIP", 80203)).to.equal(true)
			harness.Fake.FailMessages = true
			expect(harness.Data.HandleReceipt(receipt(80201, 222, "arm-fail"))).to.equal(NOT_PROCESSED)
			harness.Fake.FailMessages = false
			expect(describePending(entry)).to.equal("222")

			-- Arm 3: the credit conversion (recipient already owns it).
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)
			entry.Tree.Reserved.PendingGifts["222"].Set({
				RecipientId = 80202,
				GiftId = "gift-owned",
				Ts = Clock.Now(),
				Product = "GiftVIP",
			})
			expect(harness.Data.HandleReceipt(receipt(80201, 222, "arm-credit"))).to.equal(GRANTED)
			expect(describePending(entry)).to.equal("")

			-- Arm 4: no intent at all (the buyer bought it for themselves).
			expect(harness.Data.HandleReceipt(receipt(80201, 222, "arm-nointent"))).to.equal(GRANTED)
			expect(describePending(entry)).to.equal("")

			-- Arm 5: a TTL-expired intent.
			entry.Tree.Reserved.PendingGifts["222"].Set({
				RecipientId = 80203,
				GiftId = "gift-stale",
				Ts = Clock.Now(),
				Product = "GiftVIP",
			})
			advance(301)
			-- NotProcessedYet here is correct and deliberate, not a failure of this
			-- arm: intentFor expires the intent and the receipt falls to the no-intent
			-- policy, where the buyer now owns the perk AND holds the unused credit
			-- arm 3 minted -- so the purchase could only stack a second credit and is
			-- declined (RECEIPT_DECLINED_PENDING_CREDIT). What this arm pins is the
			-- census: the expiry cleared the slot and left nothing half-built.
			expect(harness.Data.HandleReceipt(receipt(80201, 222, "arm-stale"))).to.equal(NOT_PROCESSED)
			expect(describePending(entry)).to.equal("")

			harness.Cleanup()
		end)
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 4: intentFor's rejections
	--------------------------------------------------------------------------------

	describe("intentFor rejects before anything is delivered", function()
		it("expires an intent left by a RETIRED product that reused this Id", function()
			withClock(1700000000, function()
				local expired, unsubscribe = codeCounter("GIFT_INTENT_EXPIRED")
				local harness = makeHarness()
				local buyer, entry = harness.Join(80301)
				local recipient = harness.Join(80302)

				entry.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = 80302,
					GiftId = "gift-retired",
					Ts = Clock.Now(),
					Product = "RetiredCoinPack", -- a DIFFERENT product once owned Id 222
				})

				local decision = harness.Data.HandleReceipt(receipt(80301, 222, "retired-1"))
				task.wait()
				unsubscribe()

				-- No gift: the recipient gets nothing, the slot is cleared, and the
				-- receipt falls through to the no-intent policy (grant to the buyer).
				expect(
					("d=%s recipient=%s buyer=%s pending=[%s] logs=%d"):format(
						tostring(decision == GRANTED),
						tostring(harness.Data.Owns(recipient, "VIP")),
						tostring(harness.Data.Owns(buyer, "VIP")),
						describePending(entry),
						expired()
					)
				).to.equal("d=true recipient=false buyer=true pending=[] logs=1")

				harness.Cleanup()
			end)
		end)

		it("expires an intent older than GiftIntentTTL", function()
			withClock(1700000000, function(advance)
				local expired, unsubscribe = codeCounter("GIFT_INTENT_EXPIRED")
				local harness = makeHarness({ GiftIntentTTL = 300 })
				local buyer, entry = harness.Join(80311)
				local recipient = harness.Join(80312)

				expect(harness.Data.PromptGift(buyer, "GiftVIP", 80312)).to.equal(true)
				advance(301)

				local decision = harness.Data.HandleReceipt(receipt(80311, 222, "stale-1"))
				task.wait()
				unsubscribe()

				expect(
					("d=%s recipient=%s buyer=%s pending=[%s] logs=%d"):format(
						tostring(decision == GRANTED),
						tostring(harness.Data.Owns(recipient, "VIP")),
						tostring(harness.Data.Owns(buyer, "VIP")),
						describePending(entry),
						expired()
					)
				).to.equal("d=true recipient=false buyer=true pending=[] logs=1")

				harness.Cleanup()
			end)
		end)
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 5: an uncleared slot costs the buyer permanent gift capacity
	--------------------------------------------------------------------------------

	it("reclaims a stranded intent on the next load, so capacity is never lost for good", function()
		-- PromptGift refuses at GiftMaxPending. The only reclaim paths are intentFor's
		-- TTL branch, the OnLoad sweep, and the explicit clears. A fix that leaves an
		-- intent no path can clear converts a transient failure into a permanent
		-- capacity loss with no diagnostic at all.
		withClock(1700000000, function(advance)
			local harness = makeHarness({ GiftMaxPending = 1, GiftIntentTTL = 300 })
			local buyer, entry = harness.Join(80401)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", 80402)).to.equal(true)

			-- The one slot is spent: a second prompt of anything is refused.
			local ok, reason = harness.Data.PromptGift(buyer, "Coins1000", 80403)
			expect(("%s/%s"):format(tostring(ok), tostring(reason))).to.equal("false/too many pending gifts")

			-- Three receipt attempts with delivery permanently down. Each refreshes
			-- the intent's Ts, so the intent is deliberately kept alive.
			harness.Fake.FailMessages = true
			for _ = 1, 3 do
				advance(60)
				expect(harness.Data.HandleReceipt(receipt(80401, 222, "stranded-1"))).to.equal(NOT_PROCESSED)
			end
			harness.Fake.FailMessages = false
			expect(describePending(entry)).to.equal("222")

			-- Roblox gives up. The intent is now stranded -- and the next load sweeps it.
			harness.Data.Flush(buyer)
			harness.Leave(buyer)
			advance(301)
			local buyer2, entry2 = harness.Join(80401)

			local ok2 = harness.Data.PromptGift(buyer2, "GiftVIP", 80404)
			expect(("pending=[%s] regift=%s"):format(describePending(entry2), tostring(ok2))).to.equal(
				"pending=[222] regift=true"
			)
			-- ...and the slot it now holds is the NEW gift, not the swept one.
			expect(slot(entry2, 222).RecipientId).to.equal(80404)

			harness.Cleanup()
		end)
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 7: recipientId / giftId are read once, before the first yield
	--------------------------------------------------------------------------------

	it("delivers to the recipient the purchase was made for, even if the slot changes mid-flight", function()
		-- The receipt reads RecipientId and GiftId once, before deliverGift yields.
		-- Re-deriving either from the live slot afterwards routes a PAID purchase to
		-- whoever happens to occupy the slot by then.
		withClock(1700000000, function()
			local harness = makeHarness()
			local buyer, entry = harness.Join(80501)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", 80502)).to.equal(true)
			local originalGiftId = slot(entry, 222).GiftId

			local restore = interceptDelivery(harness, function()
				-- A second prompt takes the slot over while this delivery is in flight.
				entry.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = 80503,
					GiftId = "gift-B",
					Ts = Clock.Now(),
					Product = "GiftVIP",
				})
				return true -- ...and this delivery still succeeds
			end)
			expect(harness.Data.HandleReceipt(receipt(80501, 222, "readonce-1"))).to.equal(GRANTED)
			restore()

			local originalKey = "Default/" .. harness.Ctx.Persistence.KeyFor(80502)
			local usurperKey = "Default/" .. harness.Ctx.Persistence.KeyFor(80503)
			local mailbox = harness.Fake.Mailboxes[originalKey] or {}
			local sent = harness.Data.GetPurchases(buyer, { Kind = "Robux" })
			local line = sent[#sent]

			expect(
				("orig=%d usurper=%d to=%s gift=%s msgTo=%s"):format(
					#mailbox,
					#(harness.Fake.Mailboxes[usurperKey] or {}),
					tostring(line.From.ToUserId),
					tostring(line.From.GiftId == originalGiftId),
					tostring(mailbox[1] ~= nil and mailbox[1].GiftId == originalGiftId)
				)
			).to.equal("orig=1 usurper=0 to=80502 gift=true msgTo=true")

			harness.Cleanup()
		end)
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 19: the cooldown stamp is written before the first yield
	--------------------------------------------------------------------------------

	it("charges the gift cooldown before PromptGift's first yield, so two cannot be in flight", function()
		-- This is what bounds how fast one buyer can overwrite their own slot, and it
		-- is why a GiftId re-check is enough where otherwise a lock would be needed.
		-- Every check above the stamp is local; the first yield is recipientAlreadyOwns.
		-- Move the stamp below that yield and nothing in the suite noticed -- until now.
		withClock(1700000000, function()
			local harness = makeHarness({ GiftCooldown = 60 })
			local buyer = harness.Join(80601)

			-- Make recipientAlreadyOwns actually yield, the way it does in production
			-- for an offline recipient (a full-profile GetAsync round trip).
			local persistence = harness.Ctx.Persistence
			local realGetOffline = persistence.GetOffline
			local parked = false
			persistence.GetOffline = function(userId)
				if userId == 80602 then
					parked = true
					task.wait()
				end
				return realGetOffline(userId)
			end

			local first: any = nil
			task.spawn(function()
				first = { harness.Data.PromptGift(buyer, "GiftVIP", 80602) }
			end)
			-- The first call is now parked INSIDE recipientAlreadyOwns.
			expect(("parked=%s finished=%s"):format(tostring(parked), tostring(first ~= nil))).to.equal(
				"parked=true finished=false"
			)

			local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 80603)
			expect(("%s/%s"):format(tostring(ok), tostring(reason))).to.equal("false/gift cooldown")

			for _ = 1, 20 do
				if first ~= nil then
					break
				end
				task.wait()
			end
			persistence.GetOffline = realGetOffline
			expect(first[1]).to.equal(true) -- the parked call still completes normally

			harness.Cleanup()
		end)
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 21: the in-flight key is released before the re-raise
	--------------------------------------------------------------------------------

	it("releases the receipt's in-flight key when the entry tears down mid-delivery", function()
		-- entry.Tree dies with the session and every reservedAcc write raises on it,
		-- so a receipt that overlaps a departure throws out of the gift path. The
		-- release sits on the line ABOVE the re-raise for exactly this reason: move it
		-- below and this receipt is refused with RECEIPT_IN_FLIGHT for the rest of the
		-- server's life, and the buyer's paid gift never lands.
		local harness = makeHarness()
		local buyer = harness.Join(80701)

		expect(harness.Data.PromptGift(buyer, "GiftVIP", 80702)).to.equal(true)
		harness.Data.Flush(buyer)

		local restore = interceptDelivery(harness, function()
			harness.Leave(buyer) -- the buyer walks out mid-delivery
			return true
		end)
		local threw = not pcall(function()
			harness.Data.HandleReceipt(receipt(80701, 222, "teardown-1"))
		end)
		restore()

		-- Same userId, same PurchaseId -> the same flight key. If it leaked, this is
		-- NotProcessedYet forever.
		local buyer2 = harness.Join(80701)
		local retry = harness.Data.HandleReceipt(receipt(80701, 222, "teardown-1"))
		expect(("threw=%s retry=%s"):format(tostring(threw), tostring(retry == GRANTED))).to.equal(
			"threw=true retry=true"
		)
		expect(buyer2).to.be.ok()

		harness.Cleanup()
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 18: a refused PromptGift moves nothing
	--------------------------------------------------------------------------------

	it("leaves PendingGifts untouched on every refusal arm of PromptGift", function()
		-- `false, reason` means no money moved and no intent survives. A pre-existing
		-- intent for a DIFFERENT product sits in the slot throughout, so an arm that
		-- writes or clears anything shows up as a changed census.
		withClock(1700000000, function()
			local harness = makeHarness({ GiftCooldown = 0 })
			local buyer, entry = harness.Join(80801)
			local recipient = harness.Join(80802)

			-- A live, unrelated intent that no refusal is allowed to disturb.
			entry.Tree.Reserved.PendingGifts["111"].Set({
				RecipientId = 80809,
				GiftId = "bystander",
				Ts = 1700000000,
				Product = "Coins1000",
			})
			local function census(): string
				local live = slot(entry, 111)
				return ("%s|%s|%s|%s"):format(
					describePending(entry),
					tostring(live.GiftId),
					tostring(live.RecipientId),
					tostring(live.Ts)
				)
			end
			local before = census()
			expect(before).to.equal("111|bystander|80809|1700000000")

			local refusals = {}
			local function refuse(label: string, ...)
				local ok, reason = harness.Data.PromptGift(...)
				table.insert(
					refusals,
					("%s=%s:%s:%s"):format(label, tostring(ok), tostring(reason), tostring(census() == before))
				)
			end

			refuse("unknown", buyer, "NoSuchProduct", 80803)
			refuse("invalid", buyer, "GiftVIP", -1)
			refuse("self", buyer, "GiftVIP", 80801)

			-- The recipient acquires the perk, so the duplicate guard refuses.
			expect(harness.Data.HandleReceipt(receipt(80802, 222, "seed-owned"))).to.equal(GRANTED)
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)
			refuse("owned", buyer, "GiftVIP", 80802)

			harness.Fake.FailSaves = true
			refuse("nosave", buyer, "GiftVIP", 80804)
			harness.Fake.FailSaves = false

			expect(table.concat(refusals, " ")).to.equal(
				'unknown=false:unknown product "NoSuchProduct":true '
					.. "invalid=false:invalid recipient:true "
					.. "self=false:cannot gift yourself:true "
					.. "owned=false:recipient already owns this:true "
					.. "nosave=false:could not record gift intent; try again later:true"
			)

			harness.Cleanup()
		end)
	end)

	--------------------------------------------------------------------------------
	-- DEFECT CHARACTERISATION -- these blocks record behaviour that is WRONG.
	--------------------------------------------------------------------------------

	describe("DEFECT CHARACTERISATION: the same-product overwrite", function()
		it("routes the FIRST purchase to the SECOND recipient once the prompt window lapses", function()
			-- PromptGift silently overwrites a live intent as soon as it is older than
			-- giftPromptWindow (120s), with no read-back and no log. Gift A's receipt --
			-- still legitimately retrying, or simply slow -- then reads B's RecipientId
			-- and delivers A's paid product to B's recipient.
			--
			-- THIS IS NOT WHAT THE F2 FIX ADDRESSES. F2 stops A's SUCCESS arm from
			-- DELETING B's intent; the misrouting below is untouched by it. This spec
			-- must therefore pass IDENTICALLY before and after F2. If it starts failing,
			-- the fix did more than it was scoped to and that is the finding, not a
			-- reason to edit this block.
			withClock(1700000000, function(advance)
				local harness = makeHarness()
				local buyer, entry = harness.Join(80901)
				local r1 = harness.Join(80902)
				local r2 = harness.Join(80903)

				expect(harness.Data.PromptGift(buyer, "GiftVIP", 80902)).to.equal(true)
				local giftA = slot(entry, 222).GiftId

				-- Past giftPromptWindow (120s), under GiftIntentTTL (3600s).
				advance(121)
				expect(harness.Data.PromptGift(buyer, "GiftVIP", 80903)).to.equal(true)
				local giftB = slot(entry, 222).GiftId
				expect(giftA ~= giftB).to.equal(true)

				-- A's receipt finally arrives.
				expect(harness.Data.HandleReceipt(receipt(80901, 222, "overwrite-A"))).to.equal(GRANTED)

				local sent = harness.Data.GetPurchases(buyer, { Kind = "Robux" })
				local line = sent[#sent]
				expect(
					("r1=%s r2=%s to=%s gift=%s"):format(
						tostring(harness.Data.Owns(r1, "VIP")),
						tostring(harness.Data.Owns(r2, "VIP")),
						tostring(line.From.ToUserId),
						tostring(line.From.GiftId == giftB)
					)
				).to.equal("r1=false r2=true to=80903 gift=true")

				harness.Cleanup()
			end)
		end)
	end)

	describe("DEFECT CHARACTERISATION: nothing re-validates the recipient on the receipt path", function()
		it("MessageAsyncs a paid gift to the DataStore key for userId 0", function()
			-- The consequence of a phantom, and the reason the guarded-refresh specs
			-- above matter. PromptGift validates the recipient at its own entry
			-- (`recipientUserId <= 0` is refused); NOTHING re-validates it afterwards.
			-- handleGiftReceipt reads `tonumber(intent.RecipientId) or 0` and hands the
			-- result straight to deliverGift, which MessageAsyncs to the recipient's
			-- key. There is no live entry for user 0, so the send goes to the mailbox
			-- for PLAYER_0 -- and MessageAsync answers true, which is a durable
			-- delivery as far as every layer above it is concerned. The receipt then
			-- answers PurchaseGranted and Roblox consumes the Robux.
			--
			-- The intent below is planted directly rather than produced by a bug,
			-- because it has to be: with the guard at the failure arm intact there is
			-- no reachable way to MAKE a phantom today. That is exactly what the
			-- phantom specs above protect, and this block records what it costs if one
			-- ever gets through.
			--
			-- THIS BLOCK MUST FLIP IF A `recipientUserId > 0` GUARD IS ADDED to the
			-- receipt path. That guard is a scope call, not part of F2 or F3 -- flag
			-- it, do not smuggle it in.
			withClock(1700000000, function()
				local harness = makeHarness()
				local buyer, entry = harness.Join(81101)

				-- A phantom: the shape a blind `PendingGifts[id].Ts.Set(x)` produces.
				entry.Tree.Reserved.PendingGifts["222"].Set({ Ts = Clock.Now() })

				local decision = harness.Data.HandleReceipt(receipt(81101, 222, "phantom-delivery"))
				local zeroKey = "Default/" .. harness.Ctx.Persistence.KeyFor(0)
				local zeroBox = harness.Fake.Mailboxes[zeroKey] or {}
				local sent = harness.Data.GetPurchases(buyer, { Kind = "Robux" })
				local line = sent[#sent]

				expect(
					("d=%s toUserZero=%d loggedTo=%s type=%s"):format(
						tostring(decision == GRANTED),
						#zeroBox,
						tostring(line.From.ToUserId),
						tostring(line.From.Type)
					)
				).to.equal("d=true toUserZero=1 loggedTo=0 type=GiftSent")

				harness.Cleanup()
			end)
		end)
	end)

	describe("DEFECT CHARACTERISATION: the blind clear on the success arm (F2)", function()
		it("deletes a SECOND gift's live intent when the first gift's receipt settles", function()
			-- THE F2 DEFECT, measured. Two prompts of the same product to two different
			-- recipients, separated by more than giftPromptWindow. Gift A's receipt
			-- settles and the success arm clears PendingGifts[productId] BLIND -- so it
			-- deletes gift B's intent, which it does not own.
			--
			-- No log, no metric, no error, no failed save. B's own receipt then finds no
			-- intent and falls into the no-intent policy, granting the perk to the BUYER.
			--
			-- THIS BLOCK MUST FLIP WHEN F2 LANDS. When it does, replace the expectation
			-- with the fixed one (B's intent survives, B's receipt reaches B's recipient)
			-- rather than deleting the block.
			withClock(1700000000, function(advance)
				local harness = makeHarness()
				local buyer, entry = harness.Join(81001)
				local r1 = harness.Join(81002)
				local r2 = harness.Join(81003)

				expect(harness.Data.PromptGift(buyer, "GiftVIP", 81002)).to.equal(true)
				advance(121)
				expect(harness.Data.PromptGift(buyer, "GiftVIP", 81003)).to.equal(true)
				local giftB = slot(entry, 222).GiftId

				-- A's receipt settles. It delivers to whoever holds the slot (see the
				-- overwrite block above) and then clears the slot outright.
				expect(harness.Data.HandleReceipt(receipt(81001, 222, "blind-A"))).to.equal(GRANTED)
				local survived = slot(entry, 222) ~= nil

				-- B's receipt arrives to find nothing.
				expect(harness.Data.HandleReceipt(receipt(81001, 222, "blind-B"))).to.equal(GRANTED)

				expect(
					("survived=%s giftB=%s r1=%s r2=%s buyer=%s"):format(
						tostring(survived),
						tostring(giftB ~= nil),
						tostring(harness.Data.Owns(r1, "VIP")),
						tostring(harness.Data.Owns(r2, "VIP")),
						tostring(harness.Data.Owns(buyer, "VIP"))
					)
				).to.equal("survived=false giftB=true r1=false r2=true buyer=true")

				harness.Cleanup()
			end)
		end)
	end)
end
