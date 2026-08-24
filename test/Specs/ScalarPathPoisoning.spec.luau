--!nonstrict
-- Binding a listener under a path that later holds a scalar must not poison it.
--
-- `resolveContainer` raised whenever a mid-path segment was not a table, and
-- `readValue` sits on that route. `applySet` brackets every mutation with
-- `snapshotDescendants` (before) and `fireDescendants` (after), each of which calls
-- `readValue` once per remembered listener path -- so with a listener bound under
-- `Loose.a.b`, writing a scalar to `Loose.a` landed the write and then threw out of
-- the write path.
--
-- That broke the module's own stated invariant. Node.luau says in two places that a
-- remote apply must never throw, "because Tree.ApplyOp is fed whole frames and one
-- throw drops every remaining op of the frame, permanently desyncing the mirror".
-- The client swallowed the throw as MALFORMED_FRAME, and a re-Init could not repair
-- it because ReplayFire took the same route.
--
-- The rule now: a READ through a scalar segment answers nil, exactly as a read
-- through an absent segment already did. A WRITE still raises, because writing
-- through a scalar is a real mistake the caller has to see.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function harnessWithLooseBag()
		return TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Loose = {},
			},
		})
	end

	describe("a listener bound under a path that becomes a scalar", function()
		it("does not throw out of the write that made it a scalar", function()
			local harness = harnessWithLooseBag()
			local player = harness.Join()
			local data = harness.Data.Get(player)

			data.Loose.a.b.Set(1)
			local seen = 0
			data.Loose.a.b.Changed(function()
				seen += 1
			end)

			-- `a` stops being a table while a listener is remembered beneath it.
			expect(function()
				data.Loose.a.Set(true)
			end).never.to.throw()

			expect(data.Loose.a.Get()).to.equal(true)
			harness.Cleanup()
		end)

		it("answers nil for a read through the scalar, rather than raising", function()
			local harness = harnessWithLooseBag()
			local player = harness.Join()
			local data = harness.Data.Get(player)

			data.Loose.a.b.Set(1)
			data.Loose.a.Set(true)

			-- A render callback reading a poisoned path used to crash here.
			expect(function()
				return data.Loose.a.b.Get()
			end).never.to.throw()
			expect(data.Loose.a.b.Get()).to.equal(nil)
			harness.Cleanup()
		end)

		it("recovers: the subtree can be written back to a table", function()
			-- The subtree used to be inert while the listener lived -- writing a table
			-- back threw from snapshotDescendants BEFORE the write, so it never landed,
			-- and only another scalar write succeeded.
			local harness = harnessWithLooseBag()
			local player = harness.Join()
			local data = harness.Data.Get(player)

			data.Loose.a.b.Set(1)
			data.Loose.a.b.Changed(function() end)
			data.Loose.a.Set(true)

			expect(function()
				data.Loose.a.Set({ b = 9 })
			end).never.to.throw()
			expect(data.Loose.a.b.Get()).to.equal(9)
			harness.Cleanup()
		end)

		it("still refuses to WRITE through a scalar segment", function()
			-- The other half. Making reads tolerant must not make writes silent: a
			-- write through a scalar is a genuine mistake and has to surface.
			local harness = harnessWithLooseBag()
			local player = harness.Join()
			local data = harness.Data.Get(player)

			data.Loose.a.Set(true)
			expect(function()
				data.Loose.a.b.Set(5)
			end).to.throw()
			harness.Cleanup()
		end)
	end)
end
