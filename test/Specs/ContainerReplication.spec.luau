--!nonstrict
-- Replication of Scribe.ArrayOf / Scribe.DictOf element schemas.
--
-- The load-bearing case is the ServerOnly leak: Template.CloneVisible resolves
-- children through node.Children, which a container node does not have, so every
-- entry used to be deep-cloned WHOLESALE. The per-op Insert path strips correctly
-- while a whole-container Set does not, so the leak is asymmetric and a test that
-- only exercises Insert would pass while secrets ship to the client.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Wire = require(ScribeRoot.Internal.Wire)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local function withServerOnlyElement()
		local template = TestCtx.defaultTemplate()
		template.Rows = Scribe.ArrayOf({
			Public = Scribe.Int(0),
			Secret = Scribe.ServerOnly(Scribe.String("")),
		})
		template.Keyed = Scribe.DictOf({
			Public = Scribe.Int(0),
			Secret = Scribe.ServerOnly(Scribe.String("")),
		})
		return template
	end

	describe("ServerOnly inside an element shape", function()
		it("strips it from a whole-container Set diff", function()
			local harness = TestCtx.make({ Template = withServerOnlyElement() })
			local player, entry, data = harness.Join()
			harness.SendHello(player)

			data.Rows.Set({ { Public = 1, Secret = "classified" } })
			harness.Ctx.Replication.FlushEntry(entry)

			expect(data.Rows[1].Secret.Get()).to.equal("classified")
			local diffs = harness.FramesFor(player, Wire.Frames.Diff)
			local op = diffs[#diffs].Ops[1]
			expect(op.Path[1]).to.equal("Rows")
			expect(op.Value[1].Public).to.equal(1)
			expect(op.Value[1].Secret).to.equal(nil)

			harness.Cleanup()
		end)

		it("strips it from an Insert op", function()
			local harness = TestCtx.make({ Template = withServerOnlyElement() })
			local player, entry, data = harness.Join()
			harness.SendHello(player)

			data.Rows.Insert({ Public = 2, Secret = "classified" })
			harness.Ctx.Replication.FlushEntry(entry)

			local diffs = harness.FramesFor(player, Wire.Frames.Diff)
			local op = diffs[#diffs].Ops[1]
			expect(op.Value.Public).to.equal(2)
			expect(op.Value.Secret).to.equal(nil)

			harness.Cleanup()
		end)

		it("strips it from a DictOf whole-container Set", function()
			local harness = TestCtx.make({ Template = withServerOnlyElement() })
			local player, entry, data = harness.Join()
			harness.SendHello(player)

			data.Keyed.Set({ alpha = { Public = 3, Secret = "classified" } })
			harness.Ctx.Replication.FlushEntry(entry)

			local diffs = harness.FramesFor(player, Wire.Frames.Diff)
			local op = diffs[#diffs].Ops[1]
			expect(op.Value.alpha.Public).to.equal(3)
			expect(op.Value.alpha.Secret).to.equal(nil)

			harness.Cleanup()
		end)

		it("strips it from the Init snapshot", function()
			local harness = TestCtx.make({ Template = withServerOnlyElement() })
			local player, entry, data = harness.Join()
			data.Rows.Set({ { Public = 4, Secret = "classified" } })
			harness.Ctx.Replication.FlushEntry(entry)
			harness.SendHello(player)

			local inits = harness.FramesFor(player, Wire.Frames.Init)
			expect(#inits > 0).to.equal(true)
			local sawRows = false
			for _, op in inits[#inits].Ops do
				if op.Path[1] == "Rows" then
					sawRows = true
					expect(op.Value[1].Public).to.equal(4)
					expect(op.Value[1].Secret).to.equal(nil)
				end
			end
			expect(sawRows).to.equal(true)

			harness.Cleanup()
		end)

		it("strips it from a Shared-root broadcast", function()
			local template = TestCtx.defaultTemplate()
			template.Board = Scribe.Shared({
				Rows = Scribe.ArrayOf({ Public = Scribe.Int(0), Secret = Scribe.ServerOnly(Scribe.String("")) }),
			})
			local harness = TestCtx.make({ Template = template })

			local playerA, entryA, dataA = harness.Join(61001)
			harness.SendHello(playerA)
			dataA.Board.Rows.Set({ { Public = 5, Secret = "classified" } })
			harness.Ctx.Replication.FlushEntry(entryA)

			local playerB = harness.Join(61002)
			harness.SendHello(playerB)

			local found = false
			for _, frame in harness.FramesFor(playerB, Wire.Frames.SharedInit) do
				if frame.UserId == 61001 then
					for _, op in frame.Ops do
						if op.Path[1] == "Board" then
							found = true
							expect(op.Value.Rows[1].Public).to.equal(5)
							expect(op.Value.Rows[1].Secret).to.equal(nil)
						end
					end
				end
			end
			expect(found).to.equal(true)

			harness.Cleanup()
		end)
	end)

	describe("element datatypes over the wire", function()
		itRunning("round-trips a nested element datatype to the client mirror", function()
			local template = TestCtx.defaultTemplate()
			template.Plots = Scribe.ArrayOf({
				Name = Scribe.String("", { MaxLength = 32 }),
				Rooms = Scribe.ArrayOf({ Origin = Scribe.CFrame(CFrame.new()) }),
			})
			template.Pets = Scribe.DictOf({ Home = Scribe.CFrame(CFrame.new()) })

			local harness = TestCtx.make({ Template = template, AutoPump = true })
			local player, entry, data = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			data.Plots.Insert({ Name = "Home" })
			data.Plots[1].Rooms.Insert({ Origin = CFrame.new(3, 4, 5) })
			data.Pets.Dragon.Home.Set(CFrame.new(6, 7, 8))
			harness.Ctx.Replication.FlushEntry(entry)

			local origin = clientData.Plots[1].Rooms[1].Origin.Get()
			expect(typeof(origin)).to.equal("CFrame")
			expect((origin:GetComponents())).to.equal(3)

			local home = clientData.Pets.Dragon.Home.Get()
			expect(typeof(home)).to.equal("CFrame")
			expect((home:GetComponents())).to.equal(6)

			-- a container-level client read must not leak packed buffers either
			expect(typeof(clientData.Plots.Get()[1].Rooms[1].Origin)).to.equal("CFrame")

			harness.Cleanup()
		end)
	end)
end
