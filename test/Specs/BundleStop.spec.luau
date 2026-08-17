--!nonstrict
-- bundle.Stop(): releasing everything a bundle holds on the process.
--
-- A Scribe bundle is normally built once per server and lives forever, so a game
-- never calls this. It exists for a PROCESS that builds many bundles: the test
-- suite builds one per harness (several hundred per run), and the multi-server
-- simulation in the load-testing plan stands up a fleet in one process. Without a
-- teardown each of those leaves behind three immortal loops and nine listeners,
-- and the process ends up measuring the accumulation rather than Scribe.
--
-- These specs assert the RELEASE, not that Stop() merely runs: a teardown that
-- silently does nothing is exactly the failure this guards against.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Health = require(Root.Scribe.Internal.Health)

	local SWEEP_INTERVAL = 1 -- mirrors src/Server/Timed.luau

	describe("bundle.Stop", function()
		it("stops the Timed sweep loop", function()
			-- The one assertion here that has to spend real time, and the only one
			-- that proves a `while` LOOP exits rather than a connection dropping.
			-- Measured by spying on the sweep the loop calls, before and after, so
			-- it demonstrates the loop was genuinely running first -- an "after"
			-- count of zero proves nothing on its own.
			local harness = TestCtx.make()
			harness.Join(96001)

			local swept = 0
			local realSweep = harness.Ctx.Timed.Sweep
			harness.Ctx.Timed.Sweep = function(...)
				swept += 1
				return realSweep(...)
			end

			task.wait(SWEEP_INTERVAL + 0.4)
			expect(swept > 0).to.equal(true) -- the loop was live

			harness.Data.Stop()
			swept = 0
			task.wait(SWEEP_INTERVAL + 0.4)
			expect(swept).to.equal(0) -- and is not any more

			harness.Ctx.Timed.Sweep = realSweep
			harness.Cleanup()
		end)

		it("disconnects the ProfileStore signal handlers it installed", function()
			local harness = TestCtx.make()
			local _, entry = harness.Join(96002)
			local key = entry.Key

			-- Before Stop, an overwrite on our store is reported.
			local before = 0
			local conn = Scribe.OnIssue:Connect(function(logEntry)
				if logEntry.Code == "PROFILE_OVERWRITTEN" then
					before += 1
				end
			end)
			harness.Fake.OnOverwrite:Fire("Default", key)
			expect(before).to.equal(1)

			harness.Data.Stop()

			-- After Stop the handler is gone, so the same signal reaches nobody.
			harness.Fake.OnOverwrite:Fire("Default", key)
			conn:Disconnect()
			expect(before).to.equal(1)

			harness.Cleanup()
		end)

		it("stops the replication flush loop", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join(96003)
			harness.SendHello(player)

			data.Coins.Set(1)
			harness.Step()
			local before = #harness.FramesFor(player)
			expect(before > 0).to.equal(true) -- the loop was live

			harness.Data.Stop()

			-- A queued write now goes nowhere: the PostSimulation handler is gone.
			data.Coins.Set(2)
			harness.Step()
			expect(#harness.FramesFor(player)).to.equal(before)

			harness.Cleanup()
		end)

		it("is idempotent", function()
			local harness = TestCtx.make()
			harness.Join(96004)
			harness.Data.Stop()
			harness.Data.Stop()
			harness.Data.Stop()
			harness.Cleanup()
		end)

		it("lets a later bundle take ProcessReceipt back", function()
			-- receiptsBound is module-global: it stops two live bundles owning the
			-- handler at once. Leaving it set after teardown would make the NEXT
			-- bundle in the process throw even though nothing owns it.
			local product = { Coins100 = { Id = 111, Grant = function() end } }
			local first = TestCtx.make({ Options = { OwnReceipts = true, Products = product } })
			first.Data.Stop()

			local ok = pcall(function()
				local second = TestCtx.make({ Options = { OwnReceipts = true, Products = product } })
				second.Data.Stop()
				second.Cleanup()
			end)
			expect(ok).to.equal(true)

			first.Cleanup()
			Health.SetCritical(false)
		end)
	end)
end
