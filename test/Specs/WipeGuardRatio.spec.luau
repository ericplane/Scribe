--!nonstrict
-- WipeGuardShrinkRatio's domain.
--
-- The guard fires when the new serialized size falls below old * (1 - ratio), and
-- the configuration guide invites tuning it ("lower it to catch smaller
-- shrinkages"). Both ends of the range fail silently rather than loudly, which is
-- why this is validated rather than trusted:
--
--   ratio <= 0  every shrink trips the guard. Under WipeGuardPolicy = "Block"
--               that refuses the save AND keeps refusing, because the unblock
--               check is the same comparison -- so the session's live data never
--               reaches the DataStore again.
--   ratio >= 1  (1 - ratio) is zero or negative, so the comparison can never be
--               true and the guard a game asked for is quietly off.
--   ratio < 0   worse than either: (1 - ratio) exceeds 1, so a profile that GREW
--               trips a wipe guard.
--
-- Both were accepted without complaint before this.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local BIG = string.rep("x", 4000)

	--- Join, save a large blob, then shrink it hard and flush. Returns whether the
	--- guard refused the write, judged by what actually reached the store.
	local function shrinkAndFlush(harness, userId: number, shrinkTo: number): boolean
		local player, _entry, data = harness.Join(userId)
		data.Blob.Set(BIG)
		harness.Ctx.Persistence.Flush(player)
		local before = harness.Fake.Persisted[`Default/PLAYER_{userId}`].Blob
		expect(`seeded={#before}`).to.equal(`seeded={#BIG}`)

		data.Blob.Set(string.rep("x", shrinkTo))
		harness.Ctx.Persistence.Flush(player)
		local after = harness.Fake.Persisted[`Default/PLAYER_{userId}`].Blob
		return #after ~= shrinkTo -- the last-good snapshot went instead of the live data
	end

	local function harnessWith(ratio: any)
		return TestCtx.make({
			Template = { Blob = Scribe.String("", { MaxLength = 5000 }) },
			Options = { WipeGuardPolicy = "Block", WipeGuardShrinkRatio = ratio },
		})
	end

	local function clampLogs(): number
		return #Scribe.GetRecentLogs({ Code = "WIPE_GUARD_RATIO_CLAMPED", Limit = 10 })
	end

	it("refuses a ratio of zero, which would block every shrinking profile forever", function()
		local before = clampLogs()
		local harness = harnessWith(0)
		expect(`warned={clampLogs() > before}`).to.equal("warned=true")

		-- A one-byte shrink. At the requested ratio this trips; at the clamped one
		-- it cannot, and the write goes through.
		local blocked = shrinkAndFlush(harness, 98101, #BIG - 1)
		expect(`blocked={blocked}`).to.equal("blocked=false")

		harness.Cleanup()
	end)

	it("refuses a negative ratio, which would trip on a profile that grew", function()
		local before = clampLogs()
		local harness = harnessWith(-5)
		expect(`warned={clampLogs() > before}`).to.equal("warned=true")

		local blocked = shrinkAndFlush(harness, 98102, #BIG - 1)
		expect(`blocked={blocked}`).to.equal("blocked=false")

		harness.Cleanup()
	end)

	it("refuses a ratio of one or more, which would switch the guard off", function()
		local before = clampLogs()
		local harness = harnessWith(1)
		expect(`warned={clampLogs() > before}`).to.equal("warned=true")

		-- A total collapse. At the requested ratio nothing could ever trip; at the
		-- clamped one this is exactly what the guard is for.
		local blocked = shrinkAndFlush(harness, 98103, 1)
		expect(`blocked={blocked}`).to.equal("blocked=true")

		-- ...and it is clamped to the CEILING, not quietly reset to the default.
		-- 0.95 trips below 5% of the old size; the default 0.6 trips below 40%. A
		-- shrink to a fifth separates them, and "blocked" for both is what a
		-- collapse-only assertion cannot see.
		local moderate = shrinkAndFlush(harness, 98113, 800)
		expect(`moderate={moderate}`).to.equal("moderate=false")

		harness.Cleanup()
	end)

	it("leaves a ratio inside the range alone, and says nothing about it", function()
		-- The inertness arm. A legitimately strict setting must not be clamped, and
		-- must not produce a warning that trains people to ignore the warning.
		local before = clampLogs()
		local harness = harnessWith(0.1)
		expect(`warned={clampLogs() > before}`).to.equal("warned=false")

		-- 0.1 means "trip below 90% of the old size", and the value has to be the one
		-- REACHING the guard rather than the default it fell back to. A shrink to
		-- 60% is the discriminator: it trips at 0.1 and does not at the default 0.6.
		local blocked = shrinkAndFlush(harness, 98104, 2400)
		expect(`blocked={blocked}`).to.equal("blocked=true")

		harness.Cleanup()
	end)

	it("still applies the documented default when nothing is configured", function()
		local harness = TestCtx.make({
			Template = { Blob = Scribe.String("", { MaxLength = 5000 }) },
			Options = { WipeGuardPolicy = "Block" },
		})
		-- Default 0.6: a shrink to 10% trips, a shrink to 80% does not.
		expect(`collapse={shrinkAndFlush(harness, 98105, 400)}`).to.equal("collapse=true")
		expect(`ordinary={shrinkAndFlush(harness, 98106, 3200)}`).to.equal("ordinary=false")

		harness.Cleanup()
	end)
end
