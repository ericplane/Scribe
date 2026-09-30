--!nonstrict
-- Round-trip serialization for the schema encoder/decoder: dynamic keys, nil,
-- bounds packing, malformed rejection.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot)
local Wire = require(ScribeRoot.Internal.Wire)
local Template = require(ScribeRoot.Internal.Template)
local deepEquals = require(Root.Test.Helpers.DeepEquals)

local template = {
	Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }), -- fixed width u32
	Level = Scribe.Int(1, { Min = 0, Max = 200 }), -- fixed width u8
	Gems = Scribe.Int(0, { Min = 0 }), -- unsigned varint
	Delta = Scribe.Int(0), -- zigzag varint
	Health = Scribe.Number(100, { Min = 0, Max = 100 }), -- f64
	Team = Scribe.Enum("Civilian", { "Civilian", "Police", "MP" }), -- u8 index
	Nick = Scribe.String("", { MaxLength = 8 }),
	Packed = buffer.create(0), -- schema-typed buffer leaf
	Settings = { Music = true, Sfx = true },
	Inventory = {},
	Quests = {},
}
local compiled = Template.Compile(template, {})

local function nodeFor(path)
	local node, dynStart = Template.Resolve(compiled, path)
	for i = dynStart, #path do
		node = Template.ChildSchema(node, path[i])
	end
	return node
end

local function encodeValue(path, value)
	local w = Wire.NewWriter(16)
	Wire.EncodeValue(w, nodeFor(path), value)
	return w
end

local function roundTripValue(path, value)
	local w = encodeValue(path, value)
	local r = Wire.NewReader(Wire.Finish(w))
	return Wire.DecodeValue(r, nodeFor(path)), w.len
end

local function roundTripOps(ops)
	local bytes = Wire.EncodeOpsFrame(Wire.Frames.Diff, compiled, ops)
	local r = Wire.NewReader(bytes)
	expect(Wire.RU8(r)).toBe(Wire.Frames.Diff)
	return Wire.DecodeOps(r, compiled)
end

local function expectDeepEqual(a, b)
	local ok, why = deepEquals(a, b)
	if not ok then
		error(`deep-equal failed: {why}`, 2)
	end
end

describe("bounds packing", function()
	it("packs a both-bounds int into the smallest fixed width (u8)", function()
		local decoded, len = roundTripValue({ "Level" }, 137)
		expect(decoded).toBe(137)
		expect(len).toBe(2) -- 1 mode byte + u8
	end)

	it("packs a wide both-bounds int as u32", function()
		local decoded, len = roundTripValue({ "Coins" }, 999999)
		expect(decoded).toBe(999999)
		expect(len).toBe(5) -- 1 mode byte + u32
	end)

	it("packs Min>=0 ints as unsigned varints", function()
		local decoded, len = roundTripValue({ "Gems" }, 5)
		expect(decoded).toBe(5)
		expect(len).toBe(2)
		local big = roundTripValue({ "Gems" }, 2 ^ 40)
		expect(big).toBe(2 ^ 40)
	end)

	it("packs unbounded ints as zigzag varints", function()
		expect((roundTripValue({ "Delta" }, -5))).toBe(-5)
		expect((roundTripValue({ "Delta" }, 300))).toBe(300)
		expect((roundTripValue({ "Delta" }, -123456789))).toBe(-123456789)
	end)

	it("round-trips large ints via the generic fallback past 2^52", function()
		-- Beyond 2^52 the varint/zigzag arithmetic is lossy, so canSchemaEncode
		-- routes these through MODE_GENERIC (raw f64), which round-trips any
		-- finite double exactly: no client brick, no silent sign flip.
		expect((roundTripValue({ "Gems" }, 2 ^ 57))).toBe(2 ^ 57)
		expect((roundTripValue({ "Gems" }, 2 ^ 70))).toBe(2 ^ 70) -- was undecodable before
		expect((roundTripValue({ "Delta" }, 2 ^ 55))).toBe(2 ^ 55)
		-- Negative large ints previously sign-flipped through zigzag.
		expect((roundTripValue({ "Delta" }, -(2 ^ 53)))).toBe(-(2 ^ 53))
		expect((roundTripValue({ "Delta" }, -(2 ^ 60)))).toBe(-(2 ^ 60))
		-- Values within the exact varint range still round-trip.
		expect((roundTripValue({ "Delta" }, -(2 ^ 52)))).toBe(-(2 ^ 52))
	end)

	it("packs enums as a u8 index", function()
		local decoded, len = roundTripValue({ "Team" }, "Police")
		expect(decoded).toBe("Police")
		expect(len).toBe(2)
	end)

	it("packs booleans as one byte", function()
		local decoded, len = roundTripValue({ "Settings", "Music" }, false)
		expect(decoded).toBe(false)
		expect(len).toBe(2)
	end)

	it("keeps fractional numbers as exact f64", function()
		expect((roundTripValue({ "Health" }, 99.125))).toBe(99.125)
	end)

	it("round-trips strings", function()
		expect((roundTripValue({ "Nick" }, "abc"))).toBe("abc")
		expect((roundTripValue({ "Nick" }, ""))).toBe("")
	end)

	it("falls back to generic encoding when a value violates its schema", function()
		-- Out of declared bounds: fixed-width packing would corrupt, so the
		-- encoder must switch to the generic mode instead.
		expect((roundTripValue({ "Coins" }, 2000000))).toBe(2000000)
		expect((roundTripValue({ "Coins" }, -5))).toBe(-5)
		-- Wrong type entirely (Wire trusts upstream validation but must
		-- never corrupt the stream).
		expect((roundTripValue({ "Coins" }, "not a number"))).toBe("not a number")
		expect((roundTripValue({ "Team" }, "NotAMember"))).toBe("NotAMember")
	end)
end)

describe("ops and paths", function()
	it("round-trips a static-path Set op", function()
		local ops = roundTripOps({ { Kind = "Set", Path = { "Coins" }, Value = 42 } })
		expect(#ops).toBe(1)
		expect(ops[1].Kind).toBe("Set")
		expectDeepEqual(ops[1].Path, { "Coins" })
		expect(ops[1].Value).toBe(42)
	end)

	it("round-trips dynamic string/number path segments", function()
		local ops = roundTripOps({
			{ Kind = "Set", Path = { "Inventory", "Sword_001", "Dmg" }, Value = 25 },
			{ Kind = "Set", Path = { "Inventory", 7 }, Value = "seven" },
			{ Kind = "Set", Path = { "Inventory", 1.5 }, Value = true },
		})
		expectDeepEqual(ops[1].Path, { "Inventory", "Sword_001", "Dmg" })
		expect(ops[1].Value).toBe(25)
		expectDeepEqual(ops[2].Path, { "Inventory", 7 })
		expect(ops[2].Value).toBe("seven")
		expectDeepEqual(ops[3].Path, { "Inventory", 1.5 })
		expect(ops[3].Value).toBe(true)
	end)

	it("round-trips Set nil (key removal) via the value-presence flag", function()
		local ops = roundTripOps({ { Kind = "Set", Path = { "Inventory", "Gone" } } })
		expect(ops[1].Kind).toBe("Set")
		expect(ops[1].Value).toBe(nil)
	end)

	it("round-trips Insert/Remove/Clear with indexes, preserving order", function()
		local ops = roundTripOps({
			{ Kind = "Insert", Path = { "Quests" }, Value = "A", Index = 1 },
			{ Kind = "Insert", Path = { "Quests" }, Value = "B", Index = 1 },
			{ Kind = "Remove", Path = { "Quests" }, Index = 2 },
			{ Kind = "Clear", Path = { "Quests" } },
		})
		expect(#ops).toBe(4)
		expect(ops[1].Kind).toBe("Insert")
		expect(ops[1].Index).toBe(1)
		expect(ops[1].Value).toBe("A")
		expect(ops[2].Value).toBe("B")
		expect(ops[3].Kind).toBe("Remove")
		expect(ops[3].Index).toBe(2)
		expect(ops[4].Kind).toBe("Clear")
	end)

	it("round-trips deep table values with static child ordinals", function()
		local value = { Music = false, Sfx = true }
		local ops = roundTripOps({ { Kind = "Set", Path = { "Settings" }, Value = value } })
		expectDeepEqual(ops[1].Value, value)
	end)

	it("round-trips buffers by schema and generically, without aliasing", function()
		local blob = buffer.fromstring("hello\0world")

		-- Schema-typed leaf: mode byte + varint length + raw bytes.
		local decoded, len = roundTripValue({ "Packed" }, blob)
		expect(typeof(decoded)).toBe("buffer")
		expect(decoded).toEqualBuffer(buffer.fromstring("hello\0world"))
		expect(len).toBe(1 + 1 + 11)

		-- Dynamic path: generic tagged encoding, fresh buffer on decode.
		local ops = roundTripOps({ { Kind = "Set", Path = { "Inventory", "Chunk" }, Value = blob } })
		expect(ops[1].Value).toEqualBuffer(buffer.fromstring("hello\0world"))
		expect(ops[1].Value == blob).toBe(false)

		-- Buffers nested inside generic tables.
		local nested = roundTripOps({
			{ Kind = "Set", Path = { "Inventory", "Bag" }, Value = { Chunks = { blob, blob } } },
		})
		expect(nested[1].Value.Chunks[2]).toEqualBuffer(buffer.fromstring("hello\0world"))
	end)

	it("round-trips generic mixed array+hash tables", function()
		-- selene: allow(mixed_table) -- the generic codec must survive mixed tables
		local value = { "a", "b", Count = 2, Nested = { X = 1.5, Flags = { true, false } } }
		local ops = roundTripOps({ { Kind = "Set", Path = { "Inventory", "Bag" }, Value = value } })
		expectDeepEqual(ops[1].Value, value)
	end)
end)

it("refuses a varint it cannot encode, rather than looping forever", function()
	-- The writer had no domain check while the reader caps itself at 10 groups.
	-- math.floor(inf) is inf, `inf >= 128` stays true and inf/128 is inf, so an
	-- infinite exponent put the encoder into an unbounded loop that grew the
	-- buffer until the process died: a server hang, not a bad frame. A negative
	-- was quieter and worse, wrapping writeu8 into bytes the reader mis-decodes.
	for _, bad in { math.huge, -math.huge, 0 / 0, -1, -0.5, 2 ^ 54 } do
		expect(function()
			Wire.Varint(Wire.NewWriter(8), bad)
		end).toThrow()
	end

	-- The whole legitimate domain still encodes and round-trips, including the
	-- boundary a zigzagged Scribe.Big exponent lands on.
	for _, good in { 0, 1, 127, 128, 2 ^ 32, 2 ^ 52, 2 ^ 53 } do
		local w = Wire.NewWriter(16)
		Wire.Varint(w, good)
		expect(Wire.RVarint(Wire.NewReader(Wire.Finish(w)))).toBe(good)
	end
end)

describe("malformed input rejection", function()
	it("rejects truncated frames", function()
		local bytes = Wire.EncodeOpsFrame(Wire.Frames.Diff, compiled, {
			{ Kind = "Set", Path = { "Nick" }, Value = "hello123" },
		})
		local truncated = buffer.create(buffer.len(bytes) - 3)
		buffer.copy(truncated, 0, bytes, 0, buffer.len(truncated))
		local reader = Wire.NewReader(truncated)
		Wire.RU8(reader)
		expect(function()
			Wire.DecodeOps(reader, compiled)
		end).toThrow()
	end)

	it("rejects garbage bytes", function()
		local garbage = buffer.create(16)
		for i = 0, 15 do
			buffer.writeu8(garbage, i, 0xFF)
		end
		local reader = Wire.NewReader(garbage)
		Wire.RU8(reader)
		expect(function()
			Wire.DecodeOps(reader, compiled)
		end).toThrow()
	end)

	it("rejects unknown field ids", function()
		local w = Wire.NewWriter(16)
		Wire.U8(w, Wire.Frames.Diff)
		Wire.U16(w, 1)
		Wire.U8(w, 1) -- op head: Set, no value
		Wire.Varint(w, 9999) -- nonexistent field id
		Wire.U8(w, 0)
		local reader = Wire.NewReader(Wire.Finish(w))
		Wire.RU8(reader)
		expect(function()
			Wire.DecodeOps(reader, compiled)
		end).toThrow()
	end)

	it("rejects strings that overrun the buffer", function()
		local w = Wire.NewWriter(16)
		Wire.Varint(w, 1000) -- claimed length far beyond the buffer
		Wire.U8(w, 65)
		local reader = Wire.NewReader(Wire.Finish(w))
		expect(function()
			Wire.RStr(reader)
		end).toThrow()
	end)
end)

describe("generic codec", function()
	it("round-trips every primitive", function()
		local w = Wire.NewWriter(64)
		Wire.EncodeGeneric(w, nil)
		Wire.EncodeGeneric(w, true)
		Wire.EncodeGeneric(w, false)
		Wire.EncodeGeneric(w, -1.25)
		Wire.EncodeGeneric(w, "hi")
		local r = Wire.NewReader(Wire.Finish(w))
		expect(Wire.DecodeGeneric(r)).toBe(nil)
		expect(Wire.DecodeGeneric(r)).toBe(true)
		expect(Wire.DecodeGeneric(r)).toBe(false)
		expect(Wire.DecodeGeneric(r)).toBe(-1.25)
		expect(Wire.DecodeGeneric(r)).toBe("hi")
	end)

	it("refuses to serialize functions", function()
		local w = Wire.NewWriter(16)
		expect(function()
			Wire.EncodeGeneric(w, function() end)
		end).toThrow()
	end)
end)
