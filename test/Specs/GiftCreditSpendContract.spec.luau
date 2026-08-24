--!nonstrict
-- CHARACTERISATION. The gift-credit SPEND path, and the double grant its current
-- shape exists to prevent.
--
-- WHAT THIS FILE PINS. `PromptGift` has a branch nobody pays Robux for: when the
-- buyer already holds an unassigned credit for the product, the credit is spent
-- instead of a purchase being prompted. Between the spend and the answer sit two
-- yields -- a durability await on the BUYER's profile, and the delivery itself --
-- so every ordering below is a place real money can be lost or duplicated. These
-- specs pin the observable contract at each of them: what the buyer is told, what
-- the buyer still holds, and what the recipient ends up owning.
--
-- THE TWO SECTIONS THAT MATTER ARE THE DOUBLE-GRANT ONES, and they are two routes
-- to the same place. Both come of the same missing property: a credit spend mints
-- its giftId per call and persists it nowhere, so ANY credit handed back after a
-- delivery that actually happened can buy a second grant under an id the
-- recipient's dedupe ring has never seen.
--
-- ROUTE ONE, the SAVE in doubt. The spend gates delivery on `deliverGift`'s FIRST
-- return (`applied`) rather than its second (`durable`), and the comment at that
-- line says why: a same-server recipient's grant is applied to their live data and
-- marked processed under `credit:{giftId}`, so refunding merely because the
-- recipient's confirming save did not land would let the buyer SPEND THE SAME
-- CREDIT AGAIN under a FRESH giftId. One payment, two grants. That gate holds it
-- shut, and the F4 deferral that keeps it is correct.
--
-- ROUTE TWO, the SEND in doubt -- and this one was OPEN IN SHIPPED CODE, with no
-- `durable` gate involved at all. An offline or other-server delivery is a
-- MessageAsync commit that can land and then lose its answer, and the arm that
-- read any `applied = false` as "did not deliver" refunded there, told the buyer to
-- try again, and let the retry queue a second gift. Measured: 2000 coins from one
-- credit, no Robux. So the reason written at the gate was TRUE AND INCOMPLETE --
-- it named a hazard a `durable` gate would open while an equivalent one stood open
-- next to it. Closed by splitting "provably not delivered" from "unconfirmed" and
-- refunding only the first: `deliverGift`'s third return.
--
-- That claim was argued in a comment and asserted by nothing. It is asserted here,
-- and deliberately as an INVARIANT rather than as a snapshot of today's answer:
--   * one payment yields ONE grant whichever way the gate settles -- if the credit
--     is handed back, the re-spend has to be caught by the recipient's dedupe;
--   * every spend mints a FRESH `credit:{giftId}`, so the ring cannot tell a retry
--     from a genuine second gift -- the fact that makes the naive fix unsafe; and
--   * a REUSED purchaseId is caught by that same ring -- the fact that makes a
--     correct fix possible, if the retry can be made to reuse its giftId; and
--   * that catch has a floor: the ring's COUNT eviction drops a LIVE credit marker,
--     after which the identical purchaseId grants a second time. A stable giftId
--     buys dedupe only for as long as the recipient's ring still holds the id, and
--     a credit retry is human-paced where a receipt retry is not.
--
-- The naive fix -- refund on a non-durable save, with a fresh giftId -- turns the
-- first of those red, which is why F4 stays deferred. The AMBIGUOUS section below
-- is the same principle failing at a different gate: it holds the identical
-- one-payment-one-grant line over a SEND whose answer was lost, and the shipped
-- tree failed it. Same invariant, different doubt, and that one was a defect
-- rather than a deferral.
--
-- Two specs at the end record how the gate settles TODAY rather than a permanent
-- contract, and say so; they are the only ones a deliberate F4 fix should rewrite.
--
-- STACKABLE ON PURPOSE. The gifted product grants coins through a `Grant`
-- callback and declares no `Grants` perk. A perk is idempotent -- granting VIP
-- twice looks exactly like granting it once -- so a boolean product cannot show a
-- double grant at all. Coins can, and `Grants` being absent is also what takes
-- PromptGift's duplicate-recipient guard off the path, which is what lets the same
-- recipient legally be gifted the same product twice.
--
-- SEAMS. `Persistence.AwaitSave` is patched per-user, which is the only way to
-- separate `applied` from `durable`: the fake's global `FailSaves` would fail the
-- BUYER's reservation too and never reach delivery. `jamInbox` is the offline
-- delivery failure that PROVABLY wrote nothing -- a full inbox found on the first
-- attempt, which is what the store now reports as `provably_clean`; a throwing
-- `Grant` is the same-server one. `commitThenLoseTheAnswer` is the third shape,
-- which neither of those can express: a write that COMMITS and then fails to say
-- so. `commitThenAnswerQueueFull` is the fourth, and the one that broke the first
-- fix: a write that COMMITS and is then answered `QueueFull` by a LATER attempt of
-- the same call, so the reason string alone cannot be trusted. Keeping the four
-- apart is the whole point -- a refund is correct on the first two and is the bug
-- on the last two -- and each seam states its own `provably_clean`, because the
-- store's third return is what the split is now made of.
-- Existing coverage NOT rebuilt here: GiftCreditBuyerLeaves.spec (the refund
-- when the buyer has left), GiftCreditClearGuard.spec (the receipt arm that MINTS
-- a credit), AwaitSaveMoneyContract.spec (the receipt decision on a failing save).

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local COINS_GIFT = 771
	local BAD_GIFT = 772

	local BUYER = 95101
	local RECIPIENT = 95102

	--- `extra` overlays the bundle options, and exists for exactly one spec: the
	--- ring's count backstop is only reachable by lowering the cap, and lowering it
	--- for every harness here would change what every other spec measures.
	local function makeHarness(fake, extra: { [string]: any }?)
		local prompted = {}
		local options: { [string]: any } = {
			Products = {
				-- Stackable, and deliberately without `Grants`: see the header.
				CoinsGift = {
					Id = COINS_GIFT,
					Category = "Currency",
					Grant = function(data)
						data.Coins.Increment(1000)
					end,
				},
				-- Same-server delivery failure: the Grant throws, RunTransaction
				-- rolls it back, and deliverGiftLocal answers (false, false).
				BadGift = {
					Id = BAD_GIFT,
					Category = "Currency",
					Grant = function()
						error("Grant refused")
					end,
				},
			},
			GiftCooldown = 0,
			PromptProductPurchase = function(player, productId)
				table.insert(prompted, { Player = player, ProductId = productId })
			end,
		}
		for key, value in extra or {} do
			options[key] = value
		end
		local harness = TestCtx.make({ Fake = fake, Options = options })
		harness.Prompted = prompted
		return harness
	end

	--- A buyer holding `count` unassigned credits, durably. Durably matters: the
	--- spend's whole discipline is "reserve on disk, then deliver", and a credit
	--- that was never on disk cannot show whether that ordering held.
	local function buyerWith(harness, userId: number, product: string, count: number)
		local buyer, entry, data = harness.Join(userId)
		entry.Tree.Reserved.GiftCredits[product].Set(count)
		expect(harness.Data.Flush(buyer, { Force = true })).to.equal(true)
		return buyer, entry, data
	end

	local function storedProfile(harness, userId: number)
		return harness.Fake.Persisted[`Default/PLAYER_{userId}`]
	end

	local function storedCredits(harness, userId: number, product: string)
		local stored = storedProfile(harness, userId)
		local scribe = stored and stored._Scribe
		local credits = scribe and scribe.GiftCredits
		return tonumber(credits and credits[product])
	end

	local function liveCredits(harness, buyer, product: string): number
		return tonumber(harness.Data.GetGiftCredits(buyer)[product]) or 0
	end

	local function mailbox(harness, userId: number)
		return harness.Fake.Mailboxes[`Default/{harness.Ctx.Persistence.KeyFor(userId)}`] or {}
	end

	--- Every purchaseId in a ring, in order. The ring holds `{ Id, At }` and, on
	--- profiles written before age-based eviction, bare strings.
	local function ringIds(list): { string }
		local ids = {}
		for _, item in list or {} do
			table.insert(ids, if type(item) == "string" then item else tostring(item.Id))
		end
		return ids
	end

	local function liveRing(entry): { string }
		return ringIds(entry.LiveData._Scribe.ProcessedPurchaseIds)
	end

	--- Only the ids this path mints, so an unrelated marker cannot pad the count.
	local function creditIds(ids: { string }): { string }
		local out = {}
		for _, id in ids do
			if string.sub(id, 1, 7) == "credit:" then
				table.insert(out, id)
			end
		end
		return out
	end

	--- Force `Persistence.AwaitSave` to answer FALSE for ONE user and behave
	--- normally for everyone else. This is the (applied = true, durable = false)
	--- construction, and there is no other way to reach it: the fake's global
	--- `FailSaves` would fail the buyer's reservation save first, so the run would
	--- refuse at the reservation and never deliver anything at all.
	---
	--- It also means no save is attempted for that user, so their PERSISTED profile
	--- genuinely lacks whatever the delivery put in memory -- which is exactly the
	--- state a recipient crash leaves behind, and what the accepted-cost spec reads.
	local function saveNeverConfirmsFor(harness, userId: number)
		local persistence = harness.Ctx.Persistence
		local real = persistence.AwaitSave
		persistence.AwaitSave = function(entry, timeout)
			if entry ~= nil and entry.UserId == userId then
				return false
			end
			return real(entry, timeout)
		end
		return function()
			persistence.AwaitSave = real
		end
	end

	--- Make every MessageAsync report a full queue: the delivery failure that
	--- answers `applied = false` without any DataStore fault.
	---
	--- CLAIMS PROVABLY CLEAN, on the store's third return, because that is the shape
	--- it stands in for: a full inbox with no attempt behind it that could have
	--- written, where the transform ran, saw the cap, aborted the write in band and
	--- said so. The store answers
	--- `(false, "QueueFull", true)` there, and a seam that stayed silent would be
	--- modelling the ambiguous QueueFull below instead -- turning the ordinary
	--- full-inbox refund, which is the common case, into a swallowed credit.
	local function jamInbox(harness, before: (() -> ())?)
		local store = harness.Ctx.Persistence.Store
		local real = store.MessageAsync
		store.MessageAsync = function()
			if before then
				before()
			end
			return false, "QueueFull", true
		end
		return function()
			store.MessageAsync = real
		end
	end

	--- THE AMBIGUOUS COMMIT: `MessageAsync` writes the message to the recipient's
	--- key and THEN loses its answer. The write LANDED; the caller cannot know it.
	---
	--- Not a hypothetical shape. ProfileStore's MessageAsync loops UpdateAsync with
	--- exponential backoff and answers a BARE `false` when `IsClosing` ends the loop
	--- (BindToClose), and the DataStore write underneath can commit and then time out
	--- -- 504, which `Failure.Classify` already calls `Unresolved` in this very
	--- codebase, with the note "the write MAY HAVE LANDED". Both land on the same
	--- `deliverGift` exit: the one that reports GIFT_DELIVERY_RETRY. `mode` picks
	--- which of the two produced it, because they must settle identically.
	---
	--- Only the FIRST send is broken. The defect is about what the buyer does NEXT,
	--- so the retry has to reach a WORKING store -- otherwise a second grant could be
	--- blamed on the seam rather than on the fresh giftId that actually causes it.
	local function commitThenLoseTheAnswer(harness, mode: "throw" | "giveup")
		local store = harness.Ctx.Persistence.Store
		local real = store.MessageAsync
		local sends = 0
		store.MessageAsync = function(self, profileKey, message)
			sends += 1
			if sends > 1 then
				return real(self, profileKey, message)
			end
			real(self, profileKey, message) -- it COMMITS ...
			if mode == "throw" then
				error("504: Datastore request timed out.") -- ... and then this
			end
			return false -- ... or the retry loop simply gives up, with no reason
		end
		return function()
			store.MessageAsync = real
		end
	end

	--- THE COMMIT A LATER ATTEMPT CALLS `QueueFull`. Sibling of the seam above, and
	--- the shape neither it nor `jamInbox` can express: a send that COMMITS and is then
	--- answered `(false, "QueueFull")` by the SAME call.
	---
	--- `(false, "QueueFull")` is a statement about the LAST attempt of ProfileStore's
	--- internal retry loop, never about the call. That loop repeats while UpdateAsync
	--- answers nil -- which is exactly what a write that committed and then timed out
	--- leaves behind -- and re-runs the cap check inside the transform on every pass
	--- (ProfileStore.luau:2503-2586). So an earlier attempt can have written the message
	--- and lost only its reply, after which the retry finds the queue at its cap, sets
	--- AbortWrite, and reports a refusal for a call that already delivered. Nothing
	--- coincidental is needed to fill the queue in between: this call's own committed
	--- insert can be what fills it, and the recipient's inbox is shared with every other
	--- server besides.
	---
	--- Fabricated, the way its sibling fabricates a throw, because one fake
	--- MessageAsync call is one attempt and cannot loop. The pair is not invented --
	--- the honesty spec below drives the fake's OWN cap logic into producing it after a
	--- commit that stands -- and neither is the consequence: `deliverGift` reads this
	--- arm as PROVABLY not delivered, and the credit spend refunds on it.
	---
	--- Only the FIRST send is broken, for the sibling's reason: the retry has to reach a
	--- working store, or a second grant could be blamed on the seam rather than on the
	--- fresh giftId that actually causes it.
	---
	--- THE STORE NOW TELLS THE TWO APART, AND THIS SEAM SAYS WHICH IT IS. MessageAsync
	--- answers a third value, `provably_clean`, true only where nothing can have been
	--- written (ProfileStore.luau:2464-2501). The seams are what stand in for the store:
	--- `jamInbox` models a first-attempt refusal and claims it, this one models a
	--- QueueFull that FOLLOWS a commit and must not. `false` is written out here rather
	--- than left absent, because the whole point of this seam is the claim it refuses to
	--- make -- and because an absent value would model the fix's failure mode rather
	--- than the store. No assertion below moved when the store learned the word.
	local function commitThenAnswerQueueFull(harness)
		local store = harness.Ctx.Persistence.Store
		local real = store.MessageAsync
		local sends = 0
		store.MessageAsync = function(self, profileKey, message)
			sends += 1
			if sends > 1 then
				return real(self, profileKey, message)
			end
			real(self, profileKey, message) -- an early attempt COMMITS ...
			-- ... and a later one finds the queue at its cap. NOT clean: this call may
			-- already have written, which is exactly what the third value reports.
			return false, "QueueFull", false
		end
		return function()
			store.MessageAsync = real
		end
	end

	describe("a gift credit spent on a recipient who is here", function()
		it("answers success, consumes exactly one credit, and grants exactly once", function()
			-- The baseline every other spec is measured against. A credit spend is
			-- not a purchase: it must deliver, cost one credit, and prompt nothing.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 2)
			local _, recipientEntry, recipientData = harness.Join(RECIPIENT)

			local ok, reason = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)

			expect(ok).to.equal(true)
			expect(reason).to.equal(nil)
			expect(liveCredits(harness, buyer, "CoinsGift")).to.equal(1)
			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(1)
			expect(#harness.Prompted).to.equal(0)

			harness.Cleanup()
		end)

		it("fires OnGiftReceived once, carrying the giftId the purchaseId is built from", function()
			-- The buyer's side is a boolean; the RECIPIENT's side is this signal, and
			-- the id it reports is the same one `credit:{giftId}` is keyed on. Any fix
			-- that changes where the giftId comes from has to keep the two agreeing.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			local _, recipientEntry = harness.Join(RECIPIENT)

			local received = {}
			harness.Data.OnGiftReceived:Connect(function(player, info)
				table.insert(received, { UserId = player.UserId, Info = info })
			end)

			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)

			expect(#received).to.equal(1)
			expect(received[1].UserId).to.equal(RECIPIENT)
			expect(received[1].Info.FromUserId).to.equal(BUYER)
			expect(received[1].Info.Product).to.equal("CoinsGift")
			expect(creditIds(liveRing(recipientEntry))[1]).to.equal(`credit:{received[1].Info.GiftId}`)

			harness.Cleanup()
		end)

		it("spends the buyer's LAST credit down to nothing rather than to zero", function()
			-- The accessor is cleared, not set to 0: a lingering `CoinsGift = 0` key
			-- would keep an empty entry in the persisted GiftCredits object forever,
			-- and GetGiftCredits would report a credit the buyer does not have.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			harness.Join(RECIPIENT)

			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)

			expect(harness.Data.GetGiftCredits(buyer).CoinsGift).to.equal(nil)
			expect(harness.Data.Flush(buyer, { Force = true })).to.equal(true)
			expect(storedCredits(harness, BUYER, "CoinsGift")).to.equal(nil)

			harness.Cleanup()
		end)
	end)

	describe("a gift credit when the reservation cannot be made durable", function()
		it("refuses with the reservation reason and hands the credit back once", function()
			-- Reservation FIRST, delivery second. If the buyer's save cannot confirm,
			-- nothing may be delivered -- otherwise a crash restores a credit that has
			-- already bought a gift. The refund is exactly one credit, never two.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			local _, recipientEntry, recipientData = harness.Join(RECIPIENT)

			local restore = saveNeverConfirmsFor(harness, BUYER)
			local ok, reason = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			expect(ok).to.equal(false)
			expect(reason).to.equal("could not reserve gift credit; try again later")
			expect(liveCredits(harness, buyer, "CoinsGift")).to.equal(1)
			-- Nothing was delivered: the recipient is untouched, marker and all.
			expect(recipientData.Coins.Get()).to.equal(0)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(0)
			expect(#harness.Prompted).to.equal(0)

			harness.Cleanup()
		end)
	end)

	describe("a gift credit when delivery fails", function()
		it("refunds once and refuses when a same-server Grant throws", function()
			-- The same-server failure arm. GiftCreditBuyerLeaves covers the OFFLINE
			-- failure (a jammed inbox); this is the other way `applied` comes back
			-- false, and it must refund identically.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "BadGift", 1)
			local _, recipientEntry, recipientData = harness.Join(RECIPIENT)

			local ok, reason = harness.Data.PromptGift(buyer, "BadGift", RECIPIENT)

			expect(ok).to.equal(false)
			expect(reason).to.equal("could not deliver gift; try again later")
			expect(liveCredits(harness, buyer, "BadGift")).to.equal(1)
			expect(recipientData.Coins.Get()).to.equal(0)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(0)

			harness.Cleanup()
		end)

		it("has already put the reservation on disk by the time delivery is attempted", function()
			-- The ordering itself, read from the DataStore mid-flight rather than
			-- inferred from the outcome: at the instant delivery runs, the buyer's
			-- PERSISTED credit is already spent. That is what makes the refund arm
			-- safe -- a crash here loses a credit, it does not duplicate a gift.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			expect(storedCredits(harness, BUYER, "CoinsGift")).to.equal(1)

			local duringDelivery
			local restore = jamInbox(harness, function()
				duringDelivery = storedCredits(harness, BUYER, "CoinsGift")
			end)
			-- No recipient entry on this server, so delivery goes by MessageAsync.
			local ok = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			expect(ok).to.equal(false)
			expect(duringDelivery).to.equal(nil) -- spent, and durably so
			expect(liveCredits(harness, buyer, "CoinsGift")).to.equal(1) -- then refunded
			expect(#harness.Prompted).to.equal(0)

			harness.Cleanup()
		end)
	end)

	describe("a gift credit spent on a recipient who is not here", function()
		it("commits one mailbox message keyed on the credit purchaseId", function()
			-- Offline delivery is a MessageAsync commit, which IS the durable copy.
			-- The buyer's credit is gone and the paid gift lives in the recipient's
			-- inbox under a fixed purchaseId -- the property the contrast below turns
			-- into dedupe safety.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)

			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)
			expect(liveCredits(harness, buyer, "CoinsGift")).to.equal(0)

			local queued = mailbox(harness, RECIPIENT)
			expect(#queued).to.equal(1)
			expect(queued[1].ScribeGift).to.equal(true)
			expect(queued[1].Product).to.equal("CoinsGift")
			expect(queued[1].FromUserId).to.equal(BUYER)
			expect(queued[1].PurchaseId).to.equal(`credit:{queued[1].GiftId}`)

			harness.Cleanup()
		end)

		it("grants exactly once when the recipient finally arrives", function()
			-- The end of the offline path: the gift is delivered on the recipient's
			-- next save, once, and the message is acked out of the inbox.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)

			local recipient, _, recipientData = harness.Join(RECIPIENT)
			expect(harness.Data.Flush(recipient, { Force = true })).to.equal(true)

			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#mailbox(harness, RECIPIENT)).to.equal(0)

			harness.Cleanup()
		end)

		it("goes by mailbox for a recipient live on ANOTHER server, and grants once there", function()
			-- `EntryForUserId` only sees this server, so a recipient playing elsewhere
			-- takes the same durable route as an offline one. Two harnesses over one
			-- fake, which is the only way this hazard exists at all.
			local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
			local fake = FakeProfileStore.new()
			local serverA = makeHarness(fake)
			local serverB = makeHarness(fake)

			local buyer = buyerWith(serverA, BUYER, "CoinsGift", 1)
			local recipient, recipientEntry, recipientData = serverB.Join(RECIPIENT)

			expect(serverA.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)
			expect(liveCredits(serverA, buyer, "CoinsGift")).to.equal(0)
			-- Not applied on B yet: MessageAsync only COMMITS.
			expect(recipientData.Coins.Get()).to.equal(0)

			expect(serverB.Data.Flush(recipient, { Force = true })).to.equal(true)

			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(1)

			serverB.Cleanup()
			serverA.Cleanup()
		end)
	end)

	describe("THE DOUBLE GRANT the `applied` gate prevents", function()
		it("INVARIANT: one payment yields ONE grant, however the gate settles", function()
			-- THE SPEC A FIX MUST KEEP GREEN, and the reason F4 was deferred.
			--
			-- Deliberately written to hold under BOTH settlements, because the naive
			-- fix fails it while a correct one does not. Force `deliverGift` to answer
			-- (applied = true, durable = false), then look at what the buyer is left
			-- holding:
			--
			--   * nothing (today, gating on `applied`) -- there is no second spend, so
			--     there cannot be a second grant; or
			--   * the credit back (a `durable` gate) -- and then the re-spend MUST be
			--     caught by the recipient's dedupe, which only happens if it reuses
			--     the ORIGINAL giftId. Minting a fresh `Util.guid()` the way the spend
			--     does today puts a purchaseId in front of the ring that it has never
			--     seen, and the recipient is granted a SECOND time off one payment.
			--
			-- So this goes red for exactly one implementation: refund WITHOUT a stable
			-- giftId. That is the bug the comment at the gate refuses to ship, and it
			-- is worse than the value loss it would close.
			--
			-- `ok` is deliberately not asserted: today the spend answers success, a
			-- `durable` gate would answer refusal, and both are legitimate ANSWERS.
			-- What is not legitimate is two grants.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			local _, recipientEntry, recipientData = harness.Join(RECIPIENT)

			local restore = saveNeverConfirmsFor(harness, RECIPIENT)
			harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			-- The grant reached the recipient's memory either way; that is what
			-- `applied` means and it is not in question.
			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(1)

			if liveCredits(harness, buyer, "CoinsGift") > 0 then
				-- Refunded. The re-spend is a RETRY of a gift already delivered, so it
				-- has to land on the id the recipient has already processed.
				expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)
				expect(recipientData.Coins.Get()).to.equal(1000)
				expect(#creditIds(liveRing(recipientEntry))).to.equal(1)
			else
				-- Not refunded. There is nothing to re-spend, so the buyer's next gift
				-- of this product is an ordinary purchase and the recipient still holds
				-- exactly one grant.
				expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)
				expect(#harness.Prompted).to.equal(1)
				expect(harness.Prompted[1].ProductId).to.equal(COINS_GIFT)
				expect(recipientData.Coins.Get()).to.equal(1000)
			end

			harness.Cleanup()
		end)

		it("INVARIANT: every spend mints a FRESH credit id, so the ring cannot tell a retry from a gift", function()
			-- The enabling fact behind the invariant above, isolated. Two genuine
			-- credit spends are two gifts and must both land -- that is correct, and
			-- it stays correct under any fix. The consequence is the whole difficulty:
			-- a spend carries no identity beyond a per-call `Util.guid()`, so nothing
			-- in a second `credit:{giftId}` distinguishes "the buyer gifted again"
			-- from "the buyer is retrying the gift they already paid for". The ring
			-- cannot dedupe what it cannot recognise.
			--
			-- A fix that makes a refunded credit safe to re-spend has to supply that
			-- missing identity -- persist the giftId alongside the reservation so the
			-- retry reuses it -- rather than change what this spec observes.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 2)
			local _, recipientEntry, recipientData = harness.Join(RECIPIENT)

			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)
			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)

			local ids = creditIds(liveRing(recipientEntry))
			expect(#ids).to.equal(2)
			expect(ids[2] == ids[1]).to.equal(false)
			expect(recipientData.Coins.Get()).to.equal(2000)
			expect(liveCredits(harness, buyer, "CoinsGift")).to.equal(0)
			expect(#harness.Prompted).to.equal(0)

			harness.Cleanup()
		end)

		it("THE CONTRAST: a REUSED credit purchaseId IS caught by the same ring", function()
			-- The ring is not broken; the giftId is not stable. Redeliver the very
			-- message the offline spend committed -- ProfileStore's delivery is
			-- at-least-once, so an unacked message really is re-handed to the handler
			-- -- and the second copy grants nothing, because its purchaseId is the one
			-- already marked.
			--
			-- This is what makes a fix POSSIBLE at all: if a re-spend reused the
			-- original giftId the way this redelivery reuses its purchaseId, the second
			-- attempt would land here instead of double-granting.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)

			local queued = mailbox(harness, RECIPIENT)
			expect(#queued).to.equal(1)
			local message = {
				ScribeGift = true,
				GiftId = queued[1].GiftId,
				PurchaseId = queued[1].PurchaseId,
				Product = queued[1].Product,
				FromUserId = queued[1].FromUserId,
			}

			local recipient, recipientEntry, recipientData = harness.Join(RECIPIENT)
			expect(harness.Data.Flush(recipient, { Force = true })).to.equal(true)
			expect(recipientData.Coins.Get()).to.equal(1000)

			-- The redelivery, same purchaseId.
			harness.Fake.Mailboxes[`Default/{harness.Ctx.Persistence.KeyFor(RECIPIENT)}`] = { message }
			expect(harness.Data.Flush(recipient, { Force = true })).to.equal(true)

			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(1)
			expect(#mailbox(harness, RECIPIENT)).to.equal(0) -- acked, not left to loop

			harness.Cleanup()
		end)

		it("THE LIMIT ON THAT CONTRAST: count eviction drops a LIVE credit marker", function()
			-- WHY A STABLE giftId IS NOT ENOUGH ON ITS OWN, measured rather than
			-- argued. The spec above shows a reused `credit:{giftId}` being caught, and
			-- that is the whole basis for "persist the giftId so a retry reuses it".
			-- The catch depends entirely on the recipient's ring STILL HOLDING the id,
			-- and the ring's count backstop drops the oldest un-expired entry to stay
			-- under MaxProcessedPurchaseIds -- the one eviction pruneProcessed's own
			-- comment admits can double-grant. Once it has run, the identical
			-- purchaseId grants a SECOND time.
			--
			-- The cap is lowered to 3 to reach the backstop in a test; at the default
			-- 200 the same rollover needs a busier recipient and more time. Time is
			-- exactly what a credit retry has: a receipt retry is machine-paced inside
			-- Roblox's window, while a buyer re-pressing a gift button is human-paced
			-- and bounded by nothing. That is the difference that makes the credit path
			-- MORE exposed to this hole than the receipt path it would be copying.
			local harness = makeHarness(nil, { MaxProcessedPurchaseIds = 3 })
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			-- Offline, so the spend commits a FIXED `credit:{giftId}` to the mailbox:
			-- the exact id a stable-giftId retry would reuse, obtained without having
			-- to build the fix to get one.
			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)
			local queued = mailbox(harness, RECIPIENT)
			expect(#queued).to.equal(1)
			local message = {
				ScribeGift = true,
				GiftId = queued[1].GiftId,
				PurchaseId = queued[1].PurchaseId,
				Product = queued[1].Product,
				FromUserId = queued[1].FromUserId,
			}

			local recipient, recipientEntry, recipientData = harness.Join(RECIPIENT)
			expect(harness.Data.Flush(recipient, { Force = true })).to.equal(true)
			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(1)

			-- The recipient keeps buying. Three ordinary receipts, three fresh ids, and
			-- the gift's marker is pushed out of a three-entry ring while it is still
			-- inside its TTL -- un-expired, still live, still the only thing standing
			-- between a retry and a second grant.
			for index = 1, 3 do
				expect(harness.Data.HandleReceipt({
					PlayerId = RECIPIENT,
					ProductId = COINS_GIFT,
					PurchaseId = `filler-{index}`,
					CurrencySpent = 99,
					CurrencyType = Enum.CurrencyType.Robux,
					PlaceIdWherePurchased = 0,
				})).to.equal(GRANTED)
			end
			expect(#creditIds(liveRing(recipientEntry))).to.equal(0)
			local coinsBefore = recipientData.Coins.Get()

			-- The same purchaseId a second time, which is precisely what a perfectly
			-- stable giftId would produce on retry.
			harness.Fake.Mailboxes[`Default/{harness.Ctx.Persistence.KeyFor(RECIPIENT)}`] = { message }
			expect(harness.Data.Flush(recipient, { Force = true })).to.equal(true)

			-- Granted again. One payment, two grants, with the id held perfectly fixed.
			expect(recipientData.Coins.Get()).to.equal(coinsBefore + 1000)

			harness.Cleanup()
		end)
	end)

	describe("THE DOUBLE GRANT an AMBIGUOUS delivery produces", function()
		-- THE SECOND ROUTE TO THE SAME DOUBLE GRANT. It was reachable on the shipped
		-- tree rather than only under a hypothetical `durable` gate, and it is CLOSED;
		-- these specs are what hold it closed.
		--
		-- The section above pins what happens when the recipient's SAVE is in doubt.
		-- This one is about the SEND being in doubt: the buyer spends a credit on a
		-- recipient who is offline or on another server, the mailbox write COMMITS,
		-- and the answer is lost on the way back. `deliverGift` could not tell that
		-- from a write that never happened, answered `applied = false`, and the credit
		-- arm REFUNDED -- handing back a credit for a gift that was already queued, and
		-- telling the buyer to try again. The retry mints a fresh `Util.guid()`, so the
		-- second message carried a `credit:{giftId}` the recipient's ring had never
		-- seen. One payment, two grants, and no `durable` gate involved.
		--
		-- So the F4 note at the gate was right about the fix it refuses and wrong about
		-- the safety it claimed: the double grant it describes was not merely a hazard
		-- a `durable` gate WOULD open, it was one the refund arm the `applied` gate
		-- keeps had open already. It was closed by `deliverGift`'s third return,
		-- `refundable`, which pays out only where delivery provably did not happen --
		-- and, once that return was found to be misclassifying in both directions, by
		-- the store answering `provably_clean` so the classification stops being a
		-- guess. The `applied` gate itself did not move.
		local function ambiguousSpendThenRetry(mode: "throw" | "giveup")
			-- One credit, one recipient who is NOT on this server, one broken send, and
			-- then the buyer does exactly what the answer told them to do.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)

			local restore = commitThenLoseTheAnswer(harness, mode)
			harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			-- The premise, asserted rather than assumed: the gift IS in the recipient's
			-- inbox. Whatever the buyer was told, this message is going to be delivered.
			expect(#mailbox(harness, RECIPIENT)).to.equal(1)

			-- The buyer presses again. Not a second gift -- a RETRY of the one they were
			-- just told had failed.
			harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)

			local recipient, recipientEntry, recipientData = harness.Join(RECIPIENT)
			expect(harness.Data.Flush(recipient, { Force = true })).to.equal(true)
			return harness, recipientEntry, recipientData
		end

		it("INVARIANT: one credit yields ONE grant when the send commits and the answer is thrown away", function()
			-- THE REPRODUCTION, and it WAS red: the refund handed the credit back, the
			-- retry queued a second message under a fresh id, and the recipient was
			-- granted twice off one paid credit.
			--
			-- Written as an invariant, not as a snapshot, which is why it needed no edit
			-- when the fix landed: the ambiguous arm stopped refunding, so the buyer's
			-- second press finds no credit and becomes an ordinary Robux prompt, which
			-- grants nothing here. Same assertion, opposite route to it.
			local harness, recipientEntry, recipientData = ambiguousSpendThenRetry("throw")

			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(1)

			harness.Cleanup()
		end)

		it("INVARIANT: and the same when MessageAsync gives up rather than throwing", function()
			-- The other way into `deliverGift`'s third exit: no error at all, just a
			-- bare `false` from the retry loop ending at BindToClose. Same ambiguity,
			-- same commit, so it must settle the same way -- a fix that read the error
			-- string would close one of these and leave the other open.
			local harness, recipientEntry, recipientData = ambiguousSpendThenRetry("giveup")

			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(1)

			harness.Cleanup()
		end)

		it("the seam is honest: an ambiguous send really does leave the gift in the inbox", function()
			-- The premise on its own, so a failure above cannot be waved away as the
			-- harness lying. The message is committed, complete, and keyed exactly as a
			-- successful send would have keyed it -- the buyer's answer is the only
			-- thing missing.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)

			local restore = commitThenLoseTheAnswer(harness, "throw")
			harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			local queued = mailbox(harness, RECIPIENT)
			expect(#queued).to.equal(1)
			expect(queued[1].ScribeGift).to.equal(true)
			expect(queued[1].Product).to.equal("CoinsGift")
			expect(queued[1].FromUserId).to.equal(BUYER)
			expect(queued[1].PurchaseId).to.equal(`credit:{queued[1].GiftId}`)

			harness.Cleanup()
		end)

		it("THE ASYMMETRY: the PAID path survives the identical ambiguity, and grants once", function()
			-- WHY THE PURCHASE PATH IS ALREADY SAFE, measured on the same seam, and the
			-- property the credit path has to copy rather than a claim about it.
			--
			-- A paid gift writes its GiftId into `PendingGifts` and makes it DURABLE
			-- before the prompt appears, and Roblox retries a receipt under the same
			-- PurchaseId. So the retry's message is byte-for-byte the first one's:
			-- same purchaseId, same giftId. Two copies reach the recipient's inbox and
			-- `isProcessed` eats the second.
			--
			-- The credit spend has neither half. Its identity is a `Util.guid()` minted
			-- inside the call and persisted nowhere, so there is nothing for a retry to
			-- reuse -- which is exactly why its retry cannot be made dedupe-safe and its
			-- ambiguous arm must not invite one.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 0)
			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)
			expect(#harness.Prompted).to.equal(1) -- a purchase, not a credit spend

			local receipt = {
				PlayerId = BUYER,
				ProductId = COINS_GIFT,
				PurchaseId = "gift-receipt-1",
				CurrencySpent = 99,
				CurrencyType = Enum.CurrencyType.Robux,
				PlaceIdWherePurchased = 0,
			}

			-- The receipt lands, the mailbox write commits, and the answer is lost.
			local restore = commitThenLoseTheAnswer(harness, "throw")
			expect(harness.Data.HandleReceipt(receipt)).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			restore()
			expect(#mailbox(harness, RECIPIENT)).to.equal(1)

			-- Roblox retries it. SAME PurchaseId, and the intent still holds the SAME
			-- GiftId, so a second identical copy is queued.
			expect(harness.Data.HandleReceipt(receipt)).to.equal(GRANTED)
			local queued = mailbox(harness, RECIPIENT)
			expect(#queued).to.equal(2)
			expect(queued[2].PurchaseId).to.equal(queued[1].PurchaseId)
			expect(queued[2].GiftId).to.equal(queued[1].GiftId)

			-- And the recipient is granted exactly once, because the ring recognises the
			-- second copy. This is the whole difference.
			local recipient, recipientEntry, recipientData = harness.Join(RECIPIENT)
			expect(harness.Data.Flush(recipient, { Force = true })).to.equal(true)
			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#ringIds(recipientEntry.LiveData._Scribe.ProcessedPurchaseIds)).to.equal(1)
			expect(#mailbox(harness, RECIPIENT)).to.equal(0)

			harness.Cleanup()
		end)
	end)

	describe("THE DOUBLE GRANT a QueueFull that FOLLOWS a commit produces", function()
		-- THE THIRD ROUTE TO THE SAME DOUBLE GRANT, and the one the `refundable` split
		-- left open. No `durable` gate, and no lost answer either -- this one went
		-- through the arm the split declared PROVABLY clean and kept refunding on.
		-- Closed, and these specs are what hold it closed.
		--
		-- `deliverGift` refunded on `(false, "QueueFull")` because the transform ran, saw
		-- the cap and wrote nothing. True of the attempt that answered. NOT true of the
		-- call: MessageAsync retries UpdateAsync inside itself, and an earlier attempt in
		-- that same loop can have committed the message and lost only its reply. What
		-- came back was then a refusal for a gift already in the recipient's inbox -- so
		-- the credit was handed back, the buyer was told to try again, the retry minted a
		-- fresh `Util.guid()`, and the recipient's ring had never seen the resulting
		-- `credit:{giftId}`. One payment, two grants, through the one delivery answer the
		-- split trusted.
		--
		-- THE FIX WAS NOT "STOP REFUNDING ON QueueFull". An ordinary full inbox with
		-- nothing written must still hand the credit back, and the PROVABLY FAILED spec
		-- below pins exactly that. What was missing was upstream: the store reported the
		-- same pair for a QueueFull that follows a committed attempt as for one that
		-- follows none, and no caller could tell those apart from what it was handed. So
		-- the store grew a third return, `provably_clean` -- true only where nothing can
		-- have been written, which it decides by classifying each failed attempt off its
		-- error rather than by counting them -- and `deliverGift` refunds on that instead
		-- of on the reason string.
		--
		-- Both reproductions below are INVARIANTS in the sibling section's sense. They
		-- assert one grant per payment and say nothing about how the classification
		-- settles, so they hold under any fix that keeps the count right: one that stops
		-- refunding when an attempt may have committed, or one that refunds with a giftId
		-- stable enough for the recipient's ring to catch the retry. What they refuse is
		-- two grants.
		local function committedThenQueueFullSpendThenRetry(harness)
			-- One credit, a recipient who is not on this server, one send whose early
			-- attempt committed and whose answer says QueueFull, and then the buyer does
			-- exactly what that answer invites.
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)

			local restore = commitThenAnswerQueueFull(harness)
			harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			-- The premise, asserted rather than assumed: the gift IS in the inbox, whatever
			-- the buyer was told. This message is going to be delivered.
			expect(#mailbox(harness, RECIPIENT)).to.equal(1)

			-- Not a second gift -- a RETRY of the one just reported undelivered.
			harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
		end

		it(
			"INVARIANT: one credit yields ONE grant when an OFFLINE recipient's committed send answers QueueFull",
			function()
				-- THE REPRODUCTION. The recipient is nowhere on this server, so delivery is a
				-- mailbox commit; the commit lands, the answer refuses, the credit comes back,
				-- and the retry queues a second message under an id the ring cannot recognise.
				-- Both messages are waiting when the recipient finally arrives.
				local harness = makeHarness()
				committedThenQueueFullSpendThenRetry(harness)

				local recipient, recipientEntry, recipientData = harness.Join(RECIPIENT)
				expect(harness.Data.Flush(recipient, { Force = true })).to.equal(true)

				expect(recipientData.Coins.Get()).to.equal(1000)
				expect(#creditIds(liveRing(recipientEntry))).to.equal(1)

				harness.Cleanup()
			end
		)

		it("INVARIANT: and the same for a recipient live on ANOTHER server", function()
			-- The same defect where the recipient is not offline at all but playing
			-- elsewhere, which is the likelier shape and the worse one: the second grant
			-- lands in a LIVE session on B while the buyer on A has been told the gift never
			-- went out. `EntryForUserId` sees only this server, so the route is the same
			-- mailbox commit, and two harnesses over one fake are the only way the hazard
			-- exists at all.
			local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
			local fake = FakeProfileStore.new()
			local serverA = makeHarness(fake)
			local serverB = makeHarness(fake)

			local recipient, recipientEntry, recipientData = serverB.Join(RECIPIENT)
			committedThenQueueFullSpendThenRetry(serverA)

			-- Not applied on B yet: MessageAsync only COMMITS.
			expect(recipientData.Coins.Get()).to.equal(0)
			expect(serverB.Data.Flush(recipient, { Force = true })).to.equal(true)

			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(1)

			serverB.Cleanup()
			serverA.Cleanup()
		end)

		it("the seam is honest: the store's OWN cap answers QueueFull after a commit that stands", function()
			-- The fabricated pair, produced by the fake's real cap logic instead of by the
			-- seam, so a failure above cannot be waved away as the harness inventing a shape
			-- the store never produces. Two sends at a queue capped at one are the two
			-- passes of one MessageAsync loop without the loop: the first commits, the
			-- second re-runs the same transform, finds `#update_list >= MAX_MESSAGE_QUEUE`
			-- and reports the refusal. The committed message is still sitting in the inbox
			-- while it does.
			--
			-- That is the whole defect in two calls: the answer describes the last attempt,
			-- the inbox describes the call, and a caller handed only the answer refunds a
			-- gift it has already delivered.
			local harness = makeHarness()
			local store = harness.Ctx.Persistence.Store
			local key = harness.Ctx.Persistence.KeyFor(RECIPIENT)
			local message = {
				ScribeGift = true,
				GiftId = "seam-gift-1",
				PurchaseId = "credit:seam-gift-1",
				Product = "CoinsGift",
				FromUserId = BUYER,
			}

			harness.Fake.SetConstant("MAX_MESSAGE_QUEUE", 1)
			local firstOk, firstReason = store:MessageAsync(key, message)
			local secondOk, secondReason = store:MessageAsync(key, message)
			harness.Fake.SetConstant("MAX_MESSAGE_QUEUE", 1000)

			expect(firstOk).to.equal(true)
			expect(firstReason).to.equal(nil)
			expect(secondOk).to.equal(false)
			expect(secondReason).to.equal("QueueFull")
			-- The commit stands, and it is a complete, deliverable gift.
			local queued = mailbox(harness, RECIPIENT)
			expect(#queued).to.equal(1)
			expect(queued[1].PurchaseId).to.equal("credit:seam-gift-1")

			harness.Cleanup()
		end)
	end)

	describe("how the two delivery failures settle, now that they are told apart", function()
		-- THE SPLIT ITSELF, read from the buyer's side. `deliverGift` answers a third
		-- value saying whether the delivery PROVABLY did not happen, and only that
		-- answer buys a refund. These pin both halves, because a later change that
		-- collapses them is a regression whichever way it collapses: refund everything
		-- and the double grant is back; refund nothing and a jammed inbox quietly eats
		-- paid credits.
		it("PROVABLY FAILED: the credit comes back and the buyer is told to try again", function()
			-- The recipient's inbox is at its cap, so MessageAsync ran its transform,
			-- declined to write and said so. Nothing was queued, nothing can arrive
			-- later, and a retry is honest advice. Unchanged by the split, on purpose.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)

			local restore = jamInbox(harness)
			local ok, reason = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			expect(ok).to.equal(false)
			expect(reason).to.equal("could not deliver gift; try again later")
			expect(liveCredits(harness, buyer, "CoinsGift")).to.equal(1)
			expect(#mailbox(harness, RECIPIENT)).to.equal(0)

			harness.Cleanup()
		end)

		it("UNCONFIRMED: the credit stays spent and the buyer is told NOT to send it again", function()
			-- The other half. The credit is deliberately not handed back, and the
			-- refusal string is the visible difference: a message that invites a retry
			-- here is part of the defect, because the retry is what grants twice.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)

			local restore = commitThenLoseTheAnswer(harness, "throw")
			local ok, reason = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			expect(ok).to.equal(false)
			expect(reason).to.equal("gift delivery could not be confirmed; do not send it again")
			expect(reason).to.equal(Scribe.GiftReason.DeliveryUnconfirmed)
			expect(liveCredits(harness, buyer, "CoinsGift")).to.equal(0)
			-- Spent on disk too, not merely in memory: the reservation was made durable
			-- before delivery was attempted and nothing has put it back.
			expect(storedCredits(harness, BUYER, "CoinsGift")).to.equal(nil)

			harness.Cleanup()
		end)

		it("UNCONFIRMED settles identically when MessageAsync gives up instead of throwing", function()
			-- No error to read, just a bare `false` from a retry loop that ended at
			-- BindToClose. Both shapes are "we cannot tell", so both must answer the
			-- same -- a fix that keyed off the error string would split them.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)

			local restore = commitThenLoseTheAnswer(harness, "giveup")
			local ok, reason = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			expect(ok).to.equal(false)
			expect(reason).to.equal("gift delivery could not be confirmed; do not send it again")
			expect(liveCredits(harness, buyer, "CoinsGift")).to.equal(0)

			harness.Cleanup()
		end)

		it("says so loudly: exactly one GIFT_CREDIT_UNCONFIRMED, naming who to compensate", function()
			-- A held credit is a player out real value with no retry that would help, so
			-- the incident has to be reconcilable from the log alone: buyer, product and
			-- recipient. Counted as well, so a studio can alert on it rather than
			-- discovering it in a support ticket.
			--
			-- Exactly one, and the delivery report beside it exactly one too: deliverGift
			-- already reported this fault, and a credit arm that reported it AGAIN would
			-- turn one incident into two log lines an operator has to correlate.
			--
			-- ITS OWN RECIPIENT ID, and that is load-bearing rather than tidiness.
			-- Health.ReportFailure folds repeats of the same `subsystem|key` inside a
			-- retry cooldown and the Health singleton outlives every harness in the run,
			-- so a recipient another spec in this file has already failed a delivery to
			-- would have GIFT_DELIVERY_RETRY silently absorbed -- and this spec would
			-- then pass while asserting the wrong thing. Measured: with RECIPIENT it
			-- reads GIFT_CREDIT_UNCONFIRMED=1 alone.
			local FRESH_RECIPIENT = 95181
			local seen, entries = {}, {}
			local unsubscribe = Scribe.AddLogSink(function(logEntry)
				seen[logEntry.Code] = (seen[logEntry.Code] or 0) + 1
				if logEntry.Code == "GIFT_CREDIT_UNCONFIRMED" then
					table.insert(entries, logEntry)
				end
			end)

			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			-- Metrics are process-global too, so this is read as a DELTA: the specs above
			-- have already counted their own unconfirmed sends.
			local before = tonumber(Scribe.GetMetrics().GiftCreditsUnconfirmed) or 0
			local restore = commitThenLoseTheAnswer(harness, "throw")
			harness.Data.PromptGift(buyer, "CoinsGift", FRESH_RECIPIENT)
			restore()

			task.wait()
			unsubscribe()

			local gifty = {}
			for code, count in seen do
				if string.sub(code, 1, 5) == "GIFT_" then
					table.insert(gifty, `{code}={count}`)
				end
			end
			table.sort(gifty)
			expect(table.concat(gifty, " ")).to.equal("GIFT_CREDIT_UNCONFIRMED=1 GIFT_DELIVERY_RETRY=1")

			expect(#entries).to.equal(1)
			expect(entries[1].Level).to.equal("Warn")
			expect(entries[1].Category).to.equal("Gifting")
			expect(entries[1].Context.Product).to.equal("CoinsGift")
			expect(entries[1].Context.RecipientId).to.equal(FRESH_RECIPIENT)
			expect(entries[1].Context.Player.UserId).to.equal(BUYER)
			expect(entries[1].Context.GiftId).to.be.ok()
			expect((tonumber(Scribe.GetMetrics().GiftCreditsUnconfirmed) or 0) - before).to.equal(1)

			harness.Cleanup()
		end)

		it("charges the health window ONCE for the incident, not twice", function()
			-- The window is shared with every Robux receipt on this server: at three
			-- distinct failures it degrades and at six it refuses receipts outright. An
			-- arm that reported alongside deliverGift instead of logging beside it would
			-- reach both on half the traffic they are tuned for.
			--
			-- Read as a delta on HealthFailures, which counts every REPORT including the
			-- ones the fold absorbs -- so it answers "how many times did we report this"
			-- rather than "did the status happen to move", and cannot be satisfied by a
			-- cooldown that swallowed the second report on this particular ordering.
			local FRESH_RECIPIENT = 95182
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)

			local before = tonumber(Scribe.GetMetrics().HealthFailures) or 0
			local restore = commitThenLoseTheAnswer(harness, "throw")
			harness.Data.PromptGift(buyer, "CoinsGift", FRESH_RECIPIENT)
			restore()

			expect((tonumber(Scribe.GetMetrics().HealthFailures) or 0) - before).to.equal(1)

			harness.Cleanup()
		end)
	end)

	-- HOW IT SETTLES TODAY --------------------------------------------------------
	--
	-- The two specs below record the CURRENT settlement rather than a permanent
	-- contract, and they are the only two in this file a deliberate F4 fix is
	-- expected to change. They exist so the improvement can be MEASURED instead of
	-- argued: whoever moves the gate has to be able to show which line moved, and to
	-- what. Neither may be edited to make a fix go green -- a fix that changes them
	-- rewrites them ON PURPOSE, with every invariant above still passing.
	describe("how the `applied` gate settles today", function()
		it("consumes the credit and does not hand it back when the save does not confirm", function()
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			local _, recipientEntry, recipientData = harness.Join(RECIPIENT)

			local restore = saveNeverConfirmsFor(harness, RECIPIENT)
			local ok, reason = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			expect(ok).to.equal(true)
			expect(reason).to.equal(nil)
			expect(liveCredits(harness, buyer, "CoinsGift")).to.equal(0)
			expect(recipientData.Coins.Get()).to.equal(1000)
			expect(#creditIds(liveRing(recipientEntry))).to.equal(1)

			harness.Cleanup()
		end)

		it("THE ACCEPTED COST: the non-durable grant is in memory only", function()
			-- The price the `applied` gate pays. After a delivery whose confirming
			-- save never landed, the recipient's STORED profile carries neither the
			-- coins nor the marker, while the buyer's stored credit is already spent:
			-- a recipient crash here loses the gift.
			--
			-- Recorded as the current cost, not as desirable. A fix that keeps ONE
			-- grant and makes this line durable is strictly better; a fix that trades
			-- it for the double grant above is strictly worse.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, "CoinsGift", 1)
			local recipient, _, recipientData = harness.Join(RECIPIENT)
			expect(harness.Data.Flush(recipient, { Force = true })).to.equal(true)

			local restore = saveNeverConfirmsFor(harness, RECIPIENT)
			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)
			restore()

			expect(recipientData.Coins.Get()).to.equal(1000) -- memory
			local stored = storedProfile(harness, RECIPIENT)
			expect(stored.Coins).to.equal(0) -- disk
			expect(#creditIds(ringIds(stored._Scribe.ProcessedPurchaseIds))).to.equal(0)
			-- The buyer's side of the trade is already permanent.
			expect(storedCredits(harness, BUYER, "CoinsGift")).to.equal(nil)

			harness.Cleanup()
		end)
	end)

	describe("the receipt path, for comparison", function()
		it("grants once across a retry because the purchaseId is fixed", function()
			-- The property the credit spend lacks, in the path that has it. Roblox
			-- retries a receipt under the SAME PurchaseId, so the ring catches the
			-- second call. Named here because it is the model any giftId fix has to
			-- copy, not because the receipt path is under test.
			local harness = makeHarness()
			local _, entry, data = harness.Join(BUYER)

			local info = {
				PlayerId = entry.UserId,
				ProductId = COINS_GIFT,
				PurchaseId = "retried-1",
				CurrencySpent = 99,
				CurrencyType = Enum.CurrencyType.Robux,
				PlaceIdWherePurchased = 0,
			}
			expect(harness.Data.HandleReceipt(info)).to.equal(GRANTED)
			expect(harness.Data.HandleReceipt(info)).to.equal(GRANTED)

			expect(data.Coins.Get()).to.equal(1000)

			harness.Cleanup()
		end)
	end)
end
