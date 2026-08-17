--!nonstrict
-- Cached unpacked read views for packed subtrees.
--
-- A container holding a Scribe.CFrame, a Scribe.Big or any datatype below it is
-- STORED packed and has to be rebuilt key by key to be read. That rebuild ran on
-- every Get, every container Changed fire and every root Observe fire, so a
-- template with a few thousand packed elements paid milliseconds per write --
-- including writes to a completely unrelated field.
--
-- The rebuild is now cached per path. The entire risk of that is a STALE read:
-- silently handing back data that no longer matches the store. Every mutation
-- shape that could produce one gets a test here, and each asserts the value a
-- reader sees, never the cache itself.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function packedHarness()
		return TestCtx.make({
			Template = {
				Tick = Scribe.Int(0),
				Spots = Scribe.ArrayOf({ Cf = Scribe.CFrame(CFrame.new()), Id = Scribe.Int(0) }),
				Bank = Scribe.DictOf(Scribe.Big(0)),
			},
		})
	end

	local function seed(data, n: number)
		for i = 1, n do
			data.Spots.Insert({ Cf = CFrame.new(i, 0, 0), Id = i })
		end
	end

	describe("staleness", function()
		it("reflects a write to a leaf INSIDE the container", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 4)
			expect(data.Spots.Get()[2].Id).to.equal(2)

			data.Spots[2].Id.Set(99)
			expect(data.Spots.Get()[2].Id).to.equal(99)

			harness.Cleanup()
		end)

		it("unpacks a DATATYPE leaf in the view, and re-unpacks it after a write", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 3)
			-- The STORED form is a packed buffer; a view handing that back would be
			-- the cache leaking the wire shape to callers.
			expect(typeof(data.Spots.Get()[1].Cf)).to.equal("CFrame")

			local before = data.Spots.Get()[1].Cf
			data.Spots[1].Cf.Set(CFrame.new(77, 0, 0))
			local after = data.Spots.Get()[1].Cf
			expect(typeof(after)).to.equal("CFrame")
			-- A stale view would hand back the very same unpacked object.
			expect(rawequal(before, after)).to.equal(false)

			harness.Cleanup()
		end)

		it("reflects a whole-container Set (a different table entirely)", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 4)
			expect(#data.Spots.Get()).to.equal(4)

			data.Spots.Set({ { Cf = CFrame.new(9, 0, 0), Id = 9 } })
			local after = data.Spots.Get()
			expect(#after).to.equal(1)
			expect(after[1].Id).to.equal(9)

			harness.Cleanup()
		end)

		it("reflects a Clear, which empties the SAME table in place", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 4)
			expect(#data.Spots.Get()).to.equal(4)

			data.Spots.Clear()
			expect(#data.Spots.Get()).to.equal(0)

			harness.Cleanup()
		end)

		it("reflects Insert and Remove", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 2)
			expect(#data.Spots.Get()).to.equal(2)

			data.Spots.Insert({ Cf = CFrame.new(3, 0, 0), Id = 3 })
			expect(#data.Spots.Get()).to.equal(3)
			expect(data.Spots.Get()[3].Id).to.equal(3)

			data.Spots.Remove(1)
			expect(#data.Spots.Get()).to.equal(2)
			expect(data.Spots.Get()[1].Id).to.equal(2)

			harness.Cleanup()
		end)

		it("reflects a Big write through a dictionary", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			data.Bank.gold.Set(1000)
			expect(data.Bank.Get().gold:ToNumber()).to.equal(1000)

			data.Bank.gold.Set(5000)
			expect(data.Bank.Get().gold:ToNumber()).to.equal(5000)

			harness.Cleanup()
		end)

		it("reflects a rolled-back transaction", function()
			local harness = packedHarness()
			local player, _, data = harness.Join()
			seed(data, 3)
			expect(data.Spots.Get()[1].Id).to.equal(1)

			local ok = harness.Data.Transaction(player, function()
				data.Spots[1].Id.Set(555)
				-- Read INSIDE the transaction so a view of the mid-txn state is cached
				-- before the rollback undoes it.
				expect(data.Spots.Get()[1].Id).to.equal(555)
				error("rollback")
			end)
			expect(ok).to.equal(false)
			expect(data.Spots.Get()[1].Id).to.equal(1)

			harness.Cleanup()
		end)

		it("gives a root Observe the CURRENT packed data on every fire", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 3)

			local seen = {}
			data.Observe(function(all)
				table.insert(seen, all.Spots[1].Id)
			end)
			data.Spots[1].Id.Set(42)
			data.Tick.Set(1) -- unrelated: Spots must still read correctly

			expect(seen[1]).to.equal(1) -- immediate call
			expect(seen[#seen]).to.equal(42)

			harness.Cleanup()
		end)

		it("keeps two different packed paths independent", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 2)
			data.Bank.gold.Set(7)

			expect(data.Spots.Get()[1].Id).to.equal(1)
			expect(data.Bank.Get().gold:ToNumber()).to.equal(7)

			-- Writing one must not disturb the other's view.
			data.Bank.gold.Set(8)
			expect(data.Spots.Get()[1].Id).to.equal(1)
			expect(data.Bank.Get().gold:ToNumber()).to.equal(8)

			harness.Cleanup()
		end)
	end)

	describe("shared view safety", function()
		it("hands back a frozen view, so an edit raises instead of leaking to later reads", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 2)

			local view = data.Spots.Get()
			expect(function()
				view[1] = { Cf = CFrame.new(), Id = 123 }
			end).to.throw()
			-- And the store is untouched by the attempt.
			expect(data.Spots.Get()[1].Id).to.equal(1)

			harness.Cleanup()
		end)

		it("still hands Clone a mutable, independent copy", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 2)

			local copy = data.Spots.Clone()
			copy[1].Id = 777 -- Clone is the documented mutable copy; must not throw
			expect(data.Spots.Get()[1].Id).to.equal(1)

			harness.Cleanup()
		end)

		it("lets Update mutate the value handed to its callback", function()
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 2)

			data.Spots.Update(function(current)
				current[1].Id = 321
				return current
			end)
			expect(data.Spots.Get()[1].Id).to.equal(321)

			harness.Cleanup()
		end)
	end)

	-- The cache holds a full unpacked COPY of each subtree it stores, so what it
	-- RELEASES matters as much as what it caches. It is weak-keyed by the stored
	-- table, which makes an orphaned subtree collectable -- but collectable is not
	-- collected, and nothing promises when a GC pass runs, so every operation that
	-- discards a subtree evicts eagerly too. These specs pin that, and the size
	-- gate that keeps many-small-reads from retaining anything at all.
	describe("retention", function()
		local function entryCount(entry): number
			local n = 0
			for _ in entry.Tree._unpacked do
				n += 1
			end
			return n
		end

		local function bagsHarness()
			local harness = TestCtx.make({
				Template = {
					Bags = Scribe.DictOf(Scribe.ArrayOf({ Cf = Scribe.CFrame(CFrame.new()), Id = Scribe.Int(0) })),
				},
			})
			local _, entry, data = harness.Join()
			for b = 1, 6 do
				local items = {}
				for i = 1, 100 do
					items[i] = { Cf = CFrame.new(i, 0, 0), Id = i }
				end
				data.Bags["b" .. b].Set(items)
				data.Bags["b" .. b].Get() -- cache each one
			end
			return harness, entry, data
		end

		it("caches nothing for many small packed reads", function()
			local harness = TestCtx.make({
				Template = { Items = Scribe.DictOf({ Cf = Scribe.CFrame(CFrame.new()), Id = Scribe.Int(0) }) },
			})
			local _, entry, data = harness.Join()
			for i = 1, 200 do
				data.Items["i" .. i].Set({ Cf = CFrame.new(i, 0, 0), Id = i })
			end
			for i = 1, 200 do
				data.Items["i" .. i].Get()
			end
			-- Each record is a couple of fields: rebuilding one is cheap, so storing
			-- 200 copies would be pure overhead. The size gate refuses them.
			expect(entryCount(entry)).to.equal(0)

			harness.Cleanup()
		end)

		it("releases every cached view when the container is cleared", function()
			local harness, entry, data = bagsHarness()
			expect(entryCount(entry) > 0).to.equal(true)
			data.Bags.Clear()
			expect(entryCount(entry)).to.equal(0)
			harness.Cleanup()
		end)

		it("releases them when the container is replaced wholesale", function()
			local harness, entry, data = bagsHarness()
			expect(entryCount(entry) > 0).to.equal(true)
			data.Bags.Set({})
			expect(entryCount(entry)).to.equal(0)
			harness.Cleanup()
		end)

		it("releases them when each subtree is removed", function()
			local harness, entry, data = bagsHarness()
			expect(entryCount(entry) > 0).to.equal(true)
			for b = 1, 6 do
				data.Bags["b" .. b].Set(nil)
			end
			expect(entryCount(entry)).to.equal(0)
			harness.Cleanup()
		end)

		it("drops everything when the tree is destroyed", function()
			local harness, entry = bagsHarness()
			expect(entryCount(entry) > 0).to.equal(true)
			entry.Tree:Destroy()
			expect(entryCount(entry)).to.equal(0)
			harness.Cleanup()
		end)
	end)

	describe("cost", function()
		it("does not rebuild the container for a write to an unrelated field", function()
			-- Shape, not wall-clock. Rebuilding 4,000 packed elements per write is
			-- orders of magnitude dearer than not doing it, so a generous bound still
			-- fails decisively if the cache stops working.
			local harness = packedHarness()
			local _, _, data = harness.Join()
			seed(data, 4000)
			data.Observe(function() end) -- forces a full root read on every write

			data.Tick.Set(0)
			local t0 = os.clock()
			for i = 1, 20 do
				data.Tick.Set(i)
			end
			local perWrite = (os.clock() - t0) / 20

			-- A rebuild of 4,000 packed elements measured ~9 ms; cached is ~0.01 ms.
			expect(perWrite < 0.002).to.equal(true)

			harness.Cleanup()
		end)
	end)
end
