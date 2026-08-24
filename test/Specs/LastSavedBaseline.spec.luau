--!nonstrict
-- The wipe guard's baseline, and why the store no longer keeps a second copy of
-- every profile to provide it.
--
-- `Profile.LastSavedData` is the table each save's round trip decoded, held for the
-- life of the session so an owner can diff against what is stored.
--
-- WHAT THE NUMBER IS. Allocating 200 deep copies of ~22 KB profiles alongside the
-- live set raised the heap counter by 18.2 MiB against the live set's 22.1 MiB --
-- 83%, taken at a scale well past the ~1 MiB step `collectgarbage("count")` moves
-- in. It is not 100% because deep copies share interned strings; the table
-- structure and boxed values are duplicated in full.
--
-- WHAT IT IS NOT. It is not a promise that releasing gives 18 MiB back. Luau
-- exposes no forced collect, so comparing two live sets end to end measures when
-- the collector happened to run: attempted here at 120 sessions each way, and it
-- came back NEGATIVE -- the released run reading HIGHER than the retained one.
-- That result is recorded rather than dropped, because it is the honest bound on
-- what this environment can answer, and it is exactly the trap the audit's
-- calibration section warns about. The claim that survives needs no collector:
-- one profile-sized table per session stops being retained for the session's
-- lifetime and becomes collectable when its save is done with it.
--
-- Scribe read exactly three things from it: the top-level key set, its serialized
-- size (already cached on the entry), and -- under `WipeGuardPolicy = "Block"` --
-- the bytes themselves, which that policy writes back as the save payload. The
-- first two are a summary the save that established them can record for free, so
-- the store is told to stop retaining unless Block policy needs it.
--
-- THE POINT OF THIS FILE is that the guard must not care. Its two inputs are the
-- same values either way, so every check below is driven under both retention
-- modes and has to agree. A summary that quietly weakened Scribe's last line of
-- defence against total data loss would be a bad trade at any memory price.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function template()
		return {
			Coins = Scribe.Int(0, { Min = 0 }),
			Nick = Scribe.String("", { MaxLength = 32 }),
			Inventory = {},
			Quests = {},
		}
	end

	--- Fill a profile with enough to make a collapse obvious, then save it.
	local function seed(harness, player, data)
		data.Nick.Set(string.rep("n", 32))
		for i = 1, 40 do
			data.Inventory[`item{i}`].Set({ Count = i, Tag = string.rep("t", 20) })
		end
		harness.Data.Flush(player)
	end

	local function anomalies(harness)
		local seen = {}
		harness.Data.OnAnomaly:Connect(function(info)
			table.insert(seen, info.Reason)
		end)
		return seen
	end

	describe("what the store keeps", function()
		it("releases the second copy once a save has established the summary", function()
			local harness = TestCtx.make({ Template = template() })
			local player, entry, data = harness.Join(70001)

			-- Before the first save the store's copy IS the baseline, so it is there.
			expect(next(entry.Profile.LastSavedData) ~= nil).to.equal(true)
			expect(entry.LastSavedKeys).to.equal(nil)

			seed(harness, player, data)

			-- After it, the summary is on the entry and the copy is gone.
			expect(entry.LastSavedKeys).never.to.equal(nil)
			expect(entry.LastSavedKeys.Inventory).to.equal(true)
			expect(entry.LastSavedSize > 0).to.equal(true)
			expect(next(entry.Profile.LastSavedData)).to.equal(nil)
			harness.Cleanup()
		end)

		it("keeps it under Block policy, which writes those bytes back", function()
			-- The one setting that needs the real thing. Retention and the branch that
			-- rewrites the payload read the same variable, so they cannot disagree --
			-- and a version where they did would persist an empty profile.
			local harness = TestCtx.make({
				Template = template(),
				Options = { WipeGuardPolicy = "Block" },
			})
			local player, entry, data = harness.Join(70002)
			seed(harness, player, data)

			expect(next(entry.Profile.LastSavedData) ~= nil).to.equal(true)
			expect(entry.LastSavedKeys).never.to.equal(nil)
			harness.Cleanup()
		end)

		it("takes the summary from the payload that persisted, not from live data", function()
			-- A blocked save stores the last-good snapshot, so the baseline has to
			-- describe what is on the KEY. Taking it from live data would rebaseline
			-- the guard onto the very state it just refused.
			local harness = TestCtx.make({
				Template = template(),
				Options = { WipeGuardPolicy = "Block" },
			})
			local player, entry, data = harness.Join(70003)
			seed(harness, player, data)
			local sizeBefore = entry.LastSavedSize

			-- Make the live key set genuinely DIFFER from what persists: the key is
			-- removed outright, not emptied. A summary read off live data would come
			-- back without it and the two would be indistinguishable.
			entry.LiveData.Inventory = nil
			entry.LiveData.Nick = ""
			entry.SaveInfo.Dirty = true
			local seen = anomalies(harness)
			harness.Data.Flush(player)
			expect(entry.Blocked).to.equal(true)
			-- What persisted is the last-good snapshot, which still has the key.
			expect(harness.Fake.Persisted["Default/PLAYER_70003"].Inventory).never.to.equal(nil)

			-- So the baseline still knows about it. Read off live data instead, this
			-- would be nil -- and the guard would have rebaselined onto the very state
			-- it just refused, accepting the collapse as the new normal.
			expect(entry.LastSavedKeys.Inventory).to.equal(true)
			expect(entry.LastSavedSize).to.equal(sizeBefore)

			-- The consequence, driven: the next save still trips rather than passing.
			entry.SaveInfo.Dirty = true
			harness.Data.Flush(player)
			local trippedAgain = false
			for _, reason in seen do
				if string.find(tostring(reason), "WipeGuard", 1, true) then
					trippedAgain = true
				end
			end
			expect(trippedAgain).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("the guard behaves the same either way", function()
		-- Same scenario, both retention modes. The assertions are identical on
		-- purpose: a difference between them is the finding.
		local function vanishedKeys(policy: string)
			local harness = TestCtx.make({
				Template = template(),
				Options = { WipeGuardPolicy = policy },
			})
			local player, entry, data = harness.Join(if policy == "Block" then 70011 else 70010)
			seed(harness, player, data)
			local seen = anomalies(harness)

			-- A top-level key disappears entirely.
			entry.LiveData.Inventory = nil
			entry.SaveInfo.Dirty = true
			harness.Data.Flush(player)

			local tripped = false
			for _, reason in seen do
				if string.find(tostring(reason), "WipeGuard", 1, true) then
					tripped = true
				end
			end
			harness.Cleanup()
			return tripped
		end

		it("catches a vanished top-level key with the summary", function()
			expect(vanishedKeys("Warn")).to.equal(true)
		end)

		it("catches the same vanished key with the full baseline", function()
			expect(vanishedKeys("Block")).to.equal(true)
		end)

		local function collapsedSize(policy: string)
			local harness = TestCtx.make({
				Template = template(),
				Options = { WipeGuardPolicy = policy },
			})
			local player, entry, data = harness.Join(if policy == "Block" then 70021 else 70020)
			seed(harness, player, data)
			local seen = anomalies(harness)

			-- Every key survives; the contents collapse.
			for i = 1, 40 do
				entry.LiveData.Inventory[`item{i}`] = nil
			end
			entry.LiveData.Nick = ""
			entry.SaveInfo.Dirty = true
			harness.Data.Flush(player)

			local tripped = false
			for _, reason in seen do
				if string.find(tostring(reason), "size collapsed", 1, true) then
					tripped = true
				end
			end
			harness.Cleanup()
			return tripped
		end

		it("catches a size collapse with the summary", function()
			expect(collapsedSize("Warn")).to.equal(true)
		end)

		it("catches the same size collapse with the full baseline", function()
			expect(collapsedSize("Block")).to.equal(true)
		end)

		local function ordinaryEdit(policy: string)
			local harness = TestCtx.make({
				Template = template(),
				Options = { WipeGuardPolicy = policy },
			})
			local player, _entry, data = harness.Join(if policy == "Block" then 70031 else 70030)
			seed(harness, player, data)
			local seen = anomalies(harness)

			-- An ordinary change: nothing vanishes, nothing collapses.
			data.Coins.Set(500)
			data.Inventory.item1.Set({ Count = 99, Tag = "changed" })
			harness.Data.Flush(player)

			harness.Cleanup()
			return #seen
		end

		it("stays quiet on an ordinary edit with the summary", function()
			expect(ordinaryEdit("Warn")).to.equal(0)
		end)

		it("stays quiet on an ordinary edit with the full baseline", function()
			expect(ordinaryEdit("Block")).to.equal(0)
		end)

		it("still guards the FIRST save of a session, before any summary exists", function()
			-- The window the store's copy is still the baseline for: a load followed
			-- immediately by a collapse, with no save in between to summarise.
			local harness = TestCtx.make({ Template = template() })
			harness.Fake.Persisted["Default/PLAYER_70040"] = {
				Coins = 10,
				Nick = string.rep("n", 32),
				Inventory = { a = { Count = 1, Tag = string.rep("t", 400) } },
				Quests = {},
			}
			local player, entry = harness.Join(70040)
			expect(entry.LastSavedKeys).to.equal(nil)
			local seen = anomalies(harness)

			entry.LiveData.Inventory = nil
			entry.SaveInfo.Dirty = true
			harness.Data.Flush(player)

			local tripped = false
			for _, reason in seen do
				if string.find(tostring(reason), "WipeGuard", 1, true) then
					tripped = true
				end
			end
			expect(tripped).to.equal(true)
			harness.Cleanup()
		end)
	end)
end
