--!nonstrict
-- Deliberately differs from its committed snapshot; do not regenerate this control.
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, expect = JestGlobals.it, JestGlobals.expect

it("reports a changed snapshot", function()
	expect("SCRIBE_CONTROL_SNAPSHOT_RECEIVED").toMatchSnapshot()
end)
