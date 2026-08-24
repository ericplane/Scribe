--!nonstrict
-- The Dirty restore on a FAILED save (Persistence, ProfileStore.OnError handler).
--
-- Dirty is cleared when a save's payload is SNAPSHOTTED, not when it lands. A save
-- that then fails has therefore erased the only record that the live tree differs
-- from storage, and the OnError handler's one job is to put it back:
--
--     entry.SaveInfo.Dirty = entry.DirtyAtSaveStart or entry.SaveInfo.Dirty
--
-- WHY THIS FILE EXISTS SEPARATELY FROM FlushDurability. That line is invisible
-- through Flush, and measurably so: deleting it leaves the whole suite green,
-- because isDurable ALSO requires `LastResult == "Ok"` and the same handler sets
-- "Fail" fifteen lines above the restore. Measured as a compound mutation --
-- delete the restore alone: 1442 passed / 0 failed. Delete the `LastResult == "Ok"`
-- clause alone: 11 failures, none of them "does not answer true off a FAILED save".
-- Delete both: those same 11 plus that test, which is the delta that proves the
-- restore is masked rather than dead.
--
-- The consumer that the LastResult clause CANNOT cover for is Monetization's
-- duplicate-receipt acknowledgement, which reads Dirty and SavesInFlight and has no
-- LastResult clause at all. So the flag is asserted here directly, and then through
-- the money path where being wrong costs a player's Robux.

-- WHAT THIS FILE COVERS, AND WHERE THE REST LIVES. Every test here drives ONE
-- save at a time. That was once the only shape in which the restore worked:
-- `DirtyAtSaveStart` was a single scalar slot overwritten unconditionally at the
-- start of every save, while `SavesInFlight` is a counter precisely because saves
-- overlap. Probed with the restore line fully INTACT -- write 4242, fire OnSave
-- twice, then OnError -- the entry came out `LastResult=Fail DirtyAtSaveStart=false
-- Dirty=false`: the second save's snapshot had clobbered the first's captured
-- `true`, the restore evaluated `false or false`, and the unstored write read as
-- clean. Same single-slot defect the OnError comment says was fixed for `SaveT0`.
--
-- THAT IS NOW FIXED, and this file is no longer the whole story. The slot
-- accumulates rather than overwrites, and is cleared only when SavesInFlight
-- drains to zero -- clearing per completion reintroduces the same bug from the
-- other end. The overlap half is pinned by OverlappingSaveDirtyClobber.spec (the
-- signal-driven interleaving, plus the receipt consequence) and by
-- SimOverlappingSaveDirty.spec (the same thing through the real vendored store
-- under Slow latency, which asserts SavesInFlight really reaches 2 rather than
-- hoping it does). Deleting the restore line still kills all four tests here, so
-- the two mechanisms are independent and both are load-bearing.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

	local function template()
		return {
			Coins = Scribe.Int(0, { Min = 0 }),
			Settings = { Music = true },
		}
	end

	local function saves(harness, entry): number
		return harness.Fake.SaveCounts[`Default/{entry.Key}`] or 0
	end

	-- Cleanup runs from afterEach rather than the end of each `it`. These tests
	-- deliberately drive save failures, which push the SHARED Health singleton away
	-- from Healthy, and TestCtx.Cleanup is what walks it back. A trailing
	-- `harness.Cleanup()` is skipped when an assertion throws -- which is exactly the
	-- case this file is built to produce -- and the poisoned singleton then fails
	-- unrelated specs (measured: deleting the restore line took FailureReport's GDPR
	-- erase and version restore down with it). The failure signal has to stay local
	-- to this file.
	local harness: any = nil

	afterEach(function()
		if harness then
			harness.Cleanup()
			harness = nil
		end
	end)

	describe("a save that failed leaves the entry dirty", function()
		it("restores the dirtiness the payload snapshot cleared", function()
			harness = TestCtx.make({ Template = template() })
			local player, entry, data = harness.Join(64001)

			data.Coins.Set(7)
			expect(entry.SaveInfo.Dirty).to.equal(true)

			harness.Fake.FailSaves = true
			harness.Data.Flush(player)
			harness.Fake.FailSaves = false

			-- The save was attempted (so the snapshot ran and cleared the flag) and it
			-- did not land.
			expect(entry.SaveInfo.LastResult).to.equal("Fail")
			expect(saves(harness, entry)).to.equal(0)
			-- ...so the entry must still read as carrying unstored writes. This is the
			-- assertion the restore line owns; nothing else in the failure path writes
			-- Dirty, and the snapshot set it to false on the way in.
			expect(entry.SaveInfo.Dirty).to.equal(true)
		end)

		it("reports that through the public GetSaveInfo surface", function()
			harness = TestCtx.make({ Template = template() })
			local player, entry, data = harness.Join(64002)

			data.Coins.Set(11)
			harness.Fake.FailSaves = true
			harness.Data.Flush(player)
			harness.Fake.FailSaves = false

			local info = harness.Data.GetSaveInfo(player)
			expect(info.LastResult).to.equal("Fail")
			expect(info.Dirty).to.equal(true)
			expect(saves(harness, entry)).to.equal(0)
		end)

		it("makes a later CLEAN save the thing that clears it, not the failure", function()
			-- Guards the assertion above against being satisfied by a Dirty that simply
			-- never moves: the same flag has to come back down once a save lands.
			harness = TestCtx.make({ Template = template() })
			local player, entry, data = harness.Join(64003)

			data.Coins.Set(13)
			harness.Fake.FailSaves = true
			harness.Data.Flush(player)
			harness.Fake.FailSaves = false
			expect(entry.SaveInfo.Dirty).to.equal(true)

			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saves(harness, entry)).to.equal(1)
			expect(entry.SaveInfo.LastResult).to.equal("Ok")
			expect(entry.SaveInfo.Dirty).to.equal(false)
			expect(harness.Fake.Persisted[`Default/{entry.Key}`].Coins).to.equal(13)
		end)
	end)

	describe("the consumer with no LastResult clause", function()
		it("does not acknowledge a duplicate receipt off a save that failed", function()
			-- Monetization's duplicate branch reads Dirty and SavesInFlight only. Without
			-- the restore both read "clean" after a failed save, and the retry is answered
			-- PurchaseGranted with the grant and its dedupe marker still only in memory --
			-- and Roblox never retries a granted receipt.
			harness = TestCtx.make({
				Template = template(),
				Options = {
					Products = {
						Coins1000 = {
							Id = 111,
							Category = "Currency",
							Grant = function(data)
								data.Coins.Increment(1000)
							end,
						},
					},
				},
			})
			local _player, entry, data = harness.Join(64004)

			local function receipt(purchaseId: string)
				return {
					PlayerId = entry.UserId,
					ProductId = 111,
					PurchaseId = purchaseId,
					CurrencySpent = 99,
					CurrencyType = Enum.CurrencyType.Robux,
				}
			end

			-- First delivery: the grant applies, the save fails, Roblox is told to retry.
			harness.Fake.FailSaves = true
			expect(harness.Data.HandleReceipt(receipt("p-dirty-1"))).to.equal(NOT_PROCESSED)
			harness.Fake.FailSaves = false

			expect(data.Coins.Get()).to.equal(1000)
			expect(entry.SaveInfo.LastResult).to.equal("Fail")
			-- Nothing reached the store, so the marker exists only in the live tree.
			expect(saves(harness, entry)).to.equal(0)
			expect(harness.Fake.Persisted[`Default/{entry.Key}`]).to.equal(nil)

			-- The retry takes the duplicate branch. It may only answer GRANTED by way of
			-- a confirmed save, which requires Dirty to still be true.
			local before = saves(harness, entry)
			expect(harness.Data.HandleReceipt(receipt("p-dirty-1"))).to.equal(GRANTED)
			expect(saves(harness, entry)).to.equal(before + 1)
			expect(harness.Fake.Persisted[`Default/{entry.Key}`].Coins).to.equal(1000)
			-- ...and still exactly once.
			expect(data.Coins.Get()).to.equal(1000)
		end)
	end)
end
