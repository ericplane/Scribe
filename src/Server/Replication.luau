--!strict
-- Replication: per-player dirty op queues flushed once per frame
-- on PostSimulation, client-ready handshake, root visibility filtering, Shared
-- broadcast, and inbound frame dispatch (size caps + pcall'd decode).

local RunService = game:GetService("RunService")

local Internal = script.Parent.Parent.Internal
local Util = require(Internal.Util)
local Wire = require(Internal.Wire)
local Template = require(Internal.Template)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)

local Replication = {}

local HANDSHAKE_TIMEOUT = 10
local MAX_OPS_PER_FRAME = 60000
local REINIT_COOLDOWN = 5 -- seconds between full snapshots for repeated Hellos

local STATUS_TO_ID: { [string]: number } = { Healthy = 0, Degraded = 1, Outage = 2 }

function Replication.new(ctx: any)
	local self = {} :: any
	local compiled: Template.Compiled = ctx.Compiled
	local transport = ctx.Transport
	local options = ctx.Options

	local maxInbound: number = options.MaxInboundBytes or 8192

	-- Op queueing ---------------------------------------------------------------

	-- Push a mutation op into the owner's queue (and the Shared broadcast
	-- queue). ServerOnly paths never enter any queue — absent from the client
	-- packet by construction.
	-- A whole-container Set/Insert can carry statically-declared ServerOnly
	-- descendants inside its table value; strip them before the value reaches
	-- any client queue (the Init snapshot does the same via CloneVisible).
	local function stripServerOnly(op: Wire.Op, schema: Template.SchemaNode?)
		if type(op.Value) ~= "table" or schema == nil then
			return
		end
		local valueNode: Template.SchemaNode? = schema
		if op.Kind == "Insert" then
			valueNode = Template.ChildSchema(schema, 1)
		end
		if valueNode ~= nil then
			op.Value = Template.CloneVisible(valueNode, op.Value)
		end
	end

	function self.PushOp(entry: any, op: Wire.Op, schema: Template.SchemaNode?)
		local visibility = if schema then schema.Visibility else Template.VisibilityOf(compiled, op.Path)
		if visibility == "ServerOnly" then
			return
		end

		stripServerOnly(op, schema)

		Metrics.Add("OpsQueued")
		-- Stamp the coalescing key on every op that may be queued (owner or
		-- Shared), so the flush-time compaction can read it in either queue.
		local pathKey = Util.pathKey(op.Path);
		(op :: any)._pk = pathKey
		if entry.HandshakeReady then
			local queue: { Wire.Op } = entry.Queue
			if op.Kind == "Set" and op.Value ~= nil and type(op.Value) ~= "table" then
				-- Scalar leaf Set: coalesce consecutive writes to the same path
				-- in place (O(1)). Supersession by whole-container writes is
				-- resolved once at flush (compactOps), preserving emission order.
				local existing = entry.QueueIndex[pathKey]
				if
					existing
					and queue[existing]
					and queue[existing].Kind == "Set"
					and (queue[existing] :: any)._pk == pathKey
				then
					queue[existing] = op
					Metrics.Add("OpsCoalesced")
				else
					table.insert(queue, op)
					entry.QueueIndex[pathKey] = #queue
				end
			else
				-- Whole-container writes (table Set, nil Set, Clear) and array
				-- ops append; break scalar coalescing at this path AND every
				-- descendant path. A later scalar Set to a child would otherwise
				-- collapse into a slot that now precedes this whole-container write,
				-- and compactOps would then drop it as superseded even though it
				-- happened after, silently losing the newest value on the client.
				table.insert(queue, op)
				entry.QueueIndex[pathKey] = nil
				local descendantPrefix = pathKey .. "\31"
				local prefixLen = #descendantPrefix
				for k in entry.QueueIndex do
					if string.sub(k, 1, prefixLen) == descendantPrefix then
						entry.QueueIndex[k] = nil
					end
				end
			end
		end
		-- Before the handshake the snapshot supersedes diffs; skip queueing.

		if visibility == "Shared" then
			table.insert(entry.SharedQueue, op)
		end
	end

	local function sendBuffer(entry: any, bytes: buffer)
		local ok, err = pcall(function()
			transport:SendToClient(entry.Player, bytes)
		end)
		if not ok then
			Log.Warn("Transport", "SEND_FAIL", tostring(err), { Player = entry.Player })
		else
			Metrics.Observe("BytesOutPerSend", buffer.len(bytes))
		end
	end

	local function broadcastBuffer(bytes: buffer, exceptEntry: any?)
		if transport.SendToAllClients and exceptEntry == nil then
			local ok, err = pcall(function()
				transport:SendToAllClients(bytes)
			end)
			if not ok then
				Log.Warn("Transport", "SEND_FAIL", tostring(err), {})
			end
			return
		end
		for _, entry in ctx.Persistence.Entries do
			if entry.HandshakeReady and entry ~= exceptEntry then
				sendBuffer(entry, bytes)
			end
		end
	end

	-- Single backward pass that drops every op superseded by a later write,
	-- preserving emission order for the survivors. O(N x depth), run once per flush.
	-- A whole-container Set (table or nil) supersedes ops at its OWN path AND all
	-- descendants (it re-establishes or deletes the whole subtree on replay). A Clear
	-- supersedes only strict DESCENDANTS (the entries it wipes) -- NOT the op at its
	-- own path, because Clear is a client-side no-op on an absent key: dropping the
	-- Set/Insert that created a fresh dynamic key would leave the client without the
	-- key while the server keeps an empty-but-present container.
	local function compactOps(queue: { Wire.Op }): { Wire.Op }
		local supersede: { [string]: boolean } = {} -- own path + descendants (Set table/nil)
		local descendantSupersede: { [string]: boolean } = {} -- descendants only (Clear)
		local reversed: { Wire.Op } = {}
		for i = #queue, 1, -1 do
			local op = queue[i]
			local k = (op :: any)._pk :: string
			local superseded = supersede[k] == true
			if not superseded then
				local pos = string.find(k, "\31", 1, true)
				while pos do
					local ancestor = string.sub(k, 1, pos - 1)
					if supersede[ancestor] or descendantSupersede[ancestor] then
						superseded = true
						break
					end
					pos = string.find(k, "\31", pos + 1, true)
				end
			end
			if not superseded then
				reversed[#reversed + 1] = op
				if op.Kind == "Clear" then
					descendantSupersede[k] = true
				elseif op.Kind == "Set" and (op.Value == nil or type(op.Value) == "table") then
					supersede[k] = true
				end
			end
		end
		local out: { Wire.Op } = table.create(#reversed)
		for i = #reversed, 1, -1 do
			out[#out + 1] = reversed[i]
		end
		return out
	end

	function self.FlushEntry(entry: any)
		local queue: { Wire.Op } = entry.Queue
		if #queue > 0 and entry.HandshakeReady then
			entry.Queue = {}
			entry.QueueIndex = {}
			queue = compactOps(queue)
			local offset = 1
			while offset <= #queue do
				local chunk = table.move(queue, offset, math.min(offset + MAX_OPS_PER_FRAME - 1, #queue), 1, {})
				local ok, bytesOrErr = pcall(Wire.EncodeOpsFrame, Wire.Frames.Diff, compiled, chunk)
				if ok then
					sendBuffer(entry, bytesOrErr)
					Metrics.Add("DiffFlushes")
					Metrics.Add("OpsSent", #chunk)
				else
					Log.Error("Replication", "SERIALIZE_FAIL", tostring(bytesOrErr), { Player = entry.Player })
				end
				offset += MAX_OPS_PER_FRAME
			end
		elseif #queue > 0 then
			entry.Queue = {}
			entry.QueueIndex = {}
		end

		local shared: { Wire.Op } = entry.SharedQueue
		if #shared > 0 then
			entry.SharedQueue = {}
			shared = compactOps(shared)
			local offset = 1
			while offset <= #shared do
				local chunk = table.move(shared, offset, math.min(offset + MAX_OPS_PER_FRAME - 1, #shared), 1, {})
				local ok, bytesOrErr = pcall(Wire.EncodeOpsFrame, Wire.Frames.SharedDiff, compiled, chunk, function(w)
					Wire.F64(w, entry.UserId)
				end)
				if ok then
					broadcastBuffer(bytesOrErr, entry)
				else
					Log.Error("Replication", "SERIALIZE_FAIL", tostring(bytesOrErr), { Player = entry.Player })
				end
				offset += MAX_OPS_PER_FRAME
			end
		end
	end

	RunService.PostSimulation:Connect(function()
		for _, entry in ctx.Persistence.Entries do
			if #entry.Queue > 0 or #entry.SharedQueue > 0 then
				self.FlushEntry(entry)
			end
		end
	end)

	-- Snapshots -------------------------------------------------------------------

	local function ownerSnapshotOps(entry: any): { Wire.Op }
		local ops: { Wire.Op } = {}
		local rootChildren = compiled.Root.Children :: { [string]: Template.SchemaNode }
		for _, rootKey in compiled.RootOrder do
			local rootSchema = rootChildren[rootKey]
			local store = if rootSchema.Visibility == "Session" then entry.SessionStore else entry.LiveData
			local value = if store then store[rootKey] else nil
			if value ~= nil then
				-- CloneVisible strips ServerOnly subtrees and returns nil for
				-- roots with nothing visible (mixed-visibility roots like
				-- _Scribe keep their Replicated subkeys).
				local visible = Template.CloneVisible(rootSchema, value)
				if visible ~= nil then
					table.insert(ops, { Kind = "Set", Path = { rootKey }, Value = visible })
				end
			end
		end
		return ops
	end

	local function sharedSnapshotOps(entry: any): { Wire.Op }
		local ops: { Wire.Op } = {}
		local rootChildren = compiled.Root.Children :: { [string]: Template.SchemaNode }
		for _, rootKey in compiled.RootOrder do
			local rootSchema = rootChildren[rootKey]
			if rootSchema.Visibility == "Shared" and entry.LiveData then
				local value = entry.LiveData[rootKey]
				if value ~= nil then
					-- CloneVisible strips ServerOnly subtrees nested under the
					-- Shared root; a plain deepClone would broadcast them.
					local visible = Template.CloneVisible(rootSchema, value)
					if visible ~= nil then
						table.insert(ops, { Kind = "Set", Path = { rootKey }, Value = visible })
					end
				end
			end
		end
		return ops
	end

	local function sendStatus(entry: any?)
		local w = Wire.NewWriter(4)
		Wire.U8(w, Wire.Frames.Status)
		Wire.U8(w, STATUS_TO_ID[Health.GetStatus()] or 0)
		local bytes = Wire.Finish(w)
		if entry then
			sendBuffer(entry, bytes)
		else
			broadcastBuffer(bytes)
		end
	end

	local function sendInit(entry: any)
		local ops = ownerSnapshotOps(entry)
		local ok, bytesOrErr = pcall(Wire.EncodeOpsFrame, Wire.Frames.Init, compiled, ops)
		if not ok then
			-- One un-encodable root must never permanently brick the client
			-- (which would block every client API on waitForLoaded). Drop the
			-- offending roots, surface them, and send the encodable remainder so
			-- the handshake still completes.
			Log.Error("Replication", "SERIALIZE_FAIL", tostring(bytesOrErr), { Player = entry.Player })
			local safeOps = {}
			for _, op in ops do
				local encodable = pcall(Wire.EncodeOpsFrame, Wire.Frames.Init, compiled, { op })
				if encodable then
					table.insert(safeOps, op)
				else
					Metrics.Add("SnapshotRootDropped")
					Log.Error("Replication", "SNAPSHOT_ROOT_DROPPED", "root omitted from Init (unserializable)", {
						Player = entry.Player,
						Root = op.Path[1],
					})
					if ctx.Signals and ctx.Signals.OnAnomaly then
						ctx.Signals.OnAnomaly:Fire({
							Player = entry.Player,
							Path = op.Path,
							Value = nil,
							Reason = "UnserializableSnapshotRoot",
						})
					end
				end
			end
			local okSafe, safeBytes = pcall(Wire.EncodeOpsFrame, Wire.Frames.Init, compiled, safeOps)
			if not okSafe then
				-- Should be unreachable (each op individually encoded); fall back
				-- to an empty Init rather than leaving the client unloaded.
				safeBytes = Wire.EncodeOpsFrame(Wire.Frames.Init, compiled, {})
			end
			bytesOrErr = safeBytes
		end
		-- Anything queued before Init is superseded by the snapshot.
		entry.Queue = {}
		entry.QueueIndex = {}
		entry.HandshakeReady = true
		entry.LastInitAt = os.clock()
		sendBuffer(entry, bytesOrErr)
		sendStatus(entry)
		if ctx.Leaderboards then
			ctx.Leaderboards.OnClientReady(entry)
		end

		-- Existing players' Shared roots for the new client.
		for _, other in ctx.Persistence.Entries do
			if other ~= entry and other.State == "Ready" then
				local sharedOps = sharedSnapshotOps(other)
				if #sharedOps > 0 then
					local okShared, sharedBytes = pcall(
						Wire.EncodeOpsFrame,
						Wire.Frames.SharedInit,
						compiled,
						sharedOps,
						function(w)
							Wire.F64(w, other.UserId)
						end
					)
					if okShared then
						sendBuffer(entry, sharedBytes)
					end
				end
			end
		end
		Metrics.Add("Handshakes")
		Log.Debug("Replication", "INIT_SENT", "initial snapshot sent", { Player = entry.Player })
	end

	-- Handshake ---------------------------------------------------------------

	local function onHello(entry: any, reader: Wire.Reader)
		local schemaHash = Wire.RU32(reader)
		-- The client sends its wire PROTOCOL_VERSION after the hash. A mismatch means
		-- the binary layout itself differs (not just the template), so decoding would
		-- be unsafe -- fail closed (no HelloReceived, no Init), unlike the hash check
		-- below which the value-mode prefix keeps decode-safe.
		local protocolVersion = Wire.RU8(reader)
		if protocolVersion ~= Wire.PROTOCOL_VERSION then
			Log.Warn("Replication", "PROTOCOL_MISMATCH", "client wire protocol version differs from the server", {
				Player = entry.Player,
			})
			return
		end
		if schemaHash ~= compiled.Hash % 4294967296 then
			Log.Warn("Replication", "SCHEMA_MISMATCH", "client derived a different schema than the server", {
				Player = entry.Player,
			})
			-- Proceed anyway: the value-mode prefix keeps decoding safe, but
			-- this indicates a template drift bug worth surfacing.
		end
		entry.HelloReceived = true
		if entry.State == "Ready" then
			-- A repeated Hello re-Inits (client-driven resync), but a full
			-- snapshot encode is expensive — throttle floods.
			if entry.HandshakeReady and os.clock() - entry.LastInitAt < REINIT_COOLDOWN then
				Metrics.Add("ReInitThrottled")
				return
			end
			sendInit(entry)
		end
	end

	function self.OnEntryReady(entry: any)
		if entry.HelloReceived and not entry.HandshakeReady then
			sendInit(entry)
		end
		-- Broadcast this player's Shared snapshot to everyone else.
		local sharedOps = sharedSnapshotOps(entry)
		if #sharedOps > 0 then
			local ok, bytes = pcall(Wire.EncodeOpsFrame, Wire.Frames.SharedInit, compiled, sharedOps, function(w)
				Wire.F64(w, entry.UserId)
			end)
			if ok then
				broadcastBuffer(bytes, entry)
			end
		end
		task.delay(HANDSHAKE_TIMEOUT, function()
			if not entry.TornDown and not entry.HandshakeReady then
				Log.Warn(
					"Replication",
					"CLIENT_HANDSHAKE_TIMEOUT",
					"client never sent Hello, so replication never started; require the Scribe bundle on the client (a LocalScript), or check a custom client transport adapter",
					{
						Player = entry.Player,
					}
				)
			end
		end)
	end

	function self.OnEntryRemoved(entry: any)
		entry.HandshakeReady = false
		local w = Wire.NewWriter(16)
		Wire.U8(w, Wire.Frames.SharedGone)
		Wire.F64(w, entry.UserId)
		broadcastBuffer(Wire.Finish(w), entry)
	end

	function self.BroadcastStatus()
		sendStatus(nil)
	end

	function self.SendTo(entry: any, bytes: buffer)
		sendBuffer(entry, bytes)
	end

	function self.Broadcast(bytes: buffer)
		broadcastBuffer(bytes)
	end

	Health.OnStatusChanged:Connect(function()
		self.BroadcastStatus()
	end)

	-- Inbound dispatch -------------------------------------------------

	transport:ListenServer(function(player: Player, bytes: buffer)
		local entry = ctx.Persistence.Entries[player]
		if not entry then
			return
		end
		if buffer.len(bytes) > maxInbound then
			Metrics.Add("InboundOversize")
			Log.Warn("Transport", "INBOUND_OVERSIZE", `dropped oversized inbound frame ({buffer.len(bytes)} bytes)`, {
				Player = player,
			})
			return
		end
		local ok, err = pcall(function()
			local reader = Wire.NewReader(bytes)
			local frameType = Wire.RU8(reader)
			if frameType == Wire.Frames.Hello then
				onHello(entry, reader)
			elseif frameType == Wire.Frames.Command then
				ctx.Commands.HandleFrame(entry, reader)
			else
				error(`unexpected inbound frame type {frameType}`)
			end
		end)
		if not ok then
			entry.MalformedCount += 1
			Metrics.Add("MalformedFrames")
			Log.Warn("Transport", "MALFORMED_FRAME", tostring(err), {
				Player = player,
				Count = entry.MalformedCount,
			})
			ctx.Signals.OnAnomaly:Fire({
				Player = player,
				Path = {},
				Value = nil,
				Reason = "MalformedFrame",
			})
		end
	end)

	return self
end

return Replication
