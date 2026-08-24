--!nonstrict
-- Getting back out of Outage when the failures stop.
--
-- The status machine only ever escalated. Nothing lowered it except a streak of
-- successful operations -- ten of them to clear Outage -- and on a quiet server
-- nothing reports anything at all, so a burst that ended left the status where it
-- peaked. Measured: a twenty-server fleet restart put 13 of 20 servers in Outage,
-- all still there three minutes after every player had loaded, with zero kicks and
-- nothing in the log. Outage refuses Robux receipts, so those servers had quietly
-- stopped earning.
--
-- The rule that fixes it is "the failures stopped", NOT "the count dipped". Three
-- of these specs exist because designs built on the other rule were measured and
-- thrown away, and each one names the design it kills:
--
--   the count dipped -> the window thins between failures whenever the stream is
--   sparser than the Outage threshold, which the retry cooldown guarantees on a
--   small server. Outage flapped to one second in every thirty.
--
--   an empty window means recovered -> a store that is 100% down but quiet is
--   indistinguishable from a store that is fine.
--
--   re-arm only when you step -> a check that declines dies, and the whole
--   feature becomes invisible.

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

	--- Six distinct problems: enough to cross the Outage threshold.
	local function toOutage(Health, tag: string)
		for i = 1, 6 do
			Health.ReportFailure("ProfileStore", `{tag}_{i}`, "Failed")
		end
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("when the failures stop", function()
		it("lifts Outage once a window has passed with none", function()
			local uni, Health = health()
			toOutage(Health, "A")
			expect(Health.GetStatus()).to.equal("Outage")

			uni:Run(90)
			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("lifts it after a burst that spans more than one window", function()
			-- Kills the first rejected design, which re-armed only when it stepped: a
			-- check that fires mid-burst, declines, and is never re-armed leaves the
			-- server in Outage forever. Every realistic burst outlasts one window, so
			-- that design fixed nothing -- and passed the entire suite.
			local uni, Health = health()
			for round = 1, 3 do
				for i = 1, 6 do
					Health.ReportFailure("ProfileStore", `B{round}_{i}`, "Failed")
				end
				uni:Run(45) -- each round is a fresh burst, the whole run outlasts a window
			end
			expect(Health.GetStatus()).to.equal("Outage")

			uni:Run(90)
			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("stops at Degraded, and does not call itself Healthy", function()
			-- Kills the second rejected design. Nobody reporting a failure is not
			-- evidence that anything succeeded: a dead store on a quiet server looks
			-- exactly like a healthy one. Healthy stays behind the success streak.
			local uni, Health = health()
			toOutage(Health, "C")
			uni:Run(600)
			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("comes back the moment something fails again", function()
			local uni, Health = health()
			toOutage(Health, "D")
			uni:Run(90)
			expect(Health.GetStatus()).to.equal("Degraded")

			toOutage(Health, "E")
			expect(Health.GetStatus()).to.equal("Outage")
		end)
	end)

	describe("while the failures continue", function()
		it("holds Outage on a stream too thin to keep the window full", function()
			-- Kills the third rejected design, and this is the sharpest spec here.
			-- Stepping down when the window merely falls below the Outage threshold
			-- looks reasonable and is a money bug: with two keys failing every thirty
			-- seconds the count dips between them, so Outage was held for one second
			-- in every thirty and the receipt gate stood open for the other twenty
			-- nine. A real outage on a small server is exactly this shape.
			local uni, Health = health()
			for _ = 1, 8 do
				Health.ReportFailure("ProfileStore", "SICK_1", "Failed")
				Health.ReportFailure("ProfileStore", "SICK_2", "Failed")
				uni:Run(30)
			end
			expect(Health.GetStatus()).to.equal("Outage")
		end)

		it("holds Outage across a long outage with steady traffic", function()
			local uni, Health = health()
			for round = 1, 10 do
				for i = 1, 6 do
					Health.ReportFailure("ProfileStore", `LONG{round}_{i}`, "Failed")
				end
				uni:Run(20)
			end
			expect(Health.GetStatus()).to.equal("Outage")
		end)
	end)

	describe("the critical flag", function()
		it("pins Outage while the store itself says it is unhappy", function()
			local uni, Health = health()
			toOutage(Health, "F")
			Health.SetCritical(true)
			uni:Run(300)
			expect(Health.GetStatus()).to.equal("Outage")
		end)

		it("lets go once the flag clears and the failures have stopped", function()
			-- The re-arm has to survive the critical early return too, or clearing the
			-- flag on a quiet server leaves the latch exactly where it was.
			local uni, Health = health()
			toOutage(Health, "G")
			Health.SetCritical(true)
			uni:Run(300)
			expect(Health.GetStatus()).to.equal("Outage")

			Health.SetCritical(false)
			uni:Run(90)
			expect(Health.GetStatus()).to.equal("Degraded")
		end)
	end)

	describe("alongside the success streak", function()
		it("still recovers to Healthy the way it always did", function()
			local _uni, Health = health()
			toOutage(Health, "H")
			for _ = 1, 10 do
				Health.ReportSuccess("Saves")
			end
			expect(Health.GetStatus()).to.equal("Healthy")
		end)

		it("does not let a decay step and a success streak compound into a free level", function()
			-- The streak has to be PART-BUILT when the decay lands, or the reset has
			-- nothing to reset and the spec proves nothing: four successes is one short
			-- of a step, and if the decay's own step is allowed to keep them, the fifth
			-- success buys Healthy having only ever earned one level.
			local uni, Health = health()
			toOutage(Health, "I")
			for _ = 1, 4 do
				Health.ReportSuccess("Saves") -- streak = 4, one short of stepping
			end
			expect(Health.GetStatus()).to.equal("Outage")

			uni:Run(90) -- the decay steps it, and must bank the part-built streak
			expect(Health.GetStatus()).to.equal("Degraded")

			Health.ReportSuccess("Saves")
			expect(Health.GetStatus()).to.equal("Degraded")
			for _ = 1, 4 do
				Health.ReportSuccess("Saves")
			end
			expect(Health.GetStatus()).to.equal("Healthy")
		end)
	end)
end
