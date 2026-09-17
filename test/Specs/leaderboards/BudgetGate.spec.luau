--!nonstrict
-- A server board reads no store, so the GetSortedAsync budget gate does not hold it.
-- Sim-backed: the policy is inert under a mock store.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	it("refreshes a server board on the tick while a global board waits on the budget", function()
		local uni = Universe.new({
			Seed = 5310,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 20, SESSION_STEAL = 10, FIRST_LOAD_REPEAT = 2, ASSUME_DEAD = 60 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {
				BudgetPolicy = "Defer",
				Leaderboards = {
					Local = { Stat = "Coins", Scope = "Server", RefreshInterval = 60 },
					Global = { Stat = "Coins", Limit = 10, RefreshInterval = 60 },
				},
			},
		})
		Guard.Install(uni)
		uni.Disk.GetRequestBudgetForRequestType = function(_self, kind)
			local name = if type(kind) == "table" and kind.Name then kind.Name else tostring(kind)
			return if name == "GetSortedAsync" then 0 else 1000
		end
		local server = uni:Server(1)
		local player = FakePlayer.new(8803)
		server:Join(8803, player)
		uni:Run(30)
		server.Bundle.Data.Get(player).Coins.Set(9)
		-- Past the next refresh cycle.
		uni:Run(70)
		local ranked = server.Bundle.Data.GetLeaderboard("Local")
		local deferred = server.Bundle.Scribe.GetMetrics().LbBudgetDeferred or 0
		expect(`local={#ranked} deferred={deferred > 0}`).to.equal("local=1 deferred=true")
	end)
end
