--!nonstrict
-- A whole-container Set fires its descendant listeners, which means scanning the
-- tree's registered paths on every container write. That was added for correctness
-- (a bound Observe used to render a stale value forever), but correctness tests say
-- nothing about cost, and this runs on the hottest write path in the library.
--
-- The budgets below are deliberately loose. This is a guard against an accidental
-- quadratic, not a micro-benchmark: it should catch "someone made container writes
-- scale with data size" and stay quiet about ordinary machine-to-machine variance.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function harnessWith()
		return TestCtx.make({
			Template = {
				Settings = { Music = true, Sfx = true },
				Inventory = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 4096 }),
			},
		})
	end

	-- Median of a few passes: a single timing on a loaded machine is noise.
	local function medianSeconds(passes: number, run: () -> ()): number
		local samples = {}
		for _ = 1, passes do
			local t0 = os.clock()
			run()
			table.insert(samples, os.clock() - t0)
		end
		table.sort(samples)
		return samples[math.ceil(#samples / 2)]
	end

	-- Times writes to a SMALL container while varying how many listener paths are
	-- registered elsewhere in the tree. Holding the written payload constant is what
	-- isolates the descendant scan: validateWrite is linear in payload, so growing
	-- both together lets validateWrite dominate and hides a scan regression.
	local function timeSmallWrites(otherListeners: number, writes: number): number
		local harness = TestCtx.make({
			Template = {
				Inv = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 64 }),
				Other = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 4096 }),
			},
		})
		local _p, _e, data = harness.Join()

		local payload = { k1 = 1, k2 = 2, k3 = 3, k4 = 4 }
		data.Inv.Set(payload)

		-- Unrelated registered paths. The scan walks every registered path, so these
		-- cost the write even though they are not descendants of Inv.
		local other = {}
		for i = 1, otherListeners do
			other[`o{i}`] = i
		end
		data.Other.Set(other)
		for i = 1, otherListeners do
			data.Other[`o{i}`].Changed(function() end)
		end
		-- One real descendant listener so the scan is not short-circuited.
		data.Inv.k1.Changed(function() end)

		local seconds = medianSeconds(3, function()
			for _ = 1, writes do
				payload.k1 = if payload.k1 == 1 then 2 else 1
				data.Inv.Set(payload)
			end
		end)
		harness.Cleanup()
		return seconds
	end

	it("the descendant scan stays at most linear in registered paths, never quadratic", function()
		local small = timeSmallWrites(64, 100)
		local large = timeSmallWrites(512, 100)

		-- 8x the registered paths, constant payload, so the scan is the only thing
		-- that grows. Linear is correct; allow 8x plus 2.5x headroom. A quadratic is
		-- ~64x and cannot hide here the way it can when payload grows too.
		expect(large < math.max(small * 8 * 2.5, 0.05)).to.equal(true)
	end)

	it("a container Set stays linear in the number of registered listeners", function()
		local harness = harnessWith()
		local _p, _e, data = harness.Join()

		local payload = {}
		for i = 1, 64 do
			payload[`k{i}`] = i
		end
		data.Inventory.Set(payload)

		local baseline = medianSeconds(3, function()
			for _ = 1, 200 do
				data.Inventory.Set(payload)
			end
		end)

		-- Bind a listener to every stored key, which is the worst realistic case.
		for i = 1, 64 do
			data.Inventory[`k{i}`].Changed(function() end)
		end

		local withListeners = medianSeconds(3, function()
			for _ = 1, 200 do
				data.Inventory.Set(payload)
			end
		end)

		-- Listeners cost something (that IS the feature), but 64 of them must not
		-- explode the write. Linear-ish with generous headroom for a noisy machine.
		expect(withListeners < math.max(baseline * 60, 0.5)).to.equal(true)

		harness.Cleanup()
	end)

	it("an unrelated listener tree does not slow a leaf write", function()
		local harness = harnessWith()
		local _p, _e, data = harness.Join()

		local function leafWrites(): number
			return medianSeconds(3, function()
				for i = 1, 500 do
					data.Settings.Music.Set(i % 2 == 0)
				end
			end)
		end

		local before = leafWrites()

		-- A large, entirely unrelated listener set. A leaf write must not pay for it:
		-- the descendant scan only runs for TABLE writes, so this should be flat.
		local payload = {}
		for i = 1, 256 do
			payload[`k{i}`] = i
		end
		data.Inventory.Set(payload)
		for i = 1, 256 do
			data.Inventory[`k{i}`].Changed(function() end)
		end

		local after = leafWrites()
		expect(after < math.max(before * 8, 0.05)).to.equal(true)

		harness.Cleanup()
	end)
end
