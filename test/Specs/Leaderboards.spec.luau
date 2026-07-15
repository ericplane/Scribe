--!nonstrict
-- Leaderboard replication is change-driven: clients get the cached board once
-- at handshake, then only when the board content or their own rank changes.

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
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
end
