--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, expect, afterAll = JestGlobals.it, JestGlobals.expect, JestGlobals.afterAll

afterAll(function()
	error("SCRIBE_CONTROL_AFTER_ALL_ERROR <cleanup> & failure", 0)
end)

it("passes its body before suite cleanup fails", function()
	expect(true).toBe(true)
end)
