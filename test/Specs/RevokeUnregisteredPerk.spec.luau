--!nonstrict
-- A perk that goes away has to be REPORTED going away.
--
-- `scanOwnership` recomputes effective ownership and fires `OnOwnershipChanged`
-- for whatever flipped. It decides what to look at from `ownershipCandidates`:
-- every registered key, plus every key the profile currently holds. That covers
-- appearing perfectly -- a name shows up in `Perks`, so it is a candidate, so the
-- true transition fires.
--
-- Disappearing is the other direction, and the candidate set is built from the
-- CURRENT state. `RevokePerk` clears the flag first; by the time the scan runs the
-- name is gone from `Perks`, gone from `OwnsCache`, and -- if it was never in the
-- optional `Perks` registry -- was never in `knownOwnsKeys` either. Nothing lists
-- it, so nothing looks at it, so no `false` is ever fired.
--
-- `Owns()` reads false immediately and correctly, so this is a MISSED SIGNAL, not
-- wrong state: every listener that strips the perk's benefits on `owned = false`
-- simply never runs. A moderation action, a chargeback or a support reversal
-- leaves the player keeping what was taken away.
--
-- The registry is optional and ad-hoc names are a documented, working way to use
-- `GrantPerk`, which is exactly why the two arms below differ only in whether
-- `Perks` was declared.
return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function makeHarness(options)
		local events = {}
		local harness = TestCtx.make({ Options = options or {} })
		harness.Data.OnOwnershipChanged:Connect(function(_player, key, owned)
			table.insert(events, `{key}={tostring(owned)}`)
		end)
		return harness, events
	end

	local function settle()
		for _ = 1, 6 do
			task.wait()
		end
	end

	describe("RevokePerk and OnOwnershipChanged", function()
		it("reports both transitions for a REGISTERED perk", function()
			-- THE CONTROL, and it is what makes the arm below a defect rather than a
			-- design: the registry keeps the name in the candidate set after the flag
			-- is cleared, so the false already fires. The two arms differ in one thing.
			local harness, events = makeHarness({ Perks = { "VIP" } })
			local player = harness.Join(88101)
			settle()

			harness.Data.GrantPerk(player, "VIP")
			settle()
			harness.Data.RevokePerk(player, "VIP")
			settle()

			expect(table.concat(events, ",")).to.equal("VIP=true,VIP=false")
			expect(harness.Data.Owns(player, "VIP")).to.equal(false)

			harness.Cleanup()
		end)

		it("reports both transitions for a perk outside the registry", function()
			-- The defect. No Perks registry at all, which is a supported way to use
			-- GrantPerk -- and the grant is reported while the revoke is not.
			local harness, events = makeHarness()
			local player = harness.Join(88102)
			settle()

			harness.Data.GrantPerk(player, "AdHocVIP")
			settle()
			harness.Data.RevokePerk(player, "AdHocVIP")
			settle()

			expect(table.concat(events, ",")).to.equal("AdHocVIP=true,AdHocVIP=false")
			-- Owns() was always right; the signal was the thing missing.
			expect(harness.Data.Owns(player, "AdHocVIP")).to.equal(false)

			harness.Cleanup()
		end)

		it("reports it exactly once, and does not keep re-reporting on later scans", function()
			-- The failure mode a candidate-set fix invites: keys retained forever, each
			-- one re-examined on every scan. A repeat false would be worse than the
			-- missing one, because listeners are not idempotent by contract.
			local harness, events = makeHarness()
			local player = harness.Join(88103)
			settle()

			harness.Data.GrantPerk(player, "AdHocVIP")
			harness.Data.RevokePerk(player, "AdHocVIP")
			settle()
			local afterRevoke = #events

			-- Several more scans, driven by unrelated ownership writes.
			harness.Data.GrantPerk(player, "Other")
			settle()
			harness.Data.RevokePerk(player, "Other")
			settle()

			local adHoc = 0
			for _, event in events do
				if event == "AdHocVIP=false" then
					adHoc += 1
				end
			end
			expect(adHoc).to.equal(1)
			expect(#events > afterRevoke).to.equal(true) -- the other perk did report

			harness.Cleanup()
		end)

		it("says nothing at all for a name that was never granted", function()
			-- The other control: retaining previously-seen keys must not turn into
			-- inventing keys. A name nobody ever held has no transitions.
			local harness, events = makeHarness()
			local player = harness.Join(88104)
			settle()

			harness.Data.RevokePerk(player, "NeverHeld")
			settle()

			expect(#events).to.equal(0)
			expect(harness.Data.Owns(player, "NeverHeld")).to.equal(false)

			harness.Cleanup()
		end)

		it("reports a re-grant after a revoke", function()
			-- The full cycle. A baseline that retained the key as `false` must still
			-- allow the next true through.
			local harness, events = makeHarness()
			local player = harness.Join(88105)
			settle()

			harness.Data.GrantPerk(player, "AdHocVIP")
			settle()
			harness.Data.RevokePerk(player, "AdHocVIP")
			settle()
			harness.Data.GrantPerk(player, "AdHocVIP")
			settle()

			expect(table.concat(events, ",")).to.equal("AdHocVIP=true,AdHocVIP=false,AdHocVIP=true")
			expect(harness.Data.Owns(player, "AdHocVIP")).to.equal(true)

			harness.Cleanup()
		end)
	end)
end
