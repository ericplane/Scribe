--!nonstrict
-- The template-fresh detector exists to rescue a first session that crashed before
-- saving. Its input is "stored bytes equal the current template", which a RETURNING
-- player who simply never earned anything also matches, so it skipped every
-- migration for them. profile.UserIds discriminates: ProfileStore writes it only as
-- part of a completed save.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Template = require(Root.Scribe.Internal.Template)

	local function harnessWith(ran, migration)
		return TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }), Gems = Scribe.Int(0, { Min = 0 }) },
			Options = {
				Migrations = {
					[2] = migration or function(data)
						table.insert(ran, 2)
						data.Gems = 99
					end,
				},
			},
		})
	end

	it("runs migrations for a returning player whose data is all defaults", function()
		local ran = {}
		local harness = harnessWith(ran)
		-- All-default bytes, but a completed save is on record: a real returning player.
		harness.Fake.Persisted["Default/PLAYER_81001"] = { Coins = 0, Gems = 0, _Scribe = { Version = 1 } }

		local _p, _e, data = harness.Join(81001)
		expect(#ran).to.equal(1)
		expect(data.Gems.Get()).to.equal(99)
		harness.Cleanup()
	end)

	it("still treats a crashed first session as fresh and skips migrations", function()
		local ran = {}
		local harness = harnessWith(ran)
		harness.Fake.Persisted["Default/PLAYER_81002"] = { Coins = 0, Gems = 0, _Scribe = { Version = 1 } }
		-- Persisted, but no save ever completed: the shape the detector exists for.
		harness.Fake.NeverSaved["Default/PLAYER_81002"] = true

		local _p, entry, data = harness.Join(81002)
		expect(#ran).to.equal(0)
		expect(data.Gems.Get()).to.equal(0)
		-- Treated as new, so the current version is stamped.
		expect(entry.LiveData[Template.RESERVED_ROOT].Version).to.equal(2)
		harness.Cleanup()
	end)

	it("loads an all-default returning player un-migrated rather than kicking", function()
		local harness = harnessWith({}, function()
			error("migration step 2 is broken")
		end)
		harness.Fake.Persisted["Default/PLAYER_81003"] = { Coins = 0, Gems = 0, _Scribe = { Version = 1 } }

		-- Nothing but template defaults is at risk, so a broken migration must not
		-- turn into a permanent kick loop for a player who loads fine today.
		local player, entry = harness.Join(81003)
		expect(player.Kicked).to.equal(nil)
		-- Left UNSTAMPED, so the chain retries next join once the migration is fixed.
		expect(entry.LiveData[Template.RESERVED_ROOT].Version).to.equal(1)
		harness.Cleanup()
	end)

	it("still kicks when a migration fails on a profile with real stored data", function()
		local harness = harnessWith({}, function()
			error("migration step 2 is broken")
		end)
		harness.Fake.Persisted["Default/PLAYER_81004"] = { Coins = 500, Gems = 0, _Scribe = { Version = 1 } }

		local ok = pcall(function()
			harness.Join(81004)
		end)
		-- Real data at risk: fail closed, exactly as before.
		expect(ok).to.equal(false)
		harness.Cleanup()
	end)
end
