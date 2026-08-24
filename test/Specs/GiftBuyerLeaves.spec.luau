--!nonstrict
-- PromptGift is documented to REFUSE, never to raise.
--
-- Its whole contract is `(boolean, string?)`: every refusal in it returns a reason
-- the caller shows the player, and a game wires it straight to a remote handler.
-- But the flow yields -- `recipientAlreadyOwns` issues a full-profile `GetAsync`
-- for an offline recipient -- and every step after that yield writes through the
-- buyer's accessor tree. A buyer who leaves during the yield leaves a DEAD tree
-- behind, and an accessor write on a dead tree raises.
--
-- So the one path the contract exists for -- "something went wrong, tell the
-- player" -- was the path that skipped the caller's refusal handling entirely and
-- surfaced as a script error inside their remote handler.
--
-- No money moves on either arm and no state is corrupted: this is about the
-- ANSWER, and about the caller's error handling never running.
return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- Returns the harness and a reader for how many purchase prompts were raised.
	--- The counter is installed at BUILD time: Options is captured when the bundle
	--- is constructed, so reassigning the field afterwards changes nothing.
	local function makeHarness()
		local prompted = 0
		local harness = TestCtx.make({
			Options = {
				Products = {
					GiftVIP = { Id = 4242, Category = "Gamepass", Grants = "VIP" },
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

	describe("PromptGift when the buyer leaves mid-flight", function()
		it("refuses cleanly when the buyer was never loaded", function()
			-- THE CONTROL for the contract itself: the documented refusal shape, on the
			-- one arm that has always worked. Without it, a fix that made every arm
			-- return `false, "buyer data not loaded"` would look like a success.
			local harness = makeHarness()
			local buyer = harness.Join(97020)
			harness.Leave(buyer)

			local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 97021)
			expect(ok).to.equal(false)
			expect(type(reason)).to.equal("string")

			harness.Cleanup()
		end)

		it("prompts normally when the buyer stays", function()
			-- THE OTHER CONTROL, and the one that matters most: the happy path has to
			-- keep reaching the prompt. A re-check inserted in the wrong place would
			-- turn every ordinary gift into a refusal and this is what catches it.
			local harness, promptCount = makeHarness()
			local buyer = harness.Join(97022)

			local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 97023)
			expect(reason).to.equal(nil)
			expect(ok).to.equal(true)
			expect(promptCount()).to.equal(1)

			harness.Cleanup()
		end)

		it("REFUSES rather than raising when the buyer leaves inside the ownership check", function()
			-- The defect. `recipientAlreadyOwns` takes its offline branch for a
			-- recipient who never joined, and `ctx.Persistence.GetOffline` is indexed
			-- off the ctx table at call time -- so wrapping it puts this spec exactly
			-- inside the yield, where a real player's departure lands.
			local harness = makeHarness()
			local buyer = harness.Join(97024)

			local realGetOffline = harness.Ctx.Persistence.GetOffline
			local armed = true
			harness.Ctx.Persistence.GetOffline = function(userId)
				if armed then
					armed = false
					task.wait()
					harness.Leave(buyer)
					task.wait()
				end
				return realGetOffline(userId)
			end

			local raised, ok, reason
			local pcallOk, err = pcall(function()
				ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 97025)
			end)
			if not pcallOk then
				raised = tostring(err)
			end
			harness.Ctx.Persistence.GetOffline = realGetOffline

			-- Stated as the outcome the caller sees, not as the internal state.
			expect(raised).to.equal(nil)
			expect(ok).to.equal(false)
			expect(type(reason)).to.equal("string")

			harness.Cleanup()
		end)

		it("takes no money and leaves no gift record behind when it refuses that way", function()
			-- The refusal has to be a real refusal, not a raise caught and relabelled:
			-- nothing prompted, and no pending intent left in the buyer's ledger for a
			-- receipt to settle against later.
			local harness, promptCount = makeHarness()
			local buyer = harness.Join(97026)

			local realGetOffline = harness.Ctx.Persistence.GetOffline
			local armed = true
			harness.Ctx.Persistence.GetOffline = function(userId)
				if armed then
					armed = false
					task.wait()
					harness.Leave(buyer)
					task.wait()
				end
				return realGetOffline(userId)
			end

			local ok = select(
				1,
				pcall(function()
					return harness.Data.PromptGift(buyer, "GiftVIP", 97027)
				end)
			)
			harness.Ctx.Persistence.GetOffline = realGetOffline

			expect(ok).to.equal(true) -- did not raise
			expect(promptCount()).to.equal(0)
			local persisted = harness.Fake.Persisted["Default/PLAYER_97026"]
			if persisted and persisted._Scribe then
				local pending = persisted._Scribe.PendingGifts
				if pending then
					local count = 0
					for _ in pending do
						count += 1
					end
					expect(count).to.equal(0)
				end
			end

			harness.Cleanup()
		end)
	end)
end
