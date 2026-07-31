--!nonstrict
-- Leaderboard replication is change-driven: clients get the cached board once
-- at handshake, then only when the board content or their own rank changes.

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Scribe = require(ScribeRoot)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function makeHarness()
		return TestCtx.make({
			Options = {
				Leaderboards = {
					TopCoins = { Stat = "Coins", Limit = 10, Replicate = true },
				},
			},
		})
	end

	local function boardFrames(harness, player)
		return harness.FramesFor(player, Wire.Frames.Leaderboard)
	end

	it("rejects an invalid Scale at construction", function()
		local function withScale(scale)
			return function()
				TestCtx.make({
					Options = { Leaderboards = { Bad = { Stat = "Coins", Scale = scale } } },
				}).Cleanup()
			end
		end
		-- Scale = 0 divided by zero on read and served NaN scores to every client.
		expect(withScale(0)).to.throw()
		expect(withScale(-1)).to.throw() -- silently inverted the ordering
		expect(withScale(math.huge)).to.throw() -- every write rejected by the store
		expect(withScale(0 / 0)).to.throw()
	end)

	it("drops a score whose scaled value is outside the OrderedDataStore range", function()
		local harness = TestCtx.make({
			Options = { Leaderboards = { Huge = { Stat = "Gems", Scale = 1000 } } },
		})
		local _, _, data = harness.Join(8600)
		-- 1e18 * 1000 overflows int64; previously this queued a write that SetAsync
		-- rejects every time and was re-enqueued on every change, forever.
		data.Gems.Set(1e18) -- Gems is Scribe.Int(0, { Min = 0 }): unbounded above
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow()
		-- The out-of-range write is dropped, so the score stays at the initial 0
		-- instead of queueing a write SetAsync rejects on every retry, forever.
		local board = harness.Data.GetLeaderboard("Huge")
		expect(board[1].Score).to.equal(0)
		expect((Scribe.GetMetrics().LbScoreOutOfRange or 0) > 0).to.equal(true)
		harness.Cleanup()
	end)

	it("sends the cached board once at handshake, not before", function()
		local harness = makeHarness()
		local player, _, data = harness.Join(8001)
		data.Coins.Set(500)
		harness.Ctx.Leaderboards.FlushAllBlocking(1) -- drain the write queue
		harness.Ctx.Leaderboards.RefreshNow()

		expect(#boardFrames(harness, player)).to.equal(0) -- no handshake yet

		harness.SendHello(player)
		local frames = boardFrames(harness, player)
		expect(#frames).to.equal(1)
		expect(frames[1].Board).to.equal("TopCoins")
		expect(frames[1].Entries[1].UserId).to.equal(8001)
		expect(frames[1].Entries[1].Score).to.equal(500)
		expect(frames[1].MyRank).to.equal(1)
		expect(frames[1].MyScore).to.equal(500)

		harness.Cleanup()
	end)

	it("does not re-broadcast an unchanged board", function()
		local harness = makeHarness()
		local player, _, data = harness.Join(8002)
		data.Coins.Set(100)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.SendHello(player)
		harness.Ctx.Leaderboards.RefreshNow()
		local baseline = #boardFrames(harness, player)

		-- Nothing changed: further refresh cycles stay silent.
		harness.Ctx.Leaderboards.RefreshNow()
		harness.Ctx.Leaderboards.RefreshNow()
		expect(#boardFrames(harness, player)).to.equal(baseline)

		harness.Cleanup()
	end)

	it("broadcasts again when scores actually change", function()
		local harness = makeHarness()
		local player, _, data = harness.Join(8003)
		data.Coins.Set(100)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.SendHello(player)
		harness.Ctx.Leaderboards.RefreshNow()
		local baseline = #boardFrames(harness, player)

		data.Coins.Set(250)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow()

		local frames = boardFrames(harness, player)
		expect(#frames).to.equal(baseline + 1)
		expect(frames[#frames].Entries[1].Score).to.equal(250)
		expect(frames[#frames].MyScore).to.equal(250)

		harness.Cleanup()
	end)

	it("stays server-only by default: no frames, but server reads work", function()
		local harness = TestCtx.make({
			Options = {
				Leaderboards = {
					TopCoins = { Stat = "Coins", Limit = 10 }, -- no Replicate flag
				},
			},
		})
		local player, _, data = harness.Join(8005)
		data.Coins.Set(300)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.SendHello(player)
		harness.Ctx.Leaderboards.RefreshNow()
		harness.Ctx.Leaderboards.RefreshNow()

		-- Nothing ever streamed to the client.
		expect(#boardFrames(harness, player)).to.equal(0)

		-- The server cache still serves reads for server-side boards.
		local top = harness.Data.GetLeaderboard("TopCoins", 10)
		expect(#top).to.equal(1)
		expect(top[1].UserId).to.equal(8005)
		expect(top[1].Score).to.equal(300)
		expect(harness.Data.GetMyRank(player, "TopCoins")).to.equal(1)

		harness.Cleanup()
	end)

	it("applies Scale on write and read", function()
		local harness = TestCtx.make({
			Options = {
				Leaderboards = {
					TopHealth = { Stat = "Health", Scale = 100, Limit = 10, Replicate = true },
				},
			},
		})
		local player, _, data = harness.Join(8004)
		data.Health.Set(87.25)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.SendHello(player)
		harness.Ctx.Leaderboards.RefreshNow()

		local frames = boardFrames(harness, player)
		expect(frames[#frames].Entries[1].Score).to.equal(87.25)

		harness.Cleanup()
	end)

	it("EraseUser scrubs the erased user from the in-memory board cache (GDPR)", function()
		local harness = makeHarness()
		local _player, _, data = harness.Join(8006)
		data.Coins.Set(777)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow()

		-- The user is in the cached board.
		local before = harness.Data.GetLeaderboard("TopCoins", 10)
		expect(#before).to.equal(1)
		expect(before[1].UserId).to.equal(8006)

		-- Erase must remove the PII from the cache IMMEDIATELY, not only at the next refresh.
		harness.Ctx.Leaderboards.EraseUser(8006)
		local after = harness.Data.GetLeaderboard("TopCoins", 10)
		local found = false
		for _, e in after do
			if e.UserId == 8006 then
				found = true
			end
		end
		expect(found).to.equal(false)

		harness.Cleanup()
	end)

	it("warns once in DevMode when a board name is not declared", function()
		local harness = TestCtx.make({
			Options = {
				DevMode = true,
				Leaderboards = { TopCoins = { Stat = "Coins" } },
			},
		})
		local player = harness.Join()
		local function warnings()
			return #Scribe.GetRecentLogs({ Code = "LB_UNKNOWN_BOARD", Limit = 50 })
		end
		local before = warnings()

		-- Case-sensitive: this is the mistake the warning exists for.
		expect(#harness.Data.GetLeaderboard("topcoins", 10)).to.equal(0)
		expect(warnings()).to.equal(before + 1)

		-- Once per name, not once per call.
		harness.Data.GetLeaderboard("topcoins", 10)
		harness.Data.GetMyRank(player, "topcoins")
		expect(warnings()).to.equal(before + 1)

		-- A declared board stays silent.
		harness.Data.GetLeaderboard("TopCoins", 10)
		expect(warnings()).to.equal(before + 1)

		harness.Cleanup()
	end)

	it("clamps a sub-60s RefreshInterval up and says so", function()
		local harness = TestCtx.make({
			Options = {
				DevMode = true,
				Leaderboards = { Fast = { Stat = "Coins", RefreshInterval = 5 } },
			},
		})
		local logs = Scribe.GetRecentLogs({ Code = "LB_INTERVAL_CLAMPED", Limit = 10 })
		expect(#logs > 0).to.equal(true)
		expect(string.find(logs[1].Message, "clamped", 1, true) ~= nil).to.equal(true)
		harness.Cleanup()
	end)

	it("accepts a slower RefreshInterval without complaint", function()
		local before = #Scribe.GetRecentLogs({ Code = "LB_INTERVAL_CLAMPED", Limit = 50 })
		local harness = TestCtx.make({
			Options = { Leaderboards = { Slow = { Stat = "Coins", RefreshInterval = 600 } } },
		})
		expect(#Scribe.GetRecentLogs({ Code = "LB_INTERVAL_CLAMPED", Limit = 50 })).to.equal(before)
		harness.Cleanup()
	end)

	it("rejects a board set whose aggregate read rate is too high", function()
		-- The floor alone permits this: every board is at the 60s minimum, but the
		-- TOTAL is what burns the GetSortedAsync budget.
		local many = {}
		for i = 1, 20 do
			many[`Board{i}`] = { Stat = "Coins" }
		end
		expect(function()
			TestCtx.make({ Options = { Leaderboards = many } })
		end).to.throw()

		-- A sane count still boots.
		local harness = TestCtx.make({
			Options = { Leaderboards = { A = { Stat = "Coins" }, B = { Stat = "Gems" } } },
		})
		harness.Cleanup()
	end)

	it("fires OnLeaderboard on the server when a board changes, even without Replicate", function()
		local harness = TestCtx.make({
			Options = { Leaderboards = { TopCoins = { Stat = "Coins" } } }, -- server-only
		})
		local fired = {}
		harness.Data.OnLeaderboard:Connect(function(boardName, entries)
			table.insert(fired, { Board = boardName, Count = #entries })
		end)

		local player, _e, data = harness.Join(96001)
		data.Coins.Set(500)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow("TopCoins")

		expect(#fired >= 1).to.equal(true)
		expect(fired[1].Board).to.equal("TopCoins")
		expect(fired[1].Count >= 1).to.equal(true)

		-- An unchanged board must not re-fire.
		local afterFirst = #fired
		harness.Ctx.Leaderboards.RefreshNow("TopCoins")
		expect(#fired).to.equal(afterFirst)

		harness.Leave(player)
		harness.Cleanup()
	end)

	it("hands OnLeaderboard entries rank-ordered, matching GetLeaderboard", function()
		local harness = TestCtx.make({ Options = { Leaderboards = { Top = { Stat = "Coins" } } } })
		local entries
		harness.Data.OnLeaderboard:Connect(function(_boardName, received)
			entries = received
		end)

		-- Joined deliberately out of score order: the ordering must come from the
		-- board, not from join order or table iteration.
		for _, pair in { { 1, 50 }, { 2, 900 }, { 3, 300 } } do
			local _p, _e, data = harness.Join(97000 + pair[1])
			data.Coins.Set(pair[2])
		end
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow("Top")

		expect(entries).to.be.ok()
		expect(#entries).to.equal(3)
		-- entries[i] is rank i, highest score first.
		expect(entries[1].Rank).to.equal(1)
		expect(entries[1].Score).to.equal(900)
		expect(entries[2].Rank).to.equal(2)
		expect(entries[2].Score).to.equal(300)
		expect(entries[3].Rank).to.equal(3)
		expect(entries[3].Score).to.equal(50)

		-- Same order GetLeaderboard serves, so the two are interchangeable.
		local fromGetter = harness.Data.GetLeaderboard("Top", 10)
		for i, entry in entries do
			expect(fromGetter[i].UserId).to.equal(entry.UserId)
			expect(fromGetter[i].Rank).to.equal(entry.Rank)
		end

		harness.Cleanup()
	end)
end
