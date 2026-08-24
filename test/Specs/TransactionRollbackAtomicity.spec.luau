--!nonstrict
-- A rolled-back transaction restores many paths, and every restore is an ordinary
-- write that fires Changed. Dispatching those fires AS EACH RESTORE LANDS hands the
-- listener a tree that is only part-way back: it reads a state that never existed,
-- acts on it (a RemoteEvent, an analytics call, a write of its own), and nothing
-- undoes that. Which listener sees which torn state depended on the iteration order
-- of the Snapshots hash map, so the same game code was correct or corrupt depending
-- on how the keys happened to hash.
--
-- The promise being defended is docgen/guides/lifecycle.md:122 -- "if the function
-- throws, every write inside is rolled back" -- in its only observable form: a
-- listener woken by the rollback sees the pre-transaction state, not a half-restored
-- one.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function makeHarness()
		return TestCtx.make({
			Template = { Coins = 0, Audit = 0, Inventory = {} },
		})
	end

	describe("rollback fires listeners only once the tree is whole", function()
		-- Order-independent by construction: containers materialized during the
		-- transaction are pruned in a phase that runs AFTER every snapshot restore,
		-- so under the old code a listener woken by ANY snapshot restore saw the
		-- phantom, whatever order the snapshots happened to iterate in.
		it("does not show a rollback listener a container the rollback is about to prune", function()
			local harness = makeHarness()
			local player, _, data = harness.Join()
			data.Coins.Set(100)

			local seen = {}
			data.Coins.Changed(function()
				table.insert(seen, data.Inventory.Bag.Get() ~= nil)
			end)

			local ok = harness.Data.Transaction(player, function()
				data.Inventory.Bag.Sword.Set(1) -- materializes Inventory.Bag
				data.Coins.Set(200)
				error("abort")
			end)

			expect(ok).to.equal(false)
			-- Two fires: one inside the transaction (Bag really did exist then), one
			-- from the rollback restoring Coins.
			expect(#seen).to.equal(2)
			expect(seen[1]).to.equal(true)
			-- The rollback's own fire must report the pre-transaction tree, in which
			-- Inventory.Bag never existed.
			expect(seen[2]).to.equal(false)
			expect(data.Inventory.Bag.Get()).to.equal(nil)
			expect(data.Coins.Get()).to.equal(100)
			harness.Cleanup()
		end)

		-- The same tear, but caught in the DATA rather than in an observation. The
		-- listener is connected inside the transaction, after its last write, so it
		-- never fires during the body: that keeps Audit out of Snapshots, which is
		-- what makes the assertion independent of snapshot iteration order (nothing
		-- restores over the listener's write either way). Connections are not tree
		-- state, so the rollback does not undo the connect itself.
		it("does not let a rollback listener persist a value derived from a half-restored tree", function()
			local harness = makeHarness()
			local player, _, data = harness.Join()
			data.Coins.Set(100)
			data.Audit.Set(0)

			local ok = harness.Data.Transaction(player, function()
				data.Inventory.Bag.Sword.Set(1)
				data.Coins.Set(200)
				data.Coins.Changed(function()
					data.Audit.Set(if data.Inventory.Bag.Get() ~= nil then 1 else 0)
				end)
				error("abort")
			end)

			expect(ok).to.equal(false)
			expect(data.Coins.Get()).to.equal(100)
			expect(data.Inventory.Bag.Get()).to.equal(nil)
			-- Under the old code this was 1: the listener ran while the phantom
			-- container was still standing and wrote a fact about a state that never
			-- existed, and nothing rolled that write back.
			expect(data.Audit.Get()).to.equal(0)
			harness.Cleanup()
		end)

		-- Transition events are NOT collateral: queuing must move when they fire, not
		-- whether. (The `_replaying` suppression ReplayFire uses would have dropped
		-- these entirely, which is why the fix does not reuse it.)
		it("still fires OnKeyAdded/OnKeyRemoved for keys the rollback restores", function()
			local harness = makeHarness()
			local player, _, data = harness.Join()
			data.Inventory.Old.Set(1)

			local log = {}
			data.Inventory.OnKeyAdded(function(key)
				table.insert(log, "add:" .. tostring(key))
			end)
			data.Inventory.OnKeyRemoved(function(key)
				table.insert(log, "rem:" .. tostring(key))
			end)

			local ok = harness.Data.Transaction(player, function()
				data.Inventory.New.Set(2)
				data.Inventory.Old.Set(nil)
				error("abort")
			end)

			expect(ok).to.equal(false)
			expect(data.Inventory.Old.Get()).to.equal(1)
			expect(data.Inventory.New.Get()).to.equal(nil)
			-- add:New / rem:Old inside the transaction; rem:New / add:Old from the
			-- rollback undoing them.
			expect(#log).to.equal(4)
			expect(table.find(log, "rem:New") ~= nil).to.equal(true)
			expect(table.find(log, "add:Old") ~= nil).to.equal(true)
			harness.Cleanup()
		end)
		-- The queue is held on the tree, so the rollback MUST clear it and drain even
		-- when it throws part-way; a tree left with `_fireQueue` set never notifies
		-- anyone again for the rest of the session. The throw here is not injected:
		-- a derived recompute writes through a VALIDATING applySet, so an output the
		-- declarator refuses under BoundsPolicy = "Reject" throws out of the restore
		-- loop -- the case settleDerived's own comment already names. Without the
		-- pcall around the rollback this test is the only thing in the suite that
		-- fails.
		it("keeps firing listeners after a rollback that throws part-way", function()
			local mult = 1
			local harness = TestCtx.make({
				Options = { BoundsPolicy = "Reject" },
				Template = {
					Score = Scribe.Int(0, { Min = 0 }),
					Other = Scribe.Int(0, { Min = 0 }),
					Out = Scribe.Derived(Scribe.Int(0, { Min = 0, Max = 100 }), { "Score" }, function(s)
						return s * mult
					end),
				},
			})
			local player = harness.Join()
			local data = harness.Data.Get(player)
			data.Score.Set(1)
			data.Other.Set(7)

			local fired = 0
			data.Other.Changed(function()
				fired += 1
			end)

			local ok = pcall(function()
				harness.Data.Transaction(player, function()
					data.Score.Set(2)
					data.Other.Set(8)
					mult = 1000 -- makes the rollback's recompute out of bounds
					error("abort")
				end)
			end)
			expect(ok).to.equal(false) -- the refused recompute escaped the rollback
			-- The restores that DID land were still announced: the drain runs on the
			-- way out, before the error is re-raised.
			expect(fired).to.equal(2) -- one inside the txn, one from the drain

			fired = 0
			data.Other.Set(42)
			expect(fired).to.equal(1) -- the tree is not silent
			expect(data.Other.Get()).to.equal(42)
			harness.Cleanup()
		end)

		-- Draining is a REORDERING risk: the fires are collected during the restore
		-- loop and replayed afterwards, so the replay must preserve the order the
		-- restores produced. Reversing the drain loop passes every other spec in the
		-- suite.
		it("drains the rollback's fires in restore order", function()
			local harness = TestCtx.make({
				Template = { Aaa = Scribe.Int(0), Bbb = Scribe.Int(0), Ccc = Scribe.Int(0) },
			})
			local player = harness.Join()
			local data = harness.Data.Get(player)
			data.Aaa.Set(1)
			data.Bbb.Set(1)
			data.Ccc.Set(1)

			local order = {}
			for _, key in { "Aaa", "Bbb", "Ccc" } do
				data[key].Changed(function()
					table.insert(order, key)
				end)
			end

			harness.Data.Transaction(player, function()
				data.Ccc.Set(9) -- deliberately not in restore order
				data.Aaa.Set(9)
				data.Bbb.Set(9)
				error("abort")
			end)

			-- Writes fire in write order; the rollback fires in RESTORE order, which
			-- is shallowest-first then by path key.
			expect(table.concat(order, ",")).to.equal("Ccc,Aaa,Bbb,Aaa,Bbb,Ccc")
			harness.Cleanup()
		end)
	end)
end
