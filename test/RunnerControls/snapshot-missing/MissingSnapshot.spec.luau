--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, expect = JestGlobals.it, JestGlobals.expect

it("refuses to bless a missing snapshot during ordinary tests", function()
	expect("SCRIBE_CONTROL_MISSING_SNAPSHOT").toMatchSnapshot()
end)
