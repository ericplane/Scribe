--!nonstrict
-- The failure window's own rules, driven directly.
--
-- Health is a module-level singleton, so a spec that pokes it has to own an
-- isolated copy. A simulated bundle loads its whole Scribe tree through a private
-- module cache, so `server.Bundle.Health` IS a private Health -- and its clock is
-- the universe's virtual one, which makes the sixty-second window and the
-- thirty-second critical delay ordinary assertions instead of sleeps.
--
-- These pin the machine's rules. SimHealthScope pins the consequence a player
-- would notice; this pins why it happens.

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

	--- A universe built only for its private Health module and its virtual clock.
	local function health()
		universe = Universe.new({
			Seed = 4242,
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

	describe("the retry cooldown", function()
		it("counts one operation failing repeatedly as one problem", function()
			-- The whole point. ProfileStore retries a failing key on its own, so
			-- without this a single stuck profile reaches Outage unaided.
			local _uni, Health = health()
			for _ = 1, 10 do
				Health.ReportFailure("ProfileStore", "PLAYER_1")
			end
			expect(Health.GetStatus()).to.equal("Healthy")
		end)

		it("counts it again once the retry window has passed", function()
			-- Collapsing retries must not mean forgiving a key forever: a profile
			-- that is STILL failing a minute later is still a problem.
			local uni, Health = health()
			for _ = 1, 3 do
				Health.ReportFailure("ProfileStore", "PLAYER_1")
				uni:Run(30) -- past the cooldown, inside the window
			end
			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("keeps different subjects independent", function()
			local _uni, Health = health()
			Health.ReportFailure("ProfileStore", "PLAYER_1")
			Health.ReportFailure("ProfileStore", "PLAYER_2")
			Health.ReportFailure("ProfileStore", "PLAYER_3")
			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("keeps different subsystems independent for the same subject", function()
			-- A version read failing must not hide a save failing on the same key.
			local _uni, Health = health()
			Health.ReportFailure("ProfileStore", "PLAYER_1")
			Health.ReportFailure("ProfileLoad", "PLAYER_1")
			Health.ReportFailure("VersionRead", "PLAYER_1")
			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("never collapses failures that carry no subject", function()
			-- Most subsystems report without a key. Those are each their own problem,
			-- exactly as every failure was before the cooldown existed.
			local _uni, Health = health()
			Health.ReportFailure("SendMessage")
			Health.ReportFailure("SendMessage")
			Health.ReportFailure("SendMessage")
			expect(Health.GetStatus()).to.equal("Degraded")
		end)
	end)

	describe("the window", function()
		it("forgets failures that age out of it", function()
			local uni, Health = health()
			Health.ReportFailure("ProfileStore", "PLAYER_1")
			Health.ReportFailure("ProfileStore", "PLAYER_2")
			uni:Run(90) -- everything above is now older than the 60s window

			-- Two fresh problems: if the window had not forgotten, this would be four
			-- and the status would move.
			Health.ReportFailure("ProfileStore", "PLAYER_3")
			Health.ReportFailure("ProfileStore", "PLAYER_4")
			expect(Health.GetStatus()).to.equal("Healthy")
		end)

		it("escalates to Outage on enough distinct problems", function()
			local _uni, Health = health()
			for i = 1, 6 do
				Health.ReportFailure("ProfileStore", `PLAYER_{i}`)
			end
			expect(Health.GetStatus()).to.equal("Outage")
		end)

		it("escalates from ONE subject that keeps failing across windows", function()
			-- Population-independent escalation. An earlier design counted distinct
			-- KEYS against the same thresholds, which made Outage unreachable below
			-- six concurrent players -- so a two-player server in a total outage
			-- would have stayed Healthy and granted Robux it could never persist.
			local uni, Health = health()
			for _ = 1, 6 do
				Health.ReportFailure("ProfileStore", "PLAYER_1")
				Health.ReportFailure("ProfileStore", "PLAYER_2")
				uni:Run(30)
			end
			expect(Health.GetStatus()).to.equal("Outage")
		end)
	end)

	describe("ProfileStore's critical flag", function()
		it("does not force Outage on its own when only one subject is failing", function()
			-- The flag counts raw DataStore errors with no key dimension, so one
			-- permanently-failing profile trips it unaided. It is corroboration, not
			-- an independent trigger.
			local uni, Health = health()
			Health.ReportFailure("ProfileStore", "PLAYER_1")
			Health.SetCritical(true)
			uni:Run(60) -- well past CriticalOutageDelay

			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("stops corroborating with subjects that have aged out of the window", function()
			-- The count that corroborates the flag has to shrink with the window, or
			-- a server that had trouble an hour ago corroborates forever -- and the
			-- bookkeeping behind it grows without bound on a long-lived server.
			local uni, Health = health()
			Health.ReportFailure("ProfileStore", "PLAYER_1")
			Health.ReportFailure("ProfileStore", "PLAYER_2")
			uni:Run(90) -- both are now older than the window

			-- One CURRENT problem, and a critical flag. That is a stuck key, not an
			-- outage, however much trouble there was a minute and a half ago.
			Health.ReportFailure("ProfileStore", "PLAYER_3")
			Health.SetCritical(true)
			uni:Run(60)

			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("does force Outage once more than one subject is failing", function()
			local uni, Health = health()
			Health.ReportFailure("ProfileStore", "PLAYER_1")
			Health.ReportFailure("ProfileStore", "PLAYER_2")
			Health.SetCritical(true)
			uni:Run(60)

			expect(Health.GetStatus()).to.equal("Outage")
		end)
	end)

	describe("recovery", function()
		it("lets a subject count again after a recovery has cleared the window", function()
			-- The dedupe bookkeeping has to be cleared alongside the failure list, or
			-- a key that failed before recovery is silently forgiven on its next
			-- failure and the machine under-reports a relapse.
			local _uni, Health = health()
			Health.ReportFailure("ProfileStore", "PLAYER_1")
			Health.ReportFailure("ProfileStore", "PLAYER_2")
			Health.ReportFailure("ProfileStore", "PLAYER_3")
			expect(Health.GetStatus()).to.equal("Degraded")

			for _ = 1, 5 do
				Health.ReportSuccess("Saves")
			end
			expect(Health.GetStatus()).to.equal("Healthy")

			-- The same three subjects relapse immediately, with no time passing.
			Health.ReportFailure("ProfileStore", "PLAYER_1")
			Health.ReportFailure("ProfileStore", "PLAYER_2")
			Health.ReportFailure("ProfileStore", "PLAYER_3")
			expect(Health.GetStatus()).to.equal("Degraded")
		end)
	end)
end
