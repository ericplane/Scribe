--!nonstrict
-- Live writes share budget pacing; Defer drains up to eight per tick.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Universe = require(Root.Test.Sim.Universe)
local Guard = require(Root.Test.Sim.Guard)
-- Sim-backed: every node below needs a simulated universe, which only the headless
-- runner can build. Under Studio they report SKIP instead of each failing with the
-- same missing capability -- see test/Sim/Available for why it cannot be provided.
local runIt = if require(Root.Test.Sim.Available).Ready then it else it.skip
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
	runIt("drains several per tick instead of one", function()
		local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }) })
		stubBudget(uni.Disk, function(name)
			return if name == "SetIncrementSortedAsync" then 60 else 1000
		end)
		local server = uni:Server(1)
		backlog(uni, server, 20)
		expect(depth(server) > 10).toBe(true) -- a real backlog exists

		-- Ten seconds is about seven ticks. One-per-tick could not clear twenty.
		uni:Run(10)

		expect(`depth={depth(server)}`).toBe("depth=0")
		expect((server.Bundle.Scribe.GetMetrics().LbWrites or 0) >= 20).toBe(true)
	end)

	runIt("leaves the same backlog largely unwritten without a BudgetPolicy", function()
		-- The control arm, and the one that gives the spec above its meaning.
		-- Identical queue, identical window, no policy: the pacer stays at one
		-- write per tick and most of the queue is still waiting.
		local uni = build({ Options = withBoard() })
		local server = uni:Server(1)
		backlog(uni, server, 20)
		uni:Run(10)

		expect(`drained={depth(server) > 5}`).toBe("drained=true")
		expect((server.Bundle.Scribe.GetMetrics().LbWrites or 0) < 15).toBe(true)
	end)

	runIt("never drains more than the per-tick ceiling", function()
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
		expect(depth(server) > 30).toBe(true)
		uni:Run(3) -- about two ticks
		local wrote = (server.Bundle.Scribe.GetMetrics().LbWrites or 0) - before
		-- Two ticks at the ceiling is 16. Uncapped, the whole remaining queue
		-- would go in the first tick.
		expect(`ceiling={wrote <= 20} drained={wrote > 0}`).toBe("ceiling=true drained=true")
	end)

	runIt("rechecks remaining allowance after each write and preserves headroom", function()
		local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }) })
		local remaining = 0
		stubBudget(uni.Disk, function(name)
			return if name == "SetIncrementSortedAsync" then remaining else 1000
		end)
		local server = uni:Server(1)
		backlog(uni, server, 40)
		local name = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
		local store = uni.Disk:GetOrderedDataStore(name)
		local setAsync = store.SetAsync
		store.SetAsync = function(view, ...)
			remaining -= 1
			return setAsync(view, ...)
		end
		-- Reserve 46 of the 230 writes/minute allowed for 40 players.
		remaining = 49
		local before = server.Bundle.Scribe.GetMetrics().LbWrites or 0
		uni:Run(3)
		expect((server.Bundle.Scribe.GetMetrics().LbWrites or 0) - before).toBe(3)
		expect(remaining).toBe(46)
		expect(depth(server) > 0).toBe(true)
	end)

	runIt("does not query repeatedly within one tick when headroom is exhausted", function()
		local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }) })
		-- An exhausted reserve keeps the backlog for the whole window.
		local queries = stubBudget(uni.Disk, function(name)
			return if name == "SetIncrementSortedAsync" then 3 else 1000
		end)
		local server = uni:Server(1)
		backlog(uni, server, 30)

		local before = queries.ByType.SetIncrementSortedAsync or 0
		uni:Run(12)
		local ticks = (queries.ByType.SetIncrementSortedAsync or 0) - before
		-- Twelve seconds of a jittered 1.5s tick is 6-11 ticks. Two queries per
		-- tick would land above that band.
		expect(`ticks={ticks >= 5 and ticks <= 12}`).toBe("ticks=true")
	end)
end)

describe("coalescing and unknown budget", function()
	runIt("drains one per tick when the queue is not backed up", function()
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
		expect(`writes={wrote}`).toBe("writes=1")
	end)

	runIt("retains bounded pacing when the model answers an infinite budget", function()
		-- Unlimited backend budget must still respect the rate and burst caps.
		local uni = build({ Options = withBoard({ BudgetPolicy = "Defer" }), NoBudget = true })
		local server = uni:Server(1)
		backlog(uni, server, 60)
		local before = server.Bundle.Scribe.GetMetrics().LbWrites or 0
		uni:Run(3)
		local wrote = (server.Bundle.Scribe.GetMetrics().LbWrites or 0) - before
		expect(wrote > 0 and wrote <= 20).toBe(true)
		expect(depth(server) > 0).toBe(true)
		expect(uni.Sched.Stalled).toBe(false)
	end)
end)

describe("the modelled budget query", function()
	runIt("reports the pool a request type actually spends from", function()
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
		expect(`ordered={ordered > 0} standard={standard > 0}`).toBe("ordered=true standard=true")
		-- Ordered writes are the scarcer pool, which is the whole reason the
		-- leaderboard paths are the ones worth pacing.
		expect(`scarcer={ordered < standard}`).toBe("scarcer=true")
		-- An unknown type has no pool and must not invent one.
		expect(disk:GetRequestBudgetForRequestType({ Name = "NotARequestType" })).toBe(0)
	end)

	runIt("reports a spent pool recovering as time passes", function()
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
		expect(`spent={spent} recovered={later > spent}`).toBe(`spent={spent} recovered=true`)
	end)

	runIt("does not spend anything by being asked", function()
		local uni = build({ Options = withBoard(), NoBudget = false })
		local disk = uni.Disk
		-- Spend one first. Without this every call takes the untouched-pool
		-- early return, the accrual path is never reached, and the assertion
		-- below holds no matter what Peek does to the tokens -- which a
		-- mutation that made Peek spend proved by surviving.
		disk.Budget:TryTake(disk._defaultJob, "OrderedWrite")
		local first = disk:GetRequestBudgetForRequestType({ Name = "SetIncrementSortedAsync" })
		expect(first > 0).toBe(true)
		for _ = 1, 20 do
			disk:GetRequestBudgetForRequestType({ Name = "SetIncrementSortedAsync" })
		end
		expect(disk:GetRequestBudgetForRequestType({ Name = "SetIncrementSortedAsync" })).toBe(first)
	end)
end)
