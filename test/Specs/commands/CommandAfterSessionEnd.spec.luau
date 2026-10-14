--!nonstrict
-- Ended sessions answer requests with rate-limited "not-ready" replies.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Client = require(Root.Scribe.Client)
local Wire = require(Root.Scribe.Internal.Wire)
local Clock = require(Root.Scribe.Internal.Clock)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local harness: any = nil
local client: any = nil

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

local function commandFrame(correlation: number, name: string): buffer
	local w = Wire.NewWriter(32)
	Wire.U8(w, Wire.Frames.Command)
	Wire.U32(w, correlation)
	Wire.Str(w, name)
	Wire.U8(w, 0)
	Wire.Str(w, "")
	return Wire.Finish(w)
end

describe("a command after the session ended", function()
	it("is answered not-ready at once rather than timing out", function()
		harness = TestCtx.make({
			AutoPump = true,
			Template = { Coins = Scribe.Int(0) },
			Options = { KickOnSessionEnd = false, RequestTimeout = 0.25 },
		})
		local player, entry = harness.Join(88901)
		harness.Transport.LocalPlayer = player
		client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		harness.Data.Command("Ping", function()
			return "pong"
		end)
		local first = client.Request("Ping")
		entry.Profile:EndSession()
		local gone = harness.Ctx.Persistence.EntryFor(player) == nil
		local ok, reason, failed = client.Request("Ping")
		expect(`first={first} gone={gone} ok={ok} reason={reason} marker={failed == Scribe.RequestFailed}`).toBe(
			"first=pong gone=true ok=false reason=not-ready marker=true"
		)
	end)

	it("answers at most CommandRateLimit of them at once", function()
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { KickOnSessionEnd = false, CommandRateLimit = 5 },
		})
		local player, entry = harness.Join(88902)
		harness.SendHello(player)
		harness.Transport:PumpToServer()
		entry.Profile:EndSession()
		local before = #harness.FramesFor(player, Wire.Frames.CommandReply)
		for correlation = 1, 20 do
			harness.Transport:InjectToServer(player, commandFrame(correlation, "Ping"))
		end
		harness.Transport:PumpToServer()
		local replies = #harness.FramesFor(player, Wire.Frames.CommandReply) - before
		expect(replies).toBe(5)
	end)

	it("refills at CommandRateLimit a second and never holds more than that", function()
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { KickOnSessionEnd = false, CommandRateLimit = 5 },
		})
		local player, entry = harness.Join(88904)
		harness.SendHello(player)
		harness.Transport:PumpToServer()
		entry.Profile:EndSession()
		local now = 100
		Clock.Install({
			Monotonic = function()
				return now
			end,
		})
		local counts = {}
		-- Check refill and capacity after long and fractional waits.
		for _, advance in { 0, 1, 10, 0.25 } do
			now += advance
			local before = #harness.FramesFor(player, Wire.Frames.CommandReply)
			for correlation = 1, 20 do
				harness.Transport:InjectToServer(player, commandFrame(correlation, "Ping"))
			end
			table.insert(counts, #harness.FramesFor(player, Wire.Frames.CommandReply) - before)
		end
		expect(table.concat(counts, " ")).toBe("5 5 5 1")
	end)

	it("answers only a whole Command frame", function()
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { KickOnSessionEnd = false },
		})
		local player, entry = harness.Join(88905)
		harness.SendHello(player)
		harness.Transport:PumpToServer()
		entry.Profile:EndSession()
		local before = #harness.FramesFor(player, Wire.Frames.CommandReply)
		local hello = Wire.NewWriter(16)
		Wire.U8(hello, Wire.Frames.Hello)
		Wire.U32(hello, 7)
		Wire.U32(hello, 0)
		local short = buffer.create(3)
		buffer.writeu8(short, 0, Wire.Frames.Command)
		harness.Transport:InjectToServer(player, buffer.create(0))
		harness.Transport:InjectToServer(player, Wire.Finish(hello))
		harness.Transport:InjectToServer(player, short)
		harness.Transport:InjectToServer(player, commandFrame(42, "Ping"))
		local seen = {}
		for i, reply in harness.FramesFor(player, Wire.Frames.CommandReply) do
			if i > before then
				table.insert(seen, `{reply.Correlation}:{reply.Ok}:{reply.Results[1]}`)
			end
		end
		expect(table.concat(seen, " ")).toBe("42:false:not-ready")
	end)

	it("is not answered once the player has left", function()
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { KickOnSessionEnd = false },
		})
		local player, entry = harness.Join(88903)
		harness.SendHello(player)
		harness.Transport:PumpToServer()
		entry.Profile:EndSession()
		harness.Leave(player)
		local before = #harness.FramesFor(player, Wire.Frames.CommandReply)
		harness.Transport:InjectToServer(player, commandFrame(1, "Ping"))
		harness.Transport:PumpToServer()
		expect(#harness.FramesFor(player, Wire.Frames.CommandReply) - before).toBe(0)
	end)
end)
