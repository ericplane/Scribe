--!nonstrict
-- Rejoin the same server while ProfileStore is still loading the previous session.
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Universe = require(Root.Test.Sim.Universe)
local Guard = require(Root.Test.Sim.Guard)
local runIt = if require(Root.Test.Sim.Available).Ready then it else it.skip
local StubTransport = require(Root.Test.Helpers.StubTransport)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)

local universe
local function build()
	universe = Universe.new({
		Seed = 7373,
		Servers = 1,
		Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
		Transport = StubTransport.new({ AutoPump = false }),
		LatencyProfile = "Instant",
		NoBudget = true,
		StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
		Template = { Coins = Scribe.Int(0, { Min = 0 }) },
		Options = { KickOnSessionEnd = true },
	})
	Guard.Install(universe)
	return universe, universe:Server(1)
end

local function stored(uni, key: string)
	for _, e in uni.Disk.Keyspace:Each() do
		if e.Key == key then
			return e.Record.Value
		end
	end
	return nil
end

--- Count updates for this key, delaying only the first around its transform.
local function slowNextUpdate(uni, server, key: string, before: number, after: number)
	local ds = server.Bundle.Ctx.Persistence.Store.data_store
	local original = ds.UpdateAsync
	local calls = { Count = 0 }
	ds.UpdateAsync = function(self, k, transform)
		if k ~= key then
			return original(self, k, transform)
		end
		calls.Count += 1
		if calls.Count > 1 then
			return original(self, k, transform)
		end
		uni.Disk:Wait(before)
		local results = table.pack(original(self, k, transform))
		uni.Disk:Wait(after)
		return table.unpack(results, 1, results.n)
	end
	return calls
end

local function leaveAndRejoin(uni, server, userId: number, leaveAt: number, rejoinAt: number)
	server:Join(userId, FakePlayer.new(userId))
	uni:Run(leaveAt)
	server:Leave(userId)
	uni:Run(rejoinAt - leaveAt)
	local rejoined = FakePlayer.new(userId)
	server:Join(userId, rejoined)
	return rejoined
end

local function saveThrough(uni, server, player, coins: number)
	local entry = server.Bundle.Ctx.Persistence.EntryFor(player)
	local outcome
	if entry and entry.State == "Ready" then
		server.Bundle.Data.Get(player).Coins.Set(coins)
		uni.Sched:Spawn(function()
			outcome = entry.Profile:SaveAwait()
		end)
		uni:Run(5)
	end
	return `state={entry and entry.State} kicked={player.Kicked} outcome={outcome}`
end

afterEach(function()
	Guard.Reset()
	universe = nil
end)

describe("a rejoin while the first load is still in flight", function()
	runIt("loads a saved profile the departed player's load had declined", function()
		local uni, server = build()
		local key = "PLAYER_63001"
		local seeded = FakePlayer.new(63001)
		server:Join(63001, seeded)
		uni:Run(2)
		server.Bundle.Data.Get(seeded).Coins.Set(100)
		server:Leave(63001)
		uni:Run(5)

		-- The first transform runs after the rejoin.
		slowNextUpdate(uni, server, key, 8, 0)
		local rejoined = leaveAndRejoin(uni, server, 63001, 2, 3)
		uni:Run(15)

		local loaded = server.Bundle.Ctx.Persistence.EntryFor(rejoined)
		local coins = if loaded and loaded.State == "Ready" then server.Bundle.Data.Get(rejoined).Coins.Get() else nil
		expect(`loaded={coins} {saveThrough(uni, server, rejoined, 150)} saved={stored(uni, key).Data.Coins}`).toBe(
			"loaded=100 state=Ready kicked=nil outcome=Saved saved=150"
		)
	end)

	runIt("loads a new profile whose first load declined before the rejoin arrived", function()
		local uni, server = build()
		local key = "PLAYER_63002"
		-- The transform runs between leave and rejoin. Its response arrives after both.
		slowNextUpdate(uni, server, key, 2, 6)
		local rejoined = leaveAndRejoin(uni, server, 63002, 1, 3)
		uni:Run(15)

		expect(`{saveThrough(uni, server, rejoined, 5)} saved={stored(uni, key).Data.Coins}`).toBe(
			"state=Ready kicked=nil outcome=Saved saved=5"
		)
	end)

	runIt("still hands the rejoin a session the first load had already taken", function()
		local uni, server = build()
		local key = "PLAYER_63003"
		-- The first load acquires the session before the player leaves.
		local calls = slowNextUpdate(uni, server, key, 0, 8)
		local rejoined = leaveAndRejoin(uni, server, 63003, 2, 3)
		uni:Run(15)

		local callsToLoad = calls.Count
		expect(`calls={callsToLoad} {saveThrough(uni, server, rejoined, 5)} saved={stored(uni, key).Data.Coins}`).toBe(
			"calls=1 state=Ready kicked=nil outcome=Saved saved=5"
		)
	end)
end)
