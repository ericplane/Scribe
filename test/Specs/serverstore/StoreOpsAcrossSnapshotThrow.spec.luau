--!nonstrict
-- Snapshot failures must preserve queued store changes for the next flush.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
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
local cloneVisible = Template.CloneVisible

afterEach(function()
	Template.CloneVisible = cloneVisible
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

it("reach every client when the snapshot being built throws", function()
	local now = 1000
	Clock.Install({
		Monotonic = function()
			return now
		end,
	})
	harness = TestCtx.make({
		AutoPump = true,
		Template = { Coins = Scribe.Int(0) },
		Options = { ServerStore = { Items = Scribe.ArrayOf(Scribe.String("")) } },
	})
	local repaired, repairedEntry = harness.Join(88870)
	harness.SendHello(repaired)
	local watcher = harness.Join(88871)
	harness.Transport.LocalPlayer = watcher
	client = Client.new(harness.Options, harness.Compiled)
	harness.StepUntil(function()
		return client.IsReady()
	end)
	local items = harness.Data.ServerStore.Items
	-- One client's repair is due this frame, and its snapshot throws while being built.
	harness.Ctx.Replication.RequestResync(repairedEntry, "test")
	items.Insert("x")
	-- Only for the Items root, which only the snapshot clones: on a real engine a deferred
	-- write elsewhere can reach CloneVisible during the Step and use the throw up.
	local itemsRoot = harness.Ctx.Compiled.Root.Children.Items
	local throws = 1
	Template.CloneVisible = function(node, ...)
		if throws > 0 and node == itemsRoot then
			throws -= 1
			error("snapshot failed", 0)
		end
		return cloneVisible(node, ...)
	end
	harness.Step()
	items.Insert("y")
	harness.Step()
	local function list(values)
		return table.concat(values, ",")
	end
	local watched = `threw={throws == 0} watcher={list(client.Items.Get())} server={list(items.Get())}`
	-- The repaired client gets them in its next snapshot.
	now += 5
	harness.Step()
	local inits = harness.FramesFor(repaired, Wire.Frames.Init)
	local initItems = "none"
	for _, op in inits[#inits].Ops do
		if op.Path[1] == "Items" then
			initItems = list(op.Value)
		end
	end
	expect(`{watched} repairedInit={initItems}`).toBe("threw=true watcher=x,y server=x,y repairedInit=x,y")
end)
