--!nonstrict
-- Health tracks DataStore/MessageAsync infrastructure, not application logic. A
-- fail-closed refusal from UpdateOffline is routine: six of them inside 60s used
-- to flip the server to Outage, which then starts refusing Robux grants.
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local function offlineFailures(): number
	return tonumber(Scribe.GetMetrics().HealthFailures_OfflineWrite) or 0
end

it("does not report a Health failure for a missing profile", function()
	local harness = TestCtx.make()
	local before = offlineFailures()

	for _ = 1, 6 do
		local ok, reason = harness.Data.UpdateOffline(999001, function() end)
		expect(ok).toBe(false)
		expect(string.find(tostring(reason), "does not exist", 1, true) ~= nil).toBe(true)
	end

	expect(offlineFailures()).toBe(before)
	harness.Cleanup()
end)

it("does not report a Health failure when the caller's callback throws", function()
	local harness = TestCtx.make()
	harness.Fake.Persisted["Default/PLAYER_999002"] = { Coins = 1 }
	local before = offlineFailures()

	for _ = 1, 6 do
		local ok, reason = harness.Data.UpdateOffline(999002, function()
			error("game logic blew up")
		end)
		expect(ok).toBe(false)
		expect(string.find(tostring(reason), "blew up", 1, true) ~= nil).toBe(true)
	end

	expect(offlineFailures()).toBe(before)
	-- The refusal is still fail-closed: nothing was committed.
	expect(harness.Fake.Persisted["Default/PLAYER_999002"].Coins).toBe(1)
	harness.Cleanup()
end)

it("still reports a Health failure when the DataStore itself fails", function()
	local harness = TestCtx.make()
	harness.Fake.Persisted["Default/PLAYER_999003"] = { Coins = 1 }
	local before = offlineFailures()

	harness.Fake.FailSaves = true
	local ok = harness.Data.UpdateOffline(999003, function(data)
		data.Coins = 5
	end)
	harness.Fake.FailSaves = false

	expect(ok).toBe(false)
	expect(offlineFailures()).toBe(before + 1)
	harness.Cleanup()
end)
