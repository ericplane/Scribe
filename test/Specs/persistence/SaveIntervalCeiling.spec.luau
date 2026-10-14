--!nonstrict
-- The 300-second ceiling leaves room for one failed save before takeover at 630s.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Config = require(Root.Scribe.Internal.Config)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local function reset()
	Config.AutoSaveInterval = nil
	Config.AutoSaveSource = nil
	Config.BundleConstructed = false
end

-- The interval ProfileStore was given, and whether the clamp was reported.
local function apply(interval: number): string
	reset()
	local codes = {}
	local unsubscribe = Scribe.AddLogSink(function(entry)
		table.insert(codes, entry.Code)
	end, { Level = "Debug" })
	local harness = TestCtx.make({ Options = { SaveInterval = interval, LogLevel = "Debug" } })
	task.wait()
	unsubscribe()
	local applied = harness.Fake.Constants.AUTO_SAVE_PERIOD
	harness.Cleanup()
	reset()
	return `applied={applied} clamped={table.find(codes, "SAVE_INTERVAL_CLAMPED") ~= nil}`
end

describe("SaveInterval", function()
	it("is clamped below half the dead-session threshold, and says so", function()
		expect(apply(315)).toBe("applied=300 clamped=true")
	end)

	it("is left alone at the ceiling", function()
		expect(apply(300)).toBe("applied=300 clamped=false")
	end)
end)
