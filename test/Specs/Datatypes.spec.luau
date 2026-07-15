--!nonstrict
-- Roblox datatype serialization: declared fields store a compact packed buffer
-- (persistence/replication only see buffers); accessors convert at the
-- boundary. Opt-in per field.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local Datatypes = Scribe.Datatypes

	local function reencodesIdentically(name, value)
		local packed = Datatypes.Pack(name, value)
		local roundTripped = Datatypes.Pack(name, Datatypes.Unpack(name, packed))
		expect(buffer.tostring(roundTripped)).to.equal(buffer.tostring(packed))
		return packed
	end

	describe("codecs", function()
		it("round-trips every supported type", function()
			reencodesIdentically("Vector3", Vector3.new(1.5, -2.25, 300))
			reencodesIdentically("Vector2", Vector2.new(0.5, -9))
			reencodesIdentically("Vector3int16", Vector3int16.new(-100, 200, 32000))
			reencodesIdentically("Vector2int16", Vector2int16.new(7, -8))
			reencodesIdentically("CFrame", CFrame.new(10, 20, 30))
			reencodesIdentically("Color3", Color3.fromRGB(255, 120, 0))
			reencodesIdentically("BrickColor", BrickColor.new(1004))
			reencodesIdentically("UDim", UDim.new(0.5, -20))
			reencodesIdentically("UDim2", UDim2.new(0.25, 10, 0.75, -30))
			reencodesIdentically("Rect", Rect.new(Vector2.new(0, 0), Vector2.new(100, 50)))
			reencodesIdentically("NumberRange", NumberRange.new(2, 8))
			reencodesIdentically("NumberSequence", NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1, 0.5),
				NumberSequenceKeypoint.new(1, 0),
			}))
			reencodesIdentically("ColorSequence", ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 255)),
			}))
			reencodesIdentically("DateTime", DateTime.fromUnixTimestampMillis(1782600000123))
			reencodesIdentically("EnumItem", Enum.Material.Plastic)
			reencodesIdentically("Font", Font.new("rbxasset://fonts/families/GothamSSm.json"))
			reencodesIdentically("PhysicalProperties", PhysicalProperties.new(0.7, 0.3, 0.5, 1, 1))
		end)

		it("packs compactly", function()
			expect(buffer.len(Datatypes.Pack("Vector3", Vector3.new(1, 2, 3)))).to.equal(12)
			expect(buffer.len(Datatypes.Pack("Vector2int16", Vector2int16.new(1, 2)))).to.equal(4)
			expect(buffer.len(Datatypes.Pack("BrickColor", BrickColor.new(1004)))).to.equal(2)
			-- Axis-aligned CFrame rotations cost one byte.
			expect(buffer.len(Datatypes.Pack("CFrame", CFrame.new(5, 10, 15)))).to.equal(13)
			-- Arbitrary rotations fall back to a quaternion.
			local tilted = CFrame.new(1, 2, 3, 0.3826834, 0, 0, 0.9238795) -- 45 degrees about X
			expect(buffer.len(Datatypes.Pack("CFrame", tilted))).to.equal(29)
			-- Exact fromRGB colors pack to 4 bytes; arbitrary floats to 13.
			expect(buffer.len(Datatypes.Pack("Color3", Color3.fromRGB(12, 34, 56)))).to.equal(4)
			expect(buffer.len(Datatypes.Pack("Color3", Color3.new(0.12345, 0.5, 0.9)))).to.equal(13)
		end)

		it("preserves arbitrary CFrame rotations through the quaternion path", function()
			local tilted = CFrame.new(1, 2, 3, 0.3826834, 0, 0, 0.9238795)
			local unpacked = Datatypes.Unpack("CFrame", Datatypes.Pack("CFrame", tilted))
			local a = { tilted:GetComponents() }
			local b = { unpacked:GetComponents() }
			for i = 1, 12 do
				expect(math.abs(a[i] - b[i]) < 1e-3).to.equal(true)
			end
		end)

		it("rejects unsupported datatype names", function()
			expect(function()
				Datatypes.Pack("Region3", nil)
			end).to.throw()
		end)
	end)

	describe("declared fields", function()
		local function makeHarness()
			local template = TestCtx.defaultTemplate()
			template.SpawnPoint = Scribe.Vector3(Vector3.new(0, 5, 0))
			template.HouseDoor = Scribe.CFrame(CFrame.new(1, 2, 3))
			template.Tint = Scribe.Color3(Color3.fromRGB(255, 120, 0))
			return TestCtx.make({ Template = template })
		end

		it("exposes datatypes at the boundary, stores packed buffers", function()
			local harness = makeHarness()
			local player, entry, data = harness.Join(6100)

			-- Defaults unpack to the declared datatype.
			local spawn = data.SpawnPoint.Get()
			expect(typeof(spawn)).to.equal("Vector3")
			expect(spawn.Y).to.equal(5)

			-- Set accepts the datatype and rejects everything else.
			data.SpawnPoint.Set(Vector3.new(10, 0, 30))
			expect(data.SpawnPoint.Get().X).to.equal(10)
			expect(function()
				data.SpawnPoint.Set(5)
			end).to.throw()
			expect(function()
				data.SpawnPoint.Set(CFrame.new())
			end).to.throw()

			-- Update and Changed see unpacked values.
			local observed = nil
			data.SpawnPoint.Changed(function(newValue)
				observed = newValue
			end)
			data.SpawnPoint.Update(function(current)
				expect(typeof(current)).to.equal("Vector3")
				return Vector3.new(current.X + 1, current.Y, current.Z)
			end)
			expect(data.SpawnPoint.Get().X).to.equal(11)
			expect(typeof(observed)).to.equal("Vector3")
			expect(observed.X).to.equal(11)

			-- Profile data only ever holds the packed form.
			expect(type(entry.LiveData.SpawnPoint)).to.equal("buffer")
			expect(buffer.len(entry.LiveData.SpawnPoint)).to.equal(12)
			expect(type(entry.LiveData.HouseDoor)).to.equal("buffer")

			-- Persists and reloads.
			harness.Data.Flush(player)
			local persisted = harness.Fake.Persisted["Default/PLAYER_6100"]
			expect(type(persisted.SpawnPoint)).to.equal("buffer")
			harness.Leave(player)
			local _, _, data2 = harness.Join(6100)
			expect(data2.SpawnPoint.Get().X).to.equal(11)
			expect(typeof(data2.Tint.Get())).to.equal("Color3")

			harness.Cleanup()
		end)

		it("replicates the packed form over the wire", function()
			local harness = makeHarness()
			local player, entry, data = harness.Join(6200)
			harness.SendHello(player)

			data.SpawnPoint.Set(Vector3.new(7, 8, 9))
			harness.Ctx.Replication.FlushEntry(entry)

			local diffs = harness.FramesFor(player, Wire.Frames.Diff)
			local op = diffs[#diffs].Ops[1]
			expect(op.Path[1]).to.equal("SpawnPoint")
			expect(type(op.Value)).to.equal("buffer")
			expect(buffer.tostring(op.Value)).to.equal(
				buffer.tostring(Scribe.Datatypes.Pack("Vector3", Vector3.new(7, 8, 9)))
			)

			harness.Cleanup()
		end)

		it("rejects non-datatype defaults at compile time", function()
			expect(function()
				TestCtx.make({ Template = { Bad = Scribe.Vector3(5 :: any) } })
			end).to.throw()
		end)
	end)
end
