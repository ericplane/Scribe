--!nonstrict
-- A crashed server is GONE. Nothing it subscribed to may still reach it.
--
-- This is a spec about the simulation itself, and it earns its place because the
-- harness was lying in the one direction a harness must never lie: making failures
-- look survivable. Server.Crash set `Dead = true`, emptied the player table and
-- stopped there. Dead is read by Frame and Heartbeat, so the crashed server stopped
-- being STEPPED -- but its ProfileStore lives in the SHARED scheduler and its
-- MessagingService subscriptions were never disconnected. So the corpse kept
-- receiving bus traffic, kept answering ProfileStore's session-steal nudge, and
-- could perform a release save after the machine it ran on was supposed to be gone.
--
-- The cost is not hypothetical. A crash-recovery row read green because a dead
-- server tidily handed its lock over, which is the exact opposite of what a crash
-- leaves behind -- and it stayed green until an auditor forced BusDropRate = 1.0 by
-- hand and watched it change. Every spec written in this area inherits that until
-- the harness is fixed, so the harness gets a spec of its own.
--
-- TWO LEVELS, DELIBERATELY. The first asserts the mechanism directly, so a
-- regression names itself instead of surfacing as some distant contention spec
-- going strange. The second asserts the consequence through the real store, which
-- is the part that actually matters and the part a mechanism test cannot cover.
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

	-- Shortened deadlines, same as SimContention's: conflict resolution and
	-- dead-session recovery are reachable at production values, but a bounded run
	-- gets there faster with these.
	local CONSTANTS = {
		AUTO_SAVE_PERIOD = 20,
		SESSION_STEAL = 10,
		FIRST_LOAD_REPEAT = 2,
		LOAD_REPEAT_PERIOD = 3,
		ASSUME_DEAD = 60,
		START_SESSION_TIMEOUT = 120,
	}

	local universe

	local function newUniverse()
		universe = Universe.new({
			Seed = 8181,
			Servers = 2,
			Constants = CONSTANTS,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
		})
		Guard.Install(universe)
		return universe
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("Server.Crash", function()
		it("severs the message bus, in both directions", function()
			local uni = newUniverse()
			local dead, alive = uni:Server(1), uni:Server(2)

			local heardByDead, heardByAlive = 0, 0
			uni.Sched:Spawn(function()
				dead.Env.Services.MessagingService:SubscribeAsync("SEVER_TOPIC", function()
					heardByDead += 1
				end)
				alive.Env.Services.MessagingService:SubscribeAsync("SEVER_TOPIC", function()
					heardByAlive += 1
				end)
			end)
			uni:Run(5)

			-- Before the crash both hear it. Without this the assertion after the
			-- crash is vacuous: a bus that delivered nothing at all would pass it.
			uni.Sched:Spawn(function()
				alive.Env.Services.MessagingService:PublishAsync("SEVER_TOPIC", { N = 1 })
			end)
			uni:Run(20)
			expect(heardByDead).to.equal(1)
			expect(heardByAlive).to.equal(1)

			uni:Crash(1)

			uni.Sched:Spawn(function()
				alive.Env.Services.MessagingService:PublishAsync("SEVER_TOPIC", { N = 2 })
			end)
			uni:Run(20)
			-- The living subscriber still hears everything: severing is per-server,
			-- not a global mute.
			expect(heardByAlive).to.equal(2)
			expect(heardByDead).to.equal(1)

			-- Outbound too. A process that can still publish but not receive models no
			-- machine that has ever existed, and a dead server that can publish can
			-- still nudge a live one into saving.
			uni.Sched:Spawn(function()
				dead.Env.Services.MessagingService:PublishAsync("SEVER_TOPIC", { N = 3 })
			end)
			uni:Run(20)
			expect(heardByAlive).to.equal(2)

			-- And a subscribe attempted by a thread that outlived the crash does not
			-- put the corpse back on the bus.
			local heardAfterResubscribe = 0
			uni.Sched:Spawn(function()
				dead.Env.Services.MessagingService:SubscribeAsync("SEVER_TOPIC", function()
					heardAfterResubscribe += 1
				end)
			end)
			uni:Run(5)
			uni.Sched:Spawn(function()
				alive.Env.Services.MessagingService:PublishAsync("SEVER_TOPIC", { N = 4 })
			end)
			uni:Run(20)
			expect(heardAfterResubscribe).to.equal(0)
		end)

		it("stops a dead server answering another server's session steal", function()
			-- The consequence, through the real store. ProfileStore resolves a session
			-- conflict by publishing `{ EndSession = true }` to the current holder's
			-- topic; the holder's subscription answers it by ending its session and
			-- writing a final release save. That is correct between two LIVE servers
			-- and it is the whole point of the fast path.
			--
			-- A crashed holder must not answer, and the difference is not cosmetic: a
			-- corpse that cooperates hands its lock over in seconds, so every spec
			-- about recovering a crashed server's lock silently stops exercising the
			-- ASSUME_DEAD deadline it claims to be about.
			local uni = newUniverse()
			local dead, alive = uni:Server(1), uni:Server(2)

			local player = FakePlayer.new(801)
			dead:Join(801, player)
			uni:Run(30)
			expect(dead.Bundle.Data.GetState(player)).to.equal("Ready")

			uni:Crash(1)
			-- Frozen mid-session, which is what a crash leaves: the entry is still
			-- Ready in the dead server's memory because nothing tore it down.
			expect(dead.Bundle.Data.GetState(player)).to.equal("Ready")

			-- The other server picks the player up and starts contending for the lock.
			-- ProfileStore republishes the nudge on every load repeat
			-- (LOAD_REPEAT_PERIOD = 3s) and the bus delivers in ~1.5s, so this window
			-- holds several deliveries -- while staying inside SESSION_STEAL, so the
			-- lock cannot yet have been taken by force. A dead server that answers has
			-- had every chance to.
			alive:Join(801, FakePlayer.new(801))
			uni:Run(9)

			-- Nothing on the dead server may have run. Its session ending here would
			-- mean its ProfileStore woke up, answered the nudge and wrote to the disk
			-- from a machine that no longer exists.
			expect(dead.Bundle.Data.GetState(player)).to.equal("Ready")
			local record = uni.Disk.Keyspace:Read("Default", "PLAYER_801")
			expect(record.Value.MetaData.ActiveSession).never.to.equal(nil)
			expect(record.Value.MetaData.ActiveSession[2]).to.equal(dead.JobId)

			-- The lock is still recoverable, just not by cooperation: only the
			-- ASSUME_DEAD deadline can take it, which is exactly the path a crash is
			-- supposed to force.
			uni:Run(200)
			local later = uni.Disk.Keyspace:Read("Default", "PLAYER_801")
			expect(later.Value.MetaData.ActiveSession[2]).to.equal(alive.JobId)
			-- Still frozen, even now. Nothing ever reaches the corpse, so its own view
			-- of the world never changes -- which is what a crashed machine looks like.
			expect(dead.Bundle.Data.GetState(player)).to.equal("Ready")
		end)
	end)
end
