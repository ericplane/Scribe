--!nonstrict
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local Promise = require(Root.DevPackages.Promise)
local it = JestGlobals.it

it("fails for a returned Promise that rejects after yielding", function()
	return Promise.new(function(_resolve, reject)
		task.defer(function()
			reject("SCRIBE_CONTROL_ASYNC_REJECTION")
		end)
	end)
end)
