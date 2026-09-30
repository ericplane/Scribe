--!nonstrict
-- A stopped bundle must not write the process-wide budget reserves: a session ending after
-- Data.Stop() reinstalled the GetAsync reserve and starved the next spec that paced on it.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Budget = require(Root.Scribe.Internal.Budget)
local TestCtx = require(Root.Test.Helpers.TestCtx)

afterEach(function()
	Budget.Reset()
end)

local function spareOf(count: number): boolean
	Budget.SetProbe(function()
		return count
	end)
	local granted, release = Budget.Await("GetAsync", count, 0)
	release()
	return granted
end

it("leaves the reserves alone once stopped, however late a session ends", function()
	local harness = TestCtx.make()
	local player = harness.Join()
	local live = spareOf(2) -- the live bundle reserves two reads, so two do not fit
	harness.Data.Stop()
	Budget.Reset()
	harness.Leave(player) -- the late session end: teardown runs against a stopped bundle
	local stopped = spareOf(2)
	harness.Cleanup()
	expect(`live={live} stopped={stopped}`).toBe("live=false stopped=true")
end)
