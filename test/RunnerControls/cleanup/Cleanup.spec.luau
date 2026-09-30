--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe, it, expect = JestGlobals.describe, JestGlobals.it, JestGlobals.expect
local beforeAll, afterAll = JestGlobals.beforeAll, JestGlobals.afterAll
local beforeEach, afterEach = JestGlobals.beforeEach, JestGlobals.afterEach

describe("cleanup after failed setup", function()
	local setups = 0
	local cleanups = 0
	local firstBodyRan = false
	local ready = false

	beforeAll(function()
		task.wait()
		ready = true
	end)

	beforeEach(function()
		setups += 1
		if setups == 1 then
			error("SCRIBE_CONTROL_SETUP_ERROR", 0)
		end
	end)

	afterEach(function()
		task.wait()
		cleanups += 1
		print(`SCRIBE_CONTROL_CLEANUP_RAN:{cleanups}`)
	end)

	afterAll(function()
		print(`SCRIBE_CONTROL_AFTER_ALL:{cleanups}`)
	end)

	it("fails in setup before its body executes", function()
		firstBodyRan = true
		error("SCRIBE_CONTROL_UNEXPECTED_BODY", 0)
	end)

	it("proves cleanup ran despite the setup failure", function()
		expect(ready).toBe(true)
		expect(setups).toBe(2)
		expect(cleanups).toBe(1)
		expect(firstBodyRan).toBe(false)
	end)
end)
