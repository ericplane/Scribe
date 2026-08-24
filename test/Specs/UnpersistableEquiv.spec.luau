--!nonstrict
-- findUnpersistable, checked against a transcription of what it used to be.
--
-- The function is the load path's guard against values the DataStore cannot
-- encode. A value it MISSES becomes a save that fails forever with an
-- undifferentiated error and no path in the log, so a rewrite for speed is only
-- worth anything if it is exactly equivalent -- not merely "still catches bad
-- data". Kind, Detail, the reported path, WHICH offender is reported when there
-- are several, and the MaxDepth it collects on the way all have to match.
--
-- The reference below is the pre-rewrite implementation, transcribed. It is
-- expected to rot: if someone changes what counts as unpersistable, this fails
-- and they update the reference deliberately. That is the point of it.

return function()
	local Root = script.Parent.Parent.Parent
	local Util = require(Root.Scribe.Internal.Util)
	local Datatypes = require(Root.Scribe.Internal.Datatypes)

	--- The original: a fresh path array cloned per child.
	local function reference(value: any, path, depth, stats): any
		local at = path or {}
		local d = depth or 0
		if stats and d > stats.MaxDepth then
			stats.MaxDepth = d
		end
		local typeName = typeof(value)
		if Datatypes.IsSupported(typeName) then
			return {
				Path = at,
				Kind = "Unserializable",
				Detail = `a raw {typeName}, which only the accessor packs; write `
					.. `Scribe.Datatypes.Pack("{typeName}", value) here, or store a plain number instead`,
			}
		end
		local t = type(value)
		if t == "string" then
			if Util.isUtf8(value) then
				return nil
			end
			return { Path = at, Kind = "InvalidUtf8", Detail = "string contains invalid UTF-8 bytes" }
		elseif t == "boolean" or t == "buffer" then
			return nil
		elseif t == "number" then
			if value ~= value or value == math.huge or value == -math.huge then
				return { Path = at, Kind = "Unserializable", Detail = "NaN/inf number" }
			end
			return nil
		elseif t == "table" then
			if d > 64 then
				return { Path = at, Kind = "Unserializable", Detail = "nested deeper than 64 levels (or cyclic)" }
			end
			local hasNum, hasStr = false, false
			for k, v in value do
				local kt = type(k)
				if kt ~= "string" and kt ~= "number" then
					local kp = table.clone(at)
					table.insert(kp, "<key>")
					return { Path = kp, Kind = "Unserializable", Detail = `unsupported key type "{kt}"` }
				end
				hasNum = hasNum or kt == "number"
				hasStr = hasStr or kt == "string"
				if hasNum and hasStr then
					return { Path = at, Kind = "Unserializable", Detail = "table mixes array indices and string keys" }
				end
				if kt == "string" and not Util.isUtf8(k) then
					local kp = table.clone(at)
					table.insert(kp, "<invalid-key>")
					return { Path = kp, Kind = "InvalidUtf8", Detail = "object key contains invalid UTF-8 bytes" }
				end
				local childPath = table.clone(at)
				table.insert(childPath, k)
				local found = reference(v, childPath, d + 1, stats)
				if found ~= nil then
					return found
				end
			end
			return nil
		end
		return { Path = at, Kind = "Unserializable", Detail = `unsupported type "{typeName}"` }
	end

	local function describe_(found): string
		if found == nil then
			return "nil"
		end
		return `{found.Kind}|{found.Detail}|{Util.pathString(found.Path)}|#{#found.Path}`
	end

	--- Compare across all three call shapes, since the load path uses two of them
	--- and the third is what a recursive caller would have used.
	local function agree(label: string, value: any)
		local a, b = reference(value), Util.findUnpersistable(value)
		expect(`{label} plain: {describe_(a)}`).to.equal(`{label} plain: {describe_(b)}`)

		local sa, sb = { MaxDepth = 0 }, { MaxDepth = 0 }
		local a2 = reference(value, nil, nil, sa)
		local b2 = Util.findUnpersistable(value, nil, nil, sb)
		expect(`{label} stats: {describe_(a2)} depth={sa.MaxDepth}`).to.equal(
			`{label} stats: {describe_(b2)} depth={sb.MaxDepth}`
		)

		-- A supplied path and depth. Also checks that neither form writes into the
		-- caller's array: a scratch stack that pushed onto it would leave its own
		-- bookkeeping in a table the caller still owns.
		local pa, pb = { "Root", 7 }, { "Root", 7 }
		local a3 = reference(value, pa, 3)
		local b3 = Util.findUnpersistable(value, pb, 3)
		expect(`{label} seeded: {describe_(a3)}`).to.equal(`{label} seeded: {describe_(b3)}`)
		expect(`{label} caller path: {Util.pathString(pa)}`).to.equal(`{label} caller path: {Util.pathString(pb)}`)
	end

	local function nest(levels: number, leaf: any): any
		local node = leaf
		for _ = 1, levels do
			node = { Deeper = node }
		end
		return node
	end

	describe("matches the previous implementation", function()
		it("on every kind of offender, and on clean data", function()
			local badUtf8 = string.char(0xFF, 0xFE)
			local cases: { { any } } = {
				{ "clean scalar", 42 },
				{ "clean string", "hello" },
				{ "clean nested", { A = { B = { C = 1, D = "x", E = true } } } },
				{ "empty", {} },
				{ "array", { 1, 2, 3 } },
				{ "nan", { Bad = 0 / 0 } },
				{ "inf", { Bad = math.huge } },
				{ "neg inf", { Bad = -math.huge } },
				{ "function", { Bad = function() end } },
				{ "invalid utf8 value", { Bad = badUtf8 } },
				{ "invalid utf8 key", { [badUtf8] = 1 } },
				{ "bad key type", { [true] = 1 } },
				{ "mixed keys", { [1] = "a", B = 2 } },
				{ "mixed keys other order", { B = 2, [1] = "a" } },
				{ "buffer", { B = buffer.fromstring("xy") } },
				{ "deep 60", nest(60, 1) },
				{ "deep 63", nest(63, 1) },
				{ "deep 64", nest(64, 1) },
				{ "deep 65", nest(65, 1) },
				{ "deep 70", nest(70, 1) },
				{ "offender under depth", nest(10, 0 / 0) },
				{ "offender at the root", 0 / 0 },
				{ "root is a function", function() end },
			}
			for _, case in cases do
				agree(case[1], case[2])
			end
		end)

		it("on a cycle, which is what the depth cap is really for", function()
			local cyclic = { Name = "loop" }
			cyclic.Self = cyclic
			agree("cycle", cyclic)

			local twice = { Name = "loop" }
			twice.A = twice
			twice.B = twice
			agree("cycle twice", twice)
		end)

		it("on random trees, so the cases above are not the only ones tried", function()
			-- Deterministic: a fixed seed, so a failure is reproducible rather than
			-- a story about one unlucky run.
			local seed = 0x5EED
			local function rnd(m: number): number
				seed = (seed * 1103515245 + 12345) % 2147483648
				return seed % m + 1
			end
			local badUtf8 = string.char(0xC3, 0x28)
			local leaves: { any } = {
				1,
				-7,
				0.5,
				"plain",
				"",
				true,
				false,
				0 / 0,
				math.huge,
				badUtf8,
				buffer.fromstring("b"),
				function() end,
			}
			local function grow(depth: number): any
				if depth <= 0 or rnd(4) == 1 then
					return leaves[rnd(#leaves)]
				end
				local node: any = {}
				local kind = rnd(3)
				for i = 1, rnd(4) do
					if kind == 1 then
						node[i] = grow(depth - 1)
					elseif kind == 2 then
						node[`k{i}`] = grow(depth - 1)
					else
						node[if rnd(2) == 1 then i else `k{i}`] = grow(depth - 1)
					end
				end
				if rnd(12) == 1 then
					node[badUtf8] = 1
				end
				return node
			end
			for i = 1, 300 do
				agree(`random{i}`, grow(5))
			end
		end)
	end)

	describe("the properties the equivalence rests on", function()
		it("reports the FIRST offender in iteration order, not any offender", function()
			-- A game reads the path out of the log and goes to fix that value, so
			-- which one is named is part of the contract. Two offenders of different
			-- kinds under one parent: whichever the iteration reaches first must win,
			-- and both implementations must agree on it.
			local badUtf8 = string.char(0xFF)
			for _, shape in
				{
					{ A = 0 / 0, B = badUtf8 },
					{ A = badUtf8, B = 0 / 0 },
					{ 0 / 0, badUtf8 },
					{ badUtf8, 0 / 0 },
				}
			do
				local a, b = reference(shape), Util.findUnpersistable(shape)
				expect(describe_(a)).to.equal(describe_(b))
			end
		end)

		it("keeps collecting MaxDepth right up to the offender it stops at", function()
			-- The depth diagnostic rides along on this walk rather than paying for a
			-- second one, so a rewrite that visits nodes in a different order, or
			-- stops updating depth once it has an answer, silently shortens the
			-- PROFILE_TOO_DEEP warning.
			local tree = { Shallow = 1, Deep = nest(30, { Bad = 0 / 0 }) }
			local sa, sb = { MaxDepth = 0 }, { MaxDepth = 0 }
			reference(tree, nil, nil, sa)
			Util.findUnpersistable(tree, nil, nil, sb)
			expect(`depth={sb.MaxDepth} found={sb.MaxDepth > 30}`).to.equal(`depth={sa.MaxDepth} found=true`)
		end)

		it("does not leave scratch entries in a path the caller handed it", function()
			-- The stack form is handed the caller's array only as a starting point.
			-- Writing its own bookkeeping into it would corrupt a table the caller
			-- still holds -- invisible today because every call site passes nil.
			local supplied = { "Root", "Sub" }
			Util.findUnpersistable({ A = { B = { C = 1 } } }, supplied)
			expect(`after={Util.pathString(supplied)} len={#supplied}`).to.equal("after=Root.Sub len=2")

			local suppliedBad = { "Root" }
			Util.findUnpersistable({ A = 0 / 0 }, suppliedBad)
			expect(`after={Util.pathString(suppliedBad)} len={#suppliedBad}`).to.equal("after=Root len=1")
		end)
	end)
end
