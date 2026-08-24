--!nonstrict
-- DeferredWakeBarrier's Studio counterpart. Reads the Roblox scheduler's
-- `task.defer` re-entrancy budget as an INTEGER, then spends it on real Scribe work
-- to see what a burst costs.
--
-- WHY THIS IS NOT DeferredWakeBarrier RUN TWICE. That file asserts "the subject
-- never parked", via `coroutine.status(child) == "dead"`. That property is
-- realm-independent: TestCtx installs the same synchronous FakeProfileStore and the
-- same StubTransport in Studio as in Lune, so a Studio copy would re-execute an
-- assertion CI already makes on every commit, in a runner nobody runs per-commit.
-- What Lune structurally cannot produce is a NUMBER. Lune has no re-entrancy
-- ceiling -- measured, by forcing the gate below true: every chain ran to CHAIN_CAP
-- rather than stopping against anything -- so it has no headroom. This file reads
-- that headroom, and every assertion below is about a quantity that does not exist
-- headless. The two are complements: DeferredWakeBarrier catches a truthiness
-- mutation this file is green on, and it runs on every commit where this one runs
-- only when somebody opens Studio. Neither replaces the other.
--
-- WHY IT NEVER DRIVES THE CODE UNDER TEST TO THE CEILING. The probe chains below do
-- reach it, by design, because the refusal is the reading; nothing Scribe owns is ever
-- taken there. At the ceiling the engine refuses the defer, and WHAT IT DOES NEXT is
-- now measured rather than guessed from the wording of the log line. A probe on
-- 2026-08-24, run in both the Edit and the Server realm, pcall-wrapped a recursive
-- `task.defer` and read `reached=80 ok=80 raised=0 lastOk=true lastRetType=thread`:
-- the call AT the ceiling raises nothing, returns a thread exactly as a successful
-- queue does, and then never runs the callback. The silent drop this file was built
-- for is the branch the engine actually takes, and it is the branch in which nothing
-- reports the failure, so it is the only branch a barrier could have been needed for.
--
-- On a ratcheting tree that dropped callback would be the SUBJECT'S OWN WAKE, so the
-- hang lands inside AwaitSave or WaitForData rather than inside the probe, and TestEZ
-- runs an `it` body under
-- a bare `xpcall` on the runner's own thread (TestRunner.lua:84, inside the helper
-- defined at :55 and called for the test body at :116 -- there is no `coroutine` in
-- that file at all), so that hang takes the entire suite down with no message, no
-- line number and no terminal "Scribe test suite:" line. That is the original
-- disaster reproduced rather than reported. Headroom was PREDICTED to shrink by one
-- per ratchet event, derived from the mechanism below; it has since been observed at
-- exactly that, so the RATE is readable from twenty iterations with sixty rungs to
-- spare.
-- Nothing here ever goes near the ceiling, and every burst is preceded by a pre-flight
-- that refuses to start if the budget is already low.
--
-- WHAT IT FOUND, so that the answers survive the instrument being gated off. Two runs,
-- 2026-08-23 21:36 and 2026-08-24 05:12, both in Studio on the real engine, agreeing
-- line for line:
--
--     [reentrancy] fresh=80 after3wakes=77 perWake=1.00 afterFrame=80
--                  survivesFrame=false repeat=80 wokenBy=defer,defer,defer
--     [reentrancy] AwaitSave x20 headroom=80 before=80 after=80 spent=0 capped=false
--     [reentrancy] site2 headroom=80 before=80 spent=[1,1,1,1,1,1,1,1,1,1]
--                  completed=10/10 perLoad=1 peak=1 budget=3 capped=false
--     [reentrancy] site2 NOT ASSERTED slope=0.000 loadsToCeiling=inf
--
-- Read as: the ceiling is 80 and real. A deferred wake promotes the thread it wakes by
-- exactly one rung. A climbed rung does NOT survive a frame boundary, so the whole bug
-- class is frame bounded and only an unyielding burst can reach the ceiling. Twenty
-- consecutive AwaitSave calls now spend nothing at all. Site 2 costs one rung per load
-- and gives it back at the load's own yield, so it cannot accumulate.
--
-- The prose below still frames the frame-boundary question as open, because the file
-- was written before either run and its DESIGN has to stay valid under both answers --
-- that is what makes the readings trustworthy rather than assumed. Do not simplify it
-- against the answer now in hand; the next engine version gets to answer it again.
--
-- THE INSTRUMENT, AND ITS ONE UNVERIFIED PREMISE. There is no `task.getdepth()`, but
-- the ceiling itself is the readout. A `task.defer` issued from INSIDE a deferred
-- callback is PREDICTED to queue one generation deeper than the callback that issued
-- it -- that is the ratchet mechanism the two shipped fixes were reasoned from, and no
-- run anywhere has observed it -- so a chain of nested defers should walk the counter
-- upward one rung per link and stop dead the instant the engine refuses the next one,
-- which would make the number of links that ran the headroom the issuing thread had:
--
--     Reached = CEILING - (generation of the thread that called startChain)
--
-- That equation is the instrument's calibration and it is a prediction, not a reading.
-- The first Studio run either bears it out or invalidates every number below, which is
-- why spec 1 asserts only the parts of it that can be checked without knowing where
-- the ceiling is -- that a ceiling was reached at all, that the reading repeats frame
-- to frame -- and prints the rest.
--
-- Three properties make that usable where a naive burst is not:
--
--   * `startChain` DOES NOT YIELD. It queues one chain and returns. WHETHER the
--     quantity being measured is destroyed by yielding -- whether a thread resumed
--     from the wait queue gets a fresh generation -- is the pivotal unmeasured
--     question of this whole tier, printed by spec 1 as `survivesFrame` and asserted
--     by nothing. Arming inside the same unbroken stretch as the code under test is
--     what makes a reading valid under BOTH answers; it is done that way because the
--     answer is unknown, not because it is known. (This bullet used to state the
--     fresh-generation half flatly as fact while test/Sim/Available.luau stated the
--     opposite half just as flatly. Two shipped files, one unmeasured question,
--     opposite answers, neither hedged.) Arming is free; collection happens
--     afterwards, and cannot corrupt what was already recorded at issue time.
--   * THE INSTRUMENT CANNOT HANG. Nothing in `startChain`/`settle` ever waits on a
--     callback that may have been dropped. A dropped link is not an event to wait
--     for; it is the absence of an increment, which is already visible. `settle`
--     waits a bounded number of FRAMES and reads whatever landed.
--     THE CODE UNDER TEST IS A DIFFERENT MATTER, and this bullet used to be written
--     as though it were not. If a load path were expensive enough to walk the
--     caller into the ceiling mid-burst, the callback the engine drops is the
--     SPEC'S OWN WAKE inside WaitForData, and the spec parks forever -- the exact
--     silent suite death described above, produced by the file written to avoid it.
--     Measured on a synthetic ceiling: with rungs surviving frames and a load path
--     costing eleven rungs, the async spec did not fail, it hung. So the async
--     burst now runs on a WORKER and the body joins it with a bounded wait; a
--     dropped wake shows up as `completed` short of ASYNC_LOADS and fails the
--     assertion. No burst here waits unboundedly on anything, instrument or
--     subject.
--   * NOTHING HARD-CODES 80. Every assertion about COST is a difference between two
--     readings taken by the same instrument in the same stretch, so if Roblox moves
--     the ceiling not one of them changes, and a failure reports rungs SPENT rather
--     than a position relative to a constant nobody can see. Exactly two terms are
--     not differences, and neither compares against an engine number: `capped`,
--     which measures a reading against CHAIN_CAP -- this file's own safety cap --
--     because a difference of two capped readings is indistinguishable from a cost
--     of zero; and `completed`, which counts loads that finished, because a burst
--     cut short by a dropped wake yields differences that are simply absent.
--
-- CHAIN_CAP exists so a realm with NO ceiling terminates instead of spinning, and it
-- is reported honestly as `capped=true` rather than returned as a number that looks
-- like a measurement. ALL THREE specs carry that term in the string they assert, and
-- it is load-bearing rather than decorative: every other number here is a DIFFERENCE
-- between two readings, and two readings that are both the cap subtract to zero --
-- which is also exactly what a perfectly cheap code path looks like. Two of these
-- three specs once asserted only on the difference, and both passed under Lune, on
-- `before = 256`, in a realm with no ceiling to spend. HEADROOM_FLOOR does not cover
-- this and cannot: 256 >= 40 sails through the pre-flight.
--
-- THE SYNCHRONOUS-STORE CONSTRAINT, established from the tree rather than assumed.
-- test.project.json mounts src and test under ReplicatedStorage.ScribeDev and runs
-- test/RunTests.server.luau from ServerScriptService, so this is a server Script and
-- never edit mode. TestCtx.make hard-sets UseMock = true, ProfileStore =
-- FakeProfileStore.new() and OwnReceipts = false in BOTH realms -- Studio never
-- reaches a real DataStore through this harness. FakeProfileStore.SaveAwait is
-- straight-line with no yield in it. The fake yields in exactly two places and
-- neither is on the save path: `task.wait()` under the opt-in `YieldOnSessionStart`
-- (FakeProfileStore:494), on the LOAD path, and the job drain inside `AwaitClose`
-- (:151), which only Data.Stop reaches -- and every reading below is collected before
-- any teardown runs. So a legitimate yield cannot be mistaken for a ratchet in the
-- AwaitSave spec, because in that configuration there is no legitimate yield
-- available. The async-load spec turns that flag on deliberately and is written
-- around the yield rather than against it.
--
-- WHAT IS DELIBERATELY ABSENT: a Client.Request arm. Its only reachable configuration
-- in Studio is StubTransport with AutoPump, which is the same object graph
-- DeferredWakeBarrier already drives in CI -- `Client.new` gates on `IsRunning()` and
-- needs no LocalPlayer (src/Client/init.luau:82-88), so the Studio client is not a
-- different client. A real RemoteEvent would be strictly worse, not better: it is
-- asynchronous by construction, so the requester parks for a CORRECT reason, and a
-- Studio Run (F8) has a server and no player at all.
return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	-- REAL ENGINE ONLY, through the suite's single host-capability register -- the
	-- same module that carries the mirror-image gate every Sim spec reads. It must NOT
	-- be spelled `itRunning`: the Lune shim returns true from IsRunning
	-- (lune/run-tests.luau:521), so that idiom discriminates Studio EDIT mode from
	-- everything else and all 23 specs using it run headless today. Under Lune
	-- `task.defer` has no ceiling, a chain never terminates against one, and every
	-- number below would be CHAIN_CAP. See test/Sim/Available for the probe itself and
	-- for why it cannot throw on either host.
	--
	-- AND OFF BY DEFAULT EVEN ON THAT ENGINE, which is the second gate and is not a
	-- capability question at all. This file reads the ceiling by walking a chain of
	-- nested defers until the engine refuses the next one, so every chain it arms
	-- costs one "Maximum re-entrancy depth (80) exceeded" warning and a three line
	-- traceback in the Output: nineteen per run, four from spec 1, three from spec 2
	-- and twelve from spec 3, on a run where every assertion passes. That count is
	-- not tunable, because the refusal IS the reading. A chain capped short reports
	-- CHAIN_CAP instead, and two capped readings subtract to spent=0, which is also
	-- exactly what a perfectly cheap code path looks like -- the failure mode the
	-- `capped` term in all three specs exists to catch.
	--
	-- THE COST OF LEAVING IT ON is not the console clutter it looks like. The string
	-- it prints nineteen times on a green run is the same string the ratchet printed
	-- when it took the suite down with no line number and no reporter output. Leave
	-- the instrument on and the next real occurrence arrives in a log that already
	-- contains nineteen identical lines, having trained its reader to scroll past
	-- them. DeferredWakeBarrier is the always-on gate for this bug class: it asserts
	-- the invariant in both realms, on every commit, and prints nothing. This file is
	-- an instrument, the category SimStudy.spec puts itself in, and is gated likewise.
	--
	-- TO RUN IT, from the Studio Command Bar before pressing Run:
	--
	--     game:GetService("ReplicatedStorage"):SetAttribute("ScribeReentrancy", true)
	--
	-- An attribute rather than a constant in this file, for two reasons. It cannot be
	-- left switched on in a commit by accident, and it is cleared by the next
	-- `rojo build` along with everything else the place holds, so the default is
	-- restored by the ordinary workflow rather than by remembering. RealEngine is
	-- read FIRST and short circuits, so the attribute read never executes under Lune,
	-- where the shimmed ReplicatedStorage has no GetAttribute to call.
	--
	-- WHY ReplicatedStorage AND NOT `game`, measured rather than assumed. An attribute
	-- set on ReplicatedStorage in edit mode reads back as a boolean `true` from the
	-- SERVER datamodel once Run starts, because that service is cloned into the run.
	-- The identical attribute set on `game` reads back NIL there: the DataModel is a
	-- fresh instance rather than a clone of the edit one, so nothing set on it
	-- carries. Both were set in one edit-mode call and read in one server-mode call
	-- on 2026-08-24; `game` was the more natural spelling and would have produced a
	-- gate that could never be switched on, with no error to say so.
	local optedIn = require(Root.Test.Sim.Available).RealEngine
		and game:GetService("ReplicatedStorage"):GetAttribute("ScribeReentrancy") == true
	local itEngine = if optedIn then it else itSKIP

	-- Comfortably above the 80 in the engine's own error message so a real ceiling is
	-- always the thing that stops a chain, and low enough that a realm with no ceiling
	-- costs one frame of cheap callbacks rather than an unbounded run.
	local CHAIN_CAP = 256
	local SETTLE_STABLE_FRAMES = 3
	local SETTLE_TIMEOUT = 5

	-- Burst length, and the single most important decision in this file: at the worst
	-- rate the mechanism is predicted to allow -- one rung per call, which is exactly
	-- the pre-fix shape -- one hundred consecutive promoting calls on one thread IS the
	-- hang this spec exists to report. A barrier that reproduces the disaster while
	-- measuring it is the worst possible barrier. Twenty SHOULD leave roughly sixty
	-- rungs unspent even on a fully ratcheting tree (80 minus 20, on the unobserved
	-- one-rung-per-event rate above), and the pre-flight below refuses to start at all
	-- if the budget is not there. The coverage a larger number was meant to buy is
	-- preserved by what the iterations are FOR: not repetition, but resolution.
	local BURST = 20
	local ASYNC_LOADS = 10
	-- What one load is given before it is called gone. Short on purpose: a load that
	-- has genuinely gone away should answer promptly and let this spec fail on its
	-- own assertion rather than on the runner's budget.
	local LOAD_TIMEOUT = 10
	-- How long the body waits for the worker that runs the loads. Longer than one
	-- load's own timeout, so a merely slow load reports `failures` instead of being
	-- cut off, and DERIVED from it rather than picked. See the worker block below
	-- for why the join is bounded at all.
	local JOIN_TIMEOUT = LOAD_TIMEOUT + 5
	-- A burst may not begin unless this much budget is already free. Guards the one
	-- way a bounded burst could still reach the ceiling: starting from a thread that is
	-- already deep.
	local HEADROOM_FLOOR = 40
	-- The most ONE load may cost and still leave the async burst safe: ASYNC_LOADS at
	-- this rate stay inside HEADROOM_FLOOR even if every rung carries. DERIVED from the
	-- two constants above rather than picked, so moving either moves this and no
	-- separate judgement call is smuggled in. It is a budget, not a prediction of the
	-- real cost: the real cost is read and printed, and one rung per load is what the
	-- source shape predicts.
	local RUNG_BUDGET_PER_LOAD = math.floor((HEADROOM_FLOOR - 1) / ASYNC_LOADS)

	-- Cleaned up from afterEach as well as inline, for the reason AwaitSaveContract
	-- and DeferredWakeBarrier both give: a trailing Cleanup() is skipped when an
	-- assertion throws, and a live entry then fails unrelated specs downstream.
	local harness: any = nil

	afterEach(function()
		if harness then
			harness.Cleanup()
			harness = nil
		end
	end)

	--- Queue one chain of nested defers and return immediately. `Reached` is the
	--- number of links that ran, which is the headroom the CALLING thread had at the
	--- moment this was issued. Non-yielding on purpose -- see the header.
	local function startChain(): { Reached: number }
		local handle = { Reached = 0 }
		local function step()
			handle.Reached += 1
			if handle.Reached >= CHAIN_CAP then
				return
			end
			task.defer(step)
		end
		task.defer(step)
		return handle
	end

	--- Did any reading in this set run into the instrument's OWN safety cap rather
	--- than into an engine ceiling? Defined once and called by all three specs,
	--- because it is the only term here that is not a difference between two
	--- readings: two readings that are both CHAIN_CAP subtract to zero, which is
	--- also exactly what a perfectly cheap code path looks like. Spelling the
	--- comparison out three times would let two of the copies drift while the third
	--- kept catching things; one function cannot.
	local function anyCapped(handles: { { Reached: number } }): boolean
		for _, handle in handles do
			if handle.Reached >= CHAIN_CAP then
				return true
			end
		end
		return false
	end

	--- Wait for every chain to stop growing, bounded in frames and in wall clock.
	--- Never waits on a specific callback, so a dropped one costs nothing.
	local function settle(handles: { { Reached: number } })
		local last, stable = -1, 0
		local deadline = os.clock() + SETTLE_TIMEOUT
		while stable < SETTLE_STABLE_FRAMES and os.clock() < deadline do
			task.wait()
			local total = 0
			for _, handle in handles do
				total += handle.Reached
			end
			if total == last then
				stable += 1
			else
				last, stable = total, 0
			end
		end
	end

	--- One reading taken from a thread freshly resumed by the engine, used as the
	--- safety guard before a burst. Yields, so it can only be used OUTSIDE a
	--- measurement window; the in-window reference is always a chain armed in the same
	--- unbroken stretch as the burst itself.
	local function preflight(): number
		task.wait()
		local probe = startChain()
		settle({ probe })
		return probe.Reached
	end

	--- Park, and be woken from inside a deferred callback -- the bug's mechanism with
	--- Scribe removed. Timer-backed so that a DROPPED wake reports "dropped" instead of
	--- parking the runner forever; on a fresh thread it can never be reached, which is
	--- itself worth asserting.
	local function wakeOnce(): string
		local waiter = coroutine.running()
		local wokenBy: string? = nil
		task.defer(function()
			if wokenBy ~= nil then
				return
			end
			wokenBy = "defer"
			task.spawn(waiter)
		end)
		task.delay(2, function()
			if wokenBy ~= nil then
				return
			end
			wokenBy = "dropped"
			task.spawn(waiter)
		end)
		coroutine.yield()
		return wokenBy :: string
	end

	--- Total writes the fake has recorded, across every key. Summed rather than keyed,
	--- so the assertion does not depend on the "Default/PLAYER_<id>" key format the
	--- harness happens to produce.
	local function totalSaves(fake: any): number
		local total = 0
		for _, count in fake.SaveCounts do
			total += count
		end
		return total
	end

	describe("engine re-entrancy budget", function()
		itEngine("the instrument reads a real ceiling, and a deferred wake promotes the thread it wakes", function()
			-- THE SPEC EVERYTHING ELSE RESTS ON, and the only artefact in the repo that
			-- executes the causal claim the two shipped fixes were built on. The comment
			-- blocks in Persistence.luau, Client/init.luau and
			-- DeferredWakeBarrier.spec.luau USED TO assert that a thread woken from
			-- inside a deferred callback inherits that callback's generation and keeps it
			-- for good, with nothing anywhere running the claim and Lune structurally
			-- unable to. Twelve lines of task.defer + task.spawn + coroutine.yield with
			-- no Scribe in them settled it, and split the verdict: inheritance
			-- confirmed, permanence refuted. All three blocks now carry that outcome and
			-- cite the readings at the top of this file.
			task.wait()
			local fresh = startChain()
			local woken = table.create(3)
			for i = 1, 3 do
				woken[i] = wakeOnce()
			end
			-- Armed in the same stretch as the third wake -- no task.wait between --
			-- because a frame boundary is exactly what would destroy the reading.
			local promoted = startChain()
			settle({ fresh, promoted })

			-- A second pair, a frame apart, answering two questions at once: whether a
			-- climbed rung SURVIVES a task.wait (which decides whether this whole bug
			-- class is frame-bounded, and therefore how much site 2 matters), and
			-- whether two consecutive frame resumptions read the same (which is what
			-- every before/after comparison in this file depends on).
			task.wait()
			local afterFrame = startChain()
			task.wait()
			local repeated = startChain()
			settle({ afterFrame, repeated })

			local perWake = (fresh.Reached - promoted.Reached) / 3
			local survivesFrame = afterFrame.Reached < fresh.Reached
			local rate = string.format("%.2f", perWake)
			local wokenBy = table.concat(woken, ",")
			-- THE INTERPRETATION KEY FOR THE WHOLE TIER. Read this line before trusting
			-- any other number in this file. `survivesFrame` in particular is the one
			-- fact no amount of source reading settles: if a climbed rung does NOT
			-- survive a task.wait, the entire bug class is frame-bounded, only an
			-- unyielding burst can ever reach the ceiling, and site 2 -- which crosses a
			-- frame on every load by construction -- is provably zero risk rather than
			-- merely low. It is PRINTED and asserted in neither direction, because both
			-- answers are consistent with a correct tree, and that has to stay true of the
			-- DESIGN however the reading falls -- see the header on not simplifying this
			-- file against the answer now in hand. This print is where the question was
			-- settled. test/Sim/Available.luau and the comment blocks in
			-- src/Server/Persistence.luau and src/Client/init.luau carried the opposite
			-- assumption until it ran; they now carry the consequence and point back here
			-- for the numbers.
			print(
				`[reentrancy] fresh={fresh.Reached} after3wakes={promoted.Reached} perWake={rate} `
					.. `afterFrame={afterFrame.Reached} survivesFrame={survivesFrame} repeat={repeated.Reached} `
					.. `wokenBy={wokenBy}`
			)

			-- `promotes` is asserted rather than merely printed, and it is the ALARM on
			-- an unmeasured premise rather than a restatement of a settled one. If this
			-- engine does NOT promote a thread woken from a deferred callback, the
			-- rationale behind the AwaitSave and Client.Request fixes needs revisiting,
			-- and a green tick would bury that. `capped` false proves a ceiling exists at all.
			-- `stable` proves the reading is repeatable frame to frame, which is the
			-- premise the other two specs' before/after arithmetic rests on.
			local summary = `capped={anyCapped({ fresh, promoted, afterFrame, repeated })} woken={wokenBy} `
				.. `promotes={perWake >= 1} stable={afterFrame.Reached == repeated.Reached}`
			expect(summary).to.equal("capped=false woken=defer,defer,defer promotes=true stable=true")
		end)

		itEngine("a burst of AwaitSave calls spends none of the caller's budget", function()
			-- WHAT THIS ADDS OVER THE LUNE BARRIER, precisely. DeferredWakeBarrier asks
			-- "did the caller park?". This asks "was the caller PROMOTED?". Against a
			-- synchronous store those coincide, which is why the shape check is enough
			-- in CI -- but they come apart on the two shapes CI cannot reach. A
			-- promotion arriving by a route that is not the caller's own park (a Metrics
			-- hook, a Health transition, a future Replication helper doing Sched.Defer +
			-- Sched.Resume on the flush path) would leave the child DEAD and, on the
			-- predicted mechanism, still cost a rung. No such route exists on this path
			-- today, so that half is reasoning about a shape rather than a reading. And
			-- against a store that yields, which is every production store, parking is
			-- CORRECT and the shape check is void by construction while this one still
			-- asks the real question.
			--
			-- WHAT ITERATION TWENTY PROVES THAT ITERATION ONE DOES NOT. One rung is
			-- inside the noise of any single reading; twenty rungs is not. A FRACTIONAL
			-- ratchet -- a defer on one call in twenty, on a slow or dirty branch, or
			-- when an autosave interval coincides -- is invisible at N=1 and is exactly
			-- one unmistakable rung here. And the loop is not decoration: Coins.Set(i)
			-- on every pass keeps the profile genuinely dirty so no durability short
			-- circuit fires, and the save count is asserted to have advanced by the full
			-- burst.
			harness = TestCtx.make()
			local _player, entry, data = harness.Join(64301)

			local headroom = preflight()
			if headroom < HEADROOM_FLOOR then
				expect(`headroom={headroom} floor={HEADROOM_FLOOR}`).to.equal(`headroom>=floor floor={HEADROOM_FLOOR}`)
			end

			local savesBefore = totalSaves(harness.Fake)
			-- Reference and result are both armed inside one unbroken stretch,
			-- straddling the burst. No task.wait may appear between these two lines.
			local before = startChain()
			local verdicts = 0
			for i = 1, BURST do
				data.Coins.Set(i)
				if harness.Ctx.Persistence.AwaitSave(entry, 5) then
					verdicts += 1
				end
			end
			local after = startChain()
			settle({ before, after })

			local spent = before.Reached - after.Reached
			local saves = totalSaves(harness.Fake) - savesBefore
			-- Spec 1's term, lifted verbatim, and load-bearing rather than informational:
			-- two readings that are both CHAIN_CAP subtract to `spent=0`, so without this
			-- the assertion below hands a clean bill of health to a realm that has no
			-- ceiling to spend. It did exactly that under Lune with the gate forced true.
			local capped = anyCapped({ before, after })
			harness.Cleanup()
			harness = nil

			print(
				`[reentrancy] AwaitSave x{BURST} headroom={headroom} before={before.Reached} `
					.. `after={after.Reached} spent={spent} capped={capped}`
			)
			local summary = `capped={capped} spent={spent} verdicts={verdicts} saves={saves}`
			expect(summary).to.equal(`capped=false spent=0 verdicts={BURST} saves={BURST}`)
		end)

		itEngine("one async load spends a bounded number of rungs in waitStateChangedUntil", function()
			-- SITE 2, QUANTIFIED RATHER THAN FIXED. `waitStateChangedUntil` still wakes
			-- its caller from inside a Sched.Defer callback, deliberately: the obvious
			-- inline transformation returns control from the middle of finishLoad and
			-- turns ReadyOrdering red. Whether that wake promotes its caller is PREDICTED by
			-- the mechanism and has never been seen; what this spec reads is the COST --
			-- `perLoad`, the rungs one load spends, taken from a reference armed before it.
			-- Measuring absolute depth means climbing toward the ceiling; measuring one
			-- load's cost does not.
			--
			-- WHAT IS ASSERTED, WHAT IS ONLY PRINTED, AND WHY THE LINE FALLS THERE.
			-- What is asserted is an ENVELOPE, `spent[i] <= i * budget`, which holds under
			-- BOTH answers to `survivesFrame` for any tree whose loads fit the budget and
			-- breaks under both for one whose loads do not -- see the block beside the
			-- computation for why it is answer-independent. The SLOPE is not asserted, and
			-- this is the correction that matters:
			-- on a tree where a climbed rung survives a frame, a CONSTANT per-load cost
			-- produces a rising slope all by itself, so `slope > 0` is what a correct tree
			-- looks like under one answer and a hazard under the other -- and one reading
			-- cannot be both a pass and a fail. This spec used to assert
			-- `accumulates=false`, and on a fully correct tree with surviving rungs that
			-- assertion FAILS, reporting `spent=[1,2,3,4,5,6,7,8,9,10] slope=1.000` -- a
			-- clean rising line, which is the one reading it was written to catch. Correct
			-- and broken hand it the same number, so it could not tell them apart, and a
			-- spec that cannot is worse than no spec. Slope and the projected
			-- loads-to-ceiling are printed instead, to be read beside spec 1's
			-- `survivesFrame`: together those two lines say what site 2 costs and whether
			-- the cost can ever add up.
			--
			-- YieldOnSessionStart is the only way to reach this code path at all, which
			-- is why the Lune suite has never once executed site 2: the fake store
			-- returns without yielding, so every other spec takes WaitForData's "already
			-- Ready" branch.
			--
			-- NO task.wait BETWEEN LOADS, on the thread being measured. IF a frame boundary
			-- re-bases a thread -- the unmeasured question again -- an explicit yield would
			-- reset the very thing being measured and the spec would report a flat cost
			-- whatever the code did. If it does not re-base, the yield is merely noise.
			-- Omitting it is right under both answers, so it is omitted. The load's own
			-- yield is the only frame boundary the worker crosses, and that is the point:
			-- it is a property of the code under test, not of the harness. The join loop
			-- below does yield, but on the BODY's thread, which takes no readings.
			harness = TestCtx.make()
			harness.Fake.YieldOnSessionStart = true

			local headroom = preflight()
			if headroom < HEADROOM_FLOOR then
				expect(`headroom={headroom} floor={HEADROOM_FLOOR}`).to.equal(`headroom>=floor floor={HEADROOM_FLOOR}`)
			end

			-- ON A WORKER, JOINED WITH A BOUNDED WAIT. The reference and all ten probes
			-- are armed by this worker, so every reading is still taken on one thread and
			-- the differences still mean what they meant. What changes is the failure
			-- mode: the thread that parks on a wake is no longer the runner's, so a wake
			-- the engine drops costs this spec its assertion instead of costing the suite
			-- its life. `task.spawn` starts the worker INLINE, so `before` is armed before
			-- this line returns and no frame separates it from the first load.
			local before: any = nil
			local probes = table.create(ASYNC_LOADS)
			local players = table.create(ASYNC_LOADS)
			local failures = 0
			local completed = 0
			task.spawn(function()
				before = startChain()
				for i = 1, ASYNC_LOADS do
					local player = FakePlayer.new(64400 + i)
					players[i] = player
					harness.Ctx.Persistence.OnPlayerAdded(player)
					local accessor = harness.Ctx.Persistence.WaitForData(player, LOAD_TIMEOUT)
					-- Armed the instant WaitForData returns, before anything else can
					-- yield: this records the generation the waiter was woken into.
					probes[i] = startChain()
					if accessor == nil then
						failures += 1
					end
					completed = i
				end
			end)
			-- Bounded in frames and in wall clock, for the same reason `settle` is: this
			-- never waits on a specific callback, only on a counter it can also give up
			-- on. A worker that never finishes stays parked for the life of the place --
			-- one leaked thread, holding a session the afterEach Cleanup ends anyway --
			-- which is a cost worth paying to keep the runner's own thread free.
			local joinDeadline = os.clock() + JOIN_TIMEOUT
			while completed < ASYNC_LOADS and os.clock() < joinDeadline do
				task.wait()
			end
			settle({ before, table.unpack(probes) })

			-- These players were minted directly rather than through harness.Join, so the
			-- harness's own joined list does not know about them and Cleanup would leave
			-- ten live entries holding session locks. Released here, AFTER settle, so the
			-- teardown's own yields cannot land inside the measurement window.
			for _, player in players do
				if harness.Ctx.Persistence.EntryFor(player) then
					harness.Leave(player)
				end
			end

			-- Over `completed`, not ASYNC_LOADS: a short run is a real outcome now, and
			-- indexing past it would turn the honest report into a nil-index traceback.
			local spent = table.create(completed)
			for i = 1, completed do
				spent[i] = before.Reached - probes[i].Reached
			end
			local first = if completed >= 1 then spent[1] else -1
			local last = if completed >= 1 then spent[completed] else -1
			local peak = first
			for _, value in spent do
				peak = math.max(peak, value)
			end
			-- THE ANSWER-INDEPENDENT ENVELOPE, and the only assertion here about cost.
			-- Reading `i` straddles exactly `i` loads. If a frame boundary re-bases a
			-- thread, `spent[i]` is load i's OWN cost; if a climbed rung survives, it is
			-- the running total of the first i. `spent[i] <= i * budget` is satisfied by
			-- both -- a tree whose every load fits the budget cannot break it under
			-- either rule -- and violated by both when a load does not: at i=1 when the
			-- extra cost is uniform, at i=k when it only appears from the k-th load on.
			-- That last case is why this is a loop and not just `spent[1]`: a term that
			-- reads only the first load is blind to a path that is cheap once and
			-- expensive afterwards, and under the re-basing answer nothing else here
			-- would catch it. Measured on a synthetic ceiling: uniform +3 rungs/load and
			-- from-the-second-load +10 rungs/load both fail this under BOTH answers,
			-- while a correct tree passes under both.
			local inBudget = true
			for i, value in spent do
				inBudget = inBudget and value >= 0 and value <= i * RUNG_BUDGET_PER_LOAD
			end
			-- Spec 1's term again, and here it guards ten differences rather than one.
			-- Every number in `spent` is a subtraction of two readings, and two readings
			-- that are both CHAIN_CAP subtract to zero -- indistinguishable from a load
			-- path that costs nothing. A single reading at the cap makes the whole vector
			-- uninterpretable, so what is checked is the readings, not the differences.
			local capped = anyCapped({ before, table.unpack(probes) })
			-- Per-load slope over the sample, PRINTED and never asserted -- see the block
			-- at the top of this spec for why. Zero means the cost is paid once per load
			-- and discarded; positive means EITHER that rungs survive the loop's frame
			-- boundaries (correct-tree behaviour under one answer to `survivesFrame`) OR
			-- that the load path itself compounds, and this reading alone cannot separate
			-- those. `loadsToCeiling` projects that printed slope forward: an extrapolation
			-- off ten samples, not a limit anybody has reached.
			local slope = if completed >= 2 then (last - first) / (completed - 1) else 0
			local loadsToCeiling = if slope <= 0 then "inf" else tostring(math.ceil((before.Reached - first) / slope))
			harness.Cleanup()
			harness = nil

			print(
				`[reentrancy] site2 headroom={headroom} before={before.Reached} spent=[{table.concat(spent, ",")}] `
					.. `completed={completed}/{ASYNC_LOADS} perLoad={first} peak={peak} `
					.. `budget={RUNG_BUDGET_PER_LOAD} capped={capped}`
			)
			print(
				`[reentrancy] site2 NOT ASSERTED slope={string.format("%.3f", slope)} `
					.. `loadsToCeiling={loadsToCeiling} -- meaningless without spec 1's survivesFrame`
			)

			-- The cost per load is NOT asserted to be zero: the source shows one deferred
			-- wake per load, so one rung is what the shape predicts, and that is the
			-- accepted trade for ReadyOrdering. What IS asserted is that one load's own
			-- cost fits the derived budget, at EVERY reading and not just the first --
			-- which fails a change that adds promotions to the load path whichever way the
			-- frame question falls -- and that no reading in the sample ran away from the
			-- pre-flight floor. `completed` is asserted first among them because a burst
			-- that stopped early has no reading worth interpreting: it is what a wake the
			-- engine dropped looks like from here.
			local summary = `completed={completed} failures={failures} capped={capped} `
				.. `everyLoadInBudget={inBudget} peakUnderFloor={peak < HEADROOM_FLOOR}`
			expect(summary).to.equal(
				`completed={ASYNC_LOADS} failures=0 capped=false everyLoadInBudget=true peakUnderFloor=true`
			)
		end)
	end)
end
