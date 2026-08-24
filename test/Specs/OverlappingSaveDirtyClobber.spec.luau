--!nonstrict
-- The Dirty restore under OVERLAPPING saves, which is the shape the restore itself
-- cannot see.
--
-- FailedSaveDirtyRestore pins the restore for ONE save at a time and says in its own
-- header why it stops there: `DirtyAtSaveStart` was a single scalar slot on the
-- Entry, assigned unconditionally at every payload snapshot, while `SavesInFlight`
-- is a counter precisely because the store permits N concurrent saves for one
-- profile. So:
--
--     save A starts   -> captures true, clears Dirty
--     save B starts   -> captures FALSE (A cleared it a moment ago)
--     save A fails    -> the OnError restore evaluates `false or false`
--
-- ...and an unstored write reads clean. That is the same single-slot defect the
-- OnError comment records as already fixed for `SaveT0` by counting instead of
-- holding one value -- unfixed, three lines lower in the same type declaration.
--
-- The fix is to make the slot MONOTONE for the length of the in-flight window: OR
-- the pre-snapshot dirtiness in rather than assigning it, and clear it only when
-- `SavesInFlight` drains to zero. The drain is the load-bearing half. Clearing per
-- COMPLETION instead would reintroduce the identical bug from the other end -- the
-- first completion hands the still-flying save a nil, and its failure restores
-- `nil or false`. Both halves are pinned below.
--
-- WHY THE INTERLEAVING IS DRIVEN SIGNAL BY SIGNAL, borrowed wholesale from
-- OverlappingSaveFailure, which had to learn it: the fake store persists
-- synchronously, so two saves issued through it are really sequential and no
-- mutation of this code could be caught by them. `profile.OnSave`,
-- `profile.OnSettled` and `fake.OnError` are the exact signals the real vendored
-- store fires, in the order it fires them -- OnSave synchronously on entry to
-- SaveProfileAsync before any yield, which is *why* the overlap is deterministic
-- rather than rare; OnError from inside the failing round trip; OnSettled once per
-- call at the end whatever the outcome. Overlap has to be constructed, not hoped for.
return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

	-- Cleanup runs from afterEach for the reason FailedSaveDirtyRestore documents at
	-- length: every test here drives save FAILURES, which push the shared Health
	-- singleton away from Healthy, and a trailing `harness.Cleanup()` is skipped when
	-- an assertion throws -- which is exactly what this file exists to produce. The
	-- poisoned singleton then fails unrelated specs, so the failure signal has to stay
	-- local to this file.
	local harness: any = nil

	afterEach(function()
		if harness then
			harness.Cleanup()
			harness = nil
		end
	end)

	local function saves(entry): number
		return harness.Fake.SaveCounts[`Default/{entry.Key}`] or 0
	end

	local function stored(entry)
		return harness.Fake.Persisted[`Default/{entry.Key}`]
	end

	describe("a failed save that overlapped a later one", function()
		it("still restores the dirtiness its own payload snapshot cleared", function()
			harness = TestCtx.make()
			local player, entry = harness.Join(65101)
			local profile = entry.Profile

			harness.Data.Get(player).Coins.Set(4242)
			expect(entry.SaveInfo.Dirty).to.equal(true)

			-- Save A takes the payload snapshot: Dirty is reset here, not on success.
			profile.OnSave:Fire({})
			expect(entry.SaveInfo.Dirty).to.equal(false)
			-- Save B starts while A is still on the wire. This is the write that used
			-- to destroy the evidence -- it reads the flag A just cleared.
			profile.OnSave:Fire({})
			expect(entry.SavesInFlight).to.equal(2)

			-- A fails. Its payload never persisted, so the 4242 exists only in memory.
			harness.Fake.OnError:Fire("500: mock save failure", "Default", entry.Key)

			expect(entry.SaveInfo.LastResult).to.equal("Fail")
			expect(saves(entry)).to.equal(0)
			-- The assertion the accumulate owns. With an unconditional assignment this
			-- reads false: `DirtyAtSaveStart` held B's snapshot, not A's.
			expect(entry.SaveInfo.Dirty).to.equal(true)
		end)

		it("keeps the capture while any save is still out, not only until the first completion", function()
			-- The other half of the fix, and the one a per-completion clear would break.
			-- A LANDS while B is still flying; B is the one that fails. If the captured
			-- value were forgotten on A's completion, B's failure would restore
			-- `nil or false` and the unstored write would read clean again -- the same
			-- clobber arriving from the opposite end.
			harness = TestCtx.make()
			local player, entry = harness.Join(65102)
			local profile = entry.Profile

			harness.Data.Get(player).Coins.Set(99)
			expect(entry.SaveInfo.Dirty).to.equal(true)

			profile.OnSave:Fire({})
			profile.OnSave:Fire({})
			expect(entry.SavesInFlight).to.equal(2)

			-- A settles. One save is still out there, so nothing may be forgotten yet.
			profile.OnSettled:Fire({}, "Saved")
			expect(entry.SavesInFlight).to.equal(1)

			harness.Fake.OnError:Fire("500: mock save failure", "Default", entry.Key)

			expect(entry.SaveInfo.LastResult).to.equal("Fail")
			expect(entry.SaveInfo.Dirty).to.equal(true)
		end)

		it("forgets the capture once every save has settled", function()
			-- The control for the clear, without which "keep it" is satisfied by never
			-- clearing at all -- and stale dirt would then be restored onto an entry
			-- whose data really is on the key. A LATER unrelated failure must restore
			-- only what ITS OWN snapshot cleared.
			harness = TestCtx.make()
			local player, entry = harness.Join(65103)
			local profile = entry.Profile

			harness.Data.Get(player).Coins.Set(7)
			-- One full round trip: dirty going in, settled coming out.
			profile.OnSave:Fire({})
			profile.OnSettled:Fire({}, "Saved")
			expect(entry.SavesInFlight).to.equal(0)
			expect(entry.SaveInfo.Dirty).to.equal(false)

			-- A later save, with nothing written since, fails.
			profile.OnSave:Fire({})
			harness.Fake.OnError:Fire("500: mock save failure", "Default", entry.Key)

			expect(entry.SaveInfo.LastResult).to.equal("Fail")
			-- Its snapshot captured a CLEAN profile, so the restore has nothing to put
			-- back. A capture that survived the drain would report dirt that no write
			-- produced.
			expect(entry.SaveInfo.Dirty).to.equal(false)
		end)

		it("does not manufacture dirtiness out of an overlap alone", function()
			-- The accumulate has to be an OR over real captures, not a latch that any
			-- second save sets. Two overlapping saves of a CLEAN profile, one failing.
			harness = TestCtx.make()
			local _player, entry = harness.Join(65104)
			local profile = entry.Profile

			expect(entry.SaveInfo.Dirty).to.equal(false)
			profile.OnSave:Fire({})
			profile.OnSave:Fire({})
			harness.Fake.OnError:Fire("500: mock save failure", "Default", entry.Key)

			expect(entry.SaveInfo.LastResult).to.equal("Fail")
			expect(entry.SaveInfo.Dirty).to.equal(false)
		end)
	end)

	describe("the consumer with no LastResult clause", function()
		it("does not acknowledge a duplicate receipt off a clobbered flag", function()
			-- WHY THIS COSTS MONEY. Monetization's duplicate-receipt branch reads
			-- `not entry.SaveInfo.Dirty and entry.SavesInFlight == 0` and nothing else --
			-- no LastResult clause -- and it sits ABOVE the Outage "never eat Robux"
			-- refusal, so nothing downstream covers for it. Once both overlapping saves
			-- have settled the counter is back to zero, and a clobbered Dirty makes that
			-- condition read TRUE for a grant that exists only in RAM. Roblox never
			-- retries a receipt it was told was granted.
			harness = TestCtx.make({
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
			local _player, entry, data = harness.Join(65105)
			local profile = entry.Profile

			local function receipt()
				return {
					PlayerId = entry.UserId,
					ProductId = 111,
					PurchaseId = "p-overlap-1",
					CurrencySpent = 99,
					CurrencyType = Enum.CurrencyType.Robux,
				}
			end

			-- First delivery: the grant and its dedupe marker land in the live tree, the
			-- save fails, Roblox is told to retry.
			harness.Fake.FailSaves = true
			expect(harness.Data.HandleReceipt(receipt())).to.equal(NOT_PROCESSED)
			harness.Fake.FailSaves = false

			expect(data.Coins.Get()).to.equal(1000)
			expect(saves(entry)).to.equal(0)
			expect(stored(entry)).to.equal(nil)
			expect(entry.SaveInfo.Dirty).to.equal(true)

			-- Now the overlap, on top of that still-unsaved grant: two saves out, the
			-- first fails, then both settle so the in-flight counter is back to zero.
			profile.OnSave:Fire({})
			profile.OnSave:Fire({})
			harness.Fake.OnError:Fire("500: mock save failure", "Default", entry.Key)
			profile.OnSettled:Fire({}, "Failed")
			profile.OnSettled:Fire({}, "Failed")
			expect(entry.SavesInFlight).to.equal(0)
			-- Nothing has reached the key at any point.
			expect(saves(entry)).to.equal(0)
			expect(stored(entry)).to.equal(nil)

			-- The retry takes the duplicate branch. Saves are still failing, so the only
			-- honest answer is "retry" -- and the ONLY thing standing between this
			-- receipt and a free PurchaseGranted is the Dirty flag the overlap clobbered.
			harness.Fake.FailSaves = true
			local decision = harness.Data.HandleReceipt(receipt())
			harness.Fake.FailSaves = false

			expect(decision).to.equal(NOT_PROCESSED)
			expect(stored(entry)).to.equal(nil)
			-- ...and the control, so this cannot pass against a Monetization that has
			-- simply stopped acknowledging duplicates: once a save genuinely lands, the
			-- same retry is answered GRANTED.
			expect(harness.Data.Flush(entry.Player)).to.equal(true)
			expect(stored(entry).Coins).to.equal(1000)
			expect(harness.Data.HandleReceipt(receipt())).to.equal(GRANTED)
			expect(data.Coins.Get()).to.equal(1000)
		end)
	end)
end
