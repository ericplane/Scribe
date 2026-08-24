--!nonstrict
-- The overlapping-save Dirty clobber, driven against the REAL vendored store with
-- two saves genuinely on the wire at once.
--
-- OverlappingSaveDirtyClobber asks the same question of the fake harness, and has
-- to construct the interleaving by firing OnSave/OnSettled/OnError by hand, because
-- that store persists synchronously and cannot hold two saves open. That is enough
-- to pin the logic and it is what the existing OverlappingSaveFailure does -- but it
-- is a reconstruction of the ordering, not the ordering itself.
--
-- Here nothing is reconstructed. `Profile:Save()` task.spawns SaveProfileAsync,
-- which fires OnSave synchronously on entry and only then yields into UpdateAsync --
-- which is exactly why the overlap is DETERMINISTIC rather than rare, and why the
-- capture the second save takes is of a flag the first one has already cleared. Two
-- calls, modelled latency underneath, an armed fault standing in for the burst that
-- takes both round trips, and the assertion is on what the entry says afterwards.
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

	local function stored(uni, key: string)
		local record = uni.Disk.Keyspace:Read("Default", key)
		return record and record.Value and record.Value.Data
	end

	local function build()
		universe = Universe.new({
			Seed = 20260822,
			Servers = 1,
			-- Autosave pushed well past the run so the only saves in the window are
			-- the two this spec issues: a third, unaccounted save would make "two in
			-- flight" a coincidence rather than a construction.
			Constants = { AUTO_SAVE_PERIOD = 600, SESSION_STEAL = 400, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			-- Slow, because the whole scenario lives inside the round trip. A short
			-- one can close before the second save has even started.
			LatencyProfile = "Slow",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {},
		})
		Guard.Install(universe)
		return universe, universe:Server(1)
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("two real saves in flight, and a burst that takes both", function()
		it("leaves the entry dirty for the write that never reached the key", function()
			local uni, server = build()
			local Persistence = server.Bundle.Ctx.Persistence
			local player = FakePlayer.new(69201)
			server:Join(69201, player)
			uni:Run(20)

			local entry = Persistence.EntryFor(player)
			local data = server.Bundle.Data.Get(player)

			-- The write that must survive the failure. It exists only in the live tree.
			data.Coins.Set(4242)
			expect(entry.SaveInfo.Dirty).to.equal(true)

			-- BOTH round trips on this key fail, and that is the scenario rather than a
			-- convenience. DataStore errors arrive in bursts -- a throttle or a
			-- partial outage takes every call on a key for as long as it lasts -- and
			-- if one of two overlapping saves SUCCEEDS it persists the write anyway
			-- (its payload is read by reference at UpdateAsync time, so it carries
			-- everything the earlier one did). Measured on the way to this spec: with
			-- Count = 1 the surviving save stored the 4242 and the entry ended
			-- LastResult = "Ok" -- correctly clean, and nothing to assert. The loss
			-- needs the case where nothing lands, which is the case the burst gives.
			-- Nothing else on the disk is faulted, so only the saves under test can
			-- consume these.
			uni.Disk:Arm({ Kind = "ServiceError", Op = "UpdateAsync", Key = entry.Key, Count = 2 })

			-- Two saves, back to back. Each spawns its own SaveProfileAsync.
			entry.Profile:Save()
			entry.Profile:Save()

			-- Step just far enough for both to have taken their payload snapshot and
			-- parked in the round trip. This is the state the whole defect lives in,
			-- and it is asserted rather than assumed: if the store ever stops
			-- overlapping, this says so here instead of passing quietly below.
			local overlapped = false
			for _ = 1, 200 do
				uni:Run(0.01)
				if (entry.SavesInFlight or 0) >= 2 then
					overlapped = true
					break
				end
			end
			expect(`overlapped={overlapped}`).to.equal("overlapped=true")
			-- ...and the second snapshot found the flag the first one had cleared.
			expect(entry.SaveInfo.Dirty).to.equal(false)

			-- Let both round trips come back.
			uni:Run(60)
			expect(entry.SavesInFlight).to.equal(0)

			-- Neither payload persisted, so the 4242 is still only in memory.
			expect(entry.SaveInfo.LastResult).to.equal("Fail")
			local onKey = stored(uni, entry.Key)
			expect(`storedCoins={onKey and onKey.Coins}`).never.to.equal("storedCoins=4242")

			-- ...so the entry has to say the live tree still differs from the key.
			-- Under an unconditional per-save capture this reads false: the second
			-- save's snapshot overwrote the first's `true` with the `false` the first
			-- had just written, and every restore then evaluated `false or false`.
			-- Monetization acknowledges a duplicate receipt off exactly this flag.
			expect(entry.SaveInfo.Dirty).to.equal(true)
		end)
	end)
end
