--!nonstrict
-- Each lost frame closes the queue, even with a repair already pending.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Client = require(Root.Scribe.Client)
local Clock = require(Root.Scribe.Internal.Clock)
local Metrics = require(Root.Scribe.Internal.Metrics)
local Wire = require(Root.Scribe.Internal.Wire)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local harness: any = nil
local client: any = nil
local now = 1000

afterEach(function()
	Clock.Reset()
	if client then
		client.Stop()
		client = nil
	end
	if harness then
		harness.Cleanup()
		harness = nil
	end
end)

local function setup(userId: number)
	now = 1000
	Clock.Install({
		Monotonic = function()
			return now
		end,
	})
	harness = TestCtx.make({
		AutoPump = true,
		Template = { Coins = Scribe.Int(0), Log = Scribe.ArrayOf(Scribe.String("")) },
	})
	local player, entry, data = harness.Join(userId)
	harness.Transport.LocalPlayer = player
	client = Client.new(harness.Options, harness.Compiled)
	harness.StepUntil(function()
		return client.IsReady()
	end)
	local real = harness.Transport.SendToClient
	local refuse: { [number]: number } = {}
	harness.Transport.SendToClient = function(self, target, bytes)
		local kind = buffer.readu8(bytes, 0)
		if target == player and (refuse[kind] or 0) > 0 then
			refuse[kind] -= 1
			error("transport adapter: refused", 0)
		end
		return real(self, target, bytes)
	end
	return player, entry, data, refuse
end

local function flags(entry): string
	return `HR={entry.HandshakeReady} RP={entry.ResyncPending} QO={entry.QueueOpen}`
end

local function resyncs(): number
	return Metrics.Get().MirrorResyncs or 0
end

describe("a frame lost while a repair is pending", function()
	it("closes the mirror even after a repair whose Status was refused", function()
		local _player, entry, data, refuse = setup(88850)
		local before = resyncs()
		harness.Ctx.Replication.RequestResync(entry, "test")
		refuse[Wire.Frames.Status] = 1
		harness.Step()
		local afterRepair = flags(entry)
		refuse[Wire.Frames.Diff] = 1
		data.Log.Insert("a")
		harness.Step()
		data.Log.Insert("b")
		harness.Step()
		local log = function(values)
			return table.concat(values, ",")
		end
		local during = `client={log(client.Log.Get())} server={log(data.Log.Get())} {flags(entry)}`
		now += 5
		harness.Step()
		expect(`{afterRepair} | {during} | later client={log(client.Log.Get())} resyncs={resyncs() - before}`).toBe(
			"HR=true RP=true QO=true | client= server=a,b HR=false RP=true QO=false | later client=a,b resyncs=1"
		)
	end)

	it("changes nothing on a mirror that is already closed", function()
		local _player, entry = setup(88851)
		local before = resyncs()
		harness.Ctx.Replication.RequestResync(entry, "first")
		local queue = entry.Queue
		harness.Ctx.Replication.RequestResync(entry, "second")
		expect(`resyncs={resyncs() - before} sameQueue={entry.Queue == queue} {flags(entry)}`).toBe(
			"resyncs=1 sameQueue=true HR=false RP=true QO=false"
		)
	end)
end)
