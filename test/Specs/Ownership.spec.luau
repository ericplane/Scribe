--!nonstrict
-- OwnsAsync + the replicated OwnsSynced flag. Gamepass ownership is resolved by
-- async UserOwnsGamePassAsync calls fired at load, so plain Owns can read false
-- for a genuine owner in the window right after join; OwnsAsync awaits that
-- refresh. Perks/gifts resolve synchronously and are unaffected.

return function()
	local Root = script.Parent.Parent.Parent
	local Template = require(Root.Scribe.Internal.Template)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	-- Ownership is injected through the UserOwnsGamePassAsync seam rather than by
	-- patching MarketplaceService, which a real service Instance rejects and which
	-- made every spec in this file unrunnable in Studio. `owned` is read live on
	-- each call, so a test can flip it mid-run to simulate a purchase.
	local ownedPasses: { [number]: boolean } = {}
	-- When true the seam yields, so the join-time refresh has not resolved yet.
	local yieldOwns = false
	local function withPasses()
		return TestCtx.make({
			Options = {
				Passes = { ["Air Traffic Controller"] = { Id = 14966357 } },
				Perks = { "VIP" },
				UserOwnsGamePassAsync = function(_userId: number, passId: number): boolean
					if yieldOwns then
						task.wait()
					end
					return ownedPasses[passId] == true
				end,
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

	describe("ownership change signal", function()
		it("fires on a perk grant and revoke", function()
			local harness = withPasses()
			local player = harness.Join()
			local events = {}
			harness.Data.OnOwnershipChanged:Connect(function(p, key, owned)
				table.insert(events, { Player = p, Key = key, Owned = owned })
			end)
			harness.Data.GrantPerk(player, "VIP")
			expect(#events).to.equal(1)
			expect(events[1].Player).to.equal(player)
			expect(events[1].Key).to.equal("VIP")
			expect(events[1].Owned).to.equal(true)
			harness.Data.RevokePerk(player, "VIP")
			expect(#events).to.equal(2)
			expect(events[2].Owned).to.equal(false)
			harness.Cleanup()
		end)

		it("treats ownership already held at join as the baseline, not a change", function()
			local harness = withPasses()
			-- A returning player who already owns the perk.
			harness.Fake.Persisted["Default/PLAYER_96001"] = { _Scribe = { Perks = { VIP = true } } }
			local events = 0
			harness.Data.OnOwnershipChanged:Connect(function()
				events += 1
			end)
			local player = harness.Join(96001)
			expect(harness.Data.Owns(player, "VIP")).to.equal(true)
			expect(events).to.equal(0)
			harness.Cleanup()
		end)

		it("ObserveOwned pushes the current value, then changes, until disconnected", function()
			local harness = withPasses()
			local player = harness.Join()
			local seen = {}
			local disconnect = harness.Data.ObserveOwned(player, "VIP", function(owned)
				table.insert(seen, owned)
			end)
			expect(seen[1]).to.equal(false) -- immediate push of the current value
			harness.Data.GrantPerk(player, "VIP")
			expect(seen[2]).to.equal(true)
			disconnect()
			harness.Data.RevokePerk(player, "VIP")
			expect(#seen).to.equal(2) -- no further pushes after disconnect
			harness.Cleanup()
		end)
	end)

	describe("gamepass ownership", function()
		local AIR_TRAFFIC_ID = 14966357

		afterEach(function()
			table.clear(ownedPasses)
			yieldOwns = false
		end)

		it("Owns and OwnsAsync return true for an owned gamepass (warm cache)", function()
			ownedPasses[AIR_TRAFFIC_ID] = true
			local harness = withPasses()
			local player = harness.Join()
			-- refreshOwnership ran synchronously at load (OwnsYield is false).
			expect(harness.Data.Owns(player, "Air Traffic Controller")).to.equal(true)
			expect(harness.Data.OwnsAsync(player, "Air Traffic Controller")).to.equal(true)
			harness.Cleanup()
		end)

		it("OwnsAsync verifies live and returns true even before the background refresh finishes", function()
			ownedPasses[AIR_TRAFFIC_ID] = true
			yieldOwns = true -- the gamepass check yields, so the cache is not warm at join
			local harness = withPasses()
			local player, entry = harness.Join()
			expect(entry.OwnershipReady).never.to.equal(true)
			-- Cache is cold, so OwnsAsync does its own live UserOwnsGamePassAsync and
			-- returns the authoritative answer without waiting on the background refresh.
			expect(harness.Data.OwnsAsync(player, "Air Traffic Controller")).to.equal(true)
			harness.Cleanup()
		end)

		it("OwnsAsync re-checks live on every call, reflecting a purchase between calls", function()
			local harness = withPasses()
			local player = harness.Join()
			-- Not owned yet.
			expect(harness.Data.OwnsAsync(player, "Air Traffic Controller")).to.equal(false)
			-- The player buys the pass; the very next OwnsAsync must reflect it (no TTL).
			ownedPasses[AIR_TRAFFIC_ID] = true
			expect(harness.Data.OwnsAsync(player, "Air Traffic Controller")).to.equal(true)
			harness.Cleanup()
		end)
	end)
end
