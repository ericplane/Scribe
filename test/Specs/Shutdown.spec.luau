--!nonstrict
-- Shutdown (BindToClose): stop accepting new sessions, flush the leaderboard
-- queue, end every profile session within the budget.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	it("drains sessions and the leaderboard queue on shutdown", function()
		local harness = TestCtx.make({
			Options = {
				Leaderboards = {
					TopCoins = { Stat = "Coins", Limit = 10 },
				},
			},
		})

		local _playerA, _entryA, dataA = harness.Join(7001)
		local _playerB, _entryB, dataB = harness.Join(7002)
		dataA.Coins.Set(150)
		dataB.Coins.Set(75)

		local writesBefore = Scribe.GetMetrics().LbWrites or 0

		-- The shutdown drain (what game:BindToClose invokes).
		harness.Ctx.Persistence.Shutdown(5)

		-- Every session ended and saved.
		expect(next(harness.Ctx.Persistence.Entries)).to.equal(nil)
		expect(harness.Fake.Persisted["Default/PLAYER_7001"].Coins).to.equal(150)
		expect(harness.Fake.Persisted["Default/PLAYER_7002"].Coins).to.equal(75)
		expect(next(harness.Fake.ActiveProfiles)).to.equal(nil)

		-- The paced leaderboard queue was force-drained.
		local writesAfter = Scribe.GetMetrics().LbWrites or 0
		expect(writesAfter - writesBefore >= 2).to.equal(true)

		-- Server leaderboard reads see the flushed scores (in-memory store).
		-- (The refresh cycle hasn't run; read the store through the public API
		-- after a manual refresh is out of scope here — flushed writes suffice.)

		-- New sessions are refused while closing.
		local latecomer = FakePlayer.new(7003)
		harness.Ctx.Persistence.OnPlayerAdded(latecomer)
		expect(harness.Ctx.Persistence.EntryFor(latecomer)).to.equal(nil)

		-- Structured shutdown logging.
		expect(#Scribe.GetRecentLogs({ Code = "SHUTDOWN_FLUSH", Limit = 3 }) > 0).to.equal(true)
		expect(#Scribe.GetRecentLogs({ Code = "SHUTDOWN_DONE", Limit = 3 }) > 0).to.equal(true)

		harness.Cleanup()
	end)

	it("marks trees dead after shutdown so late writes fail loudly", function()
		local harness = TestCtx.make()
		local _, entry, data = harness.Join()
		harness.Ctx.Persistence.Shutdown(5)

		expect(entry.Tree.Dead).to.equal(true)
		expect(function()
			data.Coins.Set(1)
		end).to.throw()

		harness.Cleanup()
	end)
end
