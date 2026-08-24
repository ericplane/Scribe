--!nonstrict
-- The fork's save contract, against the REAL vendored store.
--
-- AwaitSave asks the store what happened to its own save instead of watching
-- OnAfterSave and guessing. That only helps if the store answers honestly, so
-- these pin the three outcomes -- and they run under test/Sim rather than against
-- FakeProfileStore because the fake persists synchronously and so cannot produce
-- a save that is genuinely in flight, superseded, or failing.
--
-- "Saved" is the only outcome that means the bytes are on disk. "NotOwned" is the
-- dangerous one: a SUCCESSFUL DataStore round trip whose transform declined to
-- write, because the session moved on. Reporting that as success is exactly how a
-- Robux receipt gets granted for data nobody stored.
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
			Seed = 6161,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {},
		})
		Guard.Install(universe)
		return universe, universe:Server(1)
	end

	--- The live Profile object for a joined player.
	local function profileOf(server, player)
		return server.Bundle.Ctx.Persistence.EntryFor(player).Profile
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("the fork reports each save's own outcome", function()
		it("reports Saved for a save that lands, and the data is on disk", function()
			local uni, server = build()
			local player = FakePlayer.new(61001)
			server:Join(61001, player)
			uni:Run(2)

			server.Bundle.Data.Get(player).Coins.Set(4242)

			local outcome
			uni.Sched:Spawn(function()
				outcome = profileOf(server, player):SaveAwait()
			end)
			uni:Run(10)

			expect(outcome).to.equal("Saved")

			local persisted
			for _, e in uni.Disk.Keyspace:Each() do
				if e.Record.Value and e.Record.Value.Data then
					persisted = e.Record.Value.Data.Coins
				end
			end
			expect(persisted).to.equal(4242)
		end)

		it("reports Failed when the store errors, without retrying a live save", function()
			local uni, server = build()
			local player = FakePlayer.new(61002)
			server:Join(61002, player)
			uni:Run(2)

			server.Bundle.Data.Get(player).Coins.Set(99)
			uni.Disk:Arm({ Kind = "ServiceError", Count = 100000 })

			local outcome
			uni.Sched:Spawn(function()
				outcome = profileOf(server, player):SaveAwait()
			end)
			uni:Run(30)

			-- The claim that matters: it RETURNS, and says it failed. A live save
			-- sets repeat_save_flag false on its first pass, so the backoff loop the
			-- estimate worried about is not even entered.
			expect(outcome).to.equal("Failed")
		end)

		it("reports NotOwned when the stored session moved on beneath a still-active profile", function()
			-- The FIRST draft of this arm stole the session with a second server and
			-- then ran the clock, which left the local profile inactive -- so SaveAwait
			-- returned on its IsActive() guard and never reached the ownership
			-- computation at all. A mutation that hardcoded outcome = "Saved" passed it.
			--
			-- So the stored SessionLoadCount is advanced directly instead: exactly what
			-- the key looks like after another server took and released the session,
			-- while THIS profile still believes it is active. That is the only shape
			-- that exercises the real check inside the transform.
			local uni, server = build()
			local player = FakePlayer.new(61003)
			server:Join(61003, player)
			uni:Run(2)

			local profile = profileOf(server, player)
			server.Bundle.Data.Get(player).Coins.Set(7)

			for _, e in uni.Disk.Keyspace:Each() do
				if e.Record.Value and e.Record.Value.MetaData then
					e.Record.Value.MetaData.SessionLoadCount += 1
				end
			end

			expect(profile:IsActive()).to.equal(true) -- the guard must NOT be what answers

			local outcome
			uni.Sched:Spawn(function()
				outcome = profile:SaveAwait()
			end)
			uni:Run(10)

			expect(outcome).to.equal("NotOwned")
		end)
	end)
end
