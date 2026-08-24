--!nonstrict
-- A fail-closed load must leave the stored bytes exactly as it found them.
--
-- That is the whole point of the promise: a developer sets SchemaPolicy = "Reject"
-- to QUARANTINE a corrupt profile so it can be inspected and recovered, not to have
-- the first load quietly rewrite it.
--
-- It used to be false, and had been claimed in a comment and in configuration.md for
-- long enough to be believed. Ending the session is an unconditional save, and by
-- the time a reject runs, profile.Data has been through CoerceMapKeys, Reconcile,
-- the version stamp and the whole migration chain -- so the rejected load wrote
-- Reconcile's backfill straight back to the key. Measured before the fix: the key
-- came back with a template default added and its DataStore version advanced twice.
--
-- Testing only the corrupt FIELD proves nothing: Reconcile does not touch a key that
-- is present, so it round-trips unchanged either way and the spec passes against
-- broken code. The promise is about the whole record, so that is what is compared.
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
	local HttpService = game:GetService("HttpService")

	local universe

	local function build()
		universe = Universe.new({
			Seed = 424242,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			-- Gems is declared but will be ABSENT from the stored profile, so Reconcile
			-- has something to backfill. Persisting that backfill is the defect.
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Gems = Scribe.Int(0, { Min = 0 }),
			},
			Options = { SchemaPolicy = "Reject" },
		})
		Guard.Install(universe)
		return universe, universe:Server(1)
	end

	local function record(uni)
		for _, e in uni.Disk.Keyspace:Each() do
			if e.Key == "PLAYER_90001" then
				return e.Record
			end
		end
		return nil
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("a rejected load", function()
		it("leaves the stored profile byte-for-byte as it found it", function()
			local uni, server = build()

			local first = FakePlayer.new(90001)
			server:Join(90001, first)
			uni:Run(3)
			server:Leave(90001)
			uni:Run(10)

			-- Corrupt the stored bytes the way a bad manual edit or a foreign writer
			-- would, and remove the field Reconcile will want to backfill.
			local rec = record(uni)
			expect(rec).to.be.ok()
			rec.Value.Data.Coins = "CORRUPT-SENTINEL"
			rec.Value.Data.Gems = nil
			local before = HttpService:JSONEncode(rec.Value.Data)

			local second = FakePlayer.new(90001)
			server:Join(90001, second)
			uni:Run(20)

			-- The reject really fired. Without this the comparison below is vacuous:
			-- a load that never rejected would also leave the bytes alone.
			expect(server.Bundle.Data.GetState(second)).to.equal("SessionEnded")

			expect(HttpService:JSONEncode(record(uni).Value.Data)).to.equal(before)
		end)

		it("still releases the session lock, so the player can rejoin elsewhere", function()
			-- Preserving the bytes must not cost the lock. A profile nobody can ever
			-- acquire again is a worse outcome than one that was rewritten, so this is
			-- the counterweight to the spec above rather than a nicety.
			local uni, server = build()

			local first = FakePlayer.new(90001)
			server:Join(90001, first)
			uni:Run(3)
			server:Leave(90001)
			uni:Run(10)

			local rec = record(uni)
			rec.Value.Data.Coins = "CORRUPT-SENTINEL"
			uni:Run(1)

			local second = FakePlayer.new(90001)
			server:Join(90001, second)
			uni:Run(20)

			expect(record(uni).Value.MetaData.ActiveSession).to.equal(nil)
		end)
	end)
end
