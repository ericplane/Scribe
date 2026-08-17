--!nonstrict
-- The MaxKeys / MapOf("integer") key-count memo.
--
-- Both guards used to walk the whole container on every new key, which made
-- building a capped or integer-keyed dictionary O(n^2) -- a 50,000-key build took
-- ~19.5 s. They are memoised per container identity now, maintained where a
-- container is assigned into.
--
-- A memo is only as good as its invalidation, so these specs pin the cases where
-- it could drift: removal must free a slot, Clear must reset it, replacing the
-- container must not inherit the old count, and a memo that has drifted must never
-- refuse a write that is actually legal.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function capped(max: number)
		return TestCtx.make({
			Template = { Bag = Scribe.DictOf(Scribe.Int(0), { MaxKeys = max }) },
		})
	end

	local function fill(data, n: number, prefix: string?)
		for i = 1, n do
			data.Bag[(prefix or "k") .. i].Set(i)
		end
	end

	describe("MaxKeys accounting", function()
		it("admits exactly MaxKeys keys and refuses the next", function()
			local harness = capped(5)
			local _, _, data = harness.Join()

			fill(data, 5)
			expect(data.Bag.Count()).to.equal(5)
			expect(function()
				data.Bag.k6.Set(6)
			end).to.throw()
			expect(data.Bag.Count()).to.equal(5)

			harness.Cleanup()
		end)

		it("still allows updating an existing key at the cap", function()
			local harness = capped(3)
			local _, _, data = harness.Join()

			fill(data, 3)
			data.Bag.k2.Set(99) -- not a NEW key, so the cap does not apply
			expect(data.Bag.k2.Get()).to.equal(99)

			harness.Cleanup()
		end)

		it("frees a slot when a key is removed", function()
			local harness = capped(3)
			local _, _, data = harness.Join()

			fill(data, 3)
			expect(function()
				data.Bag.k4.Set(4)
			end).to.throw()

			data.Bag.k1.Set(nil) -- removal must decrement the memo
			data.Bag.k4.Set(4)
			expect(data.Bag.k4.Get()).to.equal(4)
			expect(data.Bag.Count()).to.equal(3)

			harness.Cleanup()
		end)

		it("resets the count when the container is cleared in place", function()
			local harness = capped(4)
			local _, _, data = harness.Join()

			fill(data, 4)
			data.Bag.Clear() -- table.clear keeps the identity: the memo must go to 0
			expect(data.Bag.Count()).to.equal(0)

			fill(data, 4, "n") -- a full cap's worth again
			expect(data.Bag.Count()).to.equal(4)

			harness.Cleanup()
		end)

		it("does not carry the old count over when the whole container is replaced", function()
			local harness = capped(4)
			local _, _, data = harness.Join()

			fill(data, 4)
			data.Bag.Set({ only = 1 }) -- a DIFFERENT table
			expect(data.Bag.Count()).to.equal(1)

			fill(data, 3) -- room for three more under the cap of four
			expect(data.Bag.Count()).to.equal(4)
			expect(function()
				data.Bag.overflow.Set(1)
			end).to.throw()

			harness.Cleanup()
		end)

		it("survives a rolled-back transaction without leaking count", function()
			local harness = capped(4)
			local player, _, data = harness.Join()

			fill(data, 2)
			local ok = harness.Data.Transaction(player, function()
				data.Bag.t1.Set(1)
				data.Bag.t2.Set(2)
				error("rollback")
			end)
			expect(ok).to.equal(false)
			expect(data.Bag.Count()).to.equal(2)

			-- The two rolled-back keys must not still be occupying the cap.
			data.Bag.a.Set(1)
			data.Bag.b.Set(2)
			expect(data.Bag.Count()).to.equal(4)

			harness.Cleanup()
		end)

		it("re-derives rather than refusing when the live table was mutated behind the memo", function()
			local harness = capped(3)
			local _, entry, data = harness.Join()

			fill(data, 3) -- memo now says 3, at the cap
			-- Reach past the accessor the way only unsupported code would, so the memo
			-- is stale-high. The guard must re-count and let a legal write through
			-- rather than lock the container permanently.
			entry.LiveData.Bag.k1 = nil
			entry.LiveData.Bag.k2 = nil

			data.Bag.fresh.Set(1)
			expect(data.Bag.fresh.Get()).to.equal(1)

			harness.Cleanup()
		end)
	end)

	describe('MapOf("integer") string-key guard', function()
		local function ints()
			return TestCtx.make({
				Template = { Ids = Scribe.MapOf("integer", Scribe.Int(0)) },
			})
		end

		it("keeps refusing while an uncoercible string key remains", function()
			local harness = ints()
			local _, entry, data = harness.Join()

			entry.LiveData.Ids["07"] = 7 -- stands in for blocked load-time coercion
			expect(function()
				data.Ids[1].Set(1)
			end).to.throw()
			-- Twice: a memoised "yes" must not become a memoised "no" on its own.
			expect(function()
				data.Ids[2].Set(2)
			end).to.throw()

			harness.Cleanup()
		end)

		it("unblocks once the string key is repaired", function()
			local harness = ints()
			local _, entry, data = harness.Join()

			entry.LiveData.Ids["07"] = 7
			expect(function()
				data.Ids[1].Set(1)
			end).to.throw()

			-- A migration or operator fix-up removes it. The guard re-derives before
			-- refusing, so the repair takes effect immediately.
			entry.LiveData.Ids["07"] = nil
			data.Ids[1].Set(1)
			expect(data.Ids[1].Get()).to.equal(1)

			harness.Cleanup()
		end)

		it("does not re-block after a Clear wipes the string key", function()
			local harness = ints()
			local _, entry, data = harness.Join()

			entry.LiveData.Ids["07"] = 7
			expect(function()
				data.Ids[1].Set(1)
			end).to.throw()

			data.Ids.Clear()
			data.Ids[1].Set(1)
			expect(data.Ids[1].Get()).to.equal(1)

			harness.Cleanup()
		end)
	end)

	describe("growth is linear, not quadratic", function()
		it("builds 4n keys in well under the cost a full-walk-per-key would take", function()
			-- Shape, not wall-clock, so it does not depend on how fast the box is.
			--
			-- The n values matter: at n in the hundreds the fixed per-write cost
			-- (accessor, validation, emitOp) dominates and a restored O(n^2) walk
			-- still measures ~4x, so the gate would pass while broken. Verified
			-- against the real thing at 2,000 -> 8,000: memoised ~4.8x, full walk
			-- per key ~11.4x. 8x sits between with room for a noisy CI box.
			local function build(n: number): number
				local harness = TestCtx.make({
					Template = { Bag = Scribe.DictOf(Scribe.Int(0), { MaxKeys = 1000000 }) },
				})
				local _, _, data = harness.Join()
				local t0 = os.clock()
				for i = 1, n do
					data.Bag["k" .. i].Set(i)
				end
				local elapsed = os.clock() - t0
				harness.Cleanup()
				return elapsed
			end

			build(1000) -- warm up: the first run pays interpreter warmth
			local small = build(2000)
			local large = build(8000)
			-- Guard against a divide-by-zero on an implausibly fast box.
			local ratio = if small > 0 then large / small else 0
			expect(ratio < 8).to.equal(true)
		end)
	end)
end
