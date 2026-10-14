--!nonstrict
-- Handler writes reach the caller before the reply.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Client = require(Root.Scribe.Client)
local Wire = require(Root.Scribe.Internal.Wire)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local harness: any = nil
local client: any = nil

afterEach(function()
	if client then
		client.Stop()
		client = nil
	end
	if harness then
		harness.Cleanup()
		harness = nil
	end
end)

-- Synchronous delivery makes the read immediately after Request deterministic.
local function loopback(userId: number)
	harness = TestCtx.make({ AutoPump = true, Options = { RequestTimeout = 0.25, CommandRateLimit = 1000 } })
	local player, _entry, data = harness.Join(userId)
	harness.Transport.LocalPlayer = player
	client = Client.new(harness.Options, harness.Compiled)
	return player, data
end

describe("a command reply", function()
	it("arrives after the handler's unbatched writes", function()
		local _player, data = loopback(88801)
		harness.Data.Command("Buy", function()
			data.Coins.Set(data.Coins.Get() + 50)
			return true
		end)
		local ok = client.Request("Buy")
		expect(`ok={ok} seen={client.Coins.Get()}`).toBe("ok=true seen=50")
	end)

	it("arrives after the writes a handler made before it threw", function()
		local _player, data = loopback(88802)
		harness.Data.Command("Boom", function()
			data.Coins.Set(7)
			error("boom")
		end)
		local ok, reason = client.Request("Boom")
		expect(`ok={ok} reason={reason} seen={client.Coins.Get()}`).toBe("ok=false reason=error seen=7")
	end)

	it("leaves the Shared fan-out to the frame, so a burst of commands coalesces", function()
		-- Shared updates still combine into one frame per watcher.
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0), Pub = Scribe.Shared({ Clicks = Scribe.Int(0) }) },
			Options = { CommandRateLimit = 1000 },
		})
		local owner, _ownerEntry, data = harness.Join(88804)
		local watcher = harness.Join(88805)
		harness.SendHello(owner)
		harness.SendHello(watcher)
		harness.Transport:PumpToServer()
		harness.Step()
		harness.Data.Command("Click", function()
			data.Coins.Set(data.Coins.Get() + 1)
			data.Pub.Clicks.Set(data.Pub.Clicks.Get() + 1)
			return true
		end)
		local function frame(correlation: number): buffer
			local w = Wire.NewWriter(32)
			Wire.U8(w, Wire.Frames.Command)
			Wire.U32(w, correlation)
			Wire.Str(w, "Click")
			Wire.U8(w, 0)
			Wire.Str(w, "")
			return Wire.Finish(w)
		end
		-- The owner's Diffs carrying the handlers' writes. The save-state mirror is deferred,
		-- so on a real engine its write leaves as a Diff of its own inside this frame.
		local function coinDiffs(): number
			local count = 0
			for _, sent in harness.FramesFor(owner, Wire.Frames.Diff) do
				for _, op in sent.Ops do
					if op.Path[1] == "Coins" then
						count += 1
						break
					end
				end
			end
			return count
		end
		local before = #harness.FramesFor(watcher, Wire.Frames.SharedDiff)
		local diffsBefore = coinDiffs()
		for correlation = 1, 5 do
			harness.Transport:InjectToServer(owner, frame(correlation))
		end
		harness.Step()
		local shared = #harness.FramesFor(watcher, Wire.Frames.SharedDiff) - before
		local ownDiffs = coinDiffs() - diffsBefore
		expect(`ownerDiffs={ownDiffs} watcherSharedDiffs={shared}`).toBe("ownerDiffs=5 watcherSharedDiffs=1")
	end)

	it("arrives after a batched handler's writes, as it always did", function()
		local player, data = loopback(88803)
		harness.Data.Command("BuyBatched", function()
			harness.Data.Batch(player, function()
				data.Coins.Set(data.Coins.Get() + 50)
			end)
			return true
		end)
		local ok = client.Request("BuyBatched")
		expect(`ok={ok} seen={client.Coins.Get()}`).toBe("ok=true seen=50")
	end)

	it("arrives after the handler's writes to the server store", function()
		-- A handler that writes the store flushes it before replying.
		harness = TestCtx.make({
			AutoPump = true,
			Template = { Coins = Scribe.Int(0) },
			Options = { ServerStore = { Votes = Scribe.Int(0) }, RequestTimeout = 0.25, CommandRateLimit = 1000 },
		})
		local player = harness.Join(88806)
		harness.Transport.LocalPlayer = player
		client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		harness.Data.Command("Vote", function()
			harness.Data.ServerStore.Votes.Set(harness.Data.ServerStore.Votes.Get() + 1)
			return true
		end)
		local ok = client.Request("Vote")
		expect(`ok={ok} seen={client.ServerStore.Votes.Get()}`).toBe("ok=true seen=1")
	end)

	it("leaves the store to the frame when the handler never wrote it", function()
		-- Unrelated store writes wait for the frame.
		harness = TestCtx.make({
			AutoPump = true,
			Template = { Coins = Scribe.Int(0) },
			Options = { ServerStore = { Votes = Scribe.Int(0) }, RequestTimeout = 0.25, CommandRateLimit = 1000 },
		})
		local player, _entry, data = harness.Join(88807)
		harness.Transport.LocalPlayer = player
		client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		harness.Data.Command("Buy", function()
			data.Coins.Set(data.Coins.Get() + 1)
			return true
		end)
		harness.Data.ServerStore.Votes.Set(7)
		local ok = client.Request("Buy")
		local atReturn = client.ServerStore.Votes.Get()
		harness.Step()
		expect(`ok={ok} atReturn={atReturn} afterFrame={client.ServerStore.Votes.Get()}`).toBe(
			"ok=true atReturn=0 afterFrame=7"
		)
	end)
end)
