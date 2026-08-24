--!nonstrict
-- The simulation kernel: seeded scheduler, virtual clock, replay digest.
--
-- Everything a simulation can ever prove rests on one property -- that a seed
-- names exactly one run. These specs are that property, checked rather than
-- assumed: the same seed must produce an identical digest, and different seeds
-- must not (or the scheduler is not actually shuffling anything and the whole
-- exercise is one fixed interleaving wearing a costume).

return function()
	local Root = script.Parent.Parent.Parent
	local Scheduler = require(Root.Test.Sim.Scheduler)
	local Digest = require(Root.Test.Sim.Digest)
	local Rng = require(Root.Test.Sim.Rng)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Sched = require(Root.Scribe.Internal.Sched)

	--- A workload whose threads genuinely CONTEND: they wake at the same virtual
	--- times, so the ready set repeatedly holds more than one runnable thread and
	--- the seeded pick actually decides something.
	---
	--- The first version gave each worker its own wait duration (1,2,3,4). That
	--- reads like more variety, but it produces LESS: distinct durations mean
	--- distinct wake times, the ready set holds one thread almost always, and the
	--- ordering is then fixed by arithmetic with the scheduler never making a
	--- choice. Paired durations are what put threads in the set together.
	local DURATIONS = { 1, 1, 2, 2 }

	local function run(seed: number)
		local sched = Scheduler.new(seed)
		local log = {}
		for worker = 1, 4 do
			sched:Spawn(function()
				for step = 1, 5 do
					table.insert(log, `w{worker}:s{step}@{sched.Now}`)
					sched:Wait(DURATIONS[worker])
				end
			end)
		end
		sched:Run()
		return { Log = log, Now = sched.Now, Steps = sched.Steps }
	end

	describe("determinism", function()
		it("gives the same seed an identical run", function()
			local a, b = run(4171), run(4171)
			expect(Digest.Of(a)).to.equal(Digest.Of(b))
			expect(#a.Log).to.equal(20)
		end)

		it("gives different seeds different interleavings", function()
			-- If this fails the scheduler is not shuffling, and every other
			-- simulation result would be one arbitrary ordering reported as if it
			-- were a search.
			local seen = {}
			for seed = 1, 12 do
				seen[Digest.Of(run(seed).Log)] = true
			end
			local distinct = 0
			for _ in seen do
				distinct += 1
			end
			-- Was `> 1`, which a nearly-FIFO generator satisfied. With a working
			-- generator almost every seed should give its own ordering, so the bar is
			-- most of them -- low enough to tolerate an occasional collision, high
			-- enough that a collapsed generator cannot pass.
			expect(distinct >= 10).to.equal(true)
		end)

		it("reaches the same end state whatever the interleaving", function()
			-- Ordering varies; the total does not. This is the shape every real
			-- invariant takes: something that must hold across every schedule.
			for seed = 1, 8 do
				local result = run(seed)
				expect(#result.Log).to.equal(20)
				expect(result.Now).to.equal(1700000000 + 10) -- slowest workers: 5 waits of 2
			end
		end)
	end)

	describe("virtual time", function()
		it("advances only when nothing can run", function()
			local sched = Scheduler.new(1)
			local marks = {}
			sched:Spawn(function()
				table.insert(marks, sched.Now)
				sched:Wait(0) -- cooperate without claiming to have slept
				table.insert(marks, sched.Now)
				sched:Wait(3600)
				table.insert(marks, sched.Now)
			end)
			sched:Run()
			expect(marks[1]).to.equal(1700000000)
			expect(marks[2]).to.equal(1700000000) -- a zero wait costs no time
			expect(marks[3]).to.equal(1700000000 + 3600)
		end)

		it("jumps a whole day in one step rather than ticking to it", function()
			local sched = Scheduler.new(1)
			sched:Spawn(function()
				sched:Wait(86400)
			end)
			sched:Run()
			expect(sched.Now).to.equal(1700000000 + 86400)
			-- ONE scheduled resume: the wake. Spawn ran the thread immediately on
			-- the caller's stack (matching task.spawn), so starting it costs no
			-- scheduler step at all, and the day in between is skipped rather than
			-- simulated. That is what makes eight hours cost microseconds.
			expect(sched.Steps).to.equal(1)
		end)

		it("never moves backwards", function()
			local sched = Scheduler.new(7)
			local last = sched.Now
			local ok = true
			for _ = 1, 5 do
				sched:Spawn(function()
					for _ = 1, 6 do
						if sched.Now < last then
							ok = false
						end
						last = sched.Now
						sched:Wait(sched.Rng:NextInteger(50))
					end
				end)
			end
			sched:Run()
			expect(ok).to.equal(true)
		end)
	end)

	describe("Scribe clock binding", function()
		it("drives Scribe's Clock seam from the scheduler", function()
			local sched = Scheduler.new(99)
			Clock.Install(sched:ClockImpl())

			expect(Clock.Now()).to.equal(1700000000)
			sched:Spawn(function()
				Clock.Wait(7200) -- two hours, through Scribe's own seam
			end)
			sched:Run()
			expect(Clock.Now()).to.equal(1700000000 + 7200)

			Clock.Reset()
			expect(Clock.Now()).never.to.equal(1700000000)
		end)

		it("makes Monotonic virtual too, not just Now", function()
			-- Found by mutation: swapping the scheduler's Monotonic for the real
			-- os.clock broke nothing, because the test above only checked Now. But
			-- Scribe measures every INTERVAL with Monotonic -- rate-limit buckets,
			-- retry backoff, refresh scheduling -- so a real one there leaves a
			-- simulation non-deterministic in exactly the paths a simulation exists
			-- to explore, while still looking like it fast-forwards.
			local sched = Scheduler.new(1)
			Clock.Install(sched:ClockImpl())

			local before = Clock.Monotonic()
			sched:Spawn(function()
				Clock.Wait(600)
			end)
			sched:Run()
			-- Exactly the elapsed virtual time, not "roughly" -- a real timer would
			-- add its own microseconds and never land on a round number.
			expect(Clock.Monotonic() - before).to.equal(600)
			expect(Clock.Monotonic()).to.equal(Clock.Now())

			Clock.Reset()
		end)
	end)

	describe("Spawn vs Defer", function()
		it("runs a Spawn immediately, on the caller's stack", function()
			-- The distinction that matters most in the whole kernel. task.spawn runs
			-- its function NOW; code across Scribe relies on a spawned load that does
			-- not yield having already finished when Spawn returns. A kernel that
			-- queued instead would still run everything eventually, and quietly
			-- reorder every one of those call sites.
			local sched = Scheduler.new(1)
			local ran = false
			sched:Spawn(function()
				ran = true
			end)
			expect(ran).to.equal(true) -- before Run() is ever called
		end)

		it("queues a Defer until the loop reaches it", function()
			local sched = Scheduler.new(1)
			local ran = false
			sched:Defer(function()
				ran = true
			end)
			expect(ran).to.equal(false)
			sched:Run()
			expect(ran).to.equal(true)
		end)

		it("drives Scribe's Sched seam", function()
			local sched = Scheduler.new(3)
			Sched.Install(sched:SchedImpl())

			local order = {}
			Sched.Spawn(function()
				table.insert(order, "spawn")
			end)
			Sched.Defer(function()
				table.insert(order, "defer")
			end)
			table.insert(order, "caller")
			sched:Run()

			-- Spawn ran before the caller resumed; Defer ran after it.
			expect(table.concat(order, ",")).to.equal("spawn,caller,defer")

			Sched.Reset()
		end)

		it("resumes a blocked thread through Resume, not Spawn", function()
			-- The overload split. task.spawn(thread, ...) answers a coroutine that is
			-- already blocked; task.spawn(fn, ...) starts a new one. Routing both to
			-- one entry would have the kernel call coroutine.create on a thread.
			local sched = Scheduler.new(11)
			Sched.Install(sched:SchedImpl())

			local answer = nil
			local blocked
			sched:Spawn(function()
				blocked = coroutine.running()
				answer = coroutine.yield() -- blocked on an answer, not on time
			end)
			expect(answer).to.equal(nil)

			Sched.Resume(blocked, "reply")
			expect(answer).to.equal("reply")
			-- The value arriving is NOT evidence the seam was used: the default
			-- Resume is the engine's own task.spawn, which would have delivered it
			-- just as well. Live accounting is the part only the kernel does, so it
			-- is what separates "routed" from "happened to work anyway".
			expect(sched.Live).to.equal(0)

			Sched.Reset()
		end)

		it("installs and resets all three entries, not just the ones in use", function()
			-- Found by mutation: every Resume assertion above still passed with
			-- Install and Reset ignoring Resume entirely, because the default is the
			-- real task.spawn and it does the job. A seam that silently fails to
			-- install is worse than no seam -- the simulation runs, reports a clean
			-- schedule, and never controlled the thing it claimed to.
			local seen = {}
			Sched.Install({
				Spawn = function(fn, ...)
					table.insert(seen, "spawn")
					return task.spawn(fn, ...)
				end,
				Defer = function(fn, ...)
					table.insert(seen, "defer")
					return task.defer(fn, ...)
				end,
				Resume = function(thr, ...)
					table.insert(seen, "resume")
					task.spawn(thr, ...)
				end,
			})

			local blocked
			Sched.Spawn(function()
				blocked = coroutine.running()
				coroutine.yield()
			end)
			Sched.Defer(function() end)
			Sched.Resume(blocked)
			expect(table.concat(seen, ",")).to.equal("spawn,defer,resume")

			-- ...and Reset must unhook every one of them.
			Sched.Reset()
			table.clear(seen)
			local blocked2
			Sched.Spawn(function()
				blocked2 = coroutine.running()
				coroutine.yield()
			end)
			Sched.Defer(function() end)
			Sched.Resume(blocked2)
			expect(#seen).to.equal(0)
		end)

		it("refuses to resume a thread that is not suspended", function()
			-- Matching the engine, which errors on this. A kernel that shrugged
			-- instead would replay a double-resume crash as a clean run.
			local sched = Scheduler.new(1)
			local finished
			sched:Spawn(function()
				finished = coroutine.running()
			end)
			expect(coroutine.status(finished)).to.equal("dead")
			expect(function()
				sched:Resume(finished)
			end).to.throw()
		end)
	end)
	describe("liveness", function()
		it("reports a deadlock instead of ending quietly", function()
			-- The failure a storage simulation exists to catch. A thread parked on an
			-- answer that never arrives IS "the save never completed", and before
			-- Deadlocked existed this run returned with Live=1, Stalled=false, and
			-- nothing to distinguish it from a clean finish.
			local sched = Scheduler.new(1)
			sched:Spawn(function()
				coroutine.yield()
			end)
			sched:Run()

			expect(sched.Live).to.equal(1)
			expect(sched.Deadlocked).to.equal(true)
			expect(sched:Settled()).to.equal(false)
		end)

		it("counts a normal finish as settled", function()
			local sched = Scheduler.new(1)
			sched:Spawn(function()
				sched:Wait(5)
			end)
			sched:Run()
			expect(sched.Live).to.equal(0)
			expect(sched.Deadlocked).to.equal(false)
			expect(sched:Settled()).to.equal(true)
		end)

		it("does not call a time-bounded stop a deadlock", function()
			-- Run(untilTime) legitimately leaves work pending. Calling that a
			-- deadlock would cry wolf on every bounded run, and a liveness signal
			-- that fires on healthy runs gets ignored.
			local sched = Scheduler.new(1)
			sched:Spawn(function()
				sched:Wait(1000)
			end)
			sched:Run(sched.Now + 10)
			expect(sched.Deadlocked).to.equal(false)
			expect(sched.Live).to.equal(1)
			expect(sched:Settled()).to.equal(false) -- pending, but not broken
		end)

		it("does not cry stall when the last allowed step was also the last needed", function()
			-- Found by mutation: Run set Stalled purely because the loop exited on
			-- the limit, so a run that finished all its work on exactly its final
			-- allowed step reported Live=0 alongside Stalled=true. A liveness signal
			-- that fires on healthy runs is one nobody reads.
			local probe = Scheduler.new(1)
			probe:Spawn(function()
				for _ = 1, 4 do
					probe:Wait(1)
				end
			end)
			local used = probe:Run()

			local exact = Scheduler.new(1)
			exact:Spawn(function()
				for _ = 1, 4 do
					exact:Wait(1)
				end
			end)
			exact:Run(nil, used) -- a limit of exactly the steps the work needs

			expect(exact.Live).to.equal(0)
			expect(exact.Stalled).to.equal(false)
			expect(exact:Settled()).to.equal(true)
		end)
		it("counts a stalled run as unsettled too", function()
			local sched = Scheduler.new(1)
			sched:Spawn(function()
				while true do
					sched:Wait(0) -- cooperates forever without finishing
				end
			end)
			sched:Run(nil, 500)
			expect(sched.Stalled).to.equal(true)
			expect(sched:Settled()).to.equal(false)
		end)
	end)
	describe("Rng streams", function()
		it("gives differently-named streams different sequences from one seed", function()
			local a, b = Rng.Stream(4171, "disk.latency"), Rng.Stream(4171, "disk.fault")
			local same = 0
			for _ = 1, 100 do
				if a:NextInteger(1000) == b:NextInteger(1000) then
					same += 1
				end
			end
			-- A handful of coincidental collisions in 100 draws is expected; a
			-- hundred means the label was ignored and both streams are one stream.
			expect(same < 10).to.equal(true)
		end)

		it("reproduces a named stream exactly", function()
			local a = Rng.Stream(99, "bus")
			local b = Rng.Stream(99, "bus")
			for _ = 1, 50 do
				expect(a:NextInteger(10000)).to.equal(b:NextInteger(10000))
			end
		end)

		it("does not merely offset the base sequence", function()
			-- Rng.new(seed + k) would look independent and not be: Rng.new does no
			-- mixing, so nearby seeds start a step apart in the SAME sequence. If
			-- Stream degenerated to that, one stream would be a shifted copy of the
			-- other and a lagged comparison would line up.
			local base = Rng.new(1000)
			local baseDraws = {}
			for i = 1, 60 do
				baseDraws[i] = base:NextInteger(100000)
			end

			local stream = Rng.Stream(1000, "workload")
			local streamDraws = {}
			for i = 1, 60 do
				streamDraws[i] = stream:NextInteger(100000)
			end

			for lag = 0, 5 do
				local matches = 0
				for i = 1, 50 do
					if streamDraws[i] == baseDraws[i + lag] then
						matches += 1
					end
				end
				expect(matches < 40).to.equal(true)
			end
		end)
	end)

	describe("ResumeRaw", function()
		it("accounts for a thread that dies inside a foreign resume", function()
			-- The leak that would make every clean run under real ProfileStore report
			-- a deadlock. ProfileStore parks threads on its update queue with a raw
			-- coroutine.yield and wakes them with a raw coroutine.resume; the kernel
			-- sees neither, so Live never comes back down and Run then reports a
			-- deadlock on a run that finished perfectly.
			local sched = Scheduler.new(1)
			local parked
			sched:Spawn(function()
				parked = coroutine.running()
				coroutine.yield() -- parked the way ProfileStore parks
			end)
			expect(sched.Live).to.equal(1)

			local ok = sched:ResumeRaw(parked)
			expect(ok).to.equal(true)
			expect(sched.Live).to.equal(0)

			sched:Run()
			expect(sched.Deadlocked).to.equal(false)
			expect(sched:Settled()).to.equal(true)
		end)

		it("returns coroutine.resume's values rather than raising", function()
			local sched = Scheduler.new(1)
			local co = coroutine.create(function()
				error("boom", 0)
			end)
			-- Untracked and erroring: must report (false, message) exactly like
			-- coroutine.resume, because that is the contract ProfileStore is written
			-- against. Resume (the seam entry) deliberately raises instead; these are
			-- different functions for different callers.
			local ok, err = sched:ResumeRaw(co)
			expect(ok).to.equal(false)
			-- Contains rather than equals: the host decorates the message with its
			-- own prefix and traceback. What is being asserted is that the failure
			-- came back as a VALUE, not that it was formatted a particular way.
			expect(string.find(tostring(err), "boom", 1, true) ~= nil).to.equal(true)
		end)

		it("does not let an unknown thread push Live negative", function()
			local sched = Scheduler.new(1)
			local foreign = coroutine.create(function() end)
			sched:ResumeRaw(foreign)
			expect(sched.Live).to.equal(0)
		end)
	end)
	describe("harness determinism", function()
		--- A pinnable GUID sequence is a seam the headless runner adds to its own
		--- HttpService; the real one has no equivalent, and nothing can give it one.
		---
		--- The body used to open with `if type(HttpService.ResetGuidSequence) ~=
		--- "function" then return end`, which is two faults in one line. Indexing an
		--- absent member on a real Roblox Instance RAISES rather than returning nil, so
		--- the guard was itself what failed in Studio; and had it worked, the node would
		--- have reported a PASS for a body that ran none of its assertions. Deciding at
		--- registration time reports the truth on both hosts. `typeof` asks whether the
		--- service is a real Instance without touching a member -- see test/Sim/Guard.
		local pinnable = typeof(game:GetService("HttpService")) ~= "Instance"
		local itPinned = if pinnable then it else itSKIP

		itPinned("replays the same GUID sequence from a pinned seed", function()
			-- Util.guid() feeds gift ids and version ids, which land inside persisted
			-- data. The harness used to draw them from the unseeded global
			-- math.random, so stored state differed every run and a digest over it
			-- could never have meant anything.
			local HttpService = game:GetService("HttpService")
			HttpService:ResetGuidSequence(1234)
			local first = {}
			for i = 1, 5 do
				first[i] = HttpService:GenerateGUID(false)
			end

			HttpService:ResetGuidSequence(1234)
			for i = 1, 5 do
				expect(HttpService:GenerateGUID(false)).to.equal(first[i])
			end

			-- ...and a different seed must NOT reproduce it, or "pinned" would just
			-- mean "constant".
			HttpService:ResetGuidSequence(5678)
			expect(HttpService:GenerateGUID(false)).never.to.equal(first[1])
		end)

		it("still produces distinct ids within a run", function()
			local HttpService = game:GetService("HttpService")
			local seen = {}
			for _ = 1, 500 do
				local id = HttpService:GenerateGUID(false)
				expect(seen[id]).to.equal(nil)
				seen[id] = true
			end
		end)
	end)
	describe("Digest", function()
		it("is stable across key insertion order", function()
			local a, b = {}, {}
			a.x, a.y, a.z = 1, 2, 3
			b.z, b.y, b.x = 3, 2, 1
			expect(Digest.Of(a)).to.equal(Digest.Of(b))
		end)

		it("separates values that differ only by type", function()
			expect(Digest.Of({ 1 })).never.to.equal(Digest.Of({ "1" }))
		end)

		it("survives a cyclic table rather than recursing forever", function()
			local t = { name = "loop" }
			t.self = t
			expect(type(Digest.Of(t))).to.equal("string")
		end)
	end)

	describe("Rng", function()
		it("is reproducible and independent of math.random", function()
			local a, b = Rng.new(5150), Rng.new(5150)
			for _ = 1, 50 do
				expect(a:NextInteger(1000)).to.equal(b:NextInteger(1000))
			end
			math.randomseed(1) -- must not disturb the sequence
			local c = Rng.new(5150)
			local d = Rng.new(5150)
			math.randomseed(2)
			expect(c:NextInteger(1000)).to.equal(d:NextInteger(1000))
		end)

		it("is uniform at EVEN n, not just odd", function()
			-- The spec that would have caught a real defect and did not exist. The
			-- previous LCG multiplied by ~2^30, overflowing the double mantissa and
			-- zeroing the low 8 bits, so NextInteger(2) returned 1 on 99.577% of
			-- draws. Reproducibility and range both still passed -- the sequence was
			-- perfectly repeatable and perfectly in range, just not random -- and the
			-- scheduler picks threads with NextInteger(#ready), so the kernel ran one
			-- fixed order while reporting that it searched.
			--
			-- Powers of two are the failure mode, so they are what is asserted.
			for _, n in { 2, 4, 8, 16 } do
				local counts = table.create(n, 0)
				local rng = Rng.new(20250817)
				local draws = 20000
				for _ = 1, draws do
					local v = rng:NextInteger(n)
					counts[v] += 1
				end
				local expected = draws / n
				for bucket = 1, n do
					local share = counts[bucket] / expected
					-- Generous bounds: this is a smoke test for a collapsed generator,
					-- not a chi-squared test of randomness quality.
					expect(share > 0.85 and share < 1.15).to.equal(true)
				end
			end
		end)

		it("varies its low bit, which is what an even-n pick depends on", function()
			local rng = Rng.new(7)
			local ones = 0
			for _ = 1, 20000 do
				if rng:NextInteger(2) == 1 then
					ones += 1
				end
			end
			expect(ones > 9000 and ones < 11000).to.equal(true)
		end)

		it("stays inside its range", function()
			local rng = Rng.new(31337)
			for _ = 1, 200 do
				local n = rng:NextInteger(6)
				expect(n >= 1 and n <= 6).to.equal(true)
			end
		end)
	end)
end
