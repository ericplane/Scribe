--!nonstrict
-- A user's teardown must see the same mocks and timers as the test body.
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local it, expect, afterEach, jest = JestGlobals.it, JestGlobals.expect, JestGlobals.afterEach, JestGlobals.jest
local Clock = require(Root.Scribe.Internal.Clock)
local timerFired = false
local started

afterEach(function()
	expect(Clock.Now()).toBe(123456)
	expect(jest.getTimerCount()).toBe(1)
	jest.advanceTimersByTime(60000)
	expect(timerFired).toBe(true)
	expect(Clock.Monotonic() - started).toBeWithin(60)
	expect(jest.getTimerCount()).toBe(0)
	print("SCRIBE_CONTROL_USER_CLEANUP_RETAINED_MOCKS_AND_TIMERS")
	jest.useRealTimers()
	jest.restoreAllMocks()
end)

it("keeps Clock spies and delayed work available to user teardown", function()
	jest.useFakeTimers()
	jest.spyOn(Clock, "Now").mockReturnValue(123456)
	started = Clock.Monotonic()
	Clock.Delay(60, function()
		timerFired = true
	end)
	expect(Clock.Now()).toBe(123456)
	expect(timerFired).toBe(false)
	expect(jest.getTimerCount()).toBe(1)
end)
