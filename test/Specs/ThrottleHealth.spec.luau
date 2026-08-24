--!nonstrict
-- What a throttle means to the health machine, versus what a failure means.
--
-- Being throttled is the DataStore asking to be asked less often. Being unable to
-- write is the DataStore being broken. The counts here gate money -- an Outage
-- refuses ProcessReceipt for every player on the server -- so conflating the two
-- costs real revenue in exactly the situation that produces the most throttling:
-- a lot of players arriving at once.
--
-- Measured before this: a cold join of 500 players reached Outage, and a
-- twenty-server fleet restart left 13 of 20 servers in Outage with every player
-- loaded fine and zero kicks. Each throttled key was counted as its own distinct
-- problem, so the burst walked straight past the threshold.
--
-- The fix must not buy that by going deaf. A store that is genuinely throttling
-- for minutes on end IS a problem, and the last two specs here are the ones that
-- say so.

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

	local function health()
		universe = Universe.new({
			Seed = 909,
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

	describe("a burst of throttles", function()
		it("counts as one problem however many players it hits", function()
			-- The measured scenario, in miniature: every player's key throttles at
			-- once. That is one server being asked to slow down, not fifty servers'
			-- worth of broken profiles.
			local _uni, Health = health()
			for i = 1, 50 do
				Health.ReportFailure("ProfileStore", `PLAYER_{i}`, "Throttled")
			end
			expect(Health.GetStatus()).to.equal("Healthy")
		end)

		it("still counts as one problem when the same keys throttle again inside the window", function()
			local uni, Health = health()
			for _ = 1, 3 do
				for i = 1, 50 do
					Health.ReportFailure("ProfileStore", `PLAYER_{i}`, "Throttled")
				end
				uni:Run(5) -- inside the retry cooldown
			end
			expect(Health.GetStatus()).to.equal("Healthy")
		end)

		it("does not mask real failures happening at the same time", function()
			-- The throttle burst collapses; three genuinely unsaveable profiles
			-- alongside it must still be three problems.
			local _uni, Health = health()
			for i = 1, 50 do
				Health.ReportFailure("ProfileStore", `PLAYER_{i}`, "Throttled")
			end
			Health.ReportFailure("ProfileStore", "BROKEN_1", "Failed")
			Health.ReportFailure("ProfileStore", "BROKEN_2", "Failed")
			Health.ReportFailure("ProfileStore", "BROKEN_3", "Failed")
			expect(Health.GetStatus()).to.equal("Degraded")
		end)
	end)

	describe("sustained throttling", function()
		it("still escalates, because a store throttling for minutes IS a problem", function()
			-- The sharp one. Collapsing a burst must not mean never hearing about
			-- throttling at all: one problem per retry window still accumulates, so a
			-- store that keeps saying slow down gets there on its own.
			local uni, Health = health()
			for _ = 1, 3 do
				Health.ReportFailure("ProfileStore", "PLAYER_1", "Throttled")
				uni:Run(30) -- past the retry cooldown, inside the failure window
			end
			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("settles at Degraded and does not reach Outage on its own", function()
			-- The ceiling, and it is deliberate. One shared subject plus the retry
			-- cooldown means at most three throttle reports can sit inside a sixty
			-- second window, which is exactly the Degraded threshold. So throttling
			-- alone -- however long it lasts -- says "this store wants to be asked
			-- less often", and never "this store is gone".
			--
			-- That matters because Outage is the one that refuses Robux. Getting
			-- there should take evidence that writes are actually failing, and
			-- throttled writes are ones the DataStore invited us to retry.
			local uni, Health = health()
			for _ = 1, 12 do
				Health.ReportFailure("ProfileStore", "PLAYER_1", "Throttled")
				uni:Run(30)
			end
			expect(Health.GetStatus()).to.equal("Degraded")
		end)

		it("does reach Outage once writes are genuinely failing as well", function()
			-- ...and the escape hatch from that ceiling is real evidence. Same
			-- throttle stream, plus profiles that cannot be written.
			local uni, Health = health()
			for _ = 1, 3 do
				Health.ReportFailure("ProfileStore", "PLAYER_1", "Throttled")
				uni:Run(20)
			end
			for i = 1, 4 do
				Health.ReportFailure("ProfileStore", `BROKEN_{i}`, "Failed")
			end
			expect(Health.GetStatus()).to.equal("Outage")
		end)
	end)

	describe("end to end, through the real error path", function()
		--- Join `n` players, arm one fault kind, then make every one of them write
		--- and flush so each key fails on its own.
		local function churnUnder(kind: string)
			local uni, _Health = health()
			local server = uni:Server(1)
			local players = {}
			for i = 1, 6 do
				local player = FakePlayer.new(92000 + i)
				server:Join(92000 + i, player)
				table.insert(players, player)
			end
			uni:Run(2)

			uni.Disk:Arm({ Kind = kind, Op = "UpdateAsync", Count = 100000 })
			for _ = 1, 4 do
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
			return server.Bundle.Health.GetStatus(), server.Bundle.Scribe.GetMetrics()
		end

		it("a throttled server does not refuse everybody's Robux", function()
			-- The whole change, driven the way it actually happens: real DataStore
			-- throttle errors, on six different keys, through ProfileStore's OnError
			-- and Scribe's classifier. Nothing here calls ReportFailure directly.
			local status, metrics = churnUnder("Throttled")
			expect(`status={status}`).never.to.equal("status=Outage")
			-- ...and this is not passing because no throttle ever happened.
			expect(`throttles={(metrics.DataStoreErrors_Throttled or 0) > 0}`).to.equal("throttles=true")
		end)

		it("a genuinely broken store still does", function()
			-- The control. Same six keys, same churn, same path -- an error class
			-- that means the write did not happen.
			local status, metrics = churnUnder("ServiceError")
			expect(`status={status}`).to.equal("status=Outage")
			expect(`failed={(metrics.DataStoreErrors_Failed or 0) > 0}`).to.equal("failed=true")
		end)
	end)

	describe("classification is what decides it", function()
		it("treats the same fifty keys as fifty problems when they are failures", function()
			-- The control arm, and the one that proves the collapse is keyed on the
			-- CLASS rather than on some accident of the burst's shape. Identical
			-- calls, one word different.
			local _uni, Health = health()
			for i = 1, 50 do
				Health.ReportFailure("ProfileStore", `PLAYER_{i}`, "Failed")
			end
			expect(Health.GetStatus()).to.equal("Outage")
		end)

		it("leaves an unclassified report exactly as it was", function()
			-- Every other caller in the library omits the class. Those must keep
			-- counting per key, or this change quietly rewrites subsystems it was
			-- never about.
			local _uni, Health = health()
			for i = 1, 6 do
				Health.ReportFailure("Leaderboards", `PLAYER_{i}`)
			end
			expect(Health.GetStatus()).to.equal("Outage")
		end)
	end)
end
