--!strict
-- The scheduling seam: starting a thread goes through here, so a simulation can decide
-- the interleaving. A replacement must keep the engine's semantics, or it finds bugs
-- that cannot happen and hides ones that can:
--   Spawn(fn, ...)   runs `fn` immediately on the caller's stack, like task.spawn. Code
--                    relies on a spawned load that never yields being done on return.
--   Defer(fn, ...)   queues `fn` after the current resumption point.
--   Resume(thr, ...) resumes an existing suspended coroutine: the moments a request
--                    completes, which an interleaving search most wants to move.
-- Signal dispatch and the DebugHook pair are not routed: the signal runner is never
-- blocked, so simulating it buys no orderings, and the hooks are Studio tooling.

local Sched = {}

export type Impl = {
	Spawn: ((fn: (...any) -> (), ...any) -> thread)?,
	Defer: ((fn: (...any) -> (), ...any) -> thread)?,
	Resume: ((thread: thread, ...any) -> ())?,
}

local DEFAULT_SPAWN: (fn: (...any) -> (), ...any) -> thread = task.spawn
local DEFAULT_DEFER: (fn: (...any) -> (), ...any) -> thread = task.defer
-- Wrapped rather than assigned directly: task.spawn returns the thread, and Resume
-- returns nothing so nobody mistakes a resumption for a spawn.
local DEFAULT_RESUME: (thread: thread, ...any) -> () = function(thread: thread, ...: any)
	task.spawn(thread, ...)
end

Sched.Spawn = DEFAULT_SPAWN
Sched.Defer = DEFAULT_DEFER
Sched.Resume = DEFAULT_RESUME

--- Replace any of the three. Anything omitted keeps its current value. A
--- replacement Spawn must still run its function immediately; one that queues
--- appears to work while quietly reordering everything that assumed otherwise.
function Sched.Install(impl: Impl)
	if impl.Spawn ~= nil then
		Sched.Spawn = impl.Spawn
	end
	if impl.Defer ~= nil then
		Sched.Defer = impl.Defer
	end
	if impl.Resume ~= nil then
		Sched.Resume = impl.Resume
	end
end

--- Restore all three. A test that installs must reset, or it hands its scheduler
--- to every spec that runs afterwards.
function Sched.Reset()
	Sched.Spawn = DEFAULT_SPAWN
	Sched.Defer = DEFAULT_DEFER
	Sched.Resume = DEFAULT_RESUME
end

return Sched
