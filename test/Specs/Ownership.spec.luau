--!nonstrict
-- OwnsAsync + the replicated OwnsSynced flag. Gamepass ownership is resolved by
-- async UserOwnsGamePassAsync calls fired at load, so plain Owns can read false
-- for a genuine owner in the window right after join; OwnsAsync awaits that
-- refresh. Perks/gifts resolve synchronously and are unaffected.

return function()
	local Root = script.Parent.Parent.Parent
	local Template = require(Root.Scribe.Internal.Template)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function withPasses()
		return TestCtx.make({
			Options = {
				Passes = { ["Air Traffic Controller"] = { Id = 14966357 } },
				Perks = { "VIP" },
			},
		})
	end

	describe("ownership sync", function()
		it("flips OwnsSynced true once the initial refresh completes", function()
			local harness = withPasses()
			local _, entry = harness.Join()
			expect(entry.OwnershipReady).to.equal(true)
			expect(entry.Tree.Accessor[Template.SESSION_ROOT].OwnsSynced.Get()).to.equal(true)
			harness.Cleanup()
		end)

		it("OwnsAsync returns (does not hang) for an unowned pass once synced", function()
			local harness = withPasses()
			local player = harness.Join()
			-- Fake UserOwnsGamePassAsync returns false, so the pass is not owned; the
			-- call must resolve rather than block on the already-completed refresh.
			expect(harness.Data.OwnsAsync(player, "Air Traffic Controller")).to.equal(false)
			harness.Cleanup()
		end)

		it("OwnsAsync returns true for a granted perk (synchronous ownership)", function()
			local harness = withPasses()
			local player = harness.Join()
			harness.Data.GrantPerk(player, "VIP")
			expect(harness.Data.Owns(player, "VIP")).to.equal(true)
			expect(harness.Data.OwnsAsync(player, "VIP")).to.equal(true)
			harness.Cleanup()
		end)

		it("Owns and OwnsAsync return false (no error) for an unknown key", function()
			local harness = withPasses()
			local player = harness.Join()
			expect(harness.Data.Owns(player, "NotARegisteredKey")).to.equal(false)
			expect(harness.Data.OwnsAsync(player, "NotARegisteredKey")).to.equal(false)
			harness.Cleanup()
		end)
	end)
end
