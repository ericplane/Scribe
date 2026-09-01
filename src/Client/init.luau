--!strict
-- Client assembly: local mirror tree, Hello/Init handshake, diff application,
-- command RPC, leaderboard/status/shared mirrors, and the edit-mode fallback.

local RunService = game:GetService("RunService")

local Internal = script.Parent.Internal
local Util = require(Internal.Util)
local Node = require(Internal.Node)
local Wire = require(Internal.Wire)
local Template = require(Internal.Template)
local TransportModule = require(Internal.Transport)
local DerivedModule = require(Internal.Derived)
local Version = require(Internal.Version)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)
local Signal = require(Internal.Signal)
local Clock = require(script.Parent.Internal.Clock)
local Rng = require(script.Parent.Internal.Rng)
local Sched = require(Internal.Sched)
local Defaults = require(Internal.Defaults)
-- For RequestFailed only: the identity Request appends to its own refusals.
local Types = require(script.Parent.Types)

local Client = {}

-- Test seam: Players.LocalPlayer is read-only in Studio.
local localPlayerProbe: (() -> any)? = nil

function Client.SetLocalPlayerProbe(fn: (() -> any)?)
	localPlayerProbe = fn
end

local function readLocalPlayer(): any
	if localPlayerProbe ~= nil then
		return localPlayerProbe()
	end
	return (game:GetService("Players") :: any).LocalPlayer
end

local ID_TO_STATUS: { [number]: string } = { [0] = "Healthy", [1] = "Degraded", [2] = "Outage" }

-- The placeholder a request slot carries until it is settled. Frozen and shared
-- because it is never read or written; one allocation for the whole module.
local NO_RESULTS: { any } = table.freeze({} :: { any })

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
			-- Materialize intermediates for Set and Clear too: a missing parent means
			-- its creating op was coalesced away in the same flush while the server
			-- still holds the container, so creating it here keeps existence parity.
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
			-- A Clear only emits for a container that existed server-side, so if
			-- its creating op was coalesced away, materialize the cleared {}.
			container[key] = {}
		end
	end
end

function Client.new(options: any, compiled: Template.Compiled): any
	-- Test seams: patching RunService itself is illegal on a real service Instance,
	-- so without these nothing needing edit mode or the Studio hook runs in Studio.
	local isRunning = if options.IsRunning ~= nil then options.IsRunning == true else RunService:IsRunning()
	local devMode = if options.DevMode ~= nil then options.DevMode == true else RunService:IsStudio()
	local editMode = not isRunning

	if options.LogLevel then
		Log.SetLevel(options.LogLevel)
	end
	if options.LogRingSize ~= nil then
		Log.SetRingSize(options.LogRingSize)
	end

	local mirror: { [string]: any } = Template.BuildDefaults(compiled, "Client")
	local loaded = editMode
	local stopped = false
	local loadedSignal = Signal.new()

	local tree = Node.NewTree({
		Compiled = compiled,
		Stores = { Persist = mirror, Session = mirror },
		IsServer = false,
		Label = "LocalPlayer",
		OnOp = nil, -- client writes are local-only
		OnAnomaly = nil,
		BoundsPolicy = options.BoundsPolicy or "Clamp",
		DevMode = devMode,
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
		OnDerivedIssue = function(code, field, detail)
			-- A mismatch means the server computed a different value than this realm,
			-- so the compute function is impure. The server's value wins.
			local report: typeof(Log.Warn) = if code == "DERIVED_MISMATCH" then Log.Warn else Log.Error
			report("Derived", code :: any, `"{field}": {detail}`, { Field = field })
		end,
	})

	local sharedMirrors: { [number]: { [string]: any } } = {}
	-- Derived fields another player's mirror has to compute for itself.
	local function isSharedLocalDerived(node: any): boolean
		return node.Visibility == "Shared" and not node.Derived.Transmit
	end
	local leaderboardCache: { [string]: { Entries: { any }, MyRank: number?, MyScore: number? } } = {}
	local mockCommands: { [string]: (...any) -> ...any } = {}
	local mockLeaderboards: { [string]: { any } } = {}

	local OnServiceStatus = Signal.new()
	local OnSharedChanged = Signal.new()
	local OnOwnershipChanged = Signal.new()
	local OnLeaderboard = Signal.new()

	local transport: any = nil
	-- One in-flight Client.Request. The slot carries the answer, not the resumption:
	-- Sched.Resume is task.spawn, so a synchronous loopback can settle the slot from
	-- inside the send while the requester is still running, and resuming a running
	-- thread raises.
	--   Parked   written only by the requester either side of its yield, so never true
	--            while it runs. coroutine.status is no substitute: a transport that
	--            yields inside SendToServer would misdeliver the reply.
	--   Settled  an answer has been claimed. The reply, the timeout and a throwing send
	--            race for it; first wins. Results carries an explicit Count because a
	--            handler may return nils and `#` on a table with a hole is undefined.
	type RequestSlot = {
		Correlation: number,
		Thread: thread,
		Parked: boolean,
		Settled: boolean,
		Results: { any },
		Count: number,
	}
	local requestWaiters: { [number]: RequestSlot } = {}
	local nextCorrelation = 0

	-- The one place a request is answered and the one place a slot leaves the map, so
	-- the "exactly one winner" rule is a single guard. Nothing after it yields.
	local function settleRequest(slot: RequestSlot, results: { any }, count: number)
		if slot.Settled then
			return
		end
		slot.Settled = true
		slot.Results = results
		slot.Count = count
		-- Cleared by identity, never by presence: correlations wrap at 2^32, so a dead
		-- request's timer must not evict the slot that inherited its number.
		if requestWaiters[slot.Correlation] == slot then
			requestWaiters[slot.Correlation] = nil
		end
		-- No values passed: the requester reads the slot, so a resumed request and one
		-- answered before it yielded cannot disagree about arity.
		if slot.Parked then
			Sched.Resume(slot.Thread)
		end
	end

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
		-- A dropped Hello leaves the client stuck at defaults, so surface the send error
		-- once instead of retrying silently. A sandboxed calling thread fails here.
		if not ok and not helloSendFailLogged then
			helloSendFailLogged = true
			Log.Warn("Transport", "SEND_FAIL", `client could not send its Hello handshake: {tostring(err)}`, {})
		end
	end

	local function applyInit(reader: Wire.Reader)
		local ops = Wire.DecodeOps(reader, compiled)
		-- The snapshot supersedes local state: reset to defaults, then apply.
		local defaults = Template.BuildDefaults(compiled, "Client")
		-- Reset and apply inside ReplayFire so a re-Init's Changed listeners see their
		-- true pre-snapshot value as `old`; ReplayFire snapshots olds before the closure,
		-- so resetting outside it makes every `old` the default.
		tree:ReplayFire(function()
			table.clear(mirror)
			for key, value in defaults do
				mirror[key] = value
			end
			for _, op in ops do
				tree:ApplyOp(op)
			end
		end)
		-- Foreign mirrors are superseded too. sendInit re-sends a SharedInit for every
		-- player still on the server right after this frame, so what does not come back
		-- is what left; the only way a client that missed a SharedGone drops that ghost.
		-- Cleared silently: a player who left and one whose SharedInit is a frame away
		-- are indistinguishable here, so firing would report everyone gone and then back.
		table.clear(sharedMirrors)
		if not loaded then
			loaded = true
			loadedSignal:Fire()
		end
		Log.Debug("Replication", "INIT_APPLIED", "initial snapshot applied", {})
	end

	-- Fragment reassembly ------------------------------------------------------
	--
	-- The server splits any frame larger than its MaxOutboundBytes; everything below
	-- this point sees only whole logical frames, so a snapshot still lands in one
	-- ReplayFire. Not a security boundary: only the server can raise OnClientEvent on
	-- the Down remote, which is also why the decoder below has no object budget. The
	-- ceiling only stops a corrupted length field becoming a huge allocation.
	local MAX_REASSEMBLY_BYTES = 64 * 1024 * 1024
	local fragBuf: buffer? = nil
	local fragSeq, fragTotal, fragWritten, fragExpected = -1, 0, 0, 0
	-- Set whenever a fragment lands, cleared by the handshake retry loop: a Hello sent
	-- mid-snapshot makes the server throw it away and re-encode the whole profile.
	local fragProgress = false

	local function resetFragments()
		fragBuf, fragSeq, fragTotal, fragWritten, fragExpected = nil, -1, 0, 0, 0
	end

	-- Refusals are counted, not just dropped: a gap, a replayed piece or a forged
	-- length is otherwise indistinguishable from an unfinished frame.
	local function refuseFragment(reason: string): buffer?
		resetFragments()
		Metrics.Add("FragmentsRefused")
		Log.Debug("Replication", "FRAGMENT_REFUSED", reason, {})
		return nil
	end

	local function acceptFragment(bytes: buffer): buffer?
		local size = buffer.len(bytes)
		if size < Wire.FRAGMENT_HEADER then
			return refuseFragment("fragment shorter than its header")
		end
		local seq = buffer.readu16(bytes, 1)
		local declared = buffer.readu32(bytes, 3)
		local index = buffer.readu16(bytes, 7)
		local payload = size - Wire.FRAGMENT_HEADER
		if index == 0 then
			resetFragments()
			if declared == 0 or payload == 0 then
				return refuseFragment("empty fragment")
			end
			if declared > MAX_REASSEMBLY_BYTES then
				return refuseFragment("declared length is not a plausible frame")
			end
			fragBuf, fragSeq, fragTotal, fragWritten, fragExpected = buffer.create(declared), seq, declared, 0, 0
		end
		local dest = fragBuf
		if dest == nil then
			-- Not an error and deliberately not counted: a fragment arriving with
			-- nothing in flight is the tail of a frame whose head was lost.
			return nil
		end
		if seq ~= fragSeq or index ~= fragExpected or declared ~= fragTotal or payload == 0 then
			return refuseFragment("fragment does not continue the frame in progress")
		end
		if fragWritten + payload > fragTotal then
			return refuseFragment("fragment overruns the declared length")
		end
		buffer.copy(dest, fragWritten, bytes, Wire.FRAGMENT_HEADER, payload)
		fragWritten += payload
		fragExpected += 1
		fragProgress = true
		if fragWritten < fragTotal then
			return nil
		end
		resetFragments()
		-- A reassembled frame is never itself a fragment; refusing it stops a malformed
		-- stream re-entering the dispatcher without bound.
		if buffer.readu8(dest, 0) == Wire.Frames.Fragment then
			return refuseFragment("reassembled frame is itself a fragment")
		end
		Metrics.Add("FramesReassembled")
		return dest
	end

	local function handleFrame(bytes: buffer)
		local reader = Wire.NewReader(bytes)
		local frameType = Wire.RU8(reader)

		if frameType == Wire.Frames.Fragment then
			local whole = acceptFragment(bytes)
			if whole ~= nil then
				handleFrame(whole)
			end
			return
		end

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
			-- One frame, one batch: a Server.Batch that coalesced into this frame
			-- must not fan back out into one container fire per op.
			tree:ApplyOps(ops)
			Metrics.Add("DiffsApplied")
		elseif frameType == Wire.Frames.CommandReply then
			local correlation = Wire.RU32(reader)
			local ok = Wire.RU8(reader) == 1
			local count = Wire.RU8(reader)
			local results = table.create(count)
			for i = 1, count do
				results[i] = Wire.DecodeGeneric(reader)
			end
			local slot = requestWaiters[correlation]
			if slot then
				if ok then
					-- Transparent RPC: the handler's return values are the Request results,
					-- handed over by reference with the frame's own count byte.
					settleRequest(slot, results, count)
				else
					-- ok == 0: the framework refused, so results[1] is a sentinel and the
					-- appended marker is what makes that distinguishable. The count is
					-- spelled out because a malformed reply can leave results[1] nil.
					settleRequest(slot, { false, results[1], Types.RequestFailed }, 3)
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
			-- A Shared derived field the server did not send is computed per client, and
			-- a foreign mirror is a plain table with no accessor tree. Recompute before
			-- the change event so a listener never sees it without its derived fields.
			DerivedModule.EvaluateInto(compiled, shared, isSharedLocalDerived)
			-- One event per update carrying a clone of the shared data; nil is reserved
			-- for SharedGone. CloneUnpack also converts packed datatype fields back to
			-- the real datatype, so only pay for it when something is listening.
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
			OnLeaderboard:Fire(name, entries)
		end
	end

	-- Studio-only client debug hook for the Scribe Studio plugin. Attached before the
	-- transport connects so the Init snapshot application is captured too.
	if isRunning and devMode and (options.IsClient == true or RunService:IsClient()) then
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
		Sched.Spawn(function()
			local resolved = TransportModule.Resolve(options.Transport, options.TransportChannel)
			transport = resolved
			resolved:ListenClient(function(bytes: buffer)
				local ok, err = pcall(handleFrame :: any, bytes)
				if not ok then
					Log.Warn("Transport", "MALFORMED_FRAME", tostring(err), {})
				end
			end)
			-- Hello retries cover server-side races and adapters that connect late.
			sendHello()
			local delaySeconds = 2
			while not loaded do
				-- The retry delay only. The first sendHello stays immediate: delaying it
				-- would slow every ordinary join to fix a problem only a mass rejoin has.
				Clock.Wait(Rng.Jitter(delaySeconds))
				if loaded or stopped then
					break
				end
				if fragProgress then
					-- A snapshot is arriving, one fragment at a time. Asking again is harmful:
					-- the server answers a Hello by re-encoding the whole profile, so a large
					-- Init would keep restarting. Clearing the flag keeps a stalled sequence
					-- from blocking retries forever.
					fragProgress = false
					delaySeconds = 2
					continue
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
				Sched.Resume(thread, result)
			end
		end
		local conn = loadedSignal:Connect(function()
			resume(true)
		end)
		Clock.Delay(timeout or Defaults.ClientWaitForData, function()
			resume(false)
		end)
		local result = coroutine.yield()
		conn:Disconnect()
		return result
	end

	-- The body behind Request and RequestOnce. `idemKey` is nil for a plain request
	-- and ships as an empty string, which the server reads as "no key", so a command
	-- frame has one layout. `level` keeps the arity error pointing at the caller.
	local function dispatchRequest(name: string, idemKey: string?, args: { n: number, [number]: any }, level: number)
		if editMode then
			local mock = mockCommands[name]
			if mock then
				local results
				local ok = pcall(function()
					results = table.pack(mock(table.unpack(args, 1, args.n)))
				end)
				if ok and results then
					return table.unpack(results, 1, results.n)
				end
				return false, "mock-error", Types.RequestFailed
			end
			return false, "edit-mode", Types.RequestFailed
		end
		-- Fail loud rather than clamping: dropping the extras here would run the
		-- handler with missing trailing arguments instead of the server's refusal.
		if args.n > Wire.MAX_COMMAND_ARGS then
			error(`Scribe: a command takes at most {Wire.MAX_COMMAND_ARGS} arguments (got {args.n})`, level)
		end
		-- No transport check here: waitForLoaded only returns once an Init frame arrived,
		-- which requires the transport. A nil one still surfaces as "send-failed" below.
		waitForLoaded()
		nextCorrelation = (nextCorrelation + 1) % 4294967296
		local correlation = nextCorrelation
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.Command)
		Wire.U32(w, correlation)
		Wire.Str(w, name)
		Wire.U8(w, args.n)
		-- Ahead of the arguments, so the server can refuse an unusable key before it
		-- decodes anything attacker-sized.
		Wire.Str(w, idemKey or "")
		for i = 1, args.n do
			Wire.EncodeGeneric(w, args[i])
		end

		local slot: RequestSlot = {
			Correlation = correlation,
			Thread = coroutine.running(),
			Parked = false,
			Settled = false,
			Results = NO_RESULTS,
			Count = 0,
		}
		requestWaiters[correlation] = slot
		-- Armed before the send so the deadline covers the send itself, which matters if
		-- the spawn below ever goes. Clock.Delay cannot be cancelled, so the callback
		-- always fires and settleRequest is what makes a late one a no-op.
		Clock.Delay(options.RequestTimeout or Defaults.Request, function()
			settleRequest(slot, { false, "timeout", Types.RequestFailed }, 3)
		end)
		-- Spawned, not deferred. Sched.Spawn runs the send immediately on this stack, so
		-- a synchronous loopback closes the round trip before this line returns and the
		-- requester never parks. A Sched.Defer would put the reply's resume inside a
		-- deferred callback, promoting the requester one re-entrancy generation per round
		-- trip until it hangs. The spawn also means a SendToServer that never returns
		-- hangs its own coroutine, so the timeout can still answer.
		local bytes = Wire.Finish(w)
		Sched.Spawn(function()
			local ok = pcall(function()
				transport:SendToServer(bytes)
			end)
			if not ok then
				-- Reached synchronously for a throwing send, so the requester is still
				-- running and this records rather than resumes.
				settleRequest(slot, { false, "send-failed", Types.RequestFailed }, 3)
			end
		end)
		-- A loop rather than an `if`, so a stray resume from outside Scribe re-parks
		-- instead of returning an unsettled slot; the timeout above always arrives.
		while not slot.Settled do
			slot.Parked = true
			coroutine.yield()
			slot.Parked = false
		end
		return table.unpack(slot.Results, 1, slot.Count)
	end

	--[=[
		@within Client
		@tag Commands
		@client
		@yields
		@param name string
		@param ... any
		@return ...any
		Calls a server command registered with [Server.Command] and returns whatever
		its handler returned. It yields until the reply arrives, and resolves
		`false, "timeout"` if none comes within `RequestTimeout`. This is the one way
		a client changes data authoritatively.

		When Scribe refuses rather than your handler, the result is `false`, one
		[Scribe.RequestReason], and [Scribe.RequestFailed] in a third slot. Test that
		third value, because a handler may return `false, "timeout"` of its own. A
		retry after a timeout runs the handler a second time, so reach for
		[Client.RequestOnce] when that is not safe. See
		[Commands & Requests](../commands.md#what-the-caller-gets-back-on-failure).
	]=]
	function Data.Request(name: string, ...: any): ...any
		return dispatchRequest(name, nil, table.pack(...), 3)
	end

	--[=[
		@within Client
		@tag Commands
		@client
		@yields
		@param name string
		@param key string
		@param ... any
		@return ...any
		Like [Client.Request], but tagged with an idempotency `key`: the server runs
		the handler at most once per key and replays its original reply, byte for
		byte, to every repeat. Use it for anything a retry must not do twice, and
		generate the key once per intent rather than once per attempt.

		The command must be registered `Idempotent = true`, and a key sent to one that
		is not, or a keyless [Client.Request] to one that is, is refused with
		`"bad-idempotency-key"`. A key must be non-empty, valid UTF-8, and at most 64
		bytes, and this call raises on your own thread rather than send one that is
		not. See
		[Running a command at most once](../commands.md#running-a-command-at-most-once).
	]=]
	function Data.RequestOnce(name: string, key: string, ...: any): ...any
		-- Rejected here rather than at the server: an unusable key is a caller mistake,
		-- and a round trip would return it looking like a genuine handler refusal.
		if type(key) ~= "string" or key == "" or #key > Wire.MAX_IDEMPOTENCY_KEY_BYTES or not utf8.len(key) then
			error(
				`Scribe: RequestOnce needs a non-empty idempotency key of at most `
					.. `{Wire.MAX_IDEMPOTENCY_KEY_BYTES} valid UTF-8 bytes`,
				2
			)
		end
		return dispatchRequest(name, key, table.pack(...), 3)
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

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
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

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
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

		Never returns the **local** player's own roots: the server broadcasts a
		player's Shared data to everyone except that player, so `nil` there is
		permanent rather than pending. Read your own through the ordinary accessor.
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

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
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

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
	]=]
	Data.OnOwnershipChanged = OnOwnershipChanged

	-- Ownership: reads the replicated mirror.
	-- Client twin of the server's check. Without it a non-string key reads as "not owned"
	-- off a nil table index, so a typo is indistinguishable from a player who owns nothing.
	local function assertOwnsKey(key: any, what: string)
		if type(key) ~= "string" then
			-- 3: assertOwnsKey -> Data.<Api> -> the game code that got it wrong.
			error(`Scribe: {what}: key must be a string, got {typeof(key)}`, 3)
		end
	end

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
		assertOwnsKey(key, "Owns")
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
		assertOwnsKey(key, "OwnsAsync")
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
					Sched.Resume(thread)
				end
			end
			disconnect = tree.Accessor[Template.SESSION_ROOT].OwnsSynced.Changed(function(v)
				if v == true then
					wake()
				end
			end) :: () -> ()
			Clock.Delay(timeout or Defaults.OwnsAsync, wake)
			-- If the flag arrived between the check and the connect, clean up and skip
			-- the yield: never task.spawn a thread that has not yielded.
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

	-- Drives OnOwnershipChanged. Dedupes like ObserveOwned, but across every key the
	-- mirror holds, so a listener does not have to know keys up front.
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
		-- Through the privileged handle, not the public child: a public read of the
		-- reserved root hands back a detached deep copy (readOut in Node.luau).
		tree.Reserved.Perks.Changed(function()
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
		assertOwnsKey(key, "ObserveOwned")
		if not editMode then
			waitForLoaded()
		end
		local last: boolean? = nil
		local function push()
			local owned = ownsFromMirror(key)
			if owned ~= last then
				last = owned
				Sched.Spawn(callback, owned)
			end
		end
		local accessor = tree.Accessor
		-- Privileged handle: see the note in ensureOwnershipWatched.
		local disconnectPerk = tree.Reserved.Perks.Changed(push)
		local disconnectCache = accessor[Template.SESSION_ROOT].OwnsCache.Changed(push)
		push()
		return function()
			disconnectPerk()
			disconnectCache()
		end
	end

	-- Product info --------------------------------------------------------------
	--
	-- Client-side by necessity: a live server has no player in context, so its
	-- GetProductInfoAsync answers the base catalog price, which is the one number a
	-- discounted player never pays. Studio servers DO answer personalized, so the
	-- server version tests clean and ships broken.
	--
	-- Lazy throughout: a bundle that never asks for a price pays nothing.

	-- Overridable because patching a real service Instance is illegal, the same seam
	-- as the server's UserOwnsGamePassAsync.
	local getProductInfoAsync: (assetId: number, infoType: any) -> any = options.GetProductInfoAsync
		or function(assetId: number, infoType: any): any
			local marketplace: any = game:GetService("MarketplaceService")
			return marketplace:GetProductInfoAsync(assetId, infoType)
		end

	-- Distinct from nil, so an observer's first push fires while nothing is resolved.
	local UNRESOLVED: any = table.freeze({})
	local PRODUCT_ATTEMPTS = 4
	local PRODUCT_RETRY_BASE = 2

	local productAssets: { [string]: { Id: number, InfoType: any } }? = nil
	local productInfo: { [string]: any } = {}
	local productWaiters: { [string]: { { Thread: thread, Settled: boolean } } } = {}
	local productObservers: { [string]: { () -> () } } = {}
	local productQueue: { string } = {}
	local productQueued: { [string]: boolean } = {}
	local productFlushScheduled = false
	local membershipWatched = false
	local membershipConnection: any = nil

	-- Every declared pass and product, built on first use.
	local function ensureProductAssets(): { [string]: { Id: number, InfoType: any } }
		if productAssets == nil then
			local built: { [string]: { Id: number, InfoType: any } } = {}
			for passName, config in (options.Passes or {}) :: { [string]: any } do
				built[passName] = { Id = config.Id, InfoType = Enum.InfoType.GamePass }
			end
			-- The server refuses a product named like a pass, so one namespace is enough.
			for productName, config in (options.Products or {}) :: { [string]: any } do
				built[productName] = { Id = config.Id, InfoType = Enum.InfoType.Product }
			end
			productAssets = built
		end
		return productAssets :: any
	end

	-- The declared pass or product, or a raise naming the key.
	local function productAsset(name: string, api: string): { Id: number, InfoType: any }
		local asset = ensureProductAssets()[name]
		if asset == nil then
			-- 3: productAsset -> Data.<Api> -> the game code that got it wrong.
			error(`Scribe.{api}: "{tostring(name)}" is not a declared pass or product`, 3)
		end
		return asset
	end

	local function notifyProduct(name: string)
		local observers = productObservers[name]
		if observers == nil then
			return
		end
		-- Cloned: a callback may disconnect itself, which mutates the list.
		for _, push in table.clone(observers) do
			push()
		end
	end

	local function settleProduct(name: string, info: any)
		productQueued[name] = nil
		if info ~= nil then
			productInfo[name] = info
		end
		local waiters = productWaiters[name]
		productWaiters[name] = nil
		if waiters ~= nil then
			for _, waiter in waiters do
				-- Settled is the discriminator, not coroutine status: a caller that timed
				-- out and then parked on something else is also "suspended", and resuming
				-- it here wakes it out of an unrelated wait.
				if not waiter.Settled then
					waiter.Settled = true
					-- Directly: a wake must never travel the defer queue.
					Sched.Resume(waiter.Thread, info)
				end
			end
		end
		notifyProduct(name)
	end

	local function fetchProduct(name: string)
		local asset = if productAssets ~= nil then (productAssets :: any)[name] else nil
		if asset == nil then
			return
		end
		for attempt = 1, PRODUCT_ATTEMPTS do
			local ok, result = pcall(getProductInfoAsync, asset.Id, asset.InfoType)
			if ok and type(result) == "table" then
				settleProduct(name, result)
				return
			end
			if attempt == PRODUCT_ATTEMPTS then
				Log.Warn(
					"Monetization",
					"PRODUCT_INFO_FAIL",
					`could not read product info for "{name}": {tostring(result)}`,
					{ Product = name }
				)
				-- Never the base price: nil means "show a placeholder".
				settleProduct(name, nil)
				return
			end
			Log.Warn(
				"Monetization",
				"PRODUCT_INFO_THROTTLED",
				`product info for "{name}" failed, retrying ({attempt}/{PRODUCT_ATTEMPTS})`,
				{ Product = name }
			)
			Clock.Wait(Rng.Jitter(PRODUCT_RETRY_BASE * 2 ^ (attempt - 1)))
		end
	end

	local function flushProductQueue()
		productFlushScheduled = false
		local batch = productQueue
		productQueue = {}
		-- Together on purpose: the engine only coalesces calls in flight at the same
		-- time, so one burst costs one request where N singles cost N.
		for _, name in batch do
			Sched.Spawn(fetchProduct, name)
		end
	end

	local function enqueueProduct(name: string)
		if productInfo[name] ~= nil or productQueued[name] then
			return
		end
		productQueued[name] = true
		table.insert(productQueue, name)
		if not productFlushScheduled then
			productFlushScheduled = true
			Sched.Defer(flushProductQueue)
		end
	end

	-- Observers hear about the new value landing, not the old one being dropped, so a
	-- successful refresh does not blink the price to nil.
	local function refreshProduct(name: string?)
		local names: { string } = {}
		if name ~= nil then
			names[1] = name
		else
			for cached in productInfo do
				table.insert(names, cached)
			end
		end
		for _, each in names do
			productInfo[each] = nil
			enqueueProduct(each)
		end
	end

	-- A Roblox Plus discount moves the price, leaving the cached one wrong for the rest
	-- of the session. Armed on first use, and one-shot: the flag flips at most once in a
	-- session. The 10% to 20% step at month three does not move it at all, which is what
	-- RefreshProductInfo is for.
	--
	-- The signal is on the PLAYER. Asking the Players service for it raises, and the
	-- pcall would swallow that into a watch that silently never fires.
	local function watchMembership()
		if membershipWatched then
			return
		end
		-- Left unarmed while there is no LocalPlayer, so the next read retries.
		membershipWatched = pcall(function()
			local localPlayer: any = readLocalPlayer()
			membershipConnection = localPlayer:GetPropertyChangedSignal("HasRobloxSubscription"):Once(function()
				refreshProduct(nil)
			end)
		end)
	end

	--[=[
		@within Client
		@tag Monetization
		@client
		@param name string
		@return { [string]: any }?
		Marketplace info for a declared pass or product, as **this** player sees it.
		`PriceInRobux` is what they are charged, after any Roblox Plus or regional
		discount; `UserBasePriceInRobux` and `PriceDiscountDetails` are there for a
		"was 100, now 80" button.

		Returns nil until the first read lands, and starts that read. Poll it, or use
		[Client.ObserveProductInfo]. Never waits for the profile to load.

		Client-only by necessity: a live server has no player in context and reads the
		base catalog price, which is not what a discounted player pays.
	]=]
	function Data.GetProductInfo(name: string): { [string]: any }?
		productAsset(name, "GetProductInfo")
		watchMembership()
		enqueueProduct(name)
		return productInfo[name]
	end

	--[=[
		@within Client
		@tag Monetization
		@client
		@param name string
		@return number?
		Shorthand for the `PriceInRobux` of [Client.GetProductInfo]: the Robux this
		player pays. nil until the first read lands, and starts that read.
	]=]
	function Data.GetPrice(name: string): number?
		local info = Data.GetProductInfo(name)
		local price = if info ~= nil then info.PriceInRobux else nil
		return if type(price) == "number" then price else nil
	end

	--[=[
		@within Client
		@tag Monetization
		@client
		@param name string
		@param timeout number?
		@return { [string]: any }?
		Like [Client.GetProductInfo], but yields until the read lands. Returns nil if it
		times out (default 10s), or if Marketplace refused every attempt.
	]=]
	function Data.GetProductInfoAsync(name: string, timeout: number?): { [string]: any }?
		productAsset(name, "GetProductInfoAsync")
		watchMembership()
		local cached = productInfo[name]
		if cached ~= nil then
			return cached
		end
		enqueueProduct(name)
		-- Re-checked before parking: a queue that ever resolved synchronously would
		-- leave this thread in the waiter list with nobody left to wake it.
		local resolved = productInfo[name]
		if resolved ~= nil then
			return resolved
		end
		local waiters = productWaiters[name]
		if waiters == nil then
			waiters = {}
			productWaiters[name] = waiters
		end
		local waiter = { Thread = coroutine.running(), Settled = false }
		table.insert(waiters :: { any }, waiter)
		Clock.Delay(timeout or Defaults.ProductInfo, function()
			if not waiter.Settled then
				waiter.Settled = true
				Sched.Resume(waiter.Thread, nil)
			end
		end)
		return coroutine.yield()
	end

	--[=[
		@within Client
		@tag Monetization
		@client
		@param name string
		@param timeout number?
		@return number?
		Shorthand for the `PriceInRobux` of [Client.GetProductInfoAsync]: the Robux this
		player pays. nil if the read times out (default 10s) or was refused.
	]=]
	function Data.GetPriceAsync(name: string, timeout: number?): number?
		local info = Data.GetProductInfoAsync(name, timeout)
		local price = if info ~= nil then info.PriceInRobux else nil
		return if type(price) == "number" then price else nil
	end

	--[=[
		@within Client
		@tag Monetization
		@client
		@param name string
		@param callback ({ [string]: any }?) -> ()
		@return () -> ()
		Calls `callback` with the info now (nil if it has not landed), again when it
		does, and again if the price changes. Returns a disconnect function. The
		reactive way to price a shop button.
	]=]
	function Data.ObserveProductInfo(name: string, callback: ({ [string]: any }?) -> ()): () -> ()
		productAsset(name, "ObserveProductInfo")
		watchMembership()
		local last: any = UNRESOLVED
		local alive = true
		local function push()
			if not alive then
				return
			end
			local info = productInfo[name]
			if info ~= last then
				last = info
				Sched.Spawn(callback, info)
			end
		end
		local list = productObservers[name]
		if list == nil then
			list = {}
			productObservers[name] = list
		end
		table.insert(list :: { () -> () }, push)
		enqueueProduct(name)
		push()
		return function()
			alive = false
			local current = productObservers[name]
			if current ~= nil then
				local index = table.find(current, push)
				if index ~= nil then
					table.remove(current, index)
				end
			end
		end
	end

	--[=[
		@within Client
		@tag Monetization
		@client
		@param names { string }?
		Warms `names`, or every declared pass and product when omitted, as one batch.
		Optional: every read path fetches on demand anyway. Worth calling before opening
		a shop with many items, because one burst costs one request where the same reads
		trickling in frame by frame cost one each.
	]=]
	function Data.PrefetchProductInfo(names: { string }?)
		watchMembership()
		if names == nil then
			for name in ensureProductAssets() do
				enqueueProduct(name)
			end
			return
		end
		-- Validated in full first, so a typo raises instead of half-warming.
		for _, name in names do
			productAsset(name, "PrefetchProductInfo")
		end
		for _, name in names do
			enqueueProduct(name)
		end
	end

	--[=[
		@within Client
		@tag Monetization
		@client
		@param name string?
		Drops the cached info for `name`, or for everything when omitted, and reads it
		again. Scribe already does this the first time the local player's
		`HasRobloxSubscription` flips; use this for any later move.
	]=]
	function Data.RefreshProductInfo(name: string?)
		if name ~= nil then
			productAsset(name, "RefreshProductInfo")
		end
		refreshProduct(name)
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
		@param filter PurchaseFilter?
		@return { table }
		The local player's purchase history for history UI. Only returned if the
		game opts into replicating purchase logs (`PurchaseLog.ReplicateRobux`).

		`PurchaseFilter` is `{ Kind: ("Robux" | "InGame")?, Category: string?,
		ItemId: string?, Since: number?, Limit: number? }`, exported as
		`Scribe.PurchaseFilter`.
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
		@param values { [string]: any }?
		@param scribeState { Perks: { string }?, GiftCredits: { [string]: number }?, PurchaseLogs: { Robux: { any }?, InGame: { any }? }?, Leaderboards: { [string]: { LeaderboardEntry } }? }?
		Seeds mock data for a storybook / edit mode. **Errors outside edit mode.**
		Use it to render Scribe-backed components with realistic state.

		`values` holds template fields to seed and is deep-merged into the mirror,
		so you only pass the fields your component reads. `scribeState` seeds the
		monetization and leaderboard state those APIs read.
	]=]
	function Data.Mock(values: { [string]: any }?, scribeState: { [string]: any }?)
		assertEditMode("Data.Mock")
		-- Batch the whole-root Sets through ReplayFire so a nested observer registered
		-- before Mock still fires; a whole-root Set fires only the container's Changed.
		tree:ReplayFire(function()
			if values then
				for key, value in values do
					local current = mirror[key]
					tree.Accessor[key].Set(deepMerge(current, value))
				end
			end
			if scribeState then
				-- The privileged handle: Data.Mock seeds Scribe's own ledgers, which the
				-- public accessor refuses to write.
				local reservedAccessor = tree.Reserved
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

	-- Data.<rootField> resolves through the mirror tree, returning the accessor
	-- immediately: reads give template defaults until Init lands. A metamethod must
	-- never yield, so waiting here errors with "yield across metamethod/C-call".
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
	-- Server store roots are in this mirror like any other root; they simply are never
	-- written from here. Same per-root shape as the server exposes.
	--[=[
		@within Client
		@tag Reads
		@client
		@prop ServerStore table
		The server-owned tree as this client mirrors it, present only when the
		bundle declares `ServerStore`. Read and observe it like any other root,
		with no player argument; writes belong on the server.
		
		See [Server-owned state](../server-store.md).
	]=]
	if compiled.Views.Store ~= nil then
		local proxy = {}
		for _, key in compiled.Views.Store.RootOrder do
			proxy[key] = tree.Accessor[key]
		end
		Data.ServerStore = table.freeze(proxy)
	end

	--[=[
		@within Client
		@tag Lifecycle
		@client
		Releases what this client bundle holds on the process: the transport listener,
		the Hello retry loop, the subscription watch behind [Client.GetProductInfo], and
		the mirror tree's listeners. The counterpart of [Server.Stop].

		A game never needs it. A storybook that remounts a bundle per story, or a test
		suite that builds many, otherwise stacks a listener per build. Idempotent.
	]=]
	function Data.Stop()
		if stopped then
			return
		end
		stopped = true
		if transport ~= nil and type((transport :: any).Release) == "function" then
			pcall((transport :: any).Release, transport)
		end
		if membershipConnection ~= nil then
			pcall(function()
				membershipConnection:Disconnect()
			end)
			membershipConnection = nil
		end
		tree:Destroy()
	end

	Data.Raw = Data

	-- One line confirming the bundle initialized (Banner = false to silence).
	if options.Banner ~= false then
		print(`Running Scribe v{Version} by ericplane. Client is now initialized`)
	end

	-- Drive OnOwnershipChanged once the first snapshot lands.
	Sched.Spawn(ensureOwnershipWatched)

	-- A root field named like a client Data API is silently shadowed by that real key
	-- (a real key always wins over __index), so it is unreachable as `Data.<name>`.
	-- Reported always rather than only in Studio, and at Error level so it reaches
	-- Scribe.OnIssue: the case worth catching is a shipped game upgrading into a
	-- collision. Keep this last: `for key in Data` sees only the keys that exist when
	-- it runs, and raw iteration means only real keys are judged.
	local rootChildren = compiled.Root.Children :: { [string]: any }
	for key in Data do
		if type(key) == "string" and rootChildren[key] then
			Log.Error(
				"Lifecycle",
				"API_NAME_COLLISION",
				`template root field "{key}" collides with a client Data API name, so it is unreachable as `
					.. `Data.{key} on the client. Rename the field, or read it through the accessor tree.`,
				{ Field = key }
			)
		end
	end

	return Data
end

return Client
