--!nonstrict
-- Protocol 5: the presence bitmask. A table whose keys are ALL declared static
-- children of its schema node now encodes as one bit per declared child followed
-- by the present children's values positionally, where every field used to spend
-- a key tag and an ordinal varint of its own.
--
-- THE FALLBACK IS TESTED FIRST, AND THAT ORDERING IS THE POINT -- the same point
-- WireDense.spec makes about the dense path, and it is sharper here. The dense
-- flag can only be wrong about a shape; the bitmask can be wrong about a KEY. Its
-- positions ARE the key set, so a table carrying one key the receiver's
-- ChildOrder does not contain has nowhere to put it: encode it this way and the
-- key does not arrive, the frame decodes cleanly, nothing throws, nothing logs,
-- and the mirror is simply missing a field. That is not a bug, it is silent data
-- loss, and the only thing standing between it and production is that
-- isStaticStruct refuses such a table outright. So every shape below that is not
-- exactly "all keys declared" has to come out of the TAGGED path, and the mode
-- has to be observably tagged in the bytes -- asserting only that it round-trips
-- would pass against an encoder that took the bitmask and got lucky on a table
-- whose stray key happened to be absent.
return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Wire = require(ScribeRoot.Internal.Wire)
	local Template = require(ScribeRoot.Internal.Template)
	local deepEquals = require(Root.Test.Helpers.DeepEquals)

	-- The header's four modes, restated here rather than imported: Wire keeps them
	-- private, and a test that read the encoder's own constants could not catch the
	-- encoder redefining them.
	local TAGGED, GENERIC, DENSE, STATIC = 0, 1, 2, 3

	-- The retention model's constants, restated for the same reason.
	local TABLE_BYTES, HASH_BYTES = 64, 64

	local wideShape = {}
	for i = 1, 32 do
		wideShape[string.format("F%02d", i)] = false
	end
	local tableShape = {}
	for i = 1, 32 do
		tableShape[string.format("T%02d", i)] = { A = false }
	end
	local recordShape = {
		Id = Scribe.String("", { MaxLength = 32 }),
		Count = Scribe.Int(1, { Min = 0, Max = 9999 }),
		Slot = Scribe.Int(0, { Min = 0, Max = 255 }),
		Rarity = Scribe.Enum("Common", { "Common", "Rare", "Epic" }),
		Bound = false,
		Level = Scribe.Int(1, { Min = 1, Max = 100 }),
		Durability = Scribe.Int(100, { Min = 0, Max = 100 }),
		Locked = false,
		Favorite = false,
		Acquired = Scribe.Number(0),
		Seed = Scribe.Int(0, { Min = 0 }),
	}

	local template = {
		-- Three declared children: the smallest struct the mask still beats the
		-- ordinals on, and small enough to write the whole encoding out by hand.
		Trio = { A = false, B = false, C = false },
		-- An OPEN struct. An undeclared key resolves to a generic any-node, which is
		-- the legacy field / dynamic key case the fallback exists for.
		Gear = {
			Amulet = Scribe.Int(0, { Min = 0, Max = 255 }),
			Belt = Scribe.Int(0, { Min = 0, Max = 255 }),
			Body = Scribe.Int(0, { Min = 0, Max = 255 }),
			Boots = Scribe.Int(0, { Min = 0, Max = 255 }),
			Cape = Scribe.Int(0, { Min = 0, Max = 255 }),
			Gloves = Scribe.Int(0, { Min = 0, Max = 255 }),
			Head = Scribe.Int(0, { Min = 0, Max = 255 }),
			Legs = Scribe.Int(0, { Min = 0, Max = 255 }),
			Ring = Scribe.Int(0, { Min = 0, Max = 255 }),
		},
		-- A CLOSED element record: an undeclared key resolves to nothing at all,
		-- which is a different code path in ChildSchema from the open case above.
		Roster = Scribe.ArrayOf({
			Name = Scribe.String("", { MaxLength = 16 }),
			Rank = Scribe.Int(0, { Min = 0, Max = 99 }),
			Active = false,
		}),
		-- A struct with a nested struct inside it, so static-inside-static is a
		-- shape the corpus actually reaches.
		Nest = {
			Flag = false,
			Inner = { X = false, Y = false, Z = false },
			Tag = Scribe.String("", { MaxLength = 8 }),
		},
		Wide = wideShape,
		Tables = tableShape,
		Inventory = Scribe.ArrayOf(recordShape, { MaxItems = 2000 }),
		Bools = Scribe.ArrayOf(false, { MaxItems = 5000 }),
		Nested = Scribe.ArrayOf(Scribe.ArrayOf(false, { MaxItems = 8 }), { MaxItems = 5000 }),
		Bag = Scribe.DictOf(Scribe.Int(0, { Min = 0 })),
		Loose = {},
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
		local w = Wire.NewWriter(64)
		Wire.EncodeValue(w, nodeFor(path), value)
		return Wire.Finish(w)
	end

	local function decode(path, bytes, budget)
		return Wire.DecodeValue(Wire.NewReader(bytes, budget), nodeFor(path))
	end

	local function modeOf(bytes)
		return buffer.readu8(bytes, 0) % 4
	end

	--- Round-trip, deep-equal, and hand back the mode and encoded length so a caller
	--- can pin the ENCODING the writer chose, not just the value it kept.
	local function roundTrip(path, value)
		local bytes = encode(path, value)
		local back = decode(path, bytes)
		local ok, why = deepEquals(value, back)
		if not ok then
			error(`round-trip differed at {table.concat(path, ".")}: {why}`, 2)
		end
		return modeOf(bytes), buffer.len(bytes), back
	end

	--- A struct with an extra key bolted on afterwards. Built rather than written as
	--- a literal so selene's mixed-key lints stay on for the rest of the repo -- an
	--- undeclared key is a code smell everywhere except here, where it is the shape
	--- under test.
	local function withExtra(struct, key, value)
		struct[key] = value
		return struct
	end

	local function keyCount(t)
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end

	local function copyBytes(bytes)
		local out = buffer.create(buffer.len(bytes))
		buffer.copy(out, 0, bytes, 0, buffer.len(bytes))
		return out
	end

	local function patched(bytes, index, value)
		local out = copyBytes(bytes)
		buffer.writeu8(out, index, value)
		return out
	end

	local function truncated(bytes, keep)
		local out = buffer.create(keep)
		buffer.copy(out, 0, bytes, 0, keep)
		return out
	end

	local function fromBytes(list)
		local out = buffer.create(#list)
		for i, b in list do
			buffer.writeu8(out, i - 1, b)
		end
		return out
	end

	local function refuses(path, bytes, needle)
		local ok, err = pcall(decode, path, bytes)
		if ok then
			error(`expected a refusal containing "{needle}", but the frame decoded`, 2)
		end
		if not string.find(tostring(err), needle, 1, true) then
			error(`expected a refusal containing "{needle}", got: {tostring(err)}`, 2)
		end
	end

	local function fullGear()
		return { Amulet = 1, Belt = 2, Body = 3, Boots = 4, Cape = 5, Gloves = 6, Head = 7, Legs = 8, Ring = 9 }
	end

	describe("the fallback, pinned before the fast path", function()
		it("refuses the bitmask for a struct carrying an undeclared key, and keeps the key", function()
			-- The whole reason the fallback exists. `Trinket` has no ordinal in
			-- ChildOrder, so a bitmask has no position to carry it in; an encoder that
			-- took the fast path anyway would drop it in silence.
			local value = withExtra(fullGear(), "Trinket", "legacy-field")
			local mode, _len, back = roundTrip({ "Gear" }, value)
			expect(mode).to.equal(TAGGED)
			expect(back.Trinket).to.equal("legacy-field")
			expect(keyCount(back)).to.equal(10)
		end)

		it("refuses it for a struct carrying a NUMERIC key alongside its declared ones", function()
			local value = withExtra(fullGear(), 1, "positional")
			local mode, _len, back = roundTrip({ "Gear" }, value)
			expect(mode).to.equal(TAGGED)
			expect(back[1]).to.equal("positional")
		end)

		it("refuses it for a CLOSED element record carrying an undeclared key", function()
			-- Different branch in Template.ChildSchema: a closed record resolves an
			-- undeclared key to nil rather than to a generic any-node, so the key's
			-- value degrades to the generic codec while the key itself still travels.
			local record = withExtra({ Name = "ada", Rank = 3, Active = true }, "Legacy", 42)
			local mode, _len, back = roundTrip({ "Roster", 1 }, record)
			expect(mode).to.equal(TAGGED)
			expect(back.Legacy).to.equal(42)
			expect(back.Name).to.equal("ada")
		end)

		it("refuses it when the mask would cost more bytes than the ordinals it replaces", function()
			-- 32 declared children is 4 mask bytes plus a width varint; two present
			-- fields are two ordinals. The mask is only used where it WINS, so a
			-- sparsely-filled wide struct stays tagged.
			local mode, len = roundTrip({ "Wide" }, { F03 = true, F17 = true })
			expect(mode).to.equal(TAGGED)
			-- header + count + 2 * (header + ordinal + payload)
			expect(len).to.equal(8)
		end)

		it("refuses it on a tie", function()
			-- Trio with one field present: mask (1 width + 1 byte) against ordinals
			-- (1 count + 1 ordinal). Equal, so the existing path wins -- another shape
			-- on the wire for no saving is a bad trade.
			local mode = roundTrip({ "Trio" }, { B = true })
			expect(mode).to.equal(TAGGED)
		end)

		it("refuses it for an empty table", function()
			local mode = roundTrip({ "Trio" }, {})
			expect(mode).to.equal(TAGGED)
		end)

		it("leaves dynamic-key and array shapes exactly where they were", function()
			expect(roundTrip({ "Bag" }, { alpha = 1, beta = 2, gamma = 3 })).to.equal(TAGGED)
			expect(roundTrip({ "Loose" }, { [1] = 1, [4] = 4 })).to.equal(TAGGED)
			expect(roundTrip({ "Bools" }, { true, false, true })).to.equal(DENSE)
			expect(roundTrip({ "Level" }, 137)).to.equal(TAGGED)
		end)

		it("still degrades a single BAD VALUE to generic without abandoning the mask", function()
			-- R5, at the granularity that matters. An undeclared KEY costs the whole
			-- table its fast path; a value the schema cannot describe costs only that
			-- one field, because each present child still carries its own header.
			local value = fullGear()
			value.Head = "not-an-int"
			local bytes = encode({ "Gear" }, value)
			expect(modeOf(bytes)).to.equal(STATIC)
			-- ChildOrder is sorted, so Head is the 7th of nine: 1 header + 1 width +
			-- 2 mask bytes, then Amulet, Belt, Body, Boots, Cape and Gloves at two
			-- bytes each (header + one-byte int).
			expect(buffer.readu8(bytes, 4 + 6 * 2) % 4).to.equal(GENERIC)
			local back = decode({ "Gear" }, bytes)
			local ok, why = deepEquals(value, back)
			expect(ok).to.equal(true, why)
		end)
	end)

	describe("the presence bitmask", function()
		it("spends one bit per declared child and no ordinal at all", function()
			-- Written out byte for byte. Trio declares A, B, C (ChildOrder is sorted),
			-- and A and C are present.
			local bytes = encode({ "Trio" }, { A = true, C = true })
			expect(buffer.len(bytes)).to.equal(7)
			expect(buffer.readu8(bytes, 0)).to.equal(STATIC)
			expect(buffer.readu8(bytes, 1)).to.equal(3) -- the mask's declared width
			expect(buffer.readu8(bytes, 2)).to.equal(0x05) -- bit 0 = A, bit 2 = C
			expect(buffer.readu8(bytes, 3)).to.equal(TAGGED) -- A's header
			expect(buffer.readu8(bytes, 4)).to.equal(1) -- A = true
			expect(buffer.readu8(bytes, 5)).to.equal(TAGGED) -- C's header
			expect(buffer.readu8(bytes, 6)).to.equal(1) -- C = true
			-- The tagged encoding of two declared fields is 8 -- header, entry count,
			-- and then a folded key-tag byte, an ordinal varint and a payload each. It
			-- is pinned a few tests up, on the wide struct the mask deliberately loses
			-- to; the one byte between 7 and 8 here is the whole saving on a
			-- three-field struct, and it grows by one per field from there.
			expect(buffer.len(encode({ "Wide" }, { F03 = true, F17 = true }))).to.equal(8)
		end)

		it("carries no entry count, because the mask's popcount is the count", function()
			-- A second statement of the same number is a second thing to get wrong.
			-- Every byte after the mask is a child, so the length is fully determined:
			-- 1 header + 1 width + 1 mask + 3 * (1 header + 1 payload).
			expect(buffer.len(encode({ "Trio" }, { A = true, B = false, C = true }))).to.equal(9)
		end)

		it("restores an absent child as nil rather than as a default", function()
			local _mode, _len, back = roundTrip(
				{ "Wide" },
				{ F01 = true, F09 = true, F17 = true, F25 = true, F32 = true }
			)
			expect(keyCount(back)).to.equal(5)
			expect(back.F02).to.equal(nil)
			expect(back.F32).to.equal(true)
		end)

		it("reaches the last declared child, which is the bit a byte-count error loses", function()
			-- 32 children is exactly four mask bytes, so an off-by-one in the ceiling
			-- would still read four and only lose F32; 33 would expose the other half.
			local value = {}
			for i = 1, 32 do
				value[string.format("F%02d", i)] = (i == 32)
			end
			local mode, _len, back = roundTrip({ "Wide" }, value)
			expect(mode).to.equal(STATIC)
			expect(back.F32).to.equal(true)
		end)

		it("nests inside itself", function()
			local value = { Flag = true, Inner = { X = true, Z = true }, Tag = "hi" }
			local bytes = encode({ "Nest" }, value)
			expect(modeOf(bytes)).to.equal(STATIC)
			-- 1 header + 1 width + 1 mask, then Flag (header + 1 byte), then Inner's
			-- own header, which must be STATIC too.
			expect(buffer.readu8(bytes, 5) % 4).to.equal(STATIC)
			local back = decode({ "Nest" }, bytes)
			local ok, why = deepEquals(value, back)
			expect(ok).to.equal(true, why)
		end)
	end)

	describe("the refusals", function()
		it("refuses a mask whose declared width disagrees with the schema", function()
			-- #ChildOrder is folded into the template hash the Hello handshake
			-- compares, so this should be unreachable in a live session -- which is
			-- exactly why it must fail at the table that is wrong instead of reading
			-- the wrong number of mask bytes and mis-parsing everything after it.
			local bytes = encode({ "Trio" }, { A = true, C = true })
			refuses({ "Trio" }, patched(bytes, 1, 4), "static bitmask width disagrees")
			refuses({ "Trio" }, patched(bytes, 1, 2), "static bitmask width disagrees")
		end)

		it("refuses a mask with bits set past its declared width", function()
			-- Trio's mask has five bits of padding. The encoder writes them as zero;
			-- ignoring a set one would make the padding a place to smuggle a bit past
			-- a reader that checks the bits it does use.
			local bytes = encode({ "Trio" }, { A = true, C = true })
			refuses({ "Trio" }, patched(bytes, 2, 0x05 + 0x08), "bits set past its declared width")
			refuses({ "Trio" }, patched(bytes, 2, 0x80), "bits set past its declared width")
		end)

		it("refuses a mask that runs off the end of the buffer", function()
			local value = {}
			for i = 1, 32 do
				value[string.format("F%02d", i)] = true
			end
			local bytes = encode({ "Wide" }, value)
			-- header + width + two of the four mask bytes.
			refuses({ "Wide" }, truncated(bytes, 4), "static bitmask overruns buffer")
		end)

		it("refuses a static header on a node that declares no children", function()
			-- A DictOf node is a table with an AnyChild and no ChildOrder, so there is
			-- no ordinal space for a mask to index. Before the guard this indexed nil.
			refuses({ "Bag" }, fromBytes({ STATIC, 1, 0x01 }), "no declared children")
		end)

		it("refuses a table value mode on a scalar node", function()
			-- No encoder emits this, and none of the scalar readers looks at the mode,
			-- so without an explicit refusal the bit would be accepted in silence.
			refuses({ "Level" }, fromBytes({ STATIC, 0 }), "table value mode")
			refuses({ "Level" }, fromBytes({ DENSE, 0 }), "table value mode")
		end)

		it("still refuses a header with a reserved bit set", function()
			refuses({ "Trio" }, fromBytes({ STATIC + 0x10, 3, 0x01, 0, 1 }), "malformed value header")
		end)
	end)

	describe("the retention budget", function()
		local function retained(path, value)
			local bytes = encode(path, value)
			local reader = Wire.NewReader(bytes, 1e12)
			Wire.DecodeValue(reader, nodeFor(path))
			return 1e12 - reader.budget, buffer.len(bytes)
		end

		it("charges a static struct per present child, exactly", function()
			-- R2. Every declared child that arrives becomes a hash pair in the decoded
			-- table, and is charged as one -- the same HASH_BYTES the tagged path
			-- charges for the same pair. A faster encoding may not buy a cheaper
			-- charge.
			local value = {}
			for i = 1, 32 do
				value[string.format("F%02d", i)] = true
			end
			local cost = retained({ "Wide" }, value)
			expect(cost).to.equal(TABLE_BYTES + 32 * HASH_BYTES)

			-- And per PRESENT child, not per declared one: absent children retain
			-- nothing, so they are charged nothing.
			expect(retained({ "Wide" }, { F01 = true, F02 = true, F03 = true })).to.equal(TABLE_BYTES + 3 * HASH_BYTES)
		end)

		it("refuses a static struct BEFORE decoding any of its children", function()
			-- The mask states the whole entry list in one place, so the charge is
			-- levied once, up front, from the popcount -- not per child as the frame
			-- is walked. A budget one byte short of the total must stop the reader
			-- with its position still at the end of the mask.
			local value = {}
			for i = 1, 32 do
				value[string.format("F%02d", i)] = true
			end
			local bytes = encode({ "Wide" }, value)
			local reader = Wire.NewReader(bytes, TABLE_BYTES + 32 * HASH_BYTES - 1)
			local ok = pcall(Wire.DecodeValue, reader, nodeFor({ "Wide" }))
			expect(ok).to.equal(false)
			expect(reader.overBudget).to.equal(true)
			-- 1 value header + 1 width varint + 4 mask bytes, and not one byte more.
			expect(reader.pos).to.equal(6)
		end)

		it("charges a crafted mask for the children it CLAIMS, not the bytes behind them", function()
			-- A frame that sets every bit and then stops must be refused from the
			-- mask, before the missing payloads are discovered -- otherwise a
			-- three-byte frame buys 32 charges' worth of work before failing.
			local reader = Wire.NewReader(fromBytes({ STATIC, 32, 0xFF, 0xFF, 0xFF, 0xFF }), 1000)
			local ok = pcall(Wire.DecodeValue, reader, nodeFor({ "Wide" }))
			expect(ok).to.equal(false)
			expect(reader.overBudget).to.equal(true)
			expect(reader.pos).to.equal(6)
		end)

		it("the amplification each path can reach", function()
			-- THE NUMBER THE BUDGET COMMENT QUOTES, MEASURED RATHER THAN ASSERTED, so
			-- the prose above SLOT_BYTES in Wire.luau cannot drift away from the
			-- encoder it describes. The default budget is MaxInboundBytes * 16 and the
			-- 16 was derived when the tagged path's four-byte hash pair was the only
			-- encoding there was; three of these six rows are now well past it, and
			-- the two worst are the ones where a cheap-to-write nested table pulls
			-- TABLE_BYTES through two bytes.
			--
			-- Every byte of that IS charged, before the recursive decode -- the ratios
			-- are the honest cost of the shapes, not a hole. What they bound is how
			-- early a hostile frame gets refused, and the day the schema-typed decoder
			-- becomes reachable from untrusted input, this is the table the multiplier
			-- has to be re-derived from.
			local bools, nested, tables32, wide, bag = {}, {}, {}, {}, {}
			for i = 1, 2000 do
				bools[i] = true
				nested[i] = {}
			end
			for i = 1, 32 do
				tables32[string.format("T%02d", i)] = {}
				wide[string.format("F%02d", i)] = true
			end
			for i = 1, 200 do
				bag[string.format("%d", i)] = 1
			end
			local function ratio(path, value)
				local cost, size = retained(path, value)
				return string.format("%.1f", cost / size)
			end
			expect(ratio({ "Loose" }, bools)).to.equal("16.0") -- generic array of scalars
			expect(ratio({ "Bools" }, bools)).to.equal("16.0") -- dense array of scalars
			expect(ratio({ "Bag" }, bag)).to.equal("16.6") -- tagged, dynamic string keys
			expect(ratio({ "Wide" }, wide)).to.equal("30.2") -- static struct of scalars
			expect(ratio({ "Nested" }, nested)).to.equal("48.0") -- dense array of TABLES
			expect(ratio({ "Tables" }, tables32)).to.equal("59.4") -- static struct of TABLES
		end)
	end)

	describe("round-trips the awkward corpus", function()
		it("survives every shape", function()
			-- R6. Deliberately weighted towards the shapes the bitmask must NOT take,
			-- and towards the boundaries where it starts and stops winning.
			local corpus = {
				{ { "Trio" }, {} },
				{ { "Trio" }, { A = true } },
				{ { "Trio" }, { A = false, B = false, C = false } },
				{ { "Trio" }, { B = true, C = false } },
				{ { "Trio" }, withExtra({ A = true, B = true, C = true }, "D", 1) },
				{ { "Trio" }, withExtra({ A = true }, 7, "seven") },
				{ { "Gear" }, fullGear() },
				{ { "Gear" }, { Head = 1, Ring = 9 } },
				{ { "Gear" }, withExtra(fullGear(), "Trinket", { deep = { 1, 2, 3 } }) },
				{ { "Gear" }, withExtra({}, "OnlyStray", true) },
				{ { "Nest" }, { Flag = true, Inner = { X = true, Y = true, Z = true }, Tag = "t" } },
				{ { "Nest" }, { Inner = {} } },
				{ { "Nest" }, { Inner = withExtra({ X = true }, "W", 1), Tag = "" } },
				{ { "Roster", 1 }, { Name = "ada", Rank = 1, Active = true } },
				{ { "Roster", 1 }, { Name = "grace" } },
				{ { "Roster" }, { { Name = "a", Rank = 1, Active = false }, { Name = "b", Rank = 2, Active = true } } },
				{ { "Wide" }, { F01 = true, F32 = false } },
				{ { "Bag" }, { alpha = 1 } },
				{ { "Loose" }, { [1] = 1, [4] = 4, tail = "x" } },
				{ { "Loose" }, { A = false, B = false, C = false } },
				{ { "Bools" }, { true, false } },
				{ { "Level" }, 200 },
			}
			for _, case in corpus do
				roundTrip(case[1], case[2])
			end
		end)

		it("survives the same corpus through a whole ops frame", function()
			-- Through EncodeOpsFrame/DecodeOps rather than EncodeValue directly, so the
			-- op header, path codec and value codec are exercised together.
			local ops = {
				{ Kind = "Set", Path = { "Gear" }, Value = fullGear() },
				{ Kind = "Set", Path = { "Nest" }, Value = { Flag = true, Inner = { X = true }, Tag = "n" } },
				{ Kind = "Set", Path = { "Trio" }, Value = withExtra({ A = true, B = true, C = true }, "D", 1) },
				{ Kind = "Set", Path = { "Wide" }, Value = { F05 = true, F06 = true } },
				{ Kind = "Insert", Path = { "Roster" }, Value = { Name = "ada", Rank = 1, Active = true }, Index = 1 },
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

	describe("the bytes it saves", function()
		it("MEASURES the three shapes the change was justified against", function()
			-- Exact, not a band, for the reason OutboundFraming.spec gives about its
			-- own figure: a band lets the encoder drift while the numbers quoted for
			-- it stand still. The protocol-4 figures are in the comments; the deltas
			-- are what the bitmask is worth on these shapes and nothing more.
			local flags = {}
			for i = 1, 32 do
				flags[string.format("F%02d", i)] = (i % 3 == 0)
			end
			local function record(i)
				return {
					Id = `item_{i}`,
					Count = (i % 99) + 1,
					Slot = i % 200,
					Rarity = ({ "Common", "Rare", "Epic" })[(i % 3) + 1],
					Bound = i % 2 == 0,
					Level = (i % 100) + 1,
					Durability = i % 101,
					Locked = i % 5 == 0,
					Favorite = i % 7 == 0,
					Acquired = 1700000000 + i,
					Seed = i * 7919,
				}
			end
			local inv40, inv1000 = {}, {}
			for i = 1, 40 do
				inv40[i] = record(i)
			end
			for i = 1, 1000 do
				inv1000[i] = record(i)
			end

			-- A 32-field struct with every field declared and present: 98 at
			-- protocol 4, and 136 before the value header was folded at protocol 4.
			expect(buffer.len(encode({ "Wide" }, flags))).to.equal(70)
			-- One 11-field inventory record: 50 at protocol 4. Eleven ordinals and an
			-- entry count out, a width varint and two mask bytes in.
			expect(buffer.len(encode({ "Inventory", 1 }, record(1)))).to.equal(41)
			-- Forty of them: 2071 at protocol 4.
			expect(buffer.len(encode({ "Inventory" }, inv40))).to.equal(1711)
			-- A thousand: 53630 at protocol 4.
			expect(buffer.len(encode({ "Inventory" }, inv1000))).to.equal(44630)
		end)
	end)
end
