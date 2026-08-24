--!nonstrict
-- A failed save that overlaps a successful one must not vanish.
--
-- The store permits N concurrent saves for one profile: `Profile:Save()` and the
-- autosave tick both spawn one. Scribe tracked "is a save in flight" in a single
-- timestamp slot, `entry.SaveT0`, which the FIRST completion cleared. So when a
-- successful save and a failing one overlapped, the failure arrived to find the slot
-- already nil and was attributed to nothing at all: `LastResult` stayed `"Ok"`, the
-- Dirty restore never ran, `SavesFailed` never moved, and the writes sat only in
-- memory while `GetSaveInfo` reported a clean, saved profile.
--
-- That is not a cosmetic reporting bug. `Monetization` reads exactly those two
-- fields to decide whether a duplicate receipt may be acknowledged without waiting
-- for a save, so a swallowed failure is how a receipt gets granted for data that was
-- never stored.
--
-- The fix is to count in-flight saves instead of holding one timestamp, decremented
-- by the store's `OnSettled` signal, which fires exactly once per save call whatever
-- the outcome. Pairing `OnSave` with `OnAfterSave` cannot work: `OnAfterSave` fires
-- only on success, so a failing save would leak a count forever.
return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	describe("a failed save overlapping a successful one", function()
		it("is reported, rather than swallowed by the earlier completion", function()
			-- The interleaving is driven signal by signal on purpose. The FIRST draft of
			-- this spec started a second save from inside MidSave and let the fake run
			-- it -- but the fake persists synchronously, so the two saves were really
			-- sequential and a mutation that collapsed the counter to zero on any
			-- completion passed it. Overlap has to be constructed, not hoped for.
			local harness = TestCtx.make()
			local player, entry = harness.Join()
			local profile = entry.Profile

			harness.Data.Get(player).Coins.Set(4242)

			-- Two saves on the wire.
			profile.OnSave:Fire({})
			profile.OnSave:Fire({})
			expect(entry.SavesInFlight).to.equal(2)

			-- The first one lands. One save is still out there.
			profile.OnSettled:Fire({}, "Saved")
			expect(entry.SavesInFlight).to.equal(1)

			-- The second one fails. Under the old single-slot guard this arrived to
			-- find the slot already cleared by the completion above and did nothing:
			-- LastResult stayed "Ok" while the write existed only in memory.
			harness.Fake.OnError:Fire("500: mock save failure", "Default", entry.Key)

			expect(harness.Data.GetSaveInfo(player).LastResult).to.equal("Fail")
			harness.Cleanup()
		end)

		it("stops attributing failures once every save has settled", function()
			-- The other half, and the reason the old code cleared the slot at all: an
			-- unrelated same-key error (an operator view read, a version query) must
			-- NOT be re-reported as a failed save once nothing is in flight.
			local harness = TestCtx.make()
			local player, entry = harness.Join()

			harness.Data.Get(player).Coins.Set(11)
			entry.Profile:Save()
			expect(harness.Data.GetSaveInfo(player).LastResult).to.equal("Ok")
			expect(entry.SavesInFlight).to.equal(0)

			harness.Fake.OnError:Fire("500: unrelated view read failure", "Default", entry.Key)

			expect(harness.Data.GetSaveInfo(player).LastResult).to.equal("Ok")
			harness.Cleanup()
		end)

		it("still reports success when nothing failed", function()
			-- The control. Without it the spec above passes against an implementation
			-- that simply reports "Fail" for everything.
			local harness = TestCtx.make()
			local player, entry = harness.Join()

			harness.Data.Get(player).Coins.Set(7)
			entry.Profile:Save()

			expect(harness.Data.GetSaveInfo(player).LastResult).to.equal("Ok")
			harness.Cleanup()
		end)

		it("brings the in-flight count back down on failure, not only on success", function()
			-- The leak that a naive OnSave/OnAfterSave pairing would introduce: a
			-- failing save never fires OnAfterSave, so the count would rise forever and
			-- every later error on this key would be re-attributed to a save that had
			-- long since finished.
			local harness = TestCtx.make()
			local _player, entry = harness.Join()

			harness.Fake.FailSaves = true
			entry.Profile:Save()
			harness.Fake.FailSaves = false
			entry.Profile:Save()

			expect(entry.SavesInFlight).to.equal(0)
			harness.Cleanup()
		end)
	end)
end
