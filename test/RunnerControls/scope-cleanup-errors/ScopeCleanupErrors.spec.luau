--!nonstrict
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local it, expect, afterEach, afterAll = JestGlobals.it, JestGlobals.expect, JestGlobals.afterEach, JestGlobals.afterAll
local TestCtx = require(Root.Test.Helpers.TestCtx)
local HarnessScope = require(Root.Test.Helpers.HarnessScope)

local scope = HarnessScope.new()
local handles = {}
local attempts = { 0, 0, 0 }

afterEach(function()
	local ok, failure = pcall(scope.Cleanup)
	expect(ok).toBe(false)
	-- Failure in one cleanup cannot leave unrelated handles unattempted.
	expect(attempts).toEqual({ 1, 1, 1 })
	expect(next(handles[1].Fake.ActiveProfiles)).toBeNil()
	expect((next(handles[2].Fake.ActiveProfiles))).never.toBeNil()
	expect((next(handles[3].Fake.ActiveProfiles))).never.toBeNil()
	expect(tostring(failure)).toContain("SCRIBE_CONTROL_SCOPE_CLEANUP_TWO")
	expect(tostring(failure)).toContain("SCRIBE_CONTROL_SCOPE_CLEANUP_THREE")
	error(failure, 0)
end)

afterAll(function()
	-- Failed handles stay registered for retry; completed handles are idempotent.
	scope.Cleanup()
	scope.Cleanup()
	for _, handle in handles do
		handle.Cleanup()
		expect(next(handle.Fake.ActiveProfiles)).toBeNil()
		expect(next(handle.Ctx.Persistence.Entries)).toBeNil()
	end
	expect(attempts).toEqual({ 1, 2, 2 })
	print("SCRIBE_CONTROL_SCOPE_RETRY_AND_IDEMPOTENCE_PROVEN")
end)

it("retains the original body error and every cleanup error", function()
	for index = 1, 3 do
		local handle = TestCtx.make()
		local cleanup = handle.Cleanup
		handle.Cleanup = function()
			attempts[index] += 1
			if attempts[index] == 1 and index > 1 then
				error(
					if index == 2 then "SCRIBE_CONTROL_SCOPE_CLEANUP_TWO" else "SCRIBE_CONTROL_SCOPE_CLEANUP_THREE",
					0
				)
			end
			cleanup()
		end
		table.insert(handles, scope.Track(handle))
		handle.Join(951200 + index)
	end
	error("SCRIBE_CONTROL_SCOPE_ORIGINAL_BODY_ERROR", 0)
end)
