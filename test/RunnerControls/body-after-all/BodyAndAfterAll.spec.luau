--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, afterAll = JestGlobals.it, JestGlobals.afterAll

afterAll(function()
	error("SCRIBE_CONTROL_SUITE_CLEANUP_ERROR <cleanup> & failure", 0)
end)

it("preserves a failing body and failing suite cleanup", function()
	error("SCRIBE_CONTROL_TEST_BODY_ERROR <body> & failure", 0)
end)
