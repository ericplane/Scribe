--!nonstrict
-- Passive board diagnostics across independently owned bundles.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Clock = require(Root.Scribe.Internal.Clock)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local Loader = require(Root.Test.Sim.Loader)
local itSim = if require(Root.Test.Sim.Available).Ready then it else it.skip
local harnesses, previous = {}, {}

beforeEach(function()
	for _, board in Scribe.GetLeaderboardSnapshot() do
		previous[board.BundleId] = true
	end
end)

afterEach(function()
	for _, harness in harnesses do
		harness.Cleanup()
	end
	table.clear(harnesses)
	table.clear(previous)
	Clock.Reset()
end)

local function make(boards)
	local harness = TestCtx.make({ Options = { Leaderboards = boards } })
	table.insert(harnesses, harness)
	return harness, harness.Ctx.Leaderboards
end

local function snapshot()
	local out = {}
	for _, board in Scribe.GetLeaderboardSnapshot() do
		if not previous[board.BundleId] then
			table.insert(out, board)
		end
	end
	return out
end

it("discovers later bundles and orders duplicate board names by stable bundle ID", function()
	expect(#snapshot()).toBe(0)
	local first, lb = make({ Zebra = { Stat = "Coins" }, Coins = { Stat = "Coins" } })
	local initial = snapshot()
	expect(#initial).toBe(2)
	expect(initial[1].Name).toBe("Coins")
	expect(initial[2].Name).toBe("Zebra")
	expect(initial[1].BundleId).toBe(initial[2].BundleId)
	local firstId = initial[1].BundleId
	local second = make({ Coins = { Stat = "Coins" } })
	local later = snapshot()
	expect(#later).toBe(3)
	expect(later[1].BundleId).toBe(firstId)
	expect(later[3].BundleId > firstId).toBe(true)
	expect(later[3].Name).toBe("Coins")
	lb.Start()
	expect(#snapshot()).toBe(3)
	first.Data.Stop()
	expect(#snapshot()).toBe(1)
	expect(snapshot()[1].BundleId).toBe(later[3].BundleId)
	second.Data.Stop()
	second.Data.Stop()
	expect(#snapshot()).toBe(0)
end)

it("reads cached health without refreshing or writing and returns detached records", function()
	local now = 100
	Clock.Install({
		Monotonic = function()
			return now
		end,
	})
	local harness, lb = make({ Coins = { Stat = "Coins" }, Server = { Stat = "Coins", Scope = "Server" } })
	harness.Join(89301)
	local store = lb.MockStoreFor("Coins")
	local reads, writes = 0, 0
	local get, set = store.GetSortedAsync, store.SetAsync
	store.GetSortedAsync = function(self, ...)
		reads += 1
		return get(self, ...)
	end
	store.SetAsync = function(self, ...)
		writes += 1
		return set(self, ...)
	end
	local initial = snapshot()
	expect(initial[1].Status).toBe("Starting")
	expect(initial[1].PendingWrites).toBe(1)
	expect(initial[2].PendingWrites).toBe(0)
	expect(reads).toBe(0)
	expect(writes).toBe(0)
	initial[1].Name, initial[1].Status, initial[1].PendingWrites = "changed", "changed", -1
	table.clear(initial)
	expect(snapshot()[1].Name).toBe("Coins")
	expect(snapshot()[1].PendingWrites).toBe(1)
	lb.FlushAllBlocking(1)
	lb.RefreshNow("Coins")
	lb.RefreshNow("Server")
	local beforeReads, beforeWrites = reads, writes
	local healthy = snapshot()
	expect(healthy[1].Status).toBe("Healthy")
	expect(healthy[1].PendingWrites).toBe(0)
	expect(healthy[2].Status).toBe("Healthy")
	now += 121
	for _ = 1, 4 do
		for _, board in snapshot() do
			local direct = harness.Data.GetLeaderboardStatus(board.Name)
			for key, value in direct do
				expect(board[key]).toBe(value)
			end
			expect(board.Status).toBe("Degraded")
			expect(board.ReadAge).toBe(121)
		end
	end
	expect(reads).toBe(beforeReads)
	expect(writes).toBe(beforeWrites)
end)

it("omits empty, unstarted and failed bundles", function()
	local harness = make({})
	expect(#snapshot()).toBe(0)
	local Leaderboards = require(Root.Scribe.Server.Leaderboards)
	local ctx = table.clone(harness.Ctx)
	ctx.Options = table.clone(harness.Options)
	ctx.Options.Leaderboards = { Coins = { Stat = "Coins" } }
	local unstarted = Leaderboards.new(ctx)
	expect(#snapshot()).toBe(0)
	unstarted.Stop()
	unstarted.Start()
	expect(#snapshot()).toBe(0)
	expect(function()
		TestCtx.make({ Options = { Leaderboards = { Coins = { Stat = "Coins" } }, Products = { Invalid = {} } } })
	end).toThrow()
	expect(#snapshot()).toBe(0)
end)

itSim("returns an empty client snapshot even if its private registry has a provider", function()
	local cache = Loader.NewCache()
	local env = table.clone(__SimHost.BaseGlobals)
	local realGame = env.game
	local clientRun = setmetatable({
		IsServer = function()
			return false
		end,
	}, { __index = realGame:GetService("RunService") })
	env.game = setmetatable({
		GetService = function(_, name)
			return if name == "RunService" then clientRun else realGame:GetService(name)
		end,
	}, { __index = realGame })
	local client = Loader.RequireFresh(Root.Scribe, cache, env)
	local registry = Loader.RequireFresh(Root.Scribe.Internal.LeaderboardDiagnostics, cache, env)
	local provider = function()
		return { Coins = { Status = "Healthy", PendingWrites = 0, RetryingWrites = 0, RejectedWrites = 0 } }
	end
	local remove = registry.Register(provider)
	expect(#registry.Snapshot()).toBe(1)
	expect(#client.GetLeaderboardSnapshot()).toBe(0)
	remove()
	expect(#registry.Snapshot()).toBe(0)
end)
