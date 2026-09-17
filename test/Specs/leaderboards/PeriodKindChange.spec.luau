--!nonstrict
-- A board changed between Daily and Weekly keeps the old range on record, so an erase
-- sweeps the stores it wrote to and not every period since the epoch.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)

	local DAY = 86400
	local realNow, realWait = Clock.Now, Clock.Wait
	afterEach(function()
		Clock.Install({ Now = realNow, Wait = realWait })
	end)

	local function harnessWith(fake, period: string)
		return TestCtx.make({
			Fake = fake,
			Template = { Wins = Scribe.Int(0, { Min = 0 }) },
			Options = { Leaderboards = { Wins = { Stat = "Wins", Period = period } } },
		})
	end

	--- A score under `before`, then the board redeployed as `after`.
	local function redeployed(before: string, after: string, userId: number)
		local now = 11 * DAY
		Clock.Install({
			Now = function()
				return now
			end,
			Wait = function(seconds)
				task.wait()
				return seconds
			end,
		})
		local fake = FakeProfileStore.new()
		local old = harnessWith(fake, before)
		local player, _, data = old.Join(userId)
		data.Wins.Set(3)
		old.Ctx.Leaderboards.FlushAllBlocking(1)
		local oldStoreName = old.Ctx.Leaderboards.BoardStoreName("Wins")
		old.Leave(player)
		old.Cleanup()
		local new = harnessWith(fake, after)
		-- Mock stores are per bundle.
		local oldStore = new.Ctx.Leaderboards.MockStoreNamed(oldStoreName)
		oldStore:SetAsync(tostring(userId), 3)
		local base = Scribe.GetMetrics().LbEraseRemoves or 0
		return new, oldStore, function()
			return (Scribe.GetMetrics().LbEraseRemoves or 0) - base
		end
	end

	local function entries(store): number
		return #store:GetSortedAsync(false, 10):GetCurrentPage()
	end

	it("sweeps the daily stores a profile wrote before the board became weekly", function()
		local harness, dailyStore = redeployed("Daily", "Weekly", 8201)
		local ok, reason = harness.Data.Erase(8201)
		local left = entries(dailyStore)
		harness.Cleanup()
		expect(`{ok} {reason} left={left}`).to.equal("true nil left=0")
	end)

	it("sweeps one weekly store, not every day since the epoch, when the board became daily", function()
		local harness, weeklyStore, removes = redeployed("Weekly", "Daily", 8202)
		local ok, reason = harness.Data.Erase(8202)
		local left = entries(weeklyStore)
		harness.Cleanup()
		expect(`{ok} {reason} left={left} removes={removes()}`).to.equal("true nil left=0 removes=2")
	end)

	it("keeps writing under the new kind after the change, with the old range closed on record", function()
		local harness, dailyStore = redeployed("Daily", "Weekly", 8203)
		local player, _, data = harness.Join(8203)
		data.Wins.Set(5)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		local record = table.clone(harness.Ctx.Persistence.EntryFor(player).LiveData._Scribe.Boards.Wins)
		local weeklyStore = harness.Ctx.Leaderboards.MockStoreFor("Wins")
		local weeklyEntries = entries(weeklyStore)
		harness.Leave(player)
		local erased = harness.Data.Erase(8203)
		local left = `daily={entries(dailyStore)} weekly={entries(weeklyStore)}`
		harness.Cleanup()
		expect(
			`kind={record.K} first={record.First} prior={#record.Prior}:{record.Prior[1].K}:{record.Prior[1].First}-{record.Prior[1].Last} weekly={weeklyEntries}`
		).to.equal("kind=Weekly first=2 prior=1:Daily:11-11 weekly=1")
		expect(`erased={erased} {left}`).to.equal("erased=true daily=0 weekly=0")
	end)
end
