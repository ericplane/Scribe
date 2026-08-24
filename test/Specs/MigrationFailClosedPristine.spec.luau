--!nonstrict
-- A migration that fails must leave `profile.Data` EXACTLY as it found it.
--
-- Fail-closed is the whole promise of the migration path: a chain that cannot be
-- completed must not leave a mark, so the unmodified original is what the session
-- release writes back and the chain retries on the next join. "Migrations ran on a
-- clone" used to be the entire argument for that, and it stopped being sufficient
-- the moment the reserved-root preserve started assigning the STORED `_Scribe`
-- table into the working copy BY REFERENCE. From then on
-- `work[RESERVED_ROOT].Version = currentVersion` was a write straight into the live
-- profile, and it sat ABOVE the unpersistable scan -- which can still reject.
--
-- The damage is not the stray number. The caller's all-default carve-out compares
-- `profile.Data` against the template defaults, and the reserved `Version` default
-- is a hard 1, so a premature stamp of 2 made that compare FALSE and sent a player
-- the carve-out exists to RESCUE down the kick branch instead. That is the second
-- test below, and it is the one that reads like an outage report.
--
-- The two CONTROLs are here because the invariant is broader than the bug that
-- exposed it: the throwing path was already correct, and a successful migration
-- must still stamp and commit. Both are what a future "tidy-up" of the ordering
-- would break in the other direction.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Template = require(Root.Scribe.Internal.Template)

	local RESERVED = Template.RESERVED_ROOT
	-- Lone high bytes are not valid UTF-8, so Util.findUnpersistable rejects them and
	-- the whole profile save would fail -- which is exactly what the scan exists to
	-- catch BEFORE the migrated tree is committed.
	local BAD_UTF8 = "\255\254"

	local harness

	local function makeHarness(migration)
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }), Gems = Scribe.Int(0, { Min = 0 }) },
			Options = { Migrations = { [2] = migration } },
		})
		return harness
	end

	local function key(userId: number): string
		return `Default/PLAYER_{userId}`
	end

	-- The live `profile.Data` table is the thing under test, and after a fail-closed
	-- load the entry is gone and the session released, so there is nowhere left to
	-- read it from. Grab the profile out of the fake's active-session map from INSIDE
	-- the migration body, which runs while the session is still open. The migration
	-- itself is handed `work` (the clone), never this table -- that is the point.
	local function captureProfile(userId: number): any
		return harness.Fake.ActiveProfiles[key(userId)]
	end

	-- One string, so a failure names every field that moved rather than only the
	-- first one asserted.
	local function snapshot(data: any): string
		return `coins={tostring(data.Coins)} gems={tostring(data.Gems)} junk={tostring(data.Junk)} `
			.. `version={tostring(data[RESERVED] and data[RESERVED].Version)}`
	end

	it("a migration producing unpersistable data fail-closes and leaves profile.Data untouched", function()
		local captured
		local h = makeHarness(function(data)
			captured = captureProfile(82001)
			data.Coins = 999
			data.Junk = BAD_UTF8
		end)
		h.Fake.Persisted[key(82001)] = { Coins = 500, Gems = 7, [RESERVED] = { Version = 1 } }

		local _player, _entry, accessor, reason = h.TryJoin(82001, 1)
		-- Real stored data is at risk, so this profile is SUPPOSED to fail closed.
		expect(`accessor={accessor ~= nil} reason={tostring(reason)}`).to.equal(
			"accessor=false reason=migration-failed"
		)

		-- And the fail-closed load left nothing behind. `version=1` is the assertion
		-- that fails when the stamp moves back above the scan: the reserved root in
		-- `work` IS this table, so stamping it early writes the 2 in here and the
		-- "migrations ran on a clone" invariant is simply false.
		expect(captured).to.be.ok()
		expect(snapshot(captured.Data)).to.equal("coins=500 gems=7 junk=nil version=1")

		-- Durability, and how bad the stray stamp actually is. The fake has no
		-- EndSessionWithoutSaving, so its EndSession writes profile.Data back -- the
		-- same shape any later save of the same table would take. A 2 reaching the key
		-- is permanent: the next join reads stored == current, SKIPS the broken chain
		-- entirely, and serves un-migrated data as migrated forever. Once nothing
		-- mutates `data`, it is 1 down every path into here.
		expect(h.Fake.Persisted[key(82001)][RESERVED].Version).to.equal(1)
		h.Cleanup()
	end)

	it("THE CONSEQUENCE: an all-default profile whose migration produces unpersistable data still LOADS", function()
		local h = makeHarness(function(data)
			data.Junk = BAD_UTF8
		end)
		-- All-default bytes with a completed save on record: a real returning player
		-- who never earned anything. Nothing of theirs is at risk, so the carve-out
		-- loads them un-migrated rather than manufacturing a permanent kick loop.
		h.Fake.Persisted[key(82002)] = { Coins = 0, Gems = 0, [RESERVED] = { Version = 1 } }

		local player, entry, accessor, reason = h.TryJoin(82002, 1)
		-- Without the ordering fix this is `accessor=false reason=migration-failed`
		-- and the player is KICKED: the premature stamp of 2 is compared against the
		-- template's reserved Version default of 1, the all-defaults test answers
		-- "not all defaults", and the carve-out declines to apply.
		expect(`accessor={accessor ~= nil} reason={tostring(reason)} kicked={tostring(player.Kicked)}`).to.equal(
			"accessor=true reason=nil kicked=nil"
		)
		expect(entry.State).to.equal("Ready")

		-- A live, working session rather than merely a non-nil accessor.
		accessor.Coins.Increment(5)
		expect(`coins={accessor.Coins.Get()} gems={accessor.Gems.Get()}`).to.equal("coins=5 gems=0")

		-- Left UNSTAMPED, so the chain retries on every join until the migration is
		-- fixed. Same number as the assertion above, read through the live tree: the
		-- carve-out only works BECAUSE the stamp never happened.
		expect(entry.LiveData[RESERVED].Version).to.equal(1)
		h.Cleanup()
	end)

	it("CONTROL: a migration that THROWS still fail-closes and still leaves data pristine", function()
		local captured
		local h = makeHarness(function(data)
			captured = captureProfile(82003)
			data.Coins = 999
			error("migration step 2 is broken")
		end)
		h.Fake.Persisted[key(82003)] = { Coins = 500, Gems = 7, [RESERVED] = { Version = 1 } }

		local _player, _entry, accessor, reason = h.TryJoin(82003, 1)
		expect(`accessor={accessor ~= nil} reason={tostring(reason)}`).to.equal(
			"accessor=false reason=migration-failed"
		)

		-- This path returns before the preserve and the stamp are reached, so it was
		-- correct all along. Asserted anyway: it is the same promise, and the obvious
		-- wrong "fix" for the test above is to move the stamp somewhere that breaks
		-- this one instead.
		expect(captured).to.be.ok()
		expect(snapshot(captured.Data)).to.equal("coins=500 gems=7 junk=nil version=1")
		expect(h.Fake.Persisted[key(82003)][RESERVED].Version).to.equal(1)
		h.Cleanup()
	end)

	it("CONTROL: a successful migration still stamps Version and still commits", function()
		local h = makeHarness(function(data)
			data.Gems = 42
		end)
		h.Fake.Persisted[key(82004)] = { Coins = 500, Gems = 0, [RESERVED] = { Version = 1 } }

		local player, entry, data = h.Join(82004)
		-- Moving the stamp below the scan must not LOSE it: everything from that point
		-- down commits unconditionally.
		expect(`coins={data.Coins.Get()} gems={data.Gems.Get()} version={entry.LiveData[RESERVED].Version}`).to.equal(
			"coins=500 gems=42 version=2"
		)

		h.Data.Flush(player)
		local persisted = h.Fake.Persisted[key(82004)]
		expect(`gems={persisted.Gems} version={persisted[RESERVED].Version}`).to.equal("gems=42 version=2")
		h.Cleanup()
	end)
end
