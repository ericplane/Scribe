--!nonstrict
-- Runtime behavior of Scribe.ArrayOf / Scribe.DictOf / Scribe.Optional: element
-- validation and default fill, closed-shape rejection, array/dict key rules,
-- cardinality caps, datatype packing through the element schema (the reason these
-- declarators exist), and the entry-level listeners.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function template()
		return {
			Coins = Scribe.Int(0, { Min = 0 }),
			Furniture = Scribe.ArrayOf({
				Cf = Scribe.CFrame(CFrame.new()),
				ItemId = Scribe.String("", { MaxLength = 16 }),
				Note = Scribe.Optional(Scribe.String("", { MaxLength = 8 })),
			}, { MaxItems = 3 }),
			Spots = Scribe.ArrayOf(Scribe.Vector3(Vector3.zero)),
			Resources = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 3, MaxKeyLength = 8 }),
			Pets = Scribe.DictOf({
				Level = Scribe.Int(1, { Min = 1, Max = 100 }),
				Home = Scribe.CFrame(CFrame.new()),
			}),
			Loose = {}, -- untyped container: must keep its existing behavior
		}
	end

	local function harnessed(fn)
		local harness = TestCtx.make({ Template = template() })
		local _, _, data = harness.Join()
		local ok, err = pcall(fn, data, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	-- The headless CFrame shim exposes only GetComponents, so compare a component
	-- rather than the value (two equal CFrames are distinct tables under the shim).
	local function cfX(cf)
		return (cf:GetComponents())
	end

	local function expectError(fn, fragment)
		local ok, err = pcall(fn)
		expect(ok).to.equal(false)
		if not string.find(tostring(err), fragment, 1, true) then
			error(`expected error containing "{fragment}", got: {err}`, 0)
		end
	end

	describe("datatypes inside containers", function()
		it("round-trips a datatype element field through Insert and Get", function()
			harnessed(function(data)
				data.Furniture.Insert({ Cf = CFrame.new(1, 2, 3), ItemId = "chair" })
				expect(typeof(data.Furniture[1].Cf.Get())).to.equal("CFrame")
				expect(cfX(data.Furniture[1].Cf.Get())).to.equal(1)
				expect(data.Furniture[1].ItemId.Get()).to.equal("chair")
				-- a container-level read unpacks the whole subtree, no buffers leak
				local all = data.Furniture.Get()
				expect(typeof(all[1].Cf)).to.equal("CFrame")
				expect(cfX(all[1].Cf)).to.equal(1)
			end)
		end)

		it("round-trips a leaf datatype element", function()
			harnessed(function(data)
				data.Spots.Insert(Vector3.new(4, 5, 6))
				expect(typeof(data.Spots[1].Get())).to.equal("Vector3")
				expect(data.Spots[1].Get().Y).to.equal(5)
				expect(data.Spots.Get()[1].Z).to.equal(6)
			end)
		end)

		it("packs a datatype written to a nested element field", function()
			harnessed(function(data)
				data.Pets.Dragon.Home.Set(CFrame.new(9, 9, 9))
				expect(cfX(data.Pets.Dragon.Home.Get())).to.equal(9)
				expect(typeof(data.Pets.Get().Dragon.Home)).to.equal("CFrame")
			end)
		end)

		it("Clone and Default unpack element datatypes", function()
			harnessed(function(data)
				data.Furniture.Insert({ Cf = CFrame.new(7, 0, 0), ItemId = "x" })
				expect(typeof(data.Furniture.Clone()[1].Cf)).to.equal("CFrame")
				expect(typeof(data.Furniture[1].Cf.Default())).to.equal("CFrame")
			end)
		end)

		it("finds and removes a datatype element by value, not by identity", function()
			harnessed(function(data)
				data.Spots.Insert(Vector3.new(1, 1, 1))
				data.Spots.Insert(Vector3.new(2, 2, 2))
				-- a freshly built Vector3 is a different buffer once packed, so this
				-- only works because the search compares packed BYTES
				expect(data.Spots.Find(Vector3.new(2, 2, 2))).to.equal(2)
				expect(data.Spots.Has(Vector3.new(1, 1, 1))).to.equal(true)
				expect(data.Spots.Has(Vector3.new(9, 9, 9))).to.equal(false)

				local removed, index = data.Spots.RemoveValue(Vector3.new(1, 1, 1))
				expect(typeof(removed)).to.equal("Vector3")
				expect(removed.X).to.equal(1)
				expect(index).to.equal(1)
				expect(data.Spots.Count()).to.equal(1)
			end)
		end)

		it("Remove returns an unpacked element", function()
			harnessed(function(data)
				data.Spots.Insert(Vector3.new(3, 3, 3))
				expect(data.Spots.Remove().X).to.equal(3)

				data.Furniture.Insert({ Cf = CFrame.new(5, 0, 0), ItemId = "y" })
				expect(typeof(data.Furniture.Remove().Cf)).to.equal("CFrame")
			end)
		end)
	end)

	describe("element defaults", function()
		it("fills declared fields an Insert omitted", function()
			harnessed(function(data)
				data.Furniture.Insert({ ItemId = "stool" })
				expect(typeof(data.Furniture[1].Cf.Get())).to.equal("CFrame")
				expect(cfX(data.Furniture[1].Cf.Get())).to.equal(0)
				expect(data.Furniture[1].ItemId.Get()).to.equal("stool")
			end)
		end)

		it("leaves an Optional field absent rather than filling it", function()
			harnessed(function(data)
				data.Furniture.Insert({ ItemId = "stool" })
				expect(data.Furniture[1].Note.Get()).to.equal(nil)
				data.Furniture[1].Note.Set("hi")
				expect(data.Furniture[1].Note.Get()).to.equal("hi")
				data.Furniture[1].Note.Set(nil)
				expect(data.Furniture[1].Note.Get()).to.equal(nil)
			end)
		end)

		it("materializes a fresh dict key from the element defaults", function()
			harnessed(function(data)
				data.Pets.Dragon.Level.Set(12)
				expect(data.Pets.Dragon.Level.Get()).to.equal(12)
				-- Home was never written, but the element type says it is present
				expect(typeof(data.Pets.Dragon.Home.Get())).to.equal("CFrame")
			end)
		end)

		it("Increments a fresh dict key from its declared default", function()
			harnessed(function(data)
				expect(data.Resources.Wood.Get()).to.equal(nil)
				expect(data.Resources.Wood.Increment(5)).to.equal(5)
				expect(data.Resources.Wood.Get()).to.equal(5)
			end)
		end)

		it("still enforces element bounds", function()
			local harness = TestCtx.make({ Template = template(), Options = { BoundsPolicy = "Reject" } })
			local _, _, data = harness.Join()
			expectError(function()
				data.Pets.Dragon.Level.Set(500)
			end, "out of bounds")
			harness.Cleanup()
		end)
	end)

	describe("closed element shapes", function()
		it("rejects an undeclared field on Insert", function()
			harnessed(function(data)
				expectError(function()
					data.Furniture.Insert({ ItemId = "chair", Colour = "red" })
				end, "not a declared field")
			end)
		end)

		it("rejects an undeclared field on a whole-container Set", function()
			harnessed(function(data)
				expectError(function()
					data.Furniture.Set({ { ItemId = "chair", Colour = "red" } })
				end, "not a declared field")
			end)
		end)

		it("leaves an untyped container open", function()
			harnessed(function(data)
				data.Loose.Set({ anything = { goes = true } })
				expect(data.Loose.Get().anything.goes).to.equal(true)
			end)
		end)
	end)

	describe("key rules", function()
		it("rejects an out-of-range array index", function()
			harnessed(function(data)
				expectError(function()
					data.Furniture[3].ItemId.Set("hole")
				end, "out of range")
			end)
		end)

		it("allows writing at the append position", function()
			harnessed(function(data)
				data.Furniture[1].ItemId.Set("first")
				expect(data.Furniture.Count()).to.equal(1)
				expect(typeof(data.Furniture[1].Cf.Get())).to.equal("CFrame")
			end)
		end)

		it("rejects a string key on an ArrayOf", function()
			harnessed(function(data)
				expectError(function()
					data.Furniture.nope.ItemId.Set("x")
				end, "takes array indices")
			end)
		end)

		it("rejects a dictionary payload written to an ArrayOf", function()
			harnessed(function(data)
				expectError(function()
					data.Furniture.Set({ slot = { ItemId = "chair" } })
				end, "takes array entries")
			end)
		end)

		it("rejects a ragged array payload", function()
			harnessed(function(data)
				expectError(function()
					data.Furniture.Set({ [1] = { ItemId = "a" }, [3] = { ItemId = "b" } })
				end, "contiguously")
			end)
		end)

		it("rejects Insert on a DictOf", function()
			harnessed(function(data)
				expectError(function()
					data.Pets.Insert({ Level = 2 })
				end, "write a key instead")
			end)
		end)
	end)

	describe("cardinality caps", function()
		it("refuses an Insert past MaxItems", function()
			harnessed(function(data)
				for i = 1, 3 do
					data.Furniture.Insert({ ItemId = `i{i}` })
				end
				expectError(function()
					data.Furniture.Insert({ ItemId = "over" })
				end, "MaxItems 3")
				expect(data.Furniture.Count()).to.equal(3)
			end)
		end)

		it("refuses a whole-container Set past MaxItems", function()
			harnessed(function(data)
				expectError(function()
					data.Furniture.Set({ { ItemId = "a" }, { ItemId = "b" }, { ItemId = "c" }, { ItemId = "d" } })
				end, "over MaxItems 3")
			end)
		end)

		it("refuses a new key past MaxKeys but still allows updating an existing one", function()
			harnessed(function(data)
				data.Resources.Wood.Set(1)
				data.Resources.Stone.Set(2)
				data.Resources.Iron.Set(3)
				expectError(function()
					data.Resources.Gold.Set(4)
				end, "MaxKeys 3")
				data.Resources.Wood.Set(99)
				expect(data.Resources.Wood.Get()).to.equal(99)
			end)
		end)

		it("rejects an over-long dict key rather than truncating it", function()
			harnessed(function(data)
				expectError(function()
					data.Resources.WayTooLongKeyName.Set(1)
				end, "MaxKeyLength 8")
				expect(data.Resources.Count()).to.equal(0)
			end)
		end)
	end)

	describe("entry listeners", function()
		it("hands OnInsert and OnRemove real datatypes", function()
			harnessed(function(data)
				local inserted, removed
				data.Spots.OnInsert(function(value)
					inserted = value
				end)
				data.Spots.OnRemove(function(value)
					removed = value
				end)
				data.Spots.Insert(Vector3.new(1, 2, 3))
				expect(typeof(inserted)).to.equal("Vector3")
				expect(inserted.Y).to.equal(2)
				data.Spots.Remove()
				expect(typeof(removed)).to.equal("Vector3")
			end)
		end)

		it("hands OnKeyAdded a real datatype", function()
			harnessed(function(data)
				local seenKey, seenValue
				data.Pets.OnKeyAdded(function(key, value)
					seenKey, seenValue = key, value
				end)
				data.Pets.Dragon.Set({ Level = 3, Home = CFrame.new(1, 1, 1) })
				expect(seenKey).to.equal("Dragon")
				expect(typeof(seenValue.Home)).to.equal("CFrame")
			end)
		end)

		it("does not hand a listener live authoritative state", function()
			harnessed(function(data)
				local captured
				data.Furniture.OnInsert(function(value)
					captured = value
				end)
				data.Furniture.Insert({ ItemId = "chair" })
				captured.ItemId = "tampered"
				expect(data.Furniture[1].ItemId.Get()).to.equal("chair")
			end)
		end)

		it("Observe on a nested element field reports the unpacked value", function()
			harnessed(function(data)
				data.Furniture.Insert({ Cf = CFrame.new(2, 2, 2), ItemId = "a" })
				local seen
				data.Furniture[1].Cf.Observe(function(value)
					seen = value
				end)
				expect(typeof(seen)).to.equal("CFrame")
				expect(cfX(seen)).to.equal(2)
			end)
		end)
	end)

	describe("persistence", function()
		it("saves and reloads an element datatype", function()
			local harness = TestCtx.make({ Template = template() })
			local player, _, data = harness.Join(70101)
			data.Furniture.Insert({ Cf = CFrame.new(3, 4, 5), ItemId = "lamp" })
			data.Resources.Wood.Increment(7)
			harness.Data.Flush(player)
			harness.Leave(player)

			local _, _, reloaded = harness.Join(70101)
			expect(cfX(reloaded.Furniture[1].Cf.Get())).to.equal(3)
			expect(reloaded.Furniture[1].ItemId.Get()).to.equal("lamp")
			expect(reloaded.Resources.Wood.Get()).to.equal(7)
			harness.Cleanup()
		end)
	end)
end
