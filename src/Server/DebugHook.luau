--!strict
-- Studio debug hook: the game-side half of the Scribe Studio companion plugin.
-- Server.new gates the require on RunService:IsStudio(), so outside Studio nothing here
-- exists for an exploiter to find.
--
-- Transport is one BindableFunction (request/response) and one BindableEvent (stream
-- digests) under ServerStorage._ScribeDebugHook. The plugin runs in a different Luau VM,
-- so every variable-shaped payload crosses as a Codec-encoded string; plain-table
-- reflection between VMs rejects mixed keys and mangles sparse arrays.
--
-- Reads are always available once a plugin attaches. Writes need an explicit per-session
-- opt-in and go through the public server Value API, so the hook can never do something
-- game code could not; receipt injection additionally requires the resolved Mode be
-- "Mock".
--
-- Interception installs at Attach, i.e. game boot, so ops from before the plugin window
-- opened are recorded into a capped ring and replay when a plugin subscribes.

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local Internal = script.Parent.Parent.Internal
local Util = require(Internal.Util)
local Template = require(Internal.Template)
local Datatypes = require(Internal.Datatypes)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)

local DebugHook = {}

-- Bumped whenever the request/response shapes change. The plugin declares the range
-- [MinProtocolVersion, Version] it can speak and the hook accepts when its own version
-- falls inside, so a newer plugin emulates older hooks and games never have to update
-- Scribe just for the plugin. A plugin older than the hook is refused: the hook cannot
-- know future semantics.
-- v9 adds Derived info to schema nodes and refuses a write to a derived field. The
-- full version history lives in the plugin's src/Protocol.luau, which is the one copy
-- kept complete; bump both together.
DebugHook.PROTOCOL_VERSION = 9
DebugHook.CONTAINER_NAME = "_ScribeDebugHook"

local OPS_FLUSH_HZ = 8
local ROSTER_HZ = 1
local METRICS_HZ = 1
-- Always-on stream rings, each kept below the pending-queue cap of MAX_BATCH * 4 so a
-- replay never drops live records.
local RECENT_OPS_CAP = 2000
local RECENT_LOGS_CAP = 2000
local RECENT_SENDS_CAP = 2000
local RECENT_METRICS_CAP = 1200 -- 1 Hz ticks = 20 minutes of graphs
local MAX_BATCH = 512 -- ops/log entries per digest fire
local MAX_TREE_NODES = 2000 -- ReadTree response budget
local SIZE_RECOMPUTE_SECONDS = 5

--------------------------------------------------------------------------------
-- Codec: shared with the client hook via Internal/StudioCodec, byte-compatible with the
-- plugin's Codec.luau and versioned by PROTOCOL_VERSION.
--------------------------------------------------------------------------------

local StudioCodec = require(Internal.StudioCodec)
local encode = StudioCodec.Encode
local decode = StudioCodec.Decode

DebugHook.Encode = encode
DebugHook.Decode = decode

--------------------------------------------------------------------------------
-- Mirror: a plain-table replica of each session's data, built from the same op stream the
-- plugin sees, so a digest can report the old value. Writes with Replicate=false bypass
-- ops and drift it, which is acceptable for a diagnostics view.
--------------------------------------------------------------------------------

local function readPath(root: any, path: { string | number }): any
	local value = root
	for _, seg in path do
		if type(value) ~= "table" then
			return nil
		end
		value = value[seg]
	end
	return value
end

local function applyPlainOp(root: { [any]: any }, op: any)
	local container: any = root
	for i = 1, #op.Path - 1 do
		local seg = op.Path[i]
		local nextContainer = container[seg]
		if type(nextContainer) ~= "table" then
			if op.Kind == "Remove" then
				return -- array removals always ship alongside their creating Insert
			end
			-- A removal op only emits when the parent chain existed server-side, so a
			-- missing parent means its creating op was coalesced away in the same flush
			-- while the container still exists live. Materialize it.
			nextContainer = {}
			container[seg] = nextContainer
		end
		container = nextContainer
	end
	local key = op.Path[#op.Path]
	if key == nil then
		return
	end
	if op.Kind == "Set" then
		-- deepClone copies tables and buffers, both mutable.
		container[key] = Util.deepClone(op.Value)
	elseif op.Kind == "Insert" then
		local arr = container[key]
		if type(arr) ~= "table" then
			arr = {}
			container[key] = arr
		end
		-- An Insert op's Value is the live-stored element reference, so inserting it raw
		-- would alias live data into this mirror, and a later op descending through that
		-- element would corrupt the real saved data.
		table.insert(arr, math.clamp(op.Index or #arr + 1, 1, #arr + 1), Util.deepClone(op.Value))
	elseif op.Kind == "Remove" then
		local arr = container[key]
		if type(arr) == "table" and #arr > 0 then
			table.remove(arr, math.clamp(op.Index or #arr, 1, #arr))
		end
	elseif op.Kind == "Clear" then
		local value = container[key]
		if type(value) == "table" then
			table.clear(value)
		else
			-- A Clear only emits for a container that existed server-side, so materialize
			-- the cleared {} if its creating op was coalesced away.
			container[key] = {}
		end
	end
end

--------------------------------------------------------------------------------
-- Attach
--------------------------------------------------------------------------------

local attached = false

function DebugHook.Attach(Data: any, ctx: any)
	if not RunService:IsStudio() then
		return
	end
	if attached or ServerStorage:FindFirstChild(DebugHook.CONTAINER_NAME) then
		Log.Warn(
			"Lifecycle",
			"DEBUG_HOOK_DUPLICATE",
			"a Scribe debug hook already exists; only the first bundle is inspectable",
			{}
		)
		return
	end
	attached = true

	local compiled: Template.Compiled = ctx.Compiled
	local options = ctx.Options
	local packagePrefix = script.Parent.Parent:GetFullName()

	-- Session state ------------------------------------------------------------

	local writesEnabled = false
	local attributionEnabled = false
	local subscriptions: { [string]: boolean } = {}

	local pending: { [string]: { any } } = { Ops = {}, Logs = {}, Players = {}, Status = {}, Bandwidth = {} }
	local mirrors: { [any]: { [string]: any } } = {} -- entry -> merged root mirror
	local entryConnections: { [any]: RBXScriptConnection } = {}
	local sizeCache: { [any]: { Bytes: number?, At: number } } = {}
	local statusHistory: { { T: number, WallAt: number, From: string, To: string } } = {}
	local armedLoadFailures: { [string]: number } = {}
	-- Removers for registrations on library-level singletons: the Log sink list and
	-- Health.OnStatusChanged. Everything else this hook installs is ctx-scoped and dies
	-- with the bundle; these two outlive it and nothing else clears them.
	local teardown: { () -> () } = {}
	local detached = false
	local wrapsInstalled = false
	local storeWrapped = false
	local everHandshaken = false

	-- Everything since Attach, whether or not a plugin is listening; each ring replays on
	-- its stream's subscribe edge, so a panel shows the whole session however late its tab
	-- was opened. Circular, because a shifting array would pay an O(cap) move per record.
	type Ring = { Items: { any }, Cap: number, Count: number, Next: number }

	local function newRing(cap: number): Ring
		return { Items = table.create(cap), Cap = cap, Count = 0, Next = 1 }
	end

	local function ringPush(ring: Ring, record: any)
		ring.Items[ring.Next] = record
		ring.Next = ring.Next % ring.Cap + 1
		if ring.Count < ring.Cap then
			ring.Count += 1
		end
	end

	-- Chronological snapshot. With `flagReplay` each record is a shallow copy marked
	-- Replay = true; the plugin must not apply those to its live tree mirror, since they
	-- are older than any ReadTree page it holds.
	local function ringSnapshot(ring: Ring, flagReplay: boolean?): { any }
		local out = table.create(ring.Count)
		local start = if ring.Count < ring.Cap then 1 else ring.Next
		for i = 0, ring.Count - 1 do
			local record = ring.Items[(start + i - 1) % ring.Cap + 1]
			if flagReplay then
				record = table.clone(record)
				record.Replay = true
			end
			table.insert(out, record)
		end
		return out
	end

	local opsRing = newRing(RECENT_OPS_CAP)
	local logsRing = newRing(RECENT_LOGS_CAP)
	local sendsRing = newRing(RECENT_SENDS_CAP)
	local metricsRing = newRing(RECENT_METRICS_CAP)
	local opSeq = 0
	local logSeq = 0
	local sendSeq = 0
	local metricSeq = 0

	-- Writes initiated by the plugin are attributed Source=ScribeStudio. Tracked
	-- per-coroutine rather than by a depth counter, so game writes that happen while a
	-- hook call yields are never mislabeled.
	local hookWriteThreads: { [thread]: boolean } = {}

	local function studioCall(fn: any, ...: any): (boolean, ...any)
		local thread = coroutine.running()
		hookWriteThreads[thread] = true
		local results = table.pack(pcall(fn, ...))
		hookWriteThreads[thread] = nil
		return table.unpack(results, 1, results.n)
	end

	-- Attach runs inside Server.new, before the bundle is returned, so wrapping Register
	-- here observes every registration game code makes.
	local commandRegistry: { [string]: { Name: string, Args: { string }?, Handler: any } } = {}
	do
		local origRegister = ctx.Commands.Register
		ctx.Commands.Register = function(name: string, specOrHandler: any, handler: any?)
			origRegister(name, specOrHandler, handler) -- validation errors propagate
			local record: any = { Name = name }
			if handler ~= nil then
				record.Args = if type(specOrHandler) == "table" then specOrHandler.Args else nil
				record.Handler = handler
			else
				record.Handler = specOrHandler
			end
			commandRegistry[name] = record
		end
	end

	local container = Instance.new("Folder")
	container.Name = DebugHook.CONTAINER_NAME
	local requestFn = Instance.new("BindableFunction")
	requestFn.Name = "Request"
	requestFn.Parent = container
	local streamEv = Instance.new("BindableEvent")
	streamEv.Name = "Stream"
	streamEv.Parent = container

	--- Release the process-singleton registrations (the Log sink, the Health listener) and
	--- stop the pump. Idempotent, and deliberately does not clear `attached`, so a second
	--- Attach still refuses with DEBUG_HOOK_DUPLICATE. The ctx-scoped wraps stay installed
	--- and die with the bundle.
	local function detach()
		if detached then
			return
		end
		detached = true
		-- Ends the pump on its next tick, which is what it already watches for.
		container.Parent = nil
		for _, release in teardown do
			-- A throwing release must not strand the ones after it.
			pcall(release)
		end
		table.clear(teardown)
	end

	local function queue(stream: string, item: any)
		if not subscriptions[stream] then
			return
		end
		local bucket = pending[stream]
		if #bucket < MAX_BATCH * 4 then
			table.insert(bucket, item)
		end
	end

	local function flushStream(stream: string)
		local bucket = pending[stream]
		if #bucket == 0 or not subscriptions[stream] then
			if #bucket > 0 then
				pending[stream] = {}
			end
			return
		end
		while #bucket > 0 do
			local chunk = table.move(bucket, 1, math.min(MAX_BATCH, #bucket), 1, {})
			local remaining = #bucket - #chunk
			if remaining > 0 then
				bucket = table.move(bucket, #chunk + 1, #chunk + remaining, 1, {})
			else
				bucket = {}
			end
			-- Commit the drain progress before encoding, so a chunk that throws is dropped
			-- instead of the whole bucket re-firing on every pump tick.
			pending[stream] = bucket
			local ok, err = pcall(function()
				streamEv:Fire(stream, encode(chunk))
			end)
			if not ok then
				Log.Warn("Lifecycle", "DEBUG_HOOK_ERROR", `dropped a {stream} digest chunk: {tostring(err)}`, {})
			end
		end
		pending[stream] = bucket
	end

	-- Attribution ---------------------------------------------------------------

	local function captureSource(): { [string]: any }?
		if hookWriteThreads[coroutine.running()] then
			return { Script = "ScribeStudio", Line = 0 }
		end
		if not attributionEnabled then
			return nil
		end
		-- Walk out of the Scribe package to the first game-code frame. Batches and
		-- transactions add frames, so the walk goes deep.
		for level = 3, 24 do
			local source, line = debug.info(level, "sl")
			if source == nil then
				return nil
			end
			if string.sub(source, 1, #packagePrefix) ~= packagePrefix and source ~= "[C]" then
				return { Script = source, Line = line }
			end
		end
		return nil
	end

	-- Entry helpers --------------------------------------------------------------

	local function entryForUserId(userId: number): any
		return ctx.Persistence.EntryForUserId(userId)
	end

	local function profileIsActive(profile: any): boolean
		if profile == nil then
			return false
		end
		local ok, active = pcall(function()
			return profile:IsActive()
		end)
		return ok and active == true
	end

	local function mirrorFor(entry: any): { [string]: any }
		local mirror = mirrors[entry]
		if mirror == nil then
			mirror = {}
			if entry.LiveData then
				for k, v in Util.deepClone(entry.LiveData) :: { [string]: any } do
					mirror[k] = v
				end
			end
			if entry.SessionStore then
				for k, v in Util.deepClone(entry.SessionStore) :: { [string]: any } do
					mirror[k] = v
				end
			end
			mirrors[entry] = mirror
		end
		return mirror
	end

	local function watchEntry(entry: any)
		if entryConnections[entry] then
			return
		end
		local connection
		connection = entry.StateChanged:Connect(function(state: string, reason: string?)
			queue("Players", {
				Kind = "StateChanged",
				T = os.clock(),
				UserId = entry.UserId,
				Name = entry.Player.Name,
				State = state,
				Reason = reason,
			})
			if state == "Ready" then
				-- Seed the old-value mirror before the entry's first op: the node tree
				-- mutates LiveData before emitting, so lazy seeding reads Old == new.
				mirrorFor(entry)
			elseif state == "SessionEnded" then
				mirrors[entry] = nil
				sizeCache[entry] = nil
				-- Drop the strong reference or the profile stays pinned for the rest of
				-- the play session.
				entryConnections[entry] = nil
				connection:Disconnect()
			end
		end)
		entryConnections[entry] = connection
	end

	local function profileSize(entry: any): number?
		local cached = sizeCache[entry]
		local now = os.clock()
		if cached and now - cached.At < SIZE_RECOMPUTE_SECONDS then
			return cached.Bytes
		end
		local bytes = entry.LastSavedSize
		if entry.LiveData then
			bytes = Util.approxSize(entry.LiveData)
		end
		sizeCache[entry] = { Bytes = bytes, At = now }
		return bytes
	end

	local function rosterSnapshot(): { any }
		local roster = {}
		for _, entry in ctx.Persistence.Entries do
			watchEntry(entry)
			table.insert(roster, {
				UserId = entry.UserId,
				Name = entry.Player.Name,
				DisplayName = entry.Player.DisplayName,
				State = entry.State,
				FailReason = entry.FailReason,
				Dirty = entry.SaveInfo.Dirty,
				LastSaveAt = entry.SaveInfo.LastSaveAt,
				LastResult = entry.SaveInfo.LastResult,
				SizeBytes = profileSize(entry),
				Blocked = entry.Blocked,
				HandshakeReady = entry.HandshakeReady,
				QueueOpen = entry.QueueOpen,
				QueueDepth = #entry.Queue,
				Mock = ctx.Persistence.Mode == "Mock",
			})
		end
		table.sort(roster, function(a: any, b: any)
			return a.UserId < b.UserId
		end)
		return roster
	end

	-- Interception (installed at Attach, so game boot is captured) ---------------

	local function installWraps()
		if wrapsInstalled then
			return
		end
		wrapsInstalled = true

		-- Every replication-worthy op, including the ServerOnly paths the original PushOp
		-- filters out after us. Recorded whether or not anything is subscribed, so ops
		-- from before the plugin opened can replay into the Changes feed later.
		local origPushOp = ctx.Replication.PushOp
		ctx.Replication.PushOp = function(entry: any, op: any, schema: any?)
			local ok, err = pcall(function()
				watchEntry(entry) -- StateChanged cleanup for mirrors, pre-roster
				local mirror = mirrorFor(entry)
				local old: any = nil
				if op.Kind == "Set" or op.Kind == "Clear" then
					-- For Clear this is the full contents, not a count, so the plugin's
					-- replay can undo it; the clone below snapshots it before
					-- applyPlainOp mutates.
					old = readPath(mirror, op.Path)
				elseif op.Kind == "Remove" then
					local arr = readPath(mirror, op.Path)
					if type(arr) == "table" then
						old = arr[math.clamp(op.Index or #arr, 1, math.max(#arr, 1))]
					end
				end
				local visibility = if schema then schema.Visibility else Template.VisibilityOf(compiled, op.Path)
				opSeq += 1
				-- Value/Old are cloned because the ring outlives the flush window and both
				-- game code and the mirror keep mutating what they reference. The clone
				-- runs before applyPlainOp so Clear's old contents survive.
				local record = {
					HookSeq = opSeq,
					T = os.clock(),
					UserId = entry.UserId,
					Kind = op.Kind,
					Path = table.clone(op.Path),
					Index = op.Index,
					Value = if type(op.Value) == "table" or type(op.Value) == "buffer"
						then Util.deepClone(op.Value)
						else op.Value,
					Old = if type(old) == "table" or type(old) == "buffer" then Util.deepClone(old) else old,
					Visibility = visibility,
					FieldId = if schema then schema.Id else nil,
					Source = captureSource(),
				}
				ringPush(opsRing, record)
				queue("Ops", record)
				applyPlainOp(mirror, op)
			end)
			if not ok then
				Log.Warn("Lifecycle", "DEBUG_HOOK_ERROR", tostring(err), {})
			end
			return origPushOp(entry, op, schema)
		end

		-- Real wire bytes per send, per player.
		local function recordSend(userId: number, bytes: buffer)
			sendSeq += 1
			local record = {
				SendSeq = sendSeq,
				T = os.clock(),
				UserId = userId,
				Bytes = buffer.len(bytes),
				Frame = if buffer.len(bytes) > 0 then buffer.readu8(bytes, 0) else 0,
			}
			ringPush(sendsRing, record)
			queue("Bandwidth", record)
		end

		local transport = ctx.Transport
		local origSend = transport.SendToClient
		transport.SendToClient = function(self: any, player: Player, bytes: buffer)
			pcall(recordSend, player.UserId, bytes)
			return origSend(self, player, bytes)
		end
		if transport.SendToAllClients then
			local origBroadcast: any = transport.SendToAllClients
			transport.SendToAllClients = function(self: any, bytes: buffer)
				pcall(recordSend, 0, bytes) -- 0 = broadcast
				return origBroadcast(self, bytes)
			end
		end

		-- Log ring: seeded from the core log history, which covers everything logged
		-- before Attach, then fed by the sink.
		local function recordLog(logEntry: any)
			logSeq += 1
			local record = {
				LogSeq = logSeq,
				At = logEntry.At,
				Level = logEntry.Level,
				Category = logEntry.Category,
				Code = logEntry.Code,
				Message = logEntry.Message,
				Context = Util.sanitizeContext(logEntry.Context),
			}
			ringPush(logsRing, record)
			queue("Logs", record)
		end

		pcall(function()
			for _, logEntry in Log.GetRecent({ Limit = RECENT_LOGS_CAP }) do
				recordLog(logEntry)
			end
		end)
		table.insert(teardown, Log.AddSink(recordLog))

		local statusConn = Health.OnStatusChanged:Connect(function(newStatus: string, oldStatus: string)
			local record = { T = os.clock(), WallAt = os.time(), From = oldStatus, To = newStatus }
			table.insert(statusHistory, record)
			if #statusHistory > 100 then
				table.remove(statusHistory, 1)
			end
			queue("Status", record)
		end)
		table.insert(teardown, function()
			statusConn:Disconnect()
		end)

		ctx.Signals.OnSave:Connect(function(info: any)
			local savePlayer: any = info.Player
			queue("Players", {
				Kind = "Save",
				T = os.clock(),
				UserId = if savePlayer ~= nil then savePlayer.UserId else 0,
				Ok = info.Ok,
				Duration = info.Duration,
				At = info.At,
			})
		end)

		-- Digest pump. Single loop; per-stream cadence via accumulators.
		task.spawn(function()
			local lastRoster = 0
			local lastMetrics = 0
			local lastResync = 0
			while container.Parent ~= nil do
				task.wait(1 / OPS_FLUSH_HZ)
				local ok, err = pcall(function()
					local now = os.clock()
					-- Seed every Ready entry each tick: the mirror must exist before the
					-- entry's first op, or Old reads back as the new value.
					for _, entry in ctx.Persistence.Entries do
						if entry.State == "Ready" and mirrors[entry] == nil then
							watchEntry(entry)
							mirrorFor(entry)
						end
					end
					-- Writes with Replicate=false bypass the op stream and drift the
					-- old-value mirrors. Gated on a plugin having attached, so an
					-- unwatched game never pays a recurring deep clone of every profile.
					if everHandshaken and now - lastResync >= 10 then
						lastResync = now
						local mirrored = {}
						for entry in mirrors do
							table.insert(mirrored, entry)
						end
						for _, entry in mirrored do
							mirrors[entry] = nil
							if entry.State == "Ready" and not entry.TornDown then
								mirrorFor(entry)
							end
						end
					end
					flushStream("Ops")
					flushStream("Logs")
					flushStream("Status")
					flushStream("Bandwidth")
					if subscriptions.Players and now - lastRoster >= 1 / ROSTER_HZ then
						lastRoster = now
						queue("Players", { Kind = "Roster", T = now, Roster = rosterSnapshot() })
					end
					flushStream("Players")
					if now - lastMetrics >= 1 / METRICS_HZ then
						lastMetrics = now
						metricSeq += 1
						local tick = {
							MetricSeq = metricSeq,
							T = now,
							WallAt = os.time(),
							Status = Health.GetStatus(),
							Metrics = Metrics.Get(),
						}
						ringPush(metricsRing, tick)
						if subscriptions.Metrics then
							streamEv:Fire("Metrics", encode({ tick }))
						end
					end
				end)
				if not ok then
					Log.Warn("Lifecycle", "DEBUG_HOOK_ERROR", tostring(err), {})
				end
			end
			-- The container may be destroyed by somebody other than detach(). Release
			-- either way, or the sink and the listener outlive the pump that fed them.
			detach()
		end)
	end

	-- Store wrap for simulated load failures --------------------------------------

	local function ensureStoreWrap()
		if storeWrapped then
			return
		end
		storeWrapped = true
		local store = ctx.Persistence.Store
		local origStart = store.StartSessionAsync
		store.StartSessionAsync = function(self: any, key: string, params: any?)
			local remaining = armedLoadFailures[key]
			if remaining and remaining > 0 then
				armedLoadFailures[key] = remaining - 1
				if armedLoadFailures[key] == 0 then
					armedLoadFailures[key] = nil
				end
				Log.Warn(
					"Persistence",
					"SIM_LOAD_FAILURE",
					"simulated profile load failure (Scribe Studio)",
					{ Key = key }
				)
				error("Scribe Studio: simulated load failure")
			end
			return origStart(self, key, params)
		end
	end

	-- Value API access -----------------------------------------------------------

	local function accessorAt(entry: any, path: { string | number }): any
		local accessor = entry.Tree.Accessor
		for _, seg in path do
			accessor = accessor[seg]
		end
		return accessor
	end

	-- Live view straight off the stores (Persist + Session roots merged by
	-- reference); the op mirror is only for old values.
	local function liveRootsFor(entry: any): { [string]: any }
		local merged = {}
		if entry.LiveData then
			for k, v in entry.LiveData :: { [string]: any } do
				merged[k] = v
			end
		end
		if entry.SessionStore then
			for k, v in entry.SessionStore :: { [string]: any } do
				merged[k] = v
			end
		end
		return merged
	end

	local function describeValue(value: any, depth: number, budget: { n: number }, schema: any): any
		budget.n -= 1
		if type(value) ~= "table" then
			-- A packed datatype leaf is a bare buffer in the store; show the real
			-- value as a display string (StudioCodec cannot carry Roblox datatypes).
			if type(value) == "buffer" and schema and schema.ValueType == "datatype" then
				local name = schema.Datatype :: string
				local ok, unpacked = pcall(Datatypes.Unpack, name, value)
				if ok then
					return { Leaf = true, Value = `{name}({tostring(unpacked)})`, Datatype = name }
				end
			end
			return { Leaf = true, Value = value }
		end
		local count = Util.count(value)
		if depth <= 0 or budget.n <= 0 then
			return { Table = true, Count = count, Truncated = true }
		end
		local children: { [any]: any } = {}
		for k, v in value do
			if budget.n <= 0 then
				return { Table = true, Count = count, Truncated = true, Children = children }
			end
			local childSchema = if schema then Template.ChildSchema(schema, k) else nil
			children[k] = describeValue(v, depth - 1, budget, childSchema)
		end
		return { Table = true, Count = count, Children = children }
	end

	-- A page of the tree at `path`: leaves inline, deep tables as stubs the plugin
	-- re-requests on expand. Bounded by a node budget so no response can explode.
	local function readTreePage(entry: any, path: { string | number }, depth: number, budget: { n: number }): any
		local value = readPath(liveRootsFor(entry), path)
		local schema: any, dynStart = Template.Resolve(compiled, path)
		for i = dynStart, #path do
			schema = if schema then Template.ChildSchema(schema, path[i]) else nil
		end
		return describeValue(value, depth, budget, schema)
	end

	-- Dotted input paths of a derived node, for the schema export and the write
	-- refusal. The spec's Compute is a function and never crosses the wire.
	local function derivedInputPaths(spec: any): { string }
		local out = table.create(#spec.InputPaths)
		for i, inputPath in spec.InputPaths do
			out[i] = table.concat(inputPath, ".")
		end
		return out
	end

	-- Command handlers -------------------------------------------------------------

	local handlers: { [string]: (args: any) -> any } = {}

	function handlers.Handshake(args: any): any
		local major = tonumber(args.ProtocolVersion) or 0
		-- A plugin without MinProtocolVersion effectively declares [major, major].
		local minSupported = tonumber(args.MinProtocolVersion) or major
		-- NaN compares false both ways and would slip through the range check.
		if major ~= major or minSupported ~= minSupported then
			major, minSupported = 0, 0
		end
		if DebugHook.PROTOCOL_VERSION < minSupported or DebugHook.PROTOCOL_VERSION > major then
			return {
				Ok = false,
				Error = `protocol mismatch: game hook speaks v{DebugHook.PROTOCOL_VERSION}, plugin speaks v{minSupported}-v{major}`
					.. if major < DebugHook.PROTOCOL_VERSION
						then " — update the Scribe Studio plugin"
						else " — update the Scribe package in this game",
				ProtocolVersion = DebugHook.PROTOCOL_VERSION,
			}
		end
		installWraps()
		everHandshaken = true
		-- A handshake means a new plugin instance, so forget the previous one's
		-- subscriptions: the next SetSubscriptions then sees a false->true Ops edge and
		-- replays the boot ring into the fresh, empty Store.
		for stream in subscriptions do
			subscriptions[stream] = false
		end
		for _, bucket in pending do
			table.clear(bucket)
		end
		local scribeVersion = "unknown"
		pcall(function()
			scribeVersion = (require :: any)(script.Parent.Parent).Version
		end)
		Log.Info("Lifecycle", "DEBUG_HOOK_ATTACHED", "Scribe Studio attached", {})
		return {
			Ok = true,
			ProtocolVersion = DebugHook.PROTOCOL_VERSION,
			ScribeVersion = scribeVersion,
			TemplateHash = compiled.Hash,
			NodeCount = compiled.NodeCount,
			-- Derived from the resolved mode, so a Mode = "Mock" bundle reports as mocked.
			Mode = ctx.Persistence.Mode,
			UseMock = ctx.Persistence.Mode == "Mock",
			DontSave = ctx.Persistence.Mode == "Mock",
			Clock = os.clock(),
			WallClock = os.time(),
			WritesEnabled = writesEnabled,
			AttributionEnabled = attributionEnabled,
			Status = Health.GetStatus(),
			PlaceName = game.Name,
		}
	end

	function handlers.SetSubscriptions(args: any): any
		local had: { [string]: boolean } = {}
		for _, stream in { "Ops", "Logs", "Metrics", "Players", "Status", "Bandwidth" } do
			had[stream] = subscriptions[stream] == true
			subscriptions[stream] = args[stream] == true
			if not subscriptions[stream] and pending[stream] then
				table.clear(pending[stream])
			end
		end
		-- Mirrors stay resident while unsubscribed because the op ring needs Old values;
		-- seed any Ready entries that have no ops yet.
		if subscriptions.Ops then
			for _, entry in ctx.Persistence.Entries do
				if entry.State == "Ready" then
					watchEntry(entry)
					mirrorFor(entry)
				end
			end
		end
		-- On each stream's false->true edge, replay its ring and flush immediately so the
		-- pending queue is free again for live records. Every record carries a per-stream
		-- sequence number, which the plugin dedupes on, so a re-subscribe cannot
		-- double-deliver.
		local function replay(stream: string, ring: Ring, flagReplay: boolean?)
			if subscriptions[stream] and not had[stream] and ring.Count > 0 then
				pending[stream] = ringSnapshot(ring, flagReplay)
				flushStream(stream)
			end
		end
		replay("Ops", opsRing, true)
		replay("Logs", logsRing)
		replay("Bandwidth", sendsRing)
		-- Metrics has no pending bucket, being fired directly at 1 Hz; replay the tick
		-- history the same chunked way.
		if subscriptions.Metrics and not had.Metrics and metricsRing.Count > 0 then
			local snapshot = ringSnapshot(metricsRing)
			local offset = 1
			while offset <= #snapshot do
				local chunk = table.move(snapshot, offset, math.min(offset + MAX_BATCH - 1, #snapshot), 1, {})
				local ok, err = pcall(function()
					streamEv:Fire("Metrics", encode(chunk))
				end)
				if not ok then
					Log.Warn("Lifecycle", "DEBUG_HOOK_ERROR", `dropped a Metrics replay chunk: {tostring(err)}`, {})
				end
				offset += MAX_BATCH
			end
		end
		return { Ok = true }
	end

	function handlers.SetAttribution(args: any): any
		attributionEnabled = args.Enabled == true
		Log.Info(
			"Lifecycle",
			"DEBUG_HOOK_ATTRIBUTION",
			`attribution capture {if attributionEnabled then "enabled" else "disabled"}`,
			{}
		)
		return { Ok = true, Enabled = attributionEnabled }
	end

	function handlers.SetWritesEnabled(args: any): any
		writesEnabled = args.Enabled == true
		Log.Warn(
			"Lifecycle",
			"DEBUG_HOOK_WRITES",
			`Scribe Studio writes {if writesEnabled then "ENABLED" else "disabled"}`,
			{}
		)
		return { Ok = true, Enabled = writesEnabled }
	end

	function handlers.ListPlayers(_args: any): any
		return { Ok = true, Roster = rosterSnapshot() }
	end

	function handlers.ReadTree(args: any): any
		local entry = entryForUserId(tonumber(args.UserId) or 0)
		if not entry then
			return { Ok = false, Error = "no session for that UserId" }
		end
		if entry.State ~= "Ready" then
			return { Ok = false, Error = `session is {entry.State}` }
		end
		local path: { string | number } = args.Path or {}
		local depth = math.clamp(tonumber(args.Depth) or 2, 1, 6)
		local budget = { n = math.clamp(tonumber(args.MaxNodes) or MAX_TREE_NODES, 50, MAX_TREE_NODES) }
		local page = readTreePage(entry, path, depth, budget)
		return { Ok = true, Path = path, Node = page }
	end

	local function requireWrites(): string?
		if not writesEnabled then
			return "writes are disabled — enable the write toggle in Scribe Studio settings"
		end
		return nil
	end

	function handlers.WriteValue(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		local entry = entryForUserId(tonumber(args.UserId) or 0)
		if not entry or entry.State ~= "Ready" then
			return { Ok = false, Error = "no Ready session for that UserId" }
		end
		local path: { string | number } = args.Path or {}
		if #path == 0 then
			return { Ok = false, Error = "cannot write the root" }
		end
		-- Refuse here rather than let the accessor's own error surface, so the plugin
		-- can show what the field is computed from. Derived paths are always static.
		local targetNode, dynStart = Template.Resolve(compiled, path)
		if dynStart > #path and targetNode.Derived then
			local inputs = table.concat(derivedInputPaths(targetNode.Derived), ", ")
			return {
				Ok = false,
				Error = `{table.concat(path, ".")} is a derived field: it is computed from {inputs} and cannot be written`,
			}
		end
		local mode: string = args.Mode or "Set"
		local ok, err = studioCall(function()
			if mode == "Set" then
				accessorAt(entry, path).Set(args.Value)
			elseif mode == "Insert" then
				accessorAt(entry, path).Insert(args.Value, args.Index)
			elseif mode == "RemoveIndex" then
				accessorAt(entry, path).Remove(tonumber(args.Index))
			elseif mode == "RemoveKey" then
				accessorAt(entry, path).Remove(tostring(args.Key))
			elseif mode == "Clear" then
				accessorAt(entry, path).Clear()
			elseif mode == "Increment" then
				accessorAt(entry, path).Increment(tonumber(args.Value) or 0)
			elseif mode == "SetTimed" then
				-- Value + wall-clock timer; errors on non-Timed fields.
				local seconds = tonumber(args.Seconds)
				if seconds == nil or seconds <= 0 then
					error("SetTimed needs positive Seconds")
				end
				accessorAt(entry, path).SetTimed(args.Value, seconds)
			elseif mode == "ExtendTimed" then
				local seconds = tonumber(args.Seconds)
				if seconds == nil or seconds <= 0 then
					error("ExtendTimed needs positive Seconds")
				end
				accessorAt(entry, path).ExtendTimed(seconds)
			elseif mode == "ClearTimed" then
				-- Cancel the timer, leave the value. Goes through Timed's own raw-store
				-- write rather than touching _Scribe.Timed here: a nested Timed field's
				-- pathKey embeds \31, which the accessor tree rejects, and a save in
				-- flight has the profile pointed at a converted copy.
				accessorAt(entry, path).Active() -- errors early on non-Timed fields
				ctx.Timed.ClearField(entry, Util.pathKey(path))
			else
				error(`unknown write mode "{mode}"`)
			end
		end)
		if not ok then
			return { Ok = false, Error = tostring(err) }
		end
		local newValue = nil
		pcall(function()
			newValue = accessorAt(entry, path).Get()
		end)
		return { Ok = true, NewValue = newValue }
	end

	function handlers.GetSchema(_args: any): any
		local nodes = {}
		for id = 0, compiled.NodeCount - 1 do
			local node = compiled.ById[id]
			if node then
				local record: any = {
					Id = node.Id,
					Path = table.clone(node.Path),
					Kind = node.Kind,
					ValueType = node.ValueType,
					Datatype = node.Datatype,
					Visibility = node.Visibility,
					Timed = node.Timed,
					Min = node.Min,
					Max = node.Max,
					MaxLength = node.MaxLength,
					Members = if node.Members then table.clone(node.Members) else nil,
					HasChildren = node.Children ~= nil,
				}
				-- Additive since v9; the field is absent on a non-derived node.
				local derived = node.Derived
				if derived then
					record.Derived = {
						Inputs = derivedInputPaths(derived),
						Transmit = derived.Transmit,
						OfflineComputable = derived.OfflineComputable,
						Label = derived.Label,
					}
				end
				table.insert(nodes, record)
			end
		end
		-- Element subtrees are id-less, reached only through AnyChild, so the ById walk
		-- above cannot see them. Exported additively, keyed by the container node's id;
		-- older plugins ignore the extra field.
		local elements: { [any]: any } = {}
		local function describeSchemaNode(node: any): any
			local children: { [string]: any }? = nil
			if node.Children then
				children = {}
				for name, child in node.Children do
					(children :: any)[name] = describeSchemaNode(child)
				end
			end
			return {
				Name = node.Name,
				Kind = node.Kind,
				ValueType = node.ValueType,
				Datatype = node.Datatype,
				Visibility = node.Visibility,
				Min = node.Min,
				Max = node.Max,
				MaxLength = node.MaxLength,
				Members = if node.Members then table.clone(node.Members) else nil,
				Nullable = node.Nullable,
				Container = node.Container,
				MaxItems = node.MaxItems,
				MaxKeys = node.MaxKeys,
				MaxKeyLength = node.MaxKeyLength,
				Children = children,
				Element = if node.AnyChild and node.AnyChild.IsElement then describeSchemaNode(node.AnyChild) else nil,
			}
		end
		for id = 0, compiled.NodeCount - 1 do
			local node = compiled.ById[id]
			if node and node.Container ~= nil and node.AnyChild then
				elements[id] = describeSchemaNode(node.AnyChild)
			end
		end
		return { Ok = true, Hash = compiled.Hash, NodeCount = compiled.NodeCount, Nodes = nodes, Elements = elements }
	end

	function handlers.GetRecentLogs(args: any): any
		local entries = Log.GetRecent({
			Level = args.Level,
			Category = args.Category,
			Code = args.Code,
			Limit = tonumber(args.Limit) or 500,
		})
		local out = {}
		for _, logEntry in entries do
			table.insert(out, {
				At = logEntry.At,
				Level = logEntry.Level,
				Category = logEntry.Category,
				Code = logEntry.Code,
				Message = logEntry.Message,
				Context = Util.sanitizeContext(logEntry.Context),
			})
		end
		return { Ok = true, Entries = out }
	end

	function handlers.GetMetrics(_args: any): any
		return { Ok = true, T = os.clock(), Metrics = Metrics.Get(), Status = Health.GetStatus() }
	end

	function handlers.GetStatusInfo(_args: any): any
		return { Ok = true, Status = Health.GetStatus(), History = statusHistory }
	end

	function handlers.SimulateStatus(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		local status = tostring(args.Status)
		if status ~= "Healthy" and status ~= "Degraded" and status ~= "Outage" then
			return { Ok = false, Error = `invalid status "{status}"` }
		end
		Log.Warn("Lifecycle", "SIM_STATUS", `Scribe Studio forcing service status {status}`, { To = status })
		Health.AdoptBroadcast(status :: any)
		if status == "Healthy" then
			table.clear(armedLoadFailures)
		end
		return { Ok = true, Status = Health.GetStatus() }
	end

	function handlers.SimulateLoadFailure(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		local userId = tonumber(args.UserId) or 0
		local key = ctx.Persistence.KeyFor(userId)
		ensureStoreWrap()
		armedLoadFailures[key] = tonumber(args.Failures) or 3
		Log.Warn("Persistence", "SIM_LOAD_FAILURE", "Scribe Studio armed simulated load failures", {
			UserId = userId,
			Failures = armedLoadFailures[key],
		})

		local entry = entryForUserId(userId)
		if not entry then
			return { Ok = true, Note = "armed for the next session load (no active session)" }
		end
		local player = entry.Player
		local profile: any = entry.Profile
		if profileIsActive(profile) then
			-- Without this flag Persistence classifies the OnSessionEnd as an external
			-- steal and skips the final save's bookkeeping. SimulateSessionSteal omits it
			-- deliberately, since a steal is what that simulation exercises.
			entry.LocalSessionEnd = true
			profile:EndSession()
		end
		-- Re-run the load path against the armed store so LoadFailurePolicy is
		-- actually exercised (only possible if the player wasn't kicked).
		task.delay(0.4, function()
			if player.Parent == Players and not ctx.Persistence.Entries[player] then
				ctx.Persistence.OnPlayerAdded(player)
			end
		end)
		return {
			Ok = true,
			Note = if options.KickOnSessionEnd ~= false
				then "session ended; with default KickOnSessionEnd the player is kicked — set KickOnSessionEnd=false to watch the reload loop"
				else "session ended; reload will hit the armed failures",
		}
	end

	function handlers.SimulateSessionSteal(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		local entry = entryForUserId(tonumber(args.UserId) or 0)
		if not entry then
			return { Ok = false, Error = "no session for that UserId" }
		end
		Log.Warn(
			"Persistence",
			"SIM_SESSION_STEAL",
			"Scribe Studio simulating a session steal",
			{ UserId = entry.UserId }
		)
		local profile: any = entry.Profile
		if profileIsActive(profile) then
			profile:EndSession()
			return { Ok = true }
		end
		return { Ok = false, Error = "profile is not active" }
	end

	function handlers.GetConfig(_args: any): any
		local products = {}
		for name, config in (options.Products or {}) :: { [string]: any } do
			products[name] = {
				Id = config.Id,
				Category = config.Category,
				Grants = config.Grants,
				HasGrantCallback = type(config.Grant) == "function",
			}
		end
		local passes = {}
		for name, config in (options.Passes or {}) :: { [string]: any } do
			passes[name] = { Id = config.Id, Category = config.Category }
		end
		return {
			Ok = true,
			Mode = ctx.Persistence.Mode,
			UseMock = ctx.Persistence.Mode == "Mock",
			DontSave = ctx.Persistence.Mode == "Mock",
			-- Where profiles live, so the plugin's Production panel can lock
			-- its target to the real store instead of asking the user.
			ProfileStoreIndex = options.ProfileStoreIndex or "Default",
			ProfileKeyPrefix = options.ProfileKeyPrefix or "PLAYER_",
			LoadFailurePolicy = options.LoadFailurePolicy or "Kick",
			KickOnSessionEnd = options.KickOnSessionEnd ~= false,
			BoundsPolicy = options.BoundsPolicy or "Clamp",
			WipeGuardPolicy = options.WipeGuardPolicy or "Warn",
			NoGiftIntentPolicy = options.NoGiftIntentPolicy or "GrantOrCredit",
			GiftIntentTTL = options.GiftIntentTTL or 3600,
			Products = products,
			Passes = passes,
			Perks = options.Perks or {},
		}
	end

	function handlers.GetMonetization(args: any): any
		local entry = entryForUserId(tonumber(args.UserId) or 0)
		local liveData: any = if entry then entry.LiveData else nil
		if not entry or entry.State ~= "Ready" or liveData == nil then
			return { Ok = false, Error = "no Ready session for that UserId" }
		end
		local reserved: { [string]: any } = (liveData :: any)[Template.RESERVED_ROOT]
		if type(reserved) ~= "table" then
			reserved = {}
		end
		local logs: { [string]: any } = if type(reserved.PurchaseLogs) == "table" then reserved.PurchaseLogs else {}
		local function tableOrEmpty(value: any): { [any]: any }
			return if type(value) == "table" then Util.deepClone(value) else {}
		end
		return {
			Ok = true,
			WallClock = os.time(),
			Perks = tableOrEmpty(reserved.Perks),
			PendingGifts = tableOrEmpty(reserved.PendingGifts),
			GiftCredits = tableOrEmpty(reserved.GiftCredits),
			Robux = tableOrEmpty(logs.Robux),
			InGame = tableOrEmpty(logs.InGame),
			ProcessedCount = if type(reserved.ProcessedPurchaseIds) == "table"
				then #reserved.ProcessedPurchaseIds
				else 0,
		}
	end

	function handlers.GrantPerk(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		local entry = entryForUserId(tonumber(args.UserId) or 0)
		if not entry then
			return { Ok = false, Error = "no session for that UserId" }
		end
		local ok, err = studioCall(Data.GrantPerk, entry.Player, tostring(args.Key))
		return if ok then { Ok = true } else { Ok = false, Error = tostring(err) }
	end

	function handlers.RevokePerk(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		local entry = entryForUserId(tonumber(args.UserId) or 0)
		if not entry then
			return { Ok = false, Error = "no session for that UserId" }
		end
		local ok, err = studioCall(Data.RevokePerk, entry.Player, tostring(args.Key))
		return if ok then { Ok = true } else { Ok = false, Error = tostring(err) }
	end

	function handlers.PromptGift(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		local entry = entryForUserId(tonumber(args.BuyerUserId) or 0)
		if not entry then
			return { Ok = false, Error = "no session for the buyer UserId" }
		end
		local ok, granted, reason =
			studioCall(Data.PromptGift, entry.Player, tostring(args.ProductName), tonumber(args.RecipientUserId) or 0)
		if not ok then
			return { Ok = false, Error = tostring(granted) }
		end
		return { Ok = granted == true, Error = reason }
	end

	function handlers.InjectReceipt(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		-- The resolved mode, not the legacy UseMock flag: Mode never reaches options, so
		-- gating on UseMock refuses injection on a Mode = "Mock" bundle.
		if ctx.Persistence.Mode ~= "Mock" then
			return {
				Ok = false,
				Error = 'receipt injection requires Mode = "Mock" (or the legacy UseMock), matching the core\'s testing posture: no real store is ever touched',
			}
		end
		local receipt = args.ReceiptInfo
		if type(receipt) ~= "table" then
			return { Ok = false, Error = "ReceiptInfo table required" }
		end
		Log.Warn("Monetization", "SIM_RECEIPT", "Scribe Studio injecting a mock receipt", {
			PurchaseId = tostring(receipt.PurchaseId),
			ProductId = tonumber(receipt.ProductId),
		})
		local ok, decision = studioCall(Data.HandleReceipt, receipt)
		if not ok then
			return { Ok = false, Error = tostring(decision) }
		end
		local name = if typeof(decision) == "EnumItem" then (decision :: EnumItem).Name else tostring(decision)
		return { Ok = true, Decision = name }
	end

	-- Command console -----------------------------------------------------------

	function handlers.ListCommands(_args: any): any
		local commands = {}
		for _, record in commandRegistry do
			table.insert(commands, {
				Name = record.Name,
				Args = if record.Args then table.clone(record.Args) else nil,
			})
		end
		table.sort(commands, function(a: any, b: any)
			return a.Name < b.Name
		end)
		return { Ok = true, Commands = commands }
	end

	function handlers.InvokeCommand(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		local record = commandRegistry[tostring(args.Name)]
		if record == nil then
			return { Ok = false, Error = `unknown command "{tostring(args.Name)}"` }
		end
		local entry = entryForUserId(tonumber(args.UserId) or 0)
		if not entry or entry.State ~= "Ready" then
			return { Ok = false, Error = "no Ready session for that UserId" }
		end
		local commandArgs: { any } = if type(args.Args) == "table" then args.Args :: any else {}
		local argCount = tonumber(args.ArgCount) or #commandArgs
		Log.Info("Commands", "SIM_COMMAND", `Scribe Studio invoking command "{record.Name}"`, {
			Player = entry.Player,
			Command = record.Name,
		})
		local results = table.pack(studioCall(record.Handler, entry.Player, table.unpack(commandArgs, 1, argCount)))
		local ok = results[1]
		if not ok then
			return { Ok = false, Error = tostring(results[2]) }
		end
		local returns = table.create(results.n - 1)
		for i = 2, results.n do
			returns[i - 1] = results[i]
		end
		return { Ok = true, Results = returns, ResultCount = results.n - 1 }
	end

	-- Leaderboards ---------------------------------------------------------------

	function handlers.GetLeaderboards(_args: any): any
		local boards = {}
		for name, config in (options.Leaderboards or {}) :: { [string]: any } do
			local entries = {}
			pcall(function()
				entries = ctx.Leaderboards.GetLeaderboard(name, config.Limit)
			end)
			local myRanks = {}
			for _, entry in ctx.Persistence.Entries do
				local rank = nil
				pcall(function()
					rank = ctx.Leaderboards.GetMyRank(entry.Player, name)
				end)
				if rank ~= nil then
					myRanks[tostring(entry.UserId)] = rank
				end
			end
			table.insert(boards, {
				Name = name,
				Stat = config.Stat,
				Limit = config.Limit or 100,
				Scale = config.Scale or 1,
				Replicate = config.Replicate == true,
				Entries = entries,
				MyRanks = myRanks,
			})
		end
		table.sort(boards, function(a: any, b: any)
			return a.Name < b.Name
		end)
		return {
			Ok = true,
			Boards = boards,
			QueueDepth = tonumber(Metrics.Get().LbQueueDepth) or 0,
		}
	end

	function handlers.RefreshLeaderboards(args: any): any
		local ok, err = pcall(function()
			ctx.Leaderboards.RefreshNow(if args.Name then tostring(args.Name) else nil)
		end)
		return if ok then { Ok = true } else { Ok = false, Error = tostring(err) }
	end

	function handlers.FlushLeaderboards(_args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		Log.Info("Leaderboards", "SIM_LB_FLUSH", "Scribe Studio draining the leaderboard write queue", {})
		local ok, err = pcall(function()
			ctx.Leaderboards.FlushAllBlocking(5)
		end)
		return if ok then { Ok = true } else { Ok = false, Error = tostring(err) }
	end

	-- Template defaults (player comparison baseline) ------------------------------

	function handlers.GetDefaults(_args: any): any
		return {
			Ok = true,
			Persistent = Template.BuildDefaults(compiled, "Persistent"),
			Session = Template.BuildDefaults(compiled, "Session"),
		}
	end

	function handlers.Snapshot(args: any): any
		local entry = entryForUserId(tonumber(args.UserId) or 0)
		if not entry or entry.State ~= "Ready" or not entry.LiveData then
			return { Ok = false, Error = "no Ready session for that UserId" }
		end
		return {
			Ok = true,
			UserId = entry.UserId,
			Name = entry.Player.Name,
			Data = Util.deepClone(entry.LiveData),
			Session = Util.deepClone(entry.SessionStore or {}),
		}
	end

	function handlers.Flush(args: any): any
		local gate = requireWrites()
		if gate then
			return { Ok = false, Error = gate }
		end
		local entry = entryForUserId(tonumber(args.UserId) or 0)
		if not entry then
			return { Ok = false, Error = "no session for that UserId" }
		end
		local ok = Data.Flush(entry.Player, if args.Force then { Force = true } else nil)
		return { Ok = ok == true, Error = if ok then nil else "flush did not confirm" }
	end

	-- Dispatch -------------------------------------------------------------------

	requestFn.OnInvoke = function(name: any, encodedArgs: any): string
		local response: any
		Util.safeCall(function(err)
			response = { Ok = false, Error = tostring(err) }
		end, function()
			local handler = handlers[tostring(name)]
			if not handler then
				response = { Ok = false, Error = `unknown command "{tostring(name)}"` }
				return
			end
			local args: any = {}
			if type(encodedArgs) == "string" and #encodedArgs > 0 then
				args = decode(encodedArgs)
			end
			response = handler(if type(args) == "table" then args else {})
		end)
		return encode(response)
	end

	container.Parent = ServerStorage

	-- Record from game boot, not from the first plugin handshake: the op ring, old-value
	-- mirrors and status history must exist before any plugin attaches. Parent the
	-- container first, because the pump loop exits when container.Parent is nil.
	installWraps()

	-- Restore simulated state on teardown; Studio destroys the DataModel anyway.
	game:BindToClose(function()
		table.clear(armedLoadFailures)
	end)

	return detach
end

return DebugHook
