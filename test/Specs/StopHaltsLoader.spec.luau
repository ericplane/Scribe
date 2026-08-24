--!nonstrict
-- `Data.Stop()` has to stop the loader too.
--
-- Under `LoadFailurePolicy = "Wait"` a failed profile load is retried forever
-- rather than kicking the player: `while not self.Closing do ... end`, with a
-- backoff between attempts. `Closing` is set by the SHUTDOWN drain, and only by
-- it. `Data.Stop()` -- the documented way for a process that builds many bundles
-- (a test suite, a simulation standing up a fleet) to release one -- disconnects
-- the entry-point connections and returns, leaving the loop spinning.
--
-- So a stopped bundle keeps issuing `StartSessionAsync` against the DataStore,
-- forever, for a player nobody is waiting on, holding a profile-less `Loading`
-- entry with it. Each abandoned bundle adds another.
--
-- `Closing` deliberately is NOT reused: it also gates the `StartSessionAsync`
-- Cancel hook, the session-stolen classification and the shutdown-quiet teardown
-- path, and a stop is not a shutdown drain. A separate flag says the one thing
-- that is true -- this bundle has been released -- without changing what any of
-- those mean.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	--- Waits have to YIELD but must not cost their real duration, or the retry
	--- backoff makes this spec a five-minute test. Same shape as ClockSeam.spec.
	local function fastClock()
		Clock.Install({
			Wait = function()
				return task.wait()
			end,
			Delay = function(_seconds, fn, ...)
				return task.spawn(fn, ...)
			end,
		})
	end

	--- A harness whose loads always fail, with the retry policy armed, plus a
	--- counter of how many times the store has been asked.
	local function makeHarness()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = { LoadFailurePolicy = "Wait" },
		})
		local attempts = 0
		harness.Ctx.Persistence.Store.StartSessionAsync = function(_selfStore, _key, params)
			attempts += 1
			if params and type(params.Cancel) == "function" then
				params.Cancel()
			end
			return nil
		end
		return harness, function()
			return attempts
		end
	end

	local function frames(n)
		for _ = 1, n do
			task.wait()
		end
	end

	describe("Data.Stop and the Wait-policy loader", function()
		it("is really retrying before Stop, so the measurement means something", function()
			-- THE CALIBRATION. Every assertion below is "the counter stopped moving",
			-- which a loop that never started would also satisfy.
			fastClock()
			local harness, attemptCount = makeHarness()
			harness.Ctx.Persistence.OnPlayerAdded(FakePlayer.new(910001))
			frames(6)

			expect(attemptCount() > 1).to.equal(true)

			harness.Data.Stop()
			Clock.Reset()
			harness.Cleanup()
		end)

		it("issues no further store calls after Stop", function()
			-- The defect, measured as the thing that costs money: DataStore requests
			-- for a player nobody is waiting on, from a bundle nobody holds.
			fastClock()
			local harness, attemptCount = makeHarness()
			harness.Ctx.Persistence.OnPlayerAdded(FakePlayer.new(910002))
			frames(6)
			expect(attemptCount() > 1).to.equal(true)

			harness.Data.Stop()
			local afterStop = attemptCount()
			frames(10)
			local later = attemptCount()

			if later > afterStop then
				error(`the loader issued {later - afterStop} store calls after Stop`)
			end

			Clock.Reset()
			harness.Cleanup()
		end)

		it("does not kick the player on the way out", function()
			-- A stop is not a session ending badly. Tearing the Loading entry down must
			-- not fire the default "your data session has ended, please rejoin" kick at
			-- someone whose server is fine -- which is the trap in reusing the shutdown
			-- flag for this.
			fastClock()
			local harness = makeHarness()
			local player = FakePlayer.new(910003)
			local kicked = false
			player.Kick = function()
				kicked = true
			end
			harness.Ctx.Persistence.OnPlayerAdded(player)
			frames(6)

			harness.Data.Stop()
			frames(6)

			expect(kicked).to.equal(false)

			Clock.Reset()
			harness.Cleanup()
		end)

		it("still retries across a shutdown-free lifetime", function()
			-- THE CONTROL THAT MATTERS MOST. The whole point of LoadFailurePolicy =
			-- "Wait" is that it does not give up, so a fix that simply stopped retrying
			-- would satisfy every assertion above and destroy the feature.
			fastClock()
			local harness, attemptCount = makeHarness()
			harness.Ctx.Persistence.OnPlayerAdded(FakePlayer.new(910004))
			frames(6)
			local early = attemptCount()
			frames(10)
			local late = attemptCount()

			expect(late > early).to.equal(true)

			harness.Data.Stop()
			Clock.Reset()
			harness.Cleanup()
		end)

		it("still stops on the shutdown drain, as it always did", function()
			-- The other exit, unchanged: Closing keeps meaning what it meant.
			fastClock()
			local harness, attemptCount = makeHarness()
			harness.Ctx.Persistence.OnPlayerAdded(FakePlayer.new(910005))
			frames(6)
			expect(attemptCount() > 1).to.equal(true)

			harness.Ctx.Persistence.Closing = true
			frames(4)
			local afterClosing = attemptCount()
			frames(10)
			expect(attemptCount()).to.equal(afterClosing)

			harness.Data.Stop()
			Clock.Reset()
			harness.Cleanup()
		end)
	end)
end
