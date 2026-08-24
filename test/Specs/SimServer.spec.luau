--!nonstrict
-- One simulated server, end to end: real Scribe, real vendored ProfileStore, real
-- modelled disk, on virtual time.
--
-- This is where the three layers meet, and the point of these specs is narrow --
-- that they meet AT ALL, and that a run finishes with nothing lost or left in
-- flight. Multi-server contention, workloads and soaks come after; if the single
-- server case is wrong, every one of those would be measuring the wrong thing.

return function()
	local Root = script.Parent.Parent.Parent
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	-- Production values put session conflict at 40s and dead-session recovery at
	-- 630s. Shortened so a bounded run reaches those paths; set per instance,
	-- because each server is its own module.
	local CONSTANTS = {
		AUTO_SAVE_PERIOD = 30,
		SESSION_STEAL = 10,
		FIRST_LOAD_REPEAT = 2,
		LOAD_REPEAT_PERIOD = 3,
		ASSUME_DEAD = 60,
		START_SESSION_TIMEOUT = 60,
	}

	local universe

	local function newUniverse(overrides)
		local config = {
			Seed = 4171,
			Servers = 1,
			Constants = CONSTANTS,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true, -- budgets have their own specs; not the subject here
			-- Chosen, not inherited. These specs are about the stack fitting
			-- together, so Health is set far out of the way; a spec that wants to
			-- study Outage lowers them on purpose.
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("a single server", function()
		it("loads a player through the whole stack and persists on leave", function()
			local uni = newUniverse()
			local server = uni:Server(1)
			local player = FakePlayer.new(101)

			server:Join(101, player)
			uni:Run(30)

			local accessor = server.Bundle.Ctx.Persistence.EntryFor(player)
			expect(accessor).never.to.equal(nil)

			-- Mutate through Scribe's own accessor, exactly as a game would.
			local data = server.Bundle.Data.Get(player)
			expect(data).never.to.equal(nil)
			data.Coins.Set(250)

			server:Leave(101)
			uni:Run(60)

			-- The write reached the modelled disk, through real ProfileStore.
			local record = uni.Disk.Keyspace:Read("Default", "PLAYER_101")
			expect(record).never.to.equal(nil)
			expect(record.Value.Data.Coins).to.equal(250)
		end)

		it("releases the session lock when the player leaves", function()
			local uni = newUniverse()
			local server = uni:Server(1)
			local player = FakePlayer.new(102)

			server:Join(102, player)
			uni:Run(30)

			local held = uni.Disk.Keyspace:Read("Default", "PLAYER_102")
			expect(held.Value.MetaData.ActiveSession).never.to.equal(nil)
			expect(held.Value.MetaData.ActiveSession[2]).to.equal(server.JobId)

			server:Leave(102)
			uni:Run(60)

			-- A released lock is what lets another server pick the player up.
			expect(uni.Disk.Keyspace:Read("Default", "PLAYER_102").Value.MetaData.ActiveSession).to.equal(nil)
		end)

		it("carries data across a rejoin", function()
			local uni = newUniverse()
			local server = uni:Server(1)

			local first = FakePlayer.new(103)
			server:Join(103, first)
			uni:Run(30)
			server.Bundle.Data.Get(first).Coins.Set(999)
			server:Leave(103)
			uni:Run(60)

			local second = FakePlayer.new(103)
			server:Join(103, second)
			uni:Run(30)

			expect(server.Bundle.Data.Get(second).Coins.Get()).to.equal(999)
		end)

		it("settles with nothing in flight and no deadlock", function()
			-- The liveness gate, and the assertion every later result depends on.
			-- A run that ends with a request outstanding has not proved anything
			-- about what was persisted -- the interesting write might still have
			-- been on its way.
			local uni = newUniverse()
			local server = uni:Server(1)

			local players = {}
			for i = 1, 20 do
				players[i] = FakePlayer.new(200 + i)
				server:Join(200 + i, players[i])
			end
			uni:Run(60)

			for i = 1, 20 do
				server.Bundle.Data.Get(players[i]).Coins.Set(i * 10)
				server:Leave(200 + i)
			end

			uni:Quiesce()
			local settled = uni:Settle(300)

			expect(settled).to.equal(true)
			expect(uni.Disk:InFlight()).to.equal(0)
			expect(uni.Sched.Deadlocked).to.equal(false)
			expect(uni.Sched.Stalled).to.equal(false)

			-- ...and every one of them actually persisted.
			for i = 1, 20 do
				local record = uni.Disk.Keyspace:Read("Default", `PLAYER_{200 + i}`)
				expect(record).never.to.equal(nil)
				expect(record.Value.Data.Coins).to.equal(i * 10)
			end
		end)

		it("replays a seed to an identical digest", function()
			-- Everything a simulation can ever prove rests on this. Two runs of one
			-- seed, over the full stack -- Scribe, ProfileStore, modelled disk --
			-- must agree on exactly what ended up stored.
			local function run()
				local uni = newUniverse()
				local server = uni:Server(1)
				for i = 1, 8 do
					local player = FakePlayer.new(300 + i)
					server:Join(300 + i, player)
					uni:Run(5)
					local data = server.Bundle.Data.Get(player)
					if data then
						data.Coins.Set(i * 7)
					end
					server:Leave(300 + i)
				end
				uni:Run(120)
				uni:Quiesce()
				uni:Settle(120)
				local digest = uni:Digest()
				Guard.Reset()
				return digest
			end

			expect(run()).to.equal(run())
		end)

		it("runs SCRIBE's own clock on virtual time too", function()
			-- Found by mutation: every spec above passed with the Clock seam left
			-- uninstalled, because Lune's real clock also advances and the loads
			-- still completed. But an uninstalled seam means Scribe's save
			-- intervals, retry backoff and flush cadence are pinned to wall time
			-- while everything around them fast-forwards -- so a ten-minute run
			-- would see roughly zero of Scribe's own timers fire, and report that
			-- as healthy.
			local uni = newUniverse()
			local server = uni:Server(1)

			expect(server.Bundle.Clock.Now()).to.equal(math.floor(uni.Sched.Now))
			local before = server.Bundle.Clock.Monotonic()
			uni:Run(300)
			-- Exactly the elapsed virtual time. A real timer would add its own
			-- microseconds and never land on a round number.
			expect(server.Bundle.Clock.Monotonic() - before).to.equal(300)
			expect(server.Bundle.Clock.Now()).to.equal(math.floor(uni.Sched.Now))
		end)

		it("starts SCRIBE's threads on the simulation scheduler", function()
			-- The other half of the same hole. A thread Scribe starts through an
			-- uninstalled Sched seam runs on the host scheduler, where the
			-- simulation can neither order it nor account for it.
			local uni = newUniverse()
			local server = uni:Server(1)

			local ranOn = nil
			server.Bundle.Sched.Spawn(function()
				ranOn = coroutine.running()
			end)
			expect(ranOn).never.to.equal(nil)
			-- Spawn is immediate, and the kernel knows the thread it started.
			expect(uni.Sched._known[ranOn]).to.equal(true)
		end)

		it("stops ticking a crashed server", function()
			-- A crash is not a shutdown: the server simply stops existing. Its
			-- autosave engine hangs off Heartbeat, so a crashed server that kept
			-- ticking would keep saving -- and the session locks it holds would be
			-- released tidily, which is the opposite of what a crash leaves behind.
			local uni = newUniverse()
			local server = uni:Server(1)
			local player = FakePlayer.new(400)

			server:Join(400, player)
			uni:Run(30)
			server.Bundle.Data.Get(player).Coins.Set(77)

			uni:Crash(1)
			local writesAtCrash = uni.Disk.Stats.Writes
			uni:Run(300) -- ten autosave periods

			expect(uni.Disk.Stats.Writes).to.equal(writesAtCrash)
			-- ...and the lock it held is still on disk for someone else to steal.
			local record = uni.Disk.Keyspace:Read("Default", "PLAYER_400")
			expect(record.Value.MetaData.ActiveSession).never.to.equal(nil)
		end)

		it("puts the shared DataStoreService back on reset", function()
			-- The shim's DataStoreService is a process singleton that every spec
			-- shares. A simulation that installed a disk and did not remove it would
			-- hand its keyspace to whichever spec happens to sort next -- and
			-- LeaderboardMode asserts specifically on the UNINSTALLED shim erroring.
			local uni = newUniverse()
			expect(uni).never.to.equal(nil)
			Guard.Reset()
			universe = nil

			local ok, err = pcall(function()
				return game:GetService("DataStoreService"):GetDataStore("Anything")
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "not available headless", 1, true) ~= nil).to.equal(true)
		end)

		it("keeps each server's Health counters to itself", function()
			-- Health is module-level state in Scribe, and a handful of failures in a
			-- minute flips a bundle to Outage -- which gates the money paths. Shared
			-- across simulated servers, one server's throttling would blind the
			-- whole fleet at exactly the CCU worth studying.
			local uni = newUniverse({ Servers = 2 })
			expect(uni:Server(1).Bundle.Health).never.to.equal(uni:Server(2).Bundle.Health)
			expect(uni:Server(1).Bundle.Data).never.to.equal(uni:Server(2).Bundle.Data)
		end)
	end)
end
