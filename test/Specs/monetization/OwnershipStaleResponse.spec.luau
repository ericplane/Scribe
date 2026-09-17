--!nonstrict
-- Ownership only gains during a session, but a pass check that answered "not owned"
-- after a purchase was confirmed cleared the cache.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local PASS = "Air Traffic Controller"
	local PASS_ID = 14966357

	--- The seam captures its answer when called and parks until released, so the test
	--- chooses the order in which answers land.
	local function parkedSeam()
		local state = { Owned = false, Waiting = {} }
		state.Seam = function(_userId: number, _passId: number): boolean
			local answer = state.Owned
			table.insert(state.Waiting, coroutine.running())
			coroutine.yield()
			return answer
		end
		state.Release = function(index: number)
			local thread = table.remove(state.Waiting, index)
			if thread ~= nil then
				task.spawn(thread)
			end
		end
		return state
	end

	local function withSeam(seam)
		return TestCtx.make({
			Options = { Passes = { [PASS] = { Id = PASS_ID } }, UserOwnsGamePassAsync = seam },
		})
	end

	it("keeps a confirmed purchase when an older not-owned answer lands afterwards", function()
		local state = parkedSeam()
		local harness = withSeam(state.Seam)
		local player = harness.Join(1)
		expect(#state.Waiting).to.equal(1)

		-- The purchase confirmation asks the seam too.
		state.Owned = true
		task.spawn(function()
			harness.Ctx.Monetization.OnPassPurchaseFinished(player, PASS_ID, true)
		end)
		expect(#state.Waiting).to.equal(2)
		state.Release(2)
		expect(harness.Data.Owns(player, PASS)).to.equal(true)

		state.Release(1)
		expect(
			`owns={tostring(harness.Data.Owns(player, PASS))} ready={tostring(
				harness.Ctx.Persistence.EntryFor(player).OwnershipReady
			)}`
		).to.equal("owns=true ready=true")
		harness.Cleanup()
	end)

	it("keeps a confirmed purchase when a slow OwnsAsync verification lands afterwards", function()
		local state = parkedSeam()
		local harness = withSeam(state.Seam)
		local player = harness.Join(1)
		state.Release(1)
		expect(harness.Data.Owns(player, PASS)).to.equal(false)

		local verified = nil
		task.spawn(function()
			verified = harness.Data.OwnsAsync(player, PASS)
		end)
		expect(#state.Waiting).to.equal(1)

		state.Owned = true
		task.spawn(function()
			harness.Ctx.Monetization.OnPassPurchaseFinished(player, PASS_ID, true)
		end)
		state.Release(2)
		expect(harness.Data.Owns(player, PASS)).to.equal(true)

		state.Release(1)
		expect(`owns={tostring(harness.Data.Owns(player, PASS))} verified={tostring(verified)}`).to.equal(
			"owns=true verified=true"
		)
		harness.Cleanup()
	end)

	it("a not-owned answer still lands when nothing confirmed ownership, which is the control", function()
		local state = parkedSeam()
		local harness = withSeam(state.Seam)
		local player = harness.Join(1)
		state.Release(1)
		expect(
			`owns={tostring(harness.Data.Owns(player, PASS))} ready={tostring(
				harness.Ctx.Persistence.EntryFor(player).OwnershipReady
			)}`
		).to.equal("owns=false ready=true")
		harness.Cleanup()
	end)
end
