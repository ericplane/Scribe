--!nonstrict
-- Protocol 6: declared narrowing on Scribe.Number. An undeclared Number is an f64
-- and stays one; `Precision` opts a field into IEEE binary32 or into a fixed-point
-- grid over its declared bounds.
--
-- THE FALLBACK IS TESTED FIRST, AND THAT ORDERING IS THE POINT. A narrowed float
-- is the one fast path in this codec that is ALLOWED to lose information, which
-- makes "did it lose the right amount, and only where it said it would" the whole
-- correctness question. A value the narrow form cannot carry -- NaN, an infinity,
-- something outside the grid, something binary32 would round to infinity or flush
-- to zero -- must leave by the generic path as an exact f64, and the generic MODE
-- BIT has to be observably set in the bytes. Asserting only that such a value
-- round-trips would pass against an encoder that narrowed it and got lucky on the
-- particular constant the test happened to pick.
return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Wire = require(ScribeRoot.Internal.Wire)
	local Template = require(ScribeRoot.Internal.Template)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local deepEquals = require(Root.Test.Helpers.DeepEquals)

	-- Restated rather than imported, for the reason WireDense.spec gives: a test
	-- that read the encoder's own constants could not catch the encoder redefining
	-- them.
	local VH_GENERIC = 0x01

	-- The binary32 boundaries, written out here for the same reason. F32_MAX is the
	-- largest finite binary32; F32_MIN_NORMAL is the smallest magnitude it holds
	-- without losing mantissa bits. F32_REL_ERROR is the relative error of
	-- round-to-nearest into a 24-bit significand, and is what the doc-comment
	-- promises.
	local F32_MAX = 3.4028234663852886e38
	local F32_MIN_NORMAL = 1.1754943508222875e-38
	local F32_REL_ERROR = 2 ^ -24

	local template = {
		-- The control, and the thing that must never move: no Precision at all.
		Plain = Scribe.Number(0),
		-- Bounds WITHOUT Precision. This is the declaration that existed before
		-- narrowing did, and it has to keep meaning exactly what it meant.
		Bounded = Scribe.Number(0, { Min = -1000, Max = 1000 }),

		Single = Scribe.Number(0, { Precision = "f32" }),
		SingleBounded = Scribe.Number(0, { Min = -2048, Max = 2048, Precision = "f32" }),

		-- steps = 255, the widest grid that still indexes in one byte, and 256, one
		-- past it. Then the u16/u32 boundary from both sides.
		Byte = Scribe.Number(0, { Min = 0, Max = 255, Precision = 1 }),
		Short = Scribe.Number(0, { Min = 0, Max = 256, Precision = 1 }),
		ShortMax = Scribe.Number(0, { Min = 0, Max = 65535, Precision = 1 }),
		Word = Scribe.Number(0, { Min = 0, Max = 65536, Precision = 1 }),

		-- The shapes a game actually declares: a percentage, a fraction, and a
		-- signed range whose grid straddles zero.
		Health = Scribe.Number(100, { Min = 0, Max = 100, Precision = 0.5 }),
		Ratio = Scribe.Number(0, { Min = 0, Max = 1, Precision = 0.01 }),
		Offset = Scribe.Number(0, { Min = -128, Max = 127, Precision = 0.25 }),

		-- Narrowed floats inside containers, so the ELEMENT path is covered too. An
		-- element node is built by the same code but reached through ChildSchema,
		-- and a narrowing that only worked on static fields would pass every test
		-- above this line.
		Samples = Scribe.ArrayOf(Scribe.Number(0, { Min = 0, Max = 1, Precision = 0.01 })),
		Points = Scribe.ArrayOf(Scribe.Number(0, { Precision = "f32" })),
		Vectors = Scribe.ArrayOf({
			X = Scribe.Number(0, { Min = -1024, Max = 1024, Precision = "f32" }),
			Y = Scribe.Number(0, { Min = -1024, Max = 1024, Precision = "f32" }),
			Z = Scribe.Number(0, { Min = -1024, Max = 1024, Precision = "f32" }),
		}),
		Loose = {},
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

	--- Round-trip, handing back the header byte and the encoded length alongside
	--- the value, so a caller can pin the ENCODING the writer chose and not merely
	--- the number that survived it.
	local function trip(path, value)
		local bytes = encode(path, value)
		return decode(path, bytes), buffer.readu8(bytes, 0), buffer.len(bytes)
	end

	local function isGeneric(header)
		return header % 4 == VH_GENERIC
	end

	local function compiles(field)
		return function()
			TestCtx.make({ Template = { N = field } }).Cleanup()
		end
	end

	--- Assert that declaring `field` is refused, AND refused for the stated reason.
	---
	--- `.to.throw()` alone is not enough here, and MUTATION TESTING is what showed
	--- it. Delete the "requires both Min and Max" check and the very next line
	--- compares two nils, so the template still throws and a bare throw-assertion
	--- still passes -- while the developer now gets "attempt to compare nil" where a
	--- sentence naming the fix used to be. Two of the tests below were passing on
	--- exactly that accident. Pinning the message is what separates "refused
	--- deliberately" from "crashed on the way past the missing refusal".
	local function refuses(field, needle)
		local ok, err = pcall(function()
			TestCtx.make({ Template = { N = field } }).Cleanup()
		end)
		if ok then
			error(`expected a refusal naming "{needle}", but the template compiled`, 2)
		end
		local message = tostring(err)
		if not string.find(message, needle, 1, true) then
			error(`expected a refusal naming "{needle}", got: {message}`, 2)
		end
	end

	----------------------------------------------------------------------------
	-- R1. THE FALLBACK, FIRST.
	----------------------------------------------------------------------------

	describe("the fallback", function()
		-- Every one of these must (a) take the generic path, provably, and (b) come
		-- back BIT-FOR-BIT. The second half is what makes the first half worth
		-- having: degrading onto a path that was also lossy would buy nothing.
		local DEGRADES = {
			{ path = "Single", name = "NaN", value = 0 / 0 },
			{ path = "Single", name = "positive infinity", value = math.huge },
			{ path = "Single", name = "negative infinity", value = -math.huge },
			-- Past the binary32 range: writef32 stores infinity here, turning a large
			-- finite number into one that is not a number at all.
			{ path = "Single", name = "a value past the binary32 range", value = 1e39 },
			{ path = "Single", name = "a negative value past the binary32 range", value = -1e39 },
			-- Below the smallest binary32 normal: writef32 stores a subnormal or
			-- zero, and the relative error becomes 5e-6 or 1.0 rather than 2^-24.
			{ path = "Single", name = "an f32 subnormal", value = 1e-40 },
			{ path = "Single", name = "a negative f32 subnormal", value = -1e-40 },
			-- The smallest positive double there is. binary32 flushes it to zero.
			{ path = "Single", name = "the smallest f64 subnormal", value = 5e-324 },
			-- The nearest miss there is: one part in 2^30 below the smallest normal.
			{
				path = "Single",
				name = "just below the smallest f32 normal",
				value = F32_MIN_NORMAL * (1 - 2 ^ -30),
			},

			{ path = "Health", name = "NaN on a grid", value = 0 / 0 },
			{ path = "Health", name = "infinity on a grid", value = math.huge },
			{ path = "Health", name = "negative infinity on a grid", value = -math.huge },
			-- Off the grid entirely. There is no index for these, and clamping them
			-- to an end of the range would silently rewrite the value.
			{ path = "Health", name = "a value below Min", value = -0.5 },
			{ path = "Health", name = "a value above Max", value = 100.5 },
			{ path = "Health", name = "a value far above Max", value = 1e9 },
			{ path = "Offset", name = "a value below a signed Min", value = -128.25 },
			{ path = "Offset", name = "a value above a signed Max", value = 127.25 },
		}

		for _, case in DEGRADES do
			it(`degrades {case.name} on {case.path} to an exact f64`, function()
				local back, header, len = trip({ case.path }, case.value)
				-- R5, AND THE ASSERTION THAT MATTERS. The value-mode byte is what lets
				-- a value the narrow form cannot describe leave by the generic path;
				-- without this line the test would pass against an encoder that
				-- narrowed the value and produced a plausible-looking number.
				expect(isGeneric(header)).to.equal(true)
				-- 1 value header + 1 generic type tag + 8 bytes of f64, and not one
				-- byte fewer -- a "degradation" that still wrote four bytes would be
				-- the corruption this whole block exists to catch.
				expect(len).to.equal(10)
				if case.value ~= case.value then
					expect(back ~= back).to.equal(true)
				else
					expect(back).to.equal(case.value)
				end
			end)
		end

		it("degrades a non-number written to a narrowed field", function()
			-- Narrowing did not change what a schema node accepts: a wrong-typed value
			-- still leaves by the generic path rather than reaching arithmetic that
			-- would produce NaN and write it as a grid index.
			for _, value in { "not-a-number", true, { 1, 2, 3 } } do
				local back, header = trip({ "Health" }, value)
				expect(isGeneric(header)).to.equal(true)
				expect(deepEquals(value, back)).to.equal(true)
			end
		end)

		it("degrades one element without dropping its array off the dense path", function()
			-- The degradation is PER VALUE. One unrepresentable sample must not push
			-- its whole array back to the tagged encoding, and must not disturb the
			-- samples either side of it.
			local value = { 0.25, math.huge, 0.75 }
			local bytes = encode({ "Samples" }, value)
			-- Mode 2 is dense: the array's shape is unaffected by one element's mode.
			expect(buffer.readu8(bytes, 0) % 4).to.equal(2)
			local back = decode({ "Samples" }, bytes)
			expect(back[1]).to.equal(0.25)
			expect(back[2]).to.equal(math.huge)
			expect(back[3]).to.equal(0.75)
		end)
	end)

	----------------------------------------------------------------------------
	-- THE DEFAULT.
	----------------------------------------------------------------------------

	describe("the default is untouched", function()
		it("keeps an undeclared Scribe.Number on f64, byte for byte", function()
			-- 1 header + 8. If this ever reads 5, narrowing stopped being opt-in.
			local _back, header, len = trip({ "Plain" }, 1 / 3)
			expect(len).to.equal(9)
			expect(header % 4).to.equal(0)
		end)

		it("keeps a Number declaring Min and Max on f64", function()
			-- THE REGRESSION THIS FIELD IS SHAPED TO AVOID. Bounds have been
			-- declarable on Scribe.Number since long before Precision existed, and
			-- narrowing on their presence alone would silently cost every existing
			-- such field its precision on the next deploy -- no error, no log line,
			-- just a mirror that no longer matches the server. Min/Max select nothing.
			local _back, _header, len = trip({ "Bounded" }, 1 / 3)
			expect(len).to.equal(9)
			expect(trip({ "Bounded" }, 1 / 3)).to.equal(1 / 3)
		end)

		it("round-trips every awkward double exactly on an undeclared Number", function()
			for _, path in { "Plain", "Bounded" } do
				for _, value in { 0, 1 / 3, 5e-324, 1e308, -1e308, math.pi, math.huge, -math.huge } do
					local back, header = trip({ path }, value)
					-- Schema-typed, not degraded: the f64 path takes everything.
					expect(isGeneric(header)).to.equal(false)
					expect(back).to.equal(value)
				end
				local nan = trip({ path }, 0 / 0)
				expect(nan ~= nan).to.equal(true)
			end
		end)

		it("keeps negative zero negative on the f64 path", function()
			-- -0 == 0 in Lua, so equality cannot see this; 1/-0 is -inf and 1/0 is inf.
			expect(1 / trip({ "Plain" }, -0)).to.equal(-math.huge)
		end)
	end)

	----------------------------------------------------------------------------
	-- THE WIDTHS.
	----------------------------------------------------------------------------

	describe("the widths", function()
		it("spends four bytes on an f32 field", function()
			local _back, header, len = trip({ "Single" }, 1.5)
			expect(len).to.equal(5) -- 1 header + 4
			expect(isGeneric(header)).to.equal(false)
		end)

		it("picks the narrowest index width the step count fits", function()
			-- The boundaries, from both sides. The index runs 0..steps INCLUSIVE, so
			-- 255 steps is 256 indices and still one byte.
			local WIDTHS = {
				{ path = "Byte", steps = 255, len = 2 }, -- 1 header + u8
				{ path = "Short", steps = 256, len = 3 }, -- 1 header + u16
				{ path = "ShortMax", steps = 65535, len = 3 },
				{ path = "Word", steps = 65536, len = 5 }, -- 1 header + u32
			}
			for _, case in WIDTHS do
				local node = nodeFor({ case.path })
				expect(Template.QuantSteps(node.Min, node.Max, node.Precision)).to.equal(case.steps)
				-- Both ends of the grid, because the TOP index is the one the width has
				-- to hold: a width chosen one too narrow would wrap Max round to Min.
				local _b1, _h1, len1 = trip({ case.path }, node.Min)
				local _b2, _h2, len2 = trip({ case.path }, node.Max)
				expect(len1).to.equal(case.len)
				expect(len2).to.equal(case.len)
				expect(trip({ case.path }, node.Max)).to.equal(node.Max)
			end
		end)

		it("narrows an element node, not just a static field", function()
			-- Samples is 0..1 by 0.01: 100 steps, so one byte an element. A dense
			-- array of eight is 1 outer header + 1 count + 8 * (1 header + 1 index).
			local bytes = encode({ "Samples" }, { 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 1 })
			expect(buffer.len(bytes)).to.equal(1 + 1 + 8 * 2)
		end)

		it("narrows a child inside a static struct", function()
			-- Three f32 children under the presence bitmask: 1 header + 1 width varint
			-- + 1 mask byte + 3 * (1 header + 4).
			local bytes = encode({ "Vectors", 1 }, { X = 1.5, Y = -2.25, Z = 1024 })
			expect(buffer.readu8(bytes, 0) % 4).to.equal(3) -- static
			expect(buffer.len(bytes)).to.equal(1 + 1 + 1 + 3 * 5)
		end)
	end)

	----------------------------------------------------------------------------
	-- THE GUARANTEE. Measured over a sweep rather than asserted at a few points.
	----------------------------------------------------------------------------

	describe("the precision guarantee", function()
		it("holds an f32 field to a relative error of 2^-24", function()
			-- THE NUMBER THE DOC-COMMENT PROMISES, MEASURED. A sweep across the whole
			-- binary32 exponent range, not a handful of round decimals -- 0.5 and 0.25
			-- are exact in binary32 and would prove nothing at all. The second
			-- mantissa is 1 + 2^-24, exactly halfway between two binary32 neighbours,
			-- which is where the worst case lives.
			local worst, checked = 0, 0
			for exponent = -125, 127 do
				for _, mantissa in { 1.0, 1 + 2 ^ -24, 1.3333333333333333, 1.618033988749895, 1.99999 } do
					for _, sign in { 1, -1 } do
						local value = sign * mantissa * 2 ^ exponent
						local back, header = trip({ "Single" }, value)
						-- Every one of these is inside the range, so none may degrade --
						-- a fast path that quietly stopped narrowing would otherwise pass
						-- the error bound below trivially.
						expect(isGeneric(header)).to.equal(false)
						worst = math.max(worst, math.abs(back - value) / math.abs(value))
						checked += 1
					end
				end
			end
			expect(checked).to.equal(253 * 5 * 2)
			-- Reported as well as asserted, so a future loosening names the number it
			-- actually reached instead of just failing.
			if worst > F32_REL_ERROR then
				error(`f32 relative error reached {worst}, past the promised {F32_REL_ERROR}`, 0)
			end
			-- And the bound is TIGHT, not merely true. Measured at 0.9999999 of
			-- 2^-24: the sweep really does reach the worst case, so the promise is
			-- the smallest one that holds rather than a comfortable overstatement.
			expect(worst > F32_REL_ERROR * 0.99).to.equal(true)
		end)

		it("holds a fixed-point field to half its Precision", function()
			local CASES = {
				{ path = "Health", min = 0, max = 100, precision = 0.5 },
				{ path = "Ratio", min = 0, max = 1, precision = 0.01 },
				{ path = "Offset", min = -128, max = 127, precision = 0.25 },
			}
			for _, case in CASES do
				local worst = 0
				-- 997 samples across the range. The count is deliberately coprime to
				-- every grid here, so the sweep lands BETWEEN grid points rather than
				-- on them -- which is the only place the error lives.
				for i = 0, 996 do
					local value = case.min + (case.max - case.min) * (i / 996)
					local back, header = trip({ case.path }, value)
					expect(isGeneric(header)).to.equal(false)
					worst = math.max(worst, math.abs(back - value))
				end
				local limit = case.precision / 2
				if worst > limit then
					error(`{case.path} reached an absolute error of {worst}, past the promised {limit}`, 0)
				end
				-- Tight, for the same reason as above: measured at 0.99 of the limit
				-- on all three, so half a Precision is the honest figure and not a
				-- number picked with room to spare.
				expect(worst > limit * 0.9).to.equal(true)
			end
		end)

		it("is unbiased, so a value does not drift under repeated round-trips", function()
			-- Round-to-nearest rather than truncation. Under truncation a value would
			-- fall by up to a full Precision on the first trip; what catches the
			-- difference is the SECOND trip landing exactly where the first one did,
			-- which truncation would not do for a value already on a grid point.
			for _, value in { 0.334, 12.7, 99.6, 50.25 } do
				local once = trip({ "Health" }, value)
				local twice = trip({ "Health" }, once)
				expect(twice).to.equal(once)
			end
			-- And it does not bias downward: across a sweep the roundings go both
			-- ways, which truncation would make impossible.
			local up, down = 0, 0
			for i = 0, 200 do
				local value = i * 0.4973
				if value <= 100 then
					local back = trip({ "Health" }, value)
					if back > value then
						up += 1
					elseif back < value then
						down += 1
					end
				end
			end
			expect(up > 0).to.equal(true)
			expect(down > 0).to.equal(true)
		end)
	end)

	----------------------------------------------------------------------------
	-- THE BOUNDARIES, each one saying what it does rather than assuming.
	----------------------------------------------------------------------------

	describe("the boundaries", function()
		it("returns Min and Max exactly", function()
			-- Both bounds are grid points by construction -- Min is index 0, and every
			-- range here divides by its Precision -- so these are not approximations.
			for _, path in { "Health", "Ratio", "Offset", "Byte", "Short", "ShortMax", "Word" } do
				local node = nodeFor({ path })
				expect(trip({ path }, node.Min)).to.equal(node.Min)
				expect(trip({ path }, node.Max)).to.equal(node.Max)
			end
		end)

		it("returns zero exactly from a grid that contains it", function()
			-- Offset's grid runs from -128 by 0.25, so zero is index 512 and lands
			-- exactly rather than near.
			expect(trip({ "Offset" }, 0)).to.equal(0)
			expect(trip({ "Health" }, 0)).to.equal(0)
			expect(trip({ "Ratio" }, 0)).to.equal(0)
			-- Zero is exact in binary32, sign included.
			expect(trip({ "Single" }, 0)).to.equal(0)
			expect(1 / trip({ "Single" }, -0)).to.equal(-math.huge)
		end)

		it("carries negatives on both narrow forms", function()
			expect(trip({ "Offset" }, -64)).to.equal(-64)
			expect(trip({ "Offset" }, -127.75)).to.equal(-127.75)
			expect(trip({ "Single" }, -1.5)).to.equal(-1.5)
			expect(trip({ "Single" }, -F32_MAX)).to.equal(-F32_MAX)
			expect(trip({ "SingleBounded" }, -2048)).to.equal(-2048)
		end)

		it("carries the binary32 extremes exactly, right up to the fallback", function()
			-- F32_MAX and F32_MIN_NORMAL are both representable, so they survive
			-- untouched. They are the last values before the fallback takes over, and
			-- the DEGRADES table above pins the first values after it.
			local big, bigHeader = trip({ "Single" }, F32_MAX)
			expect(isGeneric(bigHeader)).to.equal(false)
			expect(big).to.equal(F32_MAX)
			local small, smallHeader = trip({ "Single" }, F32_MIN_NORMAL)
			expect(isGeneric(smallHeader)).to.equal(false)
			expect(small).to.equal(F32_MIN_NORMAL)
		end)

		it("says what NaN and the infinities do, on every narrowed form", function()
			-- Stated once because the answer is the same for all of them and the
			-- doc-comment promises it that way: they are never narrowed, so they are
			-- never altered. binary32 could in fact carry all three; refusing them
			-- anyway keeps ONE statement true of every narrowed float rather than two
			-- that differ by width.
			for _, path in { "Single", "SingleBounded", "Health", "Ratio", "Offset", "Byte", "Word" } do
				local nan, nanHeader = trip({ path }, 0 / 0)
				expect(isGeneric(nanHeader)).to.equal(true)
				expect(nan ~= nan).to.equal(true)
				expect(trip({ path }, math.huge)).to.equal(math.huge)
				expect(trip({ path }, -math.huge)).to.equal(-math.huge)
			end
		end)

		it("says what subnormals do", function()
			-- An f64 subnormal is below every binary32 normal, so it degrades and
			-- comes back EXACT. It never flushes to zero, which is precisely what an
			-- unguarded writef32 would have done to it -- 5e-324 becomes 0.0.
			for _, value in { 5e-324, 1e-320, 2.2250738585072014e-309 } do
				local back, header = trip({ "Single" }, value)
				expect(isGeneric(header)).to.equal(true)
				expect(back).to.equal(value)
				expect(back > 0).to.equal(true)
			end
			-- On a fixed-point field a subnormal is just a value very near zero, and
			-- 0..1 by 0.01 contains it: it quantizes to index 0 and comes back as
			-- exactly zero -- well within the promised 0.005, and NOT degraded.
			local q, qHeader = trip({ "Ratio" }, 5e-324)
			expect(isGeneric(qHeader)).to.equal(false)
			expect(q).to.equal(0)
		end)
	end)

	----------------------------------------------------------------------------
	-- R2. THE RETENTION BUDGET.
	----------------------------------------------------------------------------

	describe("the retention budget", function()
		local SLOT_BYTES, TABLE_BYTES = 32, 64

		local function retained(path, value)
			local bytes = encode(path, value)
			local reader = Wire.NewReader(bytes, 1e12)
			Wire.DecodeValue(reader, nodeFor(path))
			return 1e12 - reader.budget, buffer.len(bytes)
		end

		it("charges a narrowed array per slot, exactly as the f64 one was charged", function()
			-- R2. A narrower payload may not buy a cheaper charge: the decoded slot
			-- retains the same 32 bytes whether the number arrived in eight bytes or
			-- in one, and the charge is levied from the COUNT, before any of them are
			-- read.
			local samples = {}
			for i = 1, 500 do
				samples[i] = (i % 101) / 100
			end
			expect(retained({ "Samples" }, samples)).to.equal(TABLE_BYTES + 500 * SLOT_BYTES)
		end)

		it("cannot push any path past the amplification the budget already allowed", function()
			-- THE QUESTION NARROWING ACTUALLY RAISES, and the reason R2 names it.
			-- Shrinking a value's payload raises how many values a frame of a given
			-- size can declare, so retained-bytes-per-input-byte rises with it -- and
			-- the block above SLOT_BYTES in Wire.luau quotes those ratios as the
			-- ceiling the budget multiplier was derived from.
			--
			-- A one-byte grid index is the narrowest a float can get, giving a
			-- two-byte dense element: one header, one index. That is the SAME two
			-- bytes a boolean element already costs, which is where WireBitmask.spec's
			-- 16.0 comes from. So narrowing reaches the existing floor and does not go
			-- under it: there is no charge to move, and this is the test that says so
			-- rather than a handoff note claiming it.
			local samples, bools = {}, {}
			for i = 1, 2000 do
				samples[i] = (i % 101) / 100
				bools[i] = true
			end
			local function ratio(path, value)
				local cost, size = retained(path, value)
				return string.format("%.1f", cost / size)
			end
			expect(ratio({ "Samples" }, samples)).to.equal("16.0")
			expect(ratio({ "Loose" }, bools)).to.equal("16.0")

			-- An f32 element is five bytes, so it is CHEAPER per byte than the f64 it
			-- replaced -- narrowing moves this ratio the safe way, and only the
			-- one-byte grid reaches the floor at all.
			local points = {}
			for i = 1, 2000 do
				points[i] = i * 1.5
			end
			expect(ratio({ "Points" }, points)).to.equal("6.4")
		end)

		it("refuses a long narrowed array partway, before decoding the rest of it", function()
			-- The per-slot charge still runs ahead of the payloads, so a budget that
			-- runs out stops the reader early rather than after materialising two
			-- thousand numbers.
			local samples = {}
			for i = 1, 2000 do
				samples[i] = 0.5
			end
			local bytes = encode({ "Samples" }, samples)
			local reader = Wire.NewReader(bytes, TABLE_BYTES + 100 * SLOT_BYTES)
			expect(pcall(Wire.DecodeValue, reader, nodeFor({ "Samples" }))).to.equal(false)
			expect(reader.overBudget).to.equal(true)
			expect(reader.pos < buffer.len(bytes)).to.equal(true)
		end)
	end)

	----------------------------------------------------------------------------
	-- R6. ROUND-TRIP EVERYTHING.
	----------------------------------------------------------------------------

	describe("round-trips the awkward corpus", function()
		it("survives every shape, through a whole ops frame", function()
			-- Through EncodeOpsFrame/DecodeOps rather than EncodeValue, because that
			-- is the path the client actually runs, and it is where a width the two
			-- ends disagreed about would desync every op AFTER the offending one --
			-- which a single-value round-trip cannot see at all.
			--
			-- Each case carries its own check, rather than one rule inferred from the
			-- node: an inferred rule would be the same code the encoder uses to pick a
			-- width, so a wrong width would be checked against itself.
			local function near(expected, tolerance)
				return function(got)
					expect(math.abs(got - expected) <= tolerance).to.equal(true)
				end
			end
			local function exactly(expected)
				return function(got)
					expect(got).to.equal(expected)
				end
			end
			local ops = {
				{ Kind = "Set", Path = { "Plain" }, Value = 1 / 3, Check = exactly(1 / 3) },
				{ Kind = "Set", Path = { "Bounded" }, Value = -999.99999, Check = exactly(-999.99999) },
				{ Kind = "Set", Path = { "Single" }, Value = 1234.5, Check = exactly(1234.5) },
				{ Kind = "Set", Path = { "Single" }, Value = 0.1, Check = near(0.1, 0.1 * F32_REL_ERROR) },
				{
					Kind = "Set",
					Path = { "Single" },
					Value = 0 / 0,
					Check = function(got)
						expect(got ~= got).to.equal(true)
					end,
				},
				{ Kind = "Set", Path = { "Single" }, Value = 1e39, Check = exactly(1e39) },
				{ Kind = "Set", Path = { "Single" }, Value = 5e-324, Check = exactly(5e-324) },
				{ Kind = "Set", Path = { "SingleBounded" }, Value = -2048, Check = exactly(-2048) },
				{ Kind = "Set", Path = { "Health" }, Value = 37.5, Check = exactly(37.5) },
				{ Kind = "Set", Path = { "Health" }, Value = 37.3, Check = near(37.3, 0.25) },
				{ Kind = "Set", Path = { "Health" }, Value = 1e9, Check = exactly(1e9) },
				{ Kind = "Set", Path = { "Ratio" }, Value = 0.333, Check = near(0.333, 0.005) },
				{ Kind = "Set", Path = { "Offset" }, Value = -0.25, Check = exactly(-0.25) },
				{ Kind = "Set", Path = { "Byte" }, Value = 255, Check = exactly(255) },
				{ Kind = "Set", Path = { "Word" }, Value = 65536, Check = exactly(65536) },
				{
					Kind = "Set",
					Path = { "Samples" },
					Value = { 0, 0.5, 1 },
					Check = function(got)
						expect(deepEquals({ 0, 0.5, 1 }, got)).to.equal(true)
					end,
				},
				{
					-- Sparse: the container fallback, carrying narrowed elements.
					Kind = "Set",
					Path = { "Samples" },
					Value = { [1] = 0.25, [4] = 0.75 },
					Check = function(got)
						expect(got[1]).to.equal(0.25)
						expect(got[2]).to.equal(nil)
						expect(got[3]).to.equal(nil)
						expect(got[4]).to.equal(0.75)
					end,
				},
				{
					-- An f32 array mixing carriable and degrading elements.
					Kind = "Set",
					Path = { "Points" },
					Value = { 1.5, math.huge, -1e39, 5e-324 },
					Check = function(got)
						expect(got[1]).to.equal(1.5)
						expect(got[2]).to.equal(math.huge)
						expect(got[3]).to.equal(-1e39)
						expect(got[4]).to.equal(5e-324)
					end,
				},
				{
					Kind = "Set",
					Path = { "Vectors" },
					Value = { { X = 1.5, Y = -2.25, Z = 1024 } },
					Check = function(got)
						expect(got[1].X).to.equal(1.5)
						expect(got[1].Y).to.equal(-2.25)
						expect(got[1].Z).to.equal(1024)
					end,
				},
				{
					-- A struct carrying only SOME of its narrowed children, so the
					-- static bitmask path holds narrowed values too.
					Kind = "Set",
					Path = { "Vectors", 1 },
					Value = { X = 0.125 },
					Check = function(got)
						expect(got.X).to.equal(0.125)
						expect(got.Y).to.equal(nil)
					end,
				},
				{
					-- Undeclared container: no narrowing anywhere below it, so every one
					-- of these is exact even though two of them degrade on a narrowed
					-- field elsewhere in this same frame.
					Kind = "Set",
					Path = { "Loose" },
					Value = { 1 / 3, 5e-324, math.huge },
					Check = function(got)
						expect(got[1]).to.equal(1 / 3)
						expect(got[2]).to.equal(5e-324)
						expect(got[3]).to.equal(math.huge)
					end,
				},
				{ Kind = "Insert", Path = { "Samples" }, Value = 0.66, Index = 1, Check = near(0.66, 0.005) },
			}
			local frame = Wire.EncodeOpsFrame(Wire.Frames.Diff, compiled, ops)
			local reader = Wire.NewReader(frame)
			expect(Wire.RU8(reader)).to.equal(Wire.Frames.Diff)
			local back = Wire.DecodeOps(reader, compiled)
			expect(#back).to.equal(#ops)
			-- NOTHING LEFT OVER. A width the two ends disagreed about would leave the
			-- reader short of the end or past it, and this is the assertion that sees
			-- it -- the per-op checks below would mostly still pass on a frame that
			-- had slipped by four bytes somewhere in the middle.
			expect(Wire.Remaining(reader)).to.equal(0)

			for i, op in ops do
				local got = back[i]
				expect(got.Kind).to.equal(op.Kind)
				expect(table.concat(got.Path, ".")).to.equal(table.concat(op.Path, "."))
				op.Check(got.Value)
			end
		end)
	end)

	----------------------------------------------------------------------------
	-- WHAT IT ACTUALLY SAVES.
	----------------------------------------------------------------------------

	describe("the bytes it saves", function()
		it("MEASURES a float-heavy corpus against the same corpus undeclared", function()
			-- THE SAME DATA, THE SAME SHAPES, ONE DIFFERENCE: whether the template
			-- says Precision. Comparing two templates rather than two corpora is what
			-- makes the number attributable -- a corpus-to-corpus comparison would be
			-- measuring the corpus.
			--
			-- The prediction this change was justified against was "4 wasted bytes per
			-- float field wherever f32 would do". Measured, that is exactly right for
			-- f32 and an understatement for the fixed-point path, which saves 7.
			local function build(narrow)
				local function num(min, max, precision)
					if narrow then
						return Scribe.Number(min, { Min = min, Max = max, Precision = precision })
					end
					return Scribe.Number(min, { Min = min, Max = max })
				end
				return Template.Compile({
					Transforms = Scribe.ArrayOf({
						X = num(-1024, 1024, "f32"),
						Y = num(-1024, 1024, "f32"),
						Z = num(-1024, 1024, "f32"),
					}),
					Stats = {
						Accuracy = num(0, 100, 0.5),
						Aggression = num(0, 100, 0.5),
						Charisma = num(0, 100, 0.5),
						Defence = num(0, 100, 0.5),
						Endurance = num(0, 100, 0.5),
						Luck = num(0, 100, 0.5),
						Speed = num(0, 100, 0.5),
						Stealth = num(0, 100, 0.5),
					},
					Samples = Scribe.ArrayOf(num(0, 1, 0.01)),
					Velocity = num(-1000, 1000, "f32"),
				}, {})
			end

			local transforms, samples = {}, {}
			for i = 1, 64 do
				transforms[i] = { X = i * 3.25, Y = -i * 1.5, Z = i * 0.125 }
			end
			for i = 1, 128 do
				samples[i] = (i % 101) / 100
			end
			local stats = {
				Accuracy = 72.5,
				Aggression = 41,
				Charisma = 88.5,
				Defence = 60,
				Endurance = 55.5,
				Luck = 12,
				Speed = 93.5,
				Stealth = 37,
			}
			local ops = {
				{ Kind = "Set", Path = { "Transforms" }, Value = transforms },
				{ Kind = "Set", Path = { "Stats" }, Value = stats },
				{ Kind = "Set", Path = { "Samples" }, Value = samples },
				{ Kind = "Set", Path = { "Velocity" }, Value = 12.5 },
			}
			local wide, narrow = build(false), build(true)
			local function sizeOf(schema, subset)
				return buffer.len(Wire.EncodeOpsFrame(Wire.Frames.Diff, schema, subset))
			end
			local function measure(subset)
				return sizeOf(wide, subset), sizeOf(narrow, subset)
			end

			-- 192 f32 fields, 4 bytes saved each.
			local wideBytes, narrowBytes = measure({ ops[1] })
			expect(wideBytes).to.equal(1928)
			expect(narrowBytes).to.equal(1160)
			expect(wideBytes - narrowBytes).to.equal(192 * 4)

			-- 8 one-byte grid fields, 7 bytes saved each.
			wideBytes, narrowBytes = measure({ ops[2] })
			expect(wideBytes).to.equal(81)
			expect(narrowBytes).to.equal(25)
			expect(wideBytes - narrowBytes).to.equal(8 * 7)

			-- 128 one-byte grid elements, same 7 bytes each.
			wideBytes, narrowBytes = measure({ ops[3] })
			expect(wideBytes).to.equal(1161)
			expect(narrowBytes).to.equal(265)
			expect(wideBytes - narrowBytes).to.equal(128 * 7)

			-- A single f32: the 4 bytes the prediction named, on its own.
			wideBytes, narrowBytes = measure({ ops[4] })
			expect(wideBytes).to.equal(15)
			expect(narrowBytes).to.equal(11)

			-- The whole frame: 3176 -> 1452, 54.3% off a float-heavy diff. Pinned so
			-- the figure quoted in the guide cannot drift away from the encoder.
			wideBytes, narrowBytes = measure(ops)
			expect(wideBytes).to.equal(3176)
			expect(narrowBytes).to.equal(1452)
			expect(string.format("%.1f", (wideBytes - narrowBytes) / wideBytes * 100)).to.equal("54.3")
		end)
	end)

	----------------------------------------------------------------------------
	-- REFUSED AT STARTUP, NOT AT RUNTIME.
	----------------------------------------------------------------------------

	describe("refuses an unrepresentable declaration when the template compiles", function()
		it("refuses a numeric Precision with no Min or no Max", function()
			-- A grid is measured from Min and bounded by Max; without both there is no
			-- origin and no step count, so there is nothing to narrow to.
			local why = "requires both Min and Max"
			refuses(Scribe.Number(0, { Precision = 0.5 }), why)
			refuses(Scribe.Number(0, { Min = 0, Precision = 0.5 }), why)
			refuses(Scribe.Number(0, { Max = 10, Precision = 0.5 }), why)
		end)

		it("refuses a Precision that is not positive and finite", function()
			local why = "must be finite and greater than zero"
			refuses(Scribe.Number(0, { Min = 0, Max = 10, Precision = 0 }), why)
			refuses(Scribe.Number(0, { Min = 0, Max = 10, Precision = -1 }), why)
			refuses(Scribe.Number(0, { Min = 0, Max = 10, Precision = 0 / 0 }), why)
			refuses(Scribe.Number(0, { Min = 0, Max = 10, Precision = 1e400 }), why)
		end)

		it('refuses a Precision that is neither a number nor "f32"', function()
			-- "f16" and "float" are the plausible typos, and a silently ignored
			-- Precision would leave the field an f64 while the developer believed it
			-- had been narrowed -- the failure being invisible is exactly why it is
			-- refused rather than warned about.
			local why = "or a positive number, got a"
			refuses(Scribe.Number(0, { Min = 0, Max = 1, Precision = "f16" :: any }), why)
			refuses(Scribe.Number(0, { Min = 0, Max = 1, Precision = "float" :: any }), why)
			refuses(Scribe.Number(0, { Min = 0, Max = 1, Precision = true :: any }), why)
			refuses(Scribe.Number(0, { Min = 0, Max = 1, Precision = {} :: any }), why)
		end)

		it("refuses a range needing more grid steps than an index can hold", function()
			-- 1e-9 across 0..100 is 1e11 steps, past the 4294967295 a u32 indexes.
			-- Refused HERE, at configure time, rather than by the encoder silently
			-- falling back on every single value it is ever handed.
			local why = "a fixed-point field can index"
			refuses(Scribe.Number(0, { Min = 0, Max = 100, Precision = 1e-9 }), why)
			refuses(Scribe.Number(0, { Min = -1e308, Max = 1e308, Precision = 1 }), why)
			-- And the control, exactly at the ceiling.
			expect(compiles(Scribe.Number(0, { Min = 0, Max = 4294967295, Precision = 1 }))).never.to.throw()
		end)

		it("refuses a Precision finer than a double's own spacing at the bounds", function()
			-- The step count stays SMALL here -- 1e17..1e17+10 by 0.1 is only 100
			-- steps -- so the ceiling above cannot catch it. What breaks is the double
			-- itself: at 1e17 the spacing between representable values is 16, so the
			-- grid is finer than the type storing its own endpoints and the promised
			-- half-Precision error is already broken before the codec does anything.
			local why = "spacing at"
			refuses(Scribe.Number(0, { Min = 1e17, Max = 1e17 + 10, Precision = 0.1 }), why)
			refuses(Scribe.Number(0, { Min = -1e17 - 10, Max = -1e17, Precision = 0.1 }), why)
			-- The control: the same tiny Precision at a magnitude a double resolves.
			expect(compiles(Scribe.Number(0, { Min = 0, Max = 10, Precision = 0.1 }))).never.to.throw()
		end)

		it("refuses an f32 bound past the binary32 range", function()
			-- Not a packing constraint -- the bounds do not enter the f32 encoding at
			-- all -- but a declaration that contradicts itself: every value at that
			-- end of the range would take the nine-byte generic path, so the field
			-- would be widest exactly where it was declared narrow.
			local why = "cannot represent a bound past"
			refuses(Scribe.Number(0, { Max = 1e39, Precision = "f32" }), why)
			refuses(Scribe.Number(0, { Min = -1e39, Precision = "f32" }), why)
			-- The controls: the binary32 extremes themselves are fine, and so is f32
			-- with no bounds at all.
			expect(compiles(Scribe.Number(0, { Min = -F32_MAX, Max = F32_MAX, Precision = "f32" }))).never.to.throw()
			expect(compiles(Scribe.Number(0, { Precision = "f32" }))).never.to.throw()
		end)

		it("refuses Precision on a declarator that is not Scribe.Number", function()
			-- It would sit in the meta table doing nothing. A bounded Int already
			-- packs from its Min/Max alone, so a developer who writes Precision there
			-- holds a belief about the field that is simply false, and nothing else
			-- would ever correct it.
			local why = "Precision is a Scribe.Number option"
			refuses(Scribe.Int(0, { Min = 0, Max = 9, Precision = 1 } :: any), why)
			refuses(Scribe.String("", { Precision = 1 } :: any), why)
			refuses(Scribe.Big(0, { Precision = 1 } :: any), why)
		end)

		it("still accepts every ordinary narrowing", function()
			-- The control for the whole block. A guard that refuses everything is not
			-- a guard.
			expect(compiles(Scribe.Number(0, { Precision = "f32" }))).never.to.throw()
			expect(compiles(Scribe.Number(0, { Min = 0, Max = 100, Precision = 0.5 }))).never.to.throw()
			expect(compiles(Scribe.Number(0, { Min = -1, Max = 1, Precision = 0.001 }))).never.to.throw()
			-- A degenerate single-point range. It narrows to one byte, carries only
			-- Min, and degrades everything else -- odd, but not wrong.
			expect(compiles(Scribe.Number(0, { Min = 0, Max = 0, Precision = 1 }))).never.to.throw()
		end)
	end)

	----------------------------------------------------------------------------
	-- THE SCHEMA HASH.
	----------------------------------------------------------------------------

	describe("the schema hash", function()
		local function hashOf(field)
			return Template.Compile({ N = field }, {}).Hash
		end

		it("folds Precision, so a narrowing drift cannot pass the Hello handshake", function()
			-- Precision drives the wire WIDTH exactly as Min/Max drive a bounded int's,
			-- and a realm that disagreed about it would read eight bytes where four
			-- were written and mis-parse the rest of the frame. Without this fold the
			-- templates below hash identically.
			local plain = hashOf(Scribe.Number(0, { Min = 0, Max = 100 }))
			expect(hashOf(Scribe.Number(0, { Min = 0, Max = 100, Precision = 0.5 }))).never.to.equal(plain)
			expect(hashOf(Scribe.Number(0, { Min = 0, Max = 100, Precision = "f32" }))).never.to.equal(plain)
			-- Two different grids over the same range are two different layouts.
			expect(hashOf(Scribe.Number(0, { Min = 0, Max = 100, Precision = 0.5 }))).never.to.equal(
				hashOf(Scribe.Number(0, { Min = 0, Max = 100, Precision = 0.25 }))
			)
		end)

		it("separates two grids one ulp apart", function()
			-- THE PROPERTY THE FOLD HAS TO HAVE: distinct steps hash distinctly, all
			-- the way down to adjacent doubles. Anything coarser would let two realms
			-- agree on a hash while disagreeing about where the grid points are, and
			-- every value on the field would come back slightly wrong with nothing
			-- anywhere reporting it.
			--
			-- The fold spends %.17g to get this, and a note on the original version of
			-- this test claimed tostring would have LOST these digits. Measured, that
			-- was false: Luau's tostring for numbers is shortest-round-trip, so it
			-- separates them too. %.17g is kept for not depending on that -- see
			-- precisionSig -- and the assertion below is written against the property
			-- rather than against either formatter.
			local a = 0.1
			local b = 0.1 + 2 ^ -56 -- the very next double up
			expect(a == b).to.equal(false)
			expect(hashOf(Scribe.Number(0, { Min = 0, Max = 1, Precision = a }))).never.to.equal(
				hashOf(Scribe.Number(0, { Min = 0, Max = 1, Precision = b }))
			)
		end)

		it("folds Precision on an ELEMENT node too", function()
			-- Element subtrees carry no ids, so the ById fold cannot see them and they
			-- are folded separately. A narrowing declared on an array's element would
			-- otherwise drift between realms and sail through the handshake.
			local plain = hashOf(Scribe.ArrayOf(Scribe.Number(0, { Min = 0, Max = 1 })))
			expect(hashOf(Scribe.ArrayOf(Scribe.Number(0, { Min = 0, Max = 1, Precision = 0.01 })))).never.to.equal(
				plain
			)
		end)
	end)
end
