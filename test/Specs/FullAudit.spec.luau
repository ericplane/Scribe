--!nonstrict
-- Regressions from the full-module audit. Each test pins one confirmed defect.
-- Grouped by subsystem; several defects were reachable from templates using none
-- of the container declarators.
return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Template = require(ScribeRoot.Internal.Template)
	local Util = require(ScribeRoot.Internal.Util)
	local Wire = require(ScribeRoot.Internal.Wire)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local RunService = game:GetService("RunService")
	local itRunning = if RunService:IsRunning() then it else itSKIP

	local function expectError(fn, fragment)
		local ok, err = pcall(fn)
		expect(ok).to.equal(false)
		if not string.find(tostring(err), fragment, 1, true) then
			error(`expected error containing "{fragment}", got: {err}`, 0)
		end
	end

	describe("remote apply safety", function()
		it("applies an old-server style op that must materialize past a cap without throwing", function()
			-- A stream from a server WITHOUT explicit element-seed ops (an older
			-- Scribe) can ask a mirror to materialize an element while the mirror's
			-- state appears to have no room. Remote applies are trusted; they must
			-- never throw mid-frame. Tree.ApplyOp is exactly the mirror's apply path.
			local template = TestCtx.defaultTemplate()
			template.Pets = Scribe.DictOf({ Level = Scribe.Int(1) }, { MaxKeys = 2 })
			local harness = TestCtx.make({ Template = template })
			local _, entry, data = harness.Join()
			data.Pets.a.Level.Set(2)
			data.Pets.b.Level.Set(2)

			local tree = entry.Tree
			local ok, err = pcall(function()
				tree:ApplyOp({ Kind = "Set", Path = { "Pets", "c", "Level" }, Value = 5 })
			end)
			expect(ok).to.equal(true)
			if not ok then
				error(tostring(err), 0)
			end
			expect(data.Pets.c.Level.Get()).to.equal(5)
			harness.Cleanup()
		end)

		itRunning("applies a compacted remove-then-recreate flush to a mirror at MaxKeys cap", function()
			local template = TestCtx.defaultTemplate()
			template.Pets = Scribe.DictOf({ Level = Scribe.Int(1) }, { MaxKeys = 2 })
			local harness = TestCtx.make({ Template = template, AutoPump = true })
			local player, entry, data = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			data.Pets.a.Level.Set(2)
			data.Pets.b.Level.Set(2)
			harness.Ctx.Replication.FlushEntry(entry)
			expect(clientData.Pets.Count()).to.equal(2)

			-- One flush: remove a, add c, remove b, re-add a. Compaction drops the
			-- first removal (superseded by the later re-add), so the mirror must
			-- materialize c while it still holds {a, b}, at its cap. That must not
			-- throw inside the frame apply.
			data.Pets.Remove("a")
			data.Pets.c.Level.Set(5)
			data.Pets.Remove("b")
			data.Pets.a.Set({ Level = 9 })
			harness.Ctx.Replication.FlushEntry(entry)

			expect(clientData.Pets.Count()).to.equal(2)
			expect(clientData.Pets.c.Level.Get()).to.equal(5)
			expect(clientData.Pets.a.Level.Get()).to.equal(9)
			expect(clientData.Pets.b.Get()).to.equal(nil)
			harness.Cleanup()
		end)
	end)

	describe("materialization visibility", function()
		it("replicates a dict entry created by a leaf write equal to the element default", function()
			local template = TestCtx.defaultTemplate()
			template.Pets = Scribe.DictOf({ Level = Scribe.Int(1) })
			local harness = TestCtx.make({ Template = template })
			local player, entry, data = harness.Join()
			harness.SendHello(player)

			local addedKey
			data.Pets.OnKeyAdded(function(key)
				addedKey = key
			end)
			-- 1 is the declared default: the write itself no-ops, but the entry is
			-- real persisted state and must replicate and fire OnKeyAdded.
			data.Pets.a.Level.Set(1)
			harness.Ctx.Replication.FlushEntry(entry)

			expect(data.Pets.Count()).to.equal(1)
			expect(addedKey).to.equal("a")
			local diffs = harness.FramesFor(player, Wire.Frames.Diff)
			expect(#diffs > 0).to.equal(true)
			harness.Cleanup()
		end)

		itRunning("gives a Shared mirror the full element, not a bare partial", function()
			local template = TestCtx.defaultTemplate()
			template.Board = Scribe.Shared(Scribe.DictOf({
				Name = Scribe.String("sword"),
				Level = Scribe.Int(1),
			}))
			local harness = TestCtx.make({ Template = template, AutoPump = true })

			local playerA, entryA, dataA = harness.Join(63001)
			harness.SendHello(playerA)

			local playerB = harness.Join(63002)
			harness.Transport.LocalPlayer = playerB
			local clientB = Client.new(harness.Options, harness.Compiled)

			-- A brand-new key written through one leaf: the element materializes
			-- server-side from its defaults, and B's plain mirror (which applies ops
			-- with no schema) must reconstruct the SAME full element.
			dataA.Board.k1.Level.Set(5)
			harness.Ctx.Replication.FlushEntry(entryA)

			local shared = clientB.GetShared(63001)
			expect(shared.Board.k1.Level).to.equal(5)
			expect(shared.Board.k1.Name).to.equal("sword")
			harness.Cleanup()
		end)
	end)

	describe("write-path hardening", function()
		it("rejects a ragged array payload that fools the # operator", function()
			local template = TestCtx.defaultTemplate()
			template.Tags = Scribe.ArrayOf(Scribe.String(""))
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()
			expectError(function()
				-- array part {a,nil,b} has a border at 3, [5] hides in the hash part,
				-- so count == # even though the payload is ragged
				-- selene: allow(mixed_table) -- the ragged shape IS the test input
				data.Tags.Set({ "a", nil, "b", [5] = "c" })
			end, "contiguously")
			expect(data.Tags.Count()).to.equal(0)
			harness.Cleanup()
		end)

		it("rejects Insert(nil) and a non-integer Insert position", function()
			local template = TestCtx.defaultTemplate()
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()
			expectError(function()
				data.Quests.Insert(nil)
			end, "cannot Insert nil")
			expectError(function()
				data.Quests.Insert(1, 0 / 0)
			end, "must be an integer")
			harness.Cleanup()
		end)

		it("rejects deleting a declared non-Optional element field", function()
			local template = TestCtx.defaultTemplate()
			template.Rows = Scribe.ArrayOf({
				Id = Scribe.String("x"),
				Note = Scribe.Optional(Scribe.String("")),
			})
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()
			data.Rows.Insert({ Id = "a", Note = "hi" })
			expectError(function()
				data.Rows[1].Id.Set(nil)
			end, "declared element field")
			-- Optional fields keep nil-Set
			data.Rows[1].Note.Set(nil)
			expect(data.Rows[1].Note.Get()).to.equal(nil)
			-- removing the whole element stays legal
			expect(data.Rows.Remove(1).Id).to.equal("a")
			harness.Cleanup()
		end)

		it("errors loudly for Find/Has/RemoveValue on a DictOf", function()
			local template = TestCtx.defaultTemplate()
			template.Wallet = Scribe.DictOf(Scribe.Int(0))
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()
			data.Wallet.gold.Set(5)
			expectError(function()
				data.Wallet.Has(5)
			end, "is keyed")
			harness.Cleanup()
		end)

		it("rejects mixing array indices and string keys in one write", function()
			local template = TestCtx.defaultTemplate()
			template.Blob = {}
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()
			expectError(function()
				data.Blob.Set({ [1] = "a", name = "b" })
			end, "cannot mix")
			harness.Cleanup()
		end)

		it("starts Increment and Toggle of fresh element-record fields from their defaults", function()
			local template = TestCtx.defaultTemplate()
			template.Pets = Scribe.DictOf({
				Level = Scribe.Int(3, { Min = 1 }),
				Fed = false,
			})
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()
			-- fresh key, field INSIDE the element record (not an element-root leaf)
			expect(data.Pets.dog.Level.Increment(2)).to.equal(5)
			expect(data.Pets.cat.Fed.Toggle()).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("rolling-deploy tolerance", function()
		it("lets a whole-container rewrite carry an unknown-but-stored element field", function()
			-- v2 saved an element with a field this (older) template does not declare.
			local template = TestCtx.defaultTemplate()
			template.Furniture = Scribe.ArrayOf({ Id = Scribe.String("", { MaxLength = 16 }) })
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join(64001)
			data.Furniture.Insert({ Id = "chair" })
			-- simulate the newer server's write landing in storage
			local entry = harness.Ctx.Persistence.Entries[player]
			entry.LiveData.Furniture[1].Note = "from-v2"

			-- identity rewrite (Get -> Set) must not throw and must keep the field
			data.Furniture.Set(data.Furniture.Get())
			expect(data.Furniture[1].Get().Note).to.equal("from-v2")

			-- a genuinely unknown field (not in storage) is still a typo
			expectError(function()
				data.Furniture.Set({ { Id = "x", Colour = "red" } })
			end, "not a declared field")
			harness.Cleanup()
		end)
	end)

	describe("transactions", function()
		it("drops economy events from a rolled-back transaction", function()
			local events = {}
			local harness = TestCtx.make({
				Options = {
					Economy = {
						LogEconomyEvent = function(_player, _flow, _currency, amount)
							table.insert(events, amount)
						end,
					},
				},
			})
			local player, _, data = harness.Join()

			local ok = harness.Data.Transaction(player, function()
				data.Coins.Increment(50, { Source = "Test" })
				error("boom")
			end)
			expect(ok).to.equal(false)
			expect(data.Coins.Get()).to.equal(0)
			expect(#events).to.equal(0)

			-- and a committed transaction still emits
			harness.Data.Transaction(player, function()
				data.Coins.Increment(25, { Source = "Test" })
			end)
			expect(#events).to.equal(1)
			harness.Cleanup()
		end)
	end)

	describe("ReconcileElements depth", function()
		it("backfills a field added to a nested sub-record of an element", function()
			local compiled = Template.Compile({
				Rows = Scribe.ArrayOf({
					Sub = { A = Scribe.Int(1), B = Scribe.Int(2) },
				}),
			}, {})
			local data = { Rows = { { Sub = { A = 9 } } } }
			expect(Template.ReconcileElements(compiled, data)).to.equal(true)
			expect(data.Rows[1].Sub.A).to.equal(9)
			expect(data.Rows[1].Sub.B).to.equal(2)
		end)

		it("backfills through a container nested inside an element", function()
			local compiled = Template.Compile({
				Plots = Scribe.ArrayOf({
					Rooms = Scribe.ArrayOf({ Name = Scribe.String("room"), Size = Scribe.Int(4) }),
				}),
			}, {})
			local data = { Plots = { { Rooms = { { Name = "kitchen" } } } } }
			expect(Template.ReconcileElements(compiled, data)).to.equal(true)
			expect(data.Plots[1].Rooms[1].Name).to.equal("kitchen")
			expect(data.Plots[1].Rooms[1].Size).to.equal(4)
		end)

		it("backfills entries of a container that IS the element", function()
			local compiled = Template.Compile({
				Grid = Scribe.DictOf(Scribe.ArrayOf({ V = Scribe.Int(7) })),
			}, {})
			local data = { Grid = { row1 = { {} } } }
			expect(Template.ReconcileElements(compiled, data)).to.equal(true)
			expect(data.Grid.row1[1].V).to.equal(7)
		end)
	end)

	describe("reconcile ordering", function()
		it("lets a guarded rename migration observe the raw stored element data", function()
			local v1 = TestCtx.defaultTemplate()
			v1.Inv = Scribe.ArrayOf({ Dmg = Scribe.Int(1) })
			local harness = TestCtx.make({ Template = v1 })
			local player, _, data = harness.Join(65001)
			data.Inv.Insert({ Dmg = 40 })
			harness.Data.Flush(player)
			local persisted = harness.Fake.Persisted["Default/PLAYER_65001"]
			harness.Cleanup()

			-- v2 renames Dmg -> Damage with the common defensive migration form. If
			-- element reconcile ran BEFORE the migration, Damage would already be
			-- backfilled to 1 and the guard would destroy the player's 40.
			local v2 = TestCtx.defaultTemplate()
			v2.Inv = Scribe.ArrayOf({ Damage = Scribe.Int(1) })
			local seen
			local harness2 = TestCtx.make({
				Template = v2,
				Options = {
					Migrations = {
						[2] = function(migrated)
							for _, item in migrated.Inv or {} do
								seen = item.Damage
								if item.Damage == nil then
									item.Damage = item.Dmg
								end
								item.Dmg = nil
							end
						end,
					},
				},
			})
			harness2.Fake.Persisted["Default/PLAYER_65001"] = persisted
			local _, _, reloaded = harness2.Join(65001)
			expect(seen).to.equal(nil)
			expect(reloaded.Inv[1].Damage.Get()).to.equal(40)
			harness2.Cleanup()
		end)
	end)

	describe("replication compaction", function()
		itRunning("keeps an element write that an index shift would rebind", function()
			local template = TestCtx.defaultTemplate()
			template.Inv = Scribe.ArrayOf({ HP = Scribe.Int(0) })
			local harness = TestCtx.make({ Template = template, AutoPump = true })
			local player, entry, data = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			data.Inv.Insert({ HP = 1 })
			harness.Ctx.Replication.FlushEntry(entry)

			-- one flush window: write element 1, shift it to index 2, then table-Set
			-- the NEW element 1. Compaction must not drop the first write.
			data.Inv[1].HP.Set(5)
			data.Inv.Insert({ HP = 2 }, 1)
			data.Inv[1].Set({ HP = 3 })
			harness.Ctx.Replication.FlushEntry(entry)

			expect(data.Inv[2].HP.Get()).to.equal(5)
			expect(clientData.Inv[1].HP.Get()).to.equal(3)
			expect(clientData.Inv[2].HP.Get()).to.equal(5)
			harness.Cleanup()
		end)
	end)

	describe("purchases", function()
		it("spends a starting balance the element default declares", function()
			local template = TestCtx.defaultTemplate()
			template.Wallet = Scribe.DictOf(Scribe.Int(100, { Min = 0 }))
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()

			-- the key was never written, but the declared default is 100
			local ok = harness.Data.Purchase(player, {
				Cost = { Path = "Wallet.gold", Amount = 30 },
				Grant = function() end,
			})
			expect(ok).to.equal(true)
			expect(data.Wallet.gold.Get()).to.equal(70)
			harness.Cleanup()
		end)

		it("returns (false, err) for a typo'd element cost field instead of throwing", function()
			local template = TestCtx.defaultTemplate()
			template.Bank = Scribe.DictOf({ Gold = Scribe.Int(0, { Min = 0 }) })
			local harness = TestCtx.make({ Template = template })
			local player = harness.Join()
			local ok, err = harness.Data.Purchase(player, {
				Cost = { Path = "Bank.main.Goldz", Amount = 5 },
				Grant = function() end,
			})
			expect(ok).to.equal(false)
			expect(err).to.equal("invalid cost path")
			harness.Cleanup()
		end)
	end)

	describe("leaderboards", function()
		it("rejects a Stat naming an undeclared element field at boot", function()
			local template = TestCtx.defaultTemplate()
			template.Chars = Scribe.DictOf({ Xp = Scribe.Int(0) })
			local ok, err = pcall(function()
				local harness = TestCtx.make({
					Template = template,
					Options = { Leaderboards = { Bad = { Stat = "Chars.main.Xpz" } } },
				})
				harness.Cleanup()
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "no declared field", 1, true) ~= nil).to.equal(true)
		end)
	end)

	describe("util", function()
		it("findUnpersistable flags mixed-key tables and survives cycles", function()
			local mixed = { [1] = "a", name = "b" }
			local found = Util.findUnpersistable(mixed)
			expect(found).to.be.ok()
			expect(string.find(found.Detail, "mixes", 1, true) ~= nil).to.equal(true)

			local cyclic: any = {}
			cyclic.self = cyclic
			local cycleFound = Util.findUnpersistable(cyclic)
			expect(cycleFound).to.be.ok()
		end)
	end)

	describe("template compile", function()
		it("rejects a non-string record key instead of silently dropping the field", function()
			expectError(function()
				Template.Compile({ Settings = { [true] = 1, Music = true } }, {})
			end, "string names")
		end)

		it("rejects a mixed-key array default", function()
			expectError(function()
				Template.Compile({ Blob = { [1] = "a", name = "b" } }, {})
			end, "cannot mix")
		end)

		it("folds element defaults into the schema hash", function()
			local a = Template.Compile({ W = Scribe.DictOf(Scribe.Int(0, { Min = 0 })) }, {}).Hash
			local b = Template.Compile({ W = Scribe.DictOf(Scribe.Int(100, { Min = 0 })) }, {}).Hash
			expect(a).never.to.equal(b)
		end)

		it("closes nested sub-records of an element shape", function()
			local template = TestCtx.defaultTemplate()
			template.Rows = Scribe.ArrayOf({ Sub = { A = Scribe.Int(0) } })
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()
			data.Rows.Insert({})
			expectError(function()
				data.Rows[1].Sub.Typo.Set(1)
			end, "not a declared field")
			harness.Cleanup()
		end)
	end)

	describe("declarator options", function()
		it("rejects a wrong-kind cap key instead of silently dropping it", function()
			expectError(function()
				Scribe.ArrayOf(Scribe.Int(0), { MaxKeys = 5 })
			end, "unknown option")
			expectError(function()
				Scribe.DictOf(Scribe.Int(0), { MaxItems = 5 })
			end, "unknown option")
		end)
	end)
end
