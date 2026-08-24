--!nonstrict
-- The harness has to give back what it takes.
--
-- `TestCtx.make` builds a whole Scribe bundle, and a bundle registers on
-- library-level singletons: a `Health.OnStatusChanged` listener and a
-- `RunService.PostSimulation` handler, both shared by the entire process.
-- `harness.Cleanup()` released the players and walked the Health status back, and
-- never called `Data.Stop()` -- so every harness in a run left its listener and its
-- per-frame pump attached, driving replication work against a bundle nothing holds.
--
-- This is test infrastructure, not shipped code: nothing a consumer of Scribe can
-- observe changes either way. What it costs is measurement integrity, and that is
-- the thing the rest of this suite is built on -- every later spec runs with more
-- dead pumps on the frame signal than the one before it.
--
-- Measured locally rather than across the whole run, so the number is this spec's
-- own and cannot drift with spec ordering.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Health = require(Root.Scribe.Internal.Health)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- Whether the frame signal's connections can be counted on this host.
	---
	--- The headless runner's PostSimulation is a FakeSignal whose handlers are an
	--- ordinary table; Roblox's is an RBXScriptSignal, and ordinary code cannot ask one
	--- how many connections it holds. The probe is on the signal's TYPE rather than on
	--- whether it has a `_handlers` member, because reading an unknown member off a real
	--- RBXScriptSignal RAISES instead of returning nil -- so a member probe would be the
	--- thing that breaks. Same idiom, same reason, as TestCtx.Step.
	local framesCountable = typeof(RunService.PostSimulation) ~= "RBXScriptSignal"

	--- Listeners on the two process-global signals a bundle attaches to. The frame
	--- count is nil where it cannot be taken.
	---
	--- Returning nil rather than 0 is the whole point: every assertion below is a "no
	--- leak" comparison, and a census that quietly reported zero on a host that cannot
	--- see the listeners would satisfy all of them while measuring nothing. Half the
	--- invariant still holds everywhere -- Health.OnStatusChanged is a Scribe Signal, a
	--- plain linked list, readable on any host -- so Studio checks that half honestly
	--- instead of skipping the node outright.
	local function census(): (number, number?)
		local status = 0
		local node = (Health.OnStatusChanged :: any)._head
		while node do
			status += 1
			node = node._next
		end
		if not framesCountable then
			return status, nil
		end
		local frame = 0
		for _ in (RunService.PostSimulation :: any)._handlers do
			frame += 1
		end
		return status, frame
	end

	--- Fail unless both census readings match, naming what moved.
	local function expectNoLeak(label: string, status0: number, frame0: number?, status1: number, frame1: number?)
		local frameDelta = if frame0 ~= nil and frame1 ~= nil then frame1 - frame0 else nil
		if status1 ~= status0 or (frameDelta ~= nil and frameDelta ~= 0) then
			error(`{label}: Health {status1 - status0}, PostSimulation {frameDelta or "unmeasured"}`)
		end
	end

	local function makeHarness()
		return TestCtx.make({ Template = { Coins = Scribe.Int(0, { Min = 0 }) } })
	end

	describe("TestCtx.Cleanup", function()
		it("registers on the process globals in the first place", function()
			-- THE CALIBRATION. Every assertion below is "the count came back", which a
			-- census that always reads zero would also satisfy.
			local status0, frame0 = census()
			local harness = makeHarness()
			local status1, frame1 = census()

			expect(status1 > status0).to.equal(true)
			if framesCountable then
				expect((frame1 :: number) > (frame0 :: number)).to.equal(true)
			end

			harness.Cleanup()
		end)

		it("reclaims them, so a harness costs nothing once it is done", function()
			-- The defect, stated as the invariant the harness owes its callers.
			local status0, frame0 = census()
			local harness = makeHarness()
			harness.Join(920001)
			harness.Cleanup()
			local status1, frame1 = census()

			expectNoLeak("Cleanup leaked", status0, frame0, status1, frame1)
		end)

		it("does not accumulate across many harnesses", function()
			-- The shape that makes it worth fixing: one per harness, and a full run
			-- builds over a thousand of them.
			local status0, frame0 = census()
			for i = 1, 12 do
				local harness = makeHarness()
				harness.Join(920100 + i)
				harness.Cleanup()
			end
			local status1, frame1 = census()

			expectNoLeak("12 harnesses leaked", status0, frame0, status1, frame1)
		end)

		it("still releases players through the normal leave path first", function()
			-- THE CONTROL THAT MATTERS MOST. Stopping the bundle must happen AFTER the
			-- players are released, or the leave save never runs and every spec that
			-- reads persisted state after Cleanup silently starts reading nothing.
			local harness = makeHarness()
			local player = harness.Join(920002)
			harness.Data.Get(player).Coins.Set(4242)

			harness.Cleanup()

			local stored = harness.Fake.Persisted["Default/PLAYER_920002"]
			expect(stored).to.be.ok()
			expect(stored.Coins).to.equal(4242)
		end)

		it("is safe to call twice", function()
			-- Some specs Cleanup on an early-return path and again at the end.
			local harness = makeHarness()
			harness.Join(920003)
			harness.Cleanup()
			harness.Cleanup()
		end)

		it("still walks the Health status back to Healthy", function()
			-- The job Cleanup already did, unchanged: the status machine is a singleton
			-- and a failure-injection spec must not poison the ones after it.
			local harness = makeHarness()
			harness.Join(920004)
			Health.SetCritical(true)
			for _ = 1, 10 do
				Health.ReportFailure("Saves", `leak-{math.random()}`)
			end

			harness.Cleanup()

			expect(Health.GetStatus()).to.equal("Healthy")
		end)
	end)
end
