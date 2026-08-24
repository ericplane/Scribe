--!nonstrict
-- Protocol 4: the value header byte (mode + dense flag + key tag in one byte)
-- and the dense-array fast path it enables.
--
-- THE FALLBACK IS TESTED FIRST, AND THAT ORDERING IS THE POINT. A fast path that
-- mis-encodes a shape it should have refused is not a bug, it is silent data
-- corruption: the frame decodes cleanly into a table the sender never held, so
-- nothing throws, nothing logs, and the client mirror is simply wrong. Every
-- shape below that is NOT exactly 1..n has to come out of the tagged path, and
-- the dense bit has to be observably clear in the bytes -- asserting only that
-- it round-trips would pass against an encoder that set the flag and got lucky.
return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Wire = require(ScribeRoot.Internal.Wire)
	local Template = require(ScribeRoot.Internal.Template)
	local deepEquals = require(Root.Test.Helpers.DeepEquals)

	-- Bits of the value header, restated here rather than imported: Wire keeps them
	-- private, and a test that read the encoder's own constants could not catch the
	-- encoder redefining them.
	local VH_GENERIC = 0x01
	local VH_DENSE = 0x02

	local template = {
		Ints = Scribe.ArrayOf(Scribe.Int(0, { Min = 0 })),
		Records = Scribe.ArrayOf({
			Id = Scribe.String("", { MaxLength = 32 }),
			Count = Scribe.Int(1, { Min = 0 }),
		}),
		Loose = {},
		Bag = Scribe.DictOf(Scribe.Int(0, { Min = 0 })),
		Nick = Scribe.String("", { MaxLength = 16 }),
		Level = Scribe.Int(1, { Min = 1, Max = 200 }),
	}
	local compiled = Template.Compile(template, {})

	local function nodeFor(path)
		local node, dynStart = Template.Resolve(compiled, path)
		for i = dynStart, #path do
			node = Template.ChildSchema(node, path[i])
		end
		return node
	end

	local function encode(path, value)
		local w = Wire.NewWriter(32)
		Wire.EncodeValue(w, nodeFor(path), value)
		return Wire.Finish(w)
	end

	local function decode(path, bytes, budget)
		return Wire.DecodeValue(Wire.NewReader(bytes, budget), nodeFor(path))
	end

	local function isDense(header)
		return header % 4 >= VH_DENSE
	end

	--- Round-trip, deep-equal, and hand back the header byte and encoded length so
	--- a caller can pin the SHAPE the encoder chose, not just the value it kept.
	local function roundTrip(path, value)
		local bytes = encode(path, value)
		local back = decode(path, bytes)
		local ok, why = deepEquals(value, back)
		if not ok then
			error(`round-trip differed at {table.concat(path, ".")}: {why}`, 2)
		end
		return buffer.readu8(bytes, 0), buffer.len(bytes), back
	end

	--- An array with a named key bolted on afterwards. Built rather than written
	--- as a literal so `selene`'s mixed_table lint stays on for the rest of the
	--- repo -- a mixed table is a code smell everywhere except here, where it is
	--- the shape under test.
	local function withExtra(array, key, value)
		array[key] = value
		return array
	end

	describe("the fallback", function()
		-- Each of these is a table the dense path MUST refuse. `Loose` is an
		-- undeclared container, so every key resolves through AnyChild and the
		-- encoder is free to choose either path -- which makes it the honest place
		-- to test the choice.
		local NOT_DENSE = {
			{ name = "a hole in the middle", value = { [1] = 10, [3] = 30 } },
			{ name = "a hole at the end", value = { [1] = 10, [2] = 20, [4] = 40 } },
			{ name = "mixed array and hash", value = withExtra({ 1, 2, 3 }, "extra", "x") },
			{ name = "zero-based indices", value = { [0] = "a", [1] = "b" } },
			{ name = "string keys only", value = { alpha = 1, beta = 2 } },
			{ name = "a float key", value = { [1] = 1, [2.5] = 2 } },
			{ name = "a negative key", value = { [1] = 1, [-1] = 2 } },
			{ name = "indices starting at 2", value = { [2] = "b", [3] = "c" } },
			{ name = "one far index", value = { [1000] = "far" } },
			{ name = "the empty table", value = {} },
		}

		for _, case in NOT_DENSE do
			it(`refuses the dense path for {case.name}, and round-trips it`, function()
				local header, _len, back = roundTrip({ "Loose" }, case.value)
				-- THE ASSERTION THAT MATTERS. A round-trip alone would pass against an
				-- encoder that set the flag and happened to survive; the flag itself is
				-- what says the tagged path ran.
				expect(isDense(header)).to.equal(false)
				-- And the keys survived as keys, which positional encoding would lose.
				for k, v in case.value do
					expect(back[k]).to.equal(v)
				end
			end)
		end

		it("keeps a hole a hole rather than filling it with nil", function()
			-- The specific corruption the dense path would cause if `#value` decided
			-- density instead of a probe of every index: the length operator on a
			-- holey table may report either boundary, so `{[1]=1,[3]=3}` can answer 3.
			-- An encoder that trusted it would write three positional values, and the
			-- decoder would rebuild a table with a key 2 that never existed.
			local holey = { [1] = 1, [3] = 3 }
			local back = decode({ "Loose" }, encode({ "Loose" }, holey))
			local keys = 0
			for _ in back do
				keys += 1
			end
			expect(keys).to.equal(2)
			expect(back[2]).to.equal(nil)
			expect(back[3]).to.equal(3)
		end)

		it("refuses the dense path for a DECLARED array that is sparse", function()
			-- Same shape, but under an ArrayOf node whose element schema is typed --
			-- the case the fast path was written for, deliberately given the wrong
			-- shape. Nothing about the declaration may be allowed to imply density.
			local header = roundTrip({ "Ints" }, { [1] = 5, [3] = 7 })
			expect(isDense(header)).to.equal(false)
		end)

		it("refuses the dense path for a declared array carrying an extra hash key", function()
			local header, _len, back = roundTrip({ "Ints" }, withExtra({ 5, 6, 7 }, "tail", 9))
			expect(isDense(header)).to.equal(false)
			expect(back.tail).to.equal(9)
			expect(back[3]).to.equal(7)
		end)
	end)

	describe("the dense path", function()
		it("takes it for exactly 1..n and round-trips", function()
			local header, _len, back = roundTrip({ "Ints" }, { 4, 5, 6 })
			expect(isDense(header)).to.equal(true)
			expect(header % 2).to.equal(0) -- still schema mode
			expect(#back).to.equal(3)
			expect(back[2]).to.equal(5)
		end)

		it("takes it for a single-element array", function()
			local header = roundTrip({ "Ints" }, { 42 })
			expect(isDense(header)).to.equal(true)
		end)

		it("saves the key tag and the index per element", function()
			-- 200 elements, values wide enough that the payload is not the whole
			-- story. The saving is structural: one tag byte per element, plus an
			-- index varint that is 1 byte to 127 and 2 bytes beyond.
			local ints = {}
			for i = 1, 200 do
				ints[i] = (i * 7919) % 100000
			end
			local _header, len = roundTrip({ "Ints" }, ints)
			local expectedSaving = 200 + (127 * 1 + 73 * 2)
			-- Pinned as a number so a regression that quietly reverts to the tagged
			-- path fails here rather than only showing up as a bigger frame.
			expect(expectedSaving).to.equal(473)
			expect(len).to.equal(1244 - expectedSaving)
		end)

		it("round-trips an array of records, dense outside and tagged inside", function()
			local records = {}
			for i = 1, 8 do
				records[i] = { Id = `item_{i}`, Count = i * 3 }
			end
			local header, _len, back = roundTrip({ "Records" }, records)
			expect(isDense(header)).to.equal(true)
			expect(back[8].Id).to.equal("item_8")
			expect(back[8].Count).to.equal(24)
		end)

		it("nests dense inside dense", function()
			local nested = { { 1, 2 }, { 3, 4, 5 } }
			local header, _len, back = roundTrip({ "Loose" }, nested)
			expect(isDense(header)).to.equal(true)
			expect(#back).to.equal(2)
			expect(back[2][3]).to.equal(5)
		end)
	end)

	describe("the value mode still degrades", function()
		-- R5. The mode bit moved into the header; its job did not move. A value the
		-- schema cannot describe must still fall to the self-describing generic
		-- codec instead of writing bytes the reader would read against the wrong
		-- node -- and that has to hold INSIDE a dense parent, which is the new place
		-- it could have been dropped.
		it("degrades a schema-violating element inside a DENSE array", function()
			-- Ints is ArrayOf(Int); a string element cannot be schema-encoded. The
			-- array is still dense (keys 1..3), so the element's own header is the
			-- only thing that can save it.
			local value = { 1, "not-an-int", 3 }
			local bytes = encode({ "Ints" }, value)
			expect(isDense(buffer.readu8(bytes, 0))).to.equal(true)
			local back = decode({ "Ints" }, bytes)
			expect(back[1]).to.equal(1)
			expect(back[2]).to.equal("not-an-int")
			expect(back[3]).to.equal(3)
		end)

		it("degrades a schema-violating value inside a TAGGED entry", function()
			local value = { alpha = 1, beta = "not-an-int" }
			local back = decode({ "Bag" }, encode({ "Bag" }, value))
			expect(back.alpha).to.equal(1)
			expect(back.beta).to.equal("not-an-int")
		end)

		it("marks a whole value generic when its own node cannot describe it", function()
			local bytes = encode({ "Level" }, "a string where an int was declared")
			expect(buffer.readu8(bytes, 0) % 2).to.equal(VH_GENERIC)
			expect(decode({ "Level" }, bytes)).to.equal("a string where an int was declared")
		end)

		it("degrades a table under a leaf node", function()
			local back = decode({ "Nick" }, encode({ "Nick" }, { 1, 2, 3 }))
			expect(back[2]).to.equal(2)
		end)
	end)

	describe("the folded header", function()
		it("spends ONE byte on the key tag and the mode together", function()
			-- 1B, pinned byte by byte. A single-entry dict: header, key length, key
			-- bytes, value. Before the fold this was a tag byte, the key, and then a
			-- separate mode byte -- one more byte, and the mode sat AFTER the key.
			local bytes = encode({ "Bag" }, { ab = 7 })
			-- [0] table header (schema, not dense -- string keys)
			expect(buffer.readu8(bytes, 0)).to.equal(0)
			-- [1] entry count
			expect(buffer.readu8(bytes, 1)).to.equal(1)
			-- [2] the folded byte: key tag TAG_KEY_STRING (1) in bits 2-3, schema mode
			-- in bit 0. `Bag` is a DictOf, so its keys are dynamic strings, not static
			-- ordinals.
			expect(buffer.readu8(bytes, 2)).to.equal(1 * 4)
			-- [3..5] the key, length-prefixed
			expect(buffer.readu8(bytes, 3)).to.equal(2)
			expect(buffer.readu8(bytes, 4)).to.equal(string.byte("a"))
			expect(buffer.readu8(bytes, 5)).to.equal(string.byte("b"))
			-- [6] the value, with NO mode byte of its own
			expect(buffer.readu8(bytes, 6)).to.equal(7)
			expect(buffer.len(bytes)).to.equal(7)
		end)

		it("refuses a header whose reserved bits are set", function()
			-- Bits 4-7 are spare. Ignoring them would mean a drifted encoder's frame
			-- decodes as something else entirely rather than being refused, which is
			-- the whole reason the version gate exists.
			local bytes = encode({ "Bag" }, { ab = 7 })
			buffer.writeu8(bytes, 2, buffer.readu8(bytes, 2) + 0x10)
			expect(function()
				decode({ "Bag" }, bytes)
			end).to.throw()
		end)

		it("refuses key-tag bits on a standalone value header", function()
			-- A standalone header owns bits 0-1 only. Key-tag bits here mean writer
			-- and reader disagree about whether the value sits in a table.
			local bytes = encode({ "Level" }, 12)
			buffer.writeu8(bytes, 0, buffer.readu8(bytes, 0) + 1 * 4)
			expect(function()
				decode({ "Level" }, bytes)
			end).to.throw()
		end)
	end)

	describe("the retention budget", function()
		-- R2. The dense encoding lets a frame declare more slots per byte than the
		-- tagged one did, so the charge has to move with it or the cap silently
		-- loosens. A dense element charges SLOT_BYTES (32) from the count, BEFORE
		-- the recursive decode.
		local TABLE_BYTES, SLOT_BYTES, HASH_BYTES = 64, 32, 64

		it("charges a dense array per slot, exactly", function()
			local bytes = encode({ "Ints" }, { 1, 2, 3 })
			local exact = TABLE_BYTES + SLOT_BYTES * 3
			expect(decode({ "Ints" }, bytes, exact)).to.be.ok()
			expect(function()
				decode({ "Ints" }, bytes, exact - 1)
			end).to.throw()
		end)

		it("charges the tagged path per hash pair, unchanged", function()
			local bytes = encode({ "Bag" }, { a = 1, b = 2 })
			-- Two pairs, plus the 24-byte string header and one payload byte for each
			-- decoded key.
			local exact = TABLE_BYTES + (HASH_BYTES + 24 + 1) * 2
			expect(decode({ "Bag" }, bytes, exact)).to.be.ok()
			expect(function()
				decode({ "Bag" }, bytes, exact - 1)
			end).to.throw()
		end)

		it("refuses a long dense array partway, before decoding the rest of it", function()
			-- A frame declaring more slots than the budget allows must be refused
			-- ON THE WAY THROUGH, not after it has allocated its way to the end. Each
			-- slot is charged before its own recursive decode, exactly as the generic
			-- array decoder charges, so the refusal lands at the slot that overruns.
			local ints = {}
			for i = 1, 200 do
				ints[i] = i
			end
			local bytes = encode({ "Ints" }, ints)
			expect(decode({ "Ints" }, bytes, TABLE_BYTES + SLOT_BYTES * 200)).to.be.ok()

			local reader = Wire.NewReader(bytes, TABLE_BYTES + SLOT_BYTES * 50)
			local ok = pcall(Wire.DecodeValue, reader, nodeFor({ "Ints" }))
			expect(ok).to.equal(false)
			-- Refused for being EXPENSIVE, not for being malformed -- the flag is what
			-- lets the server tell a flood from corruption.
			expect(reader.overBudget).to.equal(true)
			-- And it stopped early: the reader never walked to the end of the frame.
			expect(reader.pos < buffer.len(bytes)).to.equal(true)
		end)

		it("refuses a crafted dense count with nothing behind it", function()
			-- The other half: a two-byte frame claiming 100,000 elements. Hand-built,
			-- because no encoder produces it.
			local w = Wire.NewWriter(8)
			Wire.U8(w, VH_DENSE)
			Wire.Varint(w, 100000)
			local reader = Wire.NewReader(Wire.Finish(w), 4096)
			expect(pcall(Wire.DecodeValue, reader, nodeFor({ "Ints" }))).to.equal(false)
		end)

		it("keeps a dense element's floor at the same 16:1 the tagged path had", function()
			-- The reason the dense charge is SLOT_BYTES and not HASH_BYTES. The
			-- cheapest dense element is its header byte plus the smallest schema
			-- payload; charging it a hash pair's 64 would have doubled what a frame
			-- can retain per byte.
			local bytes = encode({ "Loose" }, { true, true, true })
			-- 1 header + 1 count + 3 * (1 header + 1 payload) = 8 bytes for 3 slots.
			expect(buffer.len(bytes)).to.equal(8)
			local perElement = 2
			expect(SLOT_BYTES / perElement).to.equal(16)
		end)
	end)

	describe("round-trips the awkward corpus", function()
		-- R6. Encode, decode, deep-equal, over shapes chosen because each one sits
		-- on a different edge of the density test rather than because it is likely.
		it("survives every shape", function()
			local CORPUS = {
				{},
				{ 1 },
				{ 1, 2, 3, 4, 5 },
				{ [1] = 1, [3] = 3 },
				{ [2] = 2 },
				{ [0] = 0, [1] = 1, [2] = 2 },
				{ a = 1 },
				withExtra({ 1, 2 }, "a", 3),
				{ [1.5] = "half" },
				{ [-3] = "neg", [1] = "one" },
				{ { 1, 2 }, { a = 1 } },
				{ true, false, true },
				{ "a", "bb", "ccc" },
				{ 1, "two", { 3 }, false },
				{ [1] = { [1] = { [1] = { 1, 2 } } } },
				{ [1] = 1, [2] = 2, [3] = 3, big = { x = { y = { 1, 2, 3 } } } },
			}
			for i, shape in CORPUS do
				local bytes = encode({ "Loose" }, shape)
				local back = decode({ "Loose" }, bytes)
				local ok, why = deepEquals(shape, back)
				if not ok then
					error(`corpus case {i} did not round-trip: {why}`, 0)
				end
			end
		end)

		it("survives the same corpus through a whole ops frame", function()
			-- Through EncodeOpsFrame/DecodeOps rather than EncodeValue directly, so
			-- the op header, path codec and value codec are exercised together.
			local ops = {
				{ Kind = "Set", Path = { "Ints" }, Value = { 9, 8, 7 } },
				{ Kind = "Set", Path = { "Loose" }, Value = { [1] = 1, [4] = 4 } },
				{ Kind = "Set", Path = { "Bag" }, Value = { k = 3 } },
				{ Kind = "Insert", Path = { "Ints" }, Value = 11, Index = 1 },
				{ Kind = "Set", Path = { "Records" }, Value = { { Id = "a", Count = 1 } } },
			}
			local frame = Wire.EncodeOpsFrame(Wire.Frames.Diff, compiled, ops)
			local reader = Wire.NewReader(frame)
			expect(Wire.RU8(reader)).to.equal(Wire.Frames.Diff)
			local back = Wire.DecodeOps(reader, compiled)
			local ok, why = deepEquals(ops, back)
			if not ok then
				error(`ops frame did not round-trip: {why}`, 0)
			end
		end)
	end)

	describe("the protocol version", function()
		it("moved for the layout change", function()
			-- R3. Every byte after a table's entry count shifted, and a v3 reader
			-- would read a v4 header's key-tag bits as a mode byte. Nothing about
			-- that announces itself, so the version has to. Re-pinned at 5 when the
			-- presence bitmask took the header's fourth mode value (see
			-- WireBitmask.spec), and again at 6 when Scribe.Number gained declared
			-- narrowing (see WireFloat.spec) -- the constant this asserts is "the
			-- current wire layout", not "the layout this file introduced".
			--
			-- A CONSTANT IS NOT THE PIN THAT MATTERS. Whoever changes the layout can
			-- change this line in the same edit and never run the refusal at all.
			-- Replication.spec's "refuses a Hello whose protocol version differs"
			-- drives a mismatched version through the real onHello; that is the test
			-- R3 actually rests on.
			expect(Wire.PROTOCOL_VERSION).to.equal(6)
		end)
	end)
end
