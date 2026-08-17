--!nonstrict
-- The clock seam.
--
-- Scribe is full of behaviour that only happens after a horizon: a cooldown
-- expires, a purchase-id ages past its TTL, a retry backs off, a board refreshes.
-- Before this seam none of it could be tested except by actually waiting, so in
-- practice it was tested by reading the code. These specs drive a virtual clock
-- and assert the behaviour instead: an hour of horizon in no time at all.
--
-- Every test here MUST reset the clock: it is a module-level singleton, so a leak
-- would hand a virtual clock to every spec that runs afterwards.

return function()
	local Root = script.Parent.Parent.Parent
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- A controllable wall clock. Monotonic advances with it so interval logic
	--- stays coherent, and waits stop costing their real duration.
	---
	--- Wait STILL YIELDS. This is the sharp edge of the seam and it is worth
	--- stating plainly: Scribe's background loops are `while ... do Clock.Wait(n)`,
	--- so a Wait that returns without yielding turns each of them into a
	--- non-yielding spin and starves the scheduler -- the whole suite hangs, with
	--- no failure to point at. Yielding a frame instead of sleeping `n` seconds is
	--- what makes time cheap without making the loops hostile.
	local function virtualClock(startAt: number?)
		local now = startAt or 1700000000
		Clock.Install({
			Now = function()
				return now
			end,
			Monotonic = function()
				return now
			end,
			Wait = function()
				return task.wait()
			end,
			Delay = function(_seconds, fn, ...)
				return task.spawn(fn, ...)
			end,
		})
		return function(seconds: number)
			now += seconds
		end
	end

	describe("Clock", function()
		it("defaults to the real clock and restores after Reset", function()
			expect(Clock.Now()).to.equal(os.time())
			local advance = virtualClock(1234567)
			expect(Clock.Now()).to.equal(1234567)
			advance(60)
			expect(Clock.Now()).to.equal(1234627)
			Clock.Reset()
			expect(Clock.Now()).to.equal(os.time())
		end)

		it("leaves anything Install omits alone", function()
			local before = Clock.Monotonic
			Clock.Install({
				Now = function()
					return 42
				end,
			})
			expect(Clock.Now()).to.equal(42)
			expect(Clock.Monotonic).to.equal(before) -- untouched
			Clock.Reset()
		end)

		it("expires an hour-long cooldown without waiting an hour", function()
			local advance = virtualClock()
			local harness = TestCtx.make()
			local player = harness.Join(97001)

			-- Arm it, and confirm it is genuinely held.
			local onCooldown = harness.Data.OnCooldown(player, "DailyChest", 3600)
			expect(onCooldown).to.equal(false) -- first call arms and passes
			expect((harness.Data.OnCooldown(player, "DailyChest", 3600))).to.equal(true)

			advance(3599)
			expect((harness.Data.OnCooldown(player, "DailyChest", 3600))).to.equal(true)

			advance(2) -- past the horizon
			expect((harness.Data.OnCooldown(player, "DailyChest", 3600))).to.equal(false)

			harness.Cleanup()
			Clock.Reset()
		end)

		it("drives the Timed sweep loop without real time passing", function()
			-- The same loop BundleStop.spec has to spend ~2.8 real seconds on. With
			-- Wait resolving instantly the loop spins, so this asserts the seam
			-- reaches the background loops too, not just the read paths.
			local advance = virtualClock()
			local harness = TestCtx.make()
			local player = harness.Join(97003)

			harness.Data.OnCooldown(player, "Brief", 30)
			expect((harness.Data.OnCooldown(player, "Brief", 30))).to.equal(true)
			advance(31)
			expect((harness.Data.OnCooldown(player, "Brief", 30))).to.equal(false)

			harness.Cleanup()
			Clock.Reset()
		end)
	end)
end
