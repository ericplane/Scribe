--!nonstrict
-- A nil inside an Args array.
--
-- REPORTED, and the reported mechanism was wrong while the conclusion was right. The
-- claim was that `Args = { "number", nil, "string" }` gives `#` = 3 while "the loop only
-- gets 1", so position 2 is never validated. `ipairs` is what stops at 1; Commands.luau
-- uses generalized iteration, which SKIPS the hole and visits 1 and 3. Either way the
-- middle position was decoded and handed to the handler unchecked, because `#` counts
-- past the hole and the arity check therefore admits the argument.
--
-- Measured before the fix, on the constructor form only: a hole built by assignment
-- (t[1], t[3]) gives `#` = 1, so the arity check rejects the third argument and the gap
-- never opens. That asymmetry is why this is pinned on the constructor shape.
--
-- Not remotely reachable: an attacker cannot create the hole, a developer has to. It is
-- refused at registration for the reason the file already refuses other malformed specs,
-- which is that a spec that silently means something else reads as a client bug.

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function commandFrame(correlation: number, name: string, args: any): buffer
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.Command)
		Wire.U32(w, correlation)
		Wire.Str(w, name)
		Wire.U8(w, args.n)
		Wire.Str(w, "")
		for i = 1, args.n do
			Wire.EncodeGeneric(w, args[i])
		end
		return Wire.Finish(w)
	end

	local function send(harness, entry, name: string, ...)
		local reader = Wire.NewReader(commandFrame(1, name, table.pack(...)))
		Wire.RU8(reader)
		harness.Ctx.Commands.HandleFrame(entry, reader)
	end

	local function raised(fn, ...): string
		local ok, err = pcall(fn, ...)
		return if ok then "no error" else tostring(err)
	end

	describe("registering one", function()
		it("REFUSES an Args array with a hole, naming the position", function()
			local harness = TestCtx.make({})
			local text = raised(harness.Data.Command, "Hole", { Args = { "number", nil, "string" } }, function() end)
			harness.Cleanup()
			expect(
				`named={string.find(text, "Args[2]", 1, true) ~= nil} `
					.. `route={string.find(text, '"any"', 1, true) ~= nil}`
			).to.equal("named=true route=true")
		end)

		it('CONTROL: the same spec with "any" in the gap registers fine', function()
			local harness = TestCtx.make({})
			local text = raised(harness.Data.Command, "Fine", { Args = { "number", "any", "string" } }, function() end)
			harness.Cleanup()
			expect(text).to.equal("no error")
		end)

		it("REFUSES a gap written by ASSIGNMENT too, where `#` stops short instead", function()
			-- The other construction form. Here `#` is 1, so a length scan would check only
			-- index 1 and miss the gap entirely; the arity check happens to reject the third
			-- argument, but the spec still does not mean what it reads as.
			local harness = TestCtx.make({})
			local built = {}
			built[1] = "number"
			built[3] = "string"
			local text = raised(harness.Data.Command, "Assigned", { Args = built }, function() end)
			harness.Cleanup()
			expect(string.find(text, "Args[2]", 1, true) ~= nil).to.equal(true)
		end)

		it("CONTROL: a named key beside the array is NOT a gap, so nothing new is refused", function()
			local harness = TestCtx.make({})
			local text = raised(harness.Data.Command, "Named", { Args = { "number" } }, function() end)
			harness.Cleanup()
			expect(text).to.equal("no error")
		end)

		it("CONTROL: an ordinary spec is untouched", function()
			local harness = TestCtx.make({})
			local text = raised(harness.Data.Command, "Plain", { Args = { "number", "string" } }, function() end)
			harness.Cleanup()
			expect(text).to.equal("no error")
		end)
	end)

	describe("what the hole used to let through", function()
		it('still type-checks EVERY position once the gap is declared "any"', function()
			-- "any" is deliberate permissiveness at position 2, and it must not soften 1 or 3.
			local harness = TestCtx.make({})
			local seen = {}
			harness.Data.Command("Mixed", { Args = { "number", "any", "string" } }, function(_player, a, b, c)
				table.insert(seen, `{typeof(a)}/{typeof(b)}/{typeof(c)}`)
			end)
			local _player, entry = harness.Join(97101)

			send(harness, entry, "Mixed", 1, {}, "ok") -- position 2 is a table: allowed by "any"
			send(harness, entry, "Mixed", 1, "junk", 2) -- position 3 is a number: still rejected
			send(harness, entry, "Mixed", "junk", 1, "ok") -- position 1 is a string: still rejected

			local ran = table.concat(seen, ",")
			harness.Cleanup()
			expect(ran).to.equal("number/table/string")
		end)
	end)
	describe("a non-finite number argument", function()
		local NAN = 0 / 0

		--- Send `value` to a command declaring `spec`, and report what the handler saw.
		local function sendArg(spec, value): string
			local harness = TestCtx.make({})
			local seen = "not reached"
			harness.Data.Command("Probe", { Args = { spec } }, function(_player, n)
				seen = tostring(n)
			end)
			local _player, entry = harness.Join(97201)
			send(harness, entry, "Probe", value)
			harness.Cleanup()
			return seen
		end

		it('REFUSES NaN through a bare "number", which typeof calls a number', function()
			-- The exploit shape: every comparison against NaN is false, so a handler guarding
			-- with `if amount > 0` AND `if amount <= 0` skips both arms.
			expect(sendArg("number", NAN)).to.equal("not reached")
		end)

		it("REFUSES infinity the same way", function()
			expect(sendArg("number", math.huge)).to.equal("not reached")
		end)

		it('REFUSES it through "any" too, since no number Scribe stores is non-finite', function()
			expect(sendArg("any", NAN)).to.equal("not reached")
		end)

		it("REFUSES it inside a shape field", function()
			local harness = TestCtx.make({})
			local seen = "not reached"
			harness.Data.Command("Shaped", { Args = { { Amount = "number" } } }, function(_player, t)
				seen = tostring(t.Amount)
			end)
			local _player, entry = harness.Join(97202)
			send(harness, entry, "Shaped", { Amount = NAN })
			harness.Cleanup()
			expect(seen).to.equal("not reached")
		end)

		it("CONTROL: ordinary numbers still arrive, including 0 and negatives", function()
			expect(`{sendArg("number", 0)},{sendArg("number", -7.5)},{sendArg("any", 42)}`).to.equal("0,-7.5,42")
		end)
	end)

	describe("the same class in Scribe.Derived", function()
		it("REFUSES a gap in the input list, which used to narrow the field silently", function()
			-- { "A", nil, "B" } became a TWO-input derived: the resolver skips the hole, so the
			-- "inputs must be strings" check never sees it and Compute takes nil forever.
			local Scribe = require(ScribeRoot) :: any
			local Template = require(ScribeRoot.Internal.Template)
			local ok, err = pcall(Template.Compile, {
				A = Scribe.Int(0),
				B = Scribe.Int(0),
				Sum = Scribe.Derived(Scribe.Int(0), { "A", nil, "B" }, function(a, b)
					return (a or 0) + (b or 0)
				end),
			}, {})
			local text = if ok then "no error" else tostring(err)
			expect(`refused={not ok} named={string.find(text, "input 2", 1, true) ~= nil}`).to.equal(
				"refused=true named=true"
			)
		end)

		it("CONTROL: the same derived with no gap still compiles", function()
			local Scribe = require(ScribeRoot) :: any
			local Template = require(ScribeRoot.Internal.Template)
			local ok = pcall(Template.Compile, {
				A = Scribe.Int(0),
				B = Scribe.Int(0),
				Sum = Scribe.Derived(Scribe.Int(0), { "A", "B" }, function(a, b)
					return a + b
				end),
			}, {})
			expect(ok).to.equal(true)
		end)
	end)
end
