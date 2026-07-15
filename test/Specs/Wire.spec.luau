--!nonstrict
-- Round-trip serialization for the schema encoder/decoder: dynamic keys, nil,
-- bounds packing, malformed rejection.

return function()
	local Root = script.Parent.Parent.Parent
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
		expect(Wire.RU8(r)).to.equal(Wire.Frames.Diff)
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
			expect(decoded).to.equal(137)
			expect(len).to.equal(2) -- 1 mode byte + u8
		end)

		it("packs a wide both-bounds int as u32", function()
			local decoded, len = roundTripValue({ "Coins" }, 999999)
			expect(decoded).to.equal(999999)
			expect(len).to.equal(5) -- 1 mode byte + u32
		end)

		it("packs Min>=0 ints as unsigned varints", function()
			local decoded, len = roundTripValue({ "Gems" }, 5)
			expect(decoded).to.equal(5)
			expect(len).to.equal(2)
			local big = roundTripValue({ "Gems" }, 2 ^ 40)
			expect(big).to.equal(2 ^ 40)
		end)

		it("packs unbounded ints as zigzag varints", function()
			expect(roundTripValue({ "Delta" }, -5)).to.equal(-5)
			expect(roundTripValue({ "Delta" }, 300)).to.equal(300)
			expect(roundTripValue({ "Delta" }, -123456789)).to.equal(-123456789)
		end)

		it("round-trips large ints via the generic fallback past 2^52", function()
			-- Beyond 2^52 the varint/zigzag arithmetic is lossy, so canSchemaEncode
			-- routes these through MODE_GENERIC (raw f64), which round-trips any
			-- finite double exactly — no client brick, no silent sign flip.
			expect(roundTripValue({ "Gems" }, 2 ^ 57)).to.equal(2 ^ 57)
			expect(roundTripValue({ "Gems" }, 2 ^ 70)).to.equal(2 ^ 70) -- was undecodable before
			expect(roundTripValue({ "Delta" }, 2 ^ 55)).to.equal(2 ^ 55)
			-- Negative large ints previously sign-flipped through zigzag.
			expect(roundTripValue({ "Delta" }, -(2 ^ 53))).to.equal(-(2 ^ 53))
			expect(roundTripValue({ "Delta" }, -(2 ^ 60))).to.equal(-(2 ^ 60))
			-- Values within the exact varint range still round-trip.
			expect(roundTripValue({ "Delta" }, -(2 ^ 52))).to.equal(-(2 ^ 52))
		end)

		it("packs enums as a u8 index", function()
			local decoded, len = roundTripValue({ "Team" }, "Police")
			expect(decoded).to.equal("Police")
			expect(len).to.equal(2)
		end)

		it("packs booleans as one byte", function()
			local decoded, len = roundTripValue({ "Settings", "Music" }, false)
			expect(decoded).to.equal(false)
			expect(len).to.equal(2)
		end)

		it("keeps fractional numbers as exact f64", function()
			expect(roundTripValue({ "Health" }, 99.125)).to.equal(99.125)
		end)

		it("round-trips strings", function()
			expect(roundTripValue({ "Nick" }, "abc")).to.equal("abc")
			expect(roundTripValue({ "Nick" }, "")).to.equal("")
		end)

		it("falls back to generic encoding when a value violates its schema", function()
			-- Out of declared bounds: fixed-width packing would corrupt, so the
			-- encoder must switch to the generic mode instead.
			expect(roundTripValue({ "Coins" }, 2000000)).to.equal(2000000)
			expect(roundTripValue({ "Coins" }, -5)).to.equal(-5)
			-- Wrong type entirely (Wire trusts upstream validation but must
			-- never corrupt the stream).
			expect(roundTripValue({ "Coins" }, "not a number")).to.equal("not a number")
			expect(roundTripValue({ "Team" }, "NotAMember")).to.equal("NotAMember")
		end)
	end)

	describe("ops and paths", function()
		it("round-trips a static-path Set op", function()
			local ops = roundTripOps({ { Kind = "Set", Path = { "Coins" }, Value = 42 } })
			expect(#ops).to.equal(1)
			expect(ops[1].Kind).to.equal("Set")
			expectDeepEqual(ops[1].Path, { "Coins" })
			expect(ops[1].Value).to.equal(42)
		end)

		it("round-trips dynamic string/number path segments", function()
			local ops = roundTripOps({
				{ Kind = "Set", Path = { "Inventory", "Sword_001", "Dmg" }, Value = 25 },
				{ Kind = "Set", Path = { "Inventory", 7 }, Value = "seven" },
				{ Kind = "Set", Path = { "Inventory", 1.5 }, Value = true },
			})
			expectDeepEqual(ops[1].Path, { "Inventory", "Sword_001", "Dmg" })
			expect(ops[1].Value).to.equal(25)
			expectDeepEqual(ops[2].Path, { "Inventory", 7 })
			expect(ops[2].Value).to.equal("seven")
			expectDeepEqual(ops[3].Path, { "Inventory", 1.5 })
			expect(ops[3].Value).to.equal(true)
		end)

		it("round-trips Set nil (key removal) via the value-presence flag", function()
			local ops = roundTripOps({ { Kind = "Set", Path = { "Inventory", "Gone" } } })
			expect(ops[1].Kind).to.equal("Set")
			expect(ops[1].Value).to.equal(nil)
		end)

		it("round-trips Insert/Remove/Clear with indexes, preserving order", function()
			local ops = roundTripOps({
				{ Kind = "Insert", Path = { "Quests" }, Value = "A", Index = 1 },
				{ Kind = "Insert", Path = { "Quests" }, Value = "B", Index = 1 },
				{ Kind = "Remove", Path = { "Quests" }, Index = 2 },
				{ Kind = "Clear", Path = { "Quests" } },
			})
			expect(#ops).to.equal(4)
			expect(ops[1].Kind).to.equal("Insert")
			expect(ops[1].Index).to.equal(1)
			expect(ops[1].Value).to.equal("A")
			expect(ops[2].Value).to.equal("B")
			expect(ops[3].Kind).to.equal("Remove")
			expect(ops[3].Index).to.equal(2)
			expect(ops[4].Kind).to.equal("Clear")
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
			expect(typeof(decoded)).to.equal("buffer")
			expect(buffer.tostring(decoded)).to.equal("hello\0world")
			expect(len).to.equal(1 + 1 + 11)

			-- Dynamic path: generic tagged encoding, fresh buffer on decode.
			local ops = roundTripOps({ { Kind = "Set", Path = { "Inventory", "Chunk" }, Value = blob } })
			expect(buffer.tostring(ops[1].Value)).to.equal("hello\0world")
			expect(ops[1].Value == blob).to.equal(false)

			-- Buffers nested inside generic tables.
			local nested = roundTripOps({
				{ Kind = "Set", Path = { "Inventory", "Bag" }, Value = { Chunks = { blob, blob } } },
			})
			expect(buffer.tostring(nested[1].Value.Chunks[2])).to.equal("hello\0world")
		end)

		it("round-trips generic mixed array+hash tables", function()
			-- selene: allow(mixed_table) -- the generic codec must survive mixed tables
			local value = { "a", "b", Count = 2, Nested = { X = 1.5, Flags = { true, false } } }
			local ops = roundTripOps({ { Kind = "Set", Path = { "Inventory", "Bag" }, Value = value } })
			expectDeepEqual(ops[1].Value, value)
		end)
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
			end).to.throw()
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
			end).to.throw()
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
			end).to.throw()
		end)

		it("rejects strings that overrun the buffer", function()
			local w = Wire.NewWriter(16)
			Wire.Varint(w, 1000) -- claimed length far beyond the buffer
			Wire.U8(w, 65)
			local reader = Wire.NewReader(Wire.Finish(w))
			expect(function()
				Wire.RStr(reader)
			end).to.throw()
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
			expect(Wire.DecodeGeneric(r)).to.equal(nil)
			expect(Wire.DecodeGeneric(r)).to.equal(true)
			expect(Wire.DecodeGeneric(r)).to.equal(false)
			expect(Wire.DecodeGeneric(r)).to.equal(-1.25)
			expect(Wire.DecodeGeneric(r)).to.equal("hi")
		end)

		it("refuses to serialize functions", function()
			local w = Wire.NewWriter(16)
			expect(function()
				Wire.EncodeGeneric(w, function() end)
			end).to.throw()
		end)
	end)
end
