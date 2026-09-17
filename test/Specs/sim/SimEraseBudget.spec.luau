--!nonstrict
-- Defer-paced erase removals; Sim-backed because the policy is inert under a mock store.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local universe

	local function build(withBudget: boolean?)
		universe = Universe.new({
			Seed = 6262,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 20, SESSION_STEAL = 10, FIRST_LOAD_REPEAT = 2, ASSUME_DEAD = 60 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = not withBudget,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {
				BudgetPolicy = "Defer",
				Leaderboards = { Coins = { Stat = "Coins", Limit = 100, RefreshInterval = 60, Period = "Daily" } },
			},
		})
		Guard.Install(universe)
		return universe
	end

	local function stubBudget(disk, remainingFor)
		local queries = { Count = 0, ByType = {} }
		disk.GetRequestBudgetForRequestType = function(_self, kind)
			local name = if type(kind) == "table" and kind.Name then kind.Name else tostring(kind)
			queries.Count += 1
			queries.ByType[name] = (queries.ByType[name] or 0) + 1
			return remainingFor(name)
		end
		return queries
	end

	it("models an OrderedRemove allowance, and the public snapshot reports it", function()
		local uni = build(true)
		local server = uni:Server(1)
		local remaining = uni.Disk:GetRequestBudgetForRequestType("OrderedRemove")
		local reported = server.Bundle.Scribe.GetBudgetSnapshot().Budgets.OrderedRemove
		expect(`positive={remaining > 0} finite={remaining < math.huge} reported={reported == remaining}`).to.equal(
			"positive=true finite=true reported=true"
		)
	end)

	it("asks the budget before every removal of a periodic erase", function()
		local uni = build()
		local queries = stubBudget(uni.Disk, function()
			return 1000
		end)
		local server = uni:Server(1)
		local player = FakePlayer.new(9101)
		server:Join(9101, player)
		uni:Run(0.05)
		server.Bundle.Data.Get(player).Coins.Set(5)
		-- Store calls yield on virtual time, so everything below runs inside the universe.
		uni:Run(5)
		server:Leave(9101)
		uni:Run(3)
		local before = queries.ByType.OrderedRemove or 0
		local ok, reason
		uni.Sched:Spawn(function()
			ok, reason = server.Bundle.Data.Erase(9101)
		end)
		uni:Run(10)
		local asked = (queries.ByType.OrderedRemove or 0) - before
		expect(`ok={tostring(ok)} reason={tostring(reason)} asked={asked >= 1}`).to.equal(
			"ok=true reason=nil asked=true"
		)
	end)
end
