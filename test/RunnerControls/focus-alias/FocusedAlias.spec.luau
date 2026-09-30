--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local fit, expect = JestGlobals.fit, JestGlobals.expect

fit("must reject an explicitly imported focused alias", function()
	expect(true).toBe(true)
end)
