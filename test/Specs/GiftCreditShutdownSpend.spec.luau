--!nonstrict
-- CHARACTERISATION. A gift-credit spend that begins after the STORE has begun
-- closing, and the paid credit it currently eats.
--
-- THE DEFECT, and it was a REGRESSION rather than an old hole. `deliverGift` grew
-- a third return, `refundable`, so a spent gift credit is handed back only where
-- delivery provably did not happen. The gate was right. One of the inputs to it was
-- not: the comment then guarding `deliverGift`'s Failure.Report arm asserted that a
-- bare `false` from `MessageAsync` always means the retry loop ended AFTER attempts
-- that could each have committed. That is true of the loop's give-up whenever any
-- of those attempts could have written. It was FALSE of the entry guard, which read
--
--     if ProfileStore.IsClosing == true then
--         return false
--     end
--
-- and which sits above `WaitForStoreReady` and above the loop. Zero attempts, zero
-- UpdateAsync calls, nothing written, and no way to have written anything. Before
-- the third return existed this arm refunded, correctly, because everything that
-- was not a success refunded. Under the split it landed on the unconfirmed exit:
-- the buyer's paid credit stayed spent, and they were told not to send the gift
-- again, for a delivery that was never attempted.
--
-- FIXED AT THE STORE, not at the call site. `MessageAsync` now answers a third
-- value, `provably_clean` -- true only where nothing can have been written -- and
-- the guard says `return false, nil, true` (ProfileStore.luau:2450-2457) while the
-- give-up says `return false, nil, provably_clean` (:2639-2645), an aggregate the
-- loop builds by classifying each failed attempt off its error. `deliverGift`
-- refunds on that value rather than on the shape of the first two. These specs are
-- what hold it there; GiftCreditCostInversion.spec holds the classification itself.
--
-- THE WINDOW IS REAL AND IT IS NOT NARROW. `Persistence.Shutdown` sets
-- `ProfileStore.IsClosing` at its very top -- before the log line, before the
-- drain -- and then works through the sessions one at a time inside a 25-second
-- budget. Every entry it has not reached yet is still `Ready`, so a PromptGift
-- already in flight, or one a remote delivers a moment later, runs its whole
-- credit branch against a store that refuses at the door. ProfileStore's own
-- BindToClose sets the same flag in mock mode with nothing else attached to it.
--
-- WHAT IS PINNED HERE, and the pair is the point:
--   * the SHUTDOWN arm must refund -- nothing was attempted, so nothing can have
--     been delivered, so the credit belongs to the buyer; and
--   * the FULL INBOX arm must STILL refund -- the ordinary case, provably clean
--     for a different reason (the transform ran, saw the cap, aborted the write
--     in band, and said so), and the one a fix aimed at the first could break.
-- D2 exists because a fix in one direction opened a defect in the other. The
-- adjacent arm is here so the next fix cannot do it again unseen.
--
-- WHAT IS NOT PINNED HERE. The ambiguous send -- a commit whose answer was lost --
-- must NOT refund, and stays where it is measured, in GiftCreditSpendContract.spec.
-- The two files are opposite sides of one distinction the store used to collapse,
-- and anything that turns this one green by refunding on every bare `false` turns
-- that one red. That is still the trap; it is why the fix went into the store.
--
-- THE SEAM, and why it is in the FAKE rather than in this file. Every other
-- MessageAsync failure in the gift specs is injected by replacing the method for
-- the length of one call, which is honest when the shape being modelled is a
-- DataStore fault the store has no opinion about. This one is a branch the store
-- OWNS: `FakeProfileStore` already models `IsClosing` for StartSessionAsync and
-- GetAsync, faithfully and for the same reason (a fork branch CI could not
-- otherwise reach), and MessageAsync was simply missing from that set. Adding it
-- there rather than stubbing here means the entry guard's ordering is modelled --
-- it answers before the mailbox is even looked up, ahead of FailMessages -- and it
-- meant that when the fork learned to say "never attempted" there was exactly one
-- place in the harness that had to learn the same word, which is how it happened.
-- A per-spec stub returning a bare `false` would have reproduced the RETURN VALUE
-- while asserting nothing about where it comes from, which is the mistake the
-- defect itself is made of.
--
-- STACKABLE ON PURPOSE, as in GiftCreditSpendContract.spec: the gifted product
-- grants coins through a `Grant` callback and declares no `Grants` perk, so a
-- second grant is visible and the duplicate-recipient guard (which would issue an
-- offline GetAsync the closing store refuses) is off the path.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local COINS_GIFT = 773

	local BUYER = 95301
	local RECIPIENT = 95302

	local function makeHarness()
		local prompted = {}
		local harness = TestCtx.make({
			Options = {
				Products = {
					CoinsGift = {
						Id = COINS_GIFT,
						Category = "Currency",
						Grant = function(data)
							data.Coins.Increment(1000)
						end,
					},
				},
				GiftCooldown = 0,
				PromptProductPurchase = function(player, productId)
					table.insert(prompted, { Player = player, ProductId = productId })
				end,
			},
		})
		harness.Prompted = prompted
		return harness
	end

	--- A buyer holding `count` unassigned credits, DURABLY. The spend's discipline
	--- is "reserve on disk, then deliver", so a credit that was never on disk cannot
	--- show whether the ordering held.
	local function buyerWith(harness, userId: number, count: number)
		local buyer = harness.Join(userId)
		harness.Ctx.Persistence.EntryFor(buyer).Tree.Reserved.GiftCredits.CoinsGift.Set(count)
		expect(harness.Data.Flush(buyer, { Force = true })).to.equal(true)
		return buyer
	end

	local function liveCredits(harness, buyer): number
		return tonumber(harness.Data.GetGiftCredits(buyer).CoinsGift) or 0
	end

	local function storedCredits(harness, userId: number): number
		local stored = harness.Fake.Persisted[`Default/PLAYER_{userId}`]
		local scribe = stored and stored._Scribe
		local credits = scribe and scribe.GiftCredits
		return tonumber(credits and credits.CoinsGift) or 0
	end

	local function mailbox(harness, userId: number)
		return harness.Fake.Mailboxes[`Default/{harness.Ctx.Persistence.KeyFor(userId)}`] or {}
	end

	--- The store's BindToClose has fired and Scribe's drain has not reached this
	--- buyer yet. `Fake.BeginClose` is the fake's spelling of `ProfileStore.BeginClose`,
	--- which is the FIRST thing `Persistence.Shutdown` does; driving the flag directly
	--- rather than calling Shutdown is what holds the window open deterministically,
	--- because Shutdown goes on to end the very session the spend needs. Shutdown.spec
	--- reads the same flag as the store half of the drain.
	local function storeBeganClosing(harness)
		harness.Fake.BeginClose()
		return function()
			-- Teardown only: Cleanup ends sessions, and it should not have to do it
			-- through a closing store.
			harness.Fake.IsClosing = false
		end
	end

	describe("a gift-credit spend that starts after the store began closing", function()
		it("REGRESSION: the entry guard attempted nothing, so the paid credit must come back", function()
			-- THE REPRODUCTION. One credit, a recipient who is not on this server, and
			-- a store whose MessageAsync refuses at the door.
			--
			-- The premise is asserted below rather than assumed: the recipient's inbox
			-- is EMPTY afterwards. Nothing was queued, nothing can arrive later, and no
			-- retry of this spend can collide with a gift that already exists -- which
			-- is the entire condition the refund gate asks about.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, 1)

			local restore = storeBeganClosing(harness)
			local ok, reason = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			expect(ok).to.equal(false)
			-- Past the reservation, not refused at it: the buyer's own save still
			-- worked, so this is a DELIVERY answer and the credit really was spent.
			expect(string.find(tostring(reason), "reserve") ~= nil).to.equal(false)
			-- Nothing was written. Provably, and not as a matter of timing.
			expect(#mailbox(harness, RECIPIENT)).to.equal(0)
			expect(#harness.Prompted).to.equal(0) -- a credit spend never charges Robux

			-- The credit is the buyer's. It was paid for once, it bought nothing, and
			-- no gift exists anywhere that a re-spend could duplicate.
			expect(liveCredits(harness, buyer)).to.equal(1)

			-- ... and not as a live-only fiction: it survives to disk.
			expect(harness.Data.Flush(buyer, { Force = true })).to.equal(true)
			expect(storedCredits(harness, BUYER)).to.equal(1)

			harness.Cleanup()
		end)

		it("REGRESSION: and the buyer is told to try again, not warned off a gift that never went out", function()
			-- The other half of the cost, and the half a player actually reads. The
			-- unconfirmed exit answers "do not send it again" and counts a
			-- GiftCreditsUnconfirmed, which is an operator's signal to reconcile a
			-- possible half-delivered gift BY HAND. Spending that signal on a send
			-- that never left the building buries the real ones.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, 1)
			local unconfirmedBefore = tonumber(Scribe.GetMetrics().GiftCreditsUnconfirmed) or 0

			local restore = storeBeganClosing(harness)
			local _ok, reason = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			restore()

			expect(string.find(tostring(reason), "do not send it again") ~= nil).to.equal(false)
			expect(string.find(tostring(reason), "try again") ~= nil).to.equal(true)
			expect((tonumber(Scribe.GetMetrics().GiftCreditsUnconfirmed) or 0) - unconfirmedBefore).to.equal(0)

			harness.Cleanup()
		end)

		it("the seam is honest: the guard answers before the mailbox is touched", function()
			-- The premise on its own, straight off the store, so a failure above cannot
			-- be waved away as the harness lying. A send to a key with an EMPTY inbox
			-- and acres of room refuses anyway, and leaves that inbox empty -- there is
			-- no cap involved, no fault, and no attempt.
			local harness = makeHarness()
			local store = harness.Ctx.Persistence.Store
			local key = harness.Ctx.Persistence.KeyFor(RECIPIENT)

			local restore = storeBeganClosing(harness)
			local delivered, why = store:MessageAsync(key, { ScribeGift = true })
			restore()

			expect(delivered).to.equal(false)
			expect(why).to.equal(nil)
			expect(#mailbox(harness, RECIPIENT)).to.equal(0)

			-- And the same store, one instant later, accepts it.
			expect(store:MessageAsync(key, { ScribeGift = true })).to.equal(true)
			expect(#mailbox(harness, RECIPIENT)).to.equal(1)

			harness.Cleanup()
		end)

		it("THE ROOT CAUSE, now fixed: the two exits agree on the first two values and DIFFER on the third", function()
			-- WHAT THE CALLER IS HANDED, stated as an assertion instead of as prose.
			-- `deliverGift` sees exactly what is compared here.
			--
			-- This spec used to assert the COLLAPSE: never-attempted and
			-- gave-up-after-attempts answered the same two values, while the correct
			-- treatments are opposite -- the first must refund, the second must not --
			-- and its own comment said to rewrite it into the distinction once the store
			-- could express one. This is that rewrite. It is deliberately still ONE spec
			-- comparing the SAME two exits, so the pair cannot drift apart unnoticed.
			--
			-- The first two values are asserted EQUAL on purpose. That is not the defect;
			-- it is why the fix had to be a third return rather than a new reason string
			-- on the second. Every caller that destructures two values sees exactly what
			-- it saw before, and only a caller that asks the new question gets a new
			-- answer. The two REGRESSION specs above are what that answer buys.
			local harness = makeHarness()
			local store = harness.Ctx.Persistence.Store
			local key = harness.Ctx.Persistence.KeyFor(RECIPIENT)

			local restore = storeBeganClosing(harness)
			local guardOk, guardWhy, guardClean = store:MessageAsync(key, { ScribeGift = true })
			restore()

			-- The give-up exit: the retry loop ran, any attempt inside it could have
			-- committed, and it ends with a bare `false` and nothing else.
			harness.Fake.FailMessages = true
			local gaveUpOk, gaveUpWhy, gaveUpClean = store:MessageAsync(key, { ScribeGift = true })
			harness.Fake.FailMessages = false

			-- Unchanged for every existing caller ...
			expect(`{tostring(guardOk)}/{tostring(guardWhy)}`).to.equal(`{tostring(gaveUpOk)}/{tostring(gaveUpWhy)}`)
			-- ... and told apart for the one that asks.
			expect(guardClean).to.equal(true)
			expect(gaveUpClean == true).to.equal(false)

			harness.Cleanup()
		end)
	end)

	describe("the adjacent arm the fix must not break", function()
		it("an ordinary full inbox still refunds the credit", function()
			-- THE COMMON CASE. A recipient whose queue is at its cap is a property of
			-- their profile, not a fault: MessageAsync ran its transform, saw the cap,
			-- set AbortWrite and said `QueueFull`, so the UpdateAsync it sat inside
			-- committed nothing. Provably clean by a DIFFERENT route from the entry
			-- guard, and refundable for the same reason.
			--
			-- Jammed through the real cap (`MAX_MESSAGE_QUEUE`, via the SetConstant
			-- seam the store itself uses) rather than by stubbing the method, so the
			-- refusal comes out of the fake's own queue logic.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, 1)

			harness.Fake.SetConstant("MAX_MESSAGE_QUEUE", 0)
			local ok, reason = harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
			harness.Fake.SetConstant("MAX_MESSAGE_QUEUE", 1000)

			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "try again") ~= nil).to.equal(true)
			expect(#mailbox(harness, RECIPIENT)).to.equal(0)
			expect(liveCredits(harness, buyer)).to.equal(1)

			expect(harness.Data.Flush(buyer, { Force = true })).to.equal(true)
			expect(storedCredits(harness, BUYER)).to.equal(1)

			harness.Cleanup()
		end)

		it("and a working send still spends it exactly once", function()
			-- The counterpart the two refunds are only meaningful against. Without it
			-- a fix could pass both by refunding unconditionally.
			local harness = makeHarness()
			local buyer = buyerWith(harness, BUYER, 1)

			expect(harness.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)).to.equal(true)

			expect(liveCredits(harness, buyer)).to.equal(0)
			expect(#mailbox(harness, RECIPIENT)).to.equal(1)
			expect(#harness.Prompted).to.equal(0)

			harness.Cleanup()
		end)
	end)
end
