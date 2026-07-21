--!nonstrict
-- Regressions found by the adversarial review of the ArrayOf/DictOf/Optional work.
-- Each test pins one confirmed defect; several were reachable from templates using
-- NONE of the new declarators, which is why they are grouped separately below.
return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Template = require(ScribeRoot.Internal.Template)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function expectError(fn, fragment)
		local ok, err = pcall(fn)
		expect(ok).to.equal(false)
		if not string.find(tostring(err), fragment, 1, true) then
			error(`expected error containing "{fragment}", got: {err}`, 0)
		end
	end

	describe("no regression for templates without the new declarators", function()
		it("still hands array listeners the stored entry, so Has/RemoveValue match it", function()
			local template = TestCtx.defaultTemplate()
			template.Queue = {}
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()

			local seenHas, removedIndex
			data.Queue.OnInsert(function(entry)
				seenHas = data.Queue.Has(entry)
				local _, index = data.Queue.RemoveValue(entry)
				removedIndex = index
			end)
			data.Queue.Insert({ Id = "a" })

			expect(seenHas).to.equal(true)
			expect(removedIndex).to.equal(1)
			expect(data.Queue.Count()).to.equal(0)
			harness.Cleanup()
		end)

		it("still lets an OnKeyAdded listener mutate the stored entry", function()
			local template = TestCtx.defaultTemplate()
			template.Bag = {}
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()

			data.Bag.OnKeyAdded(function(_key, item)
				item.Equipped = true
			end)
			data.Bag.Sword.Set({ Equipped = false })

			expect(data.Bag.Sword.Get().Equipped).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("closed element shapes are enforced at the accessor", function()
		-- A nil child schema reads as "untyped" everywhere downstream, so an
		-- undeclared field was a hole straight through every container guard.
		it("refuses an undeclared field at the index, not just at the write", function()
			local template = TestCtx.defaultTemplate()
			template.Pets = Scribe.DictOf({ Level = Scribe.Int(1) }, { MaxKeys = 2, MaxKeyLength = 4 })
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()

			expectError(function()
				data.Pets.dog.Nope.Set(1)
			end, "is not a declared field")

			-- and the caps still hold when the field IS declared
			data.Pets.a.Level.Set(1)
			data.Pets.b.Level.Set(1)
			expectError(function()
				data.Pets.c.Level.Set(1)
			end, "MaxKeys 2")
			expect(data.Pets.Count()).to.equal(2)
			harness.Cleanup()
		end)
	end)

	describe("array contiguity", function()
		it("refuses a nil-Set that would punch a hole", function()
			local template = TestCtx.defaultTemplate()
			template.Nums = Scribe.ArrayOf(Scribe.Int(0, { Min = 0 }))
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()

			data.Nums.Insert(10)
			data.Nums.Insert(20)
			data.Nums.Insert(30)
			expectError(function()
				data.Nums[2].Set(nil)
			end, "must stay contiguous")
			expect(data.Nums.Count()).to.equal(3)
			expect(#data.Nums.Get()).to.equal(3)

			-- clearing the tail keeps the array contiguous, so it is allowed
			data.Nums[3].Set(nil)
			expect(data.Nums.Count()).to.equal(2)
			harness.Cleanup()
		end)
	end)

	describe("search over declared elements", function()
		it("finds a record element by value, using what Get returned", function()
			local template = TestCtx.defaultTemplate()
			template.Furniture = Scribe.ArrayOf({
				Cf = Scribe.CFrame(CFrame.new()),
				ItemId = Scribe.String("", { MaxLength = 16 }),
			})
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()

			data.Furniture.Insert({ Cf = CFrame.new(1, 2, 3), ItemId = "chair" })
			data.Furniture.Insert({ Cf = CFrame.new(4, 5, 6), ItemId = "table" })

			local item = data.Furniture.Get()[2]
			expect(data.Furniture.Has(item)).to.equal(true)
			expect(data.Furniture.Find(item)).to.equal(2)

			local removed, index = data.Furniture.RemoveValue(item)
			expect(index).to.equal(2)
			expect(removed.ItemId).to.equal("table")
			expect(data.Furniture.Count()).to.equal(1)
			harness.Cleanup()
		end)

		it("matches a datatype whose packing is not byte-canonical", function()
			local template = TestCtx.defaultTemplate()
			template.Rots = Scribe.ArrayOf(Scribe.CFrame(CFrame.new()))
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()

			-- a non-axis-aligned rotation takes the lossy quaternion path, so the
			-- value read back does not re-pack to the bytes it came from
			data.Rots.Insert(CFrame.new(1, 2, 3, 0.3826834, 0, 0, 0.9238795))
			local cf = data.Rots[1].Get()
			expect(data.Rots.Has(cf)).to.equal(true)
			expect(data.Rots.Find(cf)).to.equal(1)
			harness.Cleanup()
		end)
	end)

	describe("transactions", function()
		it("prunes an element materialized from non-empty defaults on rollback", function()
			local template = TestCtx.defaultTemplate()
			template.Pets = Scribe.DictOf({
				Level = Scribe.Int(1, { Min = 1, Max = 100 }),
				Name = Scribe.String("", { MaxLength = 8 }),
			})
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()

			local ok = harness.Data.Transaction(player, function()
				data.Pets.dog.Level.Set(5)
				error("boom")
			end)
			expect(ok).to.equal(false)
			expect(data.Pets.Count()).to.equal(0)
			harness.Cleanup()
		end)
	end)

	describe("schema hash", function()
		it("separates templates that differ only in element tree structure", function()
			-- Same preorder node sequence, different nesting: without a structural
			-- fold these collide, and the Hello guard would pass a stale client.
			local a = Template.Compile({
				Pets = Scribe.DictOf({ M = { N = Scribe.Int(0) }, Z = Scribe.Int(0) }),
			}, {})
			local b = Template.Compile({
				Pets = Scribe.DictOf({ M = {}, N = Scribe.Int(0), Z = Scribe.Int(0) }),
			}, {})
			expect(a.Hash).never.to.equal(b.Hash)
		end)
	end)

	describe("element reconcile", function()
		it("backfills a field added to an element shape after profiles exist", function()
			local v1 = TestCtx.defaultTemplate()
			v1.Inventory2 = Scribe.ArrayOf({ ItemId = Scribe.String("", { MaxLength = 32 }) })
			local harness = TestCtx.make({ Template = v1 })
			local player, _, data = harness.Join(72001)
			data.Inventory2.Insert({ ItemId = "axe" })
			harness.Data.Flush(player)
			local persisted = harness.Fake.Persisted["Default/PLAYER_72001"]
			expect(persisted.Inventory2[1].Level).to.equal(nil)
			harness.Cleanup()

			-- v2 adds a field; the stored entry must gain it on the next load.
			local v2 = TestCtx.defaultTemplate()
			v2.Inventory2 = Scribe.ArrayOf({
				ItemId = Scribe.String("", { MaxLength = 32 }),
				Level = Scribe.Int(1, { Min = 1 }),
			})
			local harness2 = TestCtx.make({ Template = v2 })
			harness2.Fake.Persisted["Default/PLAYER_72001"] = persisted
			local _, _, reloaded = harness2.Join(72001)
			expect(reloaded.Inventory2[1].ItemId.Get()).to.equal("axe")
			expect(reloaded.Inventory2[1].Level.Get()).to.equal(1)
			harness2.Cleanup()
		end)

		it("leaves an Optional field absent rather than backfilling it", function()
			local compiled = Template.Compile({
				Rows = Scribe.ArrayOf({
					A = Scribe.Int(1),
					B = Scribe.Optional(Scribe.String("")),
				}),
			}, {})
			local data = { Rows = { {} } }
			expect(Template.ReconcileElements(compiled, data)).to.equal(true)
			expect(data.Rows[1].A).to.equal(1)
			expect(data.Rows[1].B).to.equal(nil)
		end)
	end)

	describe("client mirror", function()
		local RunService = game:GetService("RunService")
		local itRunning = if RunService:IsRunning() then it else itSKIP

		itRunning("does not materialize a ServerOnly element field from its default", function()
			local template = TestCtx.defaultTemplate()
			template.Pets = Scribe.DictOf({
				Level = Scribe.Int(1),
				Secret = Scribe.ServerOnly(Scribe.String("CLASSIFIED-DEFAULT")),
			})
			local harness = TestCtx.make({ Template = template, AutoPump = true })
			local player, entry, data = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			data.Pets.Dragon.Level.Set(5)
			data.Pets.Dragon.Secret.Set("REAL-SECRET")
			harness.Ctx.Replication.FlushEntry(entry)

			expect(clientData.Pets.Dragon.Level.Get()).to.equal(5)
			expect(clientData.Pets.Dragon.Secret.Get()).to.equal(nil)
			expect(clientData.Pets.Get().Dragon.Secret).to.equal(nil)
			harness.Cleanup()
		end)
	end)

	describe("soft-currency purchase through a declared container", function()
		it("still applies the int guard and the Min floor to a DictOf element", function()
			local template = TestCtx.defaultTemplate()
			template.Wallet = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 32 })
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()
			data.Wallet.Coins.Set(100)

			-- a fractional amount on an int currency must be refused
			local ok, err = harness.Data.Purchase(player, {
				Cost = { Path = "Wallet.Coins", Amount = 0.4 },
				Grant = function() end,
			})
			expect(ok).to.equal(false)
			expect(err).to.equal("invalid Cost amount")
			expect(data.Wallet.Coins.Get()).to.equal(100)

			-- and the element's Min floor must still hold
			local ok2 = harness.Data.Purchase(player, {
				Cost = { Path = "Wallet.Coins", Amount = 150 },
				Grant = function() end,
			})
			expect(ok2).to.equal(false)
			expect(data.Wallet.Coins.Get()).to.equal(100)
			harness.Cleanup()
		end)
	end)
end
