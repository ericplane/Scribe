--!nonstrict
-- Two gaps in descendant fanout, both silent and both permanent.
--
-- `ContainerFanout.spec` guards this invariant for `Set` and `Clear` and its header
-- calls the failure "silent, permanent, and on the ergonomic centerpiece". These are
-- the two routes it did not cover.
--
-- 1. `Insert`/`Remove` called `fire` and `fireAncestors` but never `fireDescendants`,
--    so a listener bound to an element index rendered stale forever -- while a
--    whole-array `Set` producing the same end state fired correctly.
--
-- 2. Older and wider: the snapshot map stored NOTHING when a descendant's value was
--    nil, so an absent-to-present key was invisible to the diff. This reproduced
--    through plain `Set` on untouched source -- bind `Inventory.Sword.Dmg`, then
--    `Inventory.Set({ Sword = { Dmg = 9 } })`, and the listener never fired while
--    `Get()` returned 9. An appended array element is exactly that case, so fixing
--    Insert without this would have been half a fix.
--
-- The cost note matters as much as the fix. Firing descendants naively wakes EVERY
-- row on a plain append, because table values never compare equal -- measured at 500
-- spurious fires per op with 500 bound rows. `fireDescendants` therefore compares by
-- identity: `table.insert`/`table.remove` shift references, so identity is an exact
-- signal for "did this row move". Appends now wake nothing they should not.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function arrayHarness()
		return TestCtx.make({
			Template = {
				Log = Scribe.ArrayOf({ Text = Scribe.String("") }),
			},
		})
	end

	describe("descendant fanout", function()
		it("fires for a key a parent Set introduces from absent", function()
			local harness = TestCtx.make()
			local _p, _e, data = harness.Join()

			local fires = 0
			data.Inventory.Sword.Dmg.Changed(function()
				fires += 1
			end)

			data.Inventory.Set({ Sword = { Dmg = 9 } })

			expect(data.Inventory.Sword.Dmg.Get()).to.equal(9)
			expect(fires).to.equal(1)
			harness.Cleanup()
		end)

		it("fires for an element whose index an Insert shifted", function()
			local harness = arrayHarness()
			local _p, _e, data = harness.Join()

			data.Log.Insert({ Text = "one" })
			local seen = nil
			data.Log[1].Text.Changed(function(new)
				seen = new
			end)

			data.Log.Insert({ Text = "two" }, 1) -- pushes "one" to index 2

			expect(data.Log[1].Text.Get()).to.equal("two")
			expect(seen).to.equal("two")
			harness.Cleanup()
		end)

		it("fires for an element whose index a Remove shifted", function()
			local harness = arrayHarness()
			local _p, _e, data = harness.Join()

			data.Log.Insert({ Text = "a" })
			data.Log.Insert({ Text = "b" })
			local seen = nil
			data.Log[1].Text.Changed(function(new)
				seen = new
			end)

			data.Log.Remove(1) -- "b" shifts down into index 1

			expect(data.Log[1].Text.Get()).to.equal("b")
			expect(seen).to.equal("b")
			harness.Cleanup()
		end)

		it("does not wake rows an append cannot have moved", function()
			-- The regression the naive fix introduced. Appending shifts nothing, so a
			-- listener on an existing row must stay silent. Measured before the
			-- identity test: 500 bound rows meant 500 spurious fires on every append.
			local harness = arrayHarness()
			local _p, _e, data = harness.Join()

			for i = 1, 20 do
				data.Log.Insert({ Text = `row{i}` })
			end
			local woken = 0
			for i = 1, 20 do
				data.Log[i].Text.Changed(function()
					woken += 1
				end)
			end

			data.Log.Insert({ Text = "appended" }) -- at the end: nothing shifts

			expect(data.Log[21].Text.Get()).to.equal("appended")
			expect(woken).to.equal(0)
			harness.Cleanup()
		end)
	end)
end
