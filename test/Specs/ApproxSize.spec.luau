--!nonstrict
-- Util.approxSize is what PROFILE_SIZE and the wipe guard measure a profile
-- with, so it is checked against the REAL encoder rather than against a
-- hand-computed expectation. Every "exactly" case below asserts equality with
-- #HttpService:JSONEncode(value); the numbers are not fitted.
--
-- The direction matters more than the magnitude. PROFILE_SIZE exists to warn
-- BEFORE saves start failing at the ~4 MB ceiling, so an under-count is silent
-- -- no warning, then every save fails with an undifferentiated DataStore error
-- -- while an over-count only costs an early warning. Hence the closing property
-- test, which asserts a bound rather than a value.
--
-- Two cases cannot use the oracle, because the encoder in the headless runner
-- refuses them: an integer-keyed table (it demands string keys) and a cyclic
-- one. Their expectations were taken from the real HttpService:JSONEncode in
-- Studio and are quoted at the assertion.

return function()
	local Root = script.Parent.Parent.Parent
	local Util = require(Root.Scribe.Internal.Util)
	local HttpService = game:GetService("HttpService")

	-- Byte length of the real JSON encoding. Labelled so a failure names the case
	-- instead of just disagreeing about an integer.
	local function oracle(label: string, value: any)
		local expected = #HttpService:JSONEncode(value)
		local actual = Util.approxSize(value)
		expect(`{label}={actual}`).to.equal(`{label}={expected}`)
	end

	describe("agrees with the encoder byte for byte", function()
		it("counts an array of integers", function()
			oracle("small", { 10, 20, 30 })
			-- Wide enough that a per-index key charge is unmissable: the old flat
			-- cost priced this array 7.6x over.
			local wide = {}
			for i = 1, 500 do
				wide[i] = i
			end
			oracle("wide", wide)
		end)

		it("counts a record of string keys", function()
			oracle("record", { Coins = 1250, Nick = "Player", Premium = true, Ratio = 1.5 })
		end)

		it("counts nested tables and empty containers", function()
			oracle("nested", { a = { b = { c = { 1, 2 } } } })
			oracle("emptyTable", {})
			oracle("emptyNested", { a = {}, b = {} })
		end)

		it("counts a realistic inventory", function()
			local inv = {}
			for i = 1, 120 do
				inv[i] = { Id = "sword_" .. i, Qty = i % 20, Equipped = i % 3 == 0, Lvl = 1.5 }
			end
			oracle("inventory", { Inventory = inv, Coins = 98765 })
		end)
	end)

	describe("keys", function()
		-- The distinguishing pair. "Stop counting array indices as keys" is only
		-- half a rule: a numeric key OUTSIDE the array part is written as a QUOTED
		-- string key, which is exactly why Template.CoerceMapKeys exists to undo
		-- the round trip for MapOf("integer"). A fix that frees every numeric key
		-- passes the first of these and fails the second.
		it("charges nothing for array positions", function()
			-- [1,2,3] -- three values, two commas, two brackets.
			expect(Util.approxSize({ 1, 2, 3 })).to.equal(7)
		end)

		it("charges an integer map key as a quoted string key", function()
			-- Studio, real HttpService:JSONEncode: {[123]="a"} -> {"123":"a"} (11 bytes).
			-- The headless encoder refuses integer keys outright, so this one is
			-- pinned to the value the real encoder produced.
			expect(Util.approxSize({ [123] = "a" })).to.equal(11)
			-- Same payload as an array position costs 5 fewer bytes: no "123", no
			-- quotes around it, no colon.
			expect(Util.approxSize({ "a" })).to.equal(5)
		end)

		it("charges one comma between entries, not one per entry", function()
			-- [1] has no comma at all; [1,2] has exactly one.
			expect(Util.approxSize({ 1 })).to.equal(3)
			expect(Util.approxSize({ 1, 2 })).to.equal(5)
		end)
	end)

	describe("strings", function()
		it("charges a control character six bytes", function()
			-- "\1" encodes as : six bytes for one, not one.
			oracle("ctrl", { s = "a\1b" })
			expect(Util.approxSize("\1")).to.equal(2 + 6)
		end)

		it("charges a quote and a backslash two bytes each", function()
			oracle("escaped", { s = 'a"b\\c' })
			expect(Util.approxSize('"')).to.equal(2 + 2)
			expect(Util.approxSize("\\")).to.equal(2 + 2)
		end)

		it("charges the short escapes two bytes, not six", function()
			-- \b \t \n \f \r have two-byte forms; other control characters do not.
			oracle("shortEscapes", { s = "\b\t\n\f\r" })
			expect(Util.approxSize("\n")).to.equal(2 + 2)
		end)

		it("charges non-ASCII its raw UTF-8 bytes rather than a \\u escape", function()
			-- Measured against the real encoder: it emits raw UTF-8, so a 3-byte
			-- CJK character costs three and a 4-byte emoji four. Charging \uXXXX
			-- here would over-count every non-Latin profile by 2-3x.
			oracle("cjk", { s = utf8.char(0x4E2D) })
			oracle("emoji", { s = utf8.char(0x1F600) })
			expect(Util.approxSize(utf8.char(0x4E2D))).to.equal(2 + 3)
			expect(Util.approxSize(utf8.char(0x1F600))).to.equal(2 + 4)
		end)
	end)

	describe("numbers", function()
		it("charges an integer its digit count", function()
			expect(Util.approxSize(0)).to.equal(1)
			expect(Util.approxSize(7)).to.equal(1)
			expect(Util.approxSize(1250)).to.equal(4)
			expect(Util.approxSize(-1250)).to.equal(5) -- the sign is a byte
			expect(Util.approxSize(2147483647)).to.equal(10)
		end)

		it("does not under-count a large integral value written in full", function()
			-- The trap: the encoder writes integral values in full decimal all the
			-- way to 1e20 and only switches to exponent form at 1e21. A %.17g-only
			-- implementation renders 1e20 as "1e+20" and under-counts it by 16.
			expect(Util.approxSize(1e20)).to.equal(21)
			expect(Util.approxSize(1e15)).to.equal(16)
		end)

		it("charges a non-encodable number as null rather than inventing a size", function()
			expect(Util.approxSize(0 / 0)).to.equal(4)
			expect(Util.approxSize(math.huge)).to.equal(4)
		end)
	end)

	describe("buffers", function()
		it("charges a buffer its base64 length, padding included", function()
			-- The encoder refuses buffers outright, so the oracle here is Scribe's
			-- OWN base64 writer -- the same encoding a DataStore stores a buffer in.
			-- Tying the estimate to it rather than to a constant means the two
			-- cannot drift apart silently.
			--
			-- Lengths 1..8 matter because base64 pads to four-character groups:
			-- ceil(n * 4 / 3) quietly under-counts every length that is not a
			-- multiple of 3, which is two thirds of them.
			for n = 0, 8 do
				local buf = buffer.create(n)
				local expected = #Util.base64FromBuffer(buf) + 2 -- + the quotes
				expect(`len{n}={Util.approxSize(buf)}`).to.equal(`len{n}={expected}`)
			end
		end)

		it("charges a buffer nested in a profile the same way", function()
			local buf = buffer.create(10)
			local expected = 2 + (#"Packed" + 2) + 1 + (#Util.base64FromBuffer(buf) + 2)
			expect(Util.approxSize({ Packed = buf })).to.equal(expected)
		end)
	end)

	describe("the per-byte escape cost", function()
		it("prices every single byte the encoder accepts exactly as the encoder does", function()
			-- The string cost is now a 256-entry table indexed by the byte, rather
			-- than a pattern match, so the table IS the rule and a wrong cell is the
			-- whole failure mode. One cell wrong is invisible in a shape test and
			-- unmissable here.
			--
			-- Bytes 0x80-0xFF are skipped: alone they are not valid UTF-8 and the
			-- encoder refuses them. They are covered as whole code points by the
			-- non-ASCII case above, which is the only way they can legally occur.
			local wrong = {}
			for b = 0, 127 do
				local s = string.char(b)
				local ok, expected = pcall(function()
					return #HttpService:JSONEncode(s)
				end)
				if ok then
					local actual = Util.approxSize(s)
					if actual ~= expected then
						table.insert(wrong, `byte {b}: {actual} vs {expected}`)
					end
				end
			end
			expect(`wrong={#wrong} {table.concat(wrong, ", ")}`).to.equal("wrong=0 ")
		end)

		it("charges a byte the same in a long string as it does alone", function()
			-- The walk has no fast path any more, so nothing distinguishes the first
			-- byte from the thousandth -- but a future one might, and a per-chunk
			-- optimisation that mishandles the tail would show up exactly here.
			for _, b in { 0, 8, 9, 10, 12, 13, 31, 34, 92, 65 } do
				local one = Util.approxSize(string.char(b)) - 2
				for _, n in { 1, 15, 16, 17, 63, 64, 65, 1000 } do
					local many = Util.approxSize(string.rep(string.char(b), n)) - 2
					expect(`byte {b} x{n}={many}`).to.equal(`byte {b} x{n}={one * n}`)
				end
			end
		end)
	end)

	describe("bounds and safety", function()
		it("never under-counts, across shapes the encoder accepts", function()
			local cases = {
				{ "ints", { 1, 2, 3, 1000, -5 } },
				{ "floats", { 0.1, 1 / 3, 1.5, 1e-7, math.pi, 1e300 } },
				{ "strings", { "", "plain", 'q"q', "\1\2\3", utf8.char(0x1F600) } },
				{ "bools", { true, false } },
				{ "mixedRecord", { A = 1, B = "two", C = false, D = { 1.5, "x" } } },
				{ "deep", { a = { b = { c = { d = { e = { f = 1 } } } } } } },
			}
			for _, case in cases do
				local label, value = case[1], case[2]
				local approx = Util.approxSize(value)
				local real = #HttpService:JSONEncode(value)
				-- An under-count is the silent failure, so the message names the
				-- direction and the case rather than just disagreeing about a number.
				local verdict = if approx >= real then "ok" else `UNDER by {real - approx}`
				expect(`{label} ({approx} vs {real}): {verdict}`).to.equal(`{label} ({approx} vs {real}): ok`)
			end
		end)

		it("returns a finite size for a cyclic table instead of overflowing", function()
			-- approxSize runs UNPROTECTED on the save path, so a cycle reaching it
			-- would kill the save rather than fail it. The raw-write boundaries
			-- (OnPlayerInit, migrations, offline drafts) can produce one.
			local cyclic = { Name = "loop" }
			cyclic.Self = cyclic
			local size = Util.approxSize(cyclic)
			expect(type(size)).to.equal("number")
			expect(size == size and size < math.huge).to.equal(true)
		end)

		it("is not fooled into a fixed cost per value", function()
			-- A guard against regressing to any flat-constant scheme: these three
			-- differ only in payload width and must price differently.
			local one = Util.approxSize({ N = 1 })
			local many = Util.approxSize({ N = 123456789 })
			local text = Util.approxSize({ N = "123456789" })
			expect(many > one).to.equal(true)
			expect(text > many).to.equal(true)
		end)
	end)
end
