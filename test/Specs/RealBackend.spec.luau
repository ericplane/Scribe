--!nonstrict
-- Scribe's OWN logic against the real ProfileStore and real DataStores.
--
-- The Conformance suite proves the ProfileStore contract; every other spec runs
-- Scribe against FakeProfileStore, which is fully synchronous. Real ProfileStore
-- yields on every DataStore call, so any place Scribe assumes no interleaving
-- between a read and a write has never been exercised. That is not a class of bug
-- assertions catch by inspection: it only appears when the yields are real.
--
-- Skipped entirely unless ConformanceStore.UseReal is set (see that module), so
-- this is a no-op under Lune and in CI.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local ConformanceStore = require(Root.Test.Helpers.ConformanceStore)

	if not ConformanceStore.IsReal() then
		return
	end

	local realStore = ConformanceStore.get()

	-- Every run gets a fresh key namespace so a rerun never inherits state and two
	-- developers never collide. These keys are written to a real DataStore.
	local runId = os.time()
	local nextId = 0
	local function freshUserId(): number
		nextId += 1
		return 900000 + nextId
	end

	local function makeHarness(extra)
		-- Same reason as ExchangeRealBackend: a throttled request still spends its
		-- allowance slot, so entering a harness with an empty budget makes the whole
		-- run slower rather than merely later. Both real-backend specs share one
		-- server-wide allowance, so both have to wait for it.
		ConformanceStore.AwaitBudget(10)
		local options = {
			ProfileStore = realStore,
			ProfileStoreIndex = ConformanceStore.STORE,
			ProfileKeyPrefix = `RB_{runId}_`,
			Mode = "Live", -- the whole point: real saves, real yields
			UseMock = nil,
			KickOnSessionEnd = false,
			LogLevel = "Fatal",
			Banner = false,
		}
		for key, value in extra or {} do
			options[key] = value
		end
		return TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Nick = Scribe.String("", { MaxLength = 16 }),
				Inventory = Scribe.DictOf(Scribe.Int(0, { Min = 0 })),
			},
			Options = options,
		})
	end

	describe("real backend", function()
		it("persists a write and reads it back on a later session", function()
			local userId = freshUserId()

			local first = makeHarness()
			local player, _entry, data = first.Join(userId)
			data.Coins.Set(1234)
			data.Nick.Set("scribe")
			data.Inventory.Wood.Set(7)
			-- Flush against a real DataStore: a genuine network round trip.
			expect(first.Data.Flush(player, { Timeout = 30 })).to.equal(true)
			first.Leave(player)
			first.Cleanup()

			-- A brand-new bundle and a brand-new session, same key.
			local second = makeHarness()
			local _p2, _e2, data2 = second.Join(userId)
			expect(data2.Coins.Get()).to.equal(1234)
			expect(data2.Nick.Get()).to.equal("scribe")
			expect(data2.Inventory.Wood.Get()).to.equal(7)
			second.Cleanup()
		end)

		it("reports the second session as returning, not new", function()
			local userId = freshUserId()

			local seen = {}
			local first = makeHarness({
				OnPlayerInit = function(_player, _raw, isNewProfile)
					table.insert(seen, isNewProfile)
				end,
			})
			local player = first.Join(userId)
			expect(first.Data.Flush(player, { Timeout = 30 })).to.equal(true)
			first.Leave(player)
			first.Cleanup()

			local second = makeHarness({
				OnPlayerInit = function(_player, _raw, isNewProfile)
					table.insert(seen, isNewProfile)
				end,
			})
			second.Join(userId)
			second.Cleanup()

			-- The SessionLoadCount / UserIds reasoning that FreshDetector and
			-- DryRunMigrations depend on, verified against a real backend.
			expect(seen[1]).to.equal(true)
			expect(seen[2]).to.equal(false)
		end)

		it("runs a migration against real stored data exactly once", function()
			local userId = freshUserId()

			local first = makeHarness()
			local player, _e, data = first.Join(userId)
			data.Coins.Set(50)
			expect(first.Data.Flush(player, { Timeout = 30 })).to.equal(true)
			first.Leave(player)
			first.Cleanup()

			local ran = 0
			local second = makeHarness({
				Migrations = {
					[2] = function(raw)
						ran += 1
						raw.Coins = (tonumber(raw.Coins) or 0) * 2
					end,
				},
			})
			local p2, _e2, data2 = second.Join(userId)
			expect(ran).to.equal(1)
			expect(data2.Coins.Get()).to.equal(100)
			expect(second.Data.Flush(p2, { Timeout = 30 })).to.equal(true)
			second.Leave(p2)
			second.Cleanup()

			-- Re-loading at the same version must NOT migrate again.
			local ranAgain = 0
			local third = makeHarness({
				Migrations = {
					[2] = function(raw)
						ranAgain += 1
						raw.Coins = (tonumber(raw.Coins) or 0) * 2
					end,
				},
			})
			local _p3, _e3, data3 = third.Join(userId)
			expect(ranAgain).to.equal(0)
			expect(data3.Coins.Get()).to.equal(100)
			third.Cleanup()
		end)

		-- NOT TESTED HERE: a cross-server session steal. ProfileStore identifies a
		-- session by (PlaceId, JobId), and two bundles inside one Studio play session
		-- share both, so a second StartSessionAsync on the same key is the SAME
		-- session rather than a steal and simply fails to load. Reproducing a real
		-- steal needs two separate Roblox servers, which no single-process harness
		-- can provide. The steal PATH is covered against the fake (Lifecycle,
		-- AuditFixes); only its real-latency behaviour is out of reach.

		it("GetOffline reads a saved profile without a session", function()
			local userId = freshUserId()

			local harness = makeHarness()
			local player, _e, data = harness.Join(userId)
			data.Coins.Set(777)
			expect(harness.Data.Flush(player, { Timeout = 30 })).to.equal(true)
			harness.Leave(player)

			local offline = harness.Data.GetOffline(userId)
			expect(offline).to.be.ok()
			expect(offline.Coins).to.equal(777)

			harness.Cleanup()
		end)
	end)
end
