--!strict
-- Client assembly: local mirror tree, Hello/Init handshake, diff
-- application, command RPC, leaderboard/status/shared mirrors, and the
-- always-on edit-mode fallback with mock helpers.

local RunService = game:GetService("RunService")

local Internal = script.Parent.Internal
local Util = require(Internal.Util)
local Node = require(Internal.Node)
local Wire = require(Internal.Wire)
local Template = require(Internal.Template)
local TransportModule = require(Internal.Transport)
local Version = require(Internal.Version)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)
local Signal = require(Internal.Signal)

local Client = {}

local ID_TO_STATUS: { [number]: string } = { [0] = "Healthy", [1] = "Degraded", [2] = "Outage" }

-- Applies a decoded op to a plain table (other players' Shared mirrors).
local function applyPlainOp(root: { [any]: any }, op: Wire.Op)
	local container: any = root
	for i = 1, #op.Path - 1 do
		local segment = op.Path[i]
		local nextContainer = container[segment]
		if type(nextContainer) ~= "table" then
			if op.Kind == "Remove" then
				return -- array removals always ship alongside their creating Insert
			end
			-- Materialize intermediates for Set (any value) and Clear too: the
			-- server only emits an op when the parent chain existed at emission, so
			-- a missing parent here means its creating op was coalesced away in the
			-- same flush while the server still holds the (possibly empty)
			-- container. Creating it keeps existence parity with the server.
			nextContainer = {}
			container[segment] = nextContainer
		end
		container = nextContainer
	end
	local key = op.Path[#op.Path]
	if op.Kind == "Set" then
		container[key] = op.Value
	elseif op.Kind == "Insert" then
		local arr = container[key]
		if type(arr) ~= "table" then
			arr = {}
			container[key] = arr
		end
		table.insert(arr, math.clamp(op.Index or #arr + 1, 1, #arr + 1), op.Value)
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
			-- A Clear only emits for a container that existed server-side; if its
			-- creating op was coalesced away, materialize the cleared {} here.
			container[key] = {}
		end
	end
end

function Client.new(options: any, compiled: Template.Compiled): any
	local isRunning = RunService:IsRunning()
	local editMode = not isRunning

	if options.LogLevel then
		Log.SetLevel(options.LogLevel)
	end

	local mirror: { [string]: any } = Template.BuildDefaults(compiled, "Client")
	local loaded = editMode
	local loadedSignal = Signal.new()

	local tree = Node.NewTree({
		Compiled = compiled,
		Stores = { Persist = mirror, Session = mirror },
		IsServer = false,
		Label = "LocalPlayer",
		OnOp = nil, -- client writes are local-only
		OnAnomaly = nil,
		BoundsPolicy = options.BoundsPolicy or "Clamp",
		DevMode = RunService:IsStudio(),
		TimedHooks = {
			-- Timed internals are server-only; the client sees the value.
			SetTimed = function()
				error("Scribe: SetTimed is server-only", 3)
			end,
			ExtendTimed = function()
				error("Scribe: ExtendTimed is server-only", 3)
			end,
			Active = function(accessor: any): (boolean, number?)
				local value = accessor.Get()
				return value ~= nil and value ~= false, nil
			end,
		},
		OnEconomy = nil,
		LogError = function(message)
			Log.Error("Lifecycle", "LISTENER_ERROR", message, {})
		end,
	})

	local sharedMirrors: { [number]: { [string]: any } } = {}
	local leaderboardCache: { [string]: { Entries: { any }, MyRank: number?, MyScore: number? } } = {}
	local mockCommands: { [string]: (...any) -> ...any } = {}
	local mockLeaderboards: { [string]: { any } } = {}

	local OnServiceStatus = Signal.new()
	local OnSharedChanged = Signal.new()
	local OnOwnershipChanged = Signal.new()
	local OnLeaderboard = Signal.new()

	local transport: any = nil
	local requestWaiters: { [number]: thread } = {}
	local nextCorrelation = 0

	local function waitForLoaded()
		while not loaded do
			loadedSignal:Wait()
		end
	end

	-- Frame handling ------------------------------------------------------------------

	local helloSendFailLogged = false
	local function sendHello()
		if not transport then
			return
		end
		local w = Wire.NewWriter(8)
		Wire.U8(w, Wire.Frames.Hello)
		Wire.U32(w, compiled.Hash % 4294967296)
		Wire.U8(w, Wire.PROTOCOL_VERSION)
		local ok, err = pcall(function()
			transport:SendToServer(Wire.Finish(w))
		end)
		-- A dropped Hello leaves the client stuck at defaults (the server logs
		-- CLIENT_HANDSHAKE_TIMEOUT), so surface the underlying send error once
		-- instead of retrying it silently forever. A Sandboxed Scribe fails here
		-- ("cannot fire ... the calling thread is sandboxed").
		if not ok and not helloSendFailLogged then
			helloSendFailLogged = true
			Log.Warn("Transport", "SEND_FAIL", `client could not send its Hello handshake: {tostring(err)}`, {})
		end
	end

	local function applyInit(reader: Wire.Reader)
		local ops = Wire.DecodeOps(reader, compiled)
		-- The snapshot supersedes local state: reset to defaults, then apply.
		local defaults = Template.BuildDefaults(compiled, "Client")
		-- Do the reset + apply INSIDE ReplayFire so that on a re-Init (a second
		-- snapshot after a resync) Changed listeners see their true pre-snapshot
		-- value as `old`. ReplayFire snapshots olds before running this closure;
		-- resetting the mirror outside it would make every `old` the default.
		tree:ReplayFire(function()
			table.clear(mirror)
			for key, value in defaults do
				mirror[key] = value
			end
			for _, op in ops do
				tree:ApplyOp(op)
			end
		end)
		if not loaded then
			loaded = true
			loadedSignal:Fire()
		end
		Log.Debug("Replication", "INIT_APPLIED", "initial snapshot applied", {})
	end

	local function handleFrame(bytes: buffer)
		local reader = Wire.NewReader(bytes)
		local frameType = Wire.RU8(reader)

		if frameType == Wire.Frames.Init then
			applyInit(reader)
		elseif frameType == Wire.Frames.Diff then
			if not loaded then
				-- Op before Init is a protocol error: request a re-Init.
				Log.Warn("Replication", "OP_BEFORE_INIT", "diff arrived before Init; requesting re-Init", {})
				sendHello()
				return
			end
			local ops = Wire.DecodeOps(reader, compiled)
			for _, op in ops do
				tree:ApplyOp(op)
			end
			Metrics.Add("DiffsApplied")
		elseif frameType == Wire.Frames.CommandReply then
			local correlation = Wire.RU32(reader)
			local ok = Wire.RU8(reader) == 1
			local count = Wire.RU8(reader)
			local results = table.create(count)
			for i = 1, count do
				results[i] = Wire.DecodeGeneric(reader)
			end
			local thread = requestWaiters[correlation]
			if thread then
				requestWaiters[correlation] = nil
				if ok then
					-- Transparent RPC: the handler's return values ARE the
					-- Request results`).
					task.spawn(thread, table.unpack(results, 1, count))
				else
					task.spawn(thread, false, results[1])
				end
			end
		elseif frameType == Wire.Frames.Status then
			local status = ID_TO_STATUS[Wire.RU8(reader)] or "Healthy"
			Health.AdoptBroadcast(status :: any)
			OnServiceStatus:Fire(status)
		elseif frameType == Wire.Frames.SharedInit or frameType == Wire.Frames.SharedDiff then
			local userId = Wire.RF64(reader)
			local ops = Wire.DecodeOps(reader, compiled)
			local shared: { [string]: any } = sharedMirrors[userId] or {}
			if frameType == Wire.Frames.SharedInit then
				shared = {}
			end
			sharedMirrors[userId] = shared
			for _, op in ops do
				applyPlainOp(shared, op)
			end
			-- One event per update carrying the current shared data (a clone, so
			-- listeners can't mutate the mirror); nil is reserved for SharedGone.
			-- CloneUnpack also converts any datatype fields from their packed wire
			-- buffer back to the real datatype (the Shared mirror has no accessor
			-- tree to do this on read). Only pay for that full-mirror unpack+clone
			-- when something is actually listening: a game that reads Shared data via
			-- Data.GetShared (pull) instead of OnSharedChanged (push) then skips it.
			if OnSharedChanged:HasListeners() then
				OnSharedChanged:Fire(userId, Node.CloneUnpack(compiled.Root, shared))
			end
		elseif frameType == Wire.Frames.SharedGone then
			local userId = Wire.RF64(reader)
			sharedMirrors[userId] = nil
			OnSharedChanged:Fire(userId, nil)
		elseif frameType == Wire.Frames.Leaderboard then
			local name = Wire.RStr(reader)
			local count = Wire.RU8(reader)
			local entries = table.create(count)
			for rank = 1, count do
				local userId = Wire.RF64(reader)
				local displayName = Wire.RStr(reader)
				local score = Wire.RF64(reader)
				table.insert(entries, { Rank = rank, UserId = userId, Name = displayName, Score = score })
			end
			local cache: { Entries: { any }, MyRank: number?, MyScore: number? } =
				{ Entries = entries, MyRank = nil, MyScore = nil }
			if Wire.RU8(reader) == 1 then
				cache.MyRank = Wire.RVarint(reader)
				cache.MyScore = Wire.RF64(reader)
			end
			leaderboardCache[name] = cache
			OnLeaderboard:Fire(name)
		end
	end

	-- Studio-only client debug hook for the Scribe Studio plugin's client
	-- view. Attached before the transport connects so the Init snapshot
	-- application is captured too. Read-only by construction; outside Studio
	-- the branch is never taken and the hook does not exist.
	if isRunning and RunService:IsStudio() and RunService:IsClient() then
		local hookOk, hookErr = pcall(function()
			(require(script.DebugHook) :: any).Attach({
				Compiled = compiled,
				Mirror = mirror,
				Tree = tree,
				IsLoaded = function()
					return loaded
				end,
			})
		end)
		if not hookOk then
			Log.Warn("Lifecycle", "DEBUG_HOOK_FAIL", tostring(hookErr), {})
		end
	end

	if isRunning then
		task.spawn(function()
			transport = TransportModule.Resolve(options.Transport, options.TransportChannel)
			transport:ListenClient(function(bytes: buffer)
				local ok, err = pcall(handleFrame :: any, bytes)
				if not ok then
					Log.Warn("Transport", "MALFORMED_FRAME", tostring(err), {})
				end
			end)
			-- Hello retries cover server-side races and custom adapters that
			-- connect late.
			sendHello()
			local delaySeconds = 2
			while not loaded do
				task.wait(delaySeconds)
				if loaded then
					break
				end
				sendHello()
				delaySeconds = math.min(delaySeconds * 1.5, 10)
			end
		end)
	end

	-- Public API -----------------------------------------------------------------------

	--[=[
		@class Client

		The client-side data API: `bundle.Client`. Read the local player's data
		through the same accessor tree as the server (`Data.Coins.Get()`,
		`Data.Coins.Observe(fn)`); those methods are documented on the [Value]
		class. Writes are **local-only** (optimistic UI). Server ops always win.
		To change data authoritatively, call a server command via [Client.Request].

		In edit mode (when `RunService:IsRunning()` is false, e.g. a storybook)
		the client skips the transport and initializes instantly to template
		defaults, so components render without a running server.
	]=]
	local Data = {} :: any

	--[=[
		@within Client
		@tag Lifecycle
		@client
		@return boolean
		Whether the first Init snapshot has arrived (non-yielding). Before this is
		true, accessor reads return template defaults. Always `true` in edit mode.
	]=]
	function Data.IsReady(): boolean
		return loaded
	end

	--[=[
		@within Client
		@tag Lifecycle
		@client
		@yields
		@param timeout number?
		@return boolean
		Yields until the first Init snapshot arrives, then returns `true`. Returns
		`false` if `timeout` seconds (default 30) pass first. It never hangs. Use
		it to gate startup logic; for reactive UI prefer `Observe`/`Changed`.

		```lua
		if Data.WaitForData() then
		    showMainMenu(Data.Coins.Get())
		end
		```
	]=]
	function Data.WaitForData(timeout: number?): boolean
		if loaded then
			return true
		end
		local thread = coroutine.running()
		local settled = false
		local function resume(result: boolean)
			if not settled then
				settled = true
				task.spawn(thread, result)
			end
		end
		local conn = loadedSignal:Connect(function()
			resume(true)
		end)
		task.delay(timeout or 30, function()
			resume(false)
		end)
		local result = coroutine.yield()
		conn:Disconnect()
		return result
	end

	--[=[
		@within Client
		@tag Commands
		@client
		@yields
		@param name string
		@param ... any
		@return ...any
		Calls a server command registered with [Server.Command] and returns its
		results. Yields until the reply arrives (or times out → `false, "timeout"`).
		This is the one way clients change data authoritatively.
	]=]
	function Data.Request(name: string, ...: any): ...any
		if editMode then
			local mock = mockCommands[name]
			if mock then
				local args = table.pack(...)
				local results
				local ok = pcall(function()
					results = table.pack(mock(table.unpack(args, 1, args.n)))
				end)
				if ok and results then
					return table.unpack(results, 1, results.n)
				end
				return false, "mock-error"
			end
			return false, "edit-mode"
		end
		waitForLoaded()
		if not transport then
			return false, "no-transport"
		end
		nextCorrelation = (nextCorrelation + 1) % 4294967296
		local correlation = nextCorrelation
		local args = table.pack(...)
		-- Fail loud rather than clamping: a silent clamp here would drop the extras
		-- before the server ever saw them, so the handler would run with missing
		-- trailing arguments instead of the server's "too many command arguments".
		if args.n > Wire.MAX_COMMAND_ARGS then
			error(`Scribe: a command takes at most {Wire.MAX_COMMAND_ARGS} arguments (got {args.n})`, 2)
		end
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.Command)
		Wire.U32(w, correlation)
		Wire.Str(w, name)
		Wire.U8(w, args.n)
		for i = 1, args.n do
			Wire.EncodeGeneric(w, args[i])
		end

		local thread = coroutine.running()
		requestWaiters[correlation] = thread
		task.delay(options.RequestTimeout or 10, function()
			if requestWaiters[correlation] == thread then
				requestWaiters[correlation] = nil
				task.spawn(thread, false, "timeout")
			end
		end)
		-- Deferred so the requester is already suspended when a synchronous
		-- (loopback) transport delivers the reply.
		local bytes = Wire.Finish(w)
		task.defer(function()
			local ok = pcall(function()
				transport:SendToServer(bytes)
			end)
			if not ok and requestWaiters[correlation] == thread then
				requestWaiters[correlation] = nil
				task.spawn(thread, false, "send-failed")
			end
		end)
		return coroutine.yield()
	end

	--[=[
		@within Client
		@tag Leaderboards
		@client
		@param name string
		@param limit number?
		@return { LeaderboardEntry }
		The cached top-N of a **replicated** board (`Replicate = true`), streamed
		to clients at handshake and on change. Empty for server-only boards.
	]=]
	function Data.GetLeaderboard(name: string, limit: number?): { any }
		if editMode then
			local mocked = mockLeaderboards[name]
			return if mocked then Util.deepClone(mocked) else {}
		end
		local cache = leaderboardCache[name]
		if not cache then
			return {}
		end
		local out = {}
		for i = 1, math.min(limit or #cache.Entries, #cache.Entries) do
			table.insert(out, table.clone(cache.Entries[i]))
		end
		return out
	end

	--[=[
		@within Client
		@tag Leaderboards
		@client
		@param name string
		@return number?
		The local player's rank on a replicated board, or `nil` if unranked.
	]=]
	function Data.GetMyRank(name: string): number?
		local cache = leaderboardCache[name]
		return if cache then cache.MyRank else nil
	end

	--[=[
		@within Client
		@tag Leaderboards
		@client
		@prop OnLeaderboard Signal
		Fires `(boardName, entries)` whenever a replicated board updates.
	]=]
	Data.OnLeaderboard = OnLeaderboard

	--[=[
		@within Client
		@tag Service
		@client
		@return "Healthy" | "Degraded" | "Outage"
		The replicated data-service health. Show players a "progress may save
		late" notice during a `"Degraded"`/`"Outage"`.
	]=]
	function Data.GetServiceStatus(): string
		return Health.GetStatus()
	end

	--[=[
		@within Client
		@tag Service
		@client
		@prop OnServiceStatus Signal
		Fires with the new status whenever service health changes.
	]=]
	Data.OnServiceStatus = OnServiceStatus

	--[=[
		@within Client
		@tag Shared Data
		@client
		@param playerOrUserId Player | number
		@return { [string]: any }?
		Reads another player's `Scribe.Shared` roots (public info replicated to
		everyone), or `nil` if not yet received.
	]=]
	function Data.GetShared(playerOrUserId: Player | number): { [string]: any }?
		local userId = if typeof(playerOrUserId) == "Instance"
			then (playerOrUserId :: Player).UserId
			else playerOrUserId :: number
		local shared = sharedMirrors[userId]
		-- CloneUnpack converts packed datatype buffers (wire form) back to the real
		-- datatype; the Shared mirror has no accessor tree to do it on read.
		return if shared then Node.CloneUnpack(compiled.Root, shared) else nil
	end

	--[=[
		@within Client
		@tag Shared Data
		@client
		@prop OnSharedChanged Signal
		Fires `(userId, sharedData)` when another player's Shared data changes.
	]=]
	Data.OnSharedChanged = OnSharedChanged
	--[=[
		@within Client
		@tag Ownership
		@client
		@prop OnOwnershipChanged Signal
		Fires `(key, owned)` whenever the local player's ownership of a pass or perk
		actually changes. Ownership already held at load is the baseline and does not
		fire. Use [Client.ObserveOwned] instead when you care about one specific key
		and want the current value immediately.
	]=]
	Data.OnOwnershipChanged = OnOwnershipChanged

	-- Ownership: reads the replicated mirror.
	local function ownsFromMirror(key: string): boolean
		local reserved = mirror[Template.RESERVED_ROOT]
		if type(reserved) == "table" and type(reserved.Perks) == "table" and reserved.Perks[key] == true then
			return true
		end
		local session = mirror[Template.SESSION_ROOT]
		if type(session) == "table" and type(session.OwnsCache) == "table" and session.OwnsCache[key] == true then
			return true
		end
		return false
	end

	--[=[
		@within Client
		@tag Ownership
		@client
		@yields
		@param key string
		@return boolean
		Whether the local player owns a perk or pass, from the replicated mirror.
		Yields until data has loaded.
	]=]
	function Data.Owns(key: string): boolean
		if not editMode then
			waitForLoaded()
		end
		return ownsFromMirror(key)
	end

	local function ownsSyncedFromMirror(): boolean
		local session = mirror[Template.SESSION_ROOT]
		return type(session) == "table" and session.OwnsSynced == true
	end

	--[=[
		@within Client
		@tag Ownership
		@client
		@yields
		@param key string
		@param timeout number?
		@return boolean
		Like [Client.Owns], but **yields until the server has finished syncing
		ownership** (the initial async gamepass refresh, signalled by a replicated
		flag). Use it so a genuinely-owned pass is never briefly reported un-owned in
		the window right after join. Perks/gifts are already synced at load. Falls
		back to the current mirror value after `timeout` seconds (default 10).
	]=]
	function Data.OwnsAsync(key: string, timeout: number?): boolean
		if editMode then
			return ownsFromMirror(key)
		end
		waitForLoaded()
		if not ownsSyncedFromMirror() then
			local thread = coroutine.running()
			local settled = false
			local disconnect: (() -> ())? = nil
			local function wake()
				if not settled then
					settled = true
					if disconnect then
						disconnect()
					end
					task.spawn(thread)
				end
			end
			disconnect = tree.Accessor[Template.SESSION_ROOT].OwnsSynced.Changed(function(v)
				if v == true then
					wake()
				end
			end)
			task.delay(timeout or 10, wake)
			-- If the flag arrived between the check and the connect, clean up and
			-- skip the yield -- never task.spawn a thread that has not yielded.
			if ownsSyncedFromMirror() then
				settled = true
				if disconnect then
					disconnect()
				end
			else
				coroutine.yield()
			end
		end
		return ownsFromMirror(key)
	end

	-- Drives OnOwnershipChanged. Mirrors ObserveOwned's dedupe, but across every key
	-- the mirror actually holds, so a listener does not have to know keys up front.
	local ownsLast: { [string]: boolean } = {}
	local ownsWatched = false
	local function scanOwnership(silent: boolean?)
		local candidates: { [string]: boolean } = {}
		local reserved = mirror[Template.RESERVED_ROOT]
		if type(reserved) == "table" and type(reserved.Perks) == "table" then
			for key in reserved.Perks do
				candidates[key] = true
			end
		end
		local session = mirror[Template.SESSION_ROOT]
		if type(session) == "table" and type(session.OwnsCache) == "table" then
			for key in session.OwnsCache do
				candidates[key] = true
			end
		end
		-- Keys that went away still need a false transition.
		for key in ownsLast do
			candidates[key] = true
		end
		for key in candidates do
			local owned = ownsFromMirror(key)
			if owned ~= (ownsLast[key] == true) then
				ownsLast[key] = owned
				if not silent then
					OnOwnershipChanged:Fire(key, owned)
				end
			end
		end
	end
	-- Attached lazily on first subscribe: a game that never listens pays nothing.
	local function ensureOwnershipWatched()
		if ownsWatched or editMode then
			return
		end
		ownsWatched = true
		waitForLoaded()
		scanOwnership(true) -- baseline: current ownership is not a "change"
		local accessor = tree.Accessor
		accessor[Template.RESERVED_ROOT].Perks.Changed(function()
			scanOwnership()
		end)
		accessor[Template.SESSION_ROOT].OwnsCache.Changed(function()
			scanOwnership()
		end)
	end

	--[=[
		@within Client
		@tag Ownership
		@client
		@param key string
		@param callback (owned: boolean) -> ()
		@return () -> ()
		Calls `callback` with the current ownership and again whenever it changes.
		Returns a disconnect function. Ideal for reactively toggling "buy" buttons.
	]=]
	function Data.ObserveOwned(key: string, callback: (owned: boolean) -> ()): () -> ()
		if not editMode then
			waitForLoaded()
		end
		local last: boolean? = nil
		local function push()
			local owned = ownsFromMirror(key)
			if owned ~= last then
				last = owned
				task.spawn(callback, owned)
			end
		end
		local accessor = tree.Accessor
		local disconnectPerk = accessor[Template.RESERVED_ROOT].Perks.Changed(push)
		local disconnectCache = accessor[Template.SESSION_ROOT].OwnsCache.Changed(push)
		push()
		return function()
			disconnectPerk()
			disconnectCache()
		end
	end

	--[=[
		@within Client
		@tag Reads
		@client
		@return SaveInfo
		The owner's replicated save state (`{ LastSaveAt, LastResult, Dirty, Size }`)
		for "Saving… / Saved ✓" UI. `Size` is the approximate byte size of the last
		successful save (nil before the first).
	]=]
	function Data.GetSaveInfo(): { [string]: any }
		if not editMode then
			waitForLoaded()
		end
		local session = mirror[Template.SESSION_ROOT]
		local info = if type(session) == "table" then session.SaveInfo else nil
		return if type(info) == "table" then Util.deepClone(info) else { Dirty = false }
	end

	--[=[
		@within Client
		@tag Monetization
		@client
		@return { [string]: number }
		The local player's unassigned gift credits by product name.
	]=]
	function Data.GetGiftCredits(): { [string]: number }
		if not editMode then
			waitForLoaded()
		end
		local reserved = mirror[Template.RESERVED_ROOT]
		local credits = if type(reserved) == "table" then reserved.GiftCredits else nil
		return if type(credits) == "table" then Util.deepClone(credits) else {}
	end

	--[=[
		@within Client
		@tag Monetization
		@client
		@param filter { Kind: ("Robux" | "InGame")?, Category: string?, ItemId: string?, Since: number?, Limit: number? }?
		@return { table }
		The local player's purchase history for history UI. Only returned if the
		game opts into replicating purchase logs (`PurchaseLog.ReplicateRobux`).
	]=]
	function Data.GetPurchases(filter: { [string]: any }?): { { [string]: any } }
		if not editMode then
			waitForLoaded()
		end
		local reserved = mirror[Template.RESERVED_ROOT]
		local logs = if type(reserved) == "table" then reserved.PurchaseLogs else nil
		if type(logs) ~= "table" then
			return {}
		end
		local out = {}
		local function collect(kind: string, ring: any)
			if filter and filter.Kind and filter.Kind ~= kind then
				return
			end
			if type(ring) ~= "table" then
				return
			end
			for _, item in ring do
				if filter then
					if filter.Category and item.Category ~= filter.Category then
						continue
					end
					if filter.ItemId and item.ItemId ~= filter.ItemId then
						continue
					end
					if filter.Since and (tonumber(item.Ts) or 0) < filter.Since then
						continue
					end
				end
				local record = Util.deepClone(item)
				record.Kind = kind
				table.insert(out, record)
			end
		end
		collect("Robux", logs.Robux)
		collect("InGame", logs.InGame)
		table.sort(out, function(a, b)
			return (tonumber(a.Ts) or 0) > (tonumber(b.Ts) or 0)
		end)
		if filter and filter.Limit then
			for i = #out, (filter.Limit :: number) + 1, -1 do
				out[i] = nil
			end
		end
		return out
	end

	-- Edit-mode mocks -------------------------------------------------------------

	local function assertEditMode(what: string)
		if not editMode then
			error(`Scribe: {what} is only available in edit mode (storybooks, command bar)`, 3)
		end
	end

	local function deepMerge(base: any, over: any): any
		if type(base) ~= "table" or type(over) ~= "table" then
			return Util.deepClone(over)
		end
		local out = Util.deepClone(base)
		for key, value in over do
			out[key] = deepMerge(out[key], value)
		end
		return out
	end

	--[=[
		@within Client
		@tag Edit Mode
		@client
		@param values { [string]: any }? -- template fields to seed (deep-merged)
		@param scribeState { Perks: { string }?, GiftCredits: { [string]: number }?, Leaderboards: { [string]: { LeaderboardEntry } }? }?
		Seeds mock data for a storybook / edit mode. **Errors outside edit mode.**
		Use it to render Scribe-backed components with realistic state.
	]=]
	function Data.Mock(values: { [string]: any }?, scribeState: { [string]: any }?)
		assertEditMode("Data.Mock")
		-- Batch the whole-root Sets through ReplayFire so a nested observer
		-- registered before Mock still fires (a plain whole-root Set fires only
		-- the container's Changed, never its descendants').
		tree:ReplayFire(function()
			if values then
				for key, value in values do
					local current = mirror[key]
					tree.Accessor[key].Set(deepMerge(current, value))
				end
			end
			if scribeState then
				local reservedAccessor = tree.Accessor[Template.RESERVED_ROOT]
				if scribeState.Perks then
					for _, perk in scribeState.Perks :: { string } do
						reservedAccessor.Perks[perk].Set(true)
					end
				end
				if scribeState.GiftCredits then
					reservedAccessor.GiftCredits.Set(scribeState.GiftCredits)
				end
				if scribeState.PurchaseLogs then
					local logs = scribeState.PurchaseLogs :: { [string]: any }
					if logs.Robux then
						reservedAccessor.PurchaseLogs.Robux.Set(logs.Robux)
					end
					if logs.InGame then
						reservedAccessor.PurchaseLogs.InGame.Set(logs.InGame)
					end
				end
				if scribeState.Leaderboards then
					for name, entries in scribeState.Leaderboards :: { [string]: { any } } do
						mockLeaderboards[name] = entries
					end
				end
			end
		end)
	end

	--[=[
		@within Client
		@tag Edit Mode
		@client
		@param name string
		@param handler (...any) -> ...any
		Registers a fake handler so [Client.Request] resolves in edit mode without
		a server. **Errors outside edit mode.**
	]=]
	function Data.MockCommand(name: string, handler: (...any) -> ...any)
		assertEditMode("Data.MockCommand")
		mockCommands[name] = handler
	end

	-- Dev-mode misuse guard: a root field named like a client Data API/signal
	-- is silently shadowed by that real key (a real key always wins over
	-- __index), so warn instead of leaving it mysteriously unreadable.
	if RunService:IsStudio() then
		local rootChildren = compiled.Root.Children :: { [string]: any }
		for key in Data do
			if type(key) == "string" and rootChildren[key] then
				Log.Warn(
					"Lifecycle",
					"API_NAME_COLLISION",
					`template root field "{key}" collides with a client Data API name and is unreachable on the client`,
					{}
				)
			end
		end
	end

	-- Data.<rootField> resolves through the mirror tree. Returns the accessor
	-- immediately — reads yield template defaults until the Init snapshot lands,
	-- then Observe/Changed fire with the real values. (A metamethod must never
	-- yield: `Data.Coins` before Init would otherwise error "attempt to yield
	-- across metamethod/C-call boundary".)
	setmetatable(Data :: any, {
		__index = function(_, key: any)
			if type(key) ~= "string" then
				return nil
			end
			return tree.Accessor[key]
		end,
	})

	--[=[
		@within Client
		@tag Reads
		@client
		@prop Raw Client
		The same `Data` object without the typed accessor tree: the untyped
		escape hatch if the type solver ever trips on your template.
	]=]
	Data.Raw = Data

	-- Load banner: one clean line confirming the bundle initialized
	-- (Banner = false to silence).
	if options.Banner ~= false then
		print(`Running Scribe v{Version} by ericplane — client is now initialized`)
	end

	-- Drive OnOwnershipChanged once the first snapshot lands. Two listeners plus a
	-- small scan over the keys the mirror holds, so the cost is negligible.
	task.spawn(ensureOwnershipWatched)

	return Data
end

return Client
