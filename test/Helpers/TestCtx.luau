--!strict
-- Test harness builder: constructs an isolated Scribe server instance with a
-- fake ProfileStore and a stub transport (via Server.build), plus helpers for
-- driving the player lifecycle and decoding captured wire frames.

local ScribeRoot = script.Parent.Parent.Parent.Scribe

local Scribe = require(ScribeRoot) :: any
local Template = require(ScribeRoot.Internal.Template)
local Wire = require(ScribeRoot.Internal.Wire)
local Health = require(ScribeRoot.Internal.Health)
local Server = require(ScribeRoot.Server) :: any

local FakeProfileStore = require(script.Parent.FakeProfileStore)
local StubTransport = require(script.Parent.StubTransport)
local FakePlayer = require(script.Parent.FakePlayer)

local TestCtx = {}

--- A template that exercises every declarator and wire shape.
function TestCtx.defaultTemplate(): { [string]: any }
	return {
		Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }), -- both bounds: fixed width
		Gems = Scribe.Int(0, { Min = 0 }), -- unsigned varint
		Delta = Scribe.Int(0), -- zigzag varint
		Health = Scribe.Number(100, { Min = 0, Max = 100 }), -- f64, clamped
		Team = Scribe.Enum("Civilian", { "Civilian", "Police", "MP" }), -- u8 index
		Nick = Scribe.String("", { MaxLength = 8 }),
		Settings = { Music = true, Sfx = true }, -- static struct children
		Inventory = {}, -- dynamic dictionary
		Quests = {}, -- array (generic elements)
		Booster = Scribe.Timed(false),
		Secret = Scribe.ServerOnly({ Flagged = false }),
		Pub = Scribe.Shared({ Title = "" }),
		Runtime = Scribe.Session({ InCombat = false }),
	}
end

export type Harness = {
	Data: any,
	Ctx: any,
	Transport: any,
	Fake: any, -- FakeProfileStore module fake
	Compiled: Template.Compiled,
	Options: { [string]: any },
	Join: (userId: number?) -> (any, any, any), -- (player, entry, data accessor)
	Leave: (player: any) -> (),
	SendHello: (player: any) -> (),
	DecodeFrame: (bytes: buffer) -> { [string]: any },
	FramesFor: (player: any?, frameType: number?) -> { { [string]: any } },
	Cleanup: () -> (),
}

function TestCtx.make(config: { Template: { [string]: any }?, Options: { [string]: any }?, AutoPump: boolean? }?): Harness
	local cfg = config or {}
	local fake = FakeProfileStore.new()
	local transport = StubTransport.new({ AutoPump = cfg.AutoPump })

	local options: { [string]: any } = {
		Template = cfg.Template or TestCtx.defaultTemplate(),
		Transport = transport,
		ProfileStore = fake,
		ProfileStoreIndex = "Default", -- required; keeps persisted keys "Default/PLAYER_<id>"
		ProfileKeyPrefix = "PLAYER_",
		UseMock = true, -- keeps leaderboards on the in-memory store
		OwnReceipts = false, -- never bind the real MarketplaceService.ProcessReceipt
		KickOnSessionEnd = false,
		LogLevel = "Fatal",
		Banner = false, -- keep test output clean
	}
	for key, value in cfg.Options or {} do
		options[key] = value
	end

	-- Mirror src/init.luau's compile config: purchase logs are opt-in.
	local purchaseLog = options.PurchaseLog or {}
	local compiled = Template.Compile(options.Template, {
		ReplicateRobuxLog = purchaseLog.ReplicateRobux == true,
		ReplicateInGameLog = purchaseLog.ReplicateInGame == true,
	})
	local Data, ctx = Server.build(options, compiled)

	local harness = {} :: any
	harness.Data = Data
	harness.Ctx = ctx
	harness.Transport = transport
	harness.Fake = fake
	harness.Compiled = compiled
	harness.Options = options

	local joined: { any } = {}

	-- The fake ProfileStore never yields, so load runs synchronously inside
	-- OnPlayerAdded's task.spawn and the entry is Ready on return.
	function harness.Join(userId: number?): (any, any, any)
		local player = FakePlayer.new(userId)
		table.insert(joined, player)
		ctx.Persistence.OnPlayerAdded(player)
		local accessor, reason = ctx.Persistence.WaitForData(player)
		if accessor == nil then
			error(`TestCtx.Join: load failed ({reason})`, 2)
		end
		local entry = ctx.Persistence.EntryFor(player)
		return player, entry, accessor
	end

	function harness.Leave(player: any)
		FakePlayer.leave(player)
		ctx.Persistence.OnPlayerRemoving(player)
	end

	function harness.SendHello(player: any)
		local w = Wire.NewWriter(8)
		Wire.U8(w, Wire.Frames.Hello)
		Wire.U32(w, compiled.Hash % 4294967296)
		Wire.U8(w, Wire.PROTOCOL_VERSION)
		transport:InjectToServer(player, Wire.Finish(w))
	end

	function harness.DecodeFrame(bytes: buffer): { [string]: any }
		local reader = Wire.NewReader(bytes)
		local frameType = Wire.RU8(reader)
		local frame: { [string]: any } = { Type = frameType }
		if frameType == Wire.Frames.Init or frameType == Wire.Frames.Diff then
			frame.Ops = Wire.DecodeOps(reader, compiled)
		elseif frameType == Wire.Frames.SharedInit or frameType == Wire.Frames.SharedDiff then
			frame.UserId = Wire.RF64(reader)
			frame.Ops = Wire.DecodeOps(reader, compiled)
		elseif frameType == Wire.Frames.SharedGone then
			frame.UserId = Wire.RF64(reader)
		elseif frameType == Wire.Frames.Status then
			frame.Status = Wire.RU8(reader)
		elseif frameType == Wire.Frames.CommandReply then
			frame.Correlation = Wire.RU32(reader)
			frame.Ok = Wire.RU8(reader) == 1
			local count = Wire.RU8(reader)
			local results = table.create(count)
			for i = 1, count do
				results[i] = Wire.DecodeGeneric(reader)
			end
			frame.Results = results
		elseif frameType == Wire.Frames.Leaderboard then
			frame.Board = Wire.RStr(reader)
			local count = Wire.RU8(reader)
			local entries = table.create(count)
			for rank = 1, count do
				table.insert(entries, {
					Rank = rank,
					UserId = Wire.RF64(reader),
					Name = Wire.RStr(reader),
					Score = Wire.RF64(reader),
				})
			end
			frame.Entries = entries
			if Wire.RU8(reader) == 1 then
				frame.MyRank = Wire.RVarint(reader)
				frame.MyScore = Wire.RF64(reader)
			end
		end
		return frame
	end

	--- Decoded frames sent to `player` (or broadcasts), optionally filtered by
	--- frame type.
	function harness.FramesFor(player: any?, frameType: number?): { { [string]: any } }
		local out = {}
		for _, sent in transport:FramesFor(player) do
			local frame = harness.DecodeFrame(sent.Bytes)
			if frameType == nil or frame.Type == frameType then
				table.insert(out, frame)
			end
		end
		return out
	end

	function harness.Cleanup()
		for _, player in joined do
			if ctx.Persistence.EntryFor(player) then
				harness.Leave(player)
			end
		end
		-- The Health singleton is shared across harnesses: walk it back to
		-- Healthy so failure-injection tests don't poison later specs.
		Health.SetCritical(false)
		for _ = 1, 40 do
			if Health.GetStatus() == "Healthy" then
				break
			end
			Health.ReportSuccess("TestCleanup")
		end
	end

	return harness
end

return TestCtx
