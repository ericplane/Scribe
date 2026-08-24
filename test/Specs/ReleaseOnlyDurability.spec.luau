--!nonstrict
-- A save that persisted no Data must never be reported as durable.
--
-- Scribe's store has a release that deliberately writes NOTHING but MetaData
-- (`scribe_release_only`, set by Profile:EndSessionWithoutSaving and by the three
-- fail-closed load paths). That release still succeeds -- it IS a successful
-- UpdateAsync -- so its outcome is "Saved", and every durability answer in
-- Persistence was derived from that outcome alone:
--
--   * AwaitSave resumed its waiter on `outcome == "Saved" and Blocked ~= true`.
--   * Data.Flush is AwaitSave, plus an isDurable short circuit that reads
--     Dirty/LastResult -- both of which a release-only save sets to "clean" and
--     "Ok" like any other successful write.
--
-- WHY IT MATTERS, rather than being a curiosity of an internal flag. Monetization
-- returns PurchaseGranted on this boolean and Roblox never retries a granted
-- receipt, so a false "durable" is paid Robux for data that was never stored.
-- Measured on a prototype that set the flag on a Ready profile: one run minted 40
-- coins out of nothing, another destroyed 40.
--
-- It is unreachable through the shipped API TODAY, and only by accident: all three
-- releaseWithoutWriting call sites are pre-Ready load paths, so no AwaitSave waiter
-- is registered when they run. That is an ordering coincidence, not an invariant,
-- and EndSessionWithoutSaving is a public method on the profile. This spec sets the
-- flag directly for that reason -- it asserts the RULE ("a write that carried no
-- Data is not durable"), not the current reachability of the one caller that would
-- break it.
--
-- BOTH ROUTES ARE ASSERTED SEPARATELY AND THAT IS DELIBERATE. Fixing only AwaitSave
-- leaves the isDurable short circuit answering true off the release-only save's own
-- bookkeeping, so a second flush would still lie while the first told the truth.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local universe

	local function build()
		universe = Universe.new({
			Seed = 606060,
			Servers = 1,
			-- Autosave pushed far out: an autosave landing between the assertions
			-- would be a second, unrelated save whose outcome is not the one under
			-- test.
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {},
		})
		Guard.Install(universe)
		return universe, universe:Server(1)
	end

	--- Data.Flush yields on the modelled disk, so it cannot be called inline: it has
	--- to run on a scheduler thread with the universe pumping behind it. A bounded
	--- run and an explicit error, rather than an unbounded wait, so a flush that
	--- never settles fails HERE instead of as the runner's timeout.
	local function flush(uni, server, player): boolean
		local out = {}
		uni.Sched:Spawn(function()
			out.Result = server.Bundle.Data.Flush(player, { Timeout = 30 })
			out.Done = true
		end)
		uni:Run(60)
		if not out.Done then
			error("flush never settled", 2)
		end
		return out.Result
	end

	local function storedCoins(uni)
		for _, e in uni.Disk.Keyspace:Each() do
			if e.Key == "PLAYER_90101" then
				return e.Record.Value.Data and e.Record.Value.Data.Coins
			end
		end
		return nil
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("a save that writes MetaData only", function()
		it("is not durable, and does not become durable on a second ask", function()
			local uni, server = build()
			local player = FakePlayer.new(90101)
			server:Join(90101, player)
			uni:Run(15)
			expect(server.Bundle.Data.GetState(player)).to.equal("Ready")

			local data = server.Bundle.Data.Get(player)

			-- A NORMAL flush first. Without this the spec is vacuous: a Flush that
			-- refused everything would pass the assertions below while proving
			-- nothing, and it also pins the stored value the release-only save must
			-- leave alone.
			data.Coins.Set(140)
			expect(flush(uni, server, player)).to.equal(true)
			expect(storedCoins(uni)).to.equal(140)

			-- Now the same profile, releasing without writing. This is what
			-- EndSessionWithoutSaving sets; the session stays alive, which is what
			-- lets the assertion be about the SAVE rather than about teardown.
			local entry = server.Bundle.Ctx.Persistence.Entries[player]
			expect(entry).to.be.ok()
			entry.Profile.scribe_release_only = true

			data.Coins.Set(999)
			expect(flush(uni, server, player)).to.equal(false)

			-- The release really was release-only. Without this the `false` above
			-- could equally have come from a failed or timed-out save, which is a
			-- different (and already-covered) reason to refuse.
			expect(storedCoins(uni)).to.equal(140)

			-- The second route. The release-only save completed successfully, so it
			-- stamped LastResult = "Ok" and cleared Dirty -- exactly what isDurable
			-- reads -- and a flush that short-circuits on that answers true without
			-- issuing any save at all. The live 999 is still nowhere on disk.
			expect(flush(uni, server, player)).to.equal(false)
			expect(storedCoins(uni)).to.equal(140)
		end)
	end)
end
