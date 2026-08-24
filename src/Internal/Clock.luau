--!strict
-- The clock seam: every reading of time and every timed wait in Scribe goes
-- through here, so a test or a simulation can replace them and fast-forward.
--
-- Two clocks, because conflating them is a real bug:
--
--   Now()       wall time, unix seconds (os.time). Use for anything persisted or
--               compared across sessions and servers. It can jump when the
--               machine's clock is corrected, so never measure an interval with it.
--   Monotonic() a steadily-increasing process timer (os.clock). Use for measuring
--               intervals inside one session. Never persist it; it is meaningless
--               outside this process.
--
-- Not a scheduler. A seeded interleaving of ready threads is Internal/Sched.
--
-- ProfileStore measures its own deadlines with its own os.clock, but it reaches
-- the outside world only through globals, so loading it under a per-server
-- environment (test/Sim/Env.luau) virtualises its clock without a fork.

local Clock = {}

export type Impl = {
	Now: (() -> number)?,
	Monotonic: (() -> number)?,
	Wait: ((seconds: number?) -> number)?,
	Delay: ((seconds: number, fn: (...any) -> (), ...any) -> thread)?,
}

-- Held separately so Reset can restore them. os.time is wrapped rather than
-- assigned directly because its Roblox signature is `(DateTypeArg?) -> number`,
-- which does not satisfy `() -> number`; typing Impl to match would force every
-- virtual clock to declare a parameter it ignores.
local DEFAULT_NOW: () -> number = function()
	return os.time()
end
local DEFAULT_MONOTONIC: () -> number = os.clock
local DEFAULT_WAIT: (seconds: number?) -> number = task.wait
local DEFAULT_DELAY: (seconds: number, fn: (...any) -> (), ...any) -> thread = task.delay

Clock.Now = DEFAULT_NOW
Clock.Monotonic = DEFAULT_MONOTONIC
Clock.Wait = DEFAULT_WAIT
Clock.Delay = DEFAULT_DELAY

--- Replace one or more of the four. Anything omitted keeps its current value.
---
--- A replacement `Wait` must still yield. Scribe's background loops are shaped
--- `while ... do Clock.Wait(n) ... end`, so a Wait that returns without yielding
--- starves the scheduler and hangs the process with nothing to point at. Yield
--- without sleeping the requested duration instead.
function Clock.Install(impl: Impl)
	if impl.Now ~= nil then
		Clock.Now = impl.Now
	end
	if impl.Monotonic ~= nil then
		Clock.Monotonic = impl.Monotonic
	end
	if impl.Wait ~= nil then
		Clock.Wait = impl.Wait
	end
	if impl.Delay ~= nil then
		Clock.Delay = impl.Delay
	end
end

--- Restore all four. A test that installs must reset, or it leaks a virtual clock
--- into every spec that runs after it.
function Clock.Reset()
	Clock.Now = DEFAULT_NOW
	Clock.Monotonic = DEFAULT_MONOTONIC
	Clock.Wait = DEFAULT_WAIT
	Clock.Delay = DEFAULT_DELAY
end

return Clock
