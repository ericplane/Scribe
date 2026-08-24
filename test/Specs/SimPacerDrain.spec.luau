--!nonstrict
-- The leaderboard write pacer under a backlog.
--
-- The pacer drains one queued score per tick at a flat 1.5s, i.e. 40/min, whatever
-- the server is actually allowed. That is fine until more than 40 distinct
-- (board, user) pairs change in a minute; past that the queue grows, and at
-- QUEUE_CAP the overflow path evicts the OLDEST -- so the scores that have waited
-- longest are the ones thrown away.
--
-- The fix reacts to BACKLOG, not to the allowance on its own. This matters, and it
-- is why the item is not the "derive the interval from the budget" it started as:
-- the modelled ordered-write allowance is 30/min on an empty server (BELOW the
-- flat 40/min, so small servers would have got slower) and about 280/min at 50
-- players (which would have shattered the dedup window that collapses a burst of
-- score changes into a single write). Neither is an improvement. A deep queue is.
--
-- So: with no backlog, or with no budget opinion, the pacer behaves exactly as it
-- always has. Those inertness specs are the important half of this file.

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

	local function build(overrides)
		local config = {
			Seed = 6161,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 20, SESSION_STEAL = 10, FIRST_LOAD_REPEAT = 2, ASSUME_DEAD = 60 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {
				Leaderboards = { Coins = { Stat = "Coins", Limit = 100, RefreshInterval = 60 } },
			},
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	local function withBoard(options)
		local merged = { Leaderboards = { Coins = { Stat = "Coins", Limit = 100, RefreshInterval = 60 } } }
		for key, value in options or {} do
			merged[key] = value
		end
		return merged
	end

	local function stubBudget(disk, remainingFor)
		local queries = { Count = 0, ByType = {} }
		disk.GetRequestBudgetForRequestType = function(_self, kind)
			local name = if type(kind) == "table" and kind.Name then kind.Name else tostring(kind)
			queries.Count += 1
			queries.ByType[name] = (queries.ByType[name] or 0) + 1
			return remainingFor(name)
		end
		return queries
	end

	--- Join `n` players and give each a distinct score, producing `n` queue entries.
	local function backlog(uni, server, n: number)
		for i = 1, n do
			local player = FakePlayer.new(8600 + i)
			server:Join(8600 + i, player)
			uni:Run(0.05)
			server.Bundle.Data.Get(player).Coins.Set(100 + i)
		end
		uni:Run(0.2)
	end

	local function depth(server): number
		return server.Bundle.Scribe.GetMetrics().LbQueueDepth or 0
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("with a backlog and allowance to spare", function()
		it("drains several per tick instead of one", function()
			local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }) })
			stubBudget(uni.Disk, function(name)
				return if name == "SetIncrementSortedAsync" then 60 else 1000
			end)
			local server = uni:Server(1)
			backlog(uni, server, 20)
			expect(depth(server) > 10).to.equal(true) -- a real backlog exists

			-- Ten seconds is about seven ticks. One-per-tick could not clear twenty.
			uni:Run(10)

			expect(`depth={depth(server)}`).to.equal("depth=0")
			expect((server.Bundle.Scribe.GetMetrics().LbWrites or 0) >= 20).to.equal(true)
		end)

		it("leaves the same backlog largely unwritten without a BudgetPolicy", function()
			-- The control arm, and the one that gives the spec above its meaning.
			-- Identical queue, identical window, no policy: the pacer stays at one
			-- write per tick and most of the queue is still waiting.
			local uni = build({ Options = withBoard() })
			local server = uni:Server(1)
			backlog(uni, server, 20)
			uni:Run(10)

			expect(`drained={depth(server) > 5}`).to.equal("drained=true")
			expect((server.Bundle.Scribe.GetMetrics().LbWrites or 0) < 15).to.equal(true)
		end)

		it("never drains more than the per-tick ceiling", function()
			-- A huge allowance must not turn the pacer into an unpaced flush.
			local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }) })
			stubBudget(uni.Disk, function()
				return 100000
			end)
			local server = uni:Server(1)
			backlog(uni, server, 60)

			-- Measured as a DELTA: building the backlog itself advances virtual time
			-- past several ticks, so the absolute counter already includes writes
			-- this window did not do.
			local before = server.Bundle.Scribe.GetMetrics().LbWrites or 0
			expect(depth(server) > 30).to.equal(true)
			uni:Run(3) -- about two ticks
			local wrote = (server.Bundle.Scribe.GetMetrics().LbWrites or 0) - before
			-- Two ticks at the ceiling is 16. Uncapped, the whole remaining queue
			-- would go in the first tick.
			expect(`ceiling={wrote <= 20} drained={wrote > 0}`).to.equal("ceiling=true drained=true")
		end)

		it("drains only what the allowance actually leaves spare", function()
			-- Reserve is 1, so an allowance of 4 leaves 3 to spend.
			local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }) })
			stubBudget(uni.Disk, function(name)
				return if name == "SetIncrementSortedAsync" then 4 else 1000
			end)
			local server = uni:Server(1)
			backlog(uni, server, 40)

			local before = server.Bundle.Scribe.GetMetrics().LbWrites or 0
			uni:Run(3) -- about two ticks, so at most six writes
			local wrote = (server.Bundle.Scribe.GetMetrics().LbWrites or 0) - before
			-- Three per tick, not the eight the ceiling alone would allow.
			expect(`spare={wrote <= 6} drained={wrote > 0}`).to.equal("spare=true drained=true")
		end)

		it("still asks the engine only once per tick", function()
			-- Sizing the drain must reuse the gate's reading. Two queries per tick
			-- can disagree -- the gate saying proceed while the sizing backs off --
			-- and they double a number three other specs pin at exactly zero.
			local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }) })
			local queries = stubBudget(uni.Disk, function()
				return 1000
			end)
			local server = uni:Server(1)
			backlog(uni, server, 30)

			local before = queries.ByType.SetIncrementSortedAsync or 0
			uni:Run(12)
			local ticks = (queries.ByType.SetIncrementSortedAsync or 0) - before
			-- Twelve seconds of a jittered 1.5s tick is 6-11 ticks. Two queries per
			-- tick would land above that band.
			expect(`ticks={ticks >= 5 and ticks <= 12}`).to.equal("ticks=true")
		end)
	end)

	describe("inertness", function()
		it("drains one per tick when the queue is not backed up", function()
			-- The dedup window depends on this. A single queued score must still
			-- wait its tick, or a burst of changes stops collapsing into one write.
			local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }) })
			stubBudget(uni.Disk, function()
				return 1000
			end)
			local server = uni:Server(1)
			local player = FakePlayer.new(8701)
			server:Join(8701, player)
			uni:Run(1)

			local data = server.Bundle.Data.Get(player)
			for i = 1, 20 do
				data.Coins.Set(i)
			end
			uni:Run(10)

			-- Twenty changes to ONE key still collapse to a single write.
			local wrote = server.Bundle.Scribe.GetMetrics().LbWrites or 0
			expect(`writes={wrote}`).to.equal("writes=1")
		end)

		it("stays at one per tick when budgets are switched off entirely", function()
			-- NoBudget makes the modelled disk answer infinity. Treating that as
			-- headroom would empty the queue in one tick across most of the suite,
			-- and a formula dividing by it would produce a zero-second interval --
			-- which is a scheduler spin, not a fast pacer.
			local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }), NoBudget = true })
			local server = uni:Server(1)
			backlog(uni, server, 20)
			uni:Run(10)

			expect((server.Bundle.Scribe.GetMetrics().LbWrites or 0) < 15).to.equal(true)
			expect(uni.Sched.Stalled).to.equal(false)
		end)
	end)

	describe("the modelled budget query", function()
		it("reports the pool a request type actually spends from", function()
			-- A harness defect this item had to fix first. The query looked its pool
			-- up by the ENGINE's request-type name, while the model keys pools as
			-- OrderedWrite / OrderedRead / StandardWrite -- a key never written. So
			-- every unstubbed query answered 0 no matter what the modelled allowance
			-- was, and no simulation could hand a budget-aware path a real number.
			local uni = build({ Options = withBoard(), NoBudget = false })
			local disk = uni.Disk

			-- An untouched pool reports its full allowance rather than nothing.
			local ordered = disk:GetRequestBudgetForRequestType({ Name = "SetIncrementSortedAsync" })
			local standard = disk:GetRequestBudgetForRequestType({ Name = "UpdateAsync" })
			expect(`ordered={ordered > 0} standard={standard > 0}`).to.equal("ordered=true standard=true")
			-- Ordered writes are the scarcer pool, which is the whole reason the
			-- leaderboard paths are the ones worth pacing.
			expect(`scarcer={ordered < standard}`).to.equal("scarcer=true")
			-- An unknown type has no pool and must not invent one.
			expect(disk:GetRequestBudgetForRequestType({ Name = "NotARequestType" })).to.equal(0)
		end)

		it("reports a spent pool recovering as time passes", function()
			-- The reason Peek exists at all is a budget that comes BACK. A reading
			-- that ignored accrual would show a spent pool as permanently empty and
			-- a budget-aware caller would back off forever. Seventy seconds crosses
			-- a minute boundary, so this holds under both accrual modes.
			local uni = build({ Options = withBoard(), NoBudget = false })
			local disk = uni.Disk
			for _ = 1, 200 do
				disk.Budget:TryTake(disk._defaultJob, "OrderedWrite")
			end
			local spent = disk:GetRequestBudgetForRequestType({ Name = "SetIncrementSortedAsync" })
			uni:Run(70)
			local later = disk:GetRequestBudgetForRequestType({ Name = "SetIncrementSortedAsync" })
			expect(`spent={spent} recovered={later > spent}`).to.equal(`spent={spent} recovered=true`)
		end)

		it("does not spend anything by being asked", function()
			local uni = build({ Options = withBoard(), NoBudget = false })
			local disk = uni.Disk
			-- Spend one first. Without this every call takes the untouched-pool
			-- early return, the accrual path is never reached, and the assertion
			-- below holds no matter what Peek does to the tokens -- which a
			-- mutation that made Peek spend proved by surviving.
			disk.Budget:TryTake(disk._defaultJob, "OrderedWrite")
			local first = disk:GetRequestBudgetForRequestType({ Name = "SetIncrementSortedAsync" })
			expect(first > 0).to.equal(true)
			for _ = 1, 20 do
				disk:GetRequestBudgetForRequestType({ Name = "SetIncrementSortedAsync" })
			end
			expect(disk:GetRequestBudgetForRequestType({ Name = "SetIncrementSortedAsync" })).to.equal(first)
		end)
	end)
end
