--!nonstrict
-- The duration a save reports has to be ITS OWN.
--
-- `entry.SavesInFlight` was introduced because the store permits N concurrent
-- saves for one profile and the old single-timestamp guard could not track them
-- (see OverlappingSaveFailure.spec). The counter fixed attribution; the timestamp
-- it replaced, `entry.SaveT0`, was left as a single slot -- assigned
-- unconditionally at every OnSave. So a second save starting while the first is
-- still on the wire overwrites the first one's start, and when the first save
-- lands, `onProfileSaved` measures it from the SECOND one's start.
--
-- The under-report is exactly the gap between the two starts, and it is silent:
-- `Data.OnSave`'s `Duration`, the `SaveDuration` metric, and anything an operator
-- builds on them all read low. A save that took 0.5s while a second started 0.2s
-- in is reported as 0.3s -- the direction that hides slow saves rather than
-- inventing them, which is why nothing has caught it.
--
-- The fix is the `or`-accumulate the field one line below already uses for
-- DirtyAtSaveStart, relying on the same drain-to-zero clear in OnSettled: hold the
-- EARLIEST live start, so the longest outstanding save is measured exactly and a
-- shorter overlapping one is measured pessimistically. Erring toward "slower" is
-- the safe direction for a latency number.
--
-- The interleaving is driven signal by signal, for the reason
-- OverlappingSaveFailure.spec gives: the fake persists synchronously, so overlap
-- has to be constructed rather than hoped for.
return function()
	local Root = script.Parent.Parent.Parent
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- Same shape as ClockSeam.spec's, restated because this spec needs to move
	--- Monotonic and Now independently of any harness stepping.
	local function virtualClock(startAt: number?)
		local now = startAt or 1700000000
		Clock.Install({
			Now = function()
				return now
			end,
			Monotonic = function()
				return now
			end,
			Wait = function()
				return task.wait()
			end,
			Delay = function(_seconds, fn, ...)
				return task.spawn(fn, ...)
			end,
		})
		return function(seconds: number)
			now += seconds
		end
	end

	--- Collect every Duration the public Data.OnSave publishes, in order.
	local function durationsOf(harness)
		local seen = {}
		harness.Data.OnSave:Connect(function(info)
			table.insert(seen, info.Duration)
		end)
		return seen
	end

	describe("SaveDuration under overlapping saves", function()
		it("reports a lone save's own elapsed time", function()
			-- THE CONTROL, and it must stay exact. Everything below is about not
			-- disturbing this number.
			local harness = TestCtx.make()
			local advance = virtualClock()
			local player, entry = harness.Join()
			local durations = durationsOf(harness)

			harness.Data.Get(player).Coins.Set(1)
			entry.Profile.OnSave:Fire({})
			advance(0.5)
			entry.Profile.OnAfterSave:Fire(entry.Profile.LastSavedData)
			entry.Profile.OnSettled:Fire({}, "Saved")

			expect(#durations).to.equal(1)
			expect(durations[1]).to.equal(0.5)
			expect(entry.SavesInFlight).to.equal(0)

			Clock.Reset()
			harness.Cleanup()
		end)

		it("clears the start slot once every save has drained, so the next save is fresh", function()
			-- The other half of the accumulate, and the reason it is safe: holding the
			-- earliest start must not outlive the in-flight window, or every later save
			-- in the session would be measured from the first one and grow without
			-- bound.
			local harness = TestCtx.make()
			local advance = virtualClock()
			local player, entry = harness.Join()
			local durations = durationsOf(harness)

			harness.Data.Get(player).Coins.Set(1)
			entry.Profile.OnSave:Fire({})
			advance(0.5)
			entry.Profile.OnAfterSave:Fire(entry.Profile.LastSavedData)
			entry.Profile.OnSettled:Fire({}, "Saved")
			expect(entry.SaveT0).to.equal(nil)

			advance(90)
			entry.Profile.OnSave:Fire({})
			advance(0.25)
			entry.Profile.OnAfterSave:Fire(entry.Profile.LastSavedData)
			entry.Profile.OnSettled:Fire({}, "Saved")

			expect(#durations).to.equal(2)
			expect(durations[2]).to.equal(0.25)

			Clock.Reset()
			harness.Cleanup()
		end)

		it("measures the FIRST save from its own start, not from the overlapping one's", function()
			-- The defect. Save A runs 0.5s; save B starts 0.2s in. A must report 0.5,
			-- not 0.3.
			local harness = TestCtx.make()
			local advance = virtualClock()
			local player, entry = harness.Join()
			local durations = durationsOf(harness)

			harness.Data.Get(player).Coins.Set(4242)

			entry.Profile.OnSave:Fire({}) -- save A starts
			advance(0.2)
			entry.Profile.OnSave:Fire({}) -- save B starts, A still on the wire
			expect(entry.SavesInFlight).to.equal(2)

			advance(0.3) -- A has now been out for 0.5s
			entry.Profile.OnAfterSave:Fire(entry.Profile.LastSavedData)
			entry.Profile.OnSettled:Fire({}, "Saved")

			expect(#durations).to.equal(1)
			expect(durations[1]).to.equal(0.5)

			Clock.Reset()
			harness.Cleanup()
		end)

		it("never reports a duration SHORTER than the save actually took", function()
			-- Stated as the invariant rather than as two numbers, and swept across the
			-- orderings, so a fix that merely moved the error around cannot pass. The
			-- second save is allowed to read pessimistically -- it shares one slot with
			-- the first by construction -- but neither may read low.
			for _, gap in { 0, 0.05, 0.2, 1.5 } do
				local harness = TestCtx.make()
				local advance = virtualClock()
				local player, entry = harness.Join()
				local durations = durationsOf(harness)

				harness.Data.Get(player).Coins.Set(7)
				local startA = Clock.Monotonic()
				entry.Profile.OnSave:Fire({})
				advance(gap)
				entry.Profile.OnSave:Fire({})
				advance(0.4)

				local trueA = Clock.Monotonic() - startA
				entry.Profile.OnAfterSave:Fire(entry.Profile.LastSavedData)
				entry.Profile.OnSettled:Fire({}, "Saved")
				if durations[1] < trueA - 1e-9 then
					error(`gap {gap}: save A took {trueA} but reported {durations[1]}`)
				end

				advance(0.6)
				entry.Profile.OnAfterSave:Fire(entry.Profile.LastSavedData)
				entry.Profile.OnSettled:Fire({}, "Saved")
				expect(entry.SavesInFlight).to.equal(0)
				expect(entry.SaveT0).to.equal(nil)

				Clock.Reset()
				harness.Cleanup()
			end
		end)
	end)
end
