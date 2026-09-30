--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it

it.only.failing("must reject focus on an expected-failure test", function()
	print("SCRIBE_CONTROL_FOCUSED_BODY_RAN")
	error("SCRIBE_CONTROL_EXPECTED_FAILURE", 0)
end)
