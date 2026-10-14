--!nonstrict
-- An unload error must not skip later cleanup or leak the session.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local TestCtx = require(Root.Test.Helpers.TestCtx)

it("removes the entry and runs the later hooks when one raises", function()
	local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0) } })
	local ran = {}
	local monetization = harness.Ctx.Monetization
	monetization.OnUnload = function()
		error("unload refused")
	end
	local timedUnload = harness.Ctx.Timed.OnUnload
	harness.Ctx.Timed.OnUnload = function(entry)
		table.insert(ran, "Timed")
		return timedUnload(entry)
	end
	local exchangesUnload = harness.Ctx.Exchanges.OnUnload
	harness.Ctx.Exchanges.OnUnload = function(entry)
		table.insert(ran, "Exchanges")
		return exchangesUnload(entry)
	end
	local before = #Scribe.GetRecentLogs({ Code = "SUBSYSTEM_HOOK_ERROR", Limit = 500 })
	local player, entry = harness.Join(88951)
	harness.Leave(player)
	task.wait()
	local persistence = harness.Ctx.Persistence
	local logged = #Scribe.GetRecentLogs({ Code = "SUBSYSTEM_HOOK_ERROR", Limit = 500 }) - before
	local seen = `ran={table.concat(ran, ",")} entry={persistence.Entries[player] ~= nil} `
		.. `count={persistence.EntryCount} treeDead={entry.Tree.Dead} logged={logged}`
	harness.Cleanup()
	expect(seen).toBe("ran=Timed,Exchanges entry=false count=0 treeDead=true logged=1")
end)
