--!nonstrict
-- Migration chains, including a failing step: no save, no version stamp,
-- fail-closed kick.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)
	local Scribe = require(Root.Scribe)

	it("runs every step from storedVersion + 1 to current, in order, then stamps", function()
		local order = {}
		local harness = TestCtx.make({
			Options = {
				Migrations = {
					[2] = function(data)
						table.insert(order, 2)
						data.Gems = (data.Gems or 0) + 1000
					end,
					[3] = function(data)
						table.insert(order, 3)
						data.Nick = "migrated"
					end,
				},
			},
		})

		-- Seed a legacy (version-1, pre-Scribe) profile.
		harness.Fake.Persisted["Default/PLAYER_555"] = { Coins = 9, Gems = 5 }

		local player, entry, data = harness.Join(555)
		expect(table.concat(order, ",")).to.equal("2,3")
		expect(data.Gems.Get()).to.equal(1005)
		expect(data.Nick.Get()).to.equal("migrated")
		expect(data.Coins.Get()).to.equal(9)
		expect(entry.LiveData._Scribe.Version).to.equal(3)

		-- The stamp persists.
		harness.Data.Flush(player)
		expect(harness.Fake.Persisted["Default/PLAYER_555"]._Scribe.Version).to.equal(3)
		harness.Cleanup()
	end)

	it("does not re-run migrations for up-to-date profiles", function()
		local runs = 0
		local harness = TestCtx.make({
			Options = {
				Migrations = {
					[2] = function()
						runs += 1
					end,
				},
			},
		})
		local player = harness.Join(556)
		harness.Data.Flush(player)
		harness.Leave(player)
		expect(runs).to.equal(1)

		harness.Join(556)
		expect(runs).to.equal(1) -- stamped at 2; step must not run again
		harness.Cleanup()
	end)

	it("fails closed when a step throws: no save, no stamp, kick", function()
		local harness = TestCtx.make({
			Options = {
				Migrations = {
					[2] = function(data)
						data.Gems = 1
					end,
					[3] = function()
						error("corrupt migration")
					end,
				},
			},
		})
		local seeded = { Coins = 42, Gems = 0 }
		harness.Fake.Persisted["Default/PLAYER_600"] = seeded

		local issueFired = false
		local connection = Scribe.OnIssue:Connect(function(entry)
			if entry.Code == "MIGRATION_FAIL" then
				issueFired = true
			end
		end)

		local player = FakePlayer.new(600)
		harness.Ctx.Persistence.OnPlayerAdded(player)
		local data, reason = harness.Ctx.Persistence.WaitForData(player)

		expect(data).to.equal(nil)
		expect(reason).to.equal("migration-failed")
		expect(player.Kicked).to.be.ok()

		-- A half-migrated profile must never persist: the session's final save
		-- wrote the ORIGINAL data — step 2's mutation is absent and the
		-- version was not stamped.
		local persisted = harness.Fake.Persisted["Default/PLAYER_600"]
		expect(persisted.Coins).to.equal(42)
		expect(persisted.Gems).to.equal(0)
		expect(persisted._Scribe.Version).to.equal(1)

		task.wait() -- OnIssue handlers run on their own threads
		expect(issueFired).to.equal(true)
		local logs = Scribe.GetRecentLogs({ Code = "MIGRATION_FAIL", Limit = 5 })
		expect(#logs > 0).to.equal(true)

		if connection.Disconnect then
			connection:Disconnect()
		end
		harness.Cleanup()
	end)

	it("rejects non-contiguous migration tables at startup", function()
		expect(function()
			TestCtx.make({
				Options = {
					Migrations = { [3] = function() end }, -- missing step 2
				},
			})
		end).to.throw()
	end)
end
