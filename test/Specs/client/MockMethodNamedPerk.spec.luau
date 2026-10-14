--!nonstrict
-- Mock perks can share names with accessor methods.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any
local Template = require(Root.Scribe.Internal.Template)
local Client = require(Root.Scribe.Client)

describe("edit-mode Data.Mock with a method-named perk", function()
	for _, perk in { "VIP", "Count", "Get" } do
		it(`seeds the perk {perk}`, function()
			local options = {
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				ProfileStoreIndex = "ZzMockPerkSpec",
				ProfileKeyPrefix = "PLAYER_",
				IsRunning = false,
				Banner = false,
			}
			local compiled = Template.Compile(options.Template, {})
			local clientData = Client.new(options, compiled)
			local ok, _err = pcall(clientData.Mock, nil, { Perks = { perk } })
			local owns = clientData.Owns(perk)
			pcall(clientData.Stop)
			expect(`ok={ok} owns={owns}`).toBe("ok=true owns=true")
		end)
	end

	it("seeds a root field named like a method", function()
		local options = {
			Template = { Max = Scribe.Int(0, { Min = 0 }) },
			ProfileStoreIndex = "ZzMockPerkSpec",
			ProfileKeyPrefix = "PLAYER_",
			IsRunning = false,
			Banner = false,
		}
		local compiled = Template.Compile(options.Template, {})
		local clientData = Client.new(options, compiled)
		local ok = pcall(clientData.Mock, { Max = 5 })
		local value = clientData.Child("Max").Get()
		pcall(clientData.Stop)
		expect(`ok={ok} value={value}`).toBe("ok=true value=5")
	end)
end)
