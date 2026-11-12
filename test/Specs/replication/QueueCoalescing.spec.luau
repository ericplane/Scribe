--!nonstrict
-- Shared and ServerStore queues coalesce same-frame writes to a scalar.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any
local Client = require(Root.Scribe.Client)
local Metrics = require(Root.Scribe.Internal.Metrics)
local Wire = require(Root.Scribe.Internal.Wire)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local deepEquals = require(Root.Test.Helpers.DeepEquals)

local itRunning = if RunService:IsRunning() then it else it.skip

local harness

afterEach(function()
	if harness then
		harness.Cleanup()
		harness = nil
	end
end)

--- The second player observes the first player's Shared data.
local function make()
	harness = TestCtx.make({
		Template = {
			Coins = Scribe.Int(0),
			Pub = Scribe.Shared({ Level = Scribe.Int(0), Stats = { Wins = Scribe.Int(0) }, Log = {} }),
		},
		Options = {
			ServerStore = { BossHp = Scribe.Int(1000), Config = { Mode = Scribe.Int(0) }, Pool = {} },
		},
	})
	local a, _, dataA = harness.Join(98101)
	local b = harness.Join(98102)
	harness.SendHello(a)
	harness.Transport.LocalPlayer = b
	local client = Client.new(harness.Options, harness.Compiled)
	harness.Transport:PumpToServer()
	harness.Step()
	harness.Transport:PumpToClient()
	return a, b, dataA, client
end

local function flush()
	harness.Step()
	harness.Transport:PumpToClient()
end

--- Skip frames captured before the writes under test.
local function opsFor(player, frameType, root, skip)
	local out = {}
	local frames = harness.FramesFor(player, frameType)
	for i = skip + 1, #frames do
		for _, op in frames[i].Ops do
			if op.Path[1] == root then
				table.insert(out, `{table.concat(op.Path, ".")}={tostring(op.Value)}`)
			end
		end
	end
	return table.concat(out, " ")
end

itRunning("sends one op for same-frame scalar writes to a Shared field and to a store field", function()
	local _a, b, dataA, client = make()
	local shared = #harness.FramesFor(b, Wire.Frames.SharedDiff)
	local diffs = #harness.FramesFor(b, Wire.Frames.Diff)
	local fires = {}
	client.ServerStore.BossHp.Changed(function(value)
		table.insert(fires, value)
	end)
	Metrics.Reset()
	for i = 1, 10 do
		dataA.Pub.Level.Set(i)
		harness.Data.ServerStore.BossHp.Set(1000 - i)
	end
	flush()
	expect(opsFor(b, Wire.Frames.SharedDiff, "Pub", shared)).toBe("Pub.Level=10")
	expect(opsFor(b, Wire.Frames.Diff, "BossHp", diffs)).toBe("BossHp=990")
	expect(table.concat(fires, ",")).toBe("990")
	-- Nine coalesced writes on the owner's queue and nine on the store's.
	expect(Metrics.Get().OpsCoalesced).toBe(18)
end)

itRunning("starts over each frame", function()
	local _a, b, dataA, client = make()
	for frame = 1, 2 do
		local shared = #harness.FramesFor(b, Wire.Frames.SharedDiff)
		local diffs = #harness.FramesFor(b, Wire.Frames.Diff)
		for i = 1, 3 do
			dataA.Pub.Level.Set(frame * 10 + i)
			harness.Data.ServerStore.BossHp.Set(frame * 100 + i)
		end
		flush()
		expect(opsFor(b, Wire.Frames.SharedDiff, "Pub", shared)).toBe(`Pub.Level={frame * 10 + 3}`)
		expect(opsFor(b, Wire.Frames.Diff, "BossHp", diffs)).toBe(`BossHp={frame * 100 + 3}`)
	end
	expect(client.ServerStore.BossHp.Get()).toBe(203)
end)

itRunning("does not fold a write across a container write to its parent or an array shift", function()
	local _a, _b, dataA, client = make()
	local store = harness.Data.ServerStore

	dataA.Pub.Stats.Wins.Set(1)
	dataA.Pub.Stats.Set({ Wins = 5 })
	dataA.Pub.Stats.Wins.Set(7)
	dataA.Pub.Log.Set({ "a", "b" })
	dataA.Pub.Log[2].Set("x")
	dataA.Pub.Log.Insert("front", 1)
	dataA.Pub.Log[2].Set("y")

	store.Config.Mode.Set(1)
	store.Config.Set({ Mode = 5 })
	store.Config.Mode.Set(7)
	store.Pool.Set({ "a", "b" })
	store.Pool[2].Set("x")
	store.Pool.Insert("front", 1)
	store.Pool[2].Set("y")
	flush()

	local sharedOk, sharedWhy = deepEquals(client.GetShared(98101).Pub, dataA.Pub.Get())
	local poolOk, poolWhy = deepEquals(client.ServerStore.Pool.Get(), store.Pool.Get())
	expect(`{sharedOk} {tostring(sharedWhy)}`).toBe("true nil")
	expect(`{poolOk} {tostring(poolWhy)}`).toBe("true nil")
	expect(`{dataA.Pub.Stats.Wins.Get()}/{table.concat(dataA.Pub.Log.Get(), ",")}`).toBe("7/front,y,x")
	expect(`{client.ServerStore.Config.Mode.Get()}/{table.concat(client.ServerStore.Pool.Get(), ",")}`).toBe(
		"7/front,y,x"
	)
end)
