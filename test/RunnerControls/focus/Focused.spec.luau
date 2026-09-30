--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, expect = JestGlobals.it, JestGlobals.expect

it.only("must be rejected before execution", function()
	expect(true).toBe(true)
end)
