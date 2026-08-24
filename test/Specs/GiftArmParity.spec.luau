--!nonstrict
-- ONLINE / OFFLINE RECEIPT PARITY.
--
-- A gift receipt takes one of two entirely separate implementations depending on
-- whether the buyer is still on this server: handleGiftReceipt writes through the
-- live accessor tree, handleOfflineReceipt writes raw fields inside an
-- UpdateOffline compare-and-set. The two are hand-mirrored, which means they can
-- drift, and every drift is a real-money difference nobody sees.
--
-- SIX THINGS THE TWO ARMS MUST AGREE ON, and each is one row of the table below:
--   1. the retired-product name check
--   2. the giftIntentTTL comparison (on wall time -- the value is persisted)
--   3. the credit conversion, including giftAlreadyDelivered(...) == false as an
--      EXPLICIT false (nil means "could not read the recipient" and must retry)
--   4. gating the answer on `durable`, never on `applied`
--   5. NoGiftIntentPolicy = Hold, and the owns-perk-plus-unused-credit decline
--   6. a dedupe re-check immediately before commit
--
-- Row 6 used to be the one that DISAGREED (F3: the offline arm never refreshed a
-- retrying intent's Ts, so its TTL ran out and the paid gift was lost). It is
-- fixed, and now sits at the bottom as an ordinary row. All six must keep passing.
--
-- EIGHT DIFFERENCES ARE DELIBERATE and a parity fix must not flatten them. The
-- cheap, load-bearing ones are pinned at the end of this file.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local BUYER = 91001
	local RECIPIENT = 91002
	local BUYER_KEY = "Default/PLAYER_91001"
	local RECIPIENT_KEY = "Default/PLAYER_91002"

	local function makeHarness(extraOptions)
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

	local function creditsOf(reserved): number
		local n = 0
		for _, count in reserved.GiftCredits or {} do
			n += tonumber(count) or 0
		end
		return n
	end

	local function pendingKeys(reserved): string
		local keys = {}
		for productIdStr in reserved.PendingGifts or {} do
			table.insert(keys, productIdStr)
		end
		table.sort(keys)
		return table.concat(keys, ",")
	end

	--- Drive one scenario down ONE arm and report an outcome comparable across
	--- both. Everything is read from the PERSISTED profile, not the live tree, so
	--- the online and offline runs are measured through the same lens.
	---
	--- `seed` runs with the buyer online and Ready; the offline arm then leaves
	--- before the receipt, so both arms start from the same durable state.
	local function runArm(online: boolean, opts, seed, purchaseId: string): (string, string)
		local outcome, pending
		withClock(1700000000, function(advance)
			local harness = makeHarness(opts)
			local buyer, entry = harness.Join(BUYER)
			seed(harness, buyer, entry, advance)
			harness.Data.Flush(buyer)
			if not online then
				harness.Leave(buyer)
			end

			local decision = harness.Data.HandleReceipt(receipt(BUYER, 222, purchaseId))

			if online then
				harness.Data.Flush(buyer)
				harness.Leave(buyer)
			end
			local reserved = harness.Fake.Persisted[BUYER_KEY]._Scribe
			local mailbox = harness.Fake.Mailboxes[RECIPIENT_KEY]
			outcome = ("d=%s buyerVIP=%s credits=%d queued=%d"):format(
				if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
				tostring(reserved.Perks.VIP == true),
				creditsOf(reserved),
				if mailbox then #mailbox else 0
			)
			pending = pendingKeys(reserved)
			harness.Cleanup()
		end)
		return outcome, pending
	end

	--- Both arms, one assertion. The two must agree with each other AND with the
	--- literal -- agreeing on the wrong answer is not parity.
	---
	--- What is compared is the DECISION and the money: the answer Roblox is given,
	--- whether the buyer ended up with the perk, how many credits they hold, and
	--- whether the gift actually went out. What is reported ALONGSIDE, never folded
	--- into the comparison, is each arm's leftover PendingGifts census -- the two
	--- arms legitimately differ there (see "only the ONLINE arm clears a TTL-expired
	--- slot" below), and letting a deliberate difference fail a parity row would
	--- teach the next reader to relax the row instead of the difference.
	local function bothArms(opts, seed, purchaseId: string): string
		local onlineOut, onlinePending = runArm(true, opts, seed, purchaseId .. "-on")
		local offlineOut, offlinePending = runArm(false, opts, seed, purchaseId .. "-off")
		if onlineOut ~= offlineOut then
			return ("DIVERGED\n  online : %s\n  offline: %s"):format(onlineOut, offlineOut)
		end
		return ("%s pendingOn=[%s] pendingOff=[%s]"):format(onlineOut, onlinePending, offlinePending)
	end

	--- Plant a gift intent on the live tree. Directly, not via PromptGift, so the
	--- stamp and the Product name are exactly what the row under test needs.
	local function plantIntent(entry, fields)
		local intent = {
			RecipientId = RECIPIENT,
			GiftId = "gift-" .. tostring(fields.GiftId or "x"),
			Ts = Clock.Now(),
			Product = "GiftVIP",
		}
		for key, value in fields do
			if key ~= "GiftId" then
				intent[key] = value
			end
		end
		entry.Tree.Reserved.PendingGifts["222"].Set(intent)
	end

	--- Give the recipient the perk durably, then put them back offline. Ordering
	--- matters: PromptGift refuses to create an intent for something the recipient
	--- already holds, so the seed has to run after the intent is planted.
	local function seedRecipientOwnsPerk(harness)
		local recipient = harness.Join(RECIPIENT)
		harness.Data.HandleReceipt(receipt(RECIPIENT, 222, "seed-recipient-perk"))
		harness.Data.Flush(recipient)
		harness.Leave(recipient)
	end

	--------------------------------------------------------------------------------
	-- ROWS 1-5: the parity table
	--------------------------------------------------------------------------------

	describe("the two receipt arms agree", function()
		it("row 1: an intent left by a RETIRED product reusing this Id is not honoured", function()
			-- Honouring it would ship the NEW product to the OLD intent's recipient.
			-- Online checks it in intentFor; offline hand-mirrors the check. Both must
			-- fall through to the no-intent policy and grant the buyer.
			expect(bothArms(nil, function(_harness, _buyer, entry)
				plantIntent(entry, { GiftId = "retired", Product = "RetiredCoinPack" })
			end, "row1")).to.equal("d=GRANTED buyerVIP=true credits=0 queued=0 pendingOn=[] pendingOff=[222]")
		end)

		it("row 2: an intent older than GiftIntentTTL is not honoured", function()
			-- The comparison is on Clock.Now (WALL time) on both arms, and has to be:
			-- the stamp is persisted and read back in a later session, where a
			-- monotonic value would be meaningless.
			expect(bothArms({ GiftIntentTTL = 300 }, function(_harness, _buyer, entry)
				plantIntent(entry, { GiftId = "stale", Ts = Clock.Now() - 400 })
			end, "row2")).to.equal("d=GRANTED buyerVIP=true credits=0 queued=0 pendingOn=[] pendingOff=[222]")
		end)

		it("row 3: a recipient who already owns the perk converts the purchase to a credit", function()
			-- The four-way conjunction: perk product, no Grant, duplicates disallowed,
			-- recipient owns it -- AND giftAlreadyDelivered(...) == false as an
			-- EXPLICIT false. A nil there means the recipient's data could not be read,
			-- which must fall through to a retry and never to a credit.
			expect(bothArms(nil, function(harness, _buyer, entry)
				plantIntent(entry, { GiftId = "owned" })
				seedRecipientOwnsPerk(harness)
			end, "row3")).to.equal("d=GRANTED buyerVIP=false credits=1 queued=0 pendingOn=[] pendingOff=[]")
		end)

		it("row 4: NoGiftIntentPolicy=Hold holds an owned-perk purchase on both arms", function()
			-- No intent, buyer already owns the perk, no credit banked. "Hold" means
			-- retry rather than auto-convert -- and Roblox refunds a purchase that is
			-- never processed.
			expect(bothArms({ NoGiftIntentPolicy = "Hold" }, function(harness, buyer)
				harness.Data.HandleReceipt(receipt(BUYER, 222, "seed-buyer-perk"))
				harness.Data.Flush(buyer)
			end, "row4")).to.equal("d=NOT_PROCESSED buyerVIP=true credits=0 queued=0 pendingOn=[] pendingOff=[]")
		end)

		it("row 5: an owned perk plus an unused credit is DECLINED on both arms", function()
			-- The money could only stack a second credit, so neither arm takes it.
			-- The two arms check this in the opposite ORDER (online declines before
			-- consulting Hold, offline consults Hold first), which is invisible under
			-- the default policy and is why this row runs on the default.
			expect(bothArms(nil, function(harness, buyer, entry)
				harness.Data.HandleReceipt(receipt(BUYER, 222, "seed-buyer-perk"))
				entry.Tree.Reserved.GiftCredits.GiftVIP.Set(1)
				harness.Data.Flush(buyer)
			end, "row5")).to.equal("d=NOT_PROCESSED buyerVIP=true credits=1 queued=0 pendingOn=[] pendingOff=[]")
		end)
	end)

	--------------------------------------------------------------------------------
	-- DELIBERATE DIFFERENCES -- a parity fix must NOT flatten these.
	--------------------------------------------------------------------------------

	describe("the differences that are on purpose", function()
		it("only the ONLINE arm fires OnGiftCredit -- an offline buyer has no Player", function()
			withClock(1700000000, function()
				local harness = makeHarness()
				local fired = {}
				harness.Data.OnGiftCredit:Connect(function(_player, productName)
					table.insert(fired, productName)
				end)

				local buyer, entry = harness.Join(BUYER)
				entry.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = RECIPIENT,
					GiftId = "gift-online-credit",
					Ts = Clock.Now(),
					Product = "GiftVIP",
				})
				seedRecipientOwnsPerk(harness)
				harness.Data.Flush(buyer)

				expect(harness.Data.HandleReceipt(receipt(BUYER, 222, "signal-online"))).to.equal(GRANTED)
				task.wait()
				local onlineFires = #fired

				-- Same conversion, buyer offline. No Player, so no signal.
				entry.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = RECIPIENT,
					GiftId = "gift-offline-credit",
					Ts = Clock.Now(),
					Product = "GiftVIP",
				})
				harness.Data.Flush(buyer)
				harness.Leave(buyer)
				expect(harness.Data.HandleReceipt(receipt(BUYER, 222, "signal-offline"))).to.equal(GRANTED)
				task.wait()

				expect(("online=%d total=%d"):format(onlineFires, #fired)).to.equal("online=1 total=1")
				harness.Cleanup()
			end)
		end)

		it("both arms emit the SAME log code for the same decision, with different context", function()
			-- Codes are the operator's contract (check-log-codes counts them); the
			-- context fields are not, and deliberately differ: Player online, UserId
			-- offline, because an offline buyer has no Player instance to name.
			withClock(1700000000, function()
				local seen = {}
				local unsubscribe = Scribe.AddLogSink(function(entry)
					if entry.Code == "GIFT_RECIPIENT_ALREADY_OWNS" then
						local context = entry.Context or {}
						table.insert(seen, if context.Player ~= nil then "Player" else "UserId")
					end
				end)

				local harness = makeHarness()
				local buyer, entry = harness.Join(BUYER)
				entry.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = RECIPIENT,
					GiftId = "gift-code-online",
					Ts = Clock.Now(),
					Product = "GiftVIP",
				})
				seedRecipientOwnsPerk(harness)
				harness.Data.Flush(buyer)
				expect(harness.Data.HandleReceipt(receipt(BUYER, 222, "code-online"))).to.equal(GRANTED)

				entry.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = RECIPIENT,
					GiftId = "gift-code-offline",
					Ts = Clock.Now(),
					Product = "GiftVIP",
				})
				harness.Data.Flush(buyer)
				harness.Leave(buyer)
				expect(harness.Data.HandleReceipt(receipt(BUYER, 222, "code-offline"))).to.equal(GRANTED)
				task.wait()
				unsubscribe()

				expect(table.concat(seen, ",")).to.equal("Player,UserId")
				harness.Cleanup()
			end)
		end)

		it("only the ONLINE arm clears a TTL-expired slot; offline ignores it in place", function()
			-- Offline skips the clear on purpose: it sits on a read-only path, and
			-- clearing would cost an extra DataStore round trip to remove a record the
			-- OnLoad sweep will collect for free on the buyer's next session. Rows 1
			-- and 2 above already show the DECISION is the same either way; this pins
			-- that the storage difference is intended, so a parity fix that "tidies"
			-- it has to say so.
			withClock(1700000000, function()
				local harness = makeHarness({ GiftIntentTTL = 300 })
				local buyer, entry = harness.Join(BUYER)
				entry.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = RECIPIENT,
					GiftId = "gift-ttl",
					Ts = Clock.Now() - 400,
					Product = "GiftVIP",
				})
				harness.Data.Flush(buyer)
				harness.Leave(buyer)

				expect(harness.Data.HandleReceipt(receipt(BUYER, 222, "ttl-offline"))).to.equal(GRANTED)
				local afterOffline = pendingKeys(harness.Fake.Persisted[BUYER_KEY]._Scribe)

				-- Same profile, same stale intent, buyer now ONLINE.
				local buyer2, entry2 = harness.Join(BUYER)
				entry2.Tree.Reserved.PendingGifts["222"].Set({
					RecipientId = RECIPIENT,
					GiftId = "gift-ttl-2",
					Ts = Clock.Now() - 400,
					Product = "GiftVIP",
				})
				harness.Data.Flush(buyer2)
				-- GRANTED, and for a reason worth naming: the offline receipt above
				-- already granted the buyer the perk, so this one falls into the
				-- no-intent policy with the perk owned and no credit banked, and
				-- GrantOrCredit mints one. The slot census is what this test is about.
				expect(harness.Data.HandleReceipt(receipt(BUYER, 222, "ttl-online"))).to.equal(GRANTED)
				harness.Data.Flush(buyer2)
				local afterOnline = pendingKeys(harness.Fake.Persisted[BUYER_KEY]._Scribe)

				expect(("offline=[%s] online=[%s]"):format(afterOffline, afterOnline)).to.equal(
					"offline=[222] online=[]"
				)
				harness.Cleanup()
			end)
		end)
	end)

	--------------------------------------------------------------------------------
	-- ROW 6: the TTL clock keeps running offline, and both arms now hold against it.
	--------------------------------------------------------------------------------

	describe("the two receipt arms agree (row 6)", function()
		it("keeps a paid gift alive when the retries outlive the TTL, offline as well as online", function()
			-- The same timeline down both arms: PromptGift at t=0, receipt retries at
			-- t=0, t=200 and t=400, GiftIntentTTL = 300, delivery down until t=400.
			--
			-- BOTH arms now refresh the intent's Ts on a failed delivery, under a GiftId
			-- guard, so at t=400 the intent is 200s old and still live and the gift goes
			-- out. The age is measured on WALL time because the stamp is persisted, and
			-- that is exactly why the refresh is needed: the TTL keeps running while
			-- Roblox retries, whether or not the buyer is still on this server.
			--
			-- THIS BLOCK RECORDED THE F3 DEFECT AND HAS NOW FLIPPED. Before the fix the
			-- offline arm had no refresh at all: at t=400 the intent was 400s old, the
			-- arm ignored it, fell into the no-intent policy, granted the perk to the
			-- BUYER and answered PurchaseGranted -- Roblox stopped retrying, the gift was
			-- gone for good, the buyer kept a perk they had bought for someone else, and
			-- nothing was logged as an error. The line it measured was
			--   offline: retries=N,N final=GRANTED queued=0 buyerVIP=true
			--
			-- The fix could not be a bare field write: on an absent or reassigned slot
			-- that is the phantom-intent bug (see GiftIntentNet.spec), and offline there
			-- is no accessor tree to raise on it. It happens INSIDE an UpdateOffline
			-- transform that re-reads the slot and compares GiftId; the phantom and
			-- reassignment cases are pinned in GiftOfflineIntentRefresh.spec.
			local function timeline(online: boolean, tag: string): string
				local out
				withClock(1700000000, function(advance)
					local harness = makeHarness({ GiftIntentTTL = 300 })
					local buyer = harness.Join(BUYER)
					expect(harness.Data.PromptGift(buyer, "GiftVIP", RECIPIENT)).to.equal(true)
					harness.Data.Flush(buyer)
					if not online then
						harness.Leave(buyer)
					end

					harness.Fake.FailMessages = true
					local first = harness.Data.HandleReceipt(receipt(BUYER, 222, tag))
					advance(200)
					local second = harness.Data.HandleReceipt(receipt(BUYER, 222, tag))
					advance(200)
					harness.Fake.FailMessages = false
					local third = harness.Data.HandleReceipt(receipt(BUYER, 222, tag))

					if online then
						harness.Data.Flush(buyer)
						harness.Leave(buyer)
					end
					local reserved = harness.Fake.Persisted[BUYER_KEY]._Scribe
					local mailbox = harness.Fake.Mailboxes[RECIPIENT_KEY]
					out = ("retries=%s,%s final=%s queued=%d buyerVIP=%s"):format(
						if first == GRANTED then "G" else "N",
						if second == GRANTED then "G" else "N",
						if third == GRANTED then "GRANTED" else "NOT_PROCESSED",
						if mailbox then #mailbox else 0,
						tostring(reserved.Perks.VIP == true)
					)
					harness.Cleanup()
				end)
				return out
			end

			local onlineOut = timeline(true, "f3-online")
			local offlineOut = timeline(false, "f3-offline")
			expect(("online : %s\noffline: %s"):format(onlineOut, offlineOut)).to.equal(
				"online : retries=N,N final=GRANTED queued=1 buyerVIP=false\n"
					.. "offline: retries=N,N final=GRANTED queued=1 buyerVIP=false"
			)
		end)
	end)
end
