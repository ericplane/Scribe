--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, afterEach = JestGlobals.it, JestGlobals.afterEach

afterEach(function()
	error("SCRIBE_CONTROL_CLEANUP_ERROR <cleanup> & failure", 0)
end)

it("preserves body & cleanup <errors>", function()
	error("SCRIBE_CONTROL_BODY_ERROR <body> & failure", 0)
end)
