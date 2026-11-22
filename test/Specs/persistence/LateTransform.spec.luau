--!nonstrict
-- Replay failed UpdateAsync transforms against the vendored ProfileStore.
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
		Seed = 7272,
		Servers = 1,
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

local function stored(uni, key: string)
	for _, e in uni.Disk.Keyspace:Each() do
		if e.Key == key then
			return e.Record.Value
		end
	end
	return nil
end

--- Fail UpdateAsync and return a callback that replays its transform.
local function holdNextTransform(uni, server, key: string)
	local ds = server.Bundle.Ctx.Persistence.Store.data_store
	local original = ds.UpdateAsync
	local held
	ds.UpdateAsync = function(self, k, transform)
		if k ~= key then
			return original(self, k, transform)
		end
		ds.UpdateAsync = original
		held = transform
		error("502: API Services rejected request with error. HTTP 500 (Internal Server Error)", 0)
	end
	return function()
		uni.Sched:Spawn(function()
			original(ds, key, held)
		end)
		uni:Run(1)
	end
end

afterEach(function()
	Guard.Reset()
	universe = nil
end)

describe("a transform that runs after its call has answered", function()
	runIt("leaves the session alone when a start transform lands after its retry took it", function()
		local uni, server = build()
		local key = "PLAYER_62001"
		local player = FakePlayer.new(62001)
		local landLate = holdNextTransform(uni, server, key)
		server:Join(62001, player)
		uni:Run(5)

		local entry = server.Bundle.Ctx.Persistence.EntryFor(player)
		server.Bundle.Data.Get(player).Coins.Set(100)
		landLate()
		local count = stored(uni, key).MetaData.SessionLoadCount

		local outcome
		uni.Sched:Spawn(function()
			outcome = entry.Profile:SaveAwait()
		end)
		uni:Run(10)

		expect(`count={count} outcome={outcome} state={entry.State} coins={stored(uni, key).Data.Coins}`).toBe(
			"count=1 outcome=Saved state=Ready coins=100"
		)
	end)

	runIt("writes nothing when a save transform lands after its call answered Failed", function()
		local uni, server = build()
		local key = "PLAYER_62002"
		local player = FakePlayer.new(62002)
		server:Join(62002, player)
		uni:Run(2)

		local entry = server.Bundle.Ctx.Persistence.EntryFor(player)
		server.Bundle.Data.Get(player).Coins.Set(7)
		local landLate = holdNextTransform(uni, server, key)
		local outcome
		uni.Sched:Spawn(function()
			outcome = entry.Profile:SaveAwait()
		end)
		uni:Run(5)

		local writeIndex = stored(uni, key).MetaData.WriteIndex
		landLate()
		local after = stored(uni, key)

		expect(`outcome={outcome} moved={after.MetaData.WriteIndex ~= writeIndex} coins={after.Data.Coins}`).toBe(
			"outcome=Failed moved=false coins=0"
		)
	end)
end)
