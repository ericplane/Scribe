--!nonstrict
-- A raw Roblox datatype written around the accessor gets a message that says how
-- to fix it, not one that reads as though the datatype were unsupported.
--
-- OnPlayerInit, migrations, and offline drafts all hand you the RAW profile table,
-- so datatype packing does not run. A declared Scribe.DateTime field stores a
-- packed buffer; assigning the DateTime itself stores userdata, which no DataStore
-- can serialize. The old text was `unsupported type "DateTime"`, which sounds like
-- Scribe cannot store a DateTime at all when it stores them fine through the
-- accessor.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Util = require(Root.Scribe.Internal.Util)
local Log = require(Root.Scribe.Internal.Log)
local TestCtx = require(Root.Test.Helpers.TestCtx)

it("names the datatype and the fix", function()
	local found = Util.findUnpersistable({ Stamp = DateTime.fromUnixTimestampMillis(0) })
	expect(found).never.toBeNil()
	local detail = tostring(found.Detail)
	expect(string.find(detail, "DateTime", 1, true) ~= nil).toBe(true)
	expect(string.find(detail, "Datatypes.Pack", 1, true) ~= nil).toBe(true)
	-- The old wording is what made this confusing.
	expect((string.find(detail, 'unsupported type "DateTime"', 1, true))).toBe(nil)
end)

it("reports the path, not the datatype's internals", function()
	-- Under the headless shim a datatype is a plain table, so recursing into it
	-- used to report `Stamp.<key>` with a key-type error rather than the field.
	local found = Util.findUnpersistable({ Wrap = { Stamp = Scribe.Datatypes and DateTime.now() } })
	expect(found).never.toBeNil()
	expect(table.concat(found.Path, ".")).toBe("Wrap.Stamp")
end)

it("covers every packable datatype, not just DateTime", function()
	for _, case in
		{
			{ "Vector3", Vector3.new(1, 2, 3) },
			{ "CFrame", CFrame.new(1, 2, 3) },
			{ "Color3", Color3.fromRGB(1, 2, 3) },
			{ "UDim2", UDim2.new(1, 2, 3, 4) },
		}
	do
		local found = Util.findUnpersistable({ F = case[2] })
		expect(found).never.toBeNil()
		expect(string.find(tostring(found.Detail), case[1], 1, true) ~= nil).toBe(true)
		expect(string.find(tostring(found.Detail), "Datatypes.Pack", 1, true) ~= nil).toBe(true)
	end
end)

it("still reports a genuinely unstorable value plainly", function()
	local found = Util.findUnpersistable({ F = function() end })
	expect(found).never.toBeNil()
	expect(string.find(tostring(found.Detail), "unsupported type", 1, true) ~= nil).toBe(true)
	expect((string.find(tostring(found.Detail), "Datatypes.Pack", 1, true))).toBe(nil)
end)

it("still passes everything a DataStore can hold, packed buffers included", function()
	expect(Util.findUnpersistable({
		N = 1,
		S = "ok",
		B = true,
		Packed = Scribe.Datatypes.Pack("Vector3", Vector3.new(1, 2, 3)),
		Nested = { Deep = { 1, 2, 3 } },
	})).toBe(nil)
end)

it("fires PROFILE_UNPERSISTABLE with the new wording from OnPlayerInit", function()
	local harness = TestCtx.make({
		Template = { Wrap = { Stamp = Scribe.DateTime(DateTime.fromUnixTimestampMillis(0)) } },
		Options = {
			LogLevel = "Error",
			OnPlayerInit = function(_player, raw)
				raw.Wrap.Stamp = DateTime.fromUnixTimestampMillis(1700000000000)
			end,
		},
	})
	harness.Join(98301)

	local recent = Log.GetRecent({ Code = "PROFILE_UNPERSISTABLE" })
	local last = recent[#recent]
	expect(last).never.toBeNil()
	expect(string.find(tostring(last.Message), "Datatypes.Pack", 1, true) ~= nil).toBe(true)

	harness.Cleanup()
end)

it("accepts the packed form written the same way", function()
	local before = #Log.GetRecent({ Code = "PROFILE_UNPERSISTABLE" })
	local harness = TestCtx.make({
		Template = { Wrap = { Stamp = Scribe.DateTime(DateTime.fromUnixTimestampMillis(0)) } },
		Options = {
			LogLevel = "Error",
			OnPlayerInit = function(_player, raw)
				raw.Wrap.Stamp = Scribe.Datatypes.Pack("DateTime", DateTime.fromUnixTimestampMillis(1700000000000))
			end,
		},
	})
	local _p, _e, data = harness.Join(98302)

	expect(#Log.GetRecent({ Code = "PROFILE_UNPERSISTABLE" })).toBe(before)
	-- And it still reads back as a real datatype through the accessor.
	expect(typeof(data.Wrap.Stamp.Get())).toBe("DateTime")

	harness.Cleanup()
end)
