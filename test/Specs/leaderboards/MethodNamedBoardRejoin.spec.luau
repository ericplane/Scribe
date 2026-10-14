--!nonstrict
-- Boards named after accessor methods must not leak sessions on rejoin.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any
local TestCtx = require(Root.Test.Helpers.TestCtx)

for _, name in { "WinsDaily", "Count" } do
	it(`a rejoin after leaving loads, board named {name}`, function()
		local harness = TestCtx.make({
			Template = { Wins = Scribe.Int(0, { Min = 0 }) },
			Options = { Leaderboards = { [name] = { Stat = "Wins", Period = "Daily" } } },
		})
		local player, _, data = harness.Join(1101)
		data.Wins.Set(5)
		harness.Leave(player)
		task.wait()
		local _, _entry2, data2, _reason = harness.TryJoin(1101, 2)
		local wins = if data2 then data2.Wins.Get() else nil
		local p = harness.Ctx.Persistence
		local count = p.EntryCount
		harness.Cleanup()
		expect(`data={data2 ~= nil} wins={tostring(wins)} EntryCount={count}`).toBe("data=true wins=5 EntryCount=1")
	end)
end
