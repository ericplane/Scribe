--!nonstrict
-- Scope = "Server": the players here, ranked in memory, with no store behind the board.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Wire = require(Root.Scribe.Internal.Wire)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Big = require(Root.Scribe.Internal.Big)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local DAY = 86400
	local realNow = Clock.Now

	afterEach(function()
		Clock.Install({ Now = realNow })
	end)

	local function makeHarness(extraBoards)
		local boards = {
			Local = { Stat = "Wins", Scope = "Server", Replicate = true },
			Global = { Stat = "Wins" },
		}
		for k, v in extraBoards or {} do
			boards[k] = v
		end
		return TestCtx.make({
			Template = { Wins = Scribe.Int(0, { Min = 0 }), Wealth = Scribe.Big(0) },
			Options = { Leaderboards = boards },
		})
	end

	local function top(entries): string
		local parts = {}
		for _, e in entries do
			table.insert(parts, `{e.Rank}:{e.UserId}={tostring(e.Score)}`)
		end
		return table.concat(parts, ",")
	end

	it("ranks the players on this server without a single store write", function()
		local harness = makeHarness()
		local _, _, a = harness.Join(2001)
		local _, _, b = harness.Join(2002)
		a.Wins.Set(5)
		b.Wins.Set(9)
		local writesBefore = Scribe.GetMetrics().LbWrites or 0
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow("Local")
		local ranked = top(harness.Data.GetLeaderboard("Local"))
		-- The global board on the same stat wrote twice; the server one wrote nothing.
		local writes = (Scribe.GetMetrics().LbWrites or 0) - writesBefore
		local counted = harness.Ctx.Leaderboards.BoardCount
		harness.Cleanup()
		expect(`{ranked} writes={writes} counted={counted}`).to.equal("1:2002=9,2:2001=5 writes=2 counted=1")
	end)

	it("drops a player who left on the next refresh, and answers their rank while here", function()
		local harness = makeHarness()
		local pa, _, a = harness.Join(2003)
		local pb, _, b = harness.Join(2004)
		a.Wins.Set(1)
		b.Wins.Set(2)
		harness.Ctx.Leaderboards.RefreshNow("Local")
		local rankWhileHere = harness.Data.GetMyRank(pa, "Local")
		harness.Leave(pb)
		harness.Ctx.Leaderboards.RefreshNow("Local")
		local after = top(harness.Data.GetLeaderboard("Local"))
		harness.Cleanup()
		expect(`rank={rankWhileHere} after={after}`).to.equal("rank=2 after=1:2003=1")
	end)

	it("composes with a Period: today's gain on this server, reset by the clock", function()
		local now = 10 * DAY
		Clock.Install({
			Now = function()
				return now
			end,
		})
		local harness = makeHarness({ LocalDaily = { Stat = "Wins", Scope = "Server", Period = "Daily" } })
		local _, _, a = harness.Join(2005)
		a.Wins.Set(4)
		harness.Ctx.Leaderboards.RefreshNow("LocalDaily")
		local today = top(harness.Data.GetLeaderboard("LocalDaily"))
		now = 11 * DAY
		a.Wins.Set(7)
		harness.Ctx.Leaderboards.RefreshNow("LocalDaily")
		local tomorrow = top(harness.Data.GetLeaderboard("LocalDaily"))
		harness.Cleanup()
		expect(`{today} | {tomorrow}`).to.equal("1:2005=4 | 1:2005=3")
	end)

	it("is exempt from the GetSortedAsync guard, so many fast server boards boot", function()
		local boards = {}
		for i = 1, 20 do
			boards[`S{i}`] = { Stat = "Wins", Scope = "Server", RefreshInterval = 1 }
		end
		local ok = pcall(function()
			TestCtx.make({ Template = { Wins = Scribe.Int(0) }, Options = { Leaderboards = boards } }).Cleanup()
		end)
		-- The same twenty as global boards at one second would be 1200 reads a minute.
		local okGlobal = pcall(function()
			local global = {}
			for i = 1, 20 do
				global[`G{i}`] = { Stat = "Wins", RefreshInterval = 1 }
			end
			TestCtx.make({ Template = { Wins = Scribe.Int(0) }, Options = { Leaderboards = global } }).Cleanup()
		end)
		expect(`server={ok} global={okGlobal}`).to.equal("server=true global=false")
	end)

	it("replicates to the client like any board", function()
		local harness = makeHarness()
		local player, _, data = harness.Join(2006)
		data.Wins.Set(3)
		harness.Ctx.Leaderboards.RefreshNow("Local")
		harness.SendHello(player)
		local frames = harness.FramesFor(player, Wire.Frames.Leaderboard)
		harness.Cleanup()
		expect(#frames).to.equal(1)
	end)

	it("sorts a Scribe.Big stat by value", function()
		local harness = makeHarness({ Rich = { Stat = "Wealth", Scope = "Server" } })
		local _, _, a = harness.Join(2007)
		local _, _, b = harness.Join(2008)
		a.Wealth.Set("1e30")
		b.Wealth.Set("5e29")
		harness.Ctx.Leaderboards.RefreshNow("Rich")
		local entries = harness.Data.GetLeaderboard("Rich")
		local order = `{entries[1].UserId}>{entries[2].UserId}`
		local isBig = Big.isBig(entries[1].Score)
		harness.Cleanup()
		expect(`{order} big={isBig}`).to.equal("2007>2008 big=true")
	end)

	it("erases from the cache with no store to touch", function()
		local harness = makeHarness()
		local player, _, data = harness.Join(2009)
		data.Wins.Set(1)
		harness.Ctx.Leaderboards.RefreshNow("Local")
		harness.Leave(player)
		local ok = harness.Data.Erase(2009)
		local shown = #harness.Data.GetLeaderboard("Local")
		harness.Cleanup()
		expect(`ok={ok} shown={shown}`).to.equal("ok=true shown=0")
	end)
end
