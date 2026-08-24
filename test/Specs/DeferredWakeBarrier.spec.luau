--!nonstrict
-- REGRESSION BARRIER: no answer to a waiting caller may travel the defer queue.
--
-- WHY THIS FILE EXISTS, AND WHY IT IS NOT A CHARACTERISATION FILE. Two call
-- sites used to wake a parked caller from inside a `Sched.Defer` callback:
-- `Persistence.AwaitSave`, already fixed when this file was written, and
-- `Client.Request`, which was not -- so its spec below landed RED on purpose
-- and is the pin proving that fix arrived. `Sched.Resume` is `task.spawn`,
-- which resumes INLINE on the resumer's stack, so a thread woken from a
-- deferred callback inherits that callback's Roblox re-entrancy generation.
-- Each round trip promotes the thread by one rung; at 80 the engine logs
-- "Maximum re-entrancy depth (80) exceeded", silently DROPS the callback -- it
-- returns a thread as though it had queued, measured -- and the waiter hangs for
-- the life of the server. On the AwaitSave path Monetization returns
-- PurchaseGranted off that save's boolean verdict, and Roblox never retries a
-- granted receipt.
--
-- The inherited rung lasts until that thread's next `task.wait` and no longer.
-- This header used to say "for the rest of its life", which
-- test/Specs/DeferredWakeHeadroom.spec.luau measured and refuted, so the climb
-- needs an unbroken run of round trips with no wait in it. Both fixed call sites
-- had exactly such a run against a synchronous backend, which is the
-- configuration the specs below drive.
--
-- The whole suite was green on the buggy shape. A full semantic revert of the
-- AwaitSave fix ran 1945 passed / 0 failed / 7 skipped with every PASS line
-- byte-identical, including all 49 of AwaitSaveContract's characterisation
-- specs -- which is correct behaviour for characterisation specs and exactly
-- why they cannot be the barrier. Nothing in the suite stopped anyone from
-- putting the deferred wake back. That is what this file is for.
--
-- HOW IT TESTS SOMETHING LUNE CANNOT COUNT. Lune has no re-entrancy cap, so the
-- generation the bug climbs is unobservable here. It does not need to be. The
-- assertion is not "the depth stayed low", it is "there was no deferred wake at
-- all":
--
--   Run the call on a coroutine of our own and resume it EXACTLY ONCE. Both
--   subjects are driven against a fully synchronous backend -- FakeProfileStore
--   never yields in SaveAwait, and StubTransport with AutoPump closes the whole
--   client/server round trip inside SendToServer -- so the answer is already
--   available before the caller could park. An implementation that answers by
--   VALUE therefore returns without ever yielding and the coroutine is DEAD
--   after that single resume. An implementation that hands the answer over by
--   waking a parked thread has to park first, so the coroutine is SUSPENDED.
--
-- `coroutine.status(child) == "dead"` is the discriminator, and it is an
-- ASSERTION rather than a watchdog on purpose: it fails on the spot with a
-- readable diff instead of consuming the runner's per-test budget. A timeout is
-- not a test failure -- it reads like CI infrastructure trouble, and under
-- standing practice here it does not count as killing a mutant.
--
-- WHY THE STATUS CHECK RATHER THAN A COUNTING SCHEDULER. A `Sched` installed
-- through `Sched.Install` whose `Defer` counts calls is the obvious
-- alternative, and it is included below as a SECOND assertion because it names
-- the mechanism (a deferred wake) rather than a symptom (a parked thread). It
-- is not the primary one, for three reasons. It cannot see the truthiness
-- mutation the false-verdict arm exists for -- rewrite AwaitSave's
-- `if result ~= nil` as `if result` and a FALSE verdict falls through to
-- `coroutine.yield()` and hangs with zero defers ever issued. It cannot tell
-- Scribe's own deferred wake apart from an unrelated defer issued by anything
-- else inside the measurement window, which for `Client.Request` after its fix
-- is the entire round trip running inline. And it mutates global state that
-- leaks into every later spec if a reset is ever missed. The status check needs
-- no install at all.
--
-- WHAT THESE READ ON A BROKEN TREE. Measured, not predicted, so the next reader
-- can tell a real regression from a broken harness:
--
--   AwaitSave's `resumeWaiter` restored -- the full pre-fix shape. BOTH arms:
--     status=suspended done=nil verdict=nil defers=1 resumes=0
--   AwaitSave's `if result ~= nil` weakened to `if result`. FALSE arm only;
--   the true arm still passes, which is what makes the false arm worth its
--   own spec rather than symmetry:
--     status=suspended done=nil verdict=nil defers=0 resumes=0
--   Client.Request's send wrapped in `Sched.Defer` -- the shape this spec was
--   written against, and the one it was RED on:
--     status=suspended done=nil ok=nil message=nil
--
-- In every one of them `resumed=true err=nil`: the caller is PARKED, not
-- throwing. That pair is asserted alongside the status so a failure here can
-- never be mistaken for an error escaping the subject.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local Sched = require(Root.Scribe.Internal.Sched)
	local Client = require(Root.Scribe.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	-- Client.new needs a running simulation, the same gate ClientLoopback uses.
	local itRunning = if RunService:IsRunning() then it else itSKIP

	-- Cleaned up from afterEach as well as inline: the false-verdict arm drives a
	-- save FAILURE, which pushes the shared Health singleton away from Healthy,
	-- and a trailing Cleanup() is skipped when an assertion throws -- which then
	-- fails unrelated specs downstream. Same reasoning as AwaitSaveContract's.
	local harness: any = nil

	afterEach(function()
		if harness then
			harness.Cleanup()
			harness = nil
		end
	end)

	--- Counts every `Sched.Defer` and every `Sched.Resume` the subject issues,
	--- delegating to the real ones so nothing about the run changes.
	---
	--- The window between Install and Reset must not be able to throw, or the
	--- counting scheduler outlives the spec and every later spec inherits it.
	--- Nothing in it can: `coroutine.create` and `coroutine.resume` do not raise,
	--- and an error inside the child is RETURNED by `resume` rather than
	--- propagated. Every caller below still reads its numbers, resets, and only
	--- THEN asserts.
	local function countingSched(): { Defers: number, Resumes: number, Reset: () -> () }
		local counts = { Defers = 0, Resumes = 0, Reset = function() end }
		local realDefer, realResume = Sched.Defer, Sched.Resume
		Sched.Install({
			Defer = function(fn, ...)
				counts.Defers += 1
				return realDefer(fn, ...)
			end,
			Resume = function(thread, ...)
				counts.Resumes += 1
				return realResume(thread, ...)
			end,
		})
		counts.Reset = Sched.Reset
		return counts
	end

	--- Drive `AwaitSave` on a coroutine of our own, resume it once, and report
	--- everything the barrier cares about as one line.
	local function awaitSaveOnce(entry: any): string
		local out: { [string]: any } = {}
		local counts = countingSched()
		local child = coroutine.create(function()
			out.Verdict = harness.Ctx.Persistence.AwaitSave(entry, 5)
			out.Done = true
		end)
		local resumed, err = coroutine.resume(child)
		-- Read BEFORE anything else can run. `coroutine.status` is only meaningful
		-- in the same synchronous stretch as the resume that produced it.
		local status = coroutine.status(child)
		counts.Reset()
		local caller = `resumed={resumed} err={tostring(err)} status={status}`
		local answer = `done={tostring(out.Done)} verdict={tostring(out.Verdict)}`
		return `{caller} {answer} defers={counts.Defers} resumes={counts.Resumes}`
	end

	describe("no waiting caller is woken from the defer queue", function()
		it("AwaitSave answers a TRUE verdict on the caller's first resumption", function()
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64101)
			data.Coins.Set(1234)

			local summary = awaitSaveOnce(entry)
			-- Read, reset, tear down, THEN assert -- a throw above would otherwise
			-- skip the cleanup and leave a live entry for the rest of the run.
			harness.Cleanup()
			harness = nil

			expect(summary).to.equal("resumed=true err=nil status=dead done=true verdict=true defers=0 resumes=0")
		end)

		it("AwaitSave answers a FALSE verdict on the caller's first resumption too", function()
			-- The false arm is not symmetry for its own sake. It is the only thing
			-- that pins `if result ~= nil` against `if result`: under truthiness a
			-- FALSE verdict is not recognised as an answer, falls through to
			-- `coroutine.yield()`, and parks a caller both wakers have already
			-- retired -- so nothing ever comes. That hangs exactly the failing
			-- saves, which is the half Monetization reads PurchaseGranted off.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64102)
			data.Coins.Set(7)

			harness.Fake.FailSaves = true
			local summary = awaitSaveOnce(entry)
			harness.Fake.FailSaves = false
			harness.Cleanup()
			harness = nil

			expect(summary).to.equal("resumed=true err=nil status=dead done=true verdict=false defers=0 resumes=0")
		end)

		itRunning("Client.Request answers a synchronous loopback on the caller's first resumption", function()
			-- StubTransport with AutoPump runs the server dispatch, the handler and
			-- the reply decode inside SendToServer, so the reply is in hand before
			-- the requester could reach a yield. Deferring the send is what forces
			-- it to park anyway and then be woken from the deferred callback.
			--
			-- No defer/resume counter here. After the fix the whole round trip runs
			-- inline inside the measurement window, so a `Sched.Defer` issued by any
			-- part of the server command path would be indistinguishable from the
			-- one this barrier is about. `status` is unambiguous.
			harness = TestCtx.make({ AutoPump = true, Options = { RequestTimeout = 0.25 } })
			local player = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			harness.Data.Command("BarrierEcho", function()
				return true, "pong"
			end)

			local out: { [string]: any } = {}
			local child = coroutine.create(function()
				out.Ok, out.Message = clientData.Request("BarrierEcho")
				out.Done = true
			end)
			local resumed, err = coroutine.resume(child)
			local status = coroutine.status(child)
			local caller = `resumed={resumed} err={tostring(err)} status={status}`
			local answer = `done={tostring(out.Done)} ok={tostring(out.Ok)} message={tostring(out.Message)}`
			local summary = `{caller} {answer}`

			-- Let a PARKED requester finish before teardown. This is not the
			-- assertion and cannot rescue it -- `summary` was taken above and is
			-- what gets compared. It is here so that on a failing tree the request
			-- resolves against a live harness instead of resuming into a torn-down
			-- one and raising out of a thread nobody is watching.
			local deadline = os.clock() + 2
			while out.Done ~= true and os.clock() < deadline do
				task.wait()
			end
			harness.Cleanup()
			harness = nil

			expect(summary).to.equal("resumed=true err=nil status=dead done=true ok=true message=pong")
		end)
	end)
end
