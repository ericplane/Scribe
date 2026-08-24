--!nonstrict
-- Ownership a player ALREADY HAD is the baseline, not a change.
--
-- `watchOwnership` says so in one word: it opens with `scanOwnership(entry, true)`
-- -- "baseline: record current state without firing" -- so a game that connects
-- `OnOwnershipChanged` before a player joins is told about transitions, not about
-- the state the player walked in with. `ObserveOwned` exists for the other job.
--
-- But a real game pass is not known at that moment. `refreshOwnership` is spawned
-- just before, and its `UserOwnsGamePassAsync` call is a network round trip. When
-- it yields -- which is the only thing it does in production -- the baseline is
-- taken FIRST, with the pass reading not-owned, and the resolution that lands
-- afterwards looks exactly like the player buying the pass at that instant.
--
-- So every player who already owned a pass got a spurious `owned = true` at join,
-- and a listener that plays a "purchase complete" effect played it for everyone.
-- `Owns()` was right the whole time, which is why nothing caught it.
--
-- The seam is the point: the CONTROL and the TEST differ only in whether the
-- ownership check yields. Everything else is identical.
return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- `yields` decides whether the pass check takes a scheduler turn, which is the
	--- only difference between the two arms.
	local function makeHarness(owned: boolean, yields: boolean)
		local events = {}
		local harness = TestCtx.make({
			Options = {
				Passes = { VIPPass = { Id = 777001 } },
				UserOwnsGamePassAsync = function()
					if yields then
						task.wait()
					end
					return owned
				end,
			},
		})
		harness.Data.OnOwnershipChanged:Connect(function(_player, key, isOwned)
			table.insert(events, `{key}={tostring(isOwned)}`)
		end)
		return harness, events
	end

	local function settle()
		for _ = 1, 10 do
			task.wait()
		end
	end

	describe("OnOwnershipChanged at join", function()
		it("says nothing for a pass the player already owned, when the check is instant", function()
			-- THE CONTROL. This arm already worked: with no yield the cache write lands
			-- before the baseline is taken, so the baseline absorbs it.
			local harness, events = makeHarness(true, false)
			local player = harness.Join(88201)
			settle()

			expect(#events).to.equal(0)
			expect(harness.Data.Owns(player, "VIPPass")).to.equal(true)

			harness.Cleanup()
		end)

		it("says nothing for a pass the player already owned, when the check YIELDS", function()
			-- The defect, and the only arm that differs from the control above.
			local harness, events = makeHarness(true, true)
			local player = harness.Join(88202)
			settle()

			if #events > 0 then
				error(`expected no ownership events at join, got: {table.concat(events, ",")}`)
			end
			expect(harness.Data.Owns(player, "VIPPass")).to.equal(true)

			harness.Cleanup()
		end)

		it("says nothing for a pass the player does NOT own, either way", function()
			-- The other half of "nothing at join", and it guards against a fix that
			-- seeded the baseline to true unconditionally.
			for _, yields in { false, true } do
				local harness, events = makeHarness(false, yields)
				local player = harness.Join(if yields then 88203 else 88204)
				settle()

				expect(#events).to.equal(0)
				expect(harness.Data.Owns(player, "VIPPass")).to.equal(false)

				harness.Cleanup()
			end
		end)

		it("STILL fires for a genuine transition after join", function()
			-- THE CONTROL THAT MATTERS MOST. Suppressing the join report is only
			-- correct if the signal still works afterwards -- a fix that seeded the
			-- baseline too aggressively would silence the whole feature and pass every
			-- test above.
			local harness, events = makeHarness(false, true)
			local player = harness.Join(88205)
			settle()
			expect(#events).to.equal(0)

			harness.Data.GrantPerk(player, "VIPPass")
			settle()

			expect(#events).to.equal(1)
			expect(events[1]).to.equal("VIPPass=true")
			expect(harness.Data.Owns(player, "VIPPass")).to.equal(true)

			harness.Data.RevokePerk(player, "VIPPass")
			settle()

			expect(#events).to.equal(2)
			expect(events[2]).to.equal("VIPPass=false")

			harness.Cleanup()
		end)

		it(
			"does not report a change for a PERK the player joined holding, while the pass check is still out",
			function()
				-- THE UNION CASE, and the one a naive seed gets wrong. Ownership is
				-- Perks OR OwnsCache OR RobloxPlus. A player whose STORED profile already
				-- carries the perk is owned from the instant the baseline is taken, and the
				-- pass check -- still in flight, and about to come back not-owned -- knows
				-- nothing about that. Assigning the pass result into the baseline records
				-- FALSE under a player who is owned, and the very next scan then reports a
				-- change to true that never happened.
				--
				-- The perk has to be on the KEY, not granted afterwards: granting it later
				-- happens once the resolution has already landed, which is a different and
				-- much easier ordering.
				local harness, events = makeHarness(false, true)
				harness.Fake.Persisted["Default/PLAYER_88206"] = {
					Coins = 5,
					_Scribe = { Perks = { VIPPass = true } },
				}
				local player = harness.Join(88206)
				settle()

				expect(harness.Data.Owns(player, "VIPPass")).to.equal(true)
				if #events > 0 then
					error(`expected no ownership events for a perk held at join, got: {table.concat(events, ",")}`)
				end

				-- ...and the signal is not dead: revoking it still reports.
				harness.Data.RevokePerk(player, "VIPPass")
				settle()
				expect(#events).to.equal(1)
				expect(events[1]).to.equal("VIPPass=false")

				harness.Cleanup()
			end
		)
	end)
end
