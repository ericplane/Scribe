--!nonstrict
-- Flush answers from what it already knows when there is nothing to save -- and
-- the invariant that makes that honest.
--
-- WHY THIS IS THE ONLY SAFE PART OF "DIRTY-AWARE SAVING". Skipping a profile's
-- AUTOSAVES sounds like the same idea and is not, because an autosave does two
-- things besides writing Data, both measured in the simulation:
--
--   * It refreshes MetaData.LastUpdate, which is the liveness heartbeat another
--     server reads. Past ASSUME_DEAD (630 s) with no save, a second server takes
--     the session outright -- and the incumbent does not notice: it stays Ready,
--     keeps handing out a live accessor, accepts writes, and loses them. Driven:
--     server 1 wrote 999 after the steal, Flush returned false, server 2 still read
--     100. With autosaves running the same contest correctly ends the incumbent's
--     session instead. The pinning specs live in SimHandoff/CrossServer.
--   * It is what delivers cross-server messages and gifts. Measured: the first save
--     on an idle recipient landed at exactly AUTO_SAVE_PERIOD, and delivery cannot
--     precede it, so skipping a clean profile's saves directly extends gift latency.
--
-- Removing a redundant Flush has neither property: nothing is deferred, so the
-- heartbeat and the message channel keep exactly today's cadence.
--
-- The second half of this file is the reason the first half is allowed to exist.
-- Answering "already durable" from SaveInfo.Dirty promotes that flag from an
-- optimisation hint to something a receipt path can be wrong about, so the flag is
-- driven across the write surface here rather than trusted.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Util = require(Root.Scribe.Internal.Util)
	local deepEquals = require(Root.Test.Helpers.DeepEquals)

	local function template()
		return {
			Coins = Scribe.Int(0, { Min = 0 }),
			Gems = Scribe.Int(0, { Min = 0 }),
			Nick = Scribe.String("", { MaxLength = 16 }),
			Booster = Scribe.Timed(false),
			Settings = { Music = true, Sfx = true },
			Inventory = {},
			Quests = {},
			Secret = Scribe.ServerOnly({ Flagged = false }),
			Pub = Scribe.Shared({ Title = "" }),
			Runtime = Scribe.Session({ InCombat = false }),
		}
	end

	local function saves(harness, key: string): number
		return harness.Fake.SaveCounts[`Default/{key}`] or 0
	end

	describe("a flush with nothing to save", function()
		it("spends no DataStore request and still answers true", function()
			local harness = TestCtx.make({ Template = template() })
			local player, _entry, data = harness.Join(63001)
			data.Coins.Set(10)

			expect(harness.Data.Flush(player)).to.equal(true)
			local after = saves(harness, "PLAYER_63001")

			-- Nothing has changed since that save landed.
			expect(harness.Data.Flush(player)).to.equal(true)
			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saves(harness, "PLAYER_63001")).to.equal(after)
			expect(Scribe.GetMetrics().FlushesAlreadyDurable >= 2).to.equal(true)

			harness.Cleanup()
		end)

		it("saves again the moment anything changes", function()
			-- The other half: the short circuit must not latch.
			local harness = TestCtx.make({ Template = template() })
			local player, _entry, data = harness.Join(63002)
			data.Coins.Set(1)
			harness.Data.Flush(player)
			local after = saves(harness, "PLAYER_63002")

			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saves(harness, "PLAYER_63002")).to.equal(after)

			data.Coins.Set(2)
			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saves(harness, "PLAYER_63002")).to.equal(after + 1)
			harness.Cleanup()
		end)

		it("answers true only when the live tree really is the stored tree", function()
			-- The claim behind the return value, checked against the disk rather than
			-- against the flag that produced it.
			local harness = TestCtx.make({ Template = template() })
			local player, entry, data = harness.Join(63003)
			data.Coins.Set(5)
			data.Inventory.Sword.Set({ Level = 2 })
			harness.Data.Flush(player)

			local before = saves(harness, "PLAYER_63003")
			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saves(harness, "PLAYER_63003")).to.equal(before)

			local same, why = deepEquals(entry.LiveData, harness.Fake.Persisted["Default/PLAYER_63003"])
			expect(`stored={same}, {tostring(why)}`).to.equal("stored=true, nil")
			harness.Cleanup()
		end)

		it("never short-circuits a Force flush", function()
			-- Force exists to push a wipe-guard-blocked save through. It has to reach
			-- the store even when the entry looks durable.
			local harness = TestCtx.make({ Template = template() })
			local player, _entry, data = harness.Join(63004)
			data.Coins.Set(3)
			harness.Data.Flush(player)
			local after = saves(harness, "PLAYER_63004")

			expect(harness.Data.Flush(player, { Force = true })).to.equal(true)
			expect(saves(harness, "PLAYER_63004")).to.equal(after + 1)
			harness.Cleanup()
		end)

		it("does not answer true off a FAILED save", function()
			-- Dirty is cleared when the payload is snapshotted, not when it lands, so
			-- a failure has to be what stops this rather than the flag alone.
			local harness = TestCtx.make({ Template = template() })
			local player, entry, data = harness.Join(63005)
			data.Coins.Set(7)
			harness.Fake.FailSaves = true
			harness.Data.Flush(player)
			harness.Fake.FailSaves = false

			expect(entry.SaveInfo.LastResult).to.equal("Fail")
			local before = saves(harness, "PLAYER_63005")
			-- Must issue a real save, not report the failed one as durable.
			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saves(harness, "PLAYER_63005")).to.equal(before + 1)
			harness.Cleanup()
		end)

		it("does not answer true while the wipe guard is blocking", function()
			-- A blocked save persists the last-good snapshot, so live data is NOT on
			-- disk however clean the entry looks.
			local harness = TestCtx.make({
				Template = template(),
				Options = { WipeGuardPolicy = "Block" },
			})
			local player, entry, data = harness.Join(63006)
			data.Nick.Set("someone")
			data.Inventory.Sword.Set({ Level = 9 })
			harness.Data.Flush(player)

			-- Collapse the profile so the guard trips and blocks.
			entry.LiveData.Inventory = {}
			entry.LiveData.Nick = ""
			entry.LastSavedSize = 100000
			entry.SaveInfo.Dirty = true
			harness.Data.Flush(player)
			expect(entry.Blocked).to.equal(true)

			local before = saves(harness, "PLAYER_63006")
			expect(harness.Data.Flush(player)).never.to.equal(nil)
			-- Whatever it answers, it must have gone to the store rather than reporting
			-- the blocked snapshot as this data's durability.
			expect(saves(harness, "PLAYER_63006") > before).to.equal(true)
			harness.Cleanup()
		end)

		it("does not call a freshly loaded profile durable", function()
			-- The case `LastResult == "Ok"` exists for, and it is not the failure case.
			-- finishLoad resets Dirty to false AFTER Reconcile, the migration chain, the
			-- version stamp and OnPlayerInit have written, so a profile that has just
			-- loaded looks clean while carrying changes no save has ever covered. A
			-- game that flushes in PlayerAdded must get a real save.
			local harness = TestCtx.make({ Template = template() })
			-- A returning player stored WITHOUT a field the template has since gained,
			-- so the load reconciles and the live tree genuinely differs from storage.
			harness.Fake.Persisted["Default/PLAYER_63008"] = { Coins = 25 }
			local player, entry = harness.Join(63008)

			expect(saves(harness, "PLAYER_63008")).to.equal(0)
			expect(entry.SaveInfo.Dirty).to.equal(false)
			-- ...and it really is not what is stored.
			local same = deepEquals(entry.LiveData, harness.Fake.Persisted["Default/PLAYER_63008"])
			expect(`clean but unsaved: differs={not same}`).to.equal("clean but unsaved: differs=true")

			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saves(harness, "PLAYER_63008")).to.equal(1)
			harness.Cleanup()
		end)

		it("still answers false for a player with no session", function()
			local harness = TestCtx.make({ Template = template() })
			local FakePlayer = require(Root.Test.Helpers.FakePlayer)
			expect(harness.Data.Flush(FakePlayer.new(63007))).to.equal(false)
			harness.Cleanup()
		end)
	end)

	describe("the flag the answer rests on", function()
		-- Anything that changes the PERSISTED bytes must either flag the profile
		-- dirty or already have saved them. A hole here is not a stale flush: it is
		-- Flush telling a receipt handler that a grant is on disk when it is not.
		local function battery(name: string, options, run)
			it(`stays sound through: {name}`, function()
				local harness = TestCtx.make({ Template = template(), Options = options })
				local player, entry, data = harness.Join(64000 + #name)
				-- A clean, durable starting point.
				data.Coins.Set(1)
				harness.Data.Flush(player)

				local before = Util.deepClone(entry.LiveData)
				entry.SaveInfo.Dirty = false
				run(harness, player, entry, data)

				local changed = not (deepEquals(before, entry.LiveData))
				if not changed then
					harness.Cleanup()
					return -- nothing to persist; the flag is free to be either way
				end
				-- Either it is flagged, or a save already carried it. Both are honest;
				-- "changed, clean, and not on disk" is the one that is not.
				local flagged = entry.SaveInfo.Dirty == true
				local onDisk = deepEquals(entry.LiveData, harness.Fake.Persisted[`Default/PLAYER_{64000 + #name}`])
				expect(`{name}: flagged={flagged} onDisk={onDisk}`).to.equal(
					`{name}: flagged={flagged or onDisk} onDisk={onDisk}`
				)
				expect(flagged or onDisk).to.equal(true)
				harness.Cleanup()
			end)
		end

		battery("a scalar write", nil, function(_h, _p, _e, data)
			data.Coins.Set(42)
		end)
		battery("a nested struct write", nil, function(_h, _p, _e, data)
			data.Settings.Music.Set(false)
		end)
		battery("a dictionary insert and remove", nil, function(_h, _p, _e, data)
			data.Inventory.Sword.Set({ Level = 1 })
		end)
		battery("an array insert", nil, function(_h, _p, _e, data)
			data.Quests.Insert({ Id = "q1" })
		end)
		battery("a ServerOnly write", nil, function(_h, _p, _e, data)
			data.Secret.Flagged.Set(true)
		end)
		battery("a Shared write", nil, function(_h, _p, _e, data)
			data.Pub.Title.Set("hello")
		end)
		battery("a Timed field", nil, function(_h, _p, _e, data)
			data.Booster.SetTimed(true, 600)
		end)
		battery("a cooldown", nil, function(harness, player)
			harness.Data.OnCooldown(player, "Daily", 3600)
		end)
		battery("an internal claim", nil, function(harness, _p, entry)
			harness.Ctx.Timed.Claim(entry, "@t|once", 600)
		end)
		battery("a transaction", nil, function(harness, player, _e, data)
			harness.Data.Transaction(player, function()
				data.Gems.Set(11)
				data.Coins.Increment(1)
			end)
		end)
		battery("a soft-currency purchase", nil, function(harness, player, _e, data)
			data.Coins.Set(1000)
			harness.Data.Purchase(player, {
				Cost = { Path = "Coins", Amount = 10 },
				Category = "T",
				ItemId = "X",
				IdempotencyKey = "k1",
				Grant = function() end,
			})
		end)
		battery("a granted perk", { Perks = { VIP = true } }, function(harness, player)
			harness.Data.GrantPerk(player, "VIP")
		end)
		battery("a lapsing cooldown swept", nil, function(harness, player, entry)
			harness.Data.OnCooldown(player, "Short", 3600)
			entry.LiveData._Scribe.Timed["@cd|Short"] = os.time() - 1
			harness.Ctx.Timed.Sweep(entry)
		end)

		it("a Robux receipt leaves the grant on disk, not merely flagged", function()
			-- The sharpest one, and the reason the battery above accepts "already
			-- saved" as sound: the receipt path flushes itself, so it ends CLEAN with
			-- the grant persisted. If that ever stopped being true, Flush would answer
			-- true for a grant living only in memory.
			local harness = TestCtx.make({
				Template = template(),
				Options = { Products = { { Id = 111, Name = "Pack", Grants = "VIP" } }, Perks = { VIP = true } },
			})
			local player, entry, data = harness.Join(63009)
			data.Coins.Set(1)
			harness.Data.Flush(player)

			harness.Data.HandleReceipt({
				PlayerId = 63009,
				ProductId = 111,
				PurchaseId = "pid-1",
				CurrencySpent = 100,
			})

			local same = deepEquals(entry.LiveData, harness.Fake.Persisted["Default/PLAYER_63009"])
			expect(`clean={entry.SaveInfo.Dirty == false} onDisk={same}`).to.equal("clean=true onDisk=true")
			-- ...so a flush right after a receipt is genuinely free, and honest.
			local before = saves(harness, "PLAYER_63009")
			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saves(harness, "PLAYER_63009")).to.equal(before)
			local _ = player
			harness.Cleanup()
		end)

		it("a Session-scope write is not persisted and must not flag the profile", function()
			-- The inverse error: flagging on a write that never reaches the DataStore
			-- would make every profile permanently dirty and the answer useless.
			local harness = TestCtx.make({ Template = template() })
			local player, entry, data = harness.Join(63010)
			data.Coins.Set(1)
			harness.Data.Flush(player)
			expect(entry.SaveInfo.Dirty).to.equal(false)

			data.Runtime.InCombat.Set(true)
			expect(entry.SaveInfo.Dirty).to.equal(false)
			local before = saves(harness, "PLAYER_63010")
			expect(harness.Data.Flush(player)).to.equal(true)
			expect(saves(harness, "PLAYER_63010")).to.equal(before)
			local _ = player
			harness.Cleanup()
		end)
	end)
end
