--!strict
-- The scheduling seam: starting a thread goes through here, so a simulation can
-- decide the interleaving instead of the engine. Separate from Clock, which
-- answers what time it is rather than who runs next.
--
-- The semantics are the engine's, and a replacement that gets them wrong finds
-- bugs that cannot happen or hides ones that can:
--
--   Spawn(fn, ...)   runs `fn` immediately, on the caller's stack, until it
--                    yields or returns, exactly like task.spawn. Code all over
--                    Scribe relies on a spawned load that never yields having
--                    already finished by the time Spawn returns.
--   Defer(fn, ...)   queues `fn` to run after the current resumption point.
--   Resume(thr, ...) resumes an already existing suspended coroutine. Distinct
--                    from Spawn because nothing is created, and because these
--                    resumptions are the moments a request completes, which is
--                    what an interleaving search most wants to move around.
--
-- Signal's dispatch and the DebugHook pair are deliberately not routed: the
-- signal runner is never blocked, so simulating it buys no new orderings on
-- Scribe's hottest path, and the hooks are Studio tooling.

local Sched = {}

export type Impl = {
	Spawn: ((fn: (...any) -> (), ...any) -> thread)?,
	Defer: ((fn: (...any) -> (), ...any) -> thread)?,
	Resume: ((thread: thread, ...any) -> ())?,
}

local DEFAULT_SPAWN: (fn: (...any) -> (), ...any) -> thread = task.spawn
local DEFAULT_DEFER: (fn: (...any) -> (), ...any) -> thread = task.defer
-- Wrapped rather than assigned directly: task.spawn returns the thread, and Resume
-- returns nothing on purpose, so nobody mistakes a resumption for a spawn.
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
