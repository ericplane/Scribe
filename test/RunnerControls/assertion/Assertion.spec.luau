--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, expect = JestGlobals.it, JestGlobals.expect

it("reports the assertion's expected and received values", function()
	expect("SCRIBE_CONTROL_RECEIVED").toBe("SCRIBE_CONTROL_EXPECTED")
end)
