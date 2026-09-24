--!nonstrict
-- Check sustained Scribe traffic against simulated DataStore budgets.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local Budget = require(Root.Test.Sim.Disk.Budget)
	local Scheduler = require(Root.Test.Sim.Scheduler)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP

	local function universe(options, overrides)
		local config = {
			Seed = 72541,
			Servers = 1,
			LatencyProfile = "Instant",
			NoBudget = false,
			Constants = { AUTO_SAVE_PERIOD = 60 },
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = options or {},
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		local uni = Universe.new(config)
		Guard.Install(uni)
		return uni
	end

	afterEach(function()
		Guard.Reset()
	end)

	describe("simulation budget fidelity", function()
		it("queries the sorted-list pool that GetSortedAsync actually spends", function()
			local uni = universe()
			local service = uni.Disk:ServiceFor("probe")
			local before = service:GetRequestBudgetForRequestType("GetSortedAsync")
			local after, orderedRead
			uni.Sched:Spawn(function()
				service:GetOrderedDataStore("Scores"):GetSortedAsync(false, 10)
				after = service:GetRequestBudgetForRequestType("GetSortedAsync")
				orderedRead = service:GetRequestBudgetForRequestType("OrderedRead")
			end)
			uni:Run(1)
			expect(before).to.equal(5)
			expect(after).to.equal(4)
			expect(orderedRead).to.equal(60)
		end)

		for _, kind in { "Read", "Write", "List", "Remove" } do
			it(`keeps standard and ordered experience {kind} independent`, function()
				local sched = Scheduler.new(1)
				local budget = Budget.new({ Sched = sched })
				-- A different empty server per request isolates the experience tier.
				for i = 1, 300 do
					expect(budget:TryTake(`ordered-{i}`, `Ordered{kind}`)).to.equal(true)
				end
				expect(budget:TryTake("exhausted", `Ordered{kind}`)).to.equal(false)
				for i = 1, 300 do
					expect(budget:TryTake(`standard-{i}`, `Standard{kind}`)).to.equal(true)
				end
				expect(budget:TryTake("also-exhausted", `Standard{kind}`)).to.equal(false)
			end)
		end

		it("preserves accrued server credit when the experience tier refuses", function()
			local sched = Scheduler.new(1)
			local budget = Budget.new({ Sched = sched })
			for i = 1, 300 do
				expect(budget:TryTake(`job-{i}`, "StandardWrite")).to.equal(true)
			end
			-- Accrue server credit while the experience budget stays below one token.
			sched.Now = 0.1
			local before = budget:Peek("job-1", "StandardWrite")
			expect(budget:TryTake("job-1", "StandardWrite")).to.equal(false)
			expect(budget:Peek("job-1", "StandardWrite")).to.equal(before)
		end)

		it("charges and queries each bundle's own server and player count", function()
			local uni = universe({ Leaderboards = { Coins = { Stat = "Coins" } } }, { Servers = 2 })
			local charges = {}
			local admit = uni.Disk.Admit
			uni.Disk.Admit = function(self, jobId, kind, op)
				if string.sub(kind, 1, 7) == "Ordered" then
					charges[jobId] = (charges[jobId] or 0) + 1
				end
				return admit(self, jobId, kind, op)
			end
			for index = 1, 2 do
				local server = uni:Server(index)
				for n = 1, index do
					local player = FakePlayer.new(index * 100 + n)
					server:Join(player.UserId, player)
				end
			end
			uni:Run(120)
			for index = 1, 2 do
				local server = uni:Server(index)
				expect(#server.Bundle.Players:GetPlayers()).to.equal(index)
				expect((charges[server.JobId] or 0) > 0).to.equal(true)
				local reported = server.Bundle.Scribe.GetBudgetSnapshot().Budgets.GetSortedAsync
				expect(reported).to.equal(uni.Disk:GetRequestBudgetForRequestType("GetSortedAsync", server.JobId))
			end
			expect(charges["sim-server"]).to.equal(nil)
		end)

		it("keeps a bound service attached to Guard installs and resets", function()
			local service = Guard.ServiceFor("bound")
			local first = universe()
			expect(service:GetOrderedDataStore("One")._disk).to.equal(first.Disk)
			Guard.Reset()
			local ok = pcall(function()
				service:GetOrderedDataStore("Unavailable")
			end)
			expect(ok).to.equal(false)
			local second = universe()
			expect(service:GetOrderedDataStore("Two")._disk).to.equal(second.Disk)
		end)
	end)

	describe("sustained leaderboard load", function()
		for _, mode in { "Trickle", "Bucket" } do
			it(`keeps twelve periodic boards within one player's allowance under {mode} refill`, function()
				local boards = {}
				for index = 1, 12 do
					boards[`Board{index}`] = { Stat = "Coins", Period = "Daily", Mode = "Peak", RefreshInterval = 60 }
				end
				local uni = universe({ Leaderboards = boards }, { BudgetMode = mode })
				local server = uni:Server(1)
				local orderedWrites, orderedReads = 0, 0
				local readsByStore = {}
				local admit = uni.Disk.Admit
				uni.Disk.Admit = function(self, jobId, kind, op)
					if kind == "OrderedWrite" then
						orderedWrites += 1
					elseif kind == "OrderedList" then
						orderedReads += 1
					end
					return admit(self, jobId, kind, op)
				end
				local getOrdered = uni.Disk.GetOrderedDataStore
				local watched = {}
				uni.Disk.GetOrderedDataStore = function(self, name, scope)
					local store = getOrdered(self, name, scope)
					if not watched[store] then
						watched[store] = true
						local getSorted = store.GetSortedAsync
						store.GetSortedAsync = function(view, ...)
							readsByStore[name] = (readsByStore[name] or 0) + 1
							return getSorted(view, ...)
						end
					end
					return store
				end
				local player = FakePlayer.new(7401)
				server:Join(player.UserId, player)
				uni:Run(1)
				local data = server.Bundle.Data.Get(player)
				local minWriteBudget, minReadBudget = math.huge, math.huge
				for second = 1, 1200 do
					data.Coins.Set(second)
					uni:Run(1)
					minWriteBudget = math.min(minWriteBudget, uni.Disk.Budget:Peek(server.JobId, "OrderedWrite"))
					minReadBudget = math.min(minReadBudget, uni.Disk.Budget:Peek(server.JobId, "OrderedList"))
				end
				expect(uni.Disk.Budget.Stats.Queued).to.equal(0)
				expect(uni.Disk.Budget.Stats.Dropped).to.equal(0)
				expect(uni.Disk.Budget.Stats.RefusedServer).to.equal(0)
				expect(minWriteBudget >= 7).to.equal(true)
				expect(minReadBudget >= 2).to.equal(true)
				-- Coalesce 14,400 changes; pace current and historical reads together.
				expect(orderedWrites > 200 and orderedWrites <= 500).to.equal(true)
				expect(orderedReads > 40 and orderedReads <= 115).to.equal(true)
				expect(server.Bundle.Scribe.GetMetrics().LbBudgetDeferred > 0).to.equal(true)
				local historicalReads = 0
				for name in boards do
					local storeName = server.Bundle.Ctx.Leaderboards.BoardStoreName(name)
					expect(`{name} refreshed={(readsByStore[storeName] or 0) > 0}`).to.equal(`{name} refreshed=true`)
					local previousName = server.Bundle.Ctx.Leaderboards.BoardStoreName(name, -1)
					historicalReads += readsByStore[previousName] or 0
				end
				expect(historicalReads > 0).to.equal(true)
				-- Departures skip the write interval and flush the latest scores.
				server:Leave(player.UserId)
				uni:Run(60)
				for name in boards do
					local storeName = server.Bundle.Ctx.Leaderboards.BoardStoreName(name)
					expect(uni.Disk:GetOrderedDataStore(storeName)._entries[tostring(player.UserId)]).to.equal(1200)
				end
				expect(uni.Sched.Stalled).to.equal(false)
			end)
		end
	end)
end
