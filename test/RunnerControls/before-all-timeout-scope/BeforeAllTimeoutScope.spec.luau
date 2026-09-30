--!nonstrict
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local describe, it, expect = JestGlobals.describe, JestGlobals.it, JestGlobals.expect
local beforeAll, afterAll = JestGlobals.beforeAll, JestGlobals.afterAll
local TestCtx = require(Root.Test.Helpers.TestCtx)
local HarnessScope = require(Root.Test.Helpers.HarnessScope)

local scope = HarnessScope.new()
local starts, bodies, cleanups = 0, 0, 0
local harness

describe("a shared capture that times out", function()
	beforeAll(function()
		starts += 1
		harness = scope.Track(TestCtx.make())
		harness.Join(951101)
		expect((next(harness.Fake.ActiveProfiles))).never.toBeNil()
		print("SCRIBE_CONTROL_SHARED_CAPTURE_STARTED")
		task.wait(30)
	end, 150)

	afterAll(function()
		scope.Cleanup()
		cleanups += 1
		expect(starts).toBe(1)
		expect(bodies).toBe(0)
		expect(next(harness.Fake.ActiveProfiles)).toBeNil()
		print("SCRIBE_CONTROL_SHARED_CAPTURE_RELEASED")
	end)

	it("does not run the first assertion after failed capture", function()
		bodies += 1
	end)
	it("does not restart capture for the second assertion", function()
		bodies += 1
	end)
end)

it("continues after one shared timeout with the session released", function()
	expect(starts).toBe(1)
	expect(cleanups).toBe(1)
	expect(bodies).toBe(0)
	expect(next(harness.Fake.ActiveProfiles)).toBeNil()
	expect(next(harness.Ctx.Persistence.Entries)).toBeNil()
	print("SCRIBE_CONTROL_SHARED_CAPTURE_ONCE_PROVEN")
end)
