--!nonstrict
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local Promise = require(Root.DevPackages.Promise)
local it = JestGlobals.it

it.concurrent.only("must reject focus before starting concurrent work", function()
	print("SCRIBE_CONTROL_FOCUSED_BODY_RAN")
	return Promise.resolve()
end)
