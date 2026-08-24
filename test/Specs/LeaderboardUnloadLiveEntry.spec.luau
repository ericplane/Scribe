--!nonstrict
-- Tearing one session down must not wipe another session's board state.
--
-- `Leaderboards.OnUnload` clears `MyRanks`, `MyScores` and `SentState` by USER ID.
-- Everywhere else that unwinds a session first checks the entry is still the live
-- one for that id -- `Persistence.teardown` does it twice, twenty lines below the
-- call it makes into here, because "a rejoin can already have installed a NEWER
-- entry under the same Player". `OnUnload` did not.
--
-- THE REJOIN INTERLEAVING IS REFUTED, and that is worth stating rather than
-- quietly not testing: `teardown` is one-shot and nothing between its start and
-- this call yields, so a stale teardown cannot land after a rejoin has installed a
-- replacement. What is LIVE is a different route to the same wipe: two CONCURRENT
-- entries sharing one user id, which `TargetUserId` creates by design.
-- `Mode = "NoSave", TargetUserId = <id>` is the documented safe way to inspect a
-- real profile, and with two players in the place both entries carry the SAME user
-- id -- so either one leaving blanks the other's rank cache.
--
-- Narrow, and it stays narrow: Live and Mock refuse the second same-id load
-- outright, and even here the wipe self-heals within one RefreshInterval. It is a
-- wrong answer for up to a minute in a documented inspection mode, closed by the
-- guard the file next door already uses.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- Two players, one target user id, one board. The target's stored profile has
	--- to exist for a NoSave load to have anything to read.
	local function makeHarness(coins)
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {
				UseMock = false,
				Mode = "NoSave",
				TargetUserId = 8080,
				Leaderboards = { Rich = { Stat = "Coins" } },
			},
		})
		harness.Fake.Persisted["Default/PLAYER_8080"] = { Coins = coins or 1234 }
		return harness
	end

	--- Get a real rank onto the board, through the public path.
	local function publishRanks(harness)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow()
	end

	describe("Leaderboards.OnUnload with two entries sharing a user id", function()
		it("keeps, then clears, board state for an ordinary single session", function()
			-- THE CONTROL, and it has to come first: the rank really is cached while
			-- the player is here, and really is dropped when they go. A fix that simply
			-- stopped clearing would pass everything below and fail this.
			local harness = TestCtx.make({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = { Leaderboards = { Rich = { Stat = "Coins" } } },
			})
			local player, _, data = harness.Join(870001)
			data.Coins.Set(500)
			publishRanks(harness)

			expect(harness.Data.GetMyRank(player, "Rich")).to.equal(1)

			harness.Leave(player)
			expect(harness.Data.GetMyRank(player, "Rich")).to.equal(nil)

			harness.Cleanup()
		end)

		it("really does give two players ONE user id under TargetUserId", function()
			-- THE CALIBRATION. Everything below rests on the two entries genuinely
			-- sharing an id; if TargetUserId stopped applying they would pass for the
			-- wrong reason.
			local harness = makeHarness()
			local _p1, e1 = harness.Join(870101)
			local _p2, e2 = harness.Join(870102)

			expect(e1.UserId).to.equal(8080)
			expect(e2.UserId).to.equal(8080)
			expect(e1 == e2).to.equal(false)

			harness.Cleanup()
		end)

		it("does not blank the surviving session's rank when the other leaves", function()
			-- The defect, read back through the public accessor a game would use.
			local harness = makeHarness()
			local p1 = harness.Join(870201)
			local p2 = harness.Join(870202)
			publishRanks(harness)

			local before = harness.Data.GetMyRank(p2, "Rich")
			expect(before).to.equal(1)

			harness.Leave(p1)

			expect(harness.Data.GetMyRank(p2, "Rich")).to.equal(before)

			harness.Cleanup()
		end)

		it("DOES clear it once the last of them leaves", function()
			-- The other direction, and the reason the guard is "is this still the live
			-- entry" rather than "never clear": the cache must not outlive the sessions
			-- it describes.
			local harness = makeHarness()
			local p1 = harness.Join(870301)
			local p2 = harness.Join(870302)
			publishRanks(harness)
			expect(harness.Data.GetMyRank(p2, "Rich")).to.equal(1)

			harness.Leave(p1)
			harness.Leave(p2)

			expect(harness.Data.GetMyRank(p2, "Rich")).to.equal(nil)

			harness.Cleanup()
		end)

		it("still flushes the leaving player's score either way", function()
			-- The rest of OnUnload is untouched: the guard covers the cache wipe only,
			-- and the leave-time score flush has to keep running for BOTH sessions.
			local harness = makeHarness()
			local p1 = harness.Join(870401)
			local p2 = harness.Join(870402)
			publishRanks(harness)

			local flushed = 0
			local realEnqueue = harness.Ctx.Leaderboards.Enqueue
			harness.Ctx.Leaderboards.Enqueue = function(board, userId, value)
				flushed += 1
				return realEnqueue(board, userId, value)
			end

			harness.Leave(p1)
			expect(flushed).to.equal(1)
			harness.Leave(p2)
			expect(flushed).to.equal(2)

			harness.Ctx.Leaderboards.Enqueue = realEnqueue
			harness.Cleanup()
		end)
	end)
end
