--!nonstrict
-- What ProfileStore's MessagingService fast-release is actually worth, measured.
--
-- This file settles a live design question rather than guarding a regression. The
-- audit's §5 argued that 40-second lease renewal buys insurance against a failure
-- mode nobody has quantified, at 7.5x the write traffic, and proposed the cheap
-- measurement that would decide it: count contested handoffs ending through the
-- message path against those ending by the incumbent's own polling. Below ~90%
-- and the lease argument becomes real.
--
-- Running it changed the shape of the question. Measured, at production
-- constants, the same contested handoff with the bus healthy and with every
-- message dropped:
--
--                     acquired   incumbent released   challenger sees   stored
--   message path OK      6.0s      6.0s ("External")       4242          4242
--   message path DEAD   46.0s      never                      0             0
--
-- The message path is not merely FASTER. Without it the incumbent is never told,
-- so it performs no final save at all -- the challenger force-loads after
-- SESSION_STEAL and the incumbent's writes since its last autosave are gone. At
-- the production AUTO_SAVE_PERIOD of 300s that is up to five minutes of play, and
-- it is silent: IsActive() is false on the loser either way, so nothing
-- downstream can tell a clean handoff from a lossy one.
--
-- That is a stronger reason to care about the message path than latency was, and
-- it is also why the telemetry §5 asked for has to be built differently -- see
-- the second test.

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

	-- PRODUCTION values, deliberately, unlike every other sim spec. The output of
	-- this file is a pair of durations in seconds; shortened constants would make
	-- those numbers describe a fleet nobody runs.
	local PRODUCTION = {
		AUTO_SAVE_PERIOD = 300,
		SESSION_STEAL = 40,
		FIRST_LOAD_REPEAT = 5,
		LOAD_REPEAT_PERIOD = 10,
		ASSUME_DEAD = 630,
		START_SESSION_TIMEOUT = 120,
	}

	local universe

	local function newUniverse(busDropRate: number)
		universe = Universe.new({
			Seed = 991155,
			Servers = 2,
			Constants = PRODUCTION,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			BusDropRate = busDropRate,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
		})
		Guard.Install(universe)
		return universe
	end

	--- One contested handoff.
	---
	--- `busDropRate = 1.0` models exactly the case the lease argument is about: the
	--- incumbent is ALIVE and reaching DataStores and simply never hears the
	--- challenger. When an incumbent is genuinely dead there is no dual ownership to
	--- shorten, because nobody is writing.
	local function handoff(busDropRate: number)
		local uni = newUniverse(busDropRate)
		local a, b = uni:Server(1), uni:Server(2)

		local incumbent = FakePlayer.new(90001)
		a:Join(90001, incumbent)
		uni:Run(60)

		local entryA = a.Bundle.Ctx.Persistence.EntryFor(incumbent)
		expect(entryA).never.to.equal(nil)
		-- Written and NOT flushed. This is the tail of play a handoff either carries
		-- or loses, and it is the whole point of the comparison.
		a.Bundle.Data.Get(incumbent).Coins.Set(4242)

		local reason = nil
		entryA.Profile.OnLastSave:Connect(function(why)
			reason = reason or why
		end)

		local challenger = FakePlayer.new(90001)
		local startedAt = uni.Sched.Now
		b:Join(90001, challenger)

		-- Sampled during the run, not read at the end: teardown removes the entry
		-- from Persistence and a later read can miss the flag it is asked about.
		local stolenSeen = nil
		local acquiredAt = nil
		for _ = 1, 900 do
			uni:Run(1)
			if stolenSeen == nil and entryA.SessionStolen ~= nil then
				stolenSeen = entryA.SessionStolen
			end
			-- State, not merely the entry existing: EntryFor answers as soon as the
			-- load STARTS, so an existence check would time the challenger deciding to
			-- contend rather than the incumbent letting go.
			local pending = b.Bundle.Ctx.Persistence.EntryFor(challenger)
			if pending ~= nil and pending.State == "Ready" then
				acquiredAt = uni.Sched.Now - startedAt
				break
			end
		end

		-- The loser's teardown is asynchronous: OnSessionEnd can land after the
		-- winner is already Ready. Bounded at 20s and well under AUTO_SAVE_PERIOD, so
		-- the no-message arm cannot quietly acquire a release it would not have had
		-- at the measured moment.
		for _ = 1, 20 do
			if stolenSeen ~= nil then
				break
			end
			uni:Run(1)
			if entryA.SessionStolen ~= nil then
				stolenSeen = entryA.SessionStolen
			end
		end

		return {
			Seconds = acquiredAt,
			Reason = reason,
			SessionStolen = stolenSeen,
			BusDelivered = uni.Bus.Stats.Delivered,
			BusDropped = uni.Bus.Stats.Dropped,
			Coins = if acquiredAt then b.Bundle.Data.Get(challenger).Coins.Get() else nil,
			Stored = (function()
				local record = uni.Disk.Keyspace:Read("Default", "PLAYER_90001")
				return record and record.Value and record.Value.Data and record.Value.Data.Coins
			end)(),
		}
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("contested session handoff", function()
		it("carries the incumbent's tail of play only when the message path works", function()
			local withBus = handoff(0.0)
			Guard.Reset()
			local withoutBus = handoff(1.0)

			print(
				string.format(
					"      [handoff] message path OK: %.0fs, challenger sees %s  |  DEAD: %.0fs, challenger sees %s",
					withBus.Seconds or -1,
					tostring(withBus.Coins),
					withoutBus.Seconds or -1,
					tostring(withoutBus.Coins)
				)
			)

			-- Both terminate. The message path is an optimisation on a mechanism that
			-- already completes, not the mechanism itself.
			expect(withBus.Seconds).never.to.equal(nil)
			expect(withoutBus.Seconds).never.to.equal(nil)

			-- The bus is genuinely live in one arm and genuinely dead in the other; a
			-- comparison between two identical arms would pass on anything.
			expect(withBus.BusDelivered > 0).to.equal(true)
			expect(withoutBus.BusDelivered).to.equal(0)
			expect(withoutBus.BusDropped > 0).to.equal(true)

			-- Faster, by a lot: measured 6s against 46s. The bounds are expressed
			-- against SESSION_STEAL rather than as literals, because the exact figures
			-- are properties of the seed and the latency profile while the ordering
			-- around that constant is what the design question turns on.
			expect(withBus.Seconds < withoutBus.Seconds).to.equal(true)
			expect(withBus.Seconds < PRODUCTION.SESSION_STEAL).to.equal(true)
			expect(withoutBus.Seconds >= PRODUCTION.SESSION_STEAL).to.equal(true)

			-- AND LOSSLESS. The incumbent hears, saves, and hands over: the challenger
			-- reads the value written a moment before the contest started.
			expect(withBus.Reason).to.equal("External")
			expect(withBus.Coins).to.equal(4242)
			expect(withBus.Stored).to.equal(4242)

			-- Without the message the incumbent is never told, so it never saves. The
			-- challenger gets the last autosaved state and the tail is gone. This is
			-- the finding: the cost of a dead message path is data, not seconds.
			expect(withoutBus.Reason).to.equal(nil)
			expect(withoutBus.Coins).to.equal(0)
			expect(withoutBus.Stored).to.equal(0)
		end)

		it("locates the telemetry on the winning server, because the loser learns nothing", function()
			-- The correction to the proposed instrument, measured rather than argued.
			--
			-- The audit proposed counting handoffs that end via OnLastSave with reason
			-- "External" against those that end by autosave-detected ForceLoadSession.
			-- Three measured problems, in increasing order of how much they matter:
			--
			--   1. Scribe connects Profile.OnLastSave nowhere in src/ today, so the
			--      numerator does not exist.
			--   2. A bare count of "External" events has no denominator.
			--   3. The obvious denominator does not work. entry.SessionStolen
			--      (src/Server/Persistence.luau:2181) looks like it counts every contested
			--      handoff -- and it does, eventually. But measured below, it is set
			--      promptly ONLY in the arm where the message path worked. In the arm
			--      where it did not, the losing server is still not aware more than a
			--      minute after the challenger has taken over. So both the numerator and
			--      the denominator go missing together in exactly the case the ratio
			--      exists to detect, and the counter would read 100% on a fleet whose
			--      MessagingService was completely dead.
			--
			-- The instrument therefore has to live on the WINNING server, which knows both
			-- halves at the moment of acquisition: it contested, and it can time how long
			-- StartSessionAsync took. Under SESSION_STEAL means the incumbent cooperated;
			-- at or over it means the challenger force-loaded and the message never
			-- arrived. The first test above asserts exactly that separation holds.
			--
			-- Not applied to src/ here: this tier is a test-tree tier and Persistence.luau
			-- is being worked concurrently. The change is a duration around the load and
			-- one comparison.
			local withBus = handoff(0.0)
			Guard.Reset()
			local withoutBus = handoff(1.0)

			-- The loser's view: informed in one case, oblivious in the other.
			expect(withBus.SessionStolen).to.equal(true)
			expect(withBus.Reason).to.equal("External")
			expect(withoutBus.SessionStolen).to.equal(nil)
			expect(withoutBus.Reason).to.equal(nil)

			-- The winner's view: available and decisive in both.
			expect(withBus.Seconds < PRODUCTION.SESSION_STEAL).to.equal(true)
			expect(withoutBus.Seconds >= PRODUCTION.SESSION_STEAL).to.equal(true)
		end)
	end)
end
