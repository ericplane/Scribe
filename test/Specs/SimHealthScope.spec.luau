--!nonstrict
-- What counts as a server-wide outage, and what is just one broken profile.
--
-- Health drives four gates and two of them are Robux: an Outage makes
-- ProcessReceipt return NotProcessedYet for EVERY player. So the question
-- "is the DataStore down" has to be answered about the store, not about one key.
--
-- It used not to be. ProfileStore retries a failing key by itself, with a backoff
-- doubling to a 20s ceiling, and every attempt arrived at Health as a separate
-- failure -- so one permanently-unsaveable profile (an oversize one, which fails
-- every UpdateAsync until it is trimmed) reported seven or more failures a minute
-- and took the whole server to Outage on its own. One player's stuck profile
-- stopped everybody else's purchases.
--
-- Repeated failures of the SAME operation now collapse into one problem. The
-- thresholds keep their meaning -- still failures per sixty seconds -- so this is
-- not a rebasing onto player count, which would be worse than the bug: escalation
-- must not need a crowd. The last spec here is the one that pins that.

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
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local universe

	local function build()
		universe = Universe.new({
			Seed = 31337,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			-- The defaults: Degraded at 3 failures in 60s, Outage at 6.
			StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {},
		})
		Guard.Install(universe)
		return universe
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	--- Join `n` players before any fault is armed, so their loads succeed.
	local function join(uni, server, n: number)
		local players = {}
		for i = 1, n do
			local player = FakePlayer.new(64000 + i)
			server:Join(64000 + i, player)
			table.insert(players, player)
		end
		uni:Run(2)
		return players
	end

	--- Write and flush every player repeatedly, close enough together that every
	--- failure lands inside one Health window.
	local function churn(uni, server, players, rounds: number)
		for _ = 1, rounds do
			for _, player in players do
				local data = server.Bundle.Data.Get(player)
				if data then
					data.Coins.Increment(1)
					uni.Sched:Spawn(function()
						pcall(function()
							return server.Bundle.Data.Flush(player, { Timeout = 20 })
						end)
					end)
				end
			end
			uni:Run(5)
		end
	end

	describe("one profile that can never be saved", function()
		it("does not take the whole server to Outage", function()
			local uni = build()
			local server = uni:Server(1)
			local players = join(uni, server, 3)

			-- Only THIS player's key fails. A narrow arm beats a broad one, so the
			-- other two keep saving normally throughout.
			uni.Disk:Arm({ Kind = "ServiceError", Key = "PLAYER_64001", Count = 100000 })
			churn(uni, server, players, 10)

			local status = server.Bundle.Health.GetStatus()
			-- Degraded is right and useful: something IS wrong. Outage is not --
			-- it would refuse Robux for the two players who are saving fine.
			expect(`status={status}`).never.to.equal("status=Outage")

			-- ...and the healthy players really are still saving, so this is not
			-- passing because nothing happened.
			expect((server.Bundle.Scribe.GetMetrics().SavesOk or 0) > 0).to.equal(true)
		end)

		it("still counts every error in the metric, even though it counts one problem", function()
			-- The metric measures ERRORS, which retries genuinely are; only the state
			-- machine measures distinct problems. Collapsing both would lose the
			-- evidence that something is retrying hard.
			local uni = build()
			local server = uni:Server(1)
			local players = join(uni, server, 2)
			uni.Disk:Arm({ Kind = "ServiceError", Key = "PLAYER_64001", Count = 100000 })
			churn(uni, server, players, 8)

			local failures = server.Bundle.Scribe.GetMetrics().HealthFailures or 0
			expect(`errors={failures > 3}`).to.equal("errors=true")
			expect(`status={server.Bundle.Health.GetStatus()}`).never.to.equal("status=Outage")
		end)
	end)

	describe("a genuine outage", function()
		it("still escalates when every key is failing", function()
			local uni = build()
			local server = uni:Server(1)
			local players = join(uni, server, 3)

			uni.Disk:Arm({ Kind = "ServiceError", Count = 100000 })
			churn(uni, server, players, 10)

			expect(server.Bundle.Health.GetStatus()).to.equal("Outage")
		end)

		it("escalates on a SMALL server too, where there are few keys to fail", function()
			-- The sharpest spec in this file. An earlier design counted DISTINCT KEYS
			-- against the same thresholds, which quietly made escalation impossible
			-- below six concurrent players: a two-player server losing the DataStore
			-- entirely would have stayed Healthy and granted Robux that could never
			-- be persisted. Collapsing retries rather than counting keys is what
			-- keeps this population-independent.
			local uni = build()
			local server = uni:Server(1)
			local players = join(uni, server, 2)

			uni.Disk:Arm({ Kind = "ServiceError", Count = 100000 })
			churn(uni, server, players, 12)

			expect(server.Bundle.Health.GetStatus()).to.equal("Outage")
		end)
	end)
end
