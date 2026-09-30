--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, expect = JestGlobals.it, JestGlobals.expect

-- Jest Roblox identifies callback tests by these two parameters.
it("rejects a callback that never completes", function(_context, done)
	expect(type(done)).toBe("function")
end, 100)
