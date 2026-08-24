--!nonstrict
-- CHARACTERISATION: the observable contract of `Persistence.AwaitSave` and the
-- `Data.Flush` that is built on it.
--
-- WHY THIS FILE EXISTS. A pending fix rewrites how AwaitSave gets its answer back
-- to its caller. Today the completion always resumes a caller that has already
-- yielded (or defers the resume until it has); the fix lets the caller skip the
-- yield entirely when the store settled inline, which is EVERY call in this suite
-- because FakeProfileStore.SaveAwait never yields. That removes one scheduler
-- breath from the middle of every AwaitSave in the library -- including the one
-- Monetization's receipt path returns PurchaseGranted off.
--
-- So the point of this file is not to test the resume mechanism. It is to write
-- down, BEFORE the mechanism changes, everything a caller is entitled to observe
-- across an AwaitSave, so a fix that changes the ordering and quietly changes an
-- ANSWER cannot land green.
--
-- WHAT IS DELIBERATELY NOT ASSERTED. Nothing here says "AwaitSave yields", "it
-- yields exactly once", or anything else about how the answer travels. Those are
-- the implementation the fix is allowed to replace; a spec pinning them would be
-- red by design and would teach the next reader to edit the spec instead of the
-- code. What IS pinned is the pair of orderings a caller can actually see: the
-- save has fully completed by the time AwaitSave returns, and the answer is the
-- same whether the store settled synchronously or asynchronously. The second one
-- is the load-bearing one: today only the async shape is reachable through a
-- stub, and after the fix it is the SYNC shape that takes the new branch, so
-- asserting both against the same expectations is what makes the change visible.
--
-- OVERLAP WITH EXISTING FILES, and why these are still here. AuditFixes pins the
-- outcome mapping through a stub (Failed / NotOwned / Blocked / Saved),
-- StoreSaveOutcome pins the same three against the real vendored store,
-- ReleaseOnlyDurability and BlockedSwapHonesty pin their two cases end to end
-- through Sim, and FlushDurability pins the "nothing to save" short circuit.
-- None of them assert what `entry.SavesInFlight`, `entry.DirtyAtSaveStart` and
-- `entry.SaveInfo` look like ACROSS an AwaitSave, none of them cover the
-- timeout's first-wins guard against a late completion, and none of them run the
-- same expectations against a sync and an async store. Those are the parts the
-- fix touches.
--
-- `entry.SaveGen` does not exist in this tree. The generation counter AwaitSave
-- used to correlate completions with was deleted when the store started
-- answering for its own save (see the comment above AwaitSave); the only
-- surviving mention is a stale one in FakeProfileStore's own comments. There is
-- nothing to characterise, which is itself worth recording here so the next
-- reader does not go looking.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	-- Cleanup from afterEach rather than the tail of each `it`. Several tests here
	-- drive save FAILURES, which push the shared Health singleton away from
	-- Healthy, and a trailing harness.Cleanup() is skipped when an assertion
	-- throws -- which then fails unrelated specs downstream. Same reasoning as the
	-- note at the top of FailedSaveDirtyRestore.spec.
	local harness: any = nil

	afterEach(function()
		if harness then
			harness.Cleanup()
			harness = nil
		end
	end)

	local function persistence()
		return harness.Ctx.Persistence
	end

	local function keyOf(entry): string
		return `Default/{entry.Key}`
	end

	local function saveCount(entry): number
		return harness.Fake.SaveCounts[keyOf(entry)] or 0
	end

	local function metric(name: string): number
		return (Scribe.GetMetrics()[name] :: any) or 0
	end

	local function logCount(code: string): number
		return #Scribe.GetRecentLogs({ Code = code, Limit = 500 })
	end

	--- Bounded pump for the two tests that must call AwaitSave from a thread other
	--- than the one running the assertions. Bounded, and with its own error, so a
	--- call that never settles fails HERE rather than as the runner's per-test
	--- budget -- a timeout is not a test failure and reads like an infrastructure
	--- problem in CI.
	local function pumpUntil(done: () -> boolean, what: string)
		for _ = 1, 400 do
			if done() then
				return
			end
			task.wait()
		end
		error(`{what} never settled`, 2)
	end

	describe("the answer AwaitSave gives", function()
		it("answers true for a save that landed, and the bytes are on the key", function()
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64001)
			data.Coins.Set(1234)

			local before = saveCount(entry)
			expect(persistence().AwaitSave(entry, 5)).to.equal(true)

			-- One save, not zero and not two: the answer is about a write that
			-- actually happened.
			expect(saveCount(entry) - before).to.equal(1)
			expect(harness.Fake.Persisted[keyOf(entry)].Coins).to.equal(1234)
		end)

		it("answers false for a save the store reports as Failed", function()
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64002)
			data.Coins.Set(7)

			harness.Fake.FailSaves = true
			expect(persistence().AwaitSave(entry, 5)).to.equal(false)
			harness.Fake.FailSaves = false

			-- ...and it really did refuse to write, rather than answering false for
			-- some other reason.
			expect(harness.Fake.Persisted[keyOf(entry)]).to.equal(nil)
		end)

		it("answers false for a ReleaseOnly write, even though the outcome was Saved", function()
			-- A fail-closed release writes MetaData and deliberately leaves the
			-- stored bytes untouched: the DataStore call succeeded and none of
			-- profile.Data reached the key. The end-to-end consequence through
			-- Data.Flush is ReleaseOnlyDurability.spec's; what is pinned here is the
			-- one term of AwaitSave's three-term verdict that reads this flag.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64003)
			data.Coins.Set(9)

			local real = entry.Profile.SaveAwait
			entry.Profile.SaveAwait = function()
				return "Saved", { ReleaseOnly = true }
			end
			expect(persistence().AwaitSave(entry, 5)).to.equal(false)
			entry.Profile.SaveAwait = real
		end)

		it("answers off the table the write actually serialized, not off a snapshot-time flag", function()
			-- The wipe guard's Block policy re-points profile.Data at the last-good
			-- snapshot, so a save can succeed while carrying somebody else's bytes.
			-- The verdict is taken from SavedSource -- WHICH table went to the key --
			-- and both directions matter: a save that serialized the live tree is
			-- durable however the flags looked when it started.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64004)
			data.Coins.Set(5)

			local real = entry.Profile.SaveAwait

			entry.Profile.SaveAwait = function()
				return "Saved", { SavedSource = {} } -- some other table entirely
			end
			expect(persistence().AwaitSave(entry, 5)).to.equal(false)

			entry.Profile.SaveAwait = function()
				return "Saved", { SavedSource = entry.LiveData }
			end
			expect(persistence().AwaitSave(entry, 5)).to.equal(true)

			entry.Profile.SaveAwait = real
		end)

		it("refuses without asking the store when the profile is gone or no longer active", function()
			harness = TestCtx.make()
			local _player, entry = harness.Join(64005)

			local asked = 0
			local realSaveAwait = entry.Profile.SaveAwait
			entry.Profile.SaveAwait = function()
				asked += 1
				return "Saved", {}
			end

			local realIsActive = entry.Profile.IsActive
			entry.Profile.IsActive = function()
				return false
			end
			expect(persistence().AwaitSave(entry, 5)).to.equal(false)
			entry.Profile.IsActive = realIsActive

			local realProfile = entry.Profile
			entry.Profile = nil
			expect(persistence().AwaitSave(entry, 5)).to.equal(false)
			entry.Profile = realProfile

			-- The point of the counter: refusing must be free. A guard that answered
			-- false only AFTER spending a DataStore round trip would pass every
			-- assertion above.
			expect(asked).to.equal(0)
			entry.Profile.SaveAwait = realSaveAwait
		end)
	end)

	describe("what the entry looks like across a call", function()
		it("leaves the bookkeeping drained and the entry clean after a save that landed", function()
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64011)
			data.Coins.Set(12)

			-- Before: nothing on the wire, no captured pre-snapshot dirtiness, and a
			-- write is owed.
			expect(entry.SavesInFlight).to.equal(0)
			expect(entry.DirtyAtSaveStart).to.equal(nil)
			expect(entry.SaveInfo.Dirty).to.equal(true)

			expect(persistence().AwaitSave(entry, 5)).to.equal(true)

			-- After: the count is back to zero, the shared pre-snapshot slot is
			-- cleared on that drain, and the ledger says nothing is owed.
			expect(entry.SavesInFlight).to.equal(0)
			expect(entry.DirtyAtSaveStart).to.equal(nil)
			expect(entry.SaveInfo.Dirty).to.equal(false)
			expect(entry.SaveInfo.LastResult).to.equal("Ok")
		end)

		it("leaves the entry dirty, and the bookkeeping drained, after a save that failed", function()
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64012)
			data.Coins.Set(4242)

			harness.Fake.FailSaves = true
			expect(persistence().AwaitSave(entry, 5)).to.equal(false)
			harness.Fake.FailSaves = false

			-- Dirty is cleared when the payload is SNAPSHOTTED, so a save that then
			-- fails has erased the only record that the tree differs from storage.
			-- Whatever the resume mechanism, a caller told false must be able to read
			-- "still owed" off the entry afterwards.
			expect(entry.SaveInfo.Dirty).to.equal(true)
			expect(entry.SaveInfo.LastResult).to.equal("Fail")
			expect(entry.SavesInFlight).to.equal(0)
			expect(entry.DirtyAtSaveStart).to.equal(nil)
		end)

		it("does not return until the save has completed", function()
			-- The one ordering a caller genuinely depends on, and the reason
			-- Monetization can flush and then answer a receipt. Asserted through the
			-- store's own mid-save window rather than through anything about yields.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64013)
			data.Coins.Set(3)

			local reachedMidSave = false
			harness.Fake.MidSave = function()
				reachedMidSave = true
			end
			local before = saveCount(entry)
			expect(persistence().AwaitSave(entry, 5)).to.equal(true)
			harness.Fake.MidSave = nil

			expect(reachedMidSave).to.equal(true)
			expect(saveCount(entry) - before).to.equal(1)
			expect(entry.SavesInFlight).to.equal(0)
		end)

		it("still owes a write that landed after this save's payload was snapshotted", function()
			-- A write arriving mid-save is not in the bytes this save serialized (in
			-- general -- the fake happens to read Data by reference afterwards, as
			-- the real transform does, so it may well be), and the ledger must err
			-- toward DIRTY either way: over-reporting costs one redundant save,
			-- under-reporting costs a receipt granted for data only in RAM.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64014)

			data.Coins.Set(10)
			expect(persistence().AwaitSave(entry, 5)).to.equal(true)
			expect(entry.SaveInfo.Dirty).to.equal(false)

			harness.Fake.MidSave = function()
				harness.Fake.MidSave = nil
				data.Gems.Set(77)
			end
			data.Coins.Set(11)
			expect(persistence().AwaitSave(entry, 5)).to.equal(true)

			expect(entry.SaveInfo.Dirty).to.equal(true)
			expect(entry.SavesInFlight).to.equal(0)
			expect(entry.DirtyAtSaveStart).to.equal(nil)
		end)

		it("answers its own save, and drains the counter, when a second save overlaps it", function()
			-- Two saves genuinely in flight at once, driven from inside the first
			-- one's round-trip window. The counter is the thing that has to survive
			-- it: SavesInFlight is a counter precisely because saves overlap, and
			-- DirtyAtSaveStart is a slot SHARED by every save in flight that is only
			-- safe to clear on the drain to zero.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64015)
			data.Coins.Set(5)

			local depths: { number } = {}
			harness.Fake.MidSave = function()
				table.insert(depths, entry.SavesInFlight)
				harness.Fake.MidSave = function()
					table.insert(depths, entry.SavesInFlight)
				end
				entry.Profile:Save()
				harness.Fake.MidSave = nil
			end

			expect(persistence().AwaitSave(entry, 5)).to.equal(true)

			-- The overlap really happened. Without this the test passes on a tree
			-- where the second save never started.
			expect(#depths).to.equal(2)
			expect(depths[1]).to.equal(1)
			expect(depths[2]).to.equal(2)

			expect(entry.SavesInFlight).to.equal(0)
			expect(entry.DirtyAtSaveStart).to.equal(nil)
			expect(entry.SaveInfo.Dirty).to.equal(false)
		end)
	end)

	describe("how the answer gets home", function()
		it("gives the same answer whether the store settles inline or later", function()
			-- THE SPEC THIS FILE EXISTS FOR. FakeProfileStore.SaveAwait never yields,
			-- so every AwaitSave in the suite settles on the caller's own stack; a
			-- store that parks in its round trip is only reachable through a stub.
			-- The pending fix changes which of those two shapes takes which branch,
			-- so both are run against identical expectations here.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64021)

			-- (a) settles inline -- the real fake.
			data.Coins.Set(20)
			expect(persistence().AwaitSave(entry, 5)).to.equal(true)
			expect(entry.SaveInfo.Dirty).to.equal(false)

			-- (b) settles later, on a thread that parked in the store.
			local realSaveAwait = entry.Profile.SaveAwait
			local storeThread: thread? = nil
			entry.Profile.SaveAwait = function()
				storeThread = coroutine.running()
				return coroutine.yield()
			end

			local out: { [string]: any } = {}
			task.spawn(function()
				out.Result = persistence().AwaitSave(entry, 30)
				out.Done = true
			end)

			-- Genuinely outstanding: the store has been entered and has not answered.
			-- Without this the arm is vacuous, because a synchronous stub would reach
			-- the same assertions below.
			expect(storeThread).to.be.ok()
			expect(out.Done).to.equal(nil)

			task.spawn(storeThread :: any, "Saved", { SavedSource = entry.LiveData })
			pumpUntil(function()
				return out.Done == true
			end, "the async AwaitSave")
			expect(out.Result).to.equal(true)

			-- ...and the failing answer travels the same road.
			out = {}
			task.spawn(function()
				out.Result = persistence().AwaitSave(entry, 30)
				out.Done = true
			end)
			task.spawn(storeThread :: any, "Failed", {})
			pumpUntil(function()
				return out.Done == true
			end, "the async AwaitSave (failure)")
			expect(out.Result).to.equal(false)

			entry.Profile.SaveAwait = realSaveAwait
		end)

		it("answers a caller that is itself running inside a deferred callback", function()
			-- Where the library actually calls this from: Monetization's receipt and
			-- gift paths run on threads Scribe scheduled, not on the one that started
			-- the frame. Pinned as a plain contract -- the call returns, and returns
			-- the right thing -- so it keeps meaning the same after the resume
			-- mechanism is replaced.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64022)
			data.Coins.Set(31)

			local out: { [string]: any } = {}
			task.defer(function()
				out.Result = persistence().AwaitSave(entry, 30)
				out.Done = true
			end)
			pumpUntil(function()
				return out.Done == true
			end, "the deferred AwaitSave")

			expect(out.Result).to.equal(true)
			expect(harness.Fake.Persisted[keyOf(entry)].Coins).to.equal(31)
		end)

		it("times out to false, counts it as unresolved, and ignores the completion that arrives late", function()
			-- The timeout is FIRST-WINS against the completion, and has to stay that
			-- way: the save is very often still in flight and lands seconds later, on
			-- a thread that will then try to answer a caller who has already been
			-- told no and moved on.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64023)
			data.Coins.Set(8)

			local realSaveAwait = entry.Profile.SaveAwait
			local storeThread: thread? = nil
			entry.Profile.SaveAwait = function()
				storeThread = coroutine.running()
				return coroutine.yield()
			end

			local timeoutsBefore = metric("SaveWaitTimeouts")
			local failedBefore = metric("SavesFailed")
			local logsBefore = logCount("SAVE_WAIT_TIMEOUT")

			expect(persistence().AwaitSave(entry, 0.1)).to.equal(false)

			-- Unresolved, not failed. The distinction is the whole reason the counter
			-- is separate: the save may yet succeed.
			expect(metric("SaveWaitTimeouts") - timeoutsBefore).to.equal(1)
			expect(metric("SavesFailed") - failedBefore).to.equal(0)
			expect(logCount("SAVE_WAIT_TIMEOUT") - logsBefore).to.equal(1)

			-- Now the save lands, after the caller was answered -- and it lands while
			-- that caller is PARKED ON SOMETHING ELSE, which is the shape that costs
			-- something. A completion that still believes it owes this thread an
			-- answer wakes it out of an unrelated wait carrying the save's boolean,
			-- and the thread reads that boolean as the reply it was waiting for.
			--
			-- Written as a race between two deliveries with a declared winner rather
			-- than as an assertion about resumes, so it keeps meaning the same
			-- however the answer is delivered: a thread that stopped waiting for a
			-- save must receive the value it actually parked for.
			local me = coroutine.running()
			task.delay(0.05, function()
				task.spawn(storeThread :: any, "Saved", { SavedSource = entry.LiveData })
			end)
			task.delay(0.15, function()
				task.spawn(me, "the reply this thread is actually waiting for")
			end)
			expect(coroutine.yield()).to.equal("the reply this thread is actually waiting for")

			-- ...and the late save was not re-counted as a second timeout.
			expect(metric("SaveWaitTimeouts") - timeoutsBefore).to.equal(1)
			expect(logCount("SAVE_WAIT_TIMEOUT") - logsBefore).to.equal(1)

			entry.Profile.SaveAwait = realSaveAwait
		end)
	end)

	describe("Data.Flush, on top of it", function()
		it("refuses a player with no entry, and one that is not Ready", function()
			harness = TestCtx.make()
			expect(harness.Data.Flush(FakePlayer.new(64031))).to.equal(false)

			local player, entry, data = harness.Join(64032)
			data.Coins.Set(1)
			local realState = entry.State
			entry.State = "Loading"
			local before = saveCount(entry)
			expect(harness.Data.Flush(player)).to.equal(false)
			-- Refusing has to be free too: a flush on a half-loaded entry must not
			-- reach the store at all.
			expect(saveCount(entry)).to.equal(before)
			entry.State = realState
		end)

		it("forwards the save's own answer, and leaves the entry owing the write", function()
			harness = TestCtx.make()
			local player, entry, data = harness.Join(64033)
			data.Coins.Set(15)

			harness.Fake.FailSaves = true
			expect(harness.Data.Flush(player)).to.equal(false)
			harness.Fake.FailSaves = false

			expect(entry.SaveInfo.Dirty).to.equal(true)
			expect(harness.Fake.Persisted[keyOf(entry)]).to.equal(nil)

			-- And the retry works, so the false above was about THAT save rather than
			-- a latched refusal.
			expect(harness.Data.Flush(player)).to.equal(true)
			expect(harness.Fake.Persisted[keyOf(entry)].Coins).to.equal(15)
		end)

		it("short-circuits an already-durable entry without spending a request", function()
			harness = TestCtx.make()
			local player, entry, data = harness.Join(64034)
			data.Coins.Set(2)

			expect(harness.Data.Flush(player)).to.equal(true)
			local after = saveCount(entry)
			local durableBefore = metric("FlushesAlreadyDurable")

			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saveCount(entry)).to.equal(after)
			expect(metric("FlushesAlreadyDurable") - durableBefore).to.equal(1)
		end)

		it("never short-circuits under Force, even when the entry is already durable", function()
			-- Force exists to push a wipe-guard-BLOCKED save through, so it must
			-- always reach the store; the two mechanisms must not be coupled by
			-- accident. This half is only about the short circuit -- the arm below is
			-- about what Force is FOR.
			harness = TestCtx.make()
			local player, entry, data = harness.Join(64035)
			data.Coins.Set(3)

			expect(harness.Data.Flush(player)).to.equal(true)
			local after = saveCount(entry)
			local durableBefore = metric("FlushesAlreadyDurable")

			expect(harness.Data.Flush(player, { Force = true })).to.equal(true)
			expect(saveCount(entry) - after).to.equal(1)
			expect(metric("FlushesAlreadyDurable") - durableBefore).to.equal(0)
			-- The one-shot flag is consumed rather than latched.
			expect(entry.ForceSaveOnce).to.equal(false)
		end)

		it("pushes a wipe-guard-blocked save through under Force, and answers true for it", function()
			-- The documented way out of a Block-policy stall, and the only reason the
			-- one-shot flag exists. Asserted on the ANSWER first: a blocked flush is
			-- false because the last-good snapshot went to the key instead of this
			-- data, and the forced one is true because the live tree did. Without
			-- that, "Force reached the store" is satisfied by a forced save that is
			-- still blocked and still writes somebody else's bytes.
			harness = TestCtx.make({ Options = { WipeGuardPolicy = "Block" } })
			local player, entry, data = harness.Join(64037)
			data.Nick.Set("someone")
			data.Inventory.Sword.Set({ Level = 9 })
			expect(harness.Data.Flush(player)).to.equal(true)

			-- Collapse the profile so the guard trips and holds the save. Same lever
			-- FlushDurability.spec uses: LastSavedSize is the baseline the size check
			-- reads, so raising it is a collapse without a giant fixture.
			entry.LiveData.Inventory = {}
			entry.LiveData.Nick = ""
			entry.LastSavedSize = 100000
			entry.SaveInfo.Dirty = true

			expect(harness.Data.Flush(player)).to.equal(false)
			expect(entry.Blocked).to.equal(true)

			local forcedBefore = logCount("WIPE_GUARD_FORCED")
			expect(harness.Data.Flush(player, { Force = true })).to.equal(true)
			expect(logCount("WIPE_GUARD_FORCED") - forcedBefore).to.equal(1)
			expect(entry.Blocked).to.equal(false)
		end)

		it("answers false, bounded, for a save that never confirms", function()
			harness = TestCtx.make()
			local player, entry, data = harness.Join(64036)
			data.Coins.Set(4)

			local realSaveAwait = entry.Profile.SaveAwait
			entry.Profile.SaveAwait = function()
				coroutine.yield() -- never returns, never errors
				return "Saved", {}
			end

			local startedAt = os.clock()
			expect(harness.Data.Flush(player, { Timeout = 0.15 })).to.equal(false)
			-- The caller's Timeout is what bounded it, not the 15s default.
			expect(os.clock() - startedAt < 5).to.equal(true)

			entry.Profile.SaveAwait = realSaveAwait
		end)
	end)
end
