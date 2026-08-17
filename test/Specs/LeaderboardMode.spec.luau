--!nonstrict
-- Leaderboards must honour the RESOLVED persistence Mode, not the legacy flags.
--
-- Mode is resolved inside Persistence and never written back into `options`, so
-- Leaderboards reading `options.UseMock` meant a `Mode = "Mock"` bundle still read
-- and wrote REAL OrderedDataStores while both guides promised it did not. Someone
-- play-testing in Studio was mutating live board data.
--
-- The headless shim errors on DataStoreService:GetOrderedDataStore and every store
-- call in Leaderboards is pcall'd, so hitting the real store does not throw: it
-- leaves the board EMPTY. That is the discriminator used below. The Live case is
-- what keeps this honest, since without it every assertion would still pass if the
-- mock store were wired unconditionally.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	-- UseMock = false is load-bearing: with it absent TestCtx defaults it to true,
	-- and the pre-fix code read that flag and would pass whatever Mode said.
	local function makeHarness(mode: string?)
		return TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {
				UseMock = false,
				Mode = mode,
				Leaderboards = { Top = { Stat = "Coins" } },
			},
		})
	end

	local function readBoard(harness)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow("Top")
		return harness.Data.GetLeaderboard("Top", 10)
	end

	it('keeps leaderboards on the mock store under Mode = "Mock"', function()
		local harness = makeHarness("Mock")
		local _p, _e, data = harness.Join(99401)
		data.Coins.Set(500)

		local entries = readBoard(harness)
		expect(#entries).to.equal(1)
		expect(entries[1].UserId).to.equal(99401)

		harness.Cleanup()
	end)

	it('keeps leaderboards off the real store under Mode = "NoSave"', function()
		-- NoSave promises nothing can be written back, and a board write is a write.
		local harness = makeHarness("NoSave")
		-- A view is read with GetAsync, so there has to be something stored to read.
		harness.Fake.Persisted["Default/PLAYER_99402"] = { Coins = 0 }
		local _p, _e, data = harness.Join(99402)
		data.Coins.Set(500)

		local entries = readBoard(harness)
		expect(#entries).to.equal(1)
		expect(entries[1].UserId).to.equal(99402)

		harness.Cleanup()
	end)

	it('still uses the real store under Mode = "Live"', function()
		-- The control. Proves the two assertions above discriminate rather than
		-- passing because the mock store is wired unconditionally.
		--
		-- Asserts the store CHOICE, not the board contents. Contents only
		-- discriminate under the headless runner, where reaching a real
		-- OrderedDataStore fails and leaves the board empty; under real TestEZ in
		-- Studio the write lands and the board legitimately has an entry, so the old
		-- `#readBoard(harness) == 0` could never hold there.
		local harness = makeHarness("Live")
		local _p, _e, data = harness.Join(99403)
		data.Coins.Set(500)

		expect(harness.Ctx.Leaderboards.UsesMockStore).to.equal(false)

		harness.Cleanup()
	end)

	it("still honours the legacy UseMock flag when Mode is absent", function()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = { UseMock = true, Leaderboards = { Top = { Stat = "Coins" } } },
		})
		local _p, _e, data = harness.Join(99404)
		data.Coins.Set(500)

		expect(#readBoard(harness)).to.equal(1)

		harness.Cleanup()
	end)
end
