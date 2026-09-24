--!nonstrict
-- Explicit lookups and named Big operations share the ordinary runtime paths.
return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Big = require(Root.Scribe.Internal.Big)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function withData(fn)
		local harness = TestCtx.make({
			AutoPump = true,
			Template = {
				Coins = Scribe.Int(1),
				Record = { Get = Scribe.String("initial"), Child = Scribe.Int(0) },
				Bag = Scribe.ArrayOf({ Qty = Scribe.Int(1) }),
				Items = Scribe.DictOf({ Qty = Scribe.Int(1) }),
				Users = Scribe.MapOf("integer", Scribe.String("")),
				Wealth = Scribe.Big("1e400"),
				Double = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(coins)
					return coins * 2
				end),
			},
		})
		local ok, err = pcall(function()
			local player, entry, data = harness.Join(99251)
			fn(harness, player, entry, data)
		end)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	it("Child reaches colliding names and reuses ordinary child identity", function()
		withData(function(_harness, _player, _entry, data)
			expect(data.Child("Coins") == data.Coins).to.equal(true)
			data.Record.Child("Get").Set("changed")
			data.Record.Child("Child").Increment(2)
			expect(data.Record.Get().Get).to.equal("changed")
			expect(data.Record.Get().Child).to.equal(2)
			for _, key in { "Get", "Remove", "Child" } do
				data.Items.Child(key).Qty.Set(3)
				expect(data.Items.Child(key).Qty.Get()).to.equal(3)
			end
			expect(data.Items.Count()).to.equal(3)
		end)
	end)

	it("Child preserves array positions and sparse integer map keys", function()
		withData(function(_harness, _player, _entry, data)
			data.Bag.Insert({ Qty = 5 })
			data.Bag.Insert({ Qty = 9 })
			expect(data.Bag.Child(1) == data.Bag[1]).to.equal(true)
			data.Bag.Child(1).Qty.Increment(1)
			expect(data.Bag.Get()[1].Qty).to.equal(6)
			expect(data.Bag.Get()[2].Qty).to.equal(9)
			data.Users.Child(123456).Set("Ada")
			data.Users.Child(-7).Set("Ben")
			expect(data.Users[123456].Get()).to.equal("Ada")
			expect(data.Users[-7].Get()).to.equal("Ben")
			expect(data.Users.Count()).to.equal(2)
		end)
	end)

	it("Child keeps key validation, closed schemas and write guards", function()
		withData(function(harness, _player, _entry, data)
			data.Bag.Insert({ Qty = 1 })
			for _, key in { true, 1.5, math.huge, "bad\31key", string.char(255) } do
				expect(function()
					data.Items.Child(key)
				end).to.throw()
			end
			expect(function()
				data.Bag.Child(1).Child("Typo")
			end).to.throw()
			expect(function()
				data.Child("Coins").Child("nested")
			end).to.throw()
			expect(function()
				data.Child("_Scribe").Child("Version").Set(999)
			end).to.throw()
			expect(function()
				data.Child("Double").Set(999)
			end).to.throw()
			local other = harness.Join(99252)
			local ok = harness.Data.Transaction(other, function()
				data.Child("Coins").Increment(1)
			end)
			expect(ok).to.equal(false)
			expect(data.Coins.Get()).to.equal(1)
		end)
	end)

	it("named Big operations retain range and leave the field unchanged", function()
		withData(function(_harness, _player, _entry, data)
			local original = data.Wealth.Get()
			local result = original:Add("2e400"):Subtract(Big.from("1e400")):Multiply(3):Divide(2)
			expect(tostring(result)).to.equal("3e400")
			expect(tostring(result:Negate())).to.equal("-3e400")
			expect(result:Compare(original)).to.equal(1)
			expect(original:Compare(result)).to.equal(-1)
			expect(result:Compare("3e400")).to.equal(0)
			expect(result:Equals("3e400")).to.equal(true)
			expect(Big.from(3):Equals(3)).to.equal(true)
			expect(result:Equals(original)).to.equal(false)
			expect(tostring(data.Wealth.Get())).to.equal("1e400")
			data.Wealth.Set(result)
			expect(tostring(data.Wealth.Get())).to.equal("3e400")
		end)
	end)

	it("named Big operations retain operand and zero-divisor errors", function()
		local value = Big.from("1e400")
		for _, method in { "Add", "Subtract", "Multiply", "Divide", "Compare", "Equals" } do
			expect(function()
				value[method](value, "not numeric")
			end).to.throw()
		end
		expect(function()
			value:Divide(0)
		end).to.throw()
	end)
end
