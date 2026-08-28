--!nonstrict
-- What a developer can learn about what Scribe COSTS them.
--
-- The failure-visibility surface was already good: health, save outcomes, profile size
-- against the DataStore ceiling, queue depths. The cost surface was not, and the gap had
-- a precise shape. Six distributions existed and exactly ONE of them was a duration,
-- SaveDuration, which times the DataStore round trip and is therefore network time
-- rather than anything Scribe spends. So the two questions a developer actually asks,
-- "how long did my player wait to load" and "how much frame time is this costing me",
-- were both unanswerable from the public surface.
--
-- These cases pin the answers, not the plumbing: each asserts the metric a developer
-- would read, through the same Scribe.GetMetrics they would call.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Metrics = require(Root.Scribe.Internal.Metrics)
	local Profile = require(Root.Scribe.Internal.Profile)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TEMPLATE = { Coins = Scribe.Int(0, { Min = 0, Max = 100000 }) }

	describe("the profiler seam", function()
		--- A recording stand-in, because whether a REAL profiler exists depends on where
		--- this runs: absent under Lune, present in Studio. Installing one makes every
		--- case below assert the same thing in both places.
		local function recorder()
			local log = {}
			return log,
				{
					Begin = function(label: string)
						table.insert(log, `begin:{label}`)
					end,
					End = function()
						table.insert(log, "end")
					end,
				}
		end

		it("opens and closes exactly one span, in order", function()
			local log, impl = recorder()
			Profile.Install(impl)
			local a, b = Profile.SyncSpan("probe", function(x, y)
				return x + y, "tail"
			end, 2, 3)
			Profile.Reset()
			expect(`{table.concat(log, " ")} | {a} {b}`).to.equal("begin:probe end | 5 tail")
		end)

		it("CLOSES the span when the wrapped call raises, which is the whole hazard", function()
			-- An unbalanced pair does not lose a measurement, it corrupts a DIFFERENT one:
			-- the profiler stack stays skewed and every label after it lands in the wrong
			-- place for the rest of the frame.
			--
			-- Both arms run through ONE installed recorder, deliberately. A Studio run
			-- reported the close missing on the raising arm while the succeeding arm was
			-- fine, which is a state the code should not be able to reach, so the case
			-- now measures the two together: if `ok` closes and `raise` does not, the
			-- fault is the error path, and if neither closes it is the seam.
			local log, impl = recorder()
			Profile.Install(impl)
			Profile.SyncSpan("ok", function() end)
			local raised, err = pcall(Profile.SyncSpan, "raise", function()
				error("the original message", 0)
			end)
			Profile.Reset()
			expect(`{table.concat(log, " ")} | raised={tostring(not raised)} msg={tostring(err)}`).to.equal(
				"begin:ok end begin:raise end | raised=true msg=the original message"
			)
		end)

		it("works with NO profiler at all, which is what the headless runner has", function()
			-- The fallback branch, forced rather than assumed. The first version of this
			-- case asserted that the real profiler was absent, which is true under Lune and
			-- FALSE in Studio, so it failed the moment it ran where it mattered.
			Profile.Install({
				Begin = nil :: any,
				End = nil :: any,
			})
			local available = Profile.Available()
			local value = Profile.SyncSpan("probe", function()
				return "through"
			end)
			local ok = pcall(Profile.MemoryCategory, "Scribe")
			Profile.Reset()
			expect(`available={tostring(available)} value={value} category={tostring(ok)}`).to.equal(
				"available=false value=through category=true"
			)
		end)

		it("restores whatever the environment had, so one test cannot leak into the next", function()
			-- Compared against what was there BEFORE, not against a hardcoded answer: the
			-- native seam is absent under Lune and present in Studio, and Reset has to be
			-- right in both.
			local native = Profile.Available()
			local _log, impl = recorder()
			Profile.Install(impl)
			local installed = Profile.Available()
			Profile.Reset()
			expect(`installed={tostring(installed)} restored={tostring(Profile.Available() == native)}`).to.equal(
				"installed=true restored=true"
			)
		end)
	end)

	describe("what a load cost", function()
		it("records LoadDuration, which is the number a player actually waited", function()
			-- The one duration that existed measured the DataStore round trip. This one
			-- is stamped at the JOIN, so it covers the queue, the retries and any
			-- migration: everything the player sat through.
			Metrics.Reset()
			local harness = TestCtx.make({ Template = TEMPLATE })
			harness.Join(70601)
			local seen = Scribe.GetMetrics().LoadDuration
			harness.Cleanup()

			expect(
				`present={tostring(seen ~= nil)} count={tostring(seen and seen.Count)} finite={tostring(
					seen ~= nil and seen.Max == seen.Max and seen.Max >= 0
				)}`
			).to.equal("present=true count=1 finite=true")
		end)

		it("reports it as a distribution, so the TAIL is readable and not just a mean", function()
			-- One slow join is weather; a moved p99 is a problem. A mean cannot tell the
			-- difference, which is why this is Observe and not Set.
			Metrics.Reset()
			local harness = TestCtx.make({ Template = TEMPLATE })
			for id = 70610, 70614 do
				harness.Join(id)
			end
			local pct = Scribe.GetPercentiles().LoadDuration
			harness.Cleanup()

			expect(`present={tostring(pct ~= nil)} ordered={tostring(pct ~= nil and pct.P50 <= pct.P99)}`).to.equal(
				"present=true ordered=true"
			)
		end)
	end)

	describe("what a frame cost", function()
		it("records FlushDuration whenever it records the counts beside it", function()
			-- The comment above the flush loop has always said "the frame cost is
			-- measured below"; only COUNTS were recorded. Counts answer how much work
			-- there was, never what it cost. Asserted TOGETHER with the count metric so
			-- the two cannot drift apart again: either both are recorded or neither is.
			Metrics.Reset()
			local harness = TestCtx.make({ Template = TEMPLATE })
			local player = harness.Join(70620)
			-- Nothing is queued for a client that has not shaken hands, so without this
			-- the frame is idle and the case would assert against an empty metric.
			harness.SendHello(player)
			harness.Step()
			Metrics.Reset()
			harness.Data.Get(player).Coins.Set(1234)
			-- Poll on the COUNT metric, not the duration. If the timer were ever dropped
			-- from the flush loop the poll still ends here and the assertion below still
			-- fails, which is the drift this case exists to catch.
			harness.StepUntil(function()
				local entries = Scribe.GetMetrics().FlushEntriesPerFrame
				return entries ~= nil and entries.Count > 0
			end)

			local all = Scribe.GetMetrics()
			harness.Cleanup()
			expect(
				`entries={tostring(all.FlushEntriesPerFrame ~= nil)} duration={tostring(all.FlushDuration ~= nil)} counted={tostring(
					all.FlushDuration ~= nil and all.FlushDuration.Count > 0
				)}`
			).to.equal("entries=true duration=true counted=true")
		end)

		it("records NOTHING on an idle frame, so the percentiles stay readable", function()
			-- A distribution padded with zeroes drags every percentile down and hides the
			-- busy frames, which is the reason the counts were already guarded. The new
			-- timer has to sit inside the same guard or it undoes that.
			Metrics.Reset()
			local harness = TestCtx.make({ Template = TEMPLATE })
			local idle = harness.Join(70630)
			harness.SendHello(idle)
			harness.Step()
			-- Reset AFTER the handshake frame, so what follows is genuinely idle.
			Metrics.Reset()
			harness.Step()
			harness.Step()

			local seen = Scribe.GetMetrics().FlushDuration
			harness.Cleanup()
			expect(`recorded={tostring(seen ~= nil and seen.Count or 0)}`).to.equal("recorded=0")
		end)
	end)
end
