--!nonstrict
-- An accessor is not iterable, and the reason is that the old fallback DESTROYED DATA.
--
-- Before `__iter` existed on ACCESSOR_MT, a generalized `for` over an accessor fell
-- back to `__call`, because Luau's generalized for uses `__call` as the iterator when
-- no `__iter` is present. It invoked it once with the state and control variables,
-- both nil, which reached `accessor.Set(nil, nil)`. Set with a nil value deletes the
-- node: `validateWrite` returns nil immediately for a nil value, and the declared-field
-- removal refusal only fires inside a Closed element shape, so a root-level container
-- had nothing standing between it and deletion.
--
-- The loop body never ran, so the whole thing read as a harmless no-op. MEASURED
-- before the fix: a DictOf holding one key went to zero keys, and an ArrayOf holding
-- two entries went to zero, with no error, and the deletion emitted an op and
-- persisted.
--
-- `for key, entry in data.Inventory do` is what a developer naturally writes. An
-- accessor looks like a container and `__index` makes `data.Inventory.relic` work, so
-- there is nothing to warn them off it. That is why this raises with a sentence
-- naming the fix rather than merely refusing.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function harnessed(fn)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 1000 }),
				Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 9 }) }, { MaxKeys = 5 }),
				Bag = Scribe.ArrayOf(Scribe.String("x"), { MaxItems = 5 }),
			},
		})
		local ok, err = pcall(fn, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	it("REFUSES a generalized for over a dictionary accessor, and leaves it intact", function()
		harnessed(function(harness)
			local player = harness.Join(99101)
			local data = harness.Data.Get(player)
			data.Inventory["sword"].Set({ Qty = 3 })

			local ok, err = pcall(function()
				for _key, _entry in data.Inventory do
					break
				end
			end)

			expect(
				`ok={tostring(ok)} named={tostring(string.find(tostring(err), "not iterable", 1, true) ~= nil)} count={data.Inventory.Count()}`
			).to.equal("ok=false named=true count=1")
		end)
	end)

	it("REFUSES it over an array accessor too, which lost every entry before the fix", function()
		harnessed(function(harness)
			local player = harness.Join(99102)
			local data = harness.Data.Get(player)
			data.Bag.Insert("a")
			data.Bag.Insert("b")

			local ok = pcall(function()
				for _entry in data.Bag do
					break
				end
			end)

			expect(`ok={tostring(ok)} count={data.Bag.Count()}`).to.equal("ok=false count=2")
		end)
	end)

	it("REFUSES the two-nil call the old fallback produced, by name", function()
		-- The same shape reached directly rather than through a loop. A deliberate
		-- clear is Set(nil) with ONE argument; two nils is never intentional.
		harnessed(function(harness)
			local player = harness.Join(99103)
			local data = harness.Data.Get(player)
			data.Inventory["sword"].Set({ Qty = 3 })

			local ok, err = pcall(function()
				return (data.Inventory :: any)(nil, nil)
			end)

			expect(
				`ok={tostring(ok)} named={tostring(string.find(tostring(err), "would delete this node", 1, true) ~= nil)} count={data.Inventory.Count()}`
			).to.equal("ok=false named=true count=1")
		end)
	end)

	it("still lets the callable shorthand get, set and update", function()
		-- The control. __call carries a real API and the refusal above must not have
		-- broken it, or this file would be pinning a regression rather than a fix.
		harnessed(function(harness)
			local player = harness.Join(99104)
			local data = harness.Data.Get(player)

			data.Coins(120)
			local read = data.Coins()
			data.Coins(function(current)
				return current + 5
			end)

			expect(`read={read} after={data.Coins.Get()}`).to.equal("read=120 after=125")
		end)
	end)

	it("iterates the VALUE, which is what the error message tells you to do", function()
		-- The message has to name a working alternative, or it just moves the problem.
		harnessed(function(harness)
			local player = harness.Join(99105)
			local data = harness.Data.Get(player)
			data.Inventory["sword"].Set({ Qty = 3 })
			data.Inventory["shield"].Set({ Qty = 1 })

			local keys = {}
			for key in data.Inventory.Get() do
				table.insert(keys, key)
			end
			table.sort(keys)

			local cloned = {}
			for key in data.Inventory.Clone() do
				table.insert(cloned, key)
			end
			table.sort(cloned)

			expect(`get={table.concat(keys, ",")} clone={table.concat(cloned, ",")}`).to.equal(
				"get=shield,sword clone=shield,sword"
			)
		end)
	end)
end
