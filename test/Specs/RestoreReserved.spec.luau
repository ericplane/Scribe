--!nonstrict
-- RestoreVersion and the reserved `_Scribe` root.
--
-- A restore rolls GAME state back -- that is the whole point of it, and the
-- control test below pins that it still does. What it must NOT roll back is the
-- reserved root, because that root is not game state: it is the record of things
-- that happened in the REAL WORLD. ProcessedPurchaseIds says a receipt was
-- granted. PendingGifts and GiftCredits say Robux were spent. Perks say an
-- entitlement was bought. PurchaseLogs is the audit trail and Timed is a
-- cooldown that started ticking. None of that un-happens because an operator
-- restored yesterday's backup, so rolling it back does not undo a mistake, it
-- manufactures one -- most sharply, a receipt that was already paid out becomes
-- payable a SECOND time off the same PurchaseId, and Roblox re-delivers an
-- unacknowledged receipt for days.
--
-- So: preserved by default, and rolled back only when the caller asks for it in
-- so many words, for the case where the reserved root is ITSELF what is corrupt.
-- The assertions here are about those consequences, not about which table got
-- assigned where.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

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

	-- `grants` is a shared counter rather than an assertion on Coins, because the
	-- claim is that the GRANT CALLBACK did not run again. Coins can move for other
	-- reasons; the callback running twice is the thing that costs money.
	local function makeHarness(grants)
		return TestCtx.make({
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
					GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
				},
				GiftCooldown = 0,
				PromptProductPurchase = function() end,
			},
		})
	end

	local function keyFor(userId)
		return `Default/PLAYER_{userId}`
	end

	local function storedFor(harness, userId)
		return harness.Fake.Persisted[keyFor(userId)]
	end

	-- Version IDs are taken by DIFFING the history across a save, never by index.
	-- The ordering of ListVersions is the store's business, and a spec that pins
	-- `versions[1]` follows it silently if it ever flips -- restoring a different
	-- snapshot than it meant to and still passing.
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

	-- The dedupe ring stores `{ Id, At }`, and still reads bare strings written
	-- before age-based eviction shipped.
	local function hasPurchaseId(list, wanted)
		for _, item in list or {} do
			if (if type(item) == "string" then item else item.Id) == wanted then
				return true
			end
		end
		return false
	end

	local function reservedOf(data)
		return (data or {})._Scribe or {}
	end

	describe("RestoreVersion preserves the reserved root", function()
		it("does not make an already-granted receipt payable a second time", function()
			local grants = { Count = 0 }
			local harness = makeHarness(grants)
			local userId = 96101
			local player, _, data = harness.Join(userId)

			data.Coins.Set(100)
			local before = versionIds(harness, userId)
			harness.Data.Flush(player)
			local snapshot = newVersionSince(harness, userId, before)

			-- The snapshot predates the purchase, and its EMPTY dedupe ring is
			-- precisely what made rolling it back dangerous. Pinned, because a
			-- snapshot that already carried the marker would make everything below
			-- pass for the wrong reason.
			local snapshotRing = reservedOf(harness.Data.GetVersion(userId, snapshot)).ProcessedPurchaseIds
			expect(hasPurchaseId(snapshotRing, "money-1")).to.equal(false)

			expect(harness.Data.HandleReceipt(receipt(userId, 111, "money-1"))).to.equal(GRANTED)
			expect(grants.Count).to.equal(1)
			expect(data.Coins.Get()).to.equal(1100)

			-- A later change, so the restore has something real to undo.
			data.Coins.Set(5555)
			harness.Data.Flush(player)
			harness.Leave(player)

			expect((harness.Data.RestoreVersion(userId, snapshot))).to.equal(true)

			-- THE CONSEQUENCE. The player comes back and Roblox re-delivers the same
			-- receipt, as it does for days until one is acknowledged. It must be
			-- recognised as already paid: GRANTED so the retry stops, and the Grant
			-- callback NOT run a second time.
			local _, _, rejoined = harness.Join(userId)
			expect(harness.Data.HandleReceipt(receipt(userId, 111, "money-1"))).to.equal(GRANTED)
			expect(grants.Count).to.equal(1)
			expect(rejoined.Coins.Get()).to.equal(100)

			harness.Cleanup()
		end)

		it("keeps paid gift credits and perks, while ordinary fields DO roll back", function()
			-- The control half of this matters as much as the preserving half: if
			-- preserving quietly turned RestoreVersion into a no-op, every assertion
			-- about money surviving would pass and the feature would be gone.
			local grants = { Count = 0 }
			local harness = makeHarness(grants)
			local userId = 96102
			local player, _, data = harness.Join(userId)

			data.Coins.Set(100)
			local before = versionIds(harness, userId)
			harness.Data.Flush(player)
			local snapshot = newVersionSince(harness, userId, before)

			-- Money moves AFTER the snapshot: a perk the player owns, and a paid
			-- purchase that converted to a durable gift credit because they already
			-- owned it.
			harness.Data.GrantPerk(player, "VIP")
			expect(harness.Data.HandleReceipt(receipt(userId, 222, "credit-1"))).to.equal(GRANTED)
			expect(harness.Data.GetGiftCredits(player).GiftVIP).to.equal(1)

			data.Coins.Set(4242)
			harness.Data.Flush(player)
			harness.Leave(player)

			expect((harness.Data.RestoreVersion(userId, snapshot))).to.equal(true)

			local rejoinedPlayer, _, rejoined = harness.Join(userId)
			-- Paid-for state survived.
			expect(harness.Data.Owns(rejoinedPlayer, "VIP")).to.equal(true)
			expect(harness.Data.GetGiftCredits(rejoinedPlayer).GiftVIP).to.equal(1)
			expect(hasPurchaseId(reservedOf(storedFor(harness, userId)).ProcessedPurchaseIds, "credit-1")).to.equal(
				true
			)
			-- THE CONTROL: an ordinary game field went back to the snapshot.
			expect(rejoined.Coins.Get()).to.equal(100)

			harness.Cleanup()
		end)

		it("stamps RestoredFrom and reports the preservation to the operator", function()
			local grants = { Count = 0 }
			local harness = makeHarness(grants)
			local userId = 96103
			local player, _, data = harness.Join(userId)

			data.Coins.Set(100)
			local before = versionIds(harness, userId)
			harness.Data.Flush(player)
			local snapshot = newVersionSince(harness, userId, before)

			expect(harness.Data.HandleReceipt(receipt(userId, 111, "stamp-1"))).to.equal(GRANTED)
			harness.Leave(player)

			expect((harness.Data.RestoreVersion(userId, snapshot))).to.equal(true)

			local reserved = reservedOf(storedFor(harness, userId))
			expect(reserved.RestoredFrom).to.be.ok()
			expect(reserved.RestoredFrom.VersionId).to.equal(snapshot)

			-- The operator watching the numbers move is told, in the log, that the
			-- money state did NOT move with them.
			local logged = false
			for _, entry in Scribe.GetRecentLogs({ Code = "RESTORE_RESERVED_PRESERVED", Limit = 20 }) do
				if entry.Context ~= nil and entry.Context.UserId == userId then
					logged = true
				end
			end
			expect(logged).to.equal(true)

			harness.Cleanup()
		end)

		it("restores cleanly when the LIVE record has no reserved root at all", function()
			-- A legacy or imported key that has never carried `_Scribe`. There is
			-- nothing real-world to preserve, so the snapshot's own root stands and
			-- the stamp still lands -- rather than the restore erroring on a nil.
			local grants = { Count = 0 }
			local harness = makeHarness(grants)
			local userId = 96104
			local player, _, data = harness.Join(userId)

			data.Coins.Set(7)
			local before = versionIds(harness, userId)
			harness.Data.Flush(player)
			local snapshot = newVersionSince(harness, userId, before)

			data.Coins.Set(8)
			harness.Data.Flush(player)
			harness.Leave(player)
			storedFor(harness, userId)._Scribe = nil

			local ok, reason = harness.Data.RestoreVersion(userId, snapshot)
			expect(`{ok} {reason}`).to.equal("true nil")

			local stored = storedFor(harness, userId)
			expect(stored.Coins).to.equal(7)
			expect(reservedOf(stored).RestoredFrom.VersionId).to.equal(snapshot)

			harness.Cleanup()
		end)

		it("preserves the live root when the SNAPSHOT has no reserved root", function()
			-- The mirror shape: the history predates `_Scribe` entirely. Everything
			-- in the live root was therefore preserved, and a receipt granted since
			-- must still be recognised.
			local grants = { Count = 0 }
			local harness = makeHarness(grants)
			local userId = 96105
			local player, _, data = harness.Join(userId)

			data.Coins.Set(100)
			local before = versionIds(harness, userId)
			harness.Data.Flush(player)
			local snapshot = newVersionSince(harness, userId, before)
			for _, record in harness.Fake.Versions[keyFor(userId)] do
				if record.VersionId == snapshot then
					record.Data._Scribe = nil
				end
			end

			expect(harness.Data.HandleReceipt(receipt(userId, 111, "legacy-1"))).to.equal(GRANTED)
			expect(grants.Count).to.equal(1)
			harness.Leave(player)

			expect((harness.Data.RestoreVersion(userId, snapshot))).to.equal(true)

			harness.Join(userId)
			expect(harness.Data.HandleReceipt(receipt(userId, 111, "legacy-1"))).to.equal(GRANTED)
			expect(grants.Count).to.equal(1)

			harness.Cleanup()
		end)
	end)

	describe("RollBackReserved", function()
		it("rolls the reserved root back too, returning the dedupe ring to the snapshot", function()
			local grants = { Count = 0 }
			local harness = makeHarness(grants)
			local userId = 96111
			local player, _, data = harness.Join(userId)

			data.Coins.Set(100)
			local before = versionIds(harness, userId)
			harness.Data.Flush(player)
			local snapshot = newVersionSince(harness, userId, before)

			expect(harness.Data.HandleReceipt(receipt(userId, 111, "optin-1"))).to.equal(GRANTED)
			expect(hasPurchaseId(reservedOf(storedFor(harness, userId)).ProcessedPurchaseIds, "optin-1")).to.equal(true)
			harness.Leave(player)

			expect((harness.Data.RestoreVersion(userId, snapshot, { RollBackReserved = true }))).to.equal(true)

			-- The dedupe ring is back to its HISTORICAL contents: the marker written
			-- after the snapshot is gone, so that receipt is payable again. This is
			-- the dangerous direction, which is why it has to be asked for by name.
			local reserved = reservedOf(storedFor(harness, userId))
			expect(hasPurchaseId(reserved.ProcessedPurchaseIds, "optin-1")).to.equal(false)
			-- And the stamp lands in this mode too.
			expect(reserved.RestoredFrom.VersionId).to.equal(snapshot)

			harness.Cleanup()
		end)

		it("rejects a misspelled option instead of silently ignoring it", function()
			local harness = makeHarness({ Count = 0 })
			local ok, err = pcall(function()
				harness.Data.RestoreVersion(96112, "nope", { RollbackReserved = true })
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "RollBackReserved", 1, true) ~= nil).to.equal(true)
			harness.Cleanup()
		end)
	end)
end
