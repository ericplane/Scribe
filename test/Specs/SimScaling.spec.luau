--!nonstrict
-- The kernel has to stay linear in the number of concurrently sleeping threads,
-- because "thousands upon thousands of players at once" is the question the
-- simulation exists to answer. A quadratic scheduler cannot answer it -- not
-- slowly, but at all, since the harness caps each test at ten seconds.
--
-- These are RATIO tests, never wall-clock budgets. An absolute millisecond bound
-- is a promise about the machine, and CI runners are not the machine; a ratio is
-- a promise about the algorithm, which is the thing actually being asserted.

return function()
	local Root = script.Parent.Parent.Parent
	local Scheduler = require(Root.Test.Sim.Scheduler)

	--- Time a run with `n` threads whose wake times are all DISTINCT.
	---
	--- Distinctness is the whole point. Shared wake times let the scheduler release
	--- a whole batch per advance, which stays cheap even with a bad data structure
	--- and would hide the defect this guards. Independent latency per in-flight
	--- request -- the storage pattern being simulated -- produces distinct times.
	local function timeDistinctWakes(n: number): number
		local sched = Scheduler.new(1)
		for i = 1, n do
			sched:Spawn(function()
				for _ = 1, 5 do
					sched:Wait(i * 0.001)
				end
			end)
		end
		local t0 = os.clock()
		sched:Run()
		return os.clock() - t0
	end

	describe("sleeper scaling", function()
		it("stays linear in concurrent sleepers with all-distinct wake times", function()
			local small = timeDistinctWakes(2000)
			local large = timeDistinctWakes(8000) -- 4x the threads

			-- Linear predicts ~4x, quadratic ~16x. The bar sits between them on a
			-- log scale, so ordinary timing noise cannot push a linear kernel over
			-- and a quadratic one cannot squeak under.
			--
			-- The floor keeps a fast machine from dividing by a near-zero baseline
			-- and manufacturing a huge ratio out of measurement noise.
			local ratio = large / math.max(small, 0.001)
			expect(ratio < 8).to.equal(true)
		end)

		it("releases equal wake times into the ready set in registration order", function()
			-- A heap orders equal keys however its swaps happen to land, so the
			-- sleeper entries carry an insertion sequence to break ties. That rule
			-- is checked HERE, at the release point, because it is not observable
			-- downstream: Step then shuffles the ready set by seed, which is
			-- deliberate and hides the order threads arrived in.
			--
			-- Conflating the two is easy and wrong. "Woken in registration order"
			-- describes entry into the runnable set; it never described the order
			-- they resume, which the seed decides on purpose.
			local sched = Scheduler.new(99)
			local threads = {}
			for i = 1, 40 do
				threads[i] = sched:Spawn(function()
					sched:Wait(5) -- identical for every thread
				end)
			end

			sched:_advance() -- release everything due at the earliest wake time

			expect(#sched._ready).to.equal(40)
			for i = 1, 40 do
				expect(sched._ready[i]).to.equal(threads[i])
			end
		end)

		it("gives a seed one run even when every thread wakes together", function()
			local function orderAtEqualWakes()
				local sched = Scheduler.new(99)
				local order = {}
				for i = 1, 40 do
					sched:Spawn(function()
						sched:Wait(5)
						table.insert(order, i)
					end)
				end
				sched:Run()
				return table.concat(order, ",")
			end

			local first = orderAtEqualWakes()
			expect(orderAtEqualWakes()).to.equal(first)

			-- Every thread accounted for, and NOT in plain registration order --
			-- the ready set is shuffled by design, so a run that came back sorted
			-- would mean the shuffle had stopped happening.
			local sorted = {}
			for i = 1, 40 do
				sorted[i] = tostring(i)
			end
			expect(#first:split(",")).to.equal(40)
			expect(first).never.to.equal(table.concat(sorted, ","))
		end)

		it("wakes in wake-time order regardless of insertion order", function()
			local sched = Scheduler.new(1)
			local woke = {}
			-- Registered latest-first, so a structure that ignored WakeAt and just
			-- drained insertion order would produce exactly the reverse.
			for i = 20, 1, -1 do
				sched:Spawn(function()
					sched:Wait(i)
					table.insert(woke, i)
				end)
			end
			sched:Run()

			expect(#woke).to.equal(20)
			for i = 1, 20 do
				expect(woke[i]).to.equal(i)
			end
		end)
	end)
end
