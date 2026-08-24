--!nonstrict
-- The schema `Version` travels with the GAME DATA, not with the money.
--
-- RestoreReserved.spec pins the rule these specs exist alongside: a restore does
-- NOT roll the reserved `_Scribe` root back, because that root records things
-- that happened in the real world -- receipts granted, gifts paid for, perks
-- bought. That rule is right and the controls at the bottom of this file keep it
-- loud.
--
-- `Version` is the one member of that root that is NOT a real-world ledger. It is
-- metadata about the SHAPE of the game data sitting in the same table -- the data
-- a restore has just replaced wholesale with an older snapshot. Preserving it
-- along with the money wrote OLD-SHAPED game data stamped with the CURRENT schema
-- version, and the library then acted on the stamp:
--
--   * `runMigrations` returns early on `stored == currentVersion`, so the chain
--     never re-ran. The profile sat at the pre-migration shape, marked current,
--     forever -- the migration that was meant to fix it up skipped for good.
--   * The SILENT case: a pre-deploy snapshot for a player who has bought nothing
--     differs from the live root in `Version` and nothing else, and the
--     "did the reserved root differ?" comparator deliberately ignored `Version`.
--     The one difference that changed behaviour was the one difference the
--     operator was never told about.
--   * A staged deploy: a server on OLDER code reads a stored version ahead of its
--     own and fails closed (PROFILE_VERSION_AHEAD) -- a kick loop.
--
-- Two harnesses over one FakeProfileStore model the deploy directly, so none of
-- this is simulated by hand: `oldServer` has no Migrations (currentVersion 1) and
-- writes the v1 snapshot; `newServer` carries `[2] = Gems += 1000`
-- (currentVersion 2) and is the one that restores. The staged-deploy leg is
-- therefore asserted DIRECTLY -- the old server really does load the restored
-- profile -- rather than inferred from the stored number.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local function keyFor(userId)
		return `Default/PLAYER_{userId}`
	end

	local function receipt(userId, productId, purchaseId)
		return {
			PlayerId = userId,
			ProductId = productId,
			PurchaseId = purchaseId,
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		}
	end

	local function deepCopy(value)
		if type(value) ~= "table" then
			return value
		end
		local out = {}
		for k, v in value do
			out[k] = deepCopy(v)
		end
		return out
	end

	-- Version IDs by DIFFING the history across a save, never by index: the order
	-- ListVersions answers in is the store's business, and a spec that pins
	-- `versions[1]` follows a flip silently, restoring a different snapshot than it
	-- meant to and still passing.
	local function versionIds(harness, userId)
		local seen = {}
		for _, v in harness.Data.ListVersions(userId, 25) do
			seen[v.VersionId] = true
		end
		return seen
	end

	local function newVersionSince(harness, userId, before)
		for _, v in harness.Data.ListVersions(userId, 25) do
			if not before[v.VersionId] then
				return v.VersionId
			end
		end
		error("no new version was written by that save", 2)
	end

	local function snapshotRecord(fake, userId, versionId)
		for _, record in fake.Versions[keyFor(userId)] or {} do
			if record.VersionId == versionId then
				return record
			end
		end
		error("snapshot record not found", 2)
	end

	local function storedFor(fake, userId)
		return fake.Persisted[keyFor(userId)]
	end

	local function reservedOf(data)
		return (data or {})._Scribe or {}
	end

	local function hasPurchaseId(list, wanted)
		for _, item in list or {} do
			if (if type(item) == "string" then item else item.Id) == wanted then
				return true
			end
		end
		return false
	end

	local function countLogs(code, userId)
		local n = 0
		for _, entry in Scribe.GetRecentLogs({ Code = code, Limit = 200 }) do
			if userId == nil or (entry.Context ~= nil and entry.Context.UserId == userId) then
				n += 1
			end
		end
		return n
	end

	--- Restore, asserting SUCCESS with the store's own reason in the message. A bare
	--- `expect(ok).to.equal(true)` reports "expected true, got false" and swallows
	--- the sentence that says why, which is the whole diagnosis.
	local function restore(harness, userId, snapshot, opts)
		local ok, reason = harness.Data.RestoreVersion(userId, snapshot, opts)
		expect(`{ok} {reason}`).to.equal("true nil")
	end

	local PRODUCTS = {
		Coins1000 = {
			Id = 111,
			Category = "Currency",
			Grant = function(data)
				data.Coins.Increment(1000)
			end,
		},
	}

	--- The deploy. `oldServer` is the code that is live BEFORE the migration ships;
	--- `newServer` is the code that ships it. One disk between them, so the snapshot
	--- the old server wrote is genuinely a pre-migration snapshot rather than a
	--- table this spec assembled to look like one.
	local function deploy()
		local fake = FakeProfileStore.new()
		local grants = { Count = 0 }
		local oldServer = TestCtx.make({
			Fake = fake,
			Options = { Products = PRODUCTS, PromptProductPurchase = function() end },
		})
		local newServer = TestCtx.make({
			Fake = fake,
			Options = {
				Products = {
					Coins1000 = {
						Id = 111,
						Category = "Currency",
						Grant = function(data)
							grants.Count += 1
							data.Coins.Increment(1000)
						end,
					},
				},
				PromptProductPurchase = function() end,
				Migrations = {
					[2] = function(data)
						data.Gems = (data.Gems or 0) + 1000
					end,
				},
			},
		})
		return fake, oldServer, newServer, grants, function()
			newServer.Cleanup()
			oldServer.Cleanup()
		end
	end

	--- Play out the pre-deploy life of a profile on the OLD server and hand back the
	--- version id of its v1 snapshot: Coins = 9, Gems = 5, `_Scribe.Version` = 1.
	local function seedV1Snapshot(fake, oldServer, userId)
		local player, _, data = oldServer.Join(userId)
		data.Coins.Set(9)
		data.Gems.Set(5)
		local before = versionIds(oldServer, userId)
		oldServer.Data.Flush(player)
		local snapshot = newVersionSince(oldServer, userId, before)
		oldServer.Leave(player)

		-- Pin the snapshot's shape rather than assume it. Everything below is about
		-- what the restore does with a v1 snapshot; a snapshot that was somehow
		-- already at version 2 would make the whole file pass for the wrong reason.
		local record = snapshotRecord(fake, userId, snapshot)
		expect(record.Data.Gems).to.equal(5)
		expect(record.Data.Coins).to.equal(9)
		expect(reservedOf(record.Data).Version).to.equal(1)
		return snapshot, record
	end

	--- Deploy the migration: the player rejoins on the new server, migrates to
	--- Gems = 1005 / Version = 2, and leaves with that persisted.
	local function deployMigration(fake, newServer, userId)
		local player, entry, data = newServer.Join(userId)
		expect(data.Gems.Get()).to.equal(1005)
		expect(entry.LiveData._Scribe.Version).to.equal(2)
		newServer.Data.Flush(player)
		newServer.Leave(player)
		expect(reservedOf(storedFor(fake, userId)).Version).to.equal(2)
		return player
	end

	describe("a restore rolls the schema version back with the game data", function()
		it("PROBE-5: the migration RE-RUNS after restoring a pre-migration snapshot", function()
			local fake, oldServer, newServer, _, cleanup = deploy()
			local userId = 97101

			local snapshot = seedV1Snapshot(fake, oldServer, userId)
			deployMigration(fake, newServer, userId)

			restore(newServer, userId, snapshot)

			-- What landed on disk: the OLD game shape. Captured rather than asserted
			-- here, so the FIRST failing assertion below is the consequence and not the
			-- bookkeeping -- a spec whose version check fires first reports "expected 1,
			-- got 2" and never tells you the player's Gems were wrong.
			local stored = storedFor(fake, userId)
			expect(stored.Gems).to.equal(5)
			expect(stored.Coins).to.equal(9)
			local versionOnDisk = reservedOf(stored).Version

			-- THE CONSEQUENCE, and the assertion that matters: the player rejoins and
			-- the migration runs again against the restored data. The migrated VALUE is
			-- what is asserted, not the version number -- a profile stamped 2 with Gems
			-- still 5 is exactly the bug, and a version-only assertion would watch the
			-- number move and call it fixed.
			local _, entry, data = newServer.Join(userId)
			expect(data.Gems.Get()).to.equal(1005)
			expect(data.Coins.Get()).to.equal(9)
			expect(entry.LiveData._Scribe.Version).to.equal(2)
			-- ...and the reason it re-ran: the restore committed the SNAPSHOT's version.
			expect(versionOnDisk).to.equal(1)

			cleanup()
		end)

		it("PROBE-5d: the SILENT case -- reserved roots differing only in Version", function()
			-- The common restore, and the one that used to say nothing at all: a
			-- pre-deploy snapshot for a player who has bought NOTHING. Its reserved
			-- root is identical to the live one except for `Version`, and the
			-- comparator behind RESTORE_RESERVED_PRESERVED deliberately ignored
			-- `Version` -- so the single difference that changes what the next load
			-- does was the single difference the operator could not see.
			local fake, oldServer, newServer, _, cleanup = deploy()
			local userId = 97102

			local snapshot = seedV1Snapshot(fake, oldServer, userId)
			deployMigration(fake, newServer, userId)

			-- Make the two roots differ in `Version` and in NOTHING else, by building
			-- the snapshot's root out of the live one. Constructed rather than waited
			-- for, because the point is the exactness: any other difference would make
			-- the log fire for a reason that is not the one under test.
			local record = snapshotRecord(fake, userId, snapshot)
			local liveReserved = deepCopy(reservedOf(storedFor(fake, userId)))
			expect(liveReserved.Version).to.equal(2)
			liveReserved.Version = 1
			record.Data._Scribe = liveReserved

			expect(countLogs("RESTORE_RESERVED_PRESERVED", userId)).to.equal(0)
			restore(newServer, userId, snapshot)

			-- The behaviour: the version rolled back with the game data.
			local stored = storedFor(fake, userId)
			expect(stored.Gems).to.equal(5)
			expect(reservedOf(stored).Version).to.equal(1)

			-- AND THE OPERATOR IS TOLD. A schema version moving under a profile is a
			-- behaviour change on the next load -- migrations re-run -- so it is
			-- reported even though nothing here was "preserved" in the money sense.
			-- Silence was the actual defect, so this assertion is on the log, and on
			-- the numbers the log carries, not merely on a count being non-zero.
			local told = nil
			for _, entry in Scribe.GetRecentLogs({ Code = "RESTORE_RESERVED_PRESERVED", Limit = 50 }) do
				if entry.Context ~= nil and entry.Context.UserId == userId then
					told = entry
				end
			end
			expect(told).to.be.ok()
			expect(told.Context.SchemaVersion).to.equal(1)
			expect(told.Context.PreviousSchemaVersion).to.equal(2)
			expect(told.Context.VersionId).to.equal(snapshot)

			cleanup()
		end)

		it("PROBE-6: an OLDER server still loads the restored profile (no version-ahead kick)", function()
			-- The staged deploy, asserted DIRECTLY: `oldServer` is a real Scribe
			-- instance whose currentVersion is 1, and it really does load the key the
			-- restore just wrote. A stored version ahead of its own makes
			-- runMigrations fail closed under the default VersionAheadPolicy = "Kick",
			-- which is a kick loop for as long as that server is in the rotation.
			local fake, oldServer, newServer, _, cleanup = deploy()
			local userId = 97103

			local snapshot = seedV1Snapshot(fake, oldServer, userId)
			deployMigration(fake, newServer, userId)

			local aheadBefore = countLogs("PROFILE_VERSION_AHEAD", nil)
			restore(newServer, userId, snapshot)

			local player, entry, data, reason = oldServer.TryJoin(userId, 5)
			expect(`{reason}`).to.equal("nil")
			expect(data).to.be.ok()
			expect(entry).to.be.ok()
			expect(player.Kicked).to.equal(nil)
			-- The old server sees its OWN shape: unmigrated, exactly as it wrote it.
			expect(data.Gems.Get()).to.equal(5)
			expect(data.Coins.Get()).to.equal(9)
			expect(countLogs("PROFILE_VERSION_AHEAD", nil)).to.equal(aheadBefore)

			oldServer.Leave(player)
			cleanup()
		end)

		it("THE LEGACY EDGE: a snapshot with NO Version restores as version 1 and re-migrates", function()
			-- `nil` means "legacy, version 1" -- the same reading runMigrations gives an
			-- absent version -- and must NOT mean "keep the live one". Getting that
			-- default backwards reintroduces the whole bug for precisely the OLDEST
			-- profiles, the ones with the most migration steps to miss, while every
			-- test above still passes.
			--
			-- Both shapes of absence: the reserved root present but carrying no
			-- `Version` key, and no reserved root in the snapshot at all.
			for _, case in
				{
					{ UserId = 97104, Strip = "key" },
					{ UserId = 97105, Strip = "root" },
				}
			do
				local fake, oldServer, newServer, _, cleanup = deploy()
				local userId = case.UserId

				local snapshot = seedV1Snapshot(fake, oldServer, userId)
				deployMigration(fake, newServer, userId)

				local record = snapshotRecord(fake, userId, snapshot)
				if case.Strip == "key" then
					record.Data._Scribe.Version = nil
					expect(record.Data._Scribe).to.be.ok()
				else
					record.Data._Scribe = nil
				end

				restore(newServer, userId, snapshot)

				local stored = storedFor(fake, userId)
				expect(reservedOf(stored).Version).to.equal(1)
				expect(stored.Gems).to.equal(5)

				local _, entry, data = newServer.Join(userId)
				expect(data.Gems.Get()).to.equal(1005)
				expect(entry.LiveData._Scribe.Version).to.equal(2)

				cleanup()
			end
		end)
	end)

	describe("the money still does not roll back", function()
		it("CONTROL: an already-granted receipt is still not payable a second time", function()
			-- The fix above corrects a fix; it must not undo it. If carrying the
			-- snapshot's `Version` had been implemented by rolling the whole reserved
			-- root back, every assertion about the version would pass and a paid
			-- receipt would become payable again off the same PurchaseId.
			local fake, oldServer, newServer, grants, cleanup = deploy()
			local userId = 97106

			local snapshot = seedV1Snapshot(fake, oldServer, userId)
			deployMigration(fake, newServer, userId)

			-- The snapshot predates the purchase, and its EMPTY dedupe ring is exactly
			-- what made rolling it back dangerous.
			local snapshotRing = reservedOf(snapshotRecord(fake, userId, snapshot).Data).ProcessedPurchaseIds
			expect(hasPurchaseId(snapshotRing, "v-1")).to.equal(false)

			local player, _, data = newServer.Join(userId)
			expect(newServer.Data.HandleReceipt(receipt(userId, 111, "v-1"))).to.equal(GRANTED)
			expect(grants.Count).to.equal(1)
			data.Coins.Set(5555)
			newServer.Data.Flush(player)
			newServer.Leave(player)

			restore(newServer, userId, snapshot)
			local versionOnDisk = reservedOf(storedFor(fake, userId)).Version

			-- THE MONEY DID NOT ROLL BACK. Roblox re-delivers an unacknowledged receipt
			-- for days: it must be recognised as already paid, GRANTED so the retry
			-- stops, with the Grant callback NOT run a second time. Asserted BEFORE the
			-- version, so this test reports the money when the money is what broke.
			local _, _, rejoined = newServer.Join(userId)
			expect(newServer.Data.HandleReceipt(receipt(userId, 111, "v-1"))).to.equal(GRANTED)
			expect(grants.Count).to.equal(1)
			-- The ordinary field went back to the snapshot, so the restore is real.
			expect(rejoined.Coins.Get()).to.equal(9)
			-- ...and the version DID roll back, so the migration re-ran alongside all of
			-- the above. Both halves hold at once, which is the whole claim.
			expect(rejoined.Gems.Get()).to.equal(1005)
			expect(versionOnDisk).to.equal(1)

			cleanup()
		end)

		it("CONTROL: RollBackReserved = true still rolls EVERYTHING back, Version included", function()
			local fake, oldServer, newServer, grants, cleanup = deploy()
			local userId = 97107

			local snapshot = seedV1Snapshot(fake, oldServer, userId)
			deployMigration(fake, newServer, userId)

			local player = newServer.Join(userId)
			expect(newServer.Data.HandleReceipt(receipt(userId, 111, "rb-1"))).to.equal(GRANTED)
			expect(grants.Count).to.equal(1)
			newServer.Data.Flush(player)
			newServer.Leave(player)
			expect(hasPurchaseId(reservedOf(storedFor(fake, userId)).ProcessedPurchaseIds, "rb-1")).to.equal(true)

			restore(newServer, userId, snapshot, { RollBackReserved = true })

			-- The dangerous mode, unchanged: the whole reserved root is the snapshot's,
			-- version and dedupe ring alike. It is opt-in by name for this reason.
			local reserved = reservedOf(storedFor(fake, userId))
			expect(reserved.Version).to.equal(1)
			expect(hasPurchaseId(reserved.ProcessedPurchaseIds, "rb-1")).to.equal(false)
			expect(reserved.RestoredFrom.VersionId).to.equal(snapshot)

			cleanup()
		end)
	end)
end
