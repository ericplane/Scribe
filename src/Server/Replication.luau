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
local Clock = require(Internal.Clock)
local Profile = require(Internal.Profile)

local Replication = {}

local HANDSHAKE_TIMEOUT = 10
local MAX_OPS_PER_FRAME = 60000
local REINIT_COOLDOWN = 5 -- seconds between full snapshots for repeated Hellos
local MALFORMED_LOG_INTERVAL = 1 -- seconds; throttle malformed-frame logs/anomalies per player
local MALFORMED_MAX = 32 -- after this many malformed frames, ignore all further inbound from the player
-- Its own budget rather than counting toward MALFORMED_MAX: a malformed frame
-- decoded and failed, an oversize frame was never read, and a shared counter would
-- let either mask the other.
local OVERSIZE_MAX = 32

local STATUS_TO_ID: { [string]: number } = { Healthy = 0, Degraded = 1, Outage = 2 }

-- Inverted once at load, so the oversize warning can name the kind of frame.
local FRAME_NAMES: { [number]: string } = {}
for name, id in Wire.Frames :: { [string]: number } do
	FRAME_NAMES[id] = name
end

function Replication.new(ctx: any)
	local self = {} :: any
	local compiled: Template.Compiled = ctx.Compiled
	local transport = ctx.Transport
	local options = ctx.Options

	local maxInbound: number = options.MaxInboundBytes or 8192
	-- Derived from the byte cap so the two stay in proportion: one inbound frame may
	-- retain at most 16x its own bytes. 16 admits the densest legitimate shape (an
	-- array of two-byte strings, 14.5x) while refusing the hostile ones (arrays of
	-- booleans or of empty tables both cost 32x). See Wire.NewReader.
	local maxInboundRetained: number = options.MaxInboundRetainedBytes or math.max(4096, maxInbound * 16)
	local inboundFrameRate: number = ctx.InboundFrameRate

	-- The largest buffer Scribe hands a transport in one call; anything above it is
	-- fragmented (Wire.Fragment) and reassembled by the client. A ceiling is needed
	-- because an Init snapshot is one op per root and MAX_OPS_PER_FRAME cannot divide
	-- a single op. 65536 sits far below any platform payload limit and leaves ordinary
	-- diffs unsplit. A smaller transport MaxFrameBytes wins: only the adapter knows
	-- its own framing overhead.
	local declaredMax: number? = (transport :: any).MaxFrameBytes
	local maxOutbound: number = options.MaxOutboundBytes or 65536
	if type(declaredMax) == "number" then
		maxOutbound = math.min(maxOutbound, declaredMax)
	end
	-- At maxOutbound = 64 the u16 fragment count caps a logical frame at 3.7 MB,
	-- which a real profile can reach. Refuse it at construction, where it is a typo.
	if maxOutbound < 256 then
		error(`Scribe: MaxOutboundBytes must be at least 256 (got {maxOutbound})`, 0)
	end
	-- Identifies one logical fragmented frame so the client can tell two apart. Wraps
	-- at 65536; a collision needs 65535 intervening frames mid-reassembly.
	local fragmentSeq = 0

	-- One log per server, the first time a frame needs more fragments than this.
	-- Measures the wire, unlike the profile-size warning: a Session root is absent
	-- from LiveData but still rides in Init. Latched, being a template property.
	local OVERSIZE_FRAGMENTS = 16
	local warnedOversize = false

	-- Same token-bucket shape as the command limiter, on its own per-entry clock:
	-- refills at `inboundFrameRate` per second and caps there.
	local function takeFrameToken(entry: any): boolean
		local now = Clock.Monotonic()
		local elapsed = now - entry.FrameLast
		entry.FrameLast = now
		entry.FrameTokens = math.min(inboundFrameRate, entry.FrameTokens + elapsed * inboundFrameRate)
		if entry.FrameTokens >= 1 then
			entry.FrameTokens -= 1
			return true
		end
		return false
	end

	-- Op queueing ---------------------------------------------------------------

	-- A whole-container Set/Insert can carry statically-declared ServerOnly
	-- descendants inside its table value; strip them before the value reaches any
	-- client queue (the Init snapshot does the same via CloneVisible).
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
		-- Stamped on every op that may be queued, owner or Shared, so flush-time
		-- compaction can read it in either queue.
		local pathKey = Util.pathKey(op.Path);
		(op :: any)._pk = pathKey
		if entry.QueueOpen then
			local queue: { Wire.Op } = entry.Queue
			if op.Kind == "Set" and op.Value ~= nil and type(op.Value) ~= "table" then
				-- Scalar leaf Set: coalesce consecutive writes to the same path in place.
				-- Supersession by whole-container writes is resolved at flush (compactOps).
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
				-- Whole-container writes (table Set, nil Set, Clear) and array ops append,
				-- and break scalar coalescing here and below: a later child Set would
				-- otherwise collapse into a preceding slot and be dropped as superseded.
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
		-- Before the snapshot is taken there is nothing to diff against: the snapshot
		-- about to be cloned carries this value, so queueing it would send it twice.

		if visibility == "Shared" then
			table.insert(entry.SharedQueue, op)
		end
	end

	-- Ranks a snapshot's roots by the bytes they contributed, for the oversize
	-- warning. Scribe's own two roots are skipped: tens of bytes, never the answer.
	-- "not persisted" means ProfileSize and the DataStore ceiling say nothing about
	-- that root, not that it is unbounded.
	local function describeRoots(ops: { Wire.Op }?, spans: { number }?): string
		if ops == nil or spans == nil then
			return ""
		end
		local ranked: { { Key: string, Bytes: number } } = {}
		for i, op in ops do
			local key = op.Path[1]
			local span = spans[i]
			if
				type(key) == "string"
				and span ~= nil
				and key ~= Template.RESERVED_ROOT
				and key ~= Template.SESSION_ROOT
			then
				table.insert(ranked, { Key = key, Bytes = span })
			end
		end
		if #ranked == 0 then
			return ""
		end
		table.sort(ranked, function(a: { Key: string, Bytes: number }, b: { Key: string, Bytes: number })
			return a.Bytes > b.Bytes
		end)
		local rootChildren = compiled.Root.Children :: { [string]: Template.SchemaNode }
		local out: { string } = {}
		for i = 1, math.min(3, #ranked) do
			local row = ranked[i]
			local node = rootChildren[row.Key]
			local suffix = if node ~= nil and node.Persist == false then " (not persisted)" else ""
			table.insert(out, `{row.Key}={row.Bytes}B{suffix}`)
		end
		return table.concat(out, ", ")
	end

	-- One delivery to one client, with no accounting of its own: the callers count
	-- once per frame. pcall takes the function and its arguments rather than a
	-- closure because on the Shared fanout that is N^2 allocations a frame.
	local function deliver(entry: any, bytes: buffer): boolean
		local ok, err = pcall(transport.SendToClient, transport, entry.Player, bytes)
		if not ok then
			Log.Warn("Transport", "SEND_FAIL", tostring(err), { Player = entry.Player })
			return false
		end
		return true
	end

	-- Defined below, but needed by markResync's driver in the flush loop above it.
	local sendInit: (entry: any) -> ()

	-- A frame did not reach the transport, so this client's mirror is now a value the
	-- server never had: Insert, Remove and Clear are not idempotent, so every later
	-- op lands on the wrong base, and a loaded client never Hellos again. Repair is a
	-- fresh Init, not a replay: re-broadcasting a SharedDiff would double-apply an
	-- Insert on the other recipients.
	local function markResync(entry: any, what: string)
		if entry.ResyncPending then
			return
		end
		entry.ResyncPending = true
		-- Both flags, and the queue with them: HandshakeReady false stops broadcasts to
		-- a client whose mirror is wrong, and clearing QueueOpen keeps out the
		-- (ready, not open) state in which PushOp silently discards every owner op.
		entry.HandshakeReady = false
		entry.QueueOpen = false
		entry.Queue = {}
		entry.QueueIndex = {}
		Metrics.Add("MirrorResyncs")
		Log.Warn(
			"Replication",
			"MIRROR_RESYNC",
			`a {what} frame could not be delivered, so this client's mirror is stale; re-sending the whole snapshot`,
			{ Player = entry.Player }
		)
	end

	-- One frame, to one client. Returns whether the whole frame reached the transport,
	-- which sendInit needs: a snapshot that did not land must not mark the client
	-- ready. Fragmentation happens here rather than in `deliver` so a broadcast splits
	-- once. `snapshotOps` and `snapshotSpans` are passed only by sendInit.
	local function sendBuffer(entry: any, bytes: buffer, snapshotOps: { Wire.Op }?, snapshotSpans: { number }?): boolean
		fragmentSeq = (fragmentSeq + 1) % 65536
		local parts = 0
		local whole = Wire.Fragment(bytes, maxOutbound, fragmentSeq, function(part)
			parts += 1
			return deliver(entry, part)
		end)
		if whole == nil then
			if not deliver(entry, bytes) then
				return false
			end
			Metrics.Add("FramesSent")
			Metrics.Observe("BytesOutPerSend", buffer.len(bytes))
			return true
		end
		if not whole then
			-- Stop at the first refusal rather than pushing the rest: a hole in a stream
			-- the receiver believes is contiguous could splice two frames together. A
			-- partial stays a prefix, which the next frame's index 0 discards cleanly.
			Metrics.Add("FragmentedSendFailed")
			return false
		end
		if parts > OVERSIZE_FRAGMENTS and not warnedOversize then
			warnedOversize = true
			local frameName = FRAME_NAMES[buffer.readu8(bytes, 0)] or "unknown"
			local roots = describeRoots(snapshotOps, snapshotSpans)
			Log.Warn(
				"Replication",
				"OUTBOUND_OVERSIZE",
				`a single {frameName} frame needed {parts} fragments to send; it is delivered, but the profile or `
					.. "diff behind it has grown well past MaxOutboundBytes and every join pays for it"
					.. (if roots ~= "" then `; largest roots: {roots}` else ""),
				{
					Player = entry.Player,
					Bytes = buffer.len(bytes),
					Fragments = parts,
					Frame = frameName,
					Roots = roots,
				}
			)
		end
		Metrics.Add("FramesSent")
		Metrics.Add("FramesFragmented")
		Metrics.Add("FragmentsSent", parts)
		-- The logical frame's size, once. BytesOutPerSend means bytes per outbound
		-- frame, so sampling the fragments would describe the budget, not the frames.
		Metrics.Observe("BytesOutPerSend", buffer.len(bytes))
		return true
	end

	-- One frame, to every ready client except `exceptEntry`. Returns the entries the
	-- frame did not reach, or nil when every recipient got it; the only place that
	-- knows which clients were missed.
	--
	-- BytesOutPerSend is observed once here, not once per recipient: per-recipient
	-- sampling cost O(N^2) reservoir writes a frame and skewed the distribution toward
	-- the fanout. FramesSent still counts every hand-off to the transport.
	local function broadcastBuffer(bytes: buffer, exceptEntry: any?): { any }?
		-- Split once, before the recipient loop and before the fast-path branch: the
		-- split depends only on the buffer, and the fast path never reaches `deliver`,
		-- so a fragmenter placed there would let every broadcast out unsplit.
		fragmentSeq = (fragmentSeq + 1) % 65536
		local parts: { buffer } = {}
		local split = Wire.Fragment(bytes, maxOutbound, fragmentSeq, function(part)
			parts[#parts + 1] = part
			return true
		end) ~= nil

		if transport.SendToAllClients and exceptEntry == nil then
			-- No per-recipient attribution on this path: one raise means the frame
			-- reached NOBODY, so every ready client is a missed recipient.
			local function everyReady(): { any }
				local all: { any } = {}
				for _, entry in ctx.Persistence.Entries do
					if entry.HandshakeReady then
						all[#all + 1] = entry
					end
				end
				return all
			end
			if not split then
				local ok, err = pcall(transport.SendToAllClients, transport, bytes)
				if not ok then
					Log.Warn("Transport", "SEND_FAIL", tostring(err), {})
					return everyReady()
				end
			else
				for _, part in parts do
					local ok, err = pcall(transport.SendToAllClients, transport, part)
					if not ok then
						Log.Warn("Transport", "SEND_FAIL", tostring(err), {})
						Metrics.Add("FragmentedSendFailed")
						return everyReady()
					end
				end
				Metrics.Add("FramesFragmented")
				Metrics.Add("FragmentsSent", #parts)
			end
			Metrics.Add("FramesSent")
			Metrics.Observe("BytesOutPerSend", buffer.len(bytes))
			return nil
		end

		local sent = 0
		local missed: { any }? = nil
		for _, entry in ctx.Persistence.Entries do
			if entry.HandshakeReady and entry ~= exceptEntry then
				local complete = true
				if not split then
					complete = deliver(entry, bytes)
				else
					for _, part in parts do
						if not deliver(entry, part) then
							complete = false
							break
						end
					end
				end
				if complete then
					sent += 1
				else
					-- Allocated only on the failing path, so the ordinary fanout costs
					-- nothing extra.
					local list: { any } = missed or {}
					list[#list + 1] = entry
					missed = list
				end
			end
		end
		if sent > 0 then
			-- Accumulated and added once, never per recipient: a Metrics.Add inside
			-- this loop costs O(N^2) hash writes a frame.
			Metrics.Add("FramesSent", sent)
			if split then
				Metrics.Add("FramesFragmented")
				Metrics.Add("FragmentsSent", #parts * sent)
			end
			Metrics.Observe("BytesOutPerSend", buffer.len(bytes))
		end
		return missed
	end

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
				elseif op.Kind == "Insert" or op.Kind == "Remove" then
					-- Index-shift barrier: an Insert/Remove rebinds which element every
					-- numeric path under this container denotes, so a later table-Set at
					-- arr[i] does not supersede an earlier op targeting the element that
					-- occupied i before the shift. Drop the descendant marks under it.
					local prefix = k .. "\31"
					local prefixLen = #prefix
					for marked in supersede do
						if string.sub(marked, 1, prefixLen) == prefix then
							supersede[marked] = nil
						end
					end
					for marked in descendantSupersede do
						if string.sub(marked, 1, prefixLen) == prefix then
							descendantSupersede[marked] = nil
						end
					end
				end
			end
		end
		local out = table.create(#reversed) :: { Wire.Op }
		for i = #reversed, 1, -1 do
			out[#out + 1] = reversed[i]
		end
		return out
	end

	-- Flush an entry's queued Shared ops as SharedDiff frames to every other ready
	-- client. Extracted so sendInit can drain the queue before a new client snapshots
	-- that player; otherwise the op lands twice, double-applying Insert/Remove/Clear.
	local function flushSharedQueue(entry: any)
		local shared: { Wire.Op } = entry.SharedQueue
		if #shared == 0 then
			return
		end
		entry.SharedQueue = {}
		shared = compactOps(shared)
		local offset = 1
		while offset <= #shared do
			local chunk = table.move(shared, offset, math.min(offset + MAX_OPS_PER_FRAME - 1, #shared), 1, {})
			local ok, bytesOrErr = pcall(Wire.EncodeOpsFrame, Wire.Frames.SharedDiff, compiled, chunk, function(w)
				Wire.F64(w, entry.UserId)
			end)
			if ok then
				-- A SharedDiff cannot be replayed to the client that missed it: the other
				-- recipients already applied it. It gets a whole new snapshot instead.
				local missed = broadcastBuffer(bytesOrErr, entry)
				if missed ~= nil then
					for _, other in missed do
						markResync(other, "SharedDiff")
					end
				end
			else
				Log.Error("Replication", "SERIALIZE_FAIL", tostring(bytesOrErr), { Player = entry.Player })
			end
			offset += MAX_OPS_PER_FRAME
		end
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
					if not sendBuffer(entry, bytesOrErr) then
						-- The queue was replaced at the top of this function, so these ops
						-- exist nowhere else and a discarded refusal is permanent divergence.
						-- Later chunks depend on this one, so stop the loop.
						markResync(entry, "Diff")
						break
					end
					-- Counted only for a frame that actually left, so OpsSent agrees
					-- with FramesSent.
					Metrics.Add("DiffFlushes")
					Metrics.Add("OpsSent", #chunk)
				else
					Log.Error("Replication", "SERIALIZE_FAIL", tostring(bytesOrErr), { Player = entry.Player })
				end
				offset += MAX_OPS_PER_FRAME
			end
		elseif #queue > 0 and not entry.QueueOpen then
			-- No snapshot has been taken, so whatever is queued will be in the snapshot
			-- when one is. Must NOT fire while a snapshot is in flight: those ops are
			-- exactly the ones the snapshot cannot carry.
			entry.Queue = {}
			entry.QueueIndex = {}
		end

		flushSharedQueue(entry)
	end

	local connections: { any } = {}
	-- Every entry with queued work flushes every frame, with deliberately no per-frame
	-- budget: a budget needs a round-robin cursor over an ordered entry list, and
	-- Entries is keyed by Player Instance, where next(Entries, lastPlayer) raises once
	-- that player has left and a rehash on join silently skips entries. The
	-- superlinear path is the Shared fanout, which a budget does not touch.
	--- One frame's flush. Extracted so the profiler has something to name and so the
	--- frame cost can be timed around it.
	local function flushFrame(): (number, number)
		local flushed = 0
		local queued = 0
		for _, entry in ctx.Persistence.Entries do
			-- Repair before flushing: a resync re-snapshots live state, so any op that
			-- would have flushed this frame is already in it. Throttled on the previous
			-- attempt, not on LastInitAt, whose clock starts at the join: gating on that
			-- would leave a client that lost a frame just after its handshake stale.
			if entry.ResyncPending and entry.State == "Ready" and not entry.TornDown then
				local now = Clock.Monotonic()
				if now - (entry.LastResyncAt or -math.huge) >= REINIT_COOLDOWN then
					entry.LastResyncAt = now
					entry.ResyncPending = false
					-- pcall for the reason onHello gives: a throw escaping here would take
					-- down the flush loop for every other player.
					local okInit, initErr = pcall(sendInit, entry)
					if not okInit then
						Log.Error("Replication", "INIT_SEND_FAIL", tostring(initErr), { Player = entry.Player })
						Metrics.Add("InitSendFailed")
						entry.ResyncPending = true
					end
				end
			end
			-- Counted before the flush, because FlushEntry replaces both queues. Ops
			-- pending, not ops sent: compaction shrinks it on the way to the wire.
			local pending = #entry.Queue + #entry.SharedQueue
			if pending > 0 then
				flushed += 1
				queued += pending
				self.FlushEntry(entry)
			end
		end
		return flushed, queued
	end

	connections[#connections + 1] = RunService.PostSimulation:Connect(function()
		-- No memory category here: this body runs on a thread the engine may recycle,
		-- so the tag would outlive the call and stain whatever ran next on it.
		local startedAt = Clock.Monotonic()
		-- SyncSpan, and flushFrame is synchronous: it encodes and fires, and waits on
		-- nothing. That is the precondition, not an incidental property.
		local flushed, queued = Profile.SyncSpan("Scribe.Flush", flushFrame)
		-- Nothing is recorded for an idle frame: a distribution padded with zeroes
		-- would drag every percentile down and hide the busy frames.
		if flushed > 0 then
			Metrics.Observe("FlushEntriesPerFrame", flushed)
			Metrics.Observe("FlushQueuedPerFrame", queued)
			-- The frame cost itself, in seconds; the counts above say only how much work.
			Metrics.Observe("FlushDuration", Clock.Monotonic() - startedAt)
		end
	end)

	-- Snapshots -------------------------------------------------------------------

	local function ownerSnapshotOps(entry: any): { Wire.Op }
		local ops: { Wire.Op } = {}
		local rootChildren = compiled.Root.Children :: { [string]: Template.SchemaNode }
		for _, rootKey in compiled.RootOrder do
			local rootSchema = rootChildren[rootKey]
			local store = if not rootSchema.Persist then entry.SessionStore else entry.LiveData
			local value = if store then store[rootKey] else nil
			if value ~= nil then
				-- CloneVisible strips ServerOnly subtrees and returns nil for roots with
				-- nothing visible (mixed roots like _Scribe keep their Replicated subkeys).
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
			-- Same store choice as ownerSnapshotOps: a Shared root that is also Session
			-- lives in the session store, so reading LiveData broadcasts its default.
			local store = if not rootSchema.Persist then entry.SessionStore else entry.LiveData
			if rootSchema.Visibility == "Shared" and store then
				local value = store[rootKey]
				if value ~= nil then
					-- CloneVisible strips ServerOnly subtrees nested under the Shared root;
					-- a plain deepClone would broadcast them.
					local visible = Template.CloneVisible(rootSchema, value)
					if visible ~= nil then
						table.insert(ops, { Kind = "Set", Path = { rootKey }, Value = visible })
					end
				end
			end
		end
		return ops
	end

	--- Returns whether a unicast status reached the client; always true for the
	--- broadcast form, which has no single recipient to answer for.
	local function sendStatus(entry: any?): boolean
		local w = Wire.NewWriter(4)
		Wire.U8(w, Wire.Frames.Status)
		Wire.U8(w, STATUS_TO_ID[Health.GetStatus()] or 0)
		local bytes = Wire.Finish(w)
		if entry then
			return sendBuffer(entry, bytes)
		end
		-- A missed broadcast Status is not mirror state: the next Health transition
		-- rebroadcasts, and a resync re-sends it as part of the handshake.
		broadcastBuffer(bytes)
		return true
	end

	-- Size of the most recently encoded Init frame, across all players.
	local lastInitBytes: number? = nil

	function sendInit(entry: any)
		-- Open the queue in the same breath as taking the snapshot, with no yield
		-- between them, so every write from here on is either in this clone or in the
		-- queue behind it. The clear drops what the snapshot supersedes.
		entry.Queue = {}
		entry.QueueIndex = {}
		entry.QueueOpen = true
		-- Stamped at the start of the snapshot: measuring from completion would let a
		-- slow encode widen its own cooldown.
		entry.LastInitAt = Clock.Monotonic()
		local ops = ownerSnapshotOps(entry)
		-- Per-root byte spans, filled by the encode, so the oversize warning can name
		-- what is large. `shippedOps` is what the delivered frame holds, not `ops`.
		local spans: { number } = {}
		local shippedOps: { Wire.Op } = ops
		local ok, bytesOrErr =
			pcall(Wire.EncodeOpsFrame, Wire.Frames.Init, compiled, ops, nil, spans, entry.InitSizeHint or lastInitBytes)
		if not ok then
			-- One un-encodable root must never brick the client, which would block every
			-- client API on waitForLoaded. Drop it, surface it, and send the remainder.
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
			-- A fresh spans table, and shippedOps with it: attributing the sent frame
			-- against the failed one's ops would name roots this client never received.
			spans = {}
			shippedOps = safeOps
			local okSafe, safeBytes = pcall(Wire.EncodeOpsFrame, Wire.Frames.Init, compiled, safeOps, nil, spans)
			if not okSafe then
				-- Should be unreachable (each op individually encoded); fall back
				-- to an empty Init rather than leaving the client unloaded.
				spans = {}
				shippedOps = {}
				safeBytes = Wire.EncodeOpsFrame(Wire.Frames.Init, compiled, {})
			end
			bytesOrErr = safeBytes
		end
		-- Drain every other ready player's pending Shared ops before this client becomes
		-- ready and snapshots them below: a queued op is already in other.LiveData, so it
		-- lands in the snapshot and would also be re-broadcast on the next flush,
		-- double-applying Insert/Remove/Clear. Gated on HasShared, which without a Shared
		-- root would walk every entry to find nothing.
		if compiled.HasShared then
			for _, other in ctx.Persistence.Entries do
				if other ~= entry and other.State == "Ready" and #other.SharedQueue > 0 then
					flushSharedQueue(other)
				end
			end
		end

		-- What this handshake costs the client in bytes, summed across every frame it
		-- takes, not just the Init: the SharedInit fan-out that follows can dwarf it.
		local joinBytes = buffer.len(bytesOrErr :: buffer)
		-- Seed the next Init's writer, this player's and the next joiner's. The last
		-- size, not a running maximum: one whale profile would permanently seed every
		-- later joiner's writer at the whale's size. Kept per entry and per context: the
		-- entry's own last Init is the better estimate for a re-init, the context's the
		-- only one a first join has.
		entry.InitSizeHint = joinBytes
		lastInitBytes = joinBytes
		if not sendBuffer(entry, bytesOrErr, shippedOps, spans) then
			-- The snapshot never reached the transport, so this client has no mirror for
			-- anything that follows. Leaving HandshakeReady false keeps that recoverable:
			-- the client's Hello retry asks again, and the handshake alarm still fires.
			Metrics.Add("InitSendFailed")
			Log.Error("Replication", "INIT_SEND_FAIL", "the initial snapshot could not be delivered", {
				Player = entry.Player,
				Bytes = buffer.len(bytesOrErr :: buffer),
			})
			-- Un-take the snapshot. FlushEntry flushes when HandshakeReady and clears
			-- when not QueueOpen, so QueueOpen true with HandshakeReady false matches
			-- neither branch and the queue would grow unbounded.
			entry.Queue = {}
			entry.QueueIndex = {}
			entry.QueueOpen = false
			-- On a re-Init these matter as much as the clear above: HandshakeReady is still
			-- true from the first snapshot, and (ready, not open) is the state in which
			-- PushOp silently discards every owner op forever. ResyncPending asks again,
			-- since a loaded client has no Hello left to send.
			entry.HandshakeReady = false
			entry.ResyncPending = true
			return
		end
		-- Only now: a client marked ready before its snapshot is on the wire can be
		-- handed a diff it has no mirror to apply to. broadcastBuffer skips unready
		-- entries, which is also what kept the Shared drain above safe.
		entry.HandshakeReady = true
		-- The snapshot landed but the handshake is not finished: a Status or SharedInit
		-- that does not arrive leaves this client correct about itself and blind to
		-- everyone else. Ask for the whole handshake again.
		if not sendStatus(entry) then
			entry.ResyncPending = true
		end
		if ctx.Leaderboards then
			ctx.Leaderboards.OnClientReady(entry)
		end

		-- Existing players' Shared roots for the new client. Gated on HasShared:
		-- without it this walks all N entries per join purely to send nothing.
		if compiled.HasShared then
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
							if sendBuffer(entry, sharedBytes) then
								joinBytes += buffer.len(sharedBytes)
							else
								-- A joiner that misses another player's SharedInit has no
								-- mirror of them for the rest of the session.
								entry.ResyncPending = true
							end
						end
					end
				end
			end
		end
		Metrics.Add("Handshakes")
		-- Past the early return above, so a snapshot that never reached the transport
		-- is not sampled: JoinBytes means what a completed handshake cost.
		Metrics.Observe("JoinBytes", joinBytes)
		Log.Debug("Replication", "INIT_SENT", "initial snapshot sent", { Player = entry.Player })
	end

	-- Handshake ---------------------------------------------------------------

	local function onHello(entry: any, reader: Wire.Reader)
		local schemaHash = Wire.RU32(reader)
		-- The client sends its wire PROTOCOL_VERSION after the hash. A mismatch means
		-- the binary layout differs, not just the template, so decoding is unsafe: fail
		-- closed, unlike the hash check below which the value-mode prefix keeps safe.
		local protocolVersion = Wire.RU8(reader)
		if protocolVersion ~= Wire.PROTOCOL_VERSION then
			-- Metered as well as logged, so every refusal is countable.
			Metrics.Add("ProtocolMismatch")
			Log.Warn("Replication", "PROTOCOL_MISMATCH", "client wire protocol version differs from the server", {
				Player = entry.Player,
			})
			return
		end
		if schemaHash ~= compiled.Hash % 4294967296 then
			-- Fail closed. Paths decode from the receiver's own compiled.ById, so a field
			-- id shared by two drifted templates maps to a different path on each side and
			-- a server op lands on the wrong client key. The value-mode prefix keeps value
			-- decoding safe, not path remapping.
			Metrics.Add("SchemaMismatch")
			Log.Warn(
				"Replication",
				"SCHEMA_MISMATCH",
				"client derived a different schema than the server; refusing to replicate (template drift)",
				{ Player = entry.Player }
			)
			return
		end
		entry.HelloReceived = true
		if entry.State == "Ready" then
			-- A repeated Hello re-Inits (client-driven resync), but a full snapshot
			-- encode is expensive, so throttle floods.
			if entry.QueueOpen and Clock.Monotonic() - entry.LastInitAt < REINIT_COOLDOWN then
				Metrics.Add("ReInitThrottled")
				return
			end
			-- onHello runs inside the inbound pcall, whose failure branch charges the
			-- client's malformed budget and blocks its session after 32 strikes. Every
			-- throw sendInit can produce is a server fault, so an escaping one bans a
			-- player for a bug they did not cause.
			local okInit, initErr = pcall(sendInit, entry)
			if not okInit then
				Log.Error("Replication", "INIT_SEND_FAIL", tostring(initErr), { Player = entry.Player })
				Metrics.Add("InitSendFailed")
			end
		end
	end

	function self.OnEntryReady(entry: any)
		-- QueueOpen, not HandshakeReady: the question is whether a snapshot has already
		-- been started, which is the same question the re-Init throttle asks. The two
		-- reading different flags is how the gap opened.
		if entry.HelloReceived and not entry.QueueOpen then
			local okInit, initErr = pcall(sendInit, entry)
			if not okInit then
				Log.Error("Replication", "INIT_SEND_FAIL", tostring(initErr), { Player = entry.Player })
				Metrics.Add("InitSendFailed")
			end
		end
		-- Broadcast this player's Shared snapshot to everyone else.
		local sharedOps = sharedSnapshotOps(entry)
		if #sharedOps > 0 then
			local ok, bytes = pcall(Wire.EncodeOpsFrame, Wire.Frames.SharedInit, compiled, sharedOps, function(w)
				Wire.F64(w, entry.UserId)
			end)
			if ok then
				local missed = broadcastBuffer(bytes, entry)
				if missed ~= nil then
					for _, other in missed do
						markResync(other, "SharedInit")
					end
				end
			end
		end
		-- Anything queued before this snapshot is already in it, and the next flush
		-- would broadcast it again as a SharedDiff, permanently doubling a
		-- non-idempotent Insert. Clear unconditionally: the snapshot is authoritative.
		entry.SharedQueue = {}
		Clock.Delay(HANDSHAKE_TIMEOUT, function()
			if not entry.TornDown and not entry.HandshakeReady then
				if entry.HelloReceived then
					-- A different failure with the same symptom: the client did ask and the
					-- answer could not be delivered. MaxOutboundBytes is named because a
					-- transport refusing a payload this size is the one innocent cause.
					Log.Warn(
						"Replication",
						"INIT_UNDELIVERED",
						"the client sent Hello but its snapshot never reached the transport; check MaxOutboundBytes against what this transport will carry",
						{
							Player = entry.Player,
						}
					)
				else
					Log.Warn(
						"Replication",
						"CLIENT_HANDSHAKE_TIMEOUT",
						"client never sent Hello, so replication never started; require the Scribe bundle on the client (a LocalScript), or check a custom client transport adapter",
						{
							Player = entry.Player,
						}
					)
				end
			end
		end)
	end

	function self.OnEntryRemoved(entry: any)
		entry.HandshakeReady = false
		-- Symmetry rather than a fix: a removed entry's tree is already dead, so
		-- nothing can push to it.
		entry.QueueOpen = false
		-- Only meaningful when the template declares a Shared root: without one there is
		-- no mirror to drop. Sending it anyway costs one frame per remaining client on
		-- every leave, making a full server drain quadratic.
		if not compiled.HasShared then
			return
		end
		local w = Wire.NewWriter(16)
		Wire.U8(w, Wire.Frames.SharedGone)
		Wire.F64(w, entry.UserId)
		-- A missed SharedGone leaves a mirror of a player who has left, which no later
		-- frame ever clears.
		local missed = broadcastBuffer(Wire.Finish(w), entry)
		if missed ~= nil then
			for _, other in missed do
				markResync(other, "SharedGone")
			end
		end
	end

	function self.BroadcastStatus()
		sendStatus(nil)
	end

	--- Returns whether the frame reached the client. Leaderboards depends on it:
	--- stamping SentState for a refused board means broadcastBoard's dedup never
	--- resends it, leaving the client on a stale board.
	function self.SendTo(entry: any, bytes: buffer): boolean
		return sendBuffer(entry, bytes)
	end

	function self.Broadcast(bytes: buffer)
		local missed = broadcastBuffer(bytes)
		if missed ~= nil then
			for _, other in missed do
				markResync(other, "Broadcast")
			end
		end
	end

	connections[#connections + 1] = Health.OnStatusChanged:Connect(function()
		self.BroadcastStatus()
	end)

	-- Inbound dispatch -------------------------------------------------

	transport:ListenServer(function(player: Player, bytes: buffer)
		local entry = ctx.Persistence.Entries[player]
		if not entry then
			return
		end
		if entry.MalformedBlocked or entry.OversizeBlocked then
			-- Past the malformed or oversize limit; drop without parsing so a flood of
			-- crafted frames cannot keep burning CPU. Two counters because the logs need
			-- to say which budget tripped.
			return
		end
		-- Ahead of the size check on purpose: this is the one ceiling that sees every
		-- frame whatever its type, size or validity, and it is spent before the frame
		-- is looked at. Silent, because replying is the amplification this tier avoids.
		if not takeFrameToken(entry) then
			Metrics.Add("InboundRateLimited")
			local now = Clock.Monotonic()
			if now - (entry.LastInboundRateLog or -math.huge) >= MALFORMED_LOG_INTERVAL then
				entry.LastInboundRateLog = now
				Log.Warn("Transport", "INBOUND_RATE_LIMITED", `player exceeded {inboundFrameRate} frames/s`, {
					Player = player,
				})
			end
			return
		end
		if buffer.len(bytes) > maxInbound then
			entry.OversizeCount += 1
			Metrics.Add("InboundOversize")
			-- Throttle the log, on its own clock: this frame is attacker-controlled, so
			-- logging every one would evict the diagnostic ring. The metric counts all.
			local now = Clock.Monotonic()
			if now - (entry.LastOversizeLog or -math.huge) >= MALFORMED_LOG_INTERVAL then
				entry.LastOversizeLog = now
				Log.Warn(
					"Transport",
					"INBOUND_OVERSIZE",
					`dropped oversized inbound frame ({buffer.len(bytes)} bytes)`,
					{ Player = player, Count = entry.OversizeCount }
				)
			end
			if entry.OversizeCount >= OVERSIZE_MAX and not entry.OversizeBlocked then
				entry.OversizeBlocked = true
				Log.Warn(
					"Transport",
					"INBOUND_OVERSIZE_LIMIT",
					`player exceeded {OVERSIZE_MAX} oversized frames; ignoring further inbound frames this session `
						.. `(if legitimate client traffic is this large, raise MaxInboundBytes)`,
					{ Player = player, Count = entry.OversizeCount, Limit = maxInbound }
				)
			end
			return
		end
		-- Built outside the pcall so its overBudget flag survives the failure. The
		-- retained-bytes budget is what the byte cap above cannot express: `06 00` is
		-- two bytes and allocates, eight kilobytes of one string allocates once.
		local reader = Wire.NewReader(bytes, maxInboundRetained)
		local ok, err = pcall(function()
			local frameType = Wire.RU8(reader)
			if frameType == Wire.Frames.Hello then
				onHello(entry, reader)
			elseif frameType == Wire.Frames.Command then
				ctx.Commands.HandleFrame(entry, reader)
			else
				error(`unexpected inbound frame type {frameType}`)
			end
		end)
		if not ok and reader.overBudget then
			-- Its own counter, not the malformed budget, and deliberately with no blocking
			-- limit: a frame over this budget may be a legal payload from the game's own
			-- client, and a 32-strike session-permanent budget would drop that player for
			-- playing the game. Silent, like the rate limiter.
			entry.WorkLimitCount = (entry.WorkLimitCount or 0) + 1
			Metrics.Add("InboundWorkLimited")
			local now = Clock.Monotonic()
			if now - (entry.LastWorkLimitLog or -math.huge) >= MALFORMED_LOG_INTERVAL then
				entry.LastWorkLimitLog = now
				Log.Warn(
					"Transport",
					"INBOUND_WORK_LIMIT",
					`dropped an inbound frame that would retain more than {maxInboundRetained} bytes `
						.. `(if legitimate client traffic is this large, raise MaxInboundRetainedBytes)`,
					{ Player = player, Count = entry.WorkLimitCount, Limit = maxInboundRetained }
				)
			end
		elseif not ok then
			entry.MalformedCount += 1
			Metrics.Add("MalformedFrames")
			-- Throttle the log + anomaly so a crafted-frame flood can't spam the log
			-- buffer or an OnAnomaly handler (the count still increments every time).
			local now = Clock.Monotonic()
			if now - (entry.LastMalformedLog or -math.huge) >= MALFORMED_LOG_INTERVAL then
				entry.LastMalformedLog = now
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
			-- Past the limit, stop dispatching this player's inbound frames entirely
			-- for the rest of the session (a real client never sends malformed frames).
			if entry.MalformedCount >= MALFORMED_MAX and not entry.MalformedBlocked then
				entry.MalformedBlocked = true
				Log.Warn(
					"Transport",
					"MALFORMED_FRAME_LIMIT",
					`player exceeded {MALFORMED_MAX} malformed frames; ignoring further inbound frames this session`,
					{ Player = player, Count = entry.MalformedCount }
				)
			end
		end
	end)

	-- Release the per-frame flush handler and the status listener; without this a
	-- discarded bundle keeps flushing against a dead Persistence forever.
	function self.Stop()
		for _, connection in connections do
			pcall(function()
				connection:Disconnect()
			end)
		end
		table.clear(connections)
	end

	return self
end

return Replication
