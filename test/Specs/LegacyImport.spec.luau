--!nonstrict
-- ImportLegacyData: adopting a player's data from another library, once.
--
-- The hook fires in the load path BEFORE Reconcile and before migrations, and the
-- three things that make it correct are all things a "did the data arrive" spec
-- cannot see:
--
--   * it yields, and it yields for every player Scribe has never saved for, ~300
--     lines above the load path's existing liveness re-check;
--   * adopted data has never seen a Scribe migration, so it must enter at version 1
--     and run the ENTIRE chain -- the version stamp that makes a new profile skip
--     migrations is exactly wrong for it;
--   * "new to Scribe" stops meaning "new player" the moment an import lands, and
--     three separate decisions downstream are keyed on that.

local TestCtx = require(script.Parent.Parent.Helpers.TestCtx)
local FakePlayer = require(script.Parent.Parent.Helpers.FakePlayer)

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)

	local KEY = "Default/PLAYER_96001"

	local function makeHarness(options, template)
		return TestCtx.make({
			Template = template or {
				Coins = Scribe.Int(0, { Min = 0 }),
				Nick = Scribe.String("", { MaxLength = 16 }),
			},
			Options = options,
		})
	end

	describe("adopting legacy data", function()
		it("carries the old library's data into the new profile", function()
			local harness = makeHarness({
				ImportLegacyData = function()
					return { Coins = 1234, Nick = "carried" }
				end,
			})
			local _player, entry, data = harness.Join(96001)

			expect(entry).never.to.equal(nil)
			expect(data.Coins.Get()).to.equal(1234)
			expect(data.Nick.Get()).to.equal("carried")
			harness.Cleanup()
		end)

		it("still reconciles the template keys the import did not bring", function()
			-- The hook fires BEFORE Reconcile, which is what lets a partial legacy
			-- shape become a complete profile. Placed after it, every field the old
			-- library never had would stay absent and read nil forever.
			local harness = makeHarness({
				ImportLegacyData = function()
					return { Coins = 50 }
				end,
			})
			local _player, _entry, data = harness.Join(96001)

			expect(data.Coins.Get()).to.equal(50)
			expect(data.Nick.Get()).to.equal("") -- the template default, backfilled
			harness.Cleanup()
		end)

		it("does nothing when the hook says there is nothing to carry", function()
			-- nil is the ordinary answer for a genuinely new player, and it has to
			-- leave the load exactly as it was -- including the new-profile flag that
			-- first-session logic keys on.
			local newProfileFlags = {}
			local harness = makeHarness({
				ImportLegacyData = function()
					return nil
				end,
				OnPlayerInit = function(_player, _data, isNewProfile)
					table.insert(newProfileFlags, isNewProfile)
				end,
			})
			local _player, _entry, data = harness.Join(96001)

			expect(data.Coins.Get()).to.equal(0)
			expect(newProfileFlags[1]).to.equal(true)
			harness.Cleanup()
		end)

		it("never adopts Scribe's own roots, including the session one", function()
			-- The prefix test catches "_ScribeSession" as well as "_Scribe", and that
			-- is intended. Session state is per-boot and never stored, and letting an
			-- import write into _Scribe would hand the old library's table direct
			-- control of purchase-dedupe ids, granted perks and cooldown deadlines.
			local harness = makeHarness({
				ImportLegacyData = function()
					return {
						Coins = 7,
						_Scribe = { Perks = { Founder = true }, Version = 999 },
						_ScribeSession = { OwnsCache = { VIP = true } },
					}
				end,
			})
			local player, _entry, data = harness.Join(96001)

			expect(data.Coins.Get()).to.equal(7)
			-- The forged perk did not land, so it cannot be read back as ownership.
			expect(harness.Data.Owns(player, "Founder")).to.equal(false)

			-- The session root needs its own assertion, because behaviour cannot show
			-- it. Session state is rebuilt from the template every session and never
			-- read back from stored data, so an adopted _ScribeSession changes nothing
			-- observable -- it simply sits in the saved profile forever, growing it
			-- with a blob nothing will ever read. Only the persisted shape shows it,
			-- which is what an exact `key == "_Scribe"` test would let through.
			expect(harness.Data.Flush(player)).to.equal(true)
			local stored = harness.Fake.Persisted[KEY]
			expect(stored).never.to.equal(nil)
			expect(stored._ScribeSession).to.equal(nil)
			expect(stored._Scribe.Perks.Founder).to.equal(nil)
			harness.Cleanup()
		end)
	end)

	describe("adopted data runs the whole migration chain", function()
		-- The single most important property, and the one the load path's own
		-- new-profile handling gets wrong by default: a profile Scribe has never
		-- written IS new, so it is stamped at the current version and every migration
		-- is skipped. Adopted data has never seen ANY of them.
		local function chainHarness(importer)
			local steps = {}
			local harness = makeHarness({
				ImportLegacyData = importer,
				Migrations = {
					[2] = function(data)
						table.insert(steps, 2)
						data.Coins = (data.Coins or 0) * 10
					end,
					[3] = function(data)
						table.insert(steps, 3)
						data.Nick = `v3-{tostring(data.Nick)}`
					end,
				},
			})
			return harness, steps
		end

		it("runs every step against imported data", function()
			local harness, steps = chainHarness(function()
				return { Coins = 5, Nick = "old" }
			end)
			local _player, _entry, data = harness.Join(96001)

			expect(table.concat(steps, ",")).to.equal("2,3")
			expect(data.Coins.Get()).to.equal(50)
			expect(data.Nick.Get()).to.equal("v3-old")
			harness.Cleanup()
		end)

		it("runs none of them for a genuinely new player", function()
			-- The control. Without it, "the chain ran" would pass just as well if the
			-- version stamp had been removed for everybody -- which would re-run every
			-- migration against fresh defaults on every new join, the double-apply
			-- hazard the stamp exists to prevent.
			local harness, steps = chainHarness(function()
				return nil
			end)
			local _player, _entry, data = harness.Join(96001)

			expect(#steps).to.equal(0)
			expect(data.Coins.Get()).to.equal(0)
			harness.Cleanup()
		end)
	end)

	describe("an import is not a first session", function()
		it("does not hand an imported player the new-profile flag", function()
			-- They arrive carrying a full inventory from the old library. Reporting
			-- them as a new profile runs the starter-kit path on top of it, which is
			-- the exact double-grant that flag exists to prevent everywhere else.
			local seen = {}
			local harness = makeHarness({
				ImportLegacyData = function()
					return { Coins = 900 }
				end,
				OnPlayerInit = function(_player, _data, isNewProfile)
					table.insert(seen, isNewProfile)
				end,
			})
			harness.Join(96001)

			expect(seen[1]).to.equal(false)
			harness.Cleanup()
		end)

		it("leaves a Scribe.Dynamic value the import carried", function()
			-- Dynamic fields are force-seeded for a new profile, because its stored
			-- copy is a dead boot's declaration-time sample. An imported profile's
			-- value is real data, and seeding over it destroys it.
			local harness = makeHarness({
				ImportLegacyData = function()
					return { Token = "from-legacy" }
				end,
			}, {
				Coins = Scribe.Int(0, { Min = 0 }),
				Token = Scribe.Dynamic(function()
					return "freshly-generated"
				end),
			})
			local _player, _entry, data = harness.Join(96001)

			expect(data.Token.Get()).to.equal("from-legacy")
			harness.Cleanup()
		end)
	end)

	describe("importing happens exactly once", function()
		it("does not re-import after a save has committed", function()
			-- A returning player's Scribe profile is canonical. Re-importing would
			-- overwrite everything they earned since with whatever the old library
			-- still holds.
			local calls = 0
			local fake = require(Root.Test.Helpers.FakeProfileStore).new()
			local harness = TestCtx.make({
				Fake = fake,
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					ImportLegacyData = function()
						calls += 1
						return { Coins = 100 }
					end,
				},
			})

			local player, _entry, data = harness.Join(96001)
			data.Coins.Set(500) -- earned after the import
			expect(harness.Data.Flush(player)).to.equal(true)
			harness.Leave(player)

			local _p2, _e2, data2 = harness.Join(96001)
			expect(calls).to.equal(1)
			expect(data2.Coins.Get()).to.equal(500)
			harness.Cleanup()
		end)

		it("DOES import after a first session whose save never committed", function()
			-- The reason the gate is "no save has ever committed" and not "this is
			-- session load 1". SessionLoadCount advances when a session STARTS, so a
			-- first join that crashed before saving leaves the player non-new with
			-- nothing stored. Gating on `isNew` would refuse to import them, and the
			-- empty profile Scribe then saved would become canonical while their real
			-- data sat untouched in the old library's key.
			local calls = 0
			local fake = require(Root.Test.Helpers.FakeProfileStore).new()
			-- Persisted, so SessionLoadCount reports 2 -- but never actually saved, so
			-- UserIds is empty. Exactly the shape a crashed first session leaves.
			fake.Persisted[KEY] = {}
			fake.NeverSaved[KEY] = true

			local harness = TestCtx.make({
				Fake = fake,
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					ImportLegacyData = function()
						calls += 1
						return { Coins = 4242 }
					end,
				},
			})
			local _player, _entry, data = harness.Join(96001)

			expect(calls).to.equal(1)
			expect(data.Coins.Get()).to.equal(4242)
			harness.Cleanup()
		end)

		it("is skipped for a read-only NoSave view", function()
			-- A view cannot persist what it imports, so running the hook there pays for
			-- a live DataStore read -- and whatever else the developer put in it -- to
			-- produce a result that is thrown away. The profile is set up so that the
			-- no-prior-save gate would otherwise let the import through, which is what
			-- makes the mode check the thing being tested.
			local calls = 0
			local fake = require(Root.Test.Helpers.FakeProfileStore).new()
			fake.Persisted[KEY] = { Coins = 11 }
			fake.NeverSaved[KEY] = true

			local harness = TestCtx.make({
				Fake = fake,
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					UseMock = false,
					Mode = "NoSave",
					ImportLegacyData = function()
						calls += 1
						return { Coins = 999 }
					end,
				},
			})
			local _player, _entry, data = harness.Join(96001)

			expect(calls).to.equal(0)
			expect(data.Coins.Get()).to.equal(11)
			harness.Cleanup()
		end)

		it("is skipped entirely under ResetData", function()
			local calls = 0
			local harness = makeHarness({
				ResetData = true,
				ImportLegacyData = function()
					calls += 1
					return { Coins = 100 }
				end,
			})
			local _player, _entry, data = harness.Join(96001)

			expect(calls).to.equal(0)
			expect(data.Coins.Get()).to.equal(0)
			harness.Cleanup()
		end)
	end)

	describe("a hook that cannot answer fails the load closed", function()
		it("refuses the load rather than starting the player empty", function()
			-- The destructive alternative is subtle and permanent: load them on an
			-- empty profile, and their first save both loses the session AND commits,
			-- which makes "a save has committed" true forever after -- so the import
			-- never runs again and the legacy data is stranded for good.
			local throwing = true
			local imports = 0
			local fake = require(Root.Test.Helpers.FakeProfileStore).new()
			local harness = TestCtx.make({
				Fake = fake,
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					ImportLegacyData = function()
						if throwing then
							error("the legacy DataStore is throttled", 0)
						end
						imports += 1
						return { Coins = 4242 }
					end,
				},
			})
			local ended = {}
			harness.Data.SessionEnded:Connect(function(_player, reason)
				table.insert(ended, reason)
			end)

			local _player, entry, accessor, reason = harness.TryJoin(96001, 1)

			expect(entry).to.equal(nil)
			expect(accessor).to.equal(nil)
			-- Reuses "load-failed" rather than adding an import-specific member: it is
			-- a load failure, and the fail-closed schema teardown settled on the same
			-- value for the same reason.
			expect(reason).to.equal(Scribe.Reason.LoadFailed)
			expect(ended[1]).to.equal(Scribe.Reason.LoadFailed)

			-- The refusal has to stay RETRYABLE, and that is not automatic. Ending the
			-- session writes, and for a brand-new profile it writes template defaults
			-- -- so if that write counted as a prior save, the retry gate would refuse
			-- to import ever again and a transient outage would strand the legacy data
			-- permanently. It does not count only because AddUserId has not run yet.
			expect(#(fake.PersistedUserIds[KEY] or { 1 })).to.equal(0)
			throwing = false
			local _p2, entry2, data2 = harness.TryJoin(96001, 1)
			expect(entry2).never.to.equal(nil)
			expect(imports).to.equal(1)
			expect(data2.Coins.Get()).to.equal(4242)
			harness.Cleanup()
		end)

		it("does not run OnPlayerInit for a refused load", function()
			local inits = 0
			local harness = makeHarness({
				ImportLegacyData = function()
					error("nope", 0)
				end,
				OnPlayerInit = function()
					inits += 1
				end,
			})
			harness.TryJoin(96001, 1)

			expect(inits).to.equal(0)
			harness.Cleanup()
		end)
	end)

	describe("the hook yields, and the player can leave inside it", function()
		it("tears the session down instead of finishing a load for a departed player", function()
			-- The window this closes is ~300 lines wide and universal: unlike the
			-- yields further down the load path, this one happens for EVERY player
			-- Scribe has never saved for. Without a re-check right here, Reconcile,
			-- the migration chain, the schema check and OnPlayerInit all run against a
			-- session that is already gone -- and OnPlayerInit is developer code being
			-- handed a player who left.
			local release
			local inits = 0
			local harness = makeHarness({
				ImportLegacyData = function()
					local importThread = coroutine.running()
					release = function()
						task.spawn(importThread)
					end
					coroutine.yield()
					return { Coins = 77 }
				end,
				OnPlayerInit = function()
					inits += 1
				end,
			})

			local player = FakePlayer.new(96001)
			task.spawn(harness.Ctx.Persistence.OnPlayerAdded, player)
			expect(release).never.to.equal(nil) -- parked inside the hook

			-- The player leaves while the hook is still yielding.
			harness.Leave(player)
			release()

			expect(harness.Ctx.Persistence.EntryFor(player)).to.equal(nil)
			expect(inits).to.equal(0)
			expect(harness.Ctx.Persistence.GetState(player)).to.equal("SessionEnded")
			harness.Cleanup()
		end)
	end)
end
