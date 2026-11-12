--!nonstrict
-- ObserveOwned returns before the first snapshot and reports ownership when it arrives.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local Client = require(Root.Scribe.Client)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local itRunning = if RunService:IsRunning() then it else it.skip

local harness

afterEach(function()
	if harness then
		harness.Cleanup()
		harness = nil
	end
end)

local function make()
	harness = TestCtx.make({ AutoPump = false, Template = { Coins = 0 } })
	local player = harness.Join(98001)
	harness.Data.GrantPerk(player, "VIP")
	harness.Transport.LocalPlayer = player
	return player, Client.new(harness.Options, harness.Compiled)
end

local function pump()
	harness.Step()
	harness.Transport:PumpToServer()
	harness.Transport:PumpToClient()
end

local function observe(client, key)
	local seen = {}
	local disconnect
	task.spawn(function()
		disconnect = client.ObserveOwned(key, function(owned)
			table.insert(seen, tostring(owned))
		end)
	end)
	return seen, function()
		return disconnect
	end
end

itRunning("returns its disconnect before data has loaded, then reports what the snapshot holds", function()
	local player, client = make()
	local seen, disconnect = observe(client, "VIP")
	local beforeLoad = `{type(disconnect())}/{#seen}/{client.IsReady()}`
	pump()
	local afterLoad = table.concat(seen, ",")
	harness.Data.RevokePerk(player, "VIP")
	pump()
	local afterRevoke = table.concat(seen, ",")
	disconnect()()
	harness.Data.GrantPerk(player, "VIP")
	pump()
	expect(beforeLoad).toBe("function/0/false")
	expect(afterLoad).toBe("true")
	expect(afterRevoke).toBe("true,false")
	expect(table.concat(seen, ",")).toBe("true,false")
end)

itRunning("reports an unowned key once data has loaded, not before", function()
	local _player, client = make()
	local seen = observe(client, "Radar")
	local beforeLoad = #seen
	pump()
	expect(`{beforeLoad}/{table.concat(seen, ",")}`).toBe("0/false")
end)

itRunning("reports nothing when disconnected before data has loaded", function()
	local _player, client = make()
	local seen, disconnect = observe(client, "Radar")
	disconnect()()
	pump()
	expect(#seen).toBe(0)
end)

itRunning("reports at once when data has already loaded", function()
	local _player, client = make()
	pump()
	local seen = observe(client, "VIP")
	expect(table.concat(seen, ",")).toBe("true")
end)
