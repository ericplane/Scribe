--!nonstrict
-- Making the per-frame flush cost measurable.
--
-- The flush loop drains every entry with queued work every frame, with no budget
-- and no cursor. That is a deliberate choice rather than an oversight: the worst
-- single flush measures ~0.2 ms at 700 players (about 1.2% of a frame) and
-- 0.844 ms at 2000, which is roughly three times the largest server the platform
-- runs -- while a round-robin budget would need an ordered entry list as a fourth
-- structure beside Entries/EntryCount/EntriesByUserId, and would introduce
-- starvation as a failure mode that cannot happen today.
--
-- What WAS missing is the ability to tell. Nothing in GetMetrics reported what one
-- frame cost, so "is the flush loop ever expensive in my game" had no answer short
-- of attaching a profiler. These two distributions answer it, and they are what a
-- future decision to add a budget should be argued from.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Metrics = require(Root.Scribe.Internal.Metrics)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function ready(harness, userId: number)
		local player, entry, data = harness.Join(userId)
		harness.SendHello(player)
		return player, entry, data
	end

	local function dist(name: string)
		return Scribe.GetMetrics()[name]
	end

	describe("per-frame flush cost", function()
		it("records how many entries one frame flushed", function()
			local harness = TestCtx.make()
			local _, _, d1 = ready(harness, 7301)
			local _, _, d2 = ready(harness, 7302)
			local _, _, d3 = ready(harness, 7303)
			Metrics.Reset()

			d1.Coins.Set(1)
			d2.Coins.Set(2)
			d3.Coins.Set(3)
			harness.Step()

			local entries = dist("FlushEntriesPerFrame")
			expect(entries).to.be.ok()
			-- All three flushed in the one frame, which is the behaviour this loop
			-- guarantees and the reason it needs no cursor.
			expect(`max={entries.Max} count={entries.Count}`).to.equal("max=3 count=1")

			harness.Cleanup()
		end)

		it("records the queued ops a frame had to consider", function()
			local harness = TestCtx.make()
			local _, _, data = ready(harness, 7304)
			Metrics.Reset()

			-- Distinct paths, so nothing coalesces in the queue: three real ops.
			data.Coins.Set(5)
			data.Gems.Set(6)
			data.Nick.Set("x")
			harness.Step()

			local queued = dist("FlushQueuedPerFrame")
			expect(queued).to.be.ok()
			-- AT LEAST the three the test wrote, in exactly one recorded frame.
			--
			-- Not exactly three, and the difference is the runner rather than the loop.
			-- `harness.Step()` is a synchronous Fire headless -- no time passes, so the
			-- queue holds only what this body put there -- and a real elapsed frame under
			-- Roblox, during which Scribe enqueues its own session bookkeeping
			-- (_ScribeSession.SaveInfo, from the entry going dirty) alongside the writes.
			-- Measured: 3 headless, 4 in Studio. Pinning the total to 3 pinned the
			-- headless runner's frame semantics, which is not what this records.
			expect(`atLeastThree={queued.Max >= 3} frames={queued.Count}`).to.equal("atLeastThree=true frames=1")

			harness.Cleanup()
		end)

		it("measures work pending, not bytes sent", function()
			-- The two differ by exactly the coalescing the queue does on the way to
			-- the wire, and keeping them separate is the point: OpsSent already
			-- reports what reached the client, so a second copy of it would say
			-- nothing new. Fifty writes to ONE path are fifty queued ops that
			-- collapse into one sent op.
			-- MEASURED AS A DIFFERENCE, NOT AS A TOTAL. A real frame under Roblox flushes
			-- Scribe's own session bookkeeping alongside the test's writes, so the
			-- absolute OpsSent there is one higher than the headless Fire's -- but it is
			-- one higher for a single write too. Running both arms and comparing them
			-- cancels the runner out and leaves exactly the claim: fifty writes to one
			-- path cost the same on the wire as one. That is a stronger statement than
			-- the `sent=1` it replaces, which could only ever hold on one of the two.
			local function measure(userId: number, writes: number): (number, any)
				local harness = TestCtx.make()
				local _, _, data = ready(harness, userId)
				Metrics.Reset()

				for i = 1, writes do
					data.Coins.Set(i)
				end
				harness.Step()

				local sent = Scribe.GetMetrics().OpsSent
				local queued = dist("FlushQueuedPerFrame")
				harness.Cleanup()
				return sent, queued
			end

			local oneSent = measure(7305, 1)
			local fiftySent, queued = measure(7307, 50)

			expect(queued).to.be.ok()
			-- In-place coalescing keeps one slot per scalar path, so the QUEUE never
			-- grows to fifty -- what this records is the depth the frame actually saw.
			expect(`queued={queued.Max >= 1}`).to.equal("queued=true")
			if fiftySent ~= oneSent then
				error(`fifty writes to one path sent {fiftySent} ops; a single write sent {oneSent}`)
			end
		end)

		it("records nothing at all on an idle frame", function()
			-- An idle server must stay free. A distribution padded with zeroes would
			-- also drag every percentile down and hide the busy frames, which are the
			-- only ones worth looking at.
			local harness = TestCtx.make()
			ready(harness, 7306)
			Metrics.Reset()

			for _ = 1, 10 do
				harness.Step()
			end

			expect(`entries={dist("FlushEntriesPerFrame")}`).to.equal("entries=nil")
			expect(`queued={dist("FlushQueuedPerFrame")}`).to.equal("queued=nil")

			harness.Cleanup()
		end)

		it("separates busy frames rather than averaging them away", function()
			-- Two frames, one entry each: the distribution must show two samples, not
			-- one aggregate. This is what makes Max meaningful as "the worst frame".
			local harness = TestCtx.make()
			local _, _, d1 = ready(harness, 7307)
			local _, _, d2 = ready(harness, 7308)
			Metrics.Reset()

			d1.Coins.Set(1)
			harness.Step()
			d2.Coins.Set(2)
			harness.Step()

			local entries = dist("FlushEntriesPerFrame")
			expect(`count={entries.Count} max={entries.Max}`).to.equal("count=2 max=1")

			harness.Cleanup()
		end)
	end)
end
