--!nonstrict
-- The DevMode warning for an expensive root Observe.
--
-- A root Observe/Changed re-reads every root on every write, and a root holding a
-- datatype or a Scribe.Big must be rebuilt key by key to be read. Together those
-- cost ~9 ms per unrelated write at 3,000 CFrames.
--
-- Scribe deliberately does NOT try to make that cheap. The only way to skip the
-- rebuild is to hand every reader the same view, and that view aliases live store
-- tables -- so sharing it lets one caller's edit reach another's read and the
-- profile itself. A cache doing exactly that was written, measured, audited and
-- reverted. The fix is to listen to the container instead, which is already cheap,
-- so the library points at it rather than pretending to solve it.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Log = require(Root.Scribe.Internal.Log)

	local function packedTemplate()
		return {
			Tick = Scribe.Int(0),
			Spots = Scribe.ArrayOf({ Cf = Scribe.CFrame(CFrame.new()), Id = Scribe.Int(0) }),
		}
	end

	local function warnCount(): number
		local n = 0
		for _, entry in Log.GetRecent({ Code = "DEV_WARNING" }) do
			if
				string.find(entry.Message, "root Observe", 1, true)
				or string.find(entry.Message, "root Changed", 1, true)
			then
				n += 1
			end
		end
		return n
	end

	describe("expensive root Observe", function()
		it("warns in DevMode when a packed root is large", function()
			local harness = TestCtx.make({
				Template = packedTemplate(),
				Options = { DevMode = true, LogLevel = "Warn" },
			})
			local _, _, data = harness.Join(98801)
			for i = 1, 300 do
				data.Spots.Insert({ Cf = CFrame.new(i, 0, 0), Id = i })
			end

			local before = warnCount()
			data.Observe(function() end)
			expect(warnCount()).to.equal(before + 1)

			harness.Cleanup()
		end)

		it("says it only once per tree, however many listeners are bound", function()
			local harness = TestCtx.make({
				Template = packedTemplate(),
				Options = { DevMode = true, LogLevel = "Warn" },
			})
			local _, _, data = harness.Join(98802)
			for i = 1, 300 do
				data.Spots.Insert({ Cf = CFrame.new(i, 0, 0), Id = i })
			end

			local before = warnCount()
			data.Observe(function() end)
			data.Observe(function() end)
			data.Changed(function() end)
			expect(warnCount()).to.equal(before + 1)

			harness.Cleanup()
		end)

		it("stays quiet for a small packed root", function()
			local harness = TestCtx.make({
				Template = packedTemplate(),
				Options = { DevMode = true, LogLevel = "Warn" },
			})
			local _, _, data = harness.Join(98803)
			data.Spots.Insert({ Cf = CFrame.new(1, 0, 0), Id = 1 })

			local before = warnCount()
			data.Observe(function() end)
			expect(warnCount()).to.equal(before)

			harness.Cleanup()
		end)

		it("stays quiet for a CONTAINER listener, which is the thing it recommends", function()
			local harness = TestCtx.make({
				Template = packedTemplate(),
				Options = { DevMode = true, LogLevel = "Warn" },
			})
			local _, _, data = harness.Join(98804)
			for i = 1, 300 do
				data.Spots.Insert({ Cf = CFrame.new(i, 0, 0), Id = i })
			end

			local before = warnCount()
			data.Spots.Observe(function() end)
			expect(warnCount()).to.equal(before)

			harness.Cleanup()
		end)

		it("stays quiet outside DevMode", function()
			local harness = TestCtx.make({
				Template = packedTemplate(),
				Options = { DevMode = false, LogLevel = "Warn" },
			})
			local _, _, data = harness.Join(98805)
			for i = 1, 300 do
				data.Spots.Insert({ Cf = CFrame.new(i, 0, 0), Id = i })
			end

			local before = warnCount()
			data.Observe(function() end)
			expect(warnCount()).to.equal(before)

			harness.Cleanup()
		end)
	end)
end
