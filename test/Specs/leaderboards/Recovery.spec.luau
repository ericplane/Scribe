--!nonstrict
-- Failed scores remain pending without starving healthy boards.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Metrics = require(Root.Scribe.Internal.Metrics)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)
	local itSim = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local harnesses = {}

	afterEach(function()
		for _, harness in harnesses do
			harness.Cleanup()
		end
		table.clear(harnesses)
		Guard.Reset()
		Clock.Reset()
	end)

	local function make(config)
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(100) },
			Options = { Leaderboards = { Coins = config or { Stat = "Coins" } } },
		})
		table.insert(harnesses, harness)
		return harness, harness.Ctx.Leaderboards
	end

	local function sim(boards)
		local uni = Universe.new({
			Seed = 18422,
			Servers = 1,
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
			Template = { Coins = Scribe.Int(100) },
			Options = {
				BudgetPolicy = "Defer",
				Leaderboards = boards or { Coins = { Stat = "Coins", WriteInterval = 1 } },
			},
		})
		Guard.Install(uni)
		local server = uni:Server(1)
		local lb = server.Bundle.Ctx.Leaderboards
		local store = uni.Disk:GetOrderedDataStore(lb.BoardStoreName("Coins"))
		return uni, server, lb, store
	end

	it("validates complete names including the next period's suffix", function()
		Clock.Install({
			Now = function()
				return 99999 * 86400
			end,
		})
		for _, config in
			{
				{ Stat = "Coins", StoreName = "" },
				{ Stat = "Coins", StoreName = 12 },
				{ Stat = "Coins", StoreName = string.rep("a", 51) },
				{ Stat = "Coins", StoreName = string.rep("a", 43), Period = "Daily" },
			}
		do
			local ok, err = pcall(make, config)
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "StoreName", 1, true) ~= nil).to.equal(true)
		end
		expect(function()
			make({ Stat = "Coins", StoreName = string.rep("a", 50) })
		end).never.to.throw()
		expect(function()
			make({ Stat = "Coins", StoreName = string.rep("a", 42), Period = "Daily" })
		end).never.to.throw()
	end)

	it("reports freshness and current-read failures independently of global health", function()
		local now = 100
		Clock.Install({
			Now = function()
				return 1000 + now
			end,
			Monotonic = function()
				return now
			end,
		})
		local harness, lb = make()
		expect(lb.GetStatus("missing")).to.equal(nil)
		expect(lb.GetStatus("Coins").Status).to.equal("Starting")
		expect(lb.GetStatus("Coins").ReadAge).to.equal(nil)
		lb.RefreshNow("Coins")
		local snapshot = lb.GetStatus("Coins")
		expect(snapshot.Status).to.equal("Healthy")
		expect(snapshot.LastReadAt).to.equal(1100)
		expect(snapshot.ReadAge).to.equal(0)
		snapshot.Status = "changed"
		expect(lb.GetStatus("Coins").Status).to.equal("Healthy")
		now += 121
		expect(lb.GetStatus("Coins").Status).to.equal("Degraded")
		local store = lb.MockStoreFor("Coins")
		local read = store.GetSortedAsync
		store.GetSortedAsync = function()
			error("502: read unavailable", 0)
		end
		lb.RefreshNow("Coins")
		expect(lb.GetStatus("Coins").LastReadError).to.equal("502: read unavailable")
		expect(lb.GetStatus("Coins").LastReadAt).to.equal(1100)
		expect(Scribe.GetStatus()).to.equal("Healthy")
		store.GetSortedAsync = read
		lb.RefreshNow("Coins")
		expect(lb.GetStatus("Coins").Status).to.equal("Healthy")
		expect(lb.GetStatus("Coins").LastReadError).to.equal(nil)
		expect(harness.Data.GetLeaderboardStatus("Coins").ReadAge).to.equal(0)
	end)

	it("bounds an explicit failure drain and retains the score for a later drain", function()
		local harness, lb = make()
		local store = lb.MockStoreFor("Coins")
		local set = store.SetAsync
		local attempts = 0
		store.SetAsync = function()
			attempts += 1
			error("502: unavailable", 0)
		end
		harness.Join(89201)
		lb.FlushAllBlocking(1)
		expect(attempts).to.equal(3)
		expect(lb.GetStatus("Coins").PendingWrites).to.equal(1)
		expect(lb.GetStatus("Coins").RetryingWrites).to.equal(1)
		store.SetAsync = set
		lb.FlushAllBlocking(1)
		expect(lb.GetStatus("Coins").PendingWrites).to.equal(0)
		expect(lb.GetStatus("Coins").LastWriteAt ~= nil).to.equal(true)
	end)

	it("parks a rejected score until its value changes", function()
		local harness, lb = make()
		local store = lb.MockStoreFor("Coins")
		local set = store.SetAsync
		local attempts = 0
		store.SetAsync = function(self, key, value)
			attempts += 1
			if value == 100 then
				error("103: invalid value", 0)
			end
			return set(self, key, value)
		end
		local player, entry, data = harness.Join(89202)
		lb.FlushAllBlocking(1)
		for _ = 1, 10 do
			lb.OnClientReady(entry)
			lb.FlushAllBlocking(1)
		end
		expect(attempts).to.equal(1)
		expect(lb.GetStatus("Coins").Status).to.equal("Degraded")
		expect(lb.GetStatus("Coins").PendingWrites).to.equal(1)
		expect(lb.GetStatus("Coins").RejectedWrites).to.equal(1)
		data.Coins.Set(101)
		lb.FlushAllBlocking(1)
		expect(attempts).to.equal(2)
		expect(lb.GetStatus("Coins").RejectedWrites).to.equal(0)
		harness.Leave(player)
		expect(lb.WriteStateCount()).to.equal(0)
	end)

	it("caps retries when arrivals refill the queue during a failed write", function()
		local now = 0
		Clock.Install({
			Monotonic = function()
				return now
			end,
		})
		local harness, lb = make()
		local enqueue, board = lb.Enqueue, nil
		lb.Enqueue = function(current, ...)
			board = current
			return enqueue(current, ...)
		end
		local player = harness.Join(89207)
		local store = lb.MockStoreFor("Coins")
		local set = store.SetAsync
		local overflows = Metrics.Get().LbQueueOverflow or 0
		store.SetAsync = function()
			for userId = 10000001, 10001000 do
				enqueue(board, { UserId = userId }, userId)
			end
			now = 2
			error("502: failed after the queue refilled", 0)
		end
		lb.FlushAllBlocking(1)
		expect(Metrics.Get().LbQueueDepth).to.equal(1000)
		expect(Metrics.Get().LbQueueOverflow - overflows).to.equal(1)
		expect(lb.WriteStateCount()).to.equal(1000)
		local written = {}
		store.SetAsync = function(self, key, value)
			written[key] = value
			return set(self, key, value)
		end
		lb.FlushAllBlocking(1)
		expect(written[tostring(player.UserId)]).to.equal(100)
		expect(written["10000001"]).to.equal(nil)
		expect(written["10001000"]).to.equal(10001000)
		expect(Metrics.Get().LbQueueDepth).to.equal(0)
		expect(lb.WriteStateCount()).to.equal(1)
		harness.Leave(player)
		expect(lb.WriteStateCount()).to.equal(0)
	end)

	it("preserves an in-flight state when overflow evicts its pending update", function()
		local now = 0
		Clock.Install({
			Monotonic = function()
				return now
			end,
		})
		local harness, lb = make()
		local enqueue, board = lb.Enqueue, nil
		lb.Enqueue = function(current, ...)
			board = current
			return enqueue(current, ...)
		end
		local player, entry = harness.Join(89208)
		local store = lb.MockStoreFor("Coins")
		local set = store.SetAsync
		store.SetAsync = function()
			enqueue(board, entry, 101)
			for userId = 10000001, 10001000 do
				enqueue(board, { UserId = userId }, userId)
			end
			enqueue(board, entry, 102)
			now = 2
			error("502: failed after its pending update was evicted", 0)
		end
		lb.FlushAllBlocking(1)
		expect(Metrics.Get().LbQueueDepth).to.equal(1000)
		expect(lb.WriteStateCount()).to.equal(1000)
		expect(lb.GetStatus("Coins").RetryingWrites).to.equal(1)
		local written
		store.SetAsync = function(self, key, value)
			if key == tostring(player.UserId) then
				written = value
			end
			return set(self, key, value)
		end
		lb.FlushAllBlocking(1)
		expect(written).to.equal(102)
		expect(lb.WriteStateCount()).to.equal(1)
	end)

	itSim("recovers an unchanged score after more than three failures", function()
		local uni, server, lb, store = sim()
		local set = store.SetAsync
		local attempts = 0
		store.SetAsync = function(self, key, value)
			attempts += 1
			if attempts <= 4 then
				error("502: temporary outage", 0)
			end
			return set(self, key, value)
		end
		local player = FakePlayer.new(89203)
		server:Join(player.UserId, player)
		uni:Run(10)
		expect(attempts).to.equal(3)
		expect(lb.GetStatus("Coins").RetryingWrites).to.equal(1)
		expect(server.Bundle.Scribe.GetStatus()).to.equal("Healthy")
		uni:Run(180)
		expect(attempts).to.equal(5)
		expect(store._entries[tostring(player.UserId)]).to.equal(100)
		expect(lb.GetStatus("Coins").Status).to.equal("Healthy")
		expect(lb.GetStatus("Coins").PendingWrites).to.equal(0)
	end)

	itSim("coalesces new scores without resetting backoff or starving another board", function()
		local uni, server, lb, store = sim({
			Coins = { Stat = "Coins", WriteInterval = 1 },
			Other = { Stat = "Coins", WriteInterval = 1 },
		})
		local attempts = 0
		local set = store.SetAsync
		store.SetAsync = function()
			attempts += 1
			error("502: board unavailable", 0)
		end
		local player = FakePlayer.new(89204)
		server:Join(player.UserId, player)
		uni:Run(10)
		local data = server.Bundle.Data.Get(player)
		for score = 1, 600 do
			data.Coins.Set(score)
			uni:Run(1)
		end
		expect(attempts >= 6 and attempts <= 10).to.equal(true)
		expect(lb.GetStatus("Coins").PendingWrites).to.equal(1)
		local other = uni.Disk:GetOrderedDataStore(lb.BoardStoreName("Other"))
		expect(other._entries[tostring(player.UserId)] >= 595).to.equal(true)
		store.SetAsync = set
		uni:Run(310)
		expect(store._entries[tostring(player.UserId)]).to.equal(600)
		expect(lb.GetStatus("Coins").RetryingWrites).to.equal(0)
	end)

	itSim("keeps failed period scores separate and retries a departed player's final score", function()
		local uni, server, lb, store = sim({ Coins = { Stat = "Coins", Period = "Daily", Mode = "Peak" } })
		local wallClock = server.Bundle.Clock
		local wallNow = wallClock.Now
		local dayOffset = 0
		wallClock.Install({
			Now = function()
				return wallNow() + dayOffset * 86400
			end,
		})
		local set = store.SetAsync
		store.SetAsync = function()
			error("502: old period unavailable", 0)
		end
		local player = FakePlayer.new(89205)
		server:Join(player.UserId, player)
		uni:Run(75)
		local data = server.Bundle.Data.Get(player)
		dayOffset = 1
		data.Coins.Set(150)
		server:Leave(player.UserId)
		uni:Run(15)
		local current = uni.Disk:GetOrderedDataStore(lb.BoardStoreName("Coins"))
		expect(current._entries[tostring(player.UserId)]).to.equal(150)
		store.SetAsync = set
		uni:Run(310)
		expect(store._entries[tostring(player.UserId)]).to.equal(100)
		expect(lb.WriteStateCount()).to.equal(0)
	end)

	it("stops pending retries when the bundle stops", function()
		local harness, lb = make()
		local store = lb.MockStoreFor("Coins")
		local attempts = 0
		store.SetAsync = function()
			attempts += 1
			error("502: unavailable", 0)
		end
		harness.Join(89206)
		lb.FlushAllBlocking(1)
		lb.Stop()
		local before = attempts
		task.wait(1.9)
		expect(attempts).to.equal(before)
		expect(lb.WriteStateCount()).to.equal(0)
	end)
end
