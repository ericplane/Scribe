--!nonstrict
-- Data.GetLeaderboardRefreshIn: seconds until a board next reads its store.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local realWait, realMonotonic = Clock.Wait, Clock.Monotonic

	afterEach(function()
		Clock.Install({ Wait = realWait, Monotonic = realMonotonic })
	end)

	--- The warm-up wait becomes a frame; the monotonic clock becomes ours.
	local function driveClock()
		local offset = 0
		Clock.Install({
			Wait = function()
				return task.wait()
			end,
			Monotonic = function()
				return realMonotonic() + offset
			end,
		})
		return function(seconds: number)
			offset += seconds
		end
	end

	local function makeHarness()
		return TestCtx.make({
			Template = { Wins = Scribe.Int(0) },
			Options = { Leaderboards = { Wins = { Stat = "Wins", RefreshInterval = 120 } } },
		})
	end

	it("is nil before the loop schedules its first cycle, then at most the interval", function()
		local advance = driveClock()
		local harness = makeHarness()
		local before = harness.Data.GetLeaderboardRefreshIn("Wins")
		for _ = 1, 4 do
			task.wait()
		end
		local after = harness.Data.GetLeaderboardRefreshIn("Wins")
		harness.Cleanup()
		expect(`before={tostring(before)} scheduled={after ~= nil and after <= 120 and after >= 0}`).to.equal(
			"before=nil scheduled=true"
		)
		advance(0)
	end)

	it("counts down with the clock and never goes below zero", function()
		local advance = driveClock()
		local harness = makeHarness()
		for _ = 1, 4 do
			task.wait()
		end
		local first = harness.Data.GetLeaderboardRefreshIn("Wins")
		advance(30)
		local later = harness.Data.GetLeaderboardRefreshIn("Wins")
		advance(1000)
		local floored = harness.Data.GetLeaderboardRefreshIn("Wins")
		harness.Cleanup()
		expect(`dropped={math.abs((first - later) - 30) < 0.5} floored={floored}`).to.equal("dropped=true floored=0")
	end)

	it("re-arms a full interval after a refresh runs", function()
		local advance = driveClock()
		local harness = makeHarness()
		for _ = 1, 4 do
			task.wait()
		end
		advance(200)
		for _ = 1, 4 do
			task.wait()
		end
		local rearmed = harness.Data.GetLeaderboardRefreshIn("Wins")
		harness.Cleanup()
		expect(`rearmed={rearmed ~= nil and rearmed > 100 and rearmed <= 120}`).to.equal("rearmed=true")
	end)

	it("is nil for a name that is not a board", function()
		local harness = makeHarness()
		local answer = harness.Data.GetLeaderboardRefreshIn("Nope")
		harness.Cleanup()
		expect(answer).to.equal(nil)
	end)
end
