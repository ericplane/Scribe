--!nonstrict
-- DataStore request budgets: the snapshot, and the opt-in admission it feeds.
--
-- The audit's measurement was that NOTHING in Scribe or ProfileStore had ever called
-- GetRequestBudgetForRequestType -- zero calls across a full simulation run. That
-- number is the baseline these specs pin from both directions: it must still be zero
-- with the policy absent, and must not be with it set.
--
-- The two admission specs are about WHERE the gate sits, not whether one exists. In
-- both loops the obvious placement is one line too late, and in both cases the cost
-- is invisible to a spec that only checks "did it eventually write":
--
--   * the write pacer dequeues BEFORE the natural gate point, so deferring there
--     drops the score instead of postponing it;
--   * the refresh loop advances the board's due time BEFORE the Spawn, so deferring
--     there costs a whole RefreshInterval -- a minute at the default -- rather than
--     the one-second tick the loop actually runs on.

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

	local function newUniverse(overrides)
		local config = {
			Seed = 5309,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 20, SESSION_STEAL = 10, FIRST_LOAD_REPEAT = 2, ASSUME_DEAD = 60 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {},
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		local universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	local function withBoard(options)
		local merged = {
			Leaderboards = { Coins = { Stat = "Coins", Limit = 10, RefreshInterval = 60 } },
		}
		for key, value in options or {} do
			merged[key] = value
		end
		return merged
	end

	--- Take over the disk's budget answer for the rest of the test.
	---
	--- Set on the INSTANCE, shadowing the class method through Disk's metatable, so
	--- the universe's own accounting is untouched and nothing has to be restored --
	--- the disk dies with the universe.
	local function stubBudget(disk, remainingFor: (string) -> number)
		local queries = { Count = 0, ByType = {} }
		disk.GetRequestBudgetForRequestType = function(_self, kind)
			local name = if type(kind) == "table" and kind.Name then kind.Name else tostring(kind)
			queries.Count += 1
			queries.ByType[name] = (queries.ByType[name] or 0) + 1
			return remainingFor(name)
		end
		return queries
	end

	--- Count GetSortedAsync calls on one board's ordered store.
	local function countRefreshes(disk, boardStoreName: string)
		local ordered = disk:GetOrderedDataStore(boardStoreName)
		local counter = { Count = 0 }
		local real = ordered.GetSortedAsync
		ordered.GetSortedAsync = function(selfStore, ...)
			counter.Count += 1
			return real(selfStore, ...)
		end
		return counter
	end

	afterEach(function()
		Guard.Reset()
	end)

	describe("which pools a join actually spends", function()
		--- Count budget takes by modelled pool. Set on the INSTANCE for the same reason
		--- stubBudget is: it dies with the universe and restores nothing.
		local function countCharges(disk)
			local charges = {}
			local real = disk.Budget.TryTake
			disk.Budget.TryTake = function(selfBudget, jobId, kind)
				charges[kind] = (charges[kind] or 0) + 1
				return real(selfBudget, jobId, kind)
			end
			return charges
		end

		it("charges a join to the READ pool as well as the write pool", function()
			-- A join does not CALL GetAsync, but ProfileStore loads with UpdateAsync and
			-- that charges both pools, so GET_RESERVE rests on an undocumented engine
			-- behaviour (register U12). Equal counts are the tell that every standard op
			-- in a join is an UpdateAsync rather than a bare read.
			local uni = newUniverse({ NoBudget = false })
			local charges = countCharges(uni.Disk)
			local server = uni:Server(1)
			local player = FakePlayer.new(8821)
			server:Join(8821, player)
			uni:Run(5)

			local read = charges.StandardRead or 0
			local write = charges.StandardWrite or 0
			local ordered = (charges.OrderedRead or 0) + (charges.OrderedWrite or 0)
			expect(`read={read} write={write} equal={read == write} ordered={ordered}`).to.equal(
				"read=1 write=1 equal=true ordered=0"
			)
		end)

		it("answers the GetAsync query from the pool an UpdateAsync actually drains", function()
			-- POOL_FOR_REQUEST_TYPE mirrors where Store.luau charges and nothing else holds
			-- the two together; drift leaves the query reporting a pool the ops never
			-- spend. One raw UpdateAsync, no players: the ceiling scales with player
			-- count, so a join raises the allowance faster than it spends it.
			local uni = newUniverse({ NoBudget = false })
			local service = uni.Disk:ServiceFor("probe-job")
			local before, after
			uni.Sched:Spawn(function()
				before = service:GetRequestBudgetForRequestType({ Name = "GetAsync" })
				service:GetDataStore("BudgetProbe"):UpdateAsync("k", function(old)
					return (old or 0) + 1
				end)
				after = service:GetRequestBudgetForRequestType({ Name = "GetAsync" })
			end)
			uni:Run(1)
			expect(`before={before} spent={(before or 0) - (after or -1)}`).to.equal("before=60 spent=1")
		end)

		it("reports the SCARCER pool for UpdateAsync, not just the write side", function()
			-- Answering from the roomier pool promises headroom the other cannot honour.
			local uni = newUniverse({ NoBudget = false })
			local service = uni.Disk:ServiceFor("probe-job")
			local read, write, update
			uni.Sched:Spawn(function()
				local store = service:GetDataStore("BudgetProbe")
				for i = 1, 20 do
					store:GetAsync(`k{i}`)
				end
				read = service:GetRequestBudgetForRequestType({ Name = "GetAsync" })
				write = service:GetRequestBudgetForRequestType({ Name = "SetIncrementAsync" })
				update = service:GetRequestBudgetForRequestType({ Name = "UpdateAsync" })
			end)
			uni:Run(2)
			expect(`follows={update == read} readIsScarcer={(read or 0) < (write or 0)}`).to.equal(
				"follows=true readIsScarcer=true"
			)
		end)
	end)

	describe("the budget is never consulted unless asked for", function()
		it("issues zero budget queries with no BudgetPolicy", function()
			-- The audit's measured baseline, pinned. Every save, receipt await, gift
			-- check, version query and board write is still issued blind by default,
			-- and this must stay true: the feature is opt-in, and a library that
			-- quietly started pacing itself would change the timing of every game
			-- that upgraded without asking for it.
			local uni = newUniverse({ Options = withBoard() })
			local queries = stubBudget(uni.Disk, function()
				return 0
			end)
			local server = uni:Server(1)

			local player = FakePlayer.new(8801)
			server:Join(8801, player)
			uni:Run(30)
			server.Bundle.Data.Get(player).Coins.Set(4242)
			server:Leave(8801)
			uni:Run(180) -- several refresh cycles and many pacer ticks

			expect(queries.Count).to.equal(0)
			-- ...and the board still wrote, so the run really did exercise the loops.
			local boardName = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			expect(uni.Disk:GetOrderedDataStore(boardName)._entries["8801"]).never.to.equal(nil)
		end)

		it("takes only the documented value, not any truthy one", function()
			-- An exact match rather than a truthiness check, so a value that is not
			-- the documented one leaves the library exactly as it was. The alternative
			-- reading -- "anything non-nil turns it on" -- would make `BudgetPolicy =
			-- "Off"` enable the very pacing it was written to disable.
			local uni = newUniverse({ Options = withBoard({ BudgetPolicy = "Off" }) })
			local queries = stubBudget(uni.Disk, function()
				return 0
			end)
			local server = uni:Server(1)

			local player = FakePlayer.new(8806)
			server:Join(8806, player)
			uni:Run(30)
			server.Bundle.Data.Get(player).Coins.Set(4242)
			server:Leave(8806)
			uni:Run(180)

			expect(queries.Count).to.equal(0)
			local boardName = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			expect(uni.Disk:GetOrderedDataStore(boardName)._entries["8806"]).never.to.equal(nil)
		end)

		it("stays off under a mock mode, where there is no allowance to respect", function()
			-- Mock and NoSave never reach a real DataStore, so there is no budget to
			-- conserve and nothing to ask -- and asking anyway is not merely wasteful.
			-- A stubbed or absent service answers 0, which the gate would read as an
			-- exhausted allowance and park both loops on, so a Studio play-test would
			-- watch its boards silently stop updating.
			local uni = newUniverse({ Options = withBoard({ BudgetPolicy = "Defer", Mode = "Mock" }) })
			local queries = stubBudget(uni.Disk, function()
				return 0
			end)
			local server = uni:Server(1)

			local player = FakePlayer.new(8805)
			server:Join(8805, player)
			uni:Run(30)
			server.Bundle.Data.Get(player).Coins.Set(4242)
			uni:Run(180)

			expect(queries.Count).to.equal(0)
			-- ...and the mock board kept working throughout.
			expect(#server.Bundle.Data.GetLeaderboard("Coins", 10)).to.equal(1)
		end)

		it("issues them once BudgetPolicy is set", function()
			-- The control for the assertion above: without it, `queries.Count == 0`
			-- would pass just as happily if the stub were never reachable at all.
			local uni = newUniverse({ Options = withBoard({ BudgetPolicy = "Defer" }) })
			local queries = stubBudget(uni.Disk, function()
				return 1000
			end)
			local server = uni:Server(1)

			local player = FakePlayer.new(8802)
			server:Join(8802, player)
			uni:Run(30)
			server.Bundle.Data.Get(player).Coins.Set(4242)
			server:Leave(8802)
			uni:Run(180)

			expect(queries.Count > 0).to.equal(true)
			-- Both loops ask, and each asks about its OWN pool -- the two are separate
			-- allowances, and gating a board write on the save pool would pace the
			-- wrong thing entirely.
			expect((queries.ByType.SetIncrementSortedAsync or 0) > 0).to.equal(true)
			expect((queries.ByType.GetSortedAsync or 0) > 0).to.equal(true)
			-- A generous budget defers nothing, so the write still lands.
			local boardName = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			expect(uni.Disk:GetOrderedDataStore(boardName)._entries["8802"]).never.to.equal(nil)
		end)
	end)

	describe("an unanswerable budget is not an exhausted one", function()
		it("keeps both loops running when the engine cannot be asked", function()
			-- The inertness that matters most, and the easiest to get backwards. A nil
			-- from Budget.Remaining means "could not ask", not "nothing left"; a gate
			-- that conflated the two would park the write pacer and the refresh cycle
			-- permanently in exactly the environments that have no allowance to
			-- conserve -- a headless runner, or Studio with API access off -- while
			-- the policy read as merely "enabled" and every board silently froze.
			local uni = newUniverse({ Options = withBoard({ BudgetPolicy = "Defer" }) })
			uni.Disk.GetRequestBudgetForRequestType = function()
				error("API access is not enabled", 0)
			end
			local server = uni:Server(1)
			local boardName = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			local refreshes = countRefreshes(uni.Disk, boardName)

			local player = FakePlayer.new(8804)
			server:Join(8804, player)
			uni:Run(30)
			server.Bundle.Data.Get(player).Coins.Set(4242)
			server:Leave(8804)
			uni:Run(120)

			-- The write drained and the refresh cycle ran, exactly as with no policy.
			expect(uni.Disk:GetOrderedDataStore(boardName)._entries["8804"]).never.to.equal(nil)
			expect(refreshes.Count > 0).to.equal(true)
			-- ...and nothing was recorded as deferred, because nothing was.
			expect(server.Bundle.Scribe.GetMetrics().LbBudgetDeferred).to.equal(nil)
		end)
	end)

	describe("a deferred write stays queued", function()
		it("postpones the leaderboard write instead of dropping it", function()
			-- The pacer dequeues at the top of its tick, so a gate placed at the
			-- natural-looking spot -- just before the write -- has already taken the
			-- item out of the queue. Deferring there does not delay the score, it
			-- destroys it, and nothing downstream ever notices: no retry, no
			-- LB_WRITE_DROPPED, just a board that is quietly wrong.
			-- Exactly BUDGET_RESERVE, not zero. The reserve exists so the background
			-- loops stop one request short of emptying the Sorted pool that the
			-- shutdown drain also writes to and is never gated on; a reserve of zero
			-- would let the pacer spend the last token a tick before the drain needs
			-- it. Sitting the test right on the boundary is what pins the value.
			local sortedWriteBudget = 1
			local uni = newUniverse({ Options = withBoard({ BudgetPolicy = "Defer" }) })
			stubBudget(uni.Disk, function(name)
				return if name == "SetIncrementSortedAsync" then sortedWriteBudget else 1000
			end)
			local server = uni:Server(1)
			local boardName = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			local ordered = uni.Disk:GetOrderedDataStore(boardName)

			local player = FakePlayer.new(8803)
			server:Join(8803, player)
			uni:Run(30)
			server.Bundle.Data.Get(player).Coins.Set(4242)
			server:Leave(8803)
			uni:Run(120) -- ~80 pacer ticks, every one of them deferred

			expect(ordered._entries["8803"]).to.equal(nil)
			-- Still in the queue, not consumed. This is the assertion the misplaced
			-- gate fails: it reads 0 there, because the item was dequeued and dropped.
			expect(server.Bundle.Scribe.GetMetrics().LbQueueDepth).to.equal(1)
			expect(server.Bundle.Scribe.GetMetrics().LbBudgetDeferred > 0).to.equal(true)

			-- Allowance returns, and the score that was waiting is written.
			sortedWriteBudget = 1000
			uni:Run(30)
			expect(ordered._entries["8803"]).never.to.equal(nil)
			expect(server.Bundle.Scribe.GetMetrics().LbQueueDepth).to.equal(0)
		end)
	end)

	describe("a deferred refresh costs a tick, not a cycle", function()
		it("refreshes on the next second once allowance returns", function()
			-- The refresh loop advances a board's due time on the line ABOVE the
			-- Spawn, so a gate placed around the Spawn skips a refresh whose due time
			-- has already moved a full RefreshInterval out. The board then sits stale
			-- for a minute after the budget recovered, on a loop that ticks every
			-- second -- and every "did it refresh eventually" spec still passes.
			local sortedReadBudget = 0
			local uni = newUniverse({
				Options = withBoard({ BudgetPolicy = "Defer" }),
			})
			stubBudget(uni.Disk, function(name)
				return if name == "GetSortedAsync" then sortedReadBudget else 1000
			end)
			local server = uni:Server(1)
			local boardName = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			local refreshes = countRefreshes(uni.Disk, boardName)

			-- Well past the loop's 5s warm-up and the board's first due time.
			uni:Run(60)
			expect(refreshes.Count).to.equal(0)

			-- Allowance returns. The board is still due, so the very next tick takes
			-- it -- three seconds is generous for a one-second loop and nowhere near
			-- the 60s RefreshInterval a skipped cycle would cost.
			sortedReadBudget = 1000
			uni:Run(3)
			expect(refreshes.Count > 0).to.equal(true)
		end)
	end)

	describe("Scribe.GetBudgetSnapshot", function()
		it("reports what the engine answers, by request type", function()
			local uni = newUniverse({ Options = withBoard() })
			stubBudget(uni.Disk, function(name)
				return if name == "GetSortedAsync" then 7 else 42
			end)
			local server = uni:Server(1)

			local snapshot = server.Bundle.Scribe.GetBudgetSnapshot()
			expect(snapshot.Available).to.equal(true)
			expect(snapshot.Budgets.GetSortedAsync).to.equal(7)
			expect(snapshot.Budgets.UpdateAsync).to.equal(42)
			expect(type(snapshot.At)).to.equal("number")
		end)

		it("reports unavailable rather than an allowance of zero when it cannot ask", function()
			-- The distinction the whole design turns on. A headless runner or a Studio
			-- session with API access off cannot answer, and a caller that read that
			-- as "no budget left" would throttle itself hardest in exactly the
			-- environments where there is nothing to conserve.
			local uni = newUniverse({ Options = withBoard() })
			uni.Disk.GetRequestBudgetForRequestType = function()
				error("API access is not enabled", 0)
			end
			local server = uni:Server(1)

			local snapshot = server.Bundle.Scribe.GetBudgetSnapshot()
			expect(snapshot.Available).to.equal(false)
			expect(snapshot.Reason).never.to.equal(nil)
			expect(next(snapshot.Budgets)).to.equal(nil)
		end)

		it("does not latch a failure", function()
			-- A service handle resolved through a pcall and cached on FAILURE stays
			-- broken for the life of the process: one unlucky query at startup and
			-- the diagnostic never works again, in a build where nothing looks wrong.
			local uni = newUniverse({ Options = withBoard() })
			local failing = true
			stubBudget(uni.Disk, function()
				if failing then
					error("transient", 0)
				end
				return 11
			end)
			local server = uni:Server(1)

			expect(server.Bundle.Scribe.GetBudgetSnapshot().Available).to.equal(false)
			failing = false
			local recovered = server.Bundle.Scribe.GetBudgetSnapshot()
			expect(recovered.Available).to.equal(true)
			expect(recovered.Budgets.UpdateAsync).to.equal(11)
		end)

		it("never throws, whatever the engine returns", function()
			local uni = newUniverse({ Options = withBoard() })
			uni.Disk.GetRequestBudgetForRequestType = function()
				return "not a number"
			end
			local server = uni:Server(1)

			local ok, snapshot = pcall(server.Bundle.Scribe.GetBudgetSnapshot)
			expect(ok).to.equal(true)
			expect(snapshot.Available).to.equal(false)
		end)
	end)
end
