--!strict
-- The clock seam: every time reading and timed wait goes through here, so a test can
-- replace them and fast-forward. Keep their purposes separate:
--   Now()       wall time (os.time). For anything persisted or compared across servers;
--               it can jump when corrected, so never measure an interval with it.
--   Monotonic() a steady process timer (os.clock). For intervals in one session; never
--               persist it.
--   ServerNow() synchronized server time for client countdown displays.
-- ProfileStore reaches the clock only through globals, so loading it under a per-server
-- environment (test/Sim/Env.luau) virtualises it without a fork.

local Clock = {}

export type Impl = {
	Now: (() -> number)?,
	ServerNow: (() -> number)?,
	Monotonic: (() -> number)?,
	Wait: ((seconds: number?) -> number)?,
	Delay: ((seconds: number, fn: (...any) -> (), ...any) -> thread)?,
}

-- Held separately so Reset can restore them. os.time is wrapped because its Roblox
-- signature is `(DateTypeArg?) -> number`, which does not satisfy `() -> number`;
-- widening Impl to match would force every virtual clock to declare that parameter.
local DEFAULT_NOW: () -> number = function()
	return os.time()
end
local DEFAULT_SERVER_NOW: () -> number = function()
	return game:GetService("Workspace"):GetServerTimeNow()
end
local DEFAULT_MONOTONIC: () -> number = os.clock
local DEFAULT_WAIT: (seconds: number?) -> number = task.wait
local DEFAULT_DELAY: (seconds: number, fn: (...any) -> (), ...any) -> thread = task.delay

Clock.Now = DEFAULT_NOW
Clock.ServerNow = DEFAULT_SERVER_NOW
Clock.Monotonic = DEFAULT_MONOTONIC
Clock.Wait = DEFAULT_WAIT
Clock.Delay = DEFAULT_DELAY

--- Replace clock functions. A virtual Now also supplies ServerNow unless overridden.
---
--- A replacement `Wait` must still yield. Scribe's background loops are shaped
--- `while ... do Clock.Wait(n) ... end`, so a Wait that returns without yielding
--- hangs the process with nothing to point at. Yield without sleeping instead.
function Clock.Install(impl: Impl)
	if impl.Now ~= nil then
		Clock.Now = impl.Now
		Clock.ServerNow = impl.Now
	end
	if impl.ServerNow ~= nil then
		Clock.ServerNow = impl.ServerNow
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

--- Restore defaults. A test that installs must reset, or it leaks a virtual clock
--- into every spec that runs after it.
function Clock.Reset()
	Clock.Now = DEFAULT_NOW
	Clock.ServerNow = DEFAULT_SERVER_NOW
	Clock.Monotonic = DEFAULT_MONOTONIC
	Clock.Wait = DEFAULT_WAIT
	Clock.Delay = DEFAULT_DELAY
end

return Clock
