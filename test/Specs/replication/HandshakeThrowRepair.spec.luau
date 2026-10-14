--!nonstrict
-- Any failed handshake is retried; diffs wait until Init is sent.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Client = require(Root.Scribe.Client)
local Clock = require(Root.Scribe.Internal.Clock)
local Template = require(Root.Scribe.Internal.Template)
local Wire = require(Root.Scribe.Internal.Wire)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local harness: any = nil
local client: any = nil
local now = 1000
local restore: { () -> () } = {}

afterEach(function()
	for _, undo in restore do
		undo()
	end
	table.clear(restore)
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

local function make(template)
	now = 1000
	Clock.Install({
		Monotonic = function()
			return now
		end,
	})
	harness = TestCtx.make({ AutoPump = true, Template = template })
end

-- The next `count` board sends to a ready client throw, as a fault after the Init would.
local function boardsThrow(count: number)
	local leaderboards = harness.Ctx.Leaderboards
	local real = leaderboards.OnClientReady
	leaderboards.OnClientReady = function(...)
		if count > 0 then
			count -= 1
			error("boards failed", 0)
		end
		return real(...)
	end
	table.insert(restore, function()
		leaderboards.OnClientReady = real
	end)
end

local SHARED = { Coins = Scribe.Int(0), Pub = Scribe.Shared({ Title = Scribe.String("") }) }

describe("a snapshot attempt that throws after the Init landed", function()
	it("asks again when it was a Hello's", function()
		make(SHARED)
		local other, _otherEntry, otherData = harness.Join(88860)
		otherData.Pub.Title.Set("bee")
		harness.Step()
		local player, entry = harness.Join(88861)
		boardsThrow(1)
		harness.Transport.LocalPlayer = player
		client = Client.new(harness.Options, harness.Compiled)
		local function title()
			local shared = client.GetShared(other.UserId)
			return if shared then shared.Pub.Title else "none"
		end
		local before = `ready={client.IsReady()} shared={title()} pending={entry.ResyncPending}`
		harness.Step()
		expect(`{before} | shared={title()}`).toBe("ready=true shared=none pending=true | shared=bee")
	end)

	it("asks again when it was a joining client's", function()
		make(SHARED)
		local _other, _otherEntry, otherData = harness.Join(88862)
		otherData.Pub.Title.Set("bee")
		harness.Step()
		local player, entry = harness.Join(88863)
		boardsThrow(1)
		-- What a Hello that arrived during the load leaves for the entry going ready.
		entry.HelloReceived = true
		harness.Ctx.Replication.OnEntryReady(entry)
		local function sharedInits()
			return #harness.FramesFor(player, Wire.Frames.SharedInit)
		end
		local before =
			`inits={#harness.FramesFor(player, Wire.Frames.Init)} sharedInits={sharedInits()} pending={entry.ResyncPending}`
		harness.Step()
		expect(`{before} | sharedInits={sharedInits()}`).toBe("inits=1 sharedInits=0 pending=true | sharedInits=1")
	end)
end)

describe("a repair that throws before its Init", function()
	it("leaves the client not ready, even one a refused Status left ready", function()
		make({ Coins = Scribe.Int(0), Log = Scribe.ArrayOf(Scribe.String("")) })
		local player, entry, data = harness.Join(88864)
		harness.Transport.LocalPlayer = player
		client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		local real = harness.Transport.SendToClient
		local refuseStatus = 1
		harness.Transport.SendToClient = function(self, target, bytes)
			if target == player and buffer.readu8(bytes, 0) == Wire.Frames.Status and refuseStatus > 0 then
				refuseStatus -= 1
				error("transport adapter: refused", 0)
			end
			return real(self, target, bytes)
		end
		-- A repair whose Status was refused: still pending, the client still ready.
		harness.Ctx.Replication.RequestResync(entry, "test")
		harness.Step()
		now += 5
		data.Log.Insert("a")
		-- The next repair throws while taking the snapshot, after clearing the queue. Only
		-- for the Log root, which only the snapshot clones: on a real engine the deferred
		-- save-state mirror write also reaches CloneVisible during the Step.
		local cloneVisible = Template.CloneVisible
		local logRoot = harness.Ctx.Compiled.Root.Children.Log
		local throws = 1
		Template.CloneVisible = function(node, ...)
			if throws > 0 and node == logRoot then
				throws -= 1
				error("snapshot failed", 0)
			end
			return cloneVisible(node, ...)
		end
		table.insert(restore, function()
			Template.CloneVisible = cloneVisible
		end)
		harness.Step()
		data.Log.Insert("b")
		harness.Step()
		local function log(values)
			return table.concat(values, ",")
		end
		local during =
			`threw={throws == 0} client={log(client.Log.Get())} server={log(data.Log.Get())} ready={entry.HandshakeReady}`
		now += 5
		harness.Step()
		expect(`{during} | later client={log(client.Log.Get())}`).toBe(
			"threw=true client= server=a,b ready=false | later client=a,b"
		)
	end)
end)
