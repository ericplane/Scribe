--!nonstrict
-- The two previous-period reads a period allows count successes, not attempts.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local DAY = 86400
	local realNow = Clock.Now
	afterEach(function()
		Clock.Install({ Now = realNow })
	end)

	it("shows last period's results after two failed reads, once the store answers", function()
		local now = 11 * DAY
		Clock.Install({
			Now = function()
				return now
			end,
		})
		local harness = TestCtx.make({
			Template = { Wins = Scribe.Int(0, { Min = 0 }) },
			Options = { Leaderboards = { WinsDaily = { Stat = "Wins", Period = "Daily" } } },
		})
		local _, _, data = harness.Join(8401)
		data.Wins.Set(4)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		now = 12 * DAY
		local previous = harness.Ctx.Leaderboards.MockStoreFor("WinsDaily", -1)
		local real = previous.GetSortedAsync
		local failures = 2
		previous.GetSortedAsync = function(...)
			if failures > 0 then
				failures -= 1
				error("transient")
			end
			return real(...)
		end
		local seen = {}
		for _ = 1, 3 do
			harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			table.insert(seen, #harness.Data.GetLeaderboard("WinsDaily", nil, -1))
		end
		harness.Cleanup()
		expect(table.concat(seen, ",")).to.equal("0,0,1")
	end)
end
