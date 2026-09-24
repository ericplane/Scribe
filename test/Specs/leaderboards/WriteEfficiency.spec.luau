--!nonstrict
-- Verify store calls and values through the pacer and explicit drains.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)
	local itSim = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local realNow = Clock.Now
	local harnesses = {}

	afterEach(function()
		for _, harness in harnesses do
			harness.Cleanup()
		end
		table.clear(harnesses)
		Clock.Install({ Now = realNow })
		Guard.Reset()
	end)

	local function make(board, initial)
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Number(initial or 100) },
			Options = { Leaderboards = { Coins = board or { Stat = "Coins" } } },
		})
		table.insert(harnesses, harness)
		return harness, harness.Ctx.Leaderboards
	end

	local function spy(store)
		local calls = {}
		local set = store.SetAsync
		store.SetAsync = function(self, key, value)
			table.insert(calls, value)
			return set(self, key, value)
		end
		return calls
	end

	local function stored(store, userId)
		for _, row in store:GetSortedAsync(false, 100):GetCurrentPage() do
			if row.key == tostring(userId) then
				return row.value
			end
		end
		return nil
	end

	local function newUniverse(interval, defer)
		local uni = Universe.new({
			Seed = 8831,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 20, SESSION_STEAL = 10, FIRST_LOAD_REPEAT = 2, ASSUME_DEAD = 60 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(100) },
			Options = {
				BudgetPolicy = if defer then "Defer" else nil,
				Leaderboards = { Coins = { Stat = "Coins", WriteInterval = interval } },
			},
		})
		Guard.Install(uni)
		local server = uni:Server(1)
		local store = uni.Disk:GetOrderedDataStore(server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins"))
		local calls = spy(store)
		return uni, server, store, calls
	end

	it("skips unchanged daily peaks after the first successful write", function()
		Clock.Install({
			Now = function()
				return 10 * 86400
			end,
		})
		local harness, lb = make({ Stat = "Coins", Period = "Daily", Mode = "Peak" })
		local store = lb.MockStoreFor("Coins")
		local calls = spy(store)
		local _, _, data = harness.Join(89001)
		lb.FlushAllBlocking(1)
		for value = 1, 20 do
			data.Coins.Set(value)
			lb.FlushAllBlocking(1)
		end
		expect(#calls).to.equal(1)
		expect(stored(store, 89001)).to.equal(100)
	end)

	it("skips fractional changes that encode to the same integer", function()
		local harness, lb = make(nil, 3.1)
		local store = lb.MockStoreFor("Coins")
		local calls = spy(store)
		local _, _, data = harness.Join(89002)
		lb.FlushAllBlocking(1)
		for _, value in { 3.2, 3.3, 3.4, 3.1 } do
			data.Coins.Set(value)
			lb.FlushAllBlocking(1)
		end
		expect(#calls).to.equal(1)
		expect(stored(store, 89002)).to.equal(3)
	end)

	it("cancels a pending change that returns to the last stored score", function()
		local harness, lb = make()
		local store = lb.MockStoreFor("Coins")
		local calls = spy(store)
		local _, _, data = harness.Join(89003)
		lb.FlushAllBlocking(1)
		data.Coins.Set(200)
		data.Coins.Set(100)
		lb.FlushAllBlocking(1)
		expect(#calls).to.equal(1)
		expect(stored(store, 89003)).to.equal(100)
	end)

	it("does not cache a failed first write as a stored score", function()
		local harness, lb = make()
		local store = lb.MockStoreFor("Coins")
		local set = store.SetAsync
		local attempts = 0
		store.SetAsync = function(self, key, value)
			attempts += 1
			if attempts == 1 then
				error("injected write failure")
			end
			return set(self, key, value)
		end
		harness.Join(89004)
		lb.FlushAllBlocking(1)
		expect(attempts).to.equal(2)
		expect(stored(store, 89004)).to.equal(100)
	end)

	it("restores the latest score after a write commits but returns an error", function()
		local harness, lb = make()
		local store = lb.MockStoreFor("Coins")
		local calls = spy(store)
		local _, _, data = harness.Join(89005)
		lb.FlushAllBlocking(1)
		local set = store.SetAsync
		store.SetAsync = function(self, key, value)
			set(self, key, value)
			if value == 200 then
				-- Simulate a committed write with a lost response.
				data.Coins.Set(100)
				error("injected lost response after commit")
			end
		end
		data.Coins.Set(200)
		lb.FlushAllBlocking(1)
		expect(table.concat(calls, ",")).to.equal("100,200,100")
		expect(stored(store, 89005)).to.equal(100)
	end)

	it("keeps a change back to the old score while another write is in flight", function()
		local harness, lb = make()
		local store = lb.MockStoreFor("Coins")
		local calls = spy(store)
		local _, _, data = harness.Join(89006)
		lb.FlushAllBlocking(1)
		local set = store.SetAsync
		store.SetAsync = function(self, key, value)
			if value == 200 then
				-- Change the score while this write is in flight.
				data.Coins.Set(100)
			end
			return set(self, key, value)
		end
		data.Coins.Set(200)
		lb.FlushAllBlocking(1)
		expect(table.concat(calls, ",")).to.equal("100,200,100")
		expect(stored(store, 89006)).to.equal(100)
	end)

	it("starts each period with a fresh store and prunes old successful-score history", function()
		local day = 10
		Clock.Install({
			Now = function()
				return day * 86400
			end,
		})
		local harness, lb = make({ Stat = "Coins", Period = "Daily", Mode = "Peak" })
		local _, _, data = harness.Join(89007)
		lb.FlushAllBlocking(1)
		local first = lb.MockStoreFor("Coins")
		for nextDay = 11, 20 do
			day = nextDay
			data.Coins.Set(90)
			data.Coins.Set(100)
			lb.FlushAllBlocking(1)
			expect(stored(lb.MockStoreFor("Coins"), 89007)).to.equal(100)
			expect(lb.WriteStateCount()).to.equal(1)
		end
		expect(stored(first, 89007)).to.equal(100)
	end)

	it("releases successful-score history when clean and dirty players leave", function()
		local harness, lb = make()
		local store = lb.MockStoreFor("Coins")
		local calls = spy(store)
		local clean = harness.Join(89008)
		local dirty, _, data = harness.Join(89009)
		lb.FlushAllBlocking(1)
		expect(lb.WriteStateCount()).to.equal(2)
		data.Coins.Set(250)
		harness.Leave(clean)
		harness.Leave(dirty)
		lb.FlushAllBlocking(1)
		expect(#calls).to.equal(3)
		expect(stored(store, 89009)).to.equal(250)
		expect(lb.WriteStateCount()).to.equal(0)
	end)

	itSim("coalesces changes for the default 30 seconds and writes the latest value", function()
		local uni, server, store, calls = newUniverse()
		local player = FakePlayer.new(89101)
		server:Join(89101, player)
		uni:Run(10)
		expect(#calls).to.equal(1)
		local data = server.Bundle.Data.Get(player)
		for value = 1, 20 do
			data.Coins.Set(value)
			uni:Run(1)
		end
		expect(#calls).to.equal(1)
		data.Coins.Set(777)
		uni:Run(5)
		expect(#calls).to.equal(2)
		expect(store._entries["89101"]).to.equal(777)
	end)

	itSim("honours a longer configured write interval", function()
		local uni, server, store, calls = newUniverse(60)
		local player = FakePlayer.new(89102)
		server:Join(89102, player)
		uni:Run(10)
		server.Bundle.Data.Get(player).Coins.Set(800)
		uni:Run(40)
		expect(#calls).to.equal(1)
		server.Bundle.Data.Get(player).Coins.Set(900)
		uni:Run(20)
		expect(#calls).to.equal(2)
		expect(store._entries["89102"]).to.equal(900)
	end)

	itSim("makes a dirty departure urgent while leaving a clean score alone", function()
		local uni, server, store, calls = newUniverse(60)
		local clean = FakePlayer.new(89103)
		local dirty = FakePlayer.new(89104)
		server:Join(89103, clean)
		server:Join(89104, dirty)
		uni:Run(10)
		expect(#calls).to.equal(2)
		server.Bundle.Data.Get(dirty).Coins.Set(999)
		server:Leave(89103)
		server:Leave(89104)
		uni:Run(10)
		expect(#calls).to.equal(3)
		expect(store._entries["89104"]).to.equal(999)
		expect(server.Bundle.Ctx.Leaderboards.WriteStateCount()).to.equal(0)
	end)

	itSim("spreads failed urgent retries across pacer ticks while other scores cool down", function()
		local uni, server, store = newUniverse(60, true)
		local players = {}
		for userId = 89105, 89107 do
			local player = FakePlayer.new(userId)
			players[userId] = player
			server:Join(userId, player)
		end
		uni:Run(10)
		local attempts = {}
		local set = store.SetAsync
		store.SetAsync = function(self, key, value)
			if key == "89105" then
				table.insert(attempts, uni.Sched.Now)
				error("injected urgent write failure")
			end
			return set(self, key, value)
		end
		for _, player in players do
			server.Bundle.Data.Get(player).Coins.Set(900)
		end
		server:Leave(89105)
		uni:Run(10)
		expect(#attempts).to.equal(3)
		-- Separate ticks wait at least 1.5 seconds minus 25% jitter.
		expect(attempts[2] - attempts[1] >= 1.125 - 1e-6).to.equal(true)
		expect(attempts[3] - attempts[2] >= 1.125 - 1e-6).to.equal(true)
		expect(store._entries["89106"]).to.equal(100)
		expect(store._entries["89107"]).to.equal(100)
	end)
end
