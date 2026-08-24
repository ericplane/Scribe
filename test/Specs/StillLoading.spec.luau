--!nonstrict
-- "still-loading" vs "timeout": the wait ran out for two different reasons.
--
-- WaitForData's default wait is 60 seconds. A load is given `LoadTimeout`, which
-- is max(60, LoadTimeout or 120) -- and the 120 is not arbitrary, it matches
-- ProfileStore's own START_SESSION_TIMEOUT, while the 60-second floor clears
-- SESSION_STEAL (40s) so an ordinary cross-server handoff is never aborted as a
-- failure. So there is a 60-to-120-second band in which the default wait expires
-- over a load that is merely slow and is going to succeed.
--
-- It used to report that as "timeout", the same value it reports for a player it
-- has no session for at all. The information was not missing -- Data.GetState
-- answers "Loading" throughout -- it was just absent from where the caller was
-- looking.
--
-- The fix is deliberately NOT a longer default wait. A bounded wait that tells
-- the truth beats a longer one that does not, and the caller who wants to keep
-- waiting can say so. So the two cases now answer differently, and the second
-- spec here is the one that earns the distinction: it shows the very load that
-- reported "still-loading" going on to succeed with real data.

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
			Seed = 60120,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			-- The shipped defaults, spelled out: this whole band exists because the
			-- wait (60) is shorter than the load deadline (120).
			Options = {},
		})
		Guard.Install(universe)
		return universe, universe:Server(1)
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	--- Start a WaitForData on its own scheduler thread and hand back a table that
	--- fills in when it returns. Yielding inside the spec body would block the
	--- virtual clock the wait is measured against.
	local function waitInBackground(uni, Persistence, player, timeout: number?)
		local result = {}
		uni.Sched:Spawn(function()
			local accessor, reason = Persistence.WaitForData(player, timeout)
			result.Done = true
			result.At = uni.Sched.Now
			result.Accessor = accessor
			result.Reason = reason
		end)
		return result
	end

	it("answers still-loading, not timeout, while the load is genuinely in flight", function()
		local uni, server = build()
		local Persistence = server.Bundle.Ctx.Persistence
		-- The load fails and retries: the entry sits in Loading with no state
		-- transition to wake a waiter, so only the deadline can end the wait.
		uni.Disk:Arm({ Kind = "ServiceError", Key = "PLAYER_66001", Count = 1000000 })

		local player = FakePlayer.new(66001)
		server:Join(66001, player)
		local waited = waitInBackground(uni, Persistence, player)

		uni:Run(75) -- past WaitForData's 60s default, inside the 120s load deadline

		expect(waited.Done).to.equal(true)
		expect(waited.Accessor).to.equal(nil)
		expect(waited.Reason).to.equal("still-loading")
		-- And the caller could always have found this out; it just was not in the
		-- reason. Both halves are asserted so the reason cannot drift from the state.
		expect(Persistence.GetState(player)).to.equal("Loading")
	end)

	it("was telling the truth: the same load then succeeds with real data", function()
		-- The half that makes the distinction worth having. If the load never
		-- recovered, "still-loading" would be no more accurate than "timeout".
		local uni, server = build()
		local Persistence = server.Bundle.Ctx.Persistence
		uni.Disk:Arm({ Kind = "ServiceError", Key = "PLAYER_66002", Count = 1000000 })

		local player = FakePlayer.new(66002)
		server:Join(66002, player)
		local waited = waitInBackground(uni, Persistence, player)
		uni:Run(75)
		expect(waited.Reason).to.equal("still-loading")

		uni.Disk:Heal()
		uni:Run(120)

		expect(Persistence.GetState(player)).to.equal("Ready")
		local data = server.Bundle.Data.Get(player)
		expect(data).to.be.ok()
		data.Coins.Set(7)
		expect(data.Coins.Get()).to.equal(7)
	end)

	it("still answers timeout when Scribe has no session for the player at all", function()
		-- The value has to stay reachable, and this is what it now means: not "your
		-- load is slow" but "nothing here is loading you" -- in practice, the bundle
		-- was constructed after this player joined, so OnPlayerAdded never ran.
		local uni, server = build()
		local Persistence = server.Bundle.Ctx.Persistence

		local player = FakePlayer.new(66003) -- deliberately never joined
		local waited = waitInBackground(uni, Persistence, player, 5)
		uni:Run(10)

		expect(waited.Done).to.equal(true)
		expect(waited.Accessor).to.equal(nil)
		expect(waited.Reason).to.equal("timeout")
		expect(Persistence.EntryFor(player)).to.equal(nil)
	end)

	it("keeps the wait bounded, so this is a better answer and not a longer one", function()
		-- The rejected alternative was raising WaitForData's default to match the
		-- load deadline. A caller's own timeout must still be honoured to the
		-- second, or "still-loading" would just be "we hung".
		local uni, server = build()
		local Persistence = server.Bundle.Ctx.Persistence
		uni.Disk:Arm({ Kind = "ServiceError", Key = "PLAYER_66004", Count = 1000000 })

		local player = FakePlayer.new(66004)
		server:Join(66004, player)
		local startedAt = uni.Sched.Now
		local waited = waitInBackground(uni, Persistence, player, 12)
		uni:Run(40)

		expect(waited.Reason).to.equal("still-loading")
		-- Returned on the CALLER'S deadline, not on the load's: 12 seconds, not 60
		-- and not 120. Asserted as a window rather than an equality because the
		-- resume is deferred by one scheduler turn on purpose (see
		-- waitStateChangedUntil), so the exact instant is the scheduler's business.
		local elapsed = waited.At - startedAt
		expect(`elapsed={elapsed >= 12 and elapsed < 20}`).to.equal("elapsed=true")
		expect(Persistence.GetState(player)).to.equal("Loading")
	end)

	it("exports the reason as a constant alongside the rest", function()
		expect(Scribe.Reason.StillLoading).to.equal("still-loading")
		-- The set is frozen and shared by every bundle in the process.
		expect(table.isfrozen(Scribe.Reason)).to.equal(true)
	end)
end
