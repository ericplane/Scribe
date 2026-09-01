--!nonstrict
-- What the player is told when a load, or a live session, ends.
--
-- Five outcomes used to share one sentence, so "we couldn't load your data" covered a
-- throttle that clears in seconds and a profile that will never load again. These pin
-- that each cause names itself, that a game's own LoadFailureMessage still overrides all
-- of them, and that the throttle wording is earned from the store's error code rather
-- than guessed.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Template = require(Root.Scribe.Internal.Template)

	local RESERVED = Template.RESERVED_ROOT

	local LOAD = "We couldn't load your data. Please rejoin!"
	local LEGACY = "We couldn't check your existing data, and we didn't want to start you from scratch. Please rejoin!"
	local MIGRATION = "We couldn't update your data to this version of the game. Please rejoin!"
	local SCHEMA = "Your saved data doesn't match this version of the game. Please rejoin!"
	local THROTTLED = "Roblox's data service is busy right now. Please rejoin in a moment!"
	local SESSION_END = "Your data session has ended. Please rejoin!"
	local STOLEN = "Your data was opened on another server, so this session ended. Please rejoin!"
	local INTERRUPTED = "Your data session ended before it finished loading. Please rejoin!"
	local VERSION_AHEAD = "Your data is from a newer version of the game than this server. Please rejoin!"

	local THROTTLE_ERROR = "301: Request rejected due to throttling"

	local template = { Coins = Scribe.Int(0, { Min = 0 }) }

	local function key(userId: number): string
		return `Default/PLAYER_{userId}`
	end

	--- Join a player whose load is made to fail, and return the kick text.
	local function kickOnFailedLoad(harness, userId: number, failMessage: string?): string?
		harness.Fake.LoadFailMessage = failMessage or "mock load failure"
		harness.Fake.FailNextLoad = true
		local player = harness.TryJoin(userId)
		return player.Kicked
	end

	describe("the load path", function()
		it("says the generic thing when the store simply failed", function()
			local harness = TestCtx.make({ Template = template })
			local kicked = kickOnFailedLoad(harness, 70001)
			harness.Cleanup()
			expect(kicked).to.equal(LOAD)
		end)

		it("says RATE LIMITED when the store answered with a throttling code", function()
			local harness = TestCtx.make({ Template = template })
			-- 3xx is the throttling family; Failure.Classify reads the numeric prefix.
			local kicked = kickOnFailedLoad(harness, 70002, THROTTLE_ERROR)
			harness.Cleanup()
			expect(kicked).to.equal(THROTTLED)
		end)

		it("does NOT say rate limited for a 5xx, which is the service failing rather than throttling", function()
			local harness = TestCtx.make({ Template = template })
			local kicked = kickOnFailedLoad(harness, 70003, "502: API Services rejected request")
			harness.Cleanup()
			-- The whole point of the split: only a throttle is worth waiting out.
			expect(kicked).to.equal(LOAD)
		end)
	end)

	describe("the other three causes", function()
		it("says LEGACY IMPORT when ImportLegacyData threw", function()
			local harness = TestCtx.make({
				Template = template,
				Options = {
					ImportLegacyData = function()
						error("legacy store is down")
					end,
				},
			})
			local player, _entry, accessor, reason = harness.TryJoin(70010)
			local seen = `kicked={tostring(player.Kicked)} accessor={accessor ~= nil} reason={tostring(reason)}`
			harness.Cleanup()
			expect(seen).to.equal(`kicked={LEGACY} accessor=false reason=load-failed`)
		end)

		it("says MIGRATION when the migration chain failed", function()
			local harness = TestCtx.make({
				Template = template,
				Options = {
					Migrations = {
						[2] = function(data)
							-- Lone high bytes are not valid UTF-8, so the unpersistable scan
							-- rejects the migrated tree. Throwing would take the same branch.
							data.Junk = "\255\254"
						end,
					},
				},
			})
			-- Real stored data at version 1, so the all-defaults carve-out (which loads
			-- un-migrated rather than kicking) does not swallow the case.
			harness.Fake.Persisted[key(70011)] = { Coins = 500, [RESERVED] = { Version = 1 } }
			local player, _entry, accessor, reason = harness.TryJoin(70011)
			local seen = `kicked={tostring(player.Kicked)} accessor={accessor ~= nil} reason={tostring(reason)}`
			harness.Cleanup()
			expect(seen).to.equal(`kicked={MIGRATION} accessor=false reason=migration-failed`)
		end)

		it("says VERSION AHEAD when the data is newer than the server, not that a migration failed", function()
			-- A staged deploy: an old server picks up a profile a newer one already migrated.
			-- Nothing is broken and no migration ran, so blaming the migration chain points
			-- the player and whoever reads their report in exactly the wrong direction.
			local harness = TestCtx.make({ Template = template })
			harness.Fake.Persisted[key(70013)] = { Coins = 500, [RESERVED] = { Version = 99 } }
			local player, _entry, accessor, reason = harness.TryJoin(70013)
			local seen = `kicked={tostring(player.Kicked)} accessor={accessor ~= nil} reason={tostring(reason)}`
			harness.Cleanup()
			expect(seen).to.equal(`kicked={VERSION_AHEAD} accessor=false reason=migration-failed`)
		end)

		it("still says MIGRATION when a chain actually failed, so the two stay apart", function()
			local harness = TestCtx.make({
				Template = template,
				Options = {
					Migrations = {
						[2] = function(data)
							-- Lone high bytes are not valid UTF-8, so the unpersistable scan rejects it.
							data.Junk = string.char(255, 254)
						end,
					},
				},
			})
			harness.Fake.Persisted[key(70014)] = { Coins = 500, [RESERVED] = { Version = 1 } }
			local player = harness.TryJoin(70014)
			local kicked = player.Kicked
			harness.Cleanup()
			expect(kicked).to.equal(MIGRATION)
		end)

		it("lets VersionAheadMessage be named on its own", function()
			local mine = "This server is behind. Rejoin to get the current one!"
			local harness = TestCtx.make({ Template = template, Options = { VersionAheadMessage = mine } })
			harness.Fake.Persisted[key(70015)] = { Coins = 500, [RESERVED] = { Version = 99 } }
			local player = harness.TryJoin(70015)
			local kicked = player.Kicked
			harness.Cleanup()
			expect(kicked).to.equal(mine)
		end)

		it("says SCHEMA when stored data does not match the template", function()
			local harness = TestCtx.make({
				Template = template,
				Options = { SchemaPolicy = "Reject" },
			})
			harness.Fake.Persisted[key(70012)] = { Coins = "not a number" }
			local player, _entry, accessor, reason = harness.TryJoin(70012)
			local seen = `kicked={tostring(player.Kicked)} accessor={accessor ~= nil} reason={tostring(reason)}`
			harness.Cleanup()
			expect(seen).to.equal(`kicked={SCHEMA} accessor=false reason=load-failed`)
		end)
	end)

	describe("what a game can override", function()
		it("lets LoadFailureMessage still speak for every cause, so nothing changes under it", function()
			local mine = "Emberfall is having a moment. Rejoin!"
			local a = TestCtx.make({ Template = template, Options = { LoadFailureMessage = mine } })
			local plain = kickOnFailedLoad(a, 70020)
			local throttled = kickOnFailedLoad(a, 70021, THROTTLE_ERROR)
			a.Cleanup()

			local b = TestCtx.make({
				Template = template,
				Options = {
					LoadFailureMessage = mine,
					ImportLegacyData = function()
						error("down")
					end,
				},
			})
			local player = b.TryJoin(70022)
			local legacy = player.Kicked
			b.Cleanup()

			expect(`plain={plain == mine} throttled={throttled == mine} legacy={legacy == mine}`).to.equal(
				"plain=true throttled=true legacy=true"
			)
		end)

		it("lets ONE cause be named without flattening the others", function()
			local mine = "Our data provider is throttling us, give it a second!"
			local harness = TestCtx.make({ Template = template, Options = { RateLimitedMessage = mine } })
			local throttled = kickOnFailedLoad(harness, 70030, THROTTLE_ERROR)
			local plain = kickOnFailedLoad(harness, 70031)
			harness.Cleanup()
			-- The named one wins; every other cause keeps its own default rather than
			-- inheriting the override.
			expect(`throttled={throttled == mine} plain={plain == LOAD}`).to.equal("throttled=true plain=true")
		end)
	end)

	describe("a session that ends after it loaded", function()
		it("says STOLEN when another server took the profile, which is nearly always why", function()
			local harness = TestCtx.make({ Template = template, Options = { KickOnSessionEnd = true } })
			local player, entry = harness.Join(70040)
			harness.Fake.StealSession("PLAYER_70040")
			local seen = `kicked={tostring(player.Kicked)} stolen={tostring(entry.SessionStolen)}`
			harness.Cleanup()
			expect(seen).to.equal(`kicked={STOLEN} stolen=true`)
		end)

		it("says INTERRUPTED when the session went away before the load finished", function()
			local harness
			harness = TestCtx.make({
				Template = template,
				Options = {
					KickOnSessionEnd = true,
					ImportLegacyData = function(_player, userId)
						-- Taken from under the load, before OnSessionEnd is even connected, so
						-- SessionStolen is never set and only the Loading state tells the story.
						harness.Fake.StealSession(`PLAYER_{userId}`)
						return nil
					end,
				},
			})
			local player, _entry, accessor = harness.TryJoin(70041)
			local seen = `kicked={tostring(player.Kicked)} accessor={accessor ~= nil}`
			harness.Cleanup()
			expect(seen).to.equal(`kicked={INTERRUPTED} accessor=false`)
		end)

		it("falls back to the plain wording when the end was local, not a steal", function()
			local harness = TestCtx.make({ Template = template, Options = { KickOnSessionEnd = true } })
			local player, entry = harness.Join(70042)
			-- LocalSessionEnd is exactly what separates "we ended this" from "someone took
			-- it", so setting it reaches the default branch the other two cases skip.
			entry.LocalSessionEnd = true
			harness.Fake.StealSession("PLAYER_70042")
			local seen = `kicked={tostring(player.Kicked)} stolen={tostring(entry.SessionStolen)}`
			harness.Cleanup()
			expect(seen).to.equal(`kicked={SESSION_END} stolen=false`)
		end)

		it("lets SessionEndMessage speak for the whole family, and LoadFailureMessage not at all", function()
			local mine = "Emberfall moved your data. Rejoin!"
			local harness = TestCtx.make({
				Template = template,
				-- Both set, because the two families must not leak into each other: a game
				-- that worded its load failures has not thereby worded its session ends.
				Options = { KickOnSessionEnd = true, SessionEndMessage = mine, LoadFailureMessage = "WRONG FAMILY" },
			})
			local player = harness.Join(70043)
			harness.Fake.StealSession("PLAYER_70043")
			local stolen = player.Kicked
			local load = kickOnFailedLoad(harness, 70044)
			harness.Cleanup()
			expect(`stolen={stolen == mine} load={load == "WRONG FAMILY"}`).to.equal("stolen=true load=true")
		end)

		it("lets the steal be named without flattening the rest of the family", function()
			local mine = "Your save is open on another server."
			local harness = TestCtx.make({
				Template = template,
				Options = { KickOnSessionEnd = true, SessionStolenMessage = mine },
			})
			local a = harness.Join(70045)
			harness.Fake.StealSession("PLAYER_70045")
			local b, entryB = harness.Join(70046)
			entryB.LocalSessionEnd = true
			harness.Fake.StealSession("PLAYER_70046")
			local seen = `stolen={a.Kicked == mine} plain={b.Kicked == SESSION_END}`
			harness.Cleanup()
			expect(seen).to.equal("stolen=true plain=true")
		end)
	end)
end
