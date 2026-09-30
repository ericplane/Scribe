--!nonstrict
-- Pin representative protocol bytes: an encoder and decoder can otherwise drift
-- together while all round-trip tests still pass. Review snapshot changes alongside
-- Wire.PROTOCOL_VERSION before accepting a wire compatibility change.
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local it, expect = JestGlobals.it, JestGlobals.expect
local Scribe = require(Root.Scribe)
local Wire = require(Root.Scribe.Internal.Wire)
local Template = require(Root.Scribe.Internal.Template)

local compiled = Template.Compile({
	Coins = Scribe.Int(0, { Min = 0, Max = 65535 }),
	Delta = Scribe.Int(0),
	Team = Scribe.Enum("Red", { "Red", "Blue" }),
	Active = true,
	Inventory = {},
	Quests = {},
}, {})

local function hex(bytes)
	local encoded = table.create(buffer.len(bytes))
	for offset = 0, buffer.len(bytes) - 1 do
		encoded[offset + 1] = string.format("%02x", buffer.readu8(bytes, offset))
	end
	return table.concat(encoded, " ")
end

it.each({
	{
		"schema values",
		{
			{ Kind = "Set", Path = { "Coins" }, Value = 1025 },
			{ Kind = "Set", Path = { "Delta" }, Value = -5 },
			{ Kind = "Set", Path = { "Team" }, Value = "Blue" },
			{ Kind = "Set", Path = { "Active" }, Value = false },
		},
	},
	{
		"dynamic paths and collection operations",
		{
			{ Kind = "Set", Path = { "Inventory", "Sword" }, Value = 25 },
			{ Kind = "Set", Path = { "Inventory", "Gone" } },
			{ Kind = "Insert", Path = { "Quests" }, Value = "starter", Index = 1 },
			{ Kind = "Remove", Path = { "Quests" }, Index = 1 },
			{ Kind = "Clear", Path = { "Inventory" } },
		},
	},
})("keeps the diff encoding stable for %s", function(_name, operations)
	local bytes = Wire.EncodeOpsFrame(Wire.Frames.Diff, compiled, operations)
	local reader = Wire.NewReader(bytes)
	expect(Wire.RU8(reader)).toBe(Wire.Frames.Diff)
	expect(Wire.DecodeOps(reader, compiled)).toEqual(operations)
	expect(reader.pos).toBe(buffer.len(bytes))
	expect({ ProtocolVersion = Wire.PROTOCOL_VERSION, Hex = hex(bytes) }).toMatchSnapshot()
end)
