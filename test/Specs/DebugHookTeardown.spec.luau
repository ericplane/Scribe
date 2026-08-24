--!nonstrict
-- DebugHook's registrations on LIBRARY-LEVEL singletons, and releasing them.
--
-- The hook installs a lot, and almost all of it is ctx-scoped and dies with the
-- bundle. Two things are not: `Log.AddSink` puts a closure on a module singleton
-- list, and `Health.OnStatusChanged` is a module singleton signal. Both were
-- registered and their removers discarded, so both outlived the bundle, the pump
-- that fed them, and the hook itself -- forever, in that process.
--
-- diagnostics.md:17 already states the rule: keep the remover "when the sink has a
-- lifetime -- a hot-reloaded module, a bundle you Stop(), a test -- because the sink
-- list is a module singleton that nothing else clears". The library was breaking its
-- own published rule, in the one module whose docstring cites it.
--
-- WHY THIS SPEC LOOKS LIKE THIS. Two gates stand between a test and DebugHook's
-- body, and only one of them was previously understood:
--
--   1. `RunService:IsStudio()` is the FIRST line of Attach, and it is pinned FALSE
--      headless (lune/run-tests.luau, and test/Sim/SCOPE.md records the pin). So a
--      spec that merely calls Attach reaches nothing -- measured: an unconditional
--      `error()` as the first statement of Attach's body leaves the suite fully
--      green. That is why the hook has never had executed coverage, and why
--      DebugHookIntegration.spec's first case asserts nothing about the hook.
--      Patched here with OptionTypos.spec's conditional idiom, which is what keeps
--      this runnable BOTH headless and under real TestEZ in Studio.
--   2. `attached` is set once and never cleared. detach() deliberately does not
--      clear it, so this spec does not make the hook re-attachable -- it only
--      proves the singleton registrations are released.
--
-- The sink list is private, so the census is indirect and exact: Log.emit does one
-- Sched.Spawn PER SINK, so counting spawns across a single Log.Info counts sinks.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Log = require(ScribeRoot.Internal.Log)
	local Health = require(ScribeRoot.Internal.Health)
	local Sched = require(ScribeRoot.Internal.Sched)
	local DebugHook = require(ScribeRoot.Server.DebugHook) :: any
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- How many sinks are registered on the Log singleton right now.
	---
	--- A replacement Spawn must still run its function immediately (Sched.Install
	--- says so, and a queueing one silently reorders everything downstream), so this
	--- counts and then delegates.
	local function sinkCount(): number
		local spawns = 0
		Sched.Install({
			Spawn = function(fn, ...)
				spawns += 1
				return task.spawn(fn, ...)
			end,
		})
		Log.Info("Lifecycle", "DEBUG_HOOK_ATTACHED", "sink census", {})
		Sched.Reset()
		return spawns
	end

	--- How many live listeners Health.OnStatusChanged is carrying.
	---
	--- Walked rather than Fired: Fire would drive the real status broadcast, and
	--- HasListeners cannot tell one listener from four -- Replication holds one of
	--- its own for the whole bundle's life, so the count here is never zero and a
	--- boolean would report "still listening" whether or not the hook let go.
	--- Disconnect unlinks, so the chain holds only live connections.
	local function statusListeners(): number
		local n, node = 0, (Health.OnStatusChanged :: any)._head
		while node do
			n += 1
			node = node._next
		end
		return n
	end

	it("releases its log sink and status listener when the hook tears down", function()
		local realIsStudio = nil
		if not RunService:IsStudio() then
			realIsStudio = RunService.IsStudio
			RunService.IsStudio = function()
				return true
			end
		end

		local harness = TestCtx.make({ Options = { DevMode = true } })
		local before = sinkCount()
		local listenersBefore = statusListeners()

		-- Attach hands its caller a remover. Before this existed there was nothing
		-- to call, which is the whole defect -- so the call is guarded rather than
		-- asserted first, and the RELEASE COUNT below is what reports the failure.
		-- A spec that died on `detach()` being nil would prove only that a function
		-- is missing; this one proves the sink is still registered without it.
		local detach = DebugHook.Attach(harness.Data, harness.Ctx)
		local attachedCount = sinkCount()
		local listenersAttached = statusListeners()

		if type(detach) == "function" then
			detach()
		end
		local afterDetach = sinkCount()
		local listenersAfter = statusListeners()

		-- Idempotent: a second release must not remove whatever has since taken
		-- that index, the same guarantee Log.AddSink's own remover makes.
		if type(detach) == "function" then
			detach()
		end
		local afterTwice = sinkCount()

		if realIsStudio ~= nil then
			RunService.IsStudio = realIsStudio
		end
		harness.Cleanup()

		expect(
			`remover={type(detach)} attached={attachedCount - before} `
				.. `released={attachedCount - afterDetach} twice={afterTwice - before} `
				.. `listenerAdded={listenersAttached - listenersBefore} `
				.. `listenerReleased={listenersAttached - listenersAfter}`
		).to.equal("remover=function attached=1 released=1 twice=0 listenerAdded=1 listenerReleased=1")
	end)
end
