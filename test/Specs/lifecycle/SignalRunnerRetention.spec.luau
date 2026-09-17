--!nonstrict
-- The cached runner thread must not keep a fire's arguments alive after the handler
-- returns; OnSharedChanged fires a full clone of a player's shared data. Pinned
-- structurally, since nothing here can force a collect and the suite's heap pacing
-- makes churn take seconds: a runner primed to its first yield calls every handler,
-- the first included, from the same line, where one started with the payload as its
-- arguments calls the first from the function body and keeps them for its lifetime.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Signal = require(Root.Scribe.Internal.Signal)

	--- The line runEventHandlerInFreeThread is at in the calling handler's traceback.
	local function runnerLine(): string
		for line in string.gmatch(debug.traceback("runner"), "[^\n]+") do
			local at = string.match(line, "(%d+)[^%d]*function runEventHandlerInFreeThread")
			if at ~= nil then
				return at
			end
		end
		return "none"
	end

	it("calls the first handler on a fresh runner from the same place as every later one", function()
		local signal = Signal.new()
		-- Park the current runner, so the next fire creates a fresh one.
		signal:Once(function()
			coroutine.yield()
		end)
		signal:Fire()
		local lines = {}
		signal:Connect(function()
			table.insert(lines, runnerLine())
		end)
		signal:Fire({})
		signal:Fire({})
		expect(`{lines[1]} {lines[1] ~= "none" and lines[1] == lines[2]}`).to.equal(`{lines[1]} true`)
	end)
end
