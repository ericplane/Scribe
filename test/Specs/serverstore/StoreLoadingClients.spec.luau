--!nonstrict
-- Store diffs reach only clients that have received Init.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot) :: any
local Wire = require(ScribeRoot.Internal.Wire)
local Health = require(ScribeRoot.Internal.Health)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)
local StubTransport = require(Root.Test.Helpers.StubTransport)
local Client = require(ScribeRoot.Client)

local function broadcastDiffs(harness): number
	local n = 0
	for _, frame in harness.Transport.SentToClientLog do
		if frame.Player == nil and buffer.readu8(frame.Bytes, 0) == Wire.Frames.Diff then
			n += 1
		end
	end
	return n
end

it("skips a client still loading, and its Init carries the write", function()
	local harness = TestCtx.make({
		Template = { Coins = Scribe.Int(0) },
		Options = { ServerStore = { Wave = Scribe.Int(0) } },
	})
	local a = harness.Join(80101)
	harness.SendHello(a)
	harness.Transport:PumpToServer()
	-- B has joined but sent no Hello, so no Init has reached it.
	local b, entryB = harness.Join(80102)
	harness.Data.ServerStore.Wave.Set(3)
	harness.Step()
	local toB = #harness.FramesFor(b, Wire.Frames.Diff)
	local toA = #harness.FramesFor(a, Wire.Frames.Diff)
	harness.SendHello(b)
	harness.Transport:PumpToServer()
	local inits = harness.FramesFor(b, Wire.Frames.Init)
	local initWave = nil
	for _, op in inits[#inits].Ops do
		if op.Path[1] == "Wave" then
			initWave = op.Value
		end
	end
	-- Everyone ready again: the broadcast fast path is back.
	local before = broadcastDiffs(harness)
	harness.Data.ServerStore.Wave.Set(4)
	harness.Step()
	local fast = broadcastDiffs(harness) - before
	local ready = entryB.HandshakeReady
	harness.Cleanup()
	expect(`ready={ready} toB={toB} toA={toA} initWave={initWave} fast={fast}`).toBe(
		"ready=true toB=0 toA=1 initWave=3 fast=1"
	)
end)

it("still sends a Status change to a client whose profile is loading", function()
	-- Status can arrive before Init; only store diffs wait.
	local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0) } })
	local a = harness.Join(80201)
	harness.SendHello(a)
	harness.Transport:PumpToServer()
	-- B's load is in flight: the store parks StartSessionAsync.
	harness.Fake.YieldOnSessionStart = true
	local b = FakePlayer.new(80202)
	harness.Ctx.Persistence.OnPlayerAdded(b)
	local stateB = harness.Ctx.Persistence.EntryFor(b).State
	local beforeA = #harness.FramesFor(a, Wire.Frames.Status)
	local beforeB = #harness.FramesFor(b, Wire.Frames.Status)
	for i = 1, 200 do
		if Health.GetStatus() ~= "Healthy" then
			break
		end
		Health.ReportFailure("StoreLoadingClients", `k{i}`, "Failed")
	end
	local status = Health.GetStatus()
	local toA = #harness.FramesFor(a, Wire.Frames.Status) - beforeA
	local toB = #harness.FramesFor(b, Wire.Frames.Status) - beforeB
	harness.Fake.YieldOnSessionStart = false
	task.wait()
	FakePlayer.leave(b)
	harness.Ctx.Persistence.OnPlayerRemoving(b)
	harness.Cleanup()
	expect(`stateB={stateB} degraded={status ~= "Healthy"} toA={toA} toB={toB}`).toBe(
		"stateB=Loading degraded=true toA=1 toB=1"
	)
end)

it("sends every store change to a client that stayed after its session ended", function()
	-- An ended session keeps its last snapshot and must still receive store changes.
	local harness = TestCtx.make({
		Template = { Coins = Scribe.Int(0) },
		Options = { ServerStore = { Wave = Scribe.Int(0), Boss = Scribe.Int(0) }, KickOnSessionEnd = false },
	})
	local a = harness.Join(80301)
	harness.SendHello(a)
	harness.Transport:PumpToServer()
	local c, entryC = harness.Join(80303)
	harness.SendHello(c)
	harness.Transport:PumpToServer()
	entryC.Profile:EndSession()
	local gone = harness.Ctx.Persistence.EntryFor(c) == nil
	-- B is loading when the first store write goes out.
	local b = harness.Join(80302)
	harness.Data.ServerStore.Wave.Set(3)
	harness.Step()
	harness.SendHello(b)
	harness.Transport:PumpToServer()
	harness.Data.ServerStore.Boss.Set(9)
	harness.Step()
	-- Per-client sends must stop when the player leaves.
	FakePlayer.leave(c)
	harness.Join(80304)
	harness.Data.ServerStore.Wave.Set(5)
	harness.Step()
	local function storeChanges(player): string
		local seen = {}
		for _, frame in harness.FramesFor(player, Wire.Frames.Diff) do
			for _, op in frame.Ops do
				if op.Path[1] == "Wave" or op.Path[1] == "Boss" then
					table.insert(seen, `{op.Path[1]}={op.Value}`)
				end
			end
		end
		return table.concat(seen, ",")
	end
	local seenA, seenC = storeChanges(a), storeChanges(c)
	harness.Cleanup()
	expect(`gone={gone} A=[{seenA}] C=[{seenC}]`).toBe("gone=true A=[Wave=3,Boss=9,Wave=5] C=[Wave=3,Boss=9]")
end)

it("sends no store change to a client whose session ended before its first snapshot", function()
	-- A session ending before Init still cannot receive store diffs or broadcasts.
	local harness = TestCtx.make({
		Template = { Coins = Scribe.Int(0) },
		Options = { ServerStore = { Wave = Scribe.Int(0) }, KickOnSessionEnd = false },
	})
	local a = harness.Join(80401)
	harness.SendHello(a)
	harness.Transport:PumpToServer()
	local e, entryE = harness.Join(80402)
	entryE.Profile:EndSession()
	local gone = harness.Ctx.Persistence.EntryFor(e) == nil
	local before = #harness.FramesFor(e, Wire.Frames.Diff)
	local broadcastsBefore = broadcastDiffs(harness)
	harness.Data.ServerStore.Wave.Set(7)
	harness.Step()
	local toE = #harness.FramesFor(e, Wire.Frames.Diff) - before
	local toA = #harness.FramesFor(a, Wire.Frames.Diff)
	local fast = broadcastDiffs(harness) - broadcastsBefore
	-- Once E leaves, the broadcast path is back.
	FakePlayer.leave(e)
	harness.Data.ServerStore.Wave.Set(8)
	harness.Step()
	local fastAfter = broadcastDiffs(harness) - broadcastsBefore
	harness.Cleanup()
	expect(`gone={gone} toE={toE} toA={toA} fast={fast} fastAfterLeave={fastAfter}`).toBe(
		"gone=true toE=0 toA=1 fast=0 fastAfterLeave=1"
	)
end)

it("sends a Status change to a loading client on a transport without SendToAllClients", function()
	-- The per-recipient path must reach the same clients the broadcast does.
	local transport = StubTransport.new()
	transport.SendToAllClients = nil
	local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0) }, Transport = transport })
	local a = harness.Join(80501)
	harness.SendHello(a)
	harness.Transport:PumpToServer()
	harness.Fake.YieldOnSessionStart = true
	local b = FakePlayer.new(80502)
	harness.Ctx.Persistence.OnPlayerAdded(b)
	local stateB = harness.Ctx.Persistence.EntryFor(b).State
	local beforeA = #harness.FramesFor(a, Wire.Frames.Status)
	local beforeB = #harness.FramesFor(b, Wire.Frames.Status)
	for i = 1, 200 do
		if Health.GetStatus() ~= "Healthy" then
			break
		end
		Health.ReportFailure("StoreLoadingClients", `n{i}`, "Failed")
	end
	local status = Health.GetStatus()
	local toA = #harness.FramesFor(a, Wire.Frames.Status) - beforeA
	local toB = #harness.FramesFor(b, Wire.Frames.Status) - beforeB
	harness.Fake.YieldOnSessionStart = false
	task.wait()
	FakePlayer.leave(b)
	harness.Ctx.Persistence.OnPlayerRemoving(b)
	harness.Cleanup()
	expect(`stateB={stateB} degraded={status ~= "Healthy"} toA={toA} toB={toB}`).toBe(
		"stateB=Loading degraded=true toA=1 toB=1"
	)
end)

it("keeps a lingering client current while its re-added entry has no snapshot yet", function()
	-- SimulateLoadFailure re-adds the same Player; its client keeps the old snapshot until Init.
	local harness = TestCtx.make({
		AutoPump = true,
		Template = { Coins = Scribe.Int(0) },
		Options = { ServerStore = { Wave = Scribe.Int(0) }, KickOnSessionEnd = false },
	})
	local store = harness.Data.ServerStore
	local a = harness.Join(80601)
	harness.SendHello(a)
	local p, entryP = harness.Join(80602)
	harness.Transport.LocalPlayer = p
	local client = Client.new(harness.Options, harness.Compiled)
	harness.Step()
	entryP.Profile:EndSession()
	store.Wave.Set(1)
	harness.Step()
	local beforeReload = client.ServerStore.Wave.Get()
	harness.Ctx.Persistence.OnPlayerAdded(p)
	store.Wave.Set(2)
	harness.Step()
	store.Wave.Set(3)
	harness.Step()
	local seen = client.ServerStore.Wave.Get()
	client.Stop()
	harness.Cleanup()
	expect(`before={beforeReload} seen={seen}`).toBe("before=1 seen=3")
end)

it("sends one Status change to each client, lingering or re-added, without SendToAllClients", function()
	-- A re-added player receives Status through its entry, without a second copy.
	local transport = StubTransport.new()
	transport.SendToAllClients = nil
	local harness = TestCtx.make({
		Template = { Coins = Scribe.Int(0) },
		Options = { KickOnSessionEnd = false },
		Transport = transport,
	})
	local a = harness.Join(80701)
	harness.SendHello(a)
	harness.Transport:PumpToServer()
	local c, entryC = harness.Join(80702)
	harness.SendHello(c)
	harness.Transport:PumpToServer()
	entryC.Profile:EndSession()
	local r, entryR = harness.Join(80703)
	harness.SendHello(r)
	harness.Transport:PumpToServer()
	entryR.Profile:EndSession()
	harness.Ctx.Persistence.OnPlayerAdded(r)
	local before = {
		a = #harness.FramesFor(a, Wire.Frames.Status),
		c = #harness.FramesFor(c, Wire.Frames.Status),
		r = #harness.FramesFor(r, Wire.Frames.Status),
	}
	for i = 1, 200 do
		if Health.GetStatus() ~= "Healthy" then
			break
		end
		Health.ReportFailure("StoreLoadingClients", `s{i}`, "Failed")
	end
	local toA = #harness.FramesFor(a, Wire.Frames.Status) - before.a
	local toC = #harness.FramesFor(c, Wire.Frames.Status) - before.c
	local toR = #harness.FramesFor(r, Wire.Frames.Status) - before.r
	harness.Cleanup()
	expect(`toA={toA} lingering={toC} reAdded={toR}`).toBe("toA=1 lingering=1 reAdded=1")
end)
