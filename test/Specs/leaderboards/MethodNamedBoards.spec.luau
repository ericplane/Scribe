--!nonstrict
-- Periodic board names must not resolve to accessor methods.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any
local Clock = require(Root.Scribe.Internal.Clock)
local Log = require(Root.Scribe.Internal.Log)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local DAY = 86400
local realNow = Clock.Now

afterEach(function()
	Clock.Install({ Now = realNow })
end)

local function top(entries): string
	local parts = {}
	for _, e in entries or {} do
		table.insert(parts, `{e.UserId}={tostring(e.Score)}`)
	end
	return table.concat(parts, ",")
end

describe("a periodic board named like an accessor method", function()
	for _, name in { "WinsDaily", "Count", "Max", "Clear" } do
		it(`ranks the gain and tears the session down, board named {name}`, function()
			Clock.Install({
				Now = function()
					return 10 * DAY
				end,
			})
			local before = #Log.GetRecent({ Code = "LB_STAT_RESOLVE_FAIL" })
			local harness = TestCtx.make({
				Template = { Wins = Scribe.Int(0, { Min = 0 }) },
				Options = { Leaderboards = { [name] = { Stat = "Wins", Period = "Daily" } } },
			})
			local player, entry, data = harness.Join(1001)
			data.Wins.Set(5)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Ctx.Leaderboards.RefreshNow(name)
			local ranked = top(harness.Data.GetLeaderboard(name))
			local record = entry.LiveData._Scribe.Boards[name]
			local resolveFails = #Log.GetRecent({ Code = "LB_STAT_RESOLVE_FAIL" }) - before
			local leaveOk = pcall(harness.Leave, player)
			task.wait()
			local persistence = harness.Ctx.Persistence
			local stillEntry = persistence.Entries[player] ~= nil
			local count = persistence.EntryCount
			local treeDead = entry.Tree.Dead
			harness.Cleanup()
			expect(
				`ranked={ranked} record={record ~= nil} resolveFails={resolveFails} leaveOk={leaveOk} `
					.. `entryLeaked={stillEntry} EntryCount={count} treeDead={treeDead}`
			).toBe(
				"ranked=1001=5 record=true resolveFails=0 leaveOk=true entryLeaked=false EntryCount=0 treeDead=true"
			)
		end)
	end
end)
