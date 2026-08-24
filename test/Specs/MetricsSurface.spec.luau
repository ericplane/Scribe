--!nonstrict
-- Metrics percentiles and Reset, plus the configurable log ring.
--
-- The percentile specs are shaped by a defect found in review before this shipped:
-- a design that sorted a SHARED scratch buffer would silently mix a previous name's
-- tail samples into the next name's percentiles whenever the previous name had more
-- of them. Wrong numbers, no error, nothing to notice. TWO multi-name specs below
-- exist to fail if anyone reintroduces it, and both are needed: the first-written
-- one reads the short name first, and in that order the defect is INVISIBLE -- the
-- clamped index means only the smallest values are ever read, and the short name's
-- values already are the smallest. Reintroducing the shared buffer leaves it green.
-- The reversed-ordering case is the one that actually bites.

return function()
	local Root = script.Parent.Parent.Parent
	local Metrics = require(Root.Scribe.Internal.Metrics)
	local Log = require(Root.Scribe.Internal.Log)
	local Scribe = require(Root.Scribe) :: any

	local function reset()
		Metrics.Reset()
	end

	describe("percentiles", function()
		it("returns nothing for a name that was never observed", function()
			reset()
			expect(Metrics.Percentiles("NeverSeen")).to.equal(nil)
		end)

		it("computes nearest-rank percentiles over the samples", function()
			reset()
			for i = 1, 100 do
				Metrics.Observe("Latency", i)
			end
			local p = Metrics.Percentiles("Latency")
			expect(p.P50).to.equal(50)
			expect(p.P90).to.equal(90)
			expect(p.P99).to.equal(99)
		end)

		it("does not let one name's samples leak into another's", function()
			-- The shared-scratch-buffer bug, pinned. `Big` is observed with many
			-- large samples and `Small` with a few tiny ones; if the two shared a
			-- sorted buffer, Small's P99 would come back holding one of Big's values.
			reset()
			for i = 1, 200 do
				Metrics.Observe("Big", 1000 + i)
			end
			for _ = 1, 3 do
				Metrics.Observe("Small", 1)
			end

			local small = Metrics.Percentiles("Small")
			expect(small.P50).to.equal(1)
			expect(small.P90).to.equal(1)
			expect(small.P99).to.equal(1)

			-- ...and Big is unaffected by having been read alongside Small.
			local big = Metrics.Percentiles("Big")
			expect(big.P50 >= 1000).to.equal(true)
		end)

		it("does not let a LONGER name's samples leak into a shorter one's", function()
			-- The reverse ordering, and it is the one that actually bites. The case
			-- above reads the short name FIRST and its values are the SMALLEST, so a
			-- shared buffer is invisible to it: `at()` clamps its index to Filled, so
			-- it only ever reads sorted[1..Filled] -- which, with the small name's
			-- values already the smallest in the polluted union, is exactly the right
			-- answer by accident. Reintroducing a shared scratch buffer leaves the
			-- case above GREEN.
			--
			-- Read the long, small-valued name first and then a short, large-valued
			-- one, and the same defect returns the long name's values instead: the
			-- shorter name's three samples land in slots 1..3 of a buffer still 200
			-- long, and sorting the union puts the previous name's smallest values
			-- where this name's percentiles are read from.
			reset()
			for _ = 1, 200 do
				Metrics.Observe("ManySmall", 1)
			end
			for _ = 1, 3 do
				Metrics.Observe("FewBig", 5000)
			end

			local _ = Metrics.Percentiles("ManySmall") -- read the LONG name first
			local few = Metrics.Percentiles("FewBig")
			expect(`P50={few.P50} P90={few.P90} P99={few.P99}`).to.equal("P50=5000 P90=5000 P99=5000")
		end)

		it("reports every observed name, keyed by name", function()
			-- GetPercentiles' only assertion. It used to live in the `sinks` describe,
			-- reached through the snapshot Publish handed a sink -- so when AddSink and
			-- Publish were removed this became the sole record that GetPercentiles
			-- aggregates per-name results into a table keyed by metric name at all.
			reset()
			for i = 1, 100 do
				Metrics.Observe("Alpha", i)
			end
			for _ = 1, 4 do
				Metrics.Observe("Beta", 42)
			end

			local all = Metrics.GetPercentiles()
			expect(`alpha={all.Alpha.P50} beta={all.Beta.P50}`).to.equal("alpha=50 beta=42")
			-- A name that was never observed is absent rather than present-and-nil.
			expect(all.NeverSeen).to.equal(nil)
		end)

		it("is reachable from the public bundle, not just from the internal module", function()
			-- Holds the WIRING. Every other test in this describe drives Metrics
			-- directly, so all of them stay green with Scribe.GetPercentiles deleted --
			-- which is the state this accessor was added to fix. Percentiles were
			-- computed, documented as a property of the flush-cost distributions in
			-- diagnostics.md, and reachable from no public path at all: GetMetrics
			-- returns { Count, Average, Max } and nothing else.
			--
			-- Asserted against values the average CANNOT produce, so a wiring that
			-- returned the wrong thing could not pass by coincidence. 90 ones and 10
			-- thousands: mean 100.90, but P50 and P90 are exactly 1 and only P99
			-- reaches the tail -- which is the whole reason this accessor exists.
			-- (Nearest-rank over 100 samples, so P99 reads index ceil(0.99*100) = 99;
			-- a single outlier at index 100 would NOT show, which is worth knowing
			-- before reading one of these numbers as a maximum. GetMetrics().Max is
			-- the maximum.)
			reset()
			for _ = 1, 90 do
				Metrics.Observe("Skewed", 1)
			end
			for _ = 1, 10 do
				Metrics.Observe("Skewed", 1000)
			end

			local public = Scribe.GetPercentiles()
			local skewed = public.Skewed
			local average = Scribe.GetMetrics().Skewed.Average
			expect(`p50={skewed.P50} p90={skewed.P90} p99={skewed.P99} avg={string.format("%.2f", average)}`).to.equal(
				"p50=1 p90=1 p99=1000 avg=100.90"
			)
		end)

		it("keeps only the most recent samples once the reservoir wraps", function()
			-- Bounded on purpose: an unbounded sample list on a metric observed once
			-- per save is a slow leak, and memory is already the binding constraint.
			reset()
			local size = Metrics.RESERVOIR
			for _ = 1, size do
				Metrics.Observe("Wrap", 1)
			end
			for _ = 1, size do
				Metrics.Observe("Wrap", 999)
			end

			-- Every retained sample is now from the second batch.
			local p = Metrics.Percentiles("Wrap")
			expect(p.P50).to.equal(999)

			-- Count still reflects everything ever observed, not just what is kept.
			expect(Metrics.Get().Wrap.Count).to.equal(size * 2)
		end)
	end)

	describe("Reset", function()
		it("clears counters, gauges and samples", function()
			Metrics.Add("Saves", 5)
			Metrics.Set("Live", 12)
			Metrics.Observe("Latency", 3)

			Metrics.Reset()

			local snapshot = Metrics.Get()
			expect(snapshot.Saves).to.equal(nil)
			expect(snapshot.Live).to.equal(nil)
			expect(snapshot.Latency).to.equal(nil)
			expect(Metrics.Percentiles("Latency")).to.equal(nil)
		end)
	end)

	describe("log ring", function()
		it("reports its configured size", function()
			Log.SetRingSize(nil) -- back to the default
			expect(Log.RingInfo().Size).to.equal(512)
		end)

		it("keeps the most recent entries across a resize", function()
			-- A resize is a configuration change, not a request to forget what
			-- already happened.
			Log.SetRingSize(nil)
			for i = 1, 20 do
				Log.Warn("Persistence", "PROFILE_SIZE", `entry {i}`, {})
			end

			Log.SetRingSize(8)
			local info = Log.RingInfo()
			expect(info.Size).to.equal(8)
			expect(info.Count).to.equal(8)

			local recent = Log.GetRecent()
			expect(#recent).to.equal(8)
			-- Oldest-first, and the survivors are the LAST eight logged.
			expect(recent[#recent].Message).to.equal("entry 20")

			Log.SetRingSize(nil)
		end)

		it("is reachable from the LogRingSize bundle option, on both realms", function()
			-- The three tests above drive Log.SetRingSize directly, so all of them stay
			-- green with the option's wiring deleted -- which is what it was: a public,
			-- allowlisted option, documented nowhere, asserted by nothing. This holds
			-- the wiring itself.
			--
			-- Deliberately NOT a round number: 512 is the default, so a spec that asked
			-- for 512 would pass against a bundle that ignored the option entirely.
			local TestCtx = require(script.Parent.Parent.Helpers.TestCtx)
			local Client = require(Root.Scribe.Client)

			Log.SetRingSize(nil)
			local harness = TestCtx.make({ Options = { LogRingSize = 777 } })
			local serverSize = Log.RingInfo().Size

			-- The client half reads it too (src/init.luau forwards LogRingSize to both).
			Log.SetRingSize(nil)
			local defaulted = Log.RingInfo().Size
			Client.new(harness.Options, harness.Compiled)
			local clientSize = Log.RingInfo().Size

			Log.SetRingSize(nil) -- restored before the first expect: process singleton
			harness.Cleanup()

			expect(`server={serverSize} defaulted={defaulted} client={clientSize}`).to.equal(
				"server=777 defaulted=512 client=777"
			)
		end)

		it("falls back to the default for a size below 1 or of the wrong type", function()
			-- The configuration guide promises this fallback is SILENT, so a game
			-- that passes 0 gets 512 and no warning. Pinned because the doc makes a
			-- claim about it: `size >= 1` and the `type(size) == "number"` half are
			-- one expression, and dropping either would change what the guide says.
			local out = {}
			for _, bad in { 0, -5, 0.5, "512" } do
				Log.SetRingSize(64) -- move OFF the default first, or 512 proves nothing
				Log.SetRingSize(bad :: any)
				table.insert(out, Log.RingInfo().Size)
			end
			-- 1.5 floors to 1 rather than falling back: >= 1 is the gate, not integrality.
			Log.SetRingSize(1.5)
			local floored = Log.RingInfo().Size

			Log.SetRingSize(nil)
			expect(`{table.concat(out, ",")} floored={floored}`).to.equal("512,512,512,512 floored=1")
		end)

		it("survives being configured twice with the same size", function()
			-- A loopback bundle applies its options from both halves in one process, so
			-- being called twice with the same value is the common case, not an edge.
			-- Entries are carried across a rebuild, so this holds either way -- the
			-- early return is an optimisation, and the spec pins the OUTCOME.
			Log.SetRingSize(64)
			Log.Warn("Persistence", "PROFILE_SIZE", "before", {})
			local before = Log.RingInfo().Count

			Log.SetRingSize(64)
			expect(Log.RingInfo().Count).to.equal(before)

			Log.SetRingSize(nil)
		end)
	end)
end
