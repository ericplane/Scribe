--!nonstrict
-- A gift credit is PAID FOR. Losing one is losing money.
--
-- The credit path reserves durably before delivering: spend the credit, save, then
-- deliver. If delivery fails, `refundCredit` puts it back and PromptGift refuses
-- with "could not deliver gift; try again later" -- the documented shape, and the
-- reason the reservation is safe to make at all.
--
-- But `refundCredit` writes through the buyer's accessor tree, and both of the
-- steps between the spend and the refund YIELD: the durability await, and the
-- delivery itself (a MessageAsync round trip for an offline recipient). A buyer
-- who leaves in either window leaves a dead tree behind, so the refund RAISES --
-- and the credit is simply gone. One payment, zero grants, and a raise where the
-- caller was promised a refusal.
--
-- The credit lives in the buyer's persisted `_Scribe.GiftCredits`, so a departed
-- buyer still HAS a place to be refunded to: `ctx.Persistence.UpdateOffline`, the
-- route this file already uses everywhere else for a player who is not here.
return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local BUYER_KEY_PREFIX = "Default/PLAYER_"

	local function makeHarness()
		local prompted = 0
		local harness = TestCtx.make({
			Options = {
				Products = {
					VIPGift = { Id = 4242, Category = "Gamepass", Grants = "VIP" },
				},
				GiftCooldown = 0,
				PromptProductPurchase = function()
					prompted += 1
				end,
			},
		})
		return harness, function()
			return prompted
		end
	end

	--- Join a buyer holding one unassigned credit, durably.
	local function buyerWithCredit(harness, userId)
		local buyer, entry = harness.Join(userId)
		entry.Tree.Reserved.GiftCredits.VIPGift.Set(1)
		expect(harness.Data.Flush(buyer, { Force = true })).to.equal(true)
		return buyer, entry
	end

	local function persistedCredits(harness, userId)
		local stored = harness.Fake.Persisted[BUYER_KEY_PREFIX .. userId]
		if not stored or not stored._Scribe or not stored._Scribe.GiftCredits then
			return nil
		end
		return stored._Scribe.GiftCredits.VIPGift
	end

	--- Make every MessageAsync report a full queue, which is the delivery failure
	--- deliverGift handles by returning `applied = false` -- the arm that refunds.
	---
	--- THE THIRD RETURN IS WHAT MAKES IT THE REFUNDING ARM. MessageAsync answers
	--- `provably_clean` as well as the boolean and the reason, true only where nothing
	--- can have been written, and `deliverGift` refunds on that value alone -- a
	--- QueueFull that follows a commit inside the same call is NOT clean and must not
	--- hand a paid credit back. Every seam in this file models the ordinary shape: a
	--- full inbox found on the FIRST attempt, transform run, write aborted in band,
	--- nothing queued. So each one says `true`, exactly as the store does. A seam that
	--- stayed silent would model the ambiguous case instead and quietly turn this whole
	--- file into an assertion that a paid credit is eaten.
	local function jamTheRecipientInbox(harness)
		local store = harness.Ctx.Persistence.Store
		local real = store.MessageAsync
		store.MessageAsync = function()
			return false, "QueueFull", true
		end
		return function()
			store.MessageAsync = real
		end
	end

	describe("a gift credit when delivery fails", function()
		it("comes back to a buyer who is still here", function()
			-- THE CONTROL, and the behaviour that must not move: the whole refund path,
			-- with the buyer present. Refusal, reason, and the credit restored live.
			local harness, promptCount = makeHarness()
			local buyer, entry = buyerWithCredit(harness, 97030)
			local restore = jamTheRecipientInbox(harness)

			local ok, reason = harness.Data.PromptGift(buyer, "VIPGift", 97031)
			restore()

			expect(ok).to.equal(false)
			expect(reason).to.equal("could not deliver gift; try again later")
			expect(entry.Tree.Reserved.GiftCredits.VIPGift.Get()).to.equal(1)
			-- No purchase was ever prompted: this arm spends a credit instead.
			expect(promptCount()).to.equal(0)

			harness.Cleanup()
		end)

		it("is spent, once, when delivery SUCCEEDS", function()
			-- The other control. Without it, a fix that refunded unconditionally would
			-- mint free gifts and still pass everything below.
			local harness = makeHarness()
			local buyer, entry = buyerWithCredit(harness, 97032)

			local ok, reason = harness.Data.PromptGift(buyer, "VIPGift", 97033)

			expect(reason).to.equal(nil)
			expect(ok).to.equal(true)
			expect(entry.Tree.Reserved.GiftCredits.VIPGift.Get()).to.equal(nil)

			harness.Cleanup()
		end)

		it("REFUSES rather than raising when the buyer leaves during a failing delivery", function()
			-- The defect, first half: the answer. The refund runs on a dead tree.
			local harness = makeHarness()
			local buyer = buyerWithCredit(harness, 97034)
			local restore = jamTheRecipientInbox(harness)

			-- Leave from inside the delivery attempt, which is where a real departure
			-- lands: after the credit has been spent and saved, before the refund.
			local store = harness.Ctx.Persistence.Store
			store.MessageAsync = function()
				harness.Leave(buyer)
				task.wait()
				return false, "QueueFull", true
			end

			local ok, reason, raised
			local pcallOk, err = pcall(function()
				ok, reason = harness.Data.PromptGift(buyer, "VIPGift", 97035)
			end)
			if not pcallOk then
				raised = tostring(err)
			end
			restore()

			expect(raised).to.equal(nil)
			expect(ok).to.equal(false)
			expect(type(reason)).to.equal("string")

			harness.Cleanup()
		end)

		it("puts the paid credit back on the departed buyer's key", function()
			-- The defect, second half, and the one that is actually money: not merely
			-- that the call answered politely, but that the credit still exists. Read
			-- from the datastore, because the buyer's tree is gone -- persisted state
			-- is the only place a refund can now land, and the only place a rejoin
			-- will look.
			local harness = makeHarness()
			local buyer = buyerWithCredit(harness, 97036)
			expect(persistedCredits(harness, 97036)).to.equal(1)

			local store = harness.Ctx.Persistence.Store
			local real = store.MessageAsync
			store.MessageAsync = function()
				harness.Leave(buyer)
				task.wait()
				return false, "QueueFull", true
			end

			pcall(function()
				harness.Data.PromptGift(buyer, "VIPGift", 97037)
			end)
			store.MessageAsync = real

			-- One payment, zero grants -- so the credit must still be spendable.
			expect(persistedCredits(harness, 97036)).to.equal(1)

			harness.Cleanup()
		end)

		it("says so loudly, without raising, when even the offline refund fails", function()
			-- The last branch, and it is the one nobody would ever reach by hand: the
			-- buyer is gone AND their stored profile cannot be written. The credit is
			-- genuinely lost at that point, so the only thing left to get right is that
			-- it is lost NOISILY and the caller still gets its documented refusal
			-- rather than a raise.
			local harness = makeHarness()
			local buyer = buyerWithCredit(harness, 97040)

			local realUpdate = harness.Ctx.Persistence.UpdateOffline
			harness.Ctx.Persistence.UpdateOffline = function()
				return false, "mock offline write failure"
			end
			local store = harness.Ctx.Persistence.Store
			local realMessage = store.MessageAsync
			store.MessageAsync = function()
				harness.Leave(buyer)
				task.wait()
				return false, "QueueFull", true
			end

			local ok, reason, raised
			local pcallOk, err = pcall(function()
				ok, reason = harness.Data.PromptGift(buyer, "VIPGift", 97041)
			end)
			if not pcallOk then
				raised = tostring(err)
			end
			store.MessageAsync = realMessage
			harness.Ctx.Persistence.UpdateOffline = realUpdate

			expect(raised).to.equal(nil)
			expect(ok).to.equal(false)
			expect(type(reason)).to.equal("string")

			harness.Cleanup()
		end)

		it("does not mint a credit for a departed buyer whose delivery SUCCEEDED", function()
			-- The mirror, and the reason the refund cannot simply always run offline: a
			-- buyer who leaves during a delivery that lands has spent their credit, and
			-- putting it back would hand them a free gift out of a successful one.
			local harness = makeHarness()
			local buyer = buyerWithCredit(harness, 97038)
			expect(persistedCredits(harness, 97038)).to.equal(1)

			local store = harness.Ctx.Persistence.Store
			local real = store.MessageAsync
			store.MessageAsync = function(selfStore, key, message)
				harness.Leave(buyer)
				task.wait()
				return real(selfStore, key, message)
			end

			pcall(function()
				harness.Data.PromptGift(buyer, "VIPGift", 97039)
			end)
			store.MessageAsync = real

			local credits = persistedCredits(harness, 97038)
			expect(credits == nil or credits == 0).to.equal(true)

			harness.Cleanup()
		end)
	end)
end
