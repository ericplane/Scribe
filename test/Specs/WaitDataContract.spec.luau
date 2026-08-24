--!nonstrict
-- CHARACTERISATION. What a caller of Data.WaitForData observes, pinned before a
-- rewrite of waitStateChangedUntil's wake mechanism that was then declined.
--
-- WaitForData is the documented join path -- PlayerAdded -> WaitForData -> read --
-- and it is the only place in Scribe where game code parks on Scribe's own
-- scheduling. Its answer is a two-value contract: an accessor and a reason, never
-- both, and the reason set is closed (Types.LifecycleReason). Everything below is
-- written about THAT contract rather than about how the wake is delivered. The
-- delivery did not change in the end: the site costs one rung per load and gives it
-- back at the load's own yield, measured at slope=0.000, so the rewrite was not worth
-- its risk. Do not revive it. See test/Sim/Available.luau for the readings and the
-- comment at waitStateChangedUntil for why an inline resume breaks ReadyOrdering.
--
-- The one exception is deliberate and is the reason this file exists at all.
-- waitStateChangedUntil carries a comment saying control must never be handed back
-- from INSIDE setState: signals dispatch synchronously and Sched.Resume is
-- task.spawn, so an inline wake would return the caller from the middle of
-- finishLoad -- before the cross-server message handler is registered and before
-- the monetization, leaderboard and replication hooks have run. The session would
-- say "Ready" and not be. That is an ORDERING guarantee, not an implementation
-- detail, so it is pinned here with two independent probes taken at the instant
-- WaitForData returns (see "the session is wired before a woken caller returns").
--
-- One branch is deliberately NOT pinned here, and the omission is a finding rather
-- than an oversight. WaitForData's `entry.State == "SessionEnded"` arm is UNREACHABLE
-- today: teardown removes the entry from Entries before the deferred wake runs, so a
-- woken caller always answers from the stored end reason instead. Measured -- replacing
-- that arm's return with a nonsense string leaves the whole suite green. An inline wake
-- makes it reachable, which moves the answer's source without changing its value
-- (teardown writes both from one `canonical`). The specs below assert the VALUE, so
-- they hold either way; nothing asserts the branch, because nothing can.
--
-- Method note: every wait that can actually park runs on its own spawned thread.
-- Parking a wait on the spec body's thread works, but it makes the assertion
-- depend on the runner's own thread rather than on Scribe, and a wait that hangs
-- then takes the whole test file down with it rather than failing one assertion.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local TEMPLATE = { Coins = Scribe.Int(0, { Min = 0 }) }

	--- Start a WaitForData on its own thread; the returned table fills in when it
	--- answers. `Probe` runs on the waiter's thread the instant WaitForData
	--- returns, before anything else can run, which is the only place an ordering
	--- claim about the wake can be observed.
	local function waitAsync(Persistence, player, timeout: number?, probe: ((any) -> ())?)
		local result = { Done = false, StartedAt = os.clock() }
		task.spawn(function()
			local accessor, reason = Persistence.WaitForData(player, timeout)
			result.Accessor = accessor
			result.Reason = reason
			if probe then
				probe(result)
			end
			result.Elapsed = os.clock() - result.StartedAt
			result.Done = true
		end)
		return result
	end

	--- Let the scheduler run until the wait answers, bounded well inside the
	--- runner's per-test budget so a hang fails an assertion rather than the file.
	local function pump(result, seconds: number?)
		local deadline = os.clock() + (seconds or 4)
		while not result.Done and os.clock() < deadline do
			task.wait()
		end
		return result
	end

	--- How many handlers are attached to an entry's StateChanged. Nothing in Scribe
	--- connects to it except a parked waiter, so this reads zero whenever no wait is
	--- in progress -- which is what makes "the wait cleaned up after itself"
	--- assertable at all.
	local function listenerCount(signal): number
		local n = 0
		local item = signal._head
		while item do
			n += 1
			item = item._next
		end
		return n
	end

	--- A harness whose loads park the waiter for real. The fake store is
	--- synchronous by default, which makes the window every ordering claim lives in
	--- zero-width; production yields on every join.
	local function parkingHarness()
		local harness = TestCtx.make({ Template = TEMPLATE })
		harness.Fake.YieldOnSessionStart = true
		return harness
	end

	--- A harness whose loads stick in Loading with no state transition to wake
	--- anyone: the first attempt fails and "Wait" parks the loader in a retry
	--- backoff, so only the caller's own deadline can end a wait.
	local function stuckHarness()
		local harness = TestCtx.make({ Template = TEMPLATE, Options = { LoadFailurePolicy = "Wait" } })
		harness.Fake.FailNextLoad = true
		return harness
	end

	describe("data that is already here", function()
		it("answers immediately when the session is already Ready", function()
			local harness = TestCtx.make({ Template = TEMPLATE })
			local player, _entry, joined = harness.Join()

			-- Timeout zero, deliberately: a Ready session is never subject to the
			-- deadline, so the answer cannot be "still-loading" or "timeout" however
			-- little patience the caller has.
			local accessor, reason = harness.Ctx.Persistence.WaitForData(player, 0)
			expect(accessor).to.be.ok()
			expect(reason).to.equal(nil)
			-- The same tree, not a copy: what WaitForData hands back IS the session.
			expect(accessor).to.equal(joined)
			expect(accessor.Coins.Get()).to.equal(0)

			harness.Cleanup()
		end)

		it("agrees with Data.Get and with the public Data.WaitForData", function()
			local harness = TestCtx.make({ Template = TEMPLATE })
			local player, _entry, joined = harness.Join()

			expect(harness.Data.Get(player)).to.equal(joined)
			local accessor, reason = harness.Data.WaitForData(player, 0.05)
			expect(accessor).to.equal(joined)
			expect(reason).to.equal(nil)

			harness.Cleanup()
		end)
	end)

	describe("data that arrives during the wait", function()
		it("wakes a parked caller with the accessor when the load lands", function()
			local harness = parkingHarness()
			local player = FakePlayer.new()
			harness.Ctx.Persistence.OnPlayerAdded(player)
			-- The premise: the caller really does park, rather than taking the
			-- already-Ready branch above.
			expect(harness.Ctx.Persistence.GetState(player)).to.equal("Loading")

			local waited = pump(waitAsync(harness.Ctx.Persistence, player))

			expect(waited.Done).to.equal(true)
			expect(waited.Reason).to.equal(nil)
			expect(waited.Accessor).to.be.ok()
			-- Usable, not merely non-nil.
			expect(waited.Accessor.Coins.Get()).to.equal(0)
			expect(harness.Ctx.Persistence.GetState(player)).to.equal("Ready")

			harness.Leave(player)
			harness.Cleanup()
		end)

		it("wakes every parked caller, not only the first", function()
			-- Three independent waits on one load. A wake mechanism that claims the
			-- transition for one waiter would leave the other two parked until their
			-- own 60-second deadlines, which the pump below will not sit through.
			local harness = parkingHarness()
			local player = FakePlayer.new()
			harness.Ctx.Persistence.OnPlayerAdded(player)

			local a = waitAsync(harness.Ctx.Persistence, player)
			local b = waitAsync(harness.Ctx.Persistence, player)
			local c = waitAsync(harness.Ctx.Persistence, player)
			pump(a)
			pump(b)
			pump(c)

			expect(`{a.Done} {b.Done} {c.Done}`).to.equal("true true true")
			expect(`{a.Reason} {b.Reason} {c.Reason}`).to.equal("nil nil nil")
			-- One session, so all three must be holding the same tree.
			expect(a.Accessor).to.be.ok()
			expect(b.Accessor).to.equal(a.Accessor)
			expect(c.Accessor).to.equal(a.Accessor)

			harness.Leave(player)
			harness.Cleanup()
		end)

		it("has finished wiring the session before a woken caller returns", function()
			-- THE ORDERING GUARANTEE. Both probes are taken on the waiter's own thread
			-- at the instant WaitForData returns, and both sit AFTER setState("Ready")
			-- in finishLoad: the load counter on the line below it, and the
			-- cross-server message handler a few lines further on. A caller resumed
			-- from inside setState sees neither, and would be reading a session that
			-- says Ready and is not.
			local harness = parkingHarness()
			local player = FakePlayer.new()
			local loadedBefore = (Scribe.GetMetrics().ProfilesLoaded or 0)
			harness.Ctx.Persistence.OnPlayerAdded(player)
			expect(harness.Ctx.Persistence.GetState(player)).to.equal("Loading")

			local waited = pump(waitAsync(harness.Ctx.Persistence, player, nil, function(result)
				local entry = harness.Ctx.Persistence.EntryFor(player)
				result.State = entry and entry.State
				result.Handlers = entry and entry.Profile and entry.Profile.HandlerCount or 0
				result.Loaded = (Scribe.GetMetrics().ProfilesLoaded or 0)
			end))

			expect(waited.Done).to.equal(true)
			expect(waited.Accessor).to.be.ok()
			expect(waited.State).to.equal("Ready")
			expect(`handlers={waited.Handlers > 0}`).to.equal("handlers=true")
			expect(`counted={waited.Loaded > loadedBefore}`).to.equal("counted=true")

			harness.Leave(player)
			harness.Cleanup()
		end)

		it("leaves nothing connected to the entry once it has answered", function()
			local harness = parkingHarness()
			local player = FakePlayer.new()
			harness.Ctx.Persistence.OnPlayerAdded(player)
			local entry = harness.Ctx.Persistence.EntryFor(player)
			expect(listenerCount(entry.StateChanged)).to.equal(0)

			local waited = pump(waitAsync(harness.Ctx.Persistence, player))
			expect(waited.Accessor).to.be.ok()

			-- A wait is a bounded borrow of the entry's state signal. Left connected,
			-- every join in a session's lifetime accumulates a handler on a signal that
			-- fires on every transition.
			expect(listenerCount(entry.StateChanged)).to.equal(0)

			harness.Leave(player)
			harness.Cleanup()
		end)
	end)

	describe("the session ending during the wait", function()
		it("answers player-left when the player goes while the load is in flight", function()
			local harness = parkingHarness()
			local player = FakePlayer.new()
			harness.Ctx.Persistence.OnPlayerAdded(player)
			local waited = waitAsync(harness.Ctx.Persistence, player)
			expect(waited.Done).to.equal(false) -- parked, not answered

			harness.Leave(player)
			pump(waited)

			expect(waited.Done).to.equal(true)
			expect(waited.Accessor).to.equal(nil)
			expect(waited.Reason).to.equal(Scribe.Reason.PlayerLeft)

			harness.Cleanup()
		end)

		it("answers load-failed when the load fails while a caller is parked", function()
			-- The reason has to travel the wake path intact. Under the default Kick
			-- policy a failed load is terminal, so this is the caller's whole answer.
			local harness = parkingHarness()
			harness.Fake.FailNextLoad = true
			local player = FakePlayer.new()
			harness.Ctx.Persistence.OnPlayerAdded(player)
			local waited = waitAsync(harness.Ctx.Persistence, player)
			expect(waited.Done).to.equal(false)

			pump(waited)

			expect(waited.Done).to.equal(true)
			expect(waited.Accessor).to.equal(nil)
			expect(waited.Reason).to.equal(Scribe.Reason.LoadFailed)

			harness.Cleanup()
		end)
	end)

	describe("the caller's own deadline", function()
		it("returns still-loading on the deadline while the load is genuinely in flight", function()
			local harness = stuckHarness()
			local player = FakePlayer.new()
			harness.Ctx.Persistence.OnPlayerAdded(player)
			expect(harness.Ctx.Persistence.GetState(player)).to.equal("Loading")

			local waited = pump(waitAsync(harness.Ctx.Persistence, player, 0.25))

			expect(waited.Done).to.equal(true)
			expect(waited.Accessor).to.equal(nil)
			expect(waited.Reason).to.equal(Scribe.Reason.StillLoading)
			-- Bounded by the CALLER'S timeout, not by the load's. Asserted as a window:
			-- the wake's exact instant is the scheduler's business, the bound is not.
			expect(`bounded={waited.Elapsed >= 0.2 and waited.Elapsed < 3}`).to.equal("bounded=true")
			-- The reason is not a guess -- the state says the same thing.
			expect(harness.Ctx.Persistence.GetState(player)).to.equal("Loading")

			harness.Leave(player) -- tear the stuck entry down; the retry exits on Stop
			harness.Cleanup()
		end)

		it("is finished with the entry when it gives up, and a second wait works the same", function()
			-- A wait that ended on its deadline must be settled: it does not stay
			-- connected waiting for a transition it will never report, and it has not
			-- poisoned the entry for the next caller.
			local harness = stuckHarness()
			local player = FakePlayer.new()
			harness.Ctx.Persistence.OnPlayerAdded(player)
			local entry = harness.Ctx.Persistence.EntryFor(player)

			local first = pump(waitAsync(harness.Ctx.Persistence, player, 0.2))
			expect(first.Reason).to.equal(Scribe.Reason.StillLoading)
			expect(listenerCount(entry.StateChanged)).to.equal(0)

			local second = pump(waitAsync(harness.Ctx.Persistence, player, 0.2))
			expect(second.Reason).to.equal(Scribe.Reason.StillLoading)
			expect(second.Accessor).to.equal(nil)
			expect(listenerCount(entry.StateChanged)).to.equal(0)

			harness.Leave(player)
			harness.Cleanup()
		end)

		it("distinguishes still-loading from timeout: two questions, two answers", function()
			-- The distinction is the whole reason the reason exists. "still-loading"
			-- means a load is in flight and may yet succeed; "timeout" means Scribe has
			-- no session for this player at all. Both are asserted in one test so the
			-- pair cannot drift into agreeing with each other.
			local harness = stuckHarness()
			local loading = FakePlayer.new()
			harness.Ctx.Persistence.OnPlayerAdded(loading)
			local absent = FakePlayer.new() -- never passed to OnPlayerAdded

			local a = pump(waitAsync(harness.Ctx.Persistence, loading, 0.25))
			local b = pump(waitAsync(harness.Ctx.Persistence, absent, 0.25))

			expect(a.Reason).to.equal(Scribe.Reason.StillLoading)
			expect(b.Reason).to.equal(Scribe.Reason.Timeout)
			expect(`differ={a.Reason ~= b.Reason}`).to.equal("differ=true")
			expect(harness.Ctx.Persistence.EntryFor(loading)).to.be.ok()
			expect(harness.Ctx.Persistence.EntryFor(absent)).to.equal(nil)

			harness.Leave(loading)
			harness.Cleanup()
		end)
	end)

	describe("no session at all", function()
		it("answers timeout for a player in the game that Scribe has no entry for", function()
			-- In practice: the bundle was constructed after they joined, so
			-- OnPlayerAdded never ran for them.
			local harness = TestCtx.make({ Template = TEMPLATE })
			local player = FakePlayer.new()

			local waited = pump(waitAsync(harness.Ctx.Persistence, player, 0.3))

			expect(waited.Done).to.equal(true)
			expect(waited.Accessor).to.equal(nil)
			expect(waited.Reason).to.equal(Scribe.Reason.Timeout)
			expect(`bounded={waited.Elapsed >= 0.2 and waited.Elapsed < 3}`).to.equal("bounded=true")

			harness.Cleanup()
		end)

		it("answers player-left at once for a player who has already gone", function()
			-- Never made to serve out a deadline for someone who cannot arrive.
			local harness = TestCtx.make({ Template = TEMPLATE })
			local player = FakePlayer.new()
			FakePlayer.leave(player)

			local waited = pump(waitAsync(harness.Ctx.Persistence, player, 5))

			expect(waited.Done).to.equal(true)
			expect(waited.Accessor).to.equal(nil)
			expect(waited.Reason).to.equal(Scribe.Reason.PlayerLeft)
			expect(`prompt={waited.Elapsed < 2}`).to.equal("prompt=true")

			harness.Cleanup()
		end)

		it("answers a late caller from the stored end reason, and a rejoin from the new session", function()
			-- The entry is gone by the time this caller arrives, so the reason can only
			-- come from EndReasons. Ended with the player still in the game on purpose:
			-- "session-ended" is a reason the player-left branch could not have
			-- produced, so this pins the stored reason rather than the Parent check.
			--
			-- The rejoin half pins the OUTCOME -- a rejoined player is answered with
			-- their new session, never with the previous one's reason -- and not the
			-- mechanism. Measured: deleting `EndReasons[player] = nil` from
			-- OnPlayerAdded leaves this green, because a rejoin installs the entry
			-- synchronously and a caller holding an entry never consults the stored
			-- reason at all. The clear is defence in depth, and no wait can see it.
			local harness = TestCtx.make({ Template = TEMPLATE })
			local player = harness.Join()
			harness.Ctx.Persistence.OnPlayerRemoving(player) -- still parented: a local session end
			expect(harness.Ctx.Persistence.EntryFor(player)).to.equal(nil)

			local waited = pump(waitAsync(harness.Ctx.Persistence, player, 5))
			expect(waited.Reason).to.equal(Scribe.Reason.SessionEnded)
			expect(waited.Accessor).to.equal(nil)
			expect(`prompt={waited.Elapsed < 2}`).to.equal("prompt=true")

			-- A rejoin must not be answered from the previous session's tombstone.
			harness.Ctx.Persistence.OnPlayerAdded(player)
			local accessor, reason = harness.Ctx.Persistence.WaitForData(player, 5)
			expect(accessor).to.be.ok()
			expect(reason).to.equal(nil)

			harness.Cleanup()
		end)
	end)
end
