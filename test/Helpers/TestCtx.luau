--!strict
-- Test harness builder: constructs an isolated Scribe server instance with a
-- fake ProfileStore and a stub transport (via Server.build), plus helpers for
-- driving the player lifecycle and decoding captured wire frames.

local RunService = game:GetService("RunService")

local ScribeRoot = script.Parent.Parent.Parent.Scribe

local Scribe = require(ScribeRoot) :: any
local Template = require(ScribeRoot.Internal.Template)
local Wire = require(ScribeRoot.Internal.Wire)
local Health = require(ScribeRoot.Internal.Health)
local Server = require(ScribeRoot.Server) :: any

local FakeProfileStore = require(script.Parent.FakeProfileStore)
local StubTransport = require(script.Parent.StubTransport)
local FakePlayer = require(script.Parent.FakePlayer)
local Reassemble = require(script.Parent.Reassemble)

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
	TryJoin: (userId: number?, timeout: number?) -> (any, any, any, string?), -- load may fail (locked)
	Step: () -> (), -- drive one real PostSimulation replication flush
	Leave: (player: any) -> (),
	SendHello: (player: any) -> (),
	DecodeFrame: (bytes: buffer) -> { [string]: any },
	FramesFor: (player: any?, frameType: number?) -> { { [string]: any } },
	Cleanup: () -> (),
}

function TestCtx.make(
	config: {
		Template: { [string]: any }?,
		Options: { [string]: any }?,
		AutoPump: boolean?,
		-- Reuse an existing FakeProfileStore instead of minting a private one, so
		-- two harnesses model two SERVERS sharing one DataStore: same Persisted,
		-- same ActiveProfiles (so the session lock is real across them), same
		-- Mailboxes (so cross-server messages actually arrive). Without this every
		-- harness gets its own disk and no spec can express a two-server hazard.
		Fake: any?,
		-- Supply the loopback transport instead of letting the harness mint one, so
		-- a spec can set a field Scribe reads at CONSTRUCTION -- MaxFrameBytes is
		-- read once inside Replication.new, before any spec could reach
		-- harness.Transport to set it. harness.Transport is then this table, so
		-- FramesFor and the pump helpers all work unchanged.
		Transport: any?,
	}?
): Harness
	local cfg = config or {}
	local fake = cfg.Fake or FakeProfileStore.new()
	local transport = cfg.Transport or StubTransport.new({ AutoPump = cfg.AutoPump })

	local options: { [string]: any } = {
		Template = cfg.Template or TestCtx.defaultTemplate(),
		Transport = transport,
		ProfileStore = fake,
		ProfileStoreIndex = "Default", -- required; keeps persisted keys "Default/PLAYER_<id>"
		ProfileKeyPrefix = "PLAYER_",
		-- Legacy flag on purpose, NOT Mode: the AuditFixes specs assert on legacy
		-- resolution, which only runs when Mode is absent. It resolves to Mode
		-- "Mock", so profiles and leaderboards both stay on in-memory stores.
		UseMock = true,
		OwnReceipts = false, -- never bind the real MarketplaceService.ProcessReceipt
		KickOnSessionEnd = false,
		LogLevel = "Fatal",
		Banner = false, -- keep test output clean
	}
	for key, value in cfg.Options or {} do
		options[key] = value
	end

	-- SCRIBE_FRAGMENT_ALL=1 drives the WHOLE suite through Wire.Fragment by making
	-- the outbound budget smaller than any frame Scribe produces.
	--
	-- It exists because the honest objection to fragmentation is that it is
	-- unreachable: every frame the fixtures emit is far under the 65536 default
	-- (measured across a full run: 11,942 outbound frames, largest 39,920 bytes,
	-- none over the budget), so "the existing assertions still pass" says nothing
	-- about the new code. Under this switch every assertion in the suite is an
	-- assertion about a reassembled frame. A spec that sets MaxOutboundBytes itself
	-- keeps its own value, since it is testing the budget rather than living under
	-- one. Read through the harness escape hatch: @lune/process is unreachable from
	-- a shim-loaded module, and a pcall'd require there would fail silently, which
	-- is how a switch quietly stops switching anything.
	local fragmentAll = __SimHost ~= nil and __SimHost.Env ~= nil and __SimHost.Env.SCRIBE_FRAGMENT_ALL == "1"
	if fragmentAll and options.MaxOutboundBytes == nil then
		options.MaxOutboundBytes = 256
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

	--- Join without asserting success. Returns (player, entry, accessor, reason);
	--- accessor is nil when the load failed (e.g. the profile is session-locked by
	--- another harness sharing this fake).
	---
	--- `timeout` bounds the WaitForData, and exists for specs that assert a load was
	--- REFUSED. A refusal reaches WaitForData through the stored end reason, so under
	--- correct code it returns immediately whatever the timeout is; a load that
	--- instead hangs (the failure mode a spec asserting on `entry == nil` cannot
	--- distinguish from a clean refusal) then answers "timeout" promptly, and the
	--- spec fails on its own assertion rather than on the runner's per-test budget.
	function harness.TryJoin(userId: number?, timeout: number?): (any, any, any, string?)
		local player = FakePlayer.new(userId)
		table.insert(joined, player)
		ctx.Persistence.OnPlayerAdded(player)
		local accessor, reason = ctx.Persistence.WaitForData(player, timeout)
		return player, ctx.Persistence.EntryFor(player), accessor, reason
	end

	--- Drive one frame of Scribe's REAL replication flush loop, the
	--- RunService.PostSimulation handler at src/Server/Replication.luau. Specs used
	--- to hand-call ctx.Replication.FlushEntry, which meant the production loop --
	--- including its iteration over every entry -- executed zero times under the
	--- whole suite. Portable across both runners, but the test has to be on the
	--- SIGNAL'S TYPE, not on whether it has a Fire member: reading an unknown member
	--- off a real RBXScriptSignal RAISES ("Fire is not a valid member of
	--- RBXScriptSignal") rather than returning nil, so probing for `.Fire` is itself
	--- what breaks under Studio. `typeof` answers it without touching the member.
	function harness.Step()
		local signal = RunService.PostSimulation :: any
		if typeof(signal) == "RBXScriptSignal" then
			task.wait() -- real engine: it fires PostSimulation itself, once a frame
		else
			signal:Fire(1 / 60) -- headless shim: a FakeSignal we drive ourselves
		end
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
		if frameType == Wire.Frames.Fragment then
			-- A lone fragment carries no decodable frame, and returning { Type = 11 }
			-- would let `FramesFor(player, Frames.Init)` answer an empty list for a
			-- snapshot that was sent perfectly well. Fail loudly instead.
			error("TestCtx.DecodeFrame: got a Fragment; use FramesFor, which reassembles", 2)
		elseif frameType == Wire.Frames.Init or frameType == Wire.Frames.Diff then
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
		-- Reassembled first: a frame over MaxOutboundBytes reaches the log as several
		-- Fragment frames, and every assertion in the suite is written about logical
		-- frames.
		for _, sent in Reassemble.Logical(transport:FramesFor(player)) do
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
		-- Release the bundle. A harness builds a whole Scribe instance, and a bundle
		-- registers on process globals -- a Health.OnStatusChanged listener and a
		-- RunService.PostSimulation handler -- so without this every harness in a run
		-- left a dead pump on the frame signal, one per make(), driving replication
		-- work for a bundle nothing holds.
		--
		-- AFTER the leave loop, so the release/save path runs against a live bundle.
		-- Measured: swapping the two leaves the whole suite green today, because a
		-- leave still reaches EndSession and the store still writes. Kept in this
		-- order anyway -- releasing players through a bundle that has been stopped is
		-- not something any spec should be relying on, and the day one does, the
		-- failure would look like a persistence bug rather than a harness one.
		--
		-- pcall'd and idempotent, because specs call Cleanup on early-return paths and
		-- again at the end.
		pcall(Data.Stop)
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
