--!nonstrict
-- A Mode = "NoSave" dry run is what migrating.md tells people to validate against
-- real data with. It is fetched via GetAsync, which passes EditProfile = nil, so
-- ProfileStore's session-start increment never runs and SessionLoadCount sits one
-- BELOW a live join's. Comparing it raw judged a once-loaded profile brand new,
-- which stamped the current version and skipped every migration: the dry run
-- reported a clean load having validated nothing.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Template = require(Root.Scribe.Internal.Template)

	local function viewHarness(ranTable)
		return TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Gems = Scribe.Int(0, { Min = 0 }),
			},
			Options = {
				Mode = "NoSave",
				ViewedUserId = 606,
				Migrations = {
					[2] = function(data)
						table.insert(ranTable, 2)
						data.Gems = (tonumber(data.Coins) or 0) * 2
					end,
				},
			},
		})
	end

	it("runs migrations on a profile that has been loaded before", function()
		local ran = {}
		local harness = viewHarness(ran)
		-- Stored by an earlier session: real data, no _Scribe version root.
		harness.Fake.Persisted["Default/PLAYER_606"] = { Coins = 7 }

		local _player, _entry, data = harness.Join(606)

		expect(#ran).to.equal(1)
		expect(data.Gems.Get()).to.equal(14)
		harness.Cleanup()
	end)

	it("still treats a genuinely absent profile as new", function()
		local ran = {}
		local harness = viewHarness(ran)
		-- Nothing persisted: a view of a never-saved user is brand new, so the
		-- version is stamped and there is nothing to migrate.
		harness.Fake.Persisted["Default/PLAYER_606"] = nil

		local ok = pcall(function()
			harness.Join(606)
		end)
		if ok then
			expect(#ran).to.equal(0)
		end
		harness.Cleanup()
	end)

	it("a live load of the same stored data migrates identically", function()
		local ran = {}
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Gems = Scribe.Int(0, { Min = 0 }),
			},
			Options = {
				Migrations = {
					[2] = function(data)
						table.insert(ran, 2)
						data.Gems = (tonumber(data.Coins) or 0) * 2
					end,
				},
			},
		})
		harness.Fake.Persisted["Default/PLAYER_607"] = { Coins = 7 }

		local _player, entry, data = harness.Join(607)
		expect(#ran).to.equal(1)
		expect(data.Gems.Get()).to.equal(14)
		expect(entry.LiveData[Template.RESERVED_ROOT].Version >= 2).to.equal(true)
		harness.Cleanup()
	end)
end
