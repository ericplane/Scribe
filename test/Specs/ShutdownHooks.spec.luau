--!nonstrict
-- The shutdown drain's hook phase: what it costs the players who are not in it.
--
-- OnPlayerLeaving runs once per session, and on shutdown every session ends at
-- once. The drain used to walk them one at a time on its own stack, so player N's
-- hook could not start until player N-1's had returned, and nothing in that walk
-- ever looked at the clock -- Shutdown(1) and Shutdown(25) did identical work
-- there. Two different players pay for that: the ones whose hook never gets
-- reached, and the leaderboard queue, whose flush is what the rest of the budget
-- funds and which gets whatever the hook phase leaves it.
--
-- What must NOT change is the per-player ordering. The hook runs before that
-- player's own final save, so its writes land; ending the session first destroys
-- the tree, and every subsequent hook write then throws into a swallowed
-- LISTENER_ERROR. Silent data loss with a log line. So the fan-out relaxes the
-- ordering BETWEEN players and keeps it within each one.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function harnessWith(hook)
		return TestCtx.make({
			Template = { Playtime = 0, Coins = 0 },
			Options = { OnPlayerLeaving = hook },
		})
	end

	local function metric(name: string): number
		return Scribe.GetMetrics()[name] or 0
	end

	--- Burn `seconds` of CPU without yielding -- the hook shape the guide actually
	--- asks for ("it must not yield"), and the one no amount of concurrency can
	--- make cheaper. Only a deadline bounds this.
	local function burn(seconds: number)
		local started = os.clock()
		local spins = 0
		while os.clock() - started < seconds do
			spins += 1
		end
		return spins
	end

	describe("a hook that yields", function()
		it("no longer holds up every other player's hook", function()
			-- The sequence is the whole assertion, and it does not care which player
			-- the drain reaches first. Serial: each hook finishes before the next
			-- begins. Fanned out: both are underway at once.
			local order = {}
			local harness = harnessWith(function()
				table.insert(order, "start")
				task.wait(0.05)
				table.insert(order, "end")
			end)
			harness.Join(97701)
			harness.Join(97702)

			harness.Ctx.Persistence.Shutdown(5)

			expect(table.concat(order, ",")).to.equal("start,start,end,end")

			harness.Cleanup()
		end)

		it("still gets its own writes into its own save", function()
			-- The guarantee the fan-out is not allowed to buy anything with. Both
			-- players yield mid-hook, so both are in flight together, and each one's
			-- increment still has to precede its own EndSession.
			local harness = harnessWith(function(_player, data)
				data.Playtime.Increment(3)
				task.wait(0.05)
				data.Coins.Increment(7)
			end)
			harness.Join(97703)
			harness.Join(97704)

			harness.Ctx.Persistence.Shutdown(5)

			for _, userId in { 97703, 97704 } do
				local saved = harness.Fake.Persisted[`Default/PLAYER_{userId}`]
				expect(`{userId} saved={saved ~= nil}`).to.equal(`{userId} saved=true`)
				expect(`{userId} playtime={saved.Playtime} coins={saved.Coins}`).to.equal(`{userId} playtime=3 coins=7`)
			end

			harness.Cleanup()
		end)
	end)

	describe("the budget", function()
		it("stops starting hooks once the hook phase has spent its share", function()
			-- Twenty non-yielding hooks at 20ms is 0.4s of work against a 0.3s budget,
			-- of which the hook phase may have three quarters. Some hooks do not run:
			-- that is the point, and it is what stops a hook-heavy server from
			-- spending Roblox's whole closing window before the leaderboard flush
			-- gets a single one of its seconds.
			local ran = 0
			local harness = harnessWith(function()
				ran += 1
				burn(0.02)
			end)
			local userIds = {}
			for i = 1, 20 do
				local userId = 97710 + i
				table.insert(userIds, userId)
				local _player, _entry, data = harness.Join(userId)
				-- A value only the final save can put on disk. "Is there a record at
				-- all" would not do: it is true for reasons that have nothing to do
				-- with this drain.
				data.Coins.Set(500 + i)
			end

			local skippedBefore = metric("LeavingHooksSkipped")
			local timedOutBefore = metric("LeavingHooksTimedOut")
			harness.Ctx.Persistence.Shutdown(0.3)
			local skipped = metric("LeavingHooksSkipped") - skippedBefore
			local timedOut = metric("LeavingHooksTimedOut") - timedOutBefore

			expect(`ran={ran} of 20, capped={ran < 20}`).to.equal(`ran={ran} of 20, capped=true`)
			expect(`ran={ran > 0}`).to.equal("ran=true")
			expect(`skipped={skipped}`).to.equal(`skipped={20 - ran}`)
			-- Counted as skipped and NOT as timed out. A hook that never started is a
			-- different report from one that hung, and the two answer different
			-- questions about what to change.
			expect(`timedOut={timedOut}`).to.equal("timedOut=0")

			-- And every one of them saved anyway. The hook is what the budget may
			-- drop; the profile is not.
			for i, userId in userIds do
				local saved = harness.Fake.Persisted[`Default/PLAYER_{userId}`]
				expect(`{userId} coins={saved and saved.Coins}`).to.equal(`{userId} coins={500 + i}`)
			end

			harness.Cleanup()
		end)

		it("ends the session of a hook still parked when the deadline passes", function()
			-- A hook that yields past the deadline cannot be interrupted -- Luau has
			-- no way to. What CAN happen is that we stop waiting for it and save
			-- without the rest of its writes, which is the only alternative to
			-- holding the whole server open on one player's `task.wait`.
			local harness = harnessWith(function(_player, data)
				data.Playtime.Increment(4)
				task.wait(0.8)
				data.Coins.Increment(9) -- lands after the cut-off, on a dead tree
			end)
			harness.Join(97741)
			harness.Join(97742)

			local timedOutBefore = metric("LeavingHooksTimedOut")
			local started = os.clock()
			harness.Ctx.Persistence.Shutdown(0.4)
			local elapsed = os.clock() - started
			local timedOut = metric("LeavingHooksTimedOut") - timedOutBefore

			expect(`timedOut={timedOut}`).to.equal("timedOut=2")
			-- Serially those two hooks are 1.6s on their own; fanned out and cut off,
			-- the drain is bounded by its budget.
			expect(`elapsed={elapsed < 1.0}`).to.equal("elapsed=true")

			for _, userId in { 97741, 97742 } do
				local saved = harness.Fake.Persisted[`Default/PLAYER_{userId}`]
				-- What the hook wrote BEFORE the cut-off is a real write and it
				-- persisted; what it wrote after did not. A timed-out hook is not
				-- atomic, and a game must not assume it was.
				expect(`{userId} playtime={saved.Playtime} coins={saved.Coins}`).to.equal(`{userId} playtime=4 coins=0`)
			end

			-- Let the parked hooks resume and hit the dead tree inside this spec
			-- rather than in whichever one runs next.
			task.wait(0.9)
			harness.Cleanup()
		end)

		it("stops the hook phase from starving the leaderboard flush", function()
			-- The other half of the same defect, and the half with a number on it.
			-- Both phases share one deadline, and the flush is computed as whatever
			-- is left of it. A hook phase that overran left `max(0, deadline - now)`
			-- at exactly zero, so the shutdown flush drained nothing at all and
			-- still logged itself as a flush. Capping the hook phase is what puts
			-- seconds back in the second half.
			local harness = TestCtx.make({
				Template = { Playtime = 0, Coins = 0 },
				Options = {
					OnPlayerLeaving = function()
						burn(0.02)
					end,
					Leaderboards = { TopCoins = { Stat = "Coins", Limit = 50 } },
				},
			})
			for i = 1, 20 do
				local _player, _entry, data = harness.Join(97760 + i)
				data.Coins.Set(100 + i) -- one queued leaderboard write each
			end

			local writesBefore = metric("LbWrites")
			harness.Ctx.Persistence.Shutdown(0.3)
			local wrote = metric("LbWrites") - writesBefore

			expect(`flushed={wrote > 0}`).to.equal("flushed=true")

			harness.Cleanup()
		end)
	end)
end
