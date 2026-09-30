--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it

it("requires an external deadline for non-yielding code", function()
	print("SCRIBE_CONTROL_HANG_ENTERED")
	local spins = 0
	while true do
		-- Deliberately never yield: only the verifier's process deadline can stop this.
		spins += 1
	end
end)
