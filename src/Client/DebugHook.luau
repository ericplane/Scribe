--!strict
-- Client-side Studio debug hook: a READ-ONLY view of what this client
-- actually received — the replicated mirror, every applied op from boot
-- (including the Init snapshot), and the adopted service status. The Scribe
-- Studio plugin instance running in the client DataModel attaches to it when
-- Studio is switched to the client view.
--
-- Exists ONLY in Studio play sessions (gated in Client init). No writes,
-- ever: the surface has no mutating command.
--
-- Transport mirrors the server hook: one BindableFunction (request/response)
-- and one BindableEvent (stream digests) under ReplicatedStorage (created
-- client-side, so it never exists on the server or replicates anywhere).

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Internal = script.Parent.Parent.Internal
local StudioCodec = require(Internal.StudioCodec)
local Util = require(Internal.Util)
local Template = require(Internal.Template)
local Health = require(Internal.Health)
local Log = require(Internal.Log)

local ClientDebugHook = {}

-- Versioned independently of the server hook protocol: the two attach
-- separately and evolve at their own pace. Range handshake from day one.
ClientDebugHook.PROTOCOL_VERSION = 1
ClientDebugHook.CONTAINER_NAME = "_ScribeClientDebugHook"

local OPS_FLUSH_HZ = 8
local RECENT_OPS_CAP = 1000
local MAX_BATCH = 512
local MAX_TREE_NODES = 2000

local encode = StudioCodec.Encode
local decode = StudioCodec.Decode

local attached = false

local function readPath(root: any, path: { string | number }): any
	local value: any = root
	for _, segment in path do
		if type(value) ~= "table" then
			return nil
		end
		value = value[segment]
	end
	return value
end

-- deps: { Compiled, Mirror, Tree, IsLoaded: () -> boolean }
function ClientDebugHook.Attach(deps: any)
	if not RunService:IsStudio() then
		return
	end
	if attached or ReplicatedStorage:FindFirstChild(ClientDebugHook.CONTAINER_NAME) then
		Log.Warn("Lifecycle", "DEBUG_HOOK_DUPLICATE", "a Scribe client debug hook already exists; only the first bundle is inspectable", {})
		return
	end
	attached = true

	local compiled = deps.Compiled
	local localPlayer = Players.LocalPlayer

	local subscriptions: { [string]: boolean } = {}
	local pending: { [string]: { any } } = { Ops = {}, Status = {} }
	local statusHistory: { any } = {}

	-- Ops ring: every applied op from boot (circular, oldest evicted).
	local ring: { any } = table.create(RECENT_OPS_CAP)
	local ringCount = 0
	local ringNext = 1
	local opSeq = 0

	local function ringPush(record: any)
		ring[ringNext] = record
		ringNext = ringNext % RECENT_OPS_CAP + 1
		if ringCount < RECENT_OPS_CAP then
			ringCount += 1
		end
	end

	local function ringSnapshotForReplay(): { any }
		local out = table.create(ringCount)
		local start = if ringCount < RECENT_OPS_CAP then 1 else ringNext
		for i = 0, ringCount - 1 do
			local record = table.clone(ring[(start + i - 1) % RECENT_OPS_CAP + 1])
			record.Replay = true
			table.insert(out, record)
		end
		return out
	end

	local container = Instance.new("Folder")
	container.Name = ClientDebugHook.CONTAINER_NAME
	local requestFn = Instance.new("BindableFunction")
	requestFn.Name = "Request"
	requestFn.Parent = container
	local streamEv = Instance.new("BindableEvent")
	streamEv.Name = "Stream"
	streamEv.Parent = container

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
			pending[stream] = bucket
			local ok, err = pcall(function()
				streamEv:Fire(stream, encode(chunk))
			end)
			if not ok then
				Log.Warn("Lifecycle", "DEBUG_HOOK_ERROR", `client hook dropped a {stream} chunk: {tostring(err)}`, {})
			end
		end
		pending[stream] = bucket
	end

	-- Record every applied op (Init snapshot included) BEFORE it mutates the
	-- mirror, so Old is the true pre-op value.
	local origApply = deps.Tree.ApplyOp
	deps.Tree.ApplyOp = function(treeSelf: any, op: any)
		local ok, err = pcall(function()
			-- Old per op kind, matching the server hook's record shape: the
			-- removed ELEMENT for Remove, nil for Insert, the pre-write value
			-- (full contents for Clear) otherwise.
			local old: any = nil
			if op.Kind == "Remove" then
				local arr = readPath(deps.Mirror, op.Path)
				if type(arr) == "table" then
					old = arr[math.clamp(op.Index or #arr, 1, math.max(#arr, 1))]
				end
			elseif op.Kind ~= "Insert" then
				old = readPath(deps.Mirror, op.Path)
			end
			opSeq += 1
			local record = {
				HookSeq = opSeq,
				T = os.clock(),
				UserId = if localPlayer then localPlayer.UserId else 0,
				Kind = op.Kind,
				Path = table.clone(op.Path),
				Index = op.Index,
				Value = if type(op.Value) == "table" or type(op.Value) == "buffer" then Util.deepClone(op.Value) else op.Value,
				Old = if type(old) == "table" or type(old) == "buffer" then Util.deepClone(old) else old,
				Visibility = Template.VisibilityOf(compiled, op.Path),
			}
			ringPush(record)
			queue("Ops", record)
		end)
		if not ok then
			Log.Warn("Lifecycle", "DEBUG_HOOK_ERROR", tostring(err), {})
		end
		return origApply(treeSelf, op)
	end

	-- Genuine transitions only (the raw Status frame re-sends on every Init).
	Health.OnStatusChanged:Connect(function(newStatus: string, oldStatus: string)
		local record = {
			T = os.clock(),
			WallAt = os.time(),
			From = oldStatus,
			To = newStatus,
		}
		table.insert(statusHistory, record)
		if #statusHistory > 100 then
			table.remove(statusHistory, 1)
		end
		queue("Status", record)
	end)

	-- Paged tree pages, same shape as the server hook's ReadTree.
	local function describeValue(value: any, depth: number, budget: { n: number }): any
		budget.n -= 1
		if type(value) ~= "table" then
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
			children[k] = describeValue(v, depth - 1, budget)
		end
		return { Table = true, Count = count, Children = children }
	end

	local function rosterEntry(): { [string]: any }
		return {
			UserId = if localPlayer then localPlayer.UserId else 0,
			Name = if localPlayer then localPlayer.Name else "LocalPlayer",
			DisplayName = if localPlayer then localPlayer.DisplayName else "LocalPlayer",
			State = "Ready",
			HandshakeReady = deps.IsLoaded(),
			Dirty = false,
			QueueDepth = 0,
			Mock = false,
			SizeBytes = Util.approxSize(deps.Mirror),
		}
	end

	-- Command handlers (READ-ONLY — no mutating command exists) ---------------

	local handlers: { [string]: (args: any) -> any } = {}

	function handlers.Handshake(args: any): any
		local major = tonumber(args.ProtocolVersion) or 0
		local minSupported = tonumber(args.MinProtocolVersion) or major
		-- NaN compares false both ways and would slip through the range check.
		if major ~= major or minSupported ~= minSupported then
			major, minSupported = 0, 0
		end
		if ClientDebugHook.PROTOCOL_VERSION < minSupported or ClientDebugHook.PROTOCOL_VERSION > major then
			return {
				Ok = false,
				Error = `protocol mismatch: client hook speaks v{ClientDebugHook.PROTOCOL_VERSION}, plugin speaks v{minSupported}-v{major}`
					.. if major < ClientDebugHook.PROTOCOL_VERSION
						then " — update the Scribe Studio plugin"
						else " — update the Scribe package in this game",
				ProtocolVersion = ClientDebugHook.PROTOCOL_VERSION,
			}
		end
		-- A handshake means a new plugin instance: reset subscriptions so its
		-- first SetSubscriptions replays the boot ring.
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
		return {
			Ok = true,
			ProtocolVersion = ClientDebugHook.PROTOCOL_VERSION,
			ClientView = true,
			ScribeVersion = scribeVersion,
			TemplateHash = compiled.Hash,
			NodeCount = compiled.NodeCount,
			Clock = os.clock(),
			WallClock = os.time(),
			Status = Health.GetStatus(),
			PlaceName = game.Name,
			Loaded = deps.IsLoaded(),
			UserId = if localPlayer then localPlayer.UserId else 0,
			WritesEnabled = false,
			AttributionEnabled = false,
		}
	end

	function handlers.SetSubscriptions(args: any): any
		local had: { [string]: boolean } = {}
		for _, stream in { "Ops", "Status" } do
			had[stream] = subscriptions[stream] == true
			subscriptions[stream] = args[stream] == true
			if not subscriptions[stream] and pending[stream] then
				table.clear(pending[stream])
			end
		end
		if subscriptions.Ops and not had.Ops and ringCount > 0 then
			-- Replay everything applied since boot; records carry HookSeq for
			-- plugin-side dedupe and Replay=true so the plugin keeps them out
			-- of its live tree mirror.
			pending.Ops = ringSnapshotForReplay()
			flushStream("Ops")
		end
		return { Ok = true }
	end

	function handlers.ListPlayers(_args: any): any
		return { Ok = true, Roster = { rosterEntry() } }
	end

	function handlers.ReadTree(args: any): any
		local path: { string | number } = args.Path or {}
		local depth = math.clamp(tonumber(args.Depth) or 2, 1, 6)
		local budget = { n = math.clamp(tonumber(args.MaxNodes) or MAX_TREE_NODES, 50, MAX_TREE_NODES) }
		local page = describeValue(readPath(deps.Mirror, path), depth, budget)
		return { Ok = true, Path = path, Node = page }
	end

	function handlers.GetSchema(_args: any): any
		local nodes = {}
		for id = 0, compiled.NodeCount - 1 do
			local node = compiled.ById[id]
			if node then
				table.insert(nodes, {
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
				})
			end
		end
		return { Ok = true, Hash = compiled.Hash, NodeCount = compiled.NodeCount, Nodes = nodes }
	end

	function handlers.GetStatusInfo(_args: any): any
		return { Ok = true, Status = Health.GetStatus(), History = statusHistory }
	end

	function handlers.Snapshot(_args: any): any
		return {
			Ok = true,
			UserId = if localPlayer then localPlayer.UserId else 0,
			Name = if localPlayer then localPlayer.Name else "LocalPlayer",
			Data = Util.deepClone(deps.Mirror),
			Session = {},
		}
	end

	function handlers.GetDefaults(_args: any): any
		return {
			Ok = true,
			Persistent = Template.BuildDefaults(compiled, "Client"),
			Session = {},
		}
	end

	requestFn.OnInvoke = function(name: string, encodedArgs: string?): string
		local handler = handlers[tostring(name)]
		if handler == nil then
			return encode({ Ok = false, Error = `unknown command "{tostring(name)}" (client hook is read-only)` })
		end
		local response
		local ok, err = pcall(function()
			local args: any = {}
			if type(encodedArgs) == "string" and encodedArgs ~= "" then
				args = decode(encodedArgs)
			end
			response = handler(if type(args) == "table" then args else {})
		end)
		if not ok then
			response = { Ok = false, Error = tostring(err) }
		end
		return encode(response)
	end

	container.Parent = ReplicatedStorage

	-- Digest pump.
	task.spawn(function()
		while container.Parent ~= nil do
			task.wait(1 / OPS_FLUSH_HZ)
			pcall(function()
				flushStream("Ops")
				flushStream("Status")
			end)
		end
	end)
end

return ClientDebugHook
