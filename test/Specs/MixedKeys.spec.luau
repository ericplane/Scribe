--!nolint
-- A keyed write must not build a table that is both array and hash: the DataStore
-- drops one half of one on encode, and Set on the PARENT already refuses the
-- identical shape.
return function()
	local TestCtx = require(script.Parent.Parent.Helpers.TestCtx)

	local function keyShape(t: any): (number, number)
		local numeric, strings = 0, 0
		for k in t do
			if type(k) == "number" then
				numeric += 1
			else
				strings += 1
			end
		end
		return numeric, strings
	end

	describe("mixed array/hash keys", function()
		it("refuses a numeric key on a record that already holds string keys", function()
			local harness = TestCtx.make()
			local _, entry, data = harness.Join()
			expect(function()
				data.Settings[1].Set(5)
			end).to.throw()
			local numeric, strings = keyShape(entry.Profile.Data.Settings)
			expect(numeric).to.equal(0)
			expect(strings).to.equal(2)
			harness.Cleanup()
		end)

		it("refuses a string key on a bag that already holds an array", function()
			local harness = TestCtx.make()
			local _, entry, data = harness.Join()
			data.Inventory[1].Set("a")
			data.Inventory[2].Set("b")
			expect(function()
				data.Inventory.Sword.Set(true)
			end).to.throw()
			local numeric, strings = keyShape(entry.Profile.Data.Inventory)
			expect(numeric).to.equal(2)
			expect(strings).to.equal(0)
			harness.Cleanup()
		end)

		-- The boundary the predicate is actually written against: ONE occupied index
		-- is already an array part. Without this case an off-by-one (index 2 instead
		-- of index 1) passes the whole suite.
		it("refuses a string key on a bag holding a SINGLE-element array", function()
			local harness = TestCtx.make()
			local _, entry, data = harness.Join()
			data.Inventory[1].Set("a")
			expect(function()
				data.Inventory.Sword.Set(true)
			end).to.throw()
			local numeric, strings = keyShape(entry.Profile.Data.Inventory)
			expect(numeric).to.equal(1)
			expect(strings).to.equal(0)
			harness.Cleanup()
		end)

		it("refuses an Insert that would land an array index beside a string key", function()
			local harness = TestCtx.make()
			local _, entry, data = harness.Join()
			data.Inventory.Sword.Set(true)
			expect(function()
				data.Inventory.Insert("x")
			end).to.throw()
			-- and nothing was materialized on the way out
			local numeric, strings = keyShape(entry.Profile.Data.Inventory)
			expect(numeric).to.equal(0)
			expect(strings).to.equal(1)
			harness.Cleanup()
		end)

		it("still allows Insert to build and grow an ordinary array", function()
			local harness = TestCtx.make()
			local _, entry, data = harness.Join()
			for i = 1, 5 do
				data.Quests.Insert("q" .. i)
			end
			local numeric, strings = keyShape(entry.Profile.Data.Quests)
			expect(numeric).to.equal(5)
			expect(strings).to.equal(0)
			expect(#entry.Profile.Data.Quests).to.equal(5)
			harness.Cleanup()
		end)

		it("refuses an aliasing numeric key even when the memo was scanned clean first", function()
			local harness = TestCtx.make()
			local _, entry, data = harness.Join()
			data.Inventory[7].Set("a") -- numeric create: scans, memoises "no string key"
			data.Inventory.Sword.Set(true) -- a string key arrives after the scan
			expect(function()
				data.Inventory[1].Set("x")
			end).to.throw()
			local numeric, strings = keyShape(entry.Profile.Data.Inventory)
			expect(numeric).to.equal(1)
			expect(strings).to.equal(1)
			harness.Cleanup()
		end)

		it("refuses a mixing INTERMEDIATE segment auto-vivified by a nested write", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			expect(function()
				data.Settings[1].Sub.Set(5)
			end).to.throw()
			harness.Cleanup()
		end)

		it("still allows an array to be built key by key in an empty bag", function()
			local harness = TestCtx.make()
			local _, entry, data = harness.Join()
			for i = 1, 5 do
				data.Inventory[i].Set(i * 10)
			end
			local numeric, strings = keyShape(entry.Profile.Data.Inventory)
			expect(numeric).to.equal(5)
			expect(strings).to.equal(0)
			expect(data.Inventory[3].Get()).to.equal(30)
			harness.Cleanup()
		end)

		it("still allows a sparse hash-part integer bag alongside string keys added first", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			data.Inventory[7].Set("seven")
			data.Inventory["07"].Set("oh-seven") -- no array part: index 1 is empty
			expect(data.Inventory[7].Get()).to.equal("seven")
			expect(data.Inventory["07"].Get()).to.equal("oh-seven")
			harness.Cleanup()
		end)

		it("treats removing an absent key as the no-op it has always been, not an error", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			data.Inventory[1].Set("a")
			-- Creating either of these would be refused; REMOVING one that was never
			-- there must stay the silent no-op Set(nil) has always been.
			data.Inventory.Sword.Set(nil)
			data.Settings[1].Set(nil)
			expect(data.Inventory.Sword.Get()).to.equal(nil)
			expect(data.Inventory[1].Get()).to.equal("a")
			harness.Cleanup()
		end)

		it("still permits overwriting and removing keys of an ALREADY mixed container", function()
			local harness = TestCtx.make()
			local _, entry, data = harness.Join()
			-- Stand in for a profile loaded from the store already mixed: reach past
			-- the accessor exactly as a pre-guard build would have left it.
			entry.Profile.Data.Inventory[1] = "arr"
			entry.Profile.Data.Inventory.Sword = true
			data.Inventory[1].Set("arr2") -- existing key: still writable
			data.Inventory.Sword.Set(false) -- existing key: still writable
			-- The array half stays GROWABLE while the string key is still there, so the
			-- profile can be drained or migrated instead of being frozen solid.
			data.Inventory[2].Set("arr3")
			data.Inventory.Sword.Set(nil) -- removal: still permitted
			expect(data.Inventory[1].Get()).to.equal("arr2")
			expect(data.Inventory[2].Get()).to.equal("arr3")
			expect(data.Inventory.Sword.Get()).to.equal(nil)
			harness.Cleanup()
		end)
	end)
end
