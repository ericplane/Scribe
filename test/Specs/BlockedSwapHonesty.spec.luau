--!nonstrict
-- The wipe guard's verdict has to describe the payload that WENT TO THE KEY.
--
-- Under `WipeGuardPolicy = "Block"` a save whose live data looks like a wipe is
-- turned into a rewrite of the last-good snapshot: `SetSaveSource` re-points
-- `profile.Data` and the write proceeds. `AwaitSave` must answer FALSE for such a
-- save, because none of the caller's bytes reached the key -- Monetization returns
-- `PurchaseGranted` off that boolean and Roblox never retries a granted receipt.
--
-- Scribe recorded the verdict when its own `OnSave` fired. That is SNAPSHOT time.
-- The store reads `profile.Data` later, at WRITE time, and `SetSaveSource` is
-- per-PROFILE -- the fork's own note on it says so: "a swap affects every transform
-- that has not run yet, including ones whose OnSave fired before the swap."
--
-- So a save that started clean and was still on the wire when a LATER save tripped
-- the guard had its payload swapped out from under it, wrote the last-good snapshot
-- instead, and still reported `Blocked = false`. `AwaitSave` and `Data.Flush`
-- answered TRUE for a save that stored none of the caller's data.
--
-- The fix is the one the fork's `ReleaseOnly` note already prescribes and the
-- `SetSaveSource` note already names: decide it in the transform, at write time,
-- from the identity of the table actually serialized.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function makeHarness()
		return TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Nick = Scribe.String("hello", { MaxLength = 8 }),
			},
			Options = { WipeGuardPolicy = "Block" },
		})
	end

	--- Join, write, and land one clean save so the guard has a baseline to compare
	--- against. Without it `LastSavedKeys` is nil and the guard cannot trip at all.
	local function baseline(harness, userId)
		local player, entry, data = harness.Join(userId)
		data.Coins.Set(1)
		expect(harness.Data.Flush(player, { Force = true })).to.equal(true)
		return player, entry, data
	end

	describe("a save whose payload the wipe guard swapped out", function()
		it("reports success for an ordinary, unblocked save", function()
			-- THE CONTROL. Everything below is about a specific lie; this pins that
			-- the honest answer still comes back for the ordinary case, so a fix that
			-- simply returned false more often cannot pass.
			local harness = makeHarness()
			local player, entry, data = baseline(harness, 97101)

			data.Coins.Set(4242)
			expect(harness.Data.Flush(player)).to.equal(true)
			expect(entry.Blocked).to.equal(false)
			expect(harness.Fake.Persisted["Default/PLAYER_97101"].Coins).to.equal(4242)

			harness.Cleanup()
		end)

		it("reports FAILURE for a save that is itself blocked", function()
			-- The half that already worked: the guard trips inside THIS save's own
			-- OnSave, so the snapshot-time capture happened to be right.
			local harness = makeHarness()
			local player, entry, data = baseline(harness, 97102)

			data.Coins.Set(4242)
			data.Nick.Set(nil) -- a top-level key vanishes: the guard trips
			local ok = harness.Data.Flush(player)

			expect(entry.Blocked).to.equal(true)
			expect(ok).to.equal(false)
			-- ...and the key really does still hold the last-good bytes.
			expect(harness.Fake.Persisted["Default/PLAYER_97102"].Coins).to.equal(1)

			harness.Cleanup()
		end)

		it("reports FAILURE when a LATER save's block swapped this save's payload", function()
			-- The defect. Save A snapshots clean, parks mid-save, and while it is
			-- parked save B trips the guard and re-points profile.Data. A's write then
			-- serializes the last-good snapshot -- and A's caller was told TRUE.
			local harness = makeHarness()
			local player, entry, data = baseline(harness, 97103)

			data.Coins.Set(4242)

			local armed = true
			harness.Fake.MidSave = function()
				if not armed then
					return
				end
				armed = false -- the nested save must not re-enter this hook
				-- The wipe, and a second save to make the guard see it. This runs
				-- AFTER save A's OnSave and BEFORE save A's write.
				data.Nick.Set(nil)
				entry.Profile:Save()
			end

			local ok = harness.Data.Flush(player)
			harness.Fake.MidSave = nil

			-- What actually reached the key: the last-good snapshot, not Coins=4242.
			expect(entry.Blocked).to.equal(true)
			expect(harness.Fake.Persisted["Default/PLAYER_97103"].Coins).to.equal(1)
			-- ...so the answer the caller got must not be "durable".
			expect(ok).to.equal(false)

			harness.Cleanup()
		end)

		it("reports success once the guard clears, from the blocked state", function()
			-- A CONTROL for the recovery path, not the mirror case: this save's own
			-- OnSave is the one that clears the guard, so snapshot and write agree and
			-- the answer was already right. It is here so the mirror case below cannot
			-- be satisfied by an implementation that simply says "true after any
			-- unblock".
			local harness = makeHarness()
			local player, entry, data = baseline(harness, 97104)

			data.Nick.Set(nil)
			expect(harness.Data.Flush(player)).to.equal(false)
			expect(entry.Blocked).to.equal(true)

			data.Nick.Set("hello")
			data.Coins.Set(555)
			local ok = harness.Data.Flush(player)

			expect(entry.Blocked).to.equal(false)
			expect(harness.Fake.Persisted["Default/PLAYER_97104"].Coins).to.equal(555)
			expect(ok).to.equal(true)

			harness.Cleanup()
		end)

		it("reports SUCCESS when a later save UNBLOCKED this save's payload mid-flight", function()
			-- THE MIRROR CASE, and the reason a write-time verdict is not just
			-- "answer false more often". Save A snapshots while the guard is tripped,
			-- so profile.Data is the last-good snapshot. It parks; save B repairs the
			-- shape, clears the guard, and re-points profile.Data back at the live
			-- tree. A's write therefore serializes the caller's real bytes -- and the
			-- honest answer is TRUE. Reading the snapshot-time flag gave FALSE here:
			-- harmless, but wrong, and it is the same single read that gave the
			-- dangerous answer in the test above. One fix has to get both directions
			-- right or it is not a fix, it is a bias.
			local harness = makeHarness()
			local player, entry, data = baseline(harness, 97105)

			-- Arm the wipe so save A's OWN OnSave trips the guard and swaps in the
			-- last-good snapshot.
			data.Nick.Set(nil)
			data.Coins.Set(777)

			local armed = true
			harness.Fake.MidSave = function()
				if not armed then
					return
				end
				armed = false
				-- Repair the shape and let a second save clear the guard, re-pointing
				-- profile.Data at the live tree before save A's write reads it.
				data.Nick.Set("hello")
				entry.Profile:Save()
			end

			local ok = harness.Data.Flush(player)
			harness.Fake.MidSave = nil

			-- The guard is clear and the caller's bytes really are on the key.
			expect(entry.Blocked).to.equal(false)
			expect(harness.Fake.Persisted["Default/PLAYER_97105"].Coins).to.equal(777)
			expect(harness.Fake.Persisted["Default/PLAYER_97105"].Nick).to.equal("hello")
			expect(ok).to.equal(true)

			harness.Cleanup()
		end)
	end)
end
