--!nonstrict
-- The production replication flush loop.
--
-- Scribe replicates from a RunService.PostSimulation handler
-- (src/Server/Replication.luau), but every spec in the suite reached replication
-- by hand-calling ctx.Replication.FlushEntry. Under Lune that signal is a
-- FakeSignal nothing ever fired, so the real loop -- including the per-entry
-- iteration and its "is anything queued" guard -- executed ZERO times across the
-- whole suite. These specs drive it through harness.Step() instead, which fires
-- the signal itself, so the code that actually ships is the code under test.

return function()
	local Root = script.Parent.Parent.Parent
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	-- Ops touching `field` across every Diff frame sent to `player` after the
	-- `from`th one. Assertions below count OPS, not frames: under real TestEZ the
	-- PostSimulation loop is genuinely running, so the number of flushes between
	-- two statements is not something a test can pin -- but how many ops a burst of
	-- writes produces is exactly the property these specs exist to check.
	local function opsFor(harness, player, from: number, field: string)
		local out = {}
		local frames = harness.FramesFor(player, Wire.Frames.Diff)
		for i = from + 1, #frames do
			for _, op in frames[i].Ops or {} do
				if op.Path[1] == field then
					table.insert(out, op)
				end
			end
		end
		return out
	end

	local function ready(harness, userId)
		local player, entry, data = harness.Join(userId)
		harness.SendHello(player)
		return player, entry, data
	end

	--- Step until the loop has settled.
	---
	--- One Step is one flush headless, where the harness fires the signal itself, and
	--- a real frame in Studio, where the engine schedules it. So a single Step pins
	--- nothing there: a write can land on the frame after the one Step waited for. Only
	--- the op count across a settled burst is answerable in both, which is what the
	--- header above says and what opsFor exists for.
	local function settle(harness)
		for _ = 1, 5 do
			harness.Step()
		end
	end

	describe("PostSimulation flush loop", function()
		it("flushes a queued write without any hand-called FlushEntry", function()
			local harness = TestCtx.make()
			local player, _, data = ready(harness, 7101)

			local before = #harness.FramesFor(player, Wire.Frames.Diff)
			data.Coins.Set(1234)
			-- Nothing has flushed yet: the write only queues.
			expect(#harness.FramesFor(player, Wire.Frames.Diff)).to.equal(before)

			harness.Step()

			local coins = opsFor(harness, player, before, "Coins")
			expect(#coins).to.equal(1)
			expect(coins[1].Value).to.equal(1234)

			harness.Cleanup()
		end)

		it("sends nothing when no write is pending", function()
			local harness = TestCtx.make()
			local player = ready(harness, 7102)

			local before = #harness.FramesFor(player)
			-- The loop iterates every entry each frame; the guard is what keeps an
			-- idle server from paying for it. Ten idle frames must cost zero frames.
			for _ = 1, 10 do
				harness.Step()
			end
			expect(#harness.FramesFor(player)).to.equal(before)

			harness.Cleanup()
		end)

		it("flushes every entry in ONE pass, not one per frame", function()
			-- Asserted on the loop's OWN metric rather than on frame counts. A loop that
			-- broke after the first entry still reaches all three eventually, one per
			-- frame, so op counts cannot tell the two apart: proved by mutation, which
			-- an earlier op-counting version of this case failed to catch. What only the
			-- metric answers is how many entries a SINGLE pass flushed.
			local Metrics = require(Root.Scribe.Internal.Metrics)
			local harness = TestCtx.make()
			local p1, _, d1 = ready(harness, 7103)
			local p2, _, d2 = ready(harness, 7104)
			local p3, _, d3 = ready(harness, 7105)

			local b1 = #harness.FramesFor(p1, Wire.Frames.Diff)
			local b2 = #harness.FramesFor(p2, Wire.Frames.Diff)
			local b3 = #harness.FramesFor(p3, Wire.Frames.Diff)

			Metrics.Reset()
			d1.Coins.Set(1)
			d2.Coins.Set(2)
			d3.Coins.Set(3)
			settle(harness)

			local o1 = opsFor(harness, p1, b1, "Coins")
			local o2 = opsFor(harness, p2, b2, "Coins")
			local o3 = opsFor(harness, p3, b3, "Coins")
			local perFrame = Metrics.Get().FlushEntriesPerFrame
			expect(
				`{#o1},{#o2},{#o3} value={o1[1].Value},{o2[1].Value},{o3[1].Value} inOnePass={tostring(
					perFrame ~= nil and perFrame.Max
				)}`
			).to.equal("1,1,1 value=1,2,3 inOnePass=3")

			harness.Cleanup()
		end)

		it("coalesces repeated writes to one path into a single op", function()
			local harness = TestCtx.make()
			local player, _, data = ready(harness, 7106)

			local before = #harness.FramesFor(player, Wire.Frames.Diff)
			for i = 1, 50 do
				data.Coins.Set(i)
			end
			harness.Step()

			-- The point of coalescing: fifty writes become ONE op carrying the last
			-- value, however many frames the running loop happens to split them over.
			local coins = opsFor(harness, player, before, "Coins")
			expect(#coins).to.equal(1)
			expect(coins[1].Value).to.equal(50)

			harness.Cleanup()
		end)

		it("drains the queue, so a flushed write is never re-sent", function()
			-- The invariant is that a write leaves the queue once, not that any
			-- particular step is the silent one. Five steps against one write must
			-- still produce exactly one op: a queue that did not drain would re-send it
			-- on every later frame.
			local harness = TestCtx.make()
			local player, _, data = ready(harness, 7107)

			local before = #harness.FramesFor(player, Wire.Frames.Diff)
			data.Coins.Set(9)
			settle(harness)

			local coins = opsFor(harness, player, before, "Coins")
			expect(`{#coins} value={tostring(coins[1] and coins[1].Value)}`).to.equal("1 value=9")

			harness.Cleanup()
		end)
	end)
end
