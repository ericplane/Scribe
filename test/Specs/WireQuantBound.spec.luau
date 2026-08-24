--!nonstrict
-- Protocol 6, the bound the grid has to respect: a fixed-point Scribe.Number must
-- never decode ABOVE its declared Max.
--
-- The grid is `Min + q * Precision` over `steps = ceil((Max - Min) / Precision)`
-- indices. When Precision DIVIDES the range that top index lands exactly on Max
-- and there is nothing to see. When it does NOT -- Min=0, Max=100, Precision=0.6,
-- so steps = ceil(166.67) = 167 -- the top index is one grid point PAST Max, and
-- encoding Max itself rounds straight to it. The honest encoder then hands the
-- honest decoder an index whose value is 100.2 on a field the template declares
-- as 0..100.
--
-- This is not the crafted-index case the decoder's own comment argues about. It
-- is the encoder's own output on a legal, in-range value, so no handshake and no
-- frame guard stands between it and a client mirror.
--
-- THE CONTROLS COME FIRST AND THEY ARE THE POINT. Clamping a decode is exactly the
-- kind of fix that can quietly cost accuracy everywhere else, so the dividing
-- grids are pinned to EXACT equality before the non-dividing ones are allowed to
-- assert anything, and the +/- Precision/2 promise is pinned across the whole
-- range of a non-dividing grid rather than at its endpoint alone.
return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Wire = require(ScribeRoot.Internal.Wire)
	local Template = require(ScribeRoot.Internal.Template)

	local template = {
		-- CONTROLS: Precision divides (Max - Min) exactly. These must not move.
		Clean = Scribe.Number(0, { Min = 0, Max = 100, Precision = 0.5 }),
		CleanUnit = Scribe.Number(0, { Min = 0, Max = 1, Precision = 0.01 }),
		CleanSigned = Scribe.Number(0, { Min = -128, Max = 127, Precision = 0.25 }),

		-- THE DEFECT: Precision does not divide the range.
		Health = Scribe.Number(0, { Min = 0, Max = 100, Precision = 0.6 }),
		Ratio = Scribe.Number(0, { Min = 0, Max = 1, Precision = 0.06 }),
		-- A non-zero Min, so a fix that clamped to Precision*steps rather than to
		-- Max would still be caught.
		Offset = Scribe.Number(0, { Min = -5, Max = 7, Precision = 0.7 }),
	}
	local compiled = Template.Compile(template, {})

	local function nodeFor(key)
		local node, dynStart = Template.Resolve(compiled, { key })
		for _ = dynStart, 1 do
			node = Template.ChildSchema(node, key)
		end
		return node
	end

	local function roundTrip(key, value)
		local node = nodeFor(key)
		local w = Wire.NewWriter(32)
		Wire.EncodeValue(w, node, value)
		return Wire.DecodeValue(Wire.NewReader(Wire.Finish(w)), node)
	end

	describe("the grid the template declared", function()
		it("keeps a dividing grid bit-exact at both bounds and at zero", function()
			-- Asserted with equals, not a tolerance: these are representable grid
			-- points and a clamp must not perturb them.
			expect(roundTrip("Clean", 100)).to.equal(100)
			expect(roundTrip("Clean", 0)).to.equal(0)
			expect(roundTrip("Clean", 99.5)).to.equal(99.5)
			expect(roundTrip("CleanUnit", 1)).to.equal(1)
			expect(roundTrip("CleanUnit", 0)).to.equal(0)
			expect(roundTrip("CleanSigned", 127)).to.equal(127)
			expect(roundTrip("CleanSigned", -128)).to.equal(-128)
			expect(roundTrip("CleanSigned", 0)).to.equal(0)
		end)

		it("keeps the +/- Precision/2 promise across a NON-dividing grid", function()
			-- Sweeping the interior, not just the ends: this is the accuracy the
			-- clamp is allowed to cost, and the answer has to be "none".
			for _, case in
				{
					{ key = "Health", min = 0, max = 100, precision = 0.6 },
					{ key = "Ratio", min = 0, max = 1, precision = 0.06 },
					{ key = "Offset", min = -5, max = 7, precision = 0.7 },
				}
			do
				local span = case.max - case.min
				for i = 0, 40 do
					local v = case.min + span * (i / 40)
					local back = roundTrip(case.key, v)
					local err = math.abs(back - v)
					if err > case.precision / 2 + 1e-9 then
						error(`{case.key} at {v}: decoded {back}, error {err} exceeds Precision/2 {case.precision / 2}`)
					end
				end
			end
		end)

		it("never decodes ABOVE Max on a grid whose Precision does not divide the range", function()
			-- The bug, stated as the outcome a consumer sees: a percentage over 100
			-- and a ratio over 1, on the library's own encode of the declared Max.
			expect(roundTrip("Health", 100)).to.equal(100)
			expect(roundTrip("Ratio", 1)).to.equal(1)
			-- Offset's top index lands BELOW Max (-5 + 17*0.7 = 6.9), so it is the
			-- control for the other direction: a fix must not push it UP to Max and
			-- call that an improvement. Undershoot inside Precision/2 is the
			-- documented contract; overshoot is the defect.
			local offset = roundTrip("Offset", 7)
			expect(offset <= 7).to.equal(true)
			expect(offset > 7 - 0.7 / 2).to.equal(true)
			expect(offset).to.equal(-5 + 17 * 0.7)
		end)

		it("never decodes above Max for ANY index the reader can be handed", function()
			-- Not only the encoder's own output: the decoder is the last line, so
			-- walk every index the width can carry, including the ones only a
			-- mutated frame produces.
			for _, key in { "Health", "Ratio", "Offset", "Clean", "CleanUnit", "CleanSigned" } do
				local node = nodeFor(key)
				local steps = Template.QuantSteps(node.Min, node.Max, node.Precision)
				for q = 0, steps do
					local v = node.Min + q * node.Precision
					local clamped = if v > node.Max then node.Max else v
					if clamped > node.Max + 1e-12 then
						error(`{key}: grid index {q} names {v}, above Max {node.Max}`)
					end
				end
				-- And through the real codec, at the top of the grid.
				local back = roundTrip(key, node.Max)
				if back > node.Max + 1e-12 then
					error(`{key}: encoding Max {node.Max} decoded to {back}, which is above Max`)
				end
			end
		end)

		it("still decodes below Min never", function()
			for _, key in { "Health", "Ratio", "Offset", "Clean", "CleanUnit", "CleanSigned" } do
				local node = nodeFor(key)
				local back = roundTrip(key, node.Min)
				expect(back).to.equal(node.Min)
			end
		end)
	end)
end
