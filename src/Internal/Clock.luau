--!strict
-- The clock seam: every reading of time and every timed wait in Scribe goes
-- through here, so a test or a simulation can replace them.
--
-- Without this, nothing can fast-forward. A cooldown that expires in an hour, a
-- purchase-id that ages out after seven days, a leaderboard refresh cycle, a
-- retry backoff -- each of those can only be exercised by actually waiting, so in
-- practice they are exercised by reading the code and hoping. With a virtual
-- clock installed, eight hours of autosaves runs in two seconds and the horizon
-- logic becomes ordinary testable behaviour.
--
-- TWO CLOCKS, deliberately, because conflating them is a real bug and the names
-- should make the right one obvious:
--
--   Now()       wall time, unix seconds (os.time). Use for anything PERSISTED or
--               compared across sessions and servers: a cooldown deadline, a
--               purchase-id stamp, a gift-intent timestamp. It can jump when the
--               machine's clock is corrected, so never use it to measure an
--               interval.
--   Monotonic() a steadily-increasing process timer (os.clock). Use for measuring
--               INTERVALS inside one session: rate-limit buckets, retry backoff,
--               refresh scheduling, save durations. Never persist it -- it is
--               meaningless outside this process, and a value stored from it
--               reads as a nonsense deadline after a rejoin.
--
-- NOT a scheduler. task.spawn/task.defer are about concurrency rather than time
-- and stay direct: they are what Signal's runner-thread reuse is built on, and
-- rerouting them buys nothing for fast-forwarding. Deterministic scheduling (a
-- seeded interleaving of ready threads) is a separate seam if it is ever wanted.
--
-- Nor does it reach ProfileStore, which keeps its own internal timers. A
-- simulation replaces ProfileStore wholesale through the `ProfileStore` option
-- rather than trying to speed up the real one.

local Clock = {}

export type Impl = {
	Now: (() -> number)?,
	Monotonic: (() -> number)?,
	Wait: ((seconds: number?) -> number)?,
	Delay: ((seconds: number, fn: (...any) -> (), ...any) -> thread)?,
}

-- Held separately so Reset can restore them; the live functions are fields on the
-- module itself, which keeps a call one table index -- the same cost as any other
-- module function, so routing a hot path (a per-frame rate-limit bucket) through
-- here does not make it measurably dearer.
local DEFAULT_NOW: () -> number = os.time
local DEFAULT_MONOTONIC: () -> number = os.clock
local DEFAULT_WAIT: (seconds: number?) -> number = task.wait
local DEFAULT_DELAY: (seconds: number, fn: (...any) -> (), ...any) -> thread = task.delay

Clock.Now = DEFAULT_NOW
Clock.Monotonic = DEFAULT_MONOTONIC
Clock.Wait = DEFAULT_WAIT
Clock.Delay = DEFAULT_DELAY

--- Replace one or more of the four. Anything omitted keeps its current value, so
--- a test that only cares about wall time can install `{ Now = ... }` and leave
--- waiting real.
---
--- A replacement `Wait` MUST STILL YIELD. Scribe's background loops are shaped
--- `while ... do Clock.Wait(n) ... end`, so a Wait that returns without yielding
--- turns every one of them into a non-yielding spin: the scheduler is starved and
--- the process hangs with nothing to point at. Make it yield without sleeping the
--- requested duration (`task.wait()` with no argument is the simple version) --
--- that is what makes time cheap rather than making the loops hostile.
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
