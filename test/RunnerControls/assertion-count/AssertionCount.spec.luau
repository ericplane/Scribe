--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, expect = JestGlobals.it, JestGlobals.expect

it("rejects a missing asynchronous assertion", function()
	expect.assertions(1)
end)
