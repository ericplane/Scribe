--!nonstrict
-- Outage has TWO entry paths, and only one of them used to arm the decay timer.
--
-- evaluate() reaches Outage either by crossing the failure count, or through the
-- critical-state corroboration branch. The second one did `setStatus("Outage")` and
-- returned, skipping the armDecay() at the bottom -- so no timer was ever scheduled.
--
-- Recovery from Outage needs either the decay or a success streak, and Health's own
-- comment explains why the streak cannot cover this: "a server whose burst just ended
-- has no traffic". That is precisely the state this branch produced. Outage refuses
-- Robux receipts, so the server had quietly stopped earning with nothing in the log.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)

	local universe

	local function health()
		universe = Universe.new({
			Seed = 5150,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {},
		})
		Guard.Install(universe)
		return universe, universe:Server(1).Bundle.Health
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("leaving Outage", function()
		-- CONTROL. Proves the harness can observe a decay at all, so the case below
		-- cannot be a broken test rather than a broken mechanism.
		it("decays when Outage was entered by crossing the failure count", function()
			local uni, Health = health()
			for i = 1, 6 do
				Health.ReportFailure("ProfileStore", `COUNT_{i}`, "Failed")
			end
			expect(Health.GetStatus()).to.equal("Outage")
			uni:Run(600)
			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("decays when Outage was entered by sustained critical state", function()
			local uni, Health = health()

			-- Two distinct problems: enough to corroborate, NOT enough to cross the
			-- Outage count (6). So the critical branch is the only route in.
			Health.ReportFailure("ProfileStore", "CRIT_1", "Failed")
			Health.ReportFailure("ProfileStore", "CRIT_2", "Failed")
			expect(Health.GetStatus()).to.equal("Healthy")

			Health.SetCritical(true)
			uni:Run(35) -- past CriticalOutageDelay (30s)
			expect(Health.GetStatus()).to.equal("Outage")

			-- The store recovers and ProfileStore clears its critical flag.
			Health.SetCritical(false)

			-- Ten minutes of a quiet server: no failures, and no successes either --
			-- which is the whole point, because the success streak cannot rescue a
			-- server with no traffic. Only the decay can.
			uni:Run(600)
			expect(Health.GetStatus()).to.equal("Degraded")
		end)
	end)
end
