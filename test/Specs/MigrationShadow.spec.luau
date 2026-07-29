--!nonstrict
-- Reconcile runs BEFORE migrations, so a migration guarded on `== nil` sees a
-- backfilled template default and silently does nothing. Reordering is not the fix
-- (it nil-indexes against raw stored data and fail-closed kicks every legacy
-- player), so Scribe re-runs the chain against the raw bytes in DevMode and warns
-- when the two results disagree.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local CODE = "MIGRATION_RECONCILE_DEPENDENT"

	local function warnings()
		return #Scribe.GetRecentLogs({ Code = CODE, Limit = 50 })
	end

	it("warns when a nil-guarded migration silently no-ops because of the backfill", function()
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Tutorial = { Done = false },
			},
			Options = {
				MigrationShadow = true,
				Migrations = {
					-- The classic shape: Reconcile already created Tutorial, so this
					-- guard never fires and returning players never get Done = true.
					[2] = function(data)
						if data.Tutorial == nil then
							data.Tutorial = { Done = true }
						end
					end,
				},
			},
		})
		harness.Fake.Persisted["Default/PLAYER_82001"] = { Coins = 5, _Scribe = { Version = 1 } }

		local before = warnings()
		harness.Join(82001)
		expect(warnings() > before).to.equal(true)

		harness.Cleanup()
	end)

	it("stays silent when the migration is safe against raw stored data", function()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }), Gems = Scribe.Int(0, { Min = 0 }) },
			Options = {
				MigrationShadow = true,
				Migrations = {
					-- Writes unconditionally, so the backfill changes nothing.
					[2] = function(data)
						data.Gems = 42
					end,
				},
			},
		})
		harness.Fake.Persisted["Default/PLAYER_82002"] = { Coins = 5, _Scribe = { Version = 1 } }

		local before = warnings()
		harness.Join(82002)
		expect(warnings()).to.equal(before)

		harness.Cleanup()
	end)

	it("is off unless MigrationShadow is opted into", function()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }), Tutorial = { Done = false } },
			Options = {
				Migrations = {
					[2] = function(data)
						if data.Tutorial == nil then
							data.Tutorial = { Done = true }
						end
					end,
				},
			},
		})
		harness.Fake.Persisted["Default/PLAYER_82003"] = { Coins = 5, _Scribe = { Version = 1 } }

		local before = warnings()
		harness.Join(82003)
		expect(warnings()).to.equal(before)

		harness.Cleanup()
	end)
end
