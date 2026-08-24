--!strict
-- Persistence on ProfileStore: session lifecycle, fail-closed
-- migrations, offline access, version history/restore, save observability,
-- wipe guard, and BindToClose.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Internal = script.Parent.Parent.Internal
local Util = require(Internal.Util)
local Node = require(Internal.Node)
local Template = require(Internal.Template)
local Conform = require(Internal.Conform)
local DerivedModule = require(Internal.Derived)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)
local Signal = require(Internal.Signal)
local Config = require(Internal.Config)
local Clock = require(Internal.Clock)
local Sched = require(Internal.Sched)
local Failure = require(Internal.Failure)
local Rng = require(Internal.Rng)

local Persistence = {}

export type Entry = {
	Player: Player,
	UserId: number,
	Key: string,
	State: "Loading" | "Ready" | "SessionEnded",
	FailReason: string?,
	Profile: any?,
	Tree: any?,
	SessionStore: { [string]: any },
	LiveData: { [string]: any }?,
	StateChanged: any,
	SaveInfo: { LastSaveAt: number?, LastResult: ("Ok" | "Fail")?, Dirty: boolean },
	SaveT0: number?,
	-- How many saves are on the wire right now. The store permits N concurrent saves,
	-- so a single slot cannot attribute a failure that arrives after the first
	-- completion. SaveT0 holds the earliest live start and clears when this drains.
	SavesInFlight: number,
	-- Dirtiness as it stood before ANY save currently in flight snapshotted its
	-- payload, so the OnError handler can put it back when one of them fails.
	-- OR in at every snapshot, never assign, and clear only when SavesInFlight drains
	-- to zero: a per-save capture lets a later save overwrite an earlier one's value,
	-- and the earlier one's failure then restores clean over an unstored write.
	-- nil and false both mean "nothing captured says dirty", so a store exposing no
	-- OnSettled never clears this and can only ever over-report dirty.
	DirtyAtSaveStart: boolean?,
	Blocked: boolean,
	ForceSaveOnce: boolean,
	WipeGuardRebaselinePending: boolean?,
	LocalSessionEnd: boolean?, -- set before every locally-initiated EndSession
	-- Timed's live _Scribe.Timed dict while a save is in flight, held so the restore
	-- can run from OnAfterSave or, if the save fails, from the OnError handler.
	TimedHeld: { [string]: number }?,
	TimedLive: { [string]: number }?, -- same table, read by Timed's own store lookup
	TimedSaves: number?, -- open save windows; saves are not serialized per profile
	LeavingHookRan: boolean?, -- OnPlayerLeaving fires at most once per session
	-- Cross-server messages handed to Data.OnMessage whose FireTracked has not settled.
	-- Nonzero at session end means a handler never returned; teardown reports it.
	UnsettledMessages: number?,
	SessionStolen: boolean?, -- OnSessionEnd fired that we did not initiate (external steal)
	LastSavedSize: number?,
	-- Top-level keys of the last successful save. The wipe guard's baseline, kept
	-- here so the store does not have to keep a second copy of the whole profile.
	LastSavedKeys: { [string]: true }?,
	LiveSize: number?, -- approx bytes measured at the start of the last save attempt
	SizeWarned: boolean,
	TornDown: boolean,
	-- Replication state (owned by Replication.luau)
	HelloReceived: boolean,
	-- Two flags, deliberately: QueueOpen means a snapshot has been taken, so a write
	-- belongs in the queue; HandshakeReady means the snapshot is on the wire, so this
	-- client may be sent frames. One flag left a gap between those two moments in
	-- which a write belonged nowhere and was silently dropped.
	QueueOpen: boolean,
	HandshakeReady: boolean,
	LastInitAt: number,
	-- A frame did not reach the transport, so this client's mirror is stale and it
	-- cannot ask for a repair (a loaded client never re-Hellos). The flush loop
	-- re-sends the whole snapshot; LastResyncAt throttles repeats so a permanently
	-- broken transport cannot cost one encode per frame.
	ResyncPending: boolean?,
	LastResyncAt: number?,
	Queue: { any },
	QueueIndex: { [string]: number },
	SharedQueue: { any },
	MalformedCount: number,
	MalformedBlocked: boolean?, -- crossed the malformed-frame limit; inbound frames ignored
	LastMalformedLog: number?, -- os.clock of the last emitted malformed-frame log/anomaly
	OversizeCount: number, -- own budget: an oversize frame is never read, a malformed one was
	OversizeBlocked: boolean?, -- crossed the oversize limit; inbound frames ignored
	LastOversizeLog: number?, -- os.clock of the last emitted INBOUND_OVERSIZE
	-- Raw inbound frame budget: every frame the player sends, whatever its type, size
	-- or validity, spent before the frame is looked at at all.
	FrameTokens: number,
	FrameLast: number,
	LastInboundRateLog: number?, -- os.clock of the last emitted INBOUND_RATE_LIMITED
	-- Commands state
	RateTokens: number,
	RateLast: number,
	RateLimitedCount: number?, -- consecutive rate-limited frames (decays when quiet)
	LastRateLimitAt: number?, -- os.clock of the last rate-limited frame
	LastRateLimitLog: number?, -- os.clock of the last emitted COMMAND_RATE_LIMITED
	-- Monetization state
	GiftLastAt: number,
	OwnsLast: { [string]: boolean }?, -- last reported effective ownership, for change detection
	OwnsWatchers: { () -> () }?, -- Perks/OwnsCache listeners driving OnOwnershipChanged
}

local SIZE_WARN_BYTES = 3.5 * 1024 * 1024 -- warn approaching the ~4 MB DataStore ceiling
local MIN_SAVE_INTERVAL = 15 -- seconds; below this, per-key DataStore throttling causes save failures
local WIPE_GUARD_RATIO_DEFAULT = 0.6 -- a profile shrinking past 60% looks like a wipe, not like spending

-- Matches the store's ASSUME_DEAD. Its own constant rather than reached for through
-- the module, so the operator paths behave identically against an injected store
-- that has no such constant to read.
local ASSUME_DEAD_SECONDS = 630

-- Share of the shutdown budget the OnPlayerLeaving phase may spend. Hooks come first
-- because their writes are the only thing here that cannot be rebuilt; the remainder
-- is a floor under the leaderboard flush, not a cap on it.
local HOOK_PHASE_SHARE = 0.75
local HOOK_JOIN_POLL = 0.05 -- seconds between checks that the parked hooks have returned

-- Hand the store module Scribe's error classifier, so MessageAsync can answer whether
-- any attempt inside its own retry loop could have written (the value a gift-credit
-- spend refunds on). The store fork has no `require` of its own, so it cannot reach
-- Failure directly. Written on every route, injected modules included; a fork that
-- finds no classifier assumes every failure might have written.
local function installErrorClassifier(store: any): any
	if type(store) == "table" then
		store.ClassifyError = Failure.Classify
	end
	return store
end

local function findProfileStoreModule(injected: any): any
	if type(injected) == "table" then
		return installErrorClassifier(injected)
	end
	if typeof(injected) == "Instance" and injected:IsA("ModuleScript") then
		return installErrorClassifier(require(injected) :: any)
	end
	-- Scribe ships its own store (src/Internal/Store, a vendored fork of ProfileStore
	-- 1.0.3), so there is nothing to search for. The injection paths above let a game
	-- run against a different store, and give each simulated server a private copy of
	-- the module. Do not restore the old ServerPackages/Packages hunt: it would bind
	-- to an unpatched build whose Save() cannot report an outcome.
	return installErrorClassifier(require(Internal.Store) :: any)
end

function Persistence.new(ctx: any)
	local self = {} :: any
	local options = ctx.Options

	-- Bound on ONE StartSessionAsync attempt. ProfileStore's own START_SESSION_TIMEOUT
	-- applies only `if params.Cancel == nil`, and Scribe always passes a Cancel, so
	-- without this the load never returns during a DataStore outage and everything
	-- below it (PROFILE_LOAD_FAIL, LoadFailurePolicy) is unreachable.
	--
	-- Floored at 60s: ProfileStore steals a held session after SESSION_STEAL (40s), so
	-- a shorter deadline aborts every legitimate cross-server handoff.
	local loadTimeout: number = math.max(60, tonumber(options.LoadTimeout) or 120)
	local compiled: Template.Compiled = ctx.Compiled

	-- Storage location is explicit and never defaulted (see Scribe() guard).
	local storeIndex = options.ProfileStoreIndex
	if type(storeIndex) ~= "string" or storeIndex == "" then
		error("Scribe: ProfileStoreIndex is required — name your game's DataStore explicitly", 0)
	end
	-- "" is allowed and means bare user-id keys (see the Scribe() guard); only an
	-- absent or non-string prefix is an error.
	if type(options.ProfileKeyPrefix) ~= "string" then
		error(
			'Scribe: ProfileKeyPrefix is required — set a per-player key prefix (e.g. "PLAYER_"), or "" for bare user-id keys',
			0
		)
	end

	local ProfileStore = findProfileStoreModule(options.ProfileStore)

	-- Take shutdown off the store and drive it from Scribe's own drain. Roblox runs
	-- bound BindToClose callbacks concurrently in an undocumented order, and the
	-- store's releases every profile before its first yield, while Scribe's needs them
	-- still active to run each player's OnPlayerLeaving hook. When the store won, no
	-- leaving hook ran at all and nothing was logged. Guarded on the field existing,
	-- because an injected store need not have it.
	if type(ProfileStore) == "table" and ProfileStore.ExternalShutdown ~= nil then
		ProfileStore.ExternalShutdown = true
	end
	local persistentDefaults = Template.BuildDefaults(compiled, "Persistent")
	local baseStore = ProfileStore.New(storeIndex, persistentDefaults)
	-- Persistence mode. One value answers three questions: which store to read,
	-- whether to hold a session, and whether anything saves.
	--
	--   Live    real store, exclusive session, saves           (the default)
	--   Mock    ProfileStore's mock store, saves only there
	--   NoSave  real profile read as a snapshot, no session, never saves
	--
	-- Mode wins over the legacy flags whenever it is set; when it is absent they
	-- resolve to the equivalent mode, so existing configs are untouched.
	local VALID_MODES = { Live = true, Mock = true, NoSave = true }
	local mode: string
	local useMockStore: boolean
	local targetUserId: number? = options.TargetUserId

	if options.Mode ~= nil then
		if type(options.Mode) ~= "string" or not VALID_MODES[options.Mode] then
			error(`Scribe: Mode must be "Live", "Mock" or "NoSave", got {tostring(options.Mode)}`, 0)
		end
		mode = options.Mode
		useMockStore = mode == "Mock"
		local legacy = {}
		for _, name in { "UseMock", "DontSave", "ViewedUserId", "OverriddenUserId" } do
			if (options :: any)[name] ~= nil then
				table.insert(legacy, name)
			end
		end
		if #legacy > 0 then
			Log.Warn(
				"Persistence",
				"MODE_OVERRIDES_LEGACY",
				`Mode = "{mode}" is set, so the legacy flag(s) {table.concat(legacy, ", ")} are ignored`,
				{ Mode = mode, Ignored = table.concat(legacy, ", ") }
			)
		end
	else
		-- Legacy resolution. The old flags controlled two independent axes: the store
		-- came from UseMock/DontSave, the view branch from ViewedUserId. Keep them
		-- independent, or an existing config silently changes which store it reads.
		useMockStore = (options.UseMock or options.DontSave) == true
		if options.ViewedUserId ~= nil then
			mode = "NoSave"
			targetUserId = options.ViewedUserId
		elseif useMockStore then
			mode = "Mock"
		else
			mode = "Live"
			targetUserId = targetUserId or options.OverriddenUserId
		end
	end

	self.Mode = mode
	self.TargetUserId = targetUserId

	local store = if useMockStore then baseStore.Mock else baseStore

	-- Lower ProfileStore's autosave cadence so less progress is at risk on an unclean
	-- exit. AUTO_SAVE_PERIOD is a ProfileStore GLOBAL, so this affects every Scribe
	-- bundle and any direct ProfileStore use in the game; the last value wins. Floored
	-- at 15s because Roblox throttles per-key writes to roughly one per 6s.
	local function applyAutoSaveInterval(interval: number, source: string)
		if interval < MIN_SAVE_INTERVAL then
			Log.Warn(
				"Persistence",
				"SAVE_INTERVAL_CLAMPED",
				`autosave interval below the {MIN_SAVE_INTERVAL}s floor (DataStore write throttling); clamping`,
				{ Requested = interval, Applied = MIN_SAVE_INTERVAL }
			)
			interval = MIN_SAVE_INTERVAL
		end
		-- AUTO_SAVE_PERIOD is a process global, so two bundles asking for different
		-- cadences is a real conflict; unreported it resolves as last-writer-wins with
		-- the winner decided by require order.
		if Config.AutoSaveInterval ~= nil and Config.AutoSaveInterval ~= interval then
			Log.Warn(
				"Persistence",
				"SAVE_INTERVAL_CONFLICT",
				"autosave interval is a ProfileStore process global and was already set to a different value; "
					.. "the later value wins. Set it once with Scribe.Configure instead.",
				{ Existing = Config.AutoSaveInterval, Requested = interval, Source = source }
			)
		end
		if type(ProfileStore.SetConstant) == "function" then
			local ok, err = pcall(ProfileStore.SetConstant, "AUTO_SAVE_PERIOD", interval)
			if ok then
				Config.AutoSaveInterval = interval
				Config.AutoSaveSource = source
				Log.Info("Persistence", "SAVE_INTERVAL_SET", "autosave interval configured", {
					Seconds = interval,
					Source = source,
				})
			else
				Log.Warn("Persistence", "SAVE_INTERVAL_FAIL", tostring(err), {})
			end
		end
	end

	-- Scribe.Configure runs before any bundle exists, so apply its value here,
	-- where ProfileStore has been resolved.
	if Config.AutoSaveSource == "Configure" and Config.AutoSaveInterval ~= nil then
		local pending = Config.AutoSaveInterval
		Config.AutoSaveInterval = nil -- let applyAutoSaveInterval own the record
		applyAutoSaveInterval(pending, "Configure")
	end

	if options.SaveInterval ~= nil then
		local interval = options.SaveInterval
		if type(interval) ~= "number" or interval ~= interval or interval <= 0 then
			error("Scribe: SaveInterval must be a positive number of seconds", 0)
		end
		applyAutoSaveInterval(interval, "SaveInterval")
	end

	self.Store = store
	-- Connections this bundle makes to PROCESS-GLOBAL signals. They outlive the
	-- bundle unless released, so Stop() disconnects them; per-profile signals are
	-- not here because they die with the profile.
	local connections: { any } = {}
	self.Entries = {} :: { [Player]: Entry }
	-- Maintained alongside Entries rather than recomputed: an O(N) dict walk on every
	-- teardown makes draining a full server O(N^2) in session count.
	self.EntryCount = 0
	-- userId -> Entry, so a lookup by userId is not a linear scan over Entries.
	self.EntriesByUserId = {} :: { [number]: Entry }
	self.Closing = false
	-- Released by Data.Stop, and deliberately not the same flag as Closing. Closing
	-- means the SERVER is shutting down and carries three other jobs with it: aborting
	-- an in-flight load through the Cancel hook, marking a session end as ours rather
	-- than a steal, and quieting teardown. None of those apply to a Stop.
	--
	-- What this is for: the LoadFailurePolicy = "Wait" retry loop, which never gives
	-- up and whose only exit was Closing, so a stopped bundle kept retrying forever
	-- holding a profile-less Loading entry.
	self.Stopped = false
	-- Why the last session ended, for WaitForData callers arriving after a
	-- synchronous teardown (weak keys: entries vanish with the Player).
	self.EndReasons = setmetatable({}, { __mode = "k" }) :: any

	local keyPrefix: string = options.ProfileKeyPrefix
	local migrations: { [number]: (data: any) -> () } = options.Migrations or {}
	local currentVersion = 1
	for version in migrations do
		if type(version) ~= "number" or version % 1 ~= 0 or version < 2 then
			error("Scribe: Migrations keys must be integers >= 2", 0)
		end
		currentVersion = math.max(currentVersion, version)
	end
	for version = 2, currentVersion do
		if type(migrations[version]) ~= "function" then
			error(`Scribe: Migrations table is missing step {version}`, 0)
		end
	end
	self.CurrentVersion = currentVersion

	-- ProfileStore health signals (member names verified against v1.0.3).
	local baseStoreName = storeIndex
	local okErr = pcall(function()
		connections[#connections + 1] = ProfileStore.OnError:Connect(
			function(message: string, storeName: string, profileKey: string)
				-- OnError is module-global and fires for every DataStore error, other
				-- stores included. Only our store counts toward Health, and only an
				-- in-flight SAVE marks a save failure: a throttled version read for an
				-- online player must not fail their receipts and save state.
				if storeName ~= baseStoreName then
					return
				end
				-- Classified here rather than left to Failure.Report, because this is
				-- the one site that publishes the verdict in its own log context. The
				-- class and the raw numeric code are what make an error family Roblox
				-- adds later visible as unclassified instead of silently transient.
				local class = Failure.Classify(message)
				-- DataStoreErrors counts per ATTEMPT, which is what OnError is, so one
				-- failing save produces N errors here. SavesFailed is per-operation and
				-- stays behind the in-flight guard below. Health is fed every error,
				-- throttles included; the class only adds a dimension on the way out.
				Failure.Report({
					Subsystem = "ProfileStore",
					-- Keyed, so the store's own retries of one failing profile collapse
					-- into one problem. Unkeyed, a single oversize profile drove the
					-- whole server to Outage, which refuses Robux receipts for every
					-- other player on it.
					Key = profileKey,
					Error = message,
					Class = class,
					Metric = "DataStoreErrors",
					Category = "Persistence",
					Code = "PROFILE_STORE_ERROR",
					Message = tostring(message),
					Context = {
						Store = storeName,
						Key = profileKey,
						Class = class,
						-- nil when the message carried no code: the signal that either
						-- Roblox changed the shape or this is not a store error at all.
						Code = Failure.CodeOf(message),
					},
				})
				for _, entry in self.Entries :: { [Player]: Entry } do
					if entry.Key == profileKey and entry.SavesInFlight > 0 then
						-- Attribute this failure to a save genuinely on the wire. Testing a
						-- single-slot SaveT0 let an overlapping success clear it first, so a
						-- failure was attributed to nothing: LastResult stayed "Ok" and the
						-- Dirty restore never ran, while Monetization reads both to decide
						-- whether a duplicate receipt may be acknowledged. OnSettled fires
						-- exactly once per save call, so the counter cannot drift.
						entry.SaveInfo.LastResult = "Fail"
						-- A profile already over the size-warning threshold fails EVERY
						-- UpdateAsync until it is trimmed, which the developer must act on
						-- differently from a transient throttle.
						if entry.LiveSize and entry.LiveSize > SIZE_WARN_BYTES then
							Log.Error(
								"Persistence",
								"PROFILE_TOO_LARGE",
								`save failed and the profile is {entry.LiveSize} bytes (~4 MB DataStore ceiling); this will not recover until the profile is trimmed`,
								{ Player = entry.Player, Bytes = entry.LiveSize }
							)
						end
						-- The failed save's payload never persisted: restore the dirtiness
						-- captured at its start (plus anything written since).
						entry.SaveInfo.Dirty = entry.DirtyAtSaveStart or entry.SaveInfo.Dirty
						-- Deliberately NOT closing the Timed save window here. OnError is
						-- module-global and cannot prove the failing call was this entry's
						-- save, and closing it on an unrelated error points the profile back
						-- at live DEADLINES that the pending save then serializes as
						-- remaining seconds, so a rejoin reads a cooldown decades out.
						-- Everything above errs pessimistically; this one would corrupt.
						-- The window is self-healing anyway: the next BeforeSave re-derives
						-- the persisted copy from the live table.
						ctx.Signals.OnSave:Fire({ Player = entry.Player, Ok = false, Duration = nil, At = Clock.Now() })
						Metrics.Add("SavesFailed")
						self.UpdateSaveInfoMirror(entry)
					end
				end
			end
		)
	end)
	if not okErr then
		Log.Warn(
			"Persistence",
			"PROFILE_STORE_SIGNAL_MISSING",
			"ProfileStore.OnError not connectable; save-failure observability disabled",
			{}
		)
	end
	-- ProfileStore replaces a stored value it cannot recognise as a profile with a
	-- fresh template and fires OnOverwrite. That is silent, irreversible data loss
	-- that otherwise reaches the developer as nothing at all: the overwritten profile
	-- comes back at SessionLoadCount 1, so isNew is true, migrations are skipped and
	-- OnPlayerInit runs as if for a first-time player.
	local okOverwrite = pcall(function()
		connections[#connections + 1] = ProfileStore.OnOverwrite:Connect(function(storeName: string, profileKey: string)
			-- OnOverwrite is module-global; only our store is ours to report on.
			if storeName ~= baseStoreName then
				return
			end
			-- The entry may not exist yet (the overwrite happens during the load that
			-- creates it), so the player is best-effort and the key is the reliable id.
			local entry: Entry? = nil
			for _, candidate in self.Entries :: { [Player]: Entry } do
				if candidate.Key == profileKey then
					entry = candidate
					break
				end
			end
			Failure.Report({
				Subsystem = "ProfileOverwrite",
				Key = profileKey,
				-- No Error: OnOverwrite carries no message, so there is nothing to
				-- classify.
				Metric = "ProfilesOverwritten",
				Level = "Error",
				Category = "Integrity",
				Code = "PROFILE_OVERWRITTEN",
				Message = `stored data for key "{profileKey}" was not a valid profile and has been REPLACED with a fresh `
					.. "template by ProfileStore; this session starts from defaults and the previous data is gone. "
					.. "Restore from version history before the player saves over it",
				Context = { Player = if entry then entry.Player else nil, Store = storeName, Key = profileKey },
			})
			ctx.Signals.OnAnomaly:Fire({
				Player = if entry then entry.Player else nil,
				Path = {},
				Value = nil,
				Reason = "ProfileOverwritten",
			})
		end)
	end)
	if not okOverwrite then
		Log.Warn(
			"Persistence",
			"PROFILE_STORE_SIGNAL_MISSING",
			"ProfileStore.OnOverwrite not connectable; silent corruption-overwrite detection disabled",
			{}
		)
	end
	local okCrit = pcall(function()
		connections[#connections + 1] = ProfileStore.OnCriticalToggle:Connect(function(isCritical: boolean)
			Health.SetCritical(isCritical)
			if isCritical then
				Log.Error("Persistence", "DATASTORE_CRITICAL", "ProfileStore entered critical state", {})
			else
				Log.Info("Persistence", "DATASTORE_RECOVERED", "ProfileStore left critical state", {})
			end
		end)
	end)
	if not okCrit then
		Log.Warn("Persistence", "PROFILE_STORE_SIGNAL_MISSING", "ProfileStore.OnCriticalToggle not connectable", {})
	end

	function self.KeyFor(userId: number): string
		return keyPrefix .. tostring(userId)
	end

	function self.EntryFor(player: Player): Entry?
		return self.Entries[player]
	end

	function self.EntryForUserId(userId: number): Entry?
		return self.EntriesByUserId[userId]
	end

	local function setState(entry: Entry, state: "Loading" | "Ready" | "SessionEnded", reason: string?)
		entry.State = state
		entry.FailReason = reason
		entry.StateChanged:Fire(state, reason)
	end

	function self.UpdateSaveInfoMirror(entry: Entry)
		if entry.Tree and not entry.Tree.Dead then
			local accessor = entry.Tree.Accessor[Template.SESSION_ROOT].SaveInfo
			accessor.Set({
				LastSaveAt = entry.SaveInfo.LastSaveAt,
				LastResult = entry.SaveInfo.LastResult,
				Dirty = entry.SaveInfo.Dirty,
				Size = entry.LastSavedSize,
			})
		end
	end

	-- Deep-compare stored profile data against the current template defaults, skipping
	-- Scribe.Dynamic leaves (their samples differ per server boot) and comparing packed
	-- buffers by content. Detects a profile whose first session crashed before its
	-- first save: still template-shaped, but SessionLoadCount already past 1.
	local dynamicPathKeys: { [string]: boolean } = {}
	for _, node in compiled.DynamicNodes do
		dynamicPathKeys[Util.pathKey(node.Path :: any)] = true
	end
	local function templateEquals(a: any, b: any, pathKey: string?): boolean
		if pathKey ~= nil and dynamicPathKeys[pathKey] then
			return true
		end
		if type(a) == "buffer" and type(b) == "buffer" then
			return buffer.tostring(a) == buffer.tostring(b)
		end
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for k, v in a do
			local childKey = if pathKey then pathKey .. "\31" .. tostring(k) else tostring(k)
			if not templateEquals(v, (b :: { [any]: any })[k], childKey) then
				return false
			end
		end
		for k in b :: { [any]: any } do
			if (a :: { [any]: any })[k] == nil then
				return false
			end
		end
		return true
	end
	local function equalsTemplateDefaults(data: { [string]: any }): boolean
		return templateEquals(data, persistentDefaults, nil)
	end

	-- Commit a view-mode profile and report whether the write actually landed.
	-- Profile:SetAsync reports nothing on failure: a DataStore fault is swallowed by
	-- ProfileStore's own pcall and the call returns normally having written nothing,
	-- so a pcall around it always succeeds and the offline receipt path turns that
	-- into PurchaseGranted for Robux that were silently consumed. RegisterError fires
	-- OnError synchronously before UpdateAsync returns, so a connection held across
	-- the call is the only available failure signal.
	local function commitViewProfile(profile: any, key: string): (boolean, string?)
		local failure: string? = nil
		local ok, conn = pcall(function()
			return ProfileStore.OnError:Connect(function(message: string, _storeName: string, profileKey: string)
				if profileKey == key and failure == nil then
					failure = tostring(message)
				end
			end)
		end)
		local setOk, setErr = pcall(function()
			profile:SetAsync()
		end)
		if ok and conn then
			pcall(function()
				conn:Disconnect()
			end)
		end
		if not setOk then
			return false, tostring(setErr) -- a real misuse error, not infrastructure
		end
		if failure ~= nil then
			return false, `DataStore error during save: {failure}`
		end
		if not ok then
			-- Could not observe OnError at all, so success here is unverified. Say so
			-- rather than reporting a commit we cannot stand behind.
			return false, "could not observe ProfileStore.OnError; save result unverifiable"
		end
		return true, nil
	end

	-- Asymmetric diff for the DevMode migration shadow in finishLoad. Reports a path
	-- present on both sides with different values, or only on the shadow side; keys
	-- only on the REAL side are Reconcile's backfill and would fire for every legacy
	-- profile. RESERVED_ROOT is skipped whole because runMigrations stamps its Version
	-- and the shadow loop never does.
	local function divergences(shadow: any, real: any, path: { string }, out: { string })
		if #out >= 5 then
			return
		end
		if type(shadow) == "buffer" and type(real) == "buffer" then
			if buffer.tostring(shadow) ~= buffer.tostring(real) then
				table.insert(out, Util.pathString(path))
			end
			return
		end
		if type(shadow) ~= type(real) then
			table.insert(out, Util.pathString(path))
			return
		end
		if type(shadow) ~= "table" then
			if shadow ~= real then
				table.insert(out, Util.pathString(path))
			end
			return
		end
		for k, v in shadow do
			if #path == 0 and k == Template.RESERVED_ROOT then
				continue
			end
			table.insert(path, tostring(k))
			divergences(v, (real :: any)[k], path, out)
			table.remove(path)
			if #out >= 5 then
				return
			end
		end
	end

	-- Bounds on how far the profile may shrink before the wipe guard calls it a wipe,
	-- resolved once at startup so a bad value is reported rather than never. Both ends
	-- fail quietly: at 0 any shrink trips the guard, and under WipeGuardPolicy =
	-- "Block" it then keeps tripping (the unblock check is the same comparison), so
	-- live data never persists again. At 1 or above the guard can never fire. Negative
	-- makes (1 - ratio) exceed 1, so a profile that GREW trips it. The floor is not
	-- near-zero because a few percent of churn is ordinary gameplay.
	local WIPE_GUARD_RATIO_MIN = 0.05
	local WIPE_GUARD_RATIO_MAX = 0.95
	-- Block policy writes the last-good BYTES back as the save payload, so it is the
	-- one setting that needs the store to keep its full copy. Read from this one
	-- variable here and at the retention opt-out in finishLoad: if the two disagree,
	-- the guard persists an EMPTY profile, which is the wipe it exists to prevent.
	local wipeGuardBlocks: boolean = (options.WipeGuardPolicy or "Warn") == "Block"
	local wipeGuardRatio = WIPE_GUARD_RATIO_DEFAULT
	do
		local configured = options.WipeGuardShrinkRatio
		if configured ~= nil then
			local asNumber = tonumber(configured)
			local clamped = if asNumber == nil or asNumber ~= asNumber
				then WIPE_GUARD_RATIO_DEFAULT
				else math.clamp(asNumber, WIPE_GUARD_RATIO_MIN, WIPE_GUARD_RATIO_MAX)
			if clamped ~= configured then
				Log.Warn(
					"Persistence",
					"WIPE_GUARD_RATIO_CLAMPED",
					`WipeGuardShrinkRatio must be between {WIPE_GUARD_RATIO_MIN} and {WIPE_GUARD_RATIO_MAX}: `
						.. "at or below zero every shrink trips the guard (and under Block the profile never "
						.. "saves again), at or above one it can never trip and the guard is off",
					{ Requested = configured, Applied = clamped }
				)
			end
			wipeGuardRatio = clamped
		end
	end

	-- Wipe guard: compare against the last successful save. `liveSize` is the caller's
	-- already-computed Util.approxSize(entry.LiveData), passed in because
	-- onProfileSaving measures the same table in the same synchronous frame.
	local function wipeGuardCheck(entry: Entry, liveSize: number?): (boolean, string?)
		local profile = entry.Profile
		local live = entry.LiveData
		if not profile or not live then
			return false, nil
		end
		-- The baseline is a KEY SET and a size, not the bytes: both are recorded on the
		-- entry by the save that established them, so the store need not hold a second
		-- full copy of the profile. The store's copy is still the baseline in the two
		-- cases the summary cannot be: before the first save of a session, and under
		-- WipeGuardPolicy = "Block", which writes those bytes back as the payload.
		local keys: any = entry.LastSavedKeys
		local oldSize = entry.LastSavedSize
		if keys == nil then
			local lastSaved = profile.LastSavedData
			if type(lastSaved) ~= "table" or next(lastSaved) == nil then
				return false, nil
			end
			keys = lastSaved
			oldSize = oldSize or Util.approxSize(lastSaved)
		end
		local missing = {}
		for key in keys do
			if live[key] == nil then
				table.insert(missing, tostring(key))
			end
		end
		if #missing > 0 then
			return true, `top-level keys vanished: {table.concat(missing, ", ")}`
		end
		local ratio = wipeGuardRatio
		local newSize = liveSize or Util.approxSize(live)
		if oldSize and newSize and oldSize > 1024 and newSize < oldSize * (1 - ratio) then
			return true, `serialized size collapsed {oldSize} -> {newSize} bytes`
		end
		return false, nil
	end

	-- Wrapped rather than edited in place: the body returns early on the ForceSaveOnce
	-- and rebaseline paths, so a capture at the bottom of it would miss them. Reading
	-- entry.Blocked here runs synchronously inside the save, before it yields, so the
	-- flag still describes this payload rather than a later save's.
	local onProfileSavingInner: (entry: Entry) -> ()

	local function onProfileSaving(entry: Entry, saveContext: { [string]: any }?)
		onProfileSavingInner(entry)
		if saveContext then
			saveContext.Blocked = entry.Blocked == true
		end
	end

	function onProfileSavingInner(entry: Entry)
		-- The EARLIEST live start, not this save's. The slot is shared by every save in
		-- flight, so assigning it would let a later save overwrite an earlier one's t0
		-- and under-report the earlier save's duration. Holding the earliest can only
		-- report a save as slower than it was, never faster. Cleared on the drain to
		-- zero in OnSettled, the same moment as DirtyAtSaveStart.
		entry.SaveT0 = entry.SaveT0 or Clock.Monotonic()
		entry.SavesInFlight += 1
		-- This save's payload is serialized NOW: reset Dirty so it re-accumulates from
		-- writes landing after the snapshot, and keep the pre-snapshot state so a
		-- failed save can restore it (OnError path).
		--
		-- ACCUMULATED, not assigned. With N concurrent saves permitted, a second save
		-- starting while the first is on the wire would otherwise read back the false
		-- the first one wrote, and the first one's failure would restore clean over an
		-- unstored write. ORing errs toward dirty, which is the safe direction.
		-- Cleared when the count drains to zero in OnSettled.
		entry.DirtyAtSaveStart = entry.DirtyAtSaveStart or entry.SaveInfo.Dirty
		entry.SaveInfo.Dirty = false
		local profile = entry.Profile
		if not profile or not entry.LiveData then
			return
		end

		-- Measure the payload on the way IN, not only on save success: a profile past
		-- the ~4 MB DataStore ceiling makes every UpdateAsync throw, so the
		-- success-path check below would never run for it and the developer would see
		-- only generic retryable-looking failures. Latched to once per crossing.
		local liveSize = Util.approxSize(entry.LiveData)
		if liveSize then
			entry.LiveSize = liveSize
			if liveSize > SIZE_WARN_BYTES and not entry.SizeWarned then
				entry.SizeWarned = true
				Log.Warn(
					"Persistence",
					"PROFILE_SIZE",
					`profile approaching the ~4 MB DataStore ceiling ({liveSize} bytes); trim it or saves will start failing`,
					{ Player = entry.Player, Bytes = liveSize }
				)
				ctx.Signals.OnAnomaly:Fire({ Player = entry.Player, Path = {}, Value = nil, Reason = "ProfileSize" })
			elseif liveSize <= SIZE_WARN_BYTES then
				entry.SizeWarned = false
			end
		end

		if entry.ForceSaveOnce then
			entry.ForceSaveOnce = false
			if entry.Blocked then
				entry.Blocked = false
				profile:SetSaveSource(entry.LiveData)
				Log.Warn("Integrity", "WIPE_GUARD_FORCED", "blocked save forced through", { Player = entry.Player })
			end
			return
		end

		if entry.WipeGuardRebaselinePending then
			-- First save after a reshaping migration: the LastSavedData baseline
			-- predates it, so a comparison would false-trip on any key the migration
			-- intentionally removed. Cleared on save SUCCESS (onProfileSaved), not here:
			-- this hook fires per ATTEMPT, and clearing on a failed one re-arms the
			-- guard against the stale baseline, which under Block policy stalls the
			-- migration permanently.
			return
		end

		local tripped, reason = wipeGuardCheck(entry, liveSize)
		if tripped then
			Log.Error("Integrity", "WIPE_GUARD_TRIPPED", reason :: string, { Player = entry.Player })
			Metrics.Add("WipeGuardTrips")
			ctx.Signals.OnAnomaly:Fire({
				Player = entry.Player,
				Path = {},
				Value = nil,
				Reason = "WipeGuard: " .. (reason :: string),
			})
			if wipeGuardBlocks then
				-- Persist the last good snapshot instead; the live tree keeps
				-- its own root table. Unblocked when the guard passes again or
				-- via Data.Flush(player, { Force = true }).
				if not entry.Blocked then
					entry.Blocked = true
				end
				profile:SetSaveSource(Util.deepClone(profile.LastSavedData))
				Log.Warn("Integrity", "WIPE_GUARD_BLOCKED", "save held; persisting last good snapshot", {
					Player = entry.Player,
				})
			end
		elseif entry.Blocked then
			entry.Blocked = false
			profile:SetSaveSource(entry.LiveData)
			Log.Info("Integrity", "WIPE_GUARD_CLEARED", "wipe guard cleared; live data persists again", {
				Player = entry.Player,
			})
		end
	end

	local function onProfileSaved(entry: Entry, lastSavedData: any)
		-- ProfileStore fires OnAfterSave even when the session was STOLEN and nothing
		-- local persisted. Skip the success bookkeeping only for steals: a
		-- locally-initiated final save (clean leave, shutdown drain, migration
		-- fail-closed) genuinely persisted, and dropping it would skew Health.
		if entry.TornDown and entry.SessionStolen then
			return
		end
		local duration = if entry.SaveT0 then Clock.Monotonic() - entry.SaveT0 else nil
		entry.SaveInfo.LastSaveAt = Clock.Now()
		entry.SaveInfo.LastResult = "Ok"
		-- Keep any dirtiness accumulated from writes landing AFTER this save's payload
		-- snapshot (onProfileSaving reset the flag at that moment); blocked saves
		-- persisted old data, so live data stays unsaved regardless.
		entry.SaveInfo.Dirty = entry.SaveInfo.Dirty or entry.Blocked
		-- A successful, unblocked save re-established the wipe-guard baseline with the
		-- migrated shape; the one-time post-migration skip is complete.
		if not entry.Blocked then
			entry.WipeGuardRebaselinePending = false
		end
		Metrics.Add("SavesOk")
		if duration then
			Metrics.Observe("SaveDuration", duration)
		end
		Health.ReportSuccess("Saves")
		ctx.Signals.OnSave:Fire({ Player = entry.Player, Ok = true, Duration = duration, At = Clock.Now() })

		-- Record the size that actually persisted (the warning + anomaly are owned by
		-- the pre-save check in onProfileSaving, which also fires when a save fails).
		local size = Util.approxSize(lastSavedData)
		if size then
			entry.LastSavedSize = size
			entry.LiveSize = size
			Metrics.Observe("ProfileSize", size)
		end
		-- The other half of the wipe guard's baseline, taken from the payload that
		-- actually persisted rather than from live data -- a blocked save stores the
		-- last-good snapshot, and the baseline has to describe what is on the key.
		-- Top-level keys only, which is all the guard reads.
		if type(lastSavedData) == "table" then
			local keys: { [string]: true } = {}
			for key in lastSavedData do
				keys[key :: string] = true
			end
			entry.LastSavedKeys = keys
		end

		self.UpdateSaveInfoMirror(entry)
	end

	-- Does this stored session belong to a server that is still alive?
	--
	-- `profile.Session` is a straight read of MetaData.ActiveSession with no staleness
	-- allowance, and a server that dies before its final save leaves it set forever.
	-- The store steals a session whose LastUpdate is older than ASSUME_DEAD, so
	-- mirroring that threshold keeps the two from disagreeing: without it, players
	-- recovered on rejoin while RestoreVersion and Erase stayed refused permanently
	-- for the profile that most needs them. No usable LastUpdate reads as LIVE, which
	-- is the safe direction.
	local function sessionLooksLive(profile: any): boolean
		if not profile or not profile.Session then
			return false
		end
		local lastUpdate = profile.LastUpdate
		if type(lastUpdate) ~= "number" or lastUpdate <= 0 then
			return true
		end
		return (Clock.Now() - lastUpdate) <= ASSUME_DEAD_SECONDS
	end

	-- Release the lock WITHOUT writing Data back. Every fail-closed load path promises
	-- the stored bytes are left as found so the profile can be inspected and
	-- recovered, and EndSession breaks that: it is an unconditional save, and by the
	-- time those paths run profile.Data has been through CoerceMapKeys, Reconcile, the
	-- version stamp and the migration chain.
	--
	-- Falls back to a plain EndSession for an injected store without the primitive: a
	-- profile nobody can rejoin is worse than one that was rewritten.
	local function releaseWithoutWriting(profile: any)
		if type(profile.EndSessionWithoutSaving) == "function" then
			profile:EndSessionWithoutSaving()
		else
			profile:EndSession()
		end
	end

	-- Deep structural comparison for the reserved-root discard check in runMigrations.
	-- Nothing existing fits: Util.leafEquals is deliberately false for tables, Node's
	-- entryEquals is schema-driven, and templateEquals above skips nodes by their
	-- root-relative path key, so it would silently skip a reserved child sharing a
	-- name with one of the game's Dynamic root fields. Buffers compare by identity
	-- under `==`, hence the byte compare.
	local function deepSame(a: any, b: any): boolean
		if type(a) == "buffer" and type(b) == "buffer" then
			return Util.bufferEquals(a :: buffer, b :: buffer)
		end
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for k, v in a :: { [any]: any } do
			if not deepSame(v, (b :: { [any]: any })[k]) then
				return false
			end
		end
		for k in b :: { [any]: any } do
			if (a :: { [any]: any })[k] == nil then
				return false
			end
		end
		return true
	end

	-- Do these two reserved roots agree? `compareVersion` decides whether the TOP-LEVEL
	-- `Version` key counts, and is required rather than defaulted because the two call
	-- sites want opposite answers:
	--
	--   * MIGRATION passes `false`. The library re-stamps Version right after the
	--     chain, so a step that only moved the number changed nothing worth reporting.
	--   * RESTORE passes `true`. There is no re-stamp there, so Version is the single
	--     field deciding whether the chain re-runs against the older-shaped data the
	--     restore just wrote, and excluding it made the commonest restore silent.
	--
	-- A `Version` key one level down always counts, in both modes.
	local function reservedUnchanged(stored: { [string]: any }, other: any, compareVersion: boolean): boolean
		if type(other) ~= "table" then
			return false
		end
		for k, v in stored do
			if (compareVersion or k ~= "Version") and not deepSame(v, (other :: { [string]: any })[k]) then
				return false
			end
		end
		for k in other :: { [string]: any } do
			if (compareVersion or k ~= "Version") and stored[k] == nil then
				return false
			end
		end
		return true
	end

	local function runMigrations(entry: Entry, data: { [string]: any }): boolean
		local reserved = data[Template.RESERVED_ROOT]
		local stored = if type(reserved) == "table" and type(reserved.Version) == "number" then reserved.Version else 1
		if stored > currentVersion then
			-- Data was migrated by a newer deploy this server's code has never
			-- seen. Fail closed by default (VersionAheadPolicy "Kick") so an old
			-- server can't corrupt newer-shaped data; "Allow" opts into running
			-- old code against it (documented staged-deploy hazard).
			local policy = options.VersionAheadPolicy or "Kick"
			if policy == "Kick" then
				Log.Error(
					"Persistence",
					"PROFILE_VERSION_AHEAD",
					"stored version is newer than this server's; failing closed",
					{
						Player = entry.Player,
						Stored = stored,
						Current = currentVersion,
					}
				)
				return false
			end
			Log.Warn(
				"Persistence",
				"PROFILE_VERSION_AHEAD",
				"stored version is newer than this server's (VersionAheadPolicy=Allow)",
				{
					Player = entry.Player,
					Stored = stored,
					Current = currentVersion,
				}
			)
			return true
		end
		if stored == currentVersion then
			return true
		end
		-- Run migrations on a working clone; only commit on full success so a
		-- half-migrated profile can never persist.
		local work = Util.deepClone(data)
		for version = stored + 1, currentVersion do
			local ok, err = xpcall(function()
				migrations[version](work)
			end, function(e)
				return debug.traceback(tostring(e), 2)
			end)
			if not ok then
				Log.Error("Persistence", "MIGRATION_FAIL", `migration step {version} failed: {err}`, {
					Player = entry.Player,
					Step = version,
				})
				Metrics.Add("MigrationsFailed")
				return false
			end
		end
		-- PRESERVE THE RESERVED ROOT. `_Scribe` is library-owned state (receipt dedupe
		-- ring, gift escrow, credits, perks, purchase logs, Timed deadlines) and the
		-- migration chain is entirely game-supplied, so a step that rebuilds the profile
		-- from its own key whitelist destroys receipt idempotency and paid-for gifts,
		-- silently and durably. Reconcile has already run, so nothing the library has
		-- gained since this profile was written is missing from the stored root.
		--
		-- Assigned BY REFERENCE: table.clear(data) below does not recurse, so this table
		-- survives and returns through the copy loop as the same object; the migration
		-- was handed `work`, a deep clone, so there is no aliasing hazard. Ordered
		-- BEFORE the unpersistable scan so the scan sees exactly what commits.
		local storedReserved = data[Template.RESERVED_ROOT]
		local migratedReserved = work[Template.RESERVED_ROOT]
		if type(storedReserved) == "table" then
			work[Template.RESERVED_ROOT] = storedReserved
			-- Reverting a developer's edit in silence is its own trap, so a discard is
			-- reported at Error, which also fires OnIssue. `false`: the stamp below
			-- rewrites `Version` unconditionally, so a step that only moved the number
			-- changed nothing that survives this function.
			if not reservedUnchanged(storedReserved, migratedReserved, false) then
				Log.Error(
					"Persistence",
					"MIGRATION_RESERVED_DISCARDED",
					`a migration step changed the reserved "{Template.RESERVED_ROOT}" root; the change was DISCARDED `
						.. `and the stored reserved state kept (it is library-owned: receipt dedupe, gift escrow, `
						.. `perks, purchase logs, Timed) -- migrate your own keys only`,
					{ Player = entry.Player, Path = Template.RESERVED_ROOT, Stored = stored, Current = currentVersion }
				)
			end
		elseif type(migratedReserved) ~= "table" then
			-- Nothing stored to preserve (a legacy or imported profile that never had a
			-- reserved root) and the chain did not leave one either, so make somewhere
			-- for the stamp below to go. A root a migration CREATED is kept as it built
			-- it: nothing was destroyed, so nothing is reported.
			work[Template.RESERVED_ROOT] = {}
		end

		-- Migration functions mutate `work` raw, bypassing Node.validateWrite, so a
		-- step that introduces unpersistable data (invalid-UTF-8 string/key, or a
		-- userdata/Instance/function value) would fail every save. Scan BEFORE
		-- committing into `data`, so failure takes the same fail-closed path below
		-- (the unmodified original persists).
		local badMigrated = Util.findUnpersistable(work)
		if badMigrated ~= nil then
			Log.Error(
				"Persistence",
				"MIGRATION_FAIL",
				`migration produced unpersistable data ({badMigrated.Detail}) at "{Util.pathString(badMigrated.Path)}"`,
				{ Player = entry.Player, Path = Util.pathString(badMigrated.Path) }
			)
			Metrics.Add("MigrationsFailed")
			return false
		end

		-- The stamp goes HERE, below every `return false` above, and moving it up is a
		-- data bug: on the preserve path `work[RESERVED_ROOT]` is `data[RESERVED_ROOT]`
		-- itself, so this writes straight into the live profile.Data and the
		-- unpersistable scan above can still reject after it. Stamped earlier, a
		-- rejected migration leaves the caller's all-default carve-out comparing
		-- against a profile already marked migrated, and it kicks a player that
		-- carve-out exists to load.
		work[Template.RESERVED_ROOT].Version = currentVersion
		table.clear(data)
		for k, v in work do
			data[k] = v
		end
		Log.Info("Persistence", "MIGRATED", `profile migrated {stored} -> {currentVersion}`, { Player = entry.Player })
		-- A migration may legitimately remove or rename top-level keys, but the wipe
		-- guard's baseline still holds the pre-migration shape until the first save
		-- commits. Skip the guard for that one save, or under WipeGuardPolicy = "Block"
		-- it re-persists the old data and stalls the migration permanently.
		entry.WipeGuardRebaselinePending = true
		return true
	end

	local function buildTree(entry: Entry)
		local profile = entry.Profile
		entry.LiveData = profile.Data
		entry.SessionStore = Template.BuildDefaults(compiled, "Session")

		entry.Tree = Node.NewTree({
			Compiled = compiled,
			Stores = { Persist = profile.Data, Session = entry.SessionStore },
			IsServer = true,
			Label = entry.Player.Name,
			OnOp = function(op, schema)
				local persists = if schema then schema.Persist else Template.PersistOf(compiled, op.Path)
				if persists and not entry.SaveInfo.Dirty then
					entry.SaveInfo.Dirty = true
					Sched.Defer(function()
						if entry.Tree and not entry.Tree.Dead and entry.SaveInfo.Dirty then
							self.UpdateSaveInfoMirror(entry)
						end
					end)
				end
				ctx.Replication.PushOp(entry, op, schema)
			end,
			OnAnomaly = function(path, value, reason)
				Metrics.Add("Anomalies")
				Log.Warn("Integrity", "ANOMALY", `implausible write at "{Util.pathString(path)}": {reason}`, {
					Player = entry.Player,
					Path = Util.pathString(path),
					Reason = reason,
				})
				ctx.Signals.OnAnomaly:Fire({ Player = entry.Player, Path = path, Value = value, Reason = reason })
			end,
			BoundsPolicy = options.BoundsPolicy or "Clamp",
			DevMode = ctx.DevMode,
			TimedHooks = ctx.Timed.HooksFor(entry),
			OnEconomy = function(path, delta, newValue, tags)
				ctx.Analytics.Economy(entry.Player, path, delta, newValue, tags)
			end,
			LogError = function(message)
				Log.Error("Lifecycle", "LISTENER_ERROR", message, { Player = entry.Player })
			end,
			LogWarn = function(message)
				Log.Warn("Lifecycle", "DEV_WARNING", message, { Player = entry.Player })
			end,
			OnBatchEnd = function()
				ctx.Replication.FlushEntry(entry)
			end,
			OnDerivedIssue = function(code, field, detail)
				-- MISMATCH is a dev-mode purity report, not a live fault; the other
				-- two mean a field is serving a value its inputs no longer justify.
				local report = if code == "DERIVED_MISMATCH" then Log.Warn else Log.Error
				report("Derived", code :: any, `"{field}": {detail}`, { Player = entry.Player, Field = field })
			end,
		})
	end

	-- Run the game's OnPlayerLeaving hook. Runs BEFORE EndSession, which performs the
	-- final save, so anything written here lands. Errors are contained: a throwing
	-- hook must not skip the save it was meant to contribute to.
	local function runLeavingHook(entry: Entry, reason: string)
		local hook = ctx.Options.OnPlayerLeaving
		-- The hook runs under a plain pcall, so one that yields parks the whole leave
		-- with the entry still in self.Entries and the shutdown drain then walks it
		-- again. A double fire double-counts the hook's writes into one final save.
		if hook == nil or entry.LeavingHookRan then
			return
		end
		entry.LeavingHookRan = true
		if entry.State ~= "Ready" or entry.Tree == nil then
			return -- never loaded, so there is nothing coherent to hand it
		end
		local ok, err = pcall(hook, entry.Player, entry.Tree.Accessor, reason)
		if not ok then
			Log.Error(
				"Lifecycle",
				"LISTENER_ERROR",
				`OnPlayerLeaving errored; the save continues without its writes: {tostring(err)}`,
				{ Player = entry.Player }
			)
		end
	end

	local function teardown(entry: Entry, reason: string?)
		if entry.TornDown then
			return
		end
		entry.TornDown = true
		-- One canonical reason reaches every consumer: the SessionEnded signal, the
		-- stored end reason, and WaitForData's second return (see
		-- Types.LifecycleReason). Defaulting it in only some of those makes them
		-- disagree.
		local canonical: string = reason or "session-ended"
		self.EndReasons[entry.Player] = canonical

		-- A Data.OnMessage handler that yields and never returns holds its FireTracked
		-- open forever, so no ack and no other code is ever emitted while the message
		-- is re-offered on every load, climbing toward MESSAGE_QUEUE_FULL. Withholding
		-- the ack is correct; being silent about it is not.
		--
		-- Reported at session end rather than on a timer, because no threshold is right
		-- (a handler spending a throttled round trip is slow, not stuck) and this is the
		-- moment the fact stops being provisional. Warn, not Error: a player leaving
		-- while a handler is legitimately mid-yield reads identically, and it is
		-- repetition across sessions that tells the two apart.
		local unsettled = entry.UnsettledMessages or 0
		if unsettled > 0 then
			Log.Warn(
				"Persistence",
				"MESSAGE_HANDLER_STALLED",
				"a Data.OnMessage handler had not returned when the session ended; the message was NOT "
					.. "acknowledged and will be redelivered on the next load",
				{ Player = entry.Player, Outstanding = unsettled }
			)
		end

		-- SessionEnded fires before the (default-on) kick.
		ctx.Signals.SessionEnded:Fire(entry.Player, canonical)
		setState(entry, "SessionEnded", canonical)

		ctx.Replication.OnEntryRemoved(entry)
		ctx.Leaderboards.OnUnload(entry)
		ctx.Monetization.OnUnload(entry)
		ctx.Timed.OnUnload(entry)

		if entry.Tree then
			entry.Tree:Destroy()
		end

		if
			options.KickOnSessionEnd ~= false
			and not self.Closing
			-- ...and not because this bundle was released. A Stop is not a session
			-- ending badly, so kicking the player would be a lie told by a bundle
			-- that no longer exists.
			and not self.Stopped
			and canonical ~= "player-left"
			and entry.Player.Parent == Players
		then
			entry.Player:Kick(options.SessionEndMessage or "Your data session has ended. Please rejoin!")
		end

		-- Only adjust the maintained counters if this entry was still the live one
		-- for its player: teardown can run more than once for a session, and a
		-- rejoin can already have installed a NEWER entry under the same Player.
		if self.Entries[entry.Player] == entry then
			self.Entries[entry.Player] = nil
			self.EntryCount -= 1
		end
		if self.EntriesByUserId[entry.UserId] == entry then
			self.EntriesByUserId[entry.UserId] = nil
		end
		Metrics.Set("ActiveSessions", self.EntryCount)
	end

	local function finishLoad(entry: Entry)
		local profile = entry.Profile :: any
		local player = entry.Player

		-- Stop the store holding a second full copy of this profile for the rest of the
		-- session. Everything Scribe reads from it, the wipe guard's top-level key set
		-- and its size, is recorded on the entry by each successful save, and the store
		-- still hands the real table to that handler. Not under Block policy, which
		-- persists those bytes back and therefore needs them.
		if not wipeGuardBlocks and type(profile.SetRetainLastSaved) == "function" then
			profile:SetRetainLastSaved(false)
		end

		-- A brand-new profile's very first session ever. In-place ProfileStore adoption
		-- keeps the session count from the old game, so returning players are not
		-- flagged new and still migrate normally.
		--
		-- SessionsStarted rather than the raw SessionLoadCount: a view is fetched with
		-- GetAsync, which never runs the session-start increment, so read raw a dry run
		-- of an already-loaded profile is judged brand new and skips every migration it
		-- exists to exercise.
		local isNew = profile:SessionsStarted() == 1

		-- Snapshot BEFORE AddUserId mutates the in-memory list. This is the
		-- discriminator the template-fresh check further down needs: without it a
		-- returning player who never earned anything is indistinguishable from a
		-- crashed first session, and their migrations are skipped. The negative-id
		-- exclusion is here because AddUserId no-ops for one outside mock, so the
		-- signal can never accumulate. Hoisted above the legacy import, which gates on
		-- it too.
		local hadPriorSave = entry.UserId >= 0 and profile:HasCompletedSave()

		-- Legacy import ---------------------------------------------------------
		--
		-- Adopt a player's data from another library, ONCE, before Scribe has written
		-- for them. Gated on hadPriorSave rather than `isNew`: SessionLoadCount
		-- advances when a session STARTS, so a first join whose save never committed
		-- leaves the player non-new with nothing stored, and gating on `isNew` would
		-- refuse the import while the empty profile Scribe then saved became canonical.
		--
		-- Skipped under NoSave, a read-only view: importing there would run the
		-- developer's hook for a dry run that cannot persist the result anyway.
		local imported = false
		if
			options.ImportLegacyData ~= nil
			and not hadPriorSave
			and not options.ResetData
			and mode ~= "NoSave"
			and not entry.TornDown
		then
			-- YIELDS: the hook exists to read another library's key, and everything
			-- below assumes a live session, so the liveness re-check moves up here
			-- rather than being left to the one further down.
			local ok, legacy = xpcall(options.ImportLegacyData, function(e)
				return debug.traceback(tostring(e), 2)
			end, player, entry.UserId)

			if not ok then
				-- Fail closed, the same shape as a failed migration: a hook that threw
				-- could not tell us whether legacy data exists, and loading the player
				-- on an empty profile makes emptiness canonical at their first save,
				-- after which hadPriorSave is true forever and the import never runs.
				--
				-- EndSession below writes template defaults for a brand-new profile, and
				-- that must not count as a prior save or a transient outage strands the
				-- legacy data for good. It does not, because profile:AddUserId runs
				-- further down, so the UserIds list this write persists is still empty.
				-- Hoisting AddUserId above the import would turn a retryable outage into
				-- permanent data loss.
				Metrics.Add("LegacyImportFailures")
				Log.Error(
					"Persistence",
					"LEGACY_IMPORT_FAIL",
					`ImportLegacyData threw, so it is unknown whether this player has data to carry over. `
						.. `Refusing the load rather than starting them empty: {legacy}`,
					{ Player = player, UserId = entry.UserId }
				)
				entry.LocalSessionEnd = true
				releaseWithoutWriting(profile)
				if player.Parent == Players then
					player:Kick(options.LoadFailureMessage or "We couldn't load your data. Please rejoin!")
				end
				teardown(entry, "load-failed")
				return
			end

			-- The hook yielded. A player who left in that window would leave Reconcile,
			-- the migration chain, the schema check and OnPlayerInit running against a
			-- session that is already gone. The guard further down catches later
			-- yields; this one exists because this yield happens for every new player.
			if not profile:IsActive() then
				teardown(entry, if player.Parent == Players then "session-ended" else "player-left")
				return
			end

			if type(legacy) == "table" then
				-- A returned table means "this player is an import", even an empty one;
				-- nil means "nothing to carry over". A hook must THROW rather than
				-- return nil when it could not find out, because the two are
				-- indistinguishable here and only one is safe to act on.
				local adopted = 0
				for key, value in legacy do
					-- Scribe's own roots are never adopted, and the prefix test catches
					-- both ("_ScribeSession" starts with "_Scribe"), which is intended.
					-- Letting an import write into _Scribe would hand the old library
					-- control of purchase-dedupe ids, granted perks and cooldowns.
					if
						type(key) == "string"
						and string.sub(key, 1, #Template.RESERVED_ROOT) == Template.RESERVED_ROOT
					then
						continue
					end
					profile.Data[key] = value
					adopted += 1
				end
				imported = true
				Metrics.Add("LegacyImports")
				Log.Info(
					"Persistence",
					"LEGACY_IMPORTED",
					`adopted {adopted} top-level key(s) from ImportLegacyData; the profile will run the full `
						.. "migration chain from version 1",
					{ Player = player, UserId = entry.UserId, Keys = adopted }
				)
			end
		end

		-- Decide which Scribe.Dynamic fields to seed BEFORE Reconcile backfills their
		-- baseline: all of them on a brand-new profile, plus any the STORED data is
		-- missing. Reading the stored data first is the safety guarantee, since a saved
		-- value is present and so is never flagged or overwritten.
		local dynamicToSeed: { any } = {}
		if #compiled.DynamicNodes > 0 then
			for _, node in compiled.DynamicNodes do
				local present = true
				local at: any = profile.Data
				for _, seg in node.Path do
					if type(at) ~= "table" or at[seg] == nil then
						present = false
						break
					end
					at = at[seg]
				end
				-- ResetData wipes to persistentDefaults, which carry each Dynamic
				-- field's frozen declaration-time sample, so a reset must re-seed
				-- exactly like a new profile or the player keeps the shared sample.
				--
				-- `isNew and not imported`: an imported profile is new to Scribe but
				-- not to the player, so a Dynamic value the import carried is left
				-- alone; the presence test below covers the fields it did not bring.
				if (isNew and not imported) or options.ResetData or not present then
					table.insert(dynamicToSeed, node)
				end
			end
		end

		profile:AddUserId(entry.UserId)

		-- Keep the RAW pre-Reconcile bytes so the shadow run below can show what the
		-- migrations would have seen without the backfill.
		--
		-- Opt-in and NOT gated on Studio or DevMode: the shadow re-EXECUTES your
		-- migration bodies against a clone, so any side effect in them fires a second
		-- time, which is not something to turn on unannounced. `not isNew or imported`:
		-- an imported profile runs the whole chain against real adopted data, which is
		-- the run an audit most wants to shadow.
		--
		-- Gated on the stored version here too, or a mature game pays a full profile
		-- deep clone on every join for a shadow run that then declines to happen. This
		-- pre-Reconcile read is conservative (no marker reads as nil and still clones);
		-- the post-Reconcile read below stays authoritative for whether it runs.
		local preReconcileReserved = profile.Data[Template.RESERVED_ROOT]
		local preReconcileVersion = if type(preReconcileReserved) == "table"
				and type(preReconcileReserved.Version) == "number"
			then preReconcileReserved.Version
			else nil
		local rawStored: { [string]: any }? = if options.MigrationShadow == true
				and (not isNew or imported)
				and not options.ResetData
				and (preReconcileVersion == nil or preReconcileVersion < currentVersion)
			then Util.deepClone(profile.Data)
			else nil

		-- Before Reconcile: integer map keys arrive from the DataStore as JSON
		-- strings, and every read after this point expects the declared key type.
		Template.CoerceMapKeys(compiled, profile.Data)

		profile:Reconcile()

		-- A hard crash inside the very first session persists template-shaped data with
		-- the default Version while SessionLoadCount advanced past 1. Detect that shape
		-- and treat the profile as fresh, or every migration runs against effectively
		-- new-player defaults. Gated to migrating profiles, so the deep compare is rare.
		-- Hoisted to function scope: the fail-closed carve-out below needs it, and
		-- re-reading it there would yield currentVersion after the stamp.
		local storedReserved = profile.Data[Template.RESERVED_ROOT]
		local storedVersion = if type(storedReserved) == "table" and type(storedReserved.Version) == "number"
			then storedReserved.Version
			else 1

		local freshAsTemplate = false
		if not isNew and not options.ResetData then
			if storedVersion < currentVersion then
				-- Only claim "template-fresh" when no completed save is on record. A
				-- returning player who never earned anything has identical bytes, and
				-- treating them as new skipped every migration for them.
				freshAsTemplate = not hadPriorSave and equalsTemplateDefaults(profile.Data)
				if freshAsTemplate then
					Log.Info(
						"Persistence",
						"PROFILE_LOADED",
						"stored data is template-fresh and no completed save is recorded; treating as new",
						{ Player = player }
					)
					-- Effectively a brand-new player: re-seed every Dynamic field too
					-- (the stored values are a dead boot's declaration-time samples).
					table.clear(dynamicToSeed)
					for _, node in compiled.DynamicNodes do
						table.insert(dynamicToSeed, node)
					end
				end
			end
		end

		if options.ResetData then
			local fresh = Util.deepClone(persistentDefaults)
			table.clear(profile.Data)
			for k, v in fresh do
				profile.Data[k] = v
			end
			Log.Warn("Persistence", "PROFILE_RESET", "profile reset via ResetData option", { Player = player })
		end

		-- Fresh data (a brand-new profile, or a ResetData wipe) is built entirely from
		-- the CURRENT template, so stamp it and let runMigrations no-op. Migrations
		-- reshape older stored data, and running them against fresh defaults
		-- double-applies: a one-time compensation grant handed to a new player, or a
		-- rename step overwriting a field's default with nil.
		--
		-- `not imported` is the whole point of the import hook. Adopted data has never
		-- seen a Scribe migration, so it enters at version 1 and runs the entire chain;
		-- stamping it current here would skip every step.
		if (isNew or options.ResetData or freshAsTemplate) and not imported then
			local reserved = profile.Data[Template.RESERVED_ROOT]
			if type(reserved) == "table" then
				reserved.Version = currentVersion
			end
		end

		if not runMigrations(entry, profile.Data) then
			-- Carve-out for a returning player whose stored data is still nothing but
			-- current-template defaults. Fail-closed exists to protect real stored
			-- bytes and this profile has none, so kicking would manufacture a permanent
			-- outage for players who load fine today. Load them, but do NOT stamp the
			-- version, so the chain retries every join and lands once the migration is
			-- fixed. runMigrations already logged MIGRATION_FAIL at Error.
			local allDefaults = not freshAsTemplate
				and storedVersion < currentVersion
				and equalsTemplateDefaults(profile.Data)
			if allDefaults then
				Log.Warn(
					"Persistence",
					"MIGRATION_FAIL",
					"migration failed against an all-default returning profile; loading it un-migrated "
						.. "and UNSTAMPED (nothing but template defaults is at risk). It retries on every "
						.. "join until the migration is fixed.",
					{ Player = player }
				)
			else
				-- Fail-closed: never persist a half-migrated profile. Migrations ran on
				-- a clone and runMigrations stamps the reserved Version only after its
				-- last rejection, so profile.Data is untouched on every path that
				-- returns false.
				entry.LocalSessionEnd = true
				releaseWithoutWriting(profile)
				if player.Parent == Players then
					player:Kick(options.LoadFailureMessage or "We couldn't load your data. Please rejoin!")
				end
				teardown(entry, "migration-failed")
				return
			end
		end

		-- DevMode only, zero behavior change. Reconcile runs BEFORE migrations, so a
		-- migration body reaching through a static sub-record or a scalar default reads
		-- a value Reconcile manufactured rather than one the player stored, and the two
		-- commonest guarded shapes silently no-op. Reordering is not the fix (it
		-- nil-indexes raw data and fail-closed kicks every legacy player), so re-run
		-- the chain against the raw bytes and report when the two disagree.
		if rawStored ~= nil and not freshAsTemplate and storedVersion < currentVersion then
			local shadowOk = true
			for version = storedVersion + 1, currentVersion do
				local step = migrations[version]
				if step then
					local ok, err = xpcall(step, function(e)
						return debug.traceback(tostring(e), 2)
					end, rawStored)
					if not ok then
						shadowOk = false
						Log.Warn(
							"Persistence",
							"MIGRATION_RECONCILE_DEPENDENT",
							`migration step {version} succeeds only because Reconcile backfilled a template `
								.. `key before it ran. Against the raw stored data it throws: {err}`,
							{ Player = player, Step = version }
						)
						break
					end
				end
			end
			if shadowOk then
				local diffs = {}
				divergences(rawStored, profile.Data, {}, diffs)
				if #diffs > 0 then
					Log.Warn(
						"Persistence",
						"MIGRATION_RECONCILE_DEPENDENT",
						"migrations produce a different result against the raw stored data (a guarded step "
							.. "saw a Reconcile-backfilled default instead of nil): "
							.. table.concat(diffs, ", "),
						{ Player = player }
					)
				end
			end
		end

		-- Reconcile only fills STATIC template keys; ArrayOf/DictOf element fields hang
		-- off AnyChild and would never reach stored entries. Backfilled after
		-- migrations for two reasons: a migration must observe the raw stored element
		-- data (a guarded rename would otherwise see a backfilled default and destroy
		-- the real value), and the version-ahead fail-closed path above must end the
		-- session with the stored bytes untouched.
		if Template.ReconcileElements(compiled, profile.Data) then
			entry.SaveInfo.Dirty = true
		end

		-- Stored-shape check, opt-in. After Reconcile and ReconcileElements on purpose:
		-- before them every field the template has gained since this profile was
		-- written is still absent, and each one would be reported on a profile about to
		-- be brought up to date anyway.
		--
		-- Defaults to "Warn" in DevMode and off on live. Left fully off, the five
		-- violation kinds nothing else catches (schema-relative WrongType, OutOfBounds,
		-- OverMaxLength, NotAMember, UnknownKey) stay silent for every default install.
		-- Turned on live it is worse than useless on an upgraded game: ordinary template
		-- evolutions report, and UnknownKey fires once per stored element, so one
		-- retired field on a 40-item inventory fills the whole limit and buries the real
		-- findings. An explicit SchemaPolicy always wins, in both directions.
		local schemaPolicy = options.SchemaPolicy
		if schemaPolicy == nil and ctx.DevMode then
			schemaPolicy = "Warn"
		end
		if schemaPolicy ~= nil then
			local violations = Conform.Check(compiled, profile.Data)
			if #violations > 0 then
				-- ADVISORY VIOLATIONS NEVER END A SESSION, even under "Reject"; the
				-- long form is on the Violation type in Conform. Only a table mixing
				-- array indices with string keys actually fails the DataStore save, so
				-- only that one is worth a kick. The caps in particular fire on a state
				-- Scribe's own write path calls legal, and rejecting them kicked the
				-- player on every rejoin forever, since releaseWithoutWriting leaves
				-- the bytes as they are.
				--
				-- ANY non-advisory violation rejects: one unstorable table still ends
				-- the session however many advisory findings sit beside it.
				local reject = false
				if schemaPolicy == "Reject" then
					for _, violation in violations do
						if not violation.Advisory then
							reject = true
							break
						end
					end
				end
				for _, violation in violations do
					Metrics.Add("SchemaViolations")
					-- Advisory findings stay at Warn even on a rejecting load, so the
					-- level says which one actually cost the player the session.
					local report = if reject and not violation.Advisory then Log.Error else Log.Warn
					report("Persistence", "PROFILE_SCHEMA_VIOLATION", violation.Detail, {
						Player = player,
						Path = table.concat(violation.Path :: any, "."),
						Kind = violation.Kind,
						Advisory = violation.Advisory == true,
					})
					ctx.Signals.OnAnomaly:Fire({
						Player = player,
						Path = violation.Path,
						Reason = violation.Kind,
					})
				end

				if reject then
					-- Fail-closed, the same shape as the migration failure above: the
					-- session ends rather than serving a profile that does not match the
					-- template, and the stored bytes are left alone. See
					-- releaseWithoutWriting for why EndSession will not do here.
					entry.LocalSessionEnd = true
					releaseWithoutWriting(profile)
					if player.Parent == Players then
						player:Kick(options.LoadFailureMessage or "We couldn't load your data. Please rejoin!")
					end
					teardown(entry, "load-failed")
					return
				end
			end
		end

		-- Seed the flagged Scribe.Dynamic fields now that Reconcile has created any
		-- parent containers, before OnPlayerInit so it can still override. Written
		-- raw into profile.Data (the factory already packs datatypes); the tree
		-- wraps this same table, so the values are live and will save.
		if #dynamicToSeed > 0 then
			for _, node in dynamicToSeed do
				local ok, value = pcall(node.Factory :: () -> any)
				if not ok then
					Log.Error(
						"Lifecycle",
						"DYNAMIC_DEFAULT_FAILED",
						`Scribe.Dynamic factory for "{Util.pathString(node.Path)}" threw: {value}`,
						{ Player = player, Path = Util.pathString(node.Path) }
					)
				else
					local container: any = profile.Data
					for i = 1, #node.Path - 1 do
						container = if type(container) == "table" then container[node.Path[i]] else nil
					end
					if type(container) == "table" then
						container[node.Path[#node.Path]] = value
					end
				end
			end
			entry.SaveInfo.Dirty = true
		end

		if ctx.DevMode then
			local unknown = Template.UnknownRootKeys(compiled, profile.Data)
			if #unknown > 0 then
				Log.Warn(
					"Persistence",
					"UNKNOWN_ROOT_KEYS",
					"profile contains top-level keys absent from the template "
						.. "(removing keys is a migration's job)",
					{
						Player = player,
						Keys = table.concat(unknown, ", "),
					}
				)
			end
		end

		if options.OnPlayerInit then
			-- A brand-new profile, a ResetData wipe, or a first-session crash recovery
			-- all mean "no prior saved data", which is what starter kits and welcome
			-- flows need. An IMPORTED profile is the one case where new-to-Scribe is not
			-- new-to-the-player: they arrive carrying a full inventory, and the starter
			-- kit on top is the exact double-grant this flag prevents elsewhere.
			local isNewProfile = (isNew or options.ResetData == true or freshAsTemplate) and not imported
			Util.safeCall(function(err)
				Log.Error("Lifecycle", "ON_PLAYER_INIT_ERROR", err, { Player = player })
			end, options.OnPlayerInit, player, profile.Data, isNewProfile)
		end

		-- Scribe.Dynamic factories and OnPlayerInit write raw into profile.Data without
		-- passing Node.validateWrite, and unpersistable data introduced there would
		-- fail the entire next save opaquely, with no path in the log. Scan once and
		-- surface the exact location; non-fatal, because the library cannot safely
		-- rewrite developer data.
		local depthStats = { MaxDepth = 0 }
		local badInit = Util.findUnpersistable(profile.Data, nil, nil, depthStats)
		if badInit ~= nil then
			local where = Util.pathString(badInit.Path)
			Log.Error(
				"Lifecycle",
				"PROFILE_UNPERSISTABLE",
				`unpersistable data written during load at "{where}" ({badInit.Detail}) -- this WILL fail the `
					.. `DataStore save; fix the value set by OnPlayerInit or a Scribe.Dynamic factory`,
				{ Player = player, Path = where }
			)
			ctx.Signals.OnAnomaly:Fire({ Player = player, Path = badInit.Path, Value = nil, Reason = badInit.Kind })
		end
		-- Stored data may legally be nested deeper than a write is allowed to reach.
		-- Such a profile loads and reads fine, then refuses every write to its deepest
		-- leaves at the first Set, with nothing at load having hinted at it.
		if depthStats.MaxDepth > Util.MAX_VALUE_DEPTH then
			Log.Warn(
				"Integrity",
				"PROFILE_TOO_DEEP",
				`stored data is nested {depthStats.MaxDepth} levels deep, past the {Util.MAX_VALUE_DEPTH}-level `
					.. "write limit; those leaves load and read but every write to them will be refused. "
					.. "Flatten the shape or migrate it",
				{ Player = player, Depth = depthStats.MaxDepth, Limit = Util.MAX_VALUE_DEPTH }
			)
		end

		profile.OnSave:Connect(function(saveContext: any)
			-- Point the profile at a copy holding online-only cooldowns in their
			-- persisted form and keep the live deadlines aside. OnSave fires before the
			-- store reads profile.Data, OnAfterSave once it has, and OnError covers the
			-- save that never gets there.
			entry.TimedHeld = ctx.Timed.BeforeSave(entry)
			onProfileSaving(entry, saveContext)
		end)
		-- Exactly one fire per save call, success or failure, so this is where the
		-- in-flight count comes back down. OnAfterSave cannot do it: it fires only on
		-- success, so a failing save would leak a count forever and every later error
		-- on this key would be re-attributed to it.
		if type((profile :: any).OnSettled) == "table" then
			(profile :: any).OnSettled:Connect(function(saveContext: any)
				entry.SavesInFlight = math.max(0, entry.SavesInFlight - 1)
				if entry.SavesInFlight == 0 then
					entry.SaveT0 = nil
					-- ...and with it the pre-snapshot dirtiness the OnError restore reads.
					-- On the DRAIN, not once per settle: the slot is shared by every save
					-- in flight (OnError is module-global and cannot name which call
					-- failed), so clearing it at the first of two completions hands the
					-- survivor a nil and its failure restores clean over an unstored write.
					--
					-- Holding it until nothing can still fail can leave the entry dirty for
					-- data that did land, which costs one redundant save. The other
					-- direction costs a receipt answered PurchaseGranted for a grant that
					-- exists only in RAM.
					entry.DirtyAtSaveStart = nil
				end
				-- A release-only save wrote MetaData and left the stored bytes as it
				-- found them, so everything live is still unsaved. It reaches
				-- OnAfterSave like any successful write, so onProfileSaved has just
				-- cleared Dirty and stamped "Ok", and isDurable reads exactly those two:
				-- without this, Data.Flush short-circuits true for a profile whose data
				-- has never been persisted. OnSettled fires after OnAfterSave, so
				-- re-dirtying here is not undone.
				if type(saveContext) == "table" and saveContext.ReleaseOnly == true then
					entry.SaveInfo.Dirty = true
					self.UpdateSaveInfoMirror(entry)
				end
			end)
		end

		profile.OnAfterSave:Connect(function(lastSavedData: any)
			ctx.Timed.AfterSave(entry, entry.TimedHeld)
			entry.TimedHeld = nil
			onProfileSaved(entry, lastSavedData)
		end)
		profile.OnSessionEnd:Connect(function()
			-- A session end WE did not initiate (and not the shutdown drain) is an
			-- external steal: its final save persists nothing locally, so save
			-- bookkeeping must not report success for it (onProfileSaved checks this).
			entry.SessionStolen = not entry.LocalSessionEnd and not self.Closing
			teardown(entry, if player.Parent == Players then "session-ended" else "player-left")
		end)

		-- If the player left (or the session was stolen) during the yielding
		-- migration/OnPlayerInit above, OnSessionEnd already fired with no listener
		-- attached, so tear down rather than finishing a Ready session that would leak.
		-- A NoSave load holds a VIEW, which is never IsActive() by design, so the guard
		-- must not apply to it.
		if mode ~= "NoSave" and not profile:IsActive() then
			teardown(entry, if player.Parent == Players then "session-ended" else "player-left")
			return
		end

		buildTree(entry)
		-- The session store was built from template defaults, so a derived field's
		-- default came from its inputs' defaults rather than the data that just loaded.
		-- Recompute once here: before Ready, before Leaderboards.OnLoad (which enqueues
		-- an initial score), and before Replication.OnEntryReady (whose Init snapshot
		-- must carry the real values).
		entry.Tree:SeedDerived()
		entry.SaveInfo.Dirty = false
		self.UpdateSaveInfoMirror(entry)

		-- Subsystem hooks are isolated so one failing hook cannot abort the others
		-- (or strand the load thread).
		local function runHook(name: string, hook: (any) -> ...any)
			local ok, err = pcall(hook, entry)
			if not ok then
				Log.Error(
					"Lifecycle",
					"SUBSYSTEM_HOOK_ERROR",
					`{name} hook failed: {tostring(err)}`,
					{ Player = player }
				)
			end
		end

		-- BEFORE Ready, unlike the hooks below, and that is a correctness requirement.
		-- An online-only cooldown is stored as REMAINING seconds and only becomes a
		-- deadline here, so running this after Ready hands the documented PlayerAdded
		-- -> WaitForData -> read path a remaining value to read as a deadline: the gate
		-- reads expired, and re-arming inside that window compounds into a permanent
		-- lockout. It must also stay BELOW `Dirty = false`, because the load sweep's
		-- clears write through setTimed and must keep their dirty flag.
		runHook("Timed", ctx.Timed.OnLoad)

		setState(entry, "Ready", nil)
		Metrics.Add("ProfilesLoaded")
		Metrics.Set("ActiveSessions", self.EntryCount)
		Log.Info("Persistence", "PROFILE_LOADED", "profile session started", { Player = player })

		-- Register the cross-server gift handler FIRST and independently: it only
		-- needs the tree, and it must not be lost if a subsystem hook below
		-- throws (e.g. a misconfigured leaderboard Stat path).
		profile:MessageHandler(function(message: any, processed: () -> ())
			ctx.Monetization.OnProfileMessage(entry, message, processed)
			-- User-level cross-server messages (Data.SendMessage) ride the same channel,
			-- tagged distinctly so they never collide with gift delivery.
			--
			-- ACKNOWLEDGE ONLY WHAT A HANDLER ACTUALLY OBSERVED. Fire tells the caller
			-- nothing: it returns at the handler's first yield, returns the same when no
			-- handler is connected, and lets a raised error go to the scheduler. Acking
			-- unconditionally retires messages nothing observed, and for a handler still
			-- parked before its write it also loses the write. processed() only flags
			-- locked_global_updates, and the store removes the update inside the same
			-- UpdateAsync that writes profile.Data, so acking once the handler has
			-- RETURNED is the rule the gift arm already follows.
			--
			-- Not acking is at-least-once, and Data.SendMessage payloads carry no id, so
			-- a redelivered message reaches the game twice. That is documented, and
			-- bounded: an unacked message returns on the next load, not once per save.
			if type(message) == "table" and message.ScribeMessage == true then
				-- Counted before the fire and uncounted on settle, so teardown can report
				-- a handler that never returned. FireTracked settles on the LAST handler,
				-- so one parked listener holds the whole fire open and neither arm below
				-- is ever reached.
				entry.UnsettledMessages = (entry.UnsettledMessages or 0) + 1
				ctx.Signals.OnMessage:FireTracked(function(ran: number, ok: boolean, err: any)
					entry.UnsettledMessages = (entry.UnsettledMessages or 1) - 1
					if ran == 0 then
						-- Nobody was connected. Common during a startup race, where the
						-- profile loads before the game binds its handler; keeping the
						-- message costs a redelivery, dropping it costs the message.
						Log.Warn(
							"Persistence",
							"MESSAGE_NO_LISTENER",
							"a cross-server message arrived with nothing connected to Data.OnMessage; "
								.. "it was NOT acknowledged and will be redelivered on the next load",
							{ Player = player }
						)
						return
					end
					if not ok then
						-- Fire let a handler error reach the scheduler; FireTracked pcalls it,
						-- so this is where it has to surface or it surfaces nowhere.
						Log.Error(
							"Persistence",
							"MESSAGE_HANDLER_ERROR",
							`a Data.OnMessage handler raised: {tostring(err)}; the message was NOT `
								.. "acknowledged and will be redelivered on the next load",
							{ Player = player }
						)
						return
					end
					processed()
				end, entry.Player, message.Data)
			end
		end)

		-- The rest run post-Ready; only Timed has to beat the state change.
		runHook("Monetization", ctx.Monetization.OnLoad)
		runHook("Leaderboards", ctx.Leaderboards.OnLoad)
		runHook("Replication", ctx.Replication.OnEntryReady)
	end

	local function loadProfile(entry: Entry)
		local player = entry.Player

		if mode == "NoSave" then
			-- Snapshot of the real profile with NO session: nothing is saved, because
			-- a view is never IsActive() and every save path checks that first.
			local ok, profile = pcall(function()
				return store:GetAsync(entry.Key)
			end)
			if ok and profile then
				entry.Profile = profile
				finishLoad(entry)
			else
				Log.Error(
					"Persistence",
					"PROFILE_LOAD_FAIL",
					`Mode = "NoSave": no stored profile to read for this key`,
					{ Player = player, UserId = entry.UserId }
				)
				teardown(entry, "load-failed")
			end
			return
		end

		local attempt = 0
		while not self.Closing and not self.Stopped do
			attempt += 1
			-- Captured PER ATTEMPT, which is load-bearing rather than tidy.
			-- ProfileStore latches the first `true` its Cancel returns and never asks
			-- again, so a deadline computed once outside this loop would abort every
			-- later attempt the instant it began.
			local deadline = Clock.Monotonic() + loadTimeout
			local ok, profile = pcall(function()
				return store:StartSessionAsync(entry.Key, {
					Cancel = function()
						-- Runs INSIDE a DataStore UpdateAsync transform, where
						-- yielding is forbidden, so this stays arithmetic and field
						-- reads. Monotonic, never Now: wall time can jump.
						return player.Parent ~= Players or self.Closing or Clock.Monotonic() >= deadline
					end,
				})
			end)

			if entry.TornDown then
				-- Torn down while the load was in flight (shutdown drain or a leave
				-- processed elsewhere): release any session the racing load just won
				-- and stop -- finishing a load for a dead entry would leak the lock.
				if ok and profile then
					profile:EndSession()
				end
				return
			end

			if player.Parent ~= Players then
				if ok and profile then
					profile:EndSession()
				end
				teardown(entry, "player-left")
				return
			end

			if ok and profile then
				entry.Profile = profile
				Health.ReportSuccess("ProfileLoad")
				finishLoad(entry)
				return
			end

			-- A nil profile during shutdown is a Cancel-abort, not a DataStore
			-- failure: tear down quietly (BindToClose disconnects everyone) so we
			-- don't kick with a data-loss message or poison Health/metrics.
			if self.Closing then
				teardown(entry, "shutdown")
				return
			end

			-- Keyed for the same reason as the save path: under LoadFailurePolicy =
			-- "Wait" this fires once per retry for the same profile, so folding keeps a
			-- retry cycle from emitting one Error per attempt. Context.Attempt still
			-- counts the real attempts.
			Failure.Report({
				Subsystem = "ProfileLoad",
				Key = entry.Key,
				-- StartSessionAsync answers nil rather than a message; the underlying
				-- DataStore error, if there was one, already went through OnError above
				-- where it could be classified.
				Metric = "ProfileLoadFailures",
				Level = "Error",
				Category = "Persistence",
				Code = "PROFILE_LOAD_FAIL",
				Message = `profile failed to load (attempt {attempt})`,
				Context = { Player = player, Attempt = attempt },
			})

			if (options.LoadFailurePolicy or "Kick") == "Kick" then
				player:Kick(options.LoadFailureMessage or "We couldn't load your data. Please rejoin!")
				teardown(entry, "load-failed")
				return
			end
			-- "Wait": stay in Loading and keep retrying with backoff; never fall back
			-- to template data on a live account. Jittered so a fleet that lost the
			-- DataStore at one instant does not come back at one instant.
			Clock.Wait(Rng.Jitter(math.min(5 * attempt, 60)))
		end
		-- Loop exited because Closing flipped during a "Wait" backoff: tear the
		-- stranded Loading entry down so the shutdown drain isn't held to its
		-- full budget waiting on it.
		if not entry.TornDown then
			teardown(entry, "shutdown")
		end
	end

	function self.OnPlayerAdded(player: Player)
		if self.Entries[player] or self.Closing then
			return
		end
		self.EndReasons[player] = nil
		local userId = self.TargetUserId or player.UserId
		local entry: Entry = {
			Player = player,
			UserId = userId,
			Key = self.KeyFor(userId),
			State = "Loading",
			FailReason = nil,
			Profile = nil,
			Tree = nil,
			SessionStore = {},
			LiveData = nil,
			StateChanged = Signal.new(),
			SaveInfo = { LastSaveAt = nil, LastResult = nil, Dirty = false },
			SaveT0 = nil,
			SavesInFlight = 0,
			DirtyAtSaveStart = nil,
			Blocked = false,
			ForceSaveOnce = false,
			LastSavedSize = nil,
			LastSavedKeys = nil,
			SizeWarned = false,
			TornDown = false,
			UnsettledMessages = 0,
			HelloReceived = false,
			QueueOpen = false,
			HandshakeReady = false,
			LastInitAt = 0,
			ResyncPending = false,
			Queue = {},
			QueueIndex = {},
			SharedQueue = {},
			MalformedCount = 0,
			OversizeCount = 0,
			FrameTokens = ctx.InboundFrameRate,
			FrameLast = Clock.Monotonic(),
			RateTokens = options.CommandRateLimit or 20,
			RateLast = Clock.Monotonic(),
			GiftLastAt = 0,
		}
		self.Entries[player] = entry
		self.EntryCount += 1
		self.EntriesByUserId[entry.UserId] = entry
		Sched.Spawn(loadProfile, entry)
	end

	function self.OnPlayerRemoving(player: Player)
		local entry = self.Entries[player]
		if not entry then
			return
		end
		if entry.Profile and entry.Profile:IsActive() then
			runLeavingHook(entry, if player.Parent == Players then "session-ended" else "player-left")
			entry.LocalSessionEnd = true
			entry.Profile:EndSession() -- final save; OnSessionEnd triggers teardown
		else
			-- INCLUDING Loading. The StartSessionAsync Cancel guard is enough for the
			-- default policy, but under LoadFailurePolicy = "Wait" the retry loop spends
			-- its time in the BACKOFF between attempts, where there is no Cancel hook to
			-- consult, so the entry outlives the player by up to a backoff. A rejoin
			-- inside that window gets a new entry, and the old entry's late teardown
			-- broadcasts its Shared-root removal, dropping every bystander's mirror of a
			-- live Ready player with nothing to restore it.
			--
			-- Safe for a load that IS in flight: teardown sets TornDown, and the loader
			-- checks it the moment StartSessionAsync returns, releasing any session the
			-- racing load just won.
			teardown(entry, "player-left")
		end
	end

	-- Public API ------------------------------------------------------------------

	-- Wait for the next StateChanged fire, resuming anyway once the deadline
	-- passes: under LoadFailurePolicy = "Wait" an entry can sit in Loading for
	-- an entire DataStore outage without a state transition, and WaitForData
	-- must still honor its timeout rather than hang.
	local function waitStateChangedUntil(entry: Entry, deadline: number)
		local thread = coroutine.running()
		local settled = false
		local function resume()
			if settled then
				return
			end
			-- Claimed synchronously, resumed later. Two fires racing would otherwise
			-- both queue a wake before either set the flag.
			settled = true
			-- Deferred, not inline: an inline resume would return control from the middle
			-- of finishLoad, before the hooks have run, so the caller would see a session
			-- that reports Ready but is not. It also stops an inline Clock.Delay from
			-- resuming this thread before it has yielded.
			Sched.Defer(function()
				if coroutine.status(thread) == "suspended" then
					Sched.Resume(thread)
				end
			end)
		end
		local connection = entry.StateChanged:Connect(resume)
		Clock.Delay(math.max(deadline - Clock.Monotonic(), 0), resume)
		coroutine.yield()
		connection:Disconnect()
	end

	function self.WaitForData(player: Player, timeout: number?): (any?, string?)
		local deadline = Clock.Monotonic() + (timeout or 60)
		while true do
			local entry = self.Entries[player]
			if entry then
				if entry.State == "Ready" then
					return entry.Tree.Accessor, nil
				elseif entry.State == "SessionEnded" then
					return nil, entry.FailReason or "session-ended"
				end
				if Clock.Monotonic() >= deadline then
					-- Ready and SessionEnded both returned above, so this is necessarily
					-- Loading: the load is still in flight and will often succeed. It is
					-- reported separately from "timeout" because the default wait (60s) is
					-- shorter than a legitimate slow load, and a caller that wants to keep
					-- waiting can pass its own timeout.
					return nil, "still-loading"
				end
				waitStateChangedUntil(entry, deadline)
			else
				local endedReason = self.EndReasons[player]
				if endedReason then
					return nil, endedReason
				end
				if player.Parent ~= Players then
					return nil, "player-left"
				end
				if Clock.Monotonic() >= deadline then
					-- No entry, no stored end reason, and the player is still here: Scribe
					-- has no session for them at all, which usually means the bundle was
					-- constructed after they joined and OnPlayerAdded never ran.
					return nil, "timeout"
				end
				Clock.Wait(0.1)
			end
		end
	end

	function self.GetState(player: Player): string
		local entry = self.Entries[player]
		return if entry then entry.State else "SessionEnded"
	end

	--- Notes for isDurable below. All three of its conditions are load-bearing:
	--- `Dirty` is cleared at SNAPSHOT time so it cannot answer alone; `SavesInFlight`
	--- stops a caller being told mid-flight writes are durable; and `LastResult` must
	--- be "Ok" rather than merely not "Fail", because finishLoad resets Dirty after the
	--- migration chain and OnPlayerInit have written. Deliberately no `Blocked` check:
	--- onProfileSaved already keeps a blocked entry dirty, and a clause here would
	--- cover for that line if it were deleted.
	--- Did THIS save write something other than the live tree?
	---
	--- The wipe guard's Block policy turns a save into a rewrite of the last-good
	--- snapshot by re-pointing profile.Data (SetSaveSource), which is per-PROFILE and
	--- affects every transform that has not run yet, so a save that snapshotted clean
	--- and was still out when a later save tripped the guard wrote the snapshot and
	--- told its caller true. `SavedSource` is the identity of the table the transform
	--- actually serialized, so this compares what WENT TO THE KEY against what the tree
	--- writes into, and gets the mirror case right too. The snapshot-time flag is the
	--- fallback for a store that reports no SavedSource.
	local function blockedForSave(entry: Entry, saveContext: { [string]: any }): boolean
		local source = saveContext.SavedSource
		if source ~= nil and entry.LiveData ~= nil then
			return source ~= entry.LiveData
		end
		return saveContext.Blocked == true
	end

	local function isDurable(entry: Entry): boolean
		return entry.SaveInfo.Dirty == false and (entry.SavesInFlight or 0) == 0 and entry.SaveInfo.LastResult == "Ok"
	end

	-- Force an immediate save. Returns true once the save is confirmed.
	function self.Flush(player: Player, opts: { Force: boolean?, Timeout: number? }?): boolean
		local entry = self.Entries[player]
		if not entry or not entry.Profile or entry.State ~= "Ready" then
			return false
		end
		if opts and opts.Force then
			-- Force exists to push a wipe-guard-BLOCKED save through, so it must always
			-- reach the store. It never coincides with the short circuit anyway, but
			-- keeping it separate stops the two being coupled by accident later.
			entry.ForceSaveOnce = true
		elseif isDurable(entry) then
			-- Already on disk: answer honestly and spend nothing, since a save here would
			-- be a full UpdateAsync round trip writing bytes that are already there.
			--
			-- This is the only part of "dirty-aware saving" that is safe, because it
			-- removes a write rather than deferring one. Skipping AUTOSAVES is a
			-- different thing wearing the same words: the autosave also refreshes
			-- MetaData.LastUpdate, which another server reads to decide whether this
			-- session belongs to a crashed machine, and it is what delivers cross-server
			-- messages and gifts.
			Metrics.Add("FlushesAlreadyDurable")
			return true
		end
		return self.AwaitSave(entry, (opts and opts.Timeout) or 15)
	end

	-- Save now, and report what happened to THIS save. The store answers for itself
	-- rather than correlating completions with a generation counter: ProfileStore's
	-- ordering makes overlapping saves deterministic, so the counter regularly
	-- answered a waiter whose write the completing save had never serialized, and
	-- Monetization returns PurchaseGranted on this boolean.
	function self.AwaitSave(entry: Entry, timeout: number): boolean
		local profile = entry.Profile
		if not profile or not profile:IsActive() then
			return false
		end
		local thread = coroutine.running()
		-- Claimed synchronously by whichever path arrives first, so a completion landing
		-- after this caller has given up cannot answer it a second time. By then the
		-- thread is usually parked on something else, and a stray resume would hand it
		-- this save's boolean in place of the value it asked for.
		local settled = false
		-- The verdict, left where the caller can READ it rather than be woken with it.
		--
		-- With a synchronous store (the fake in tests, a fast final save in production)
		-- SaveAwait returns on this caller's own stack, before it has reached its yield.
		-- Deferring the wake until the caller parked was the bug: Sched.Resume is
		-- task.spawn, so a thread woken from inside a deferred callback inherits that
		-- callback's re-entrancy generation and climbs one rung per AwaitSave round
		-- trip. At 80, task.defer silently DROPS the callback while still returning
		-- success, so the waiter hangs for the life of the server with Monetization
		-- returning PurchaseGranted off this boolean. Answering by value removes the
		-- wake entirely on that path rather than trying to time it. A thread keeps the
		-- rung it climbed until its own next task.wait, so only a run of wakes with no
		-- wait between them compounds.
		local result: boolean? = nil
		-- Hand the verdict to whichever state the caller is in. Only the path that
		-- claimed `settled` gets here, so the two writes cannot race.
		local function answer(ok: boolean)
			result = ok
			-- "suspended" is the only status that may be resumed. "normal" is the
			-- synchronous store above and "running" is a Clock.Delay firing on this very
			-- stack; both are answered by `result`, and resuming either would error.
			if coroutine.status(thread) == "suspended" then
				Sched.Resume(thread, ok)
			end
		end

		Sched.Spawn(function()
			local outcome, saveContext = profile:SaveAwait()
			if settled then
				return
			end
			settled = true
			-- "Saved" is the only outcome that puts these bytes on disk, and even then
			-- not if the wipe guard swapped in the last-good snapshot, nor if this was a
			-- ReleaseOnly write: a fail-closed release writes MetaData and deliberately
			-- leaves the stored bytes untouched, so the write succeeds while none of
			-- profile.Data reaches the key. All three terms are per-save rather than
			-- read back off shared entry state.
			answer(outcome == "Saved" and not blockedForSave(entry, saveContext) and saveContext.ReleaseOnly ~= true)
		end)

		Clock.Delay(timeout, function()
			if settled then
				return
			end
			settled = true
			-- Unresolved, not failed: the save is very often still in flight and lands
			-- seconds later. Named for the wait rather than the save, and deliberately
			-- not counted as SavesFailed, because it may yet succeed.
			Metrics.Add("SaveWaitTimeouts")
			Log.Warn(
				"Persistence",
				"SAVE_WAIT_TIMEOUT",
				`gave up waiting {timeout}s for a save to confirm; it may still be in flight, so this is unresolved rather than failed`,
				{ Player = entry.Player, Timeout = timeout }
			)
			answer(false)
		end)

		-- Answered without this thread ever parking: the store settled inline, or an
		-- inline Clock.Delay timed the wait out on this stack. Nothing can run between
		-- Sched.Spawn returning and this test, so reading `result` is not a race.
		-- Tested against nil rather than truthiness: a `false` verdict is an ANSWER, and
		-- falling through to the yield would park a caller both wakers have retired,
		-- hanging exactly the failing saves.
		if result ~= nil then
			return result
		end
		return coroutine.yield() == true
	end

	function self.GetSaveInfo(
		player: Player
	): { LastSaveAt: number?, LastResult: ("Ok" | "Fail")?, Dirty: boolean, Size: number? }
		local entry = self.Entries[player]
		if not entry then
			return { LastSaveAt = nil, LastResult = nil, Dirty = false, Size = nil }
		end
		local info = table.clone(entry.SaveInfo)
		info.Size = entry.LastSavedSize
		return info
	end

	-- Offline access ----------------------------------------------------------

	-- Derived fields are computed, so they are absent from stored data. Both branches
	-- of GetOffline fill in the root-level fields whose every input persists
	-- (Derived.OfflineComputable); anything reading a Session field is left out rather
	-- than filled from data that is not there.
	local function deriveOffline(snapshot: { [string]: any })
		if #compiled.DerivedNodes == 0 then
			return
		end
		DerivedModule.EvaluateInto(compiled, snapshot, function(node)
			return node.Derived.OfflineComputable
		end)
	end

	function self.GetOffline(userId: number): { [string]: any }?
		local entry = self.EntryForUserId(userId)
		if entry and entry.State == "Ready" and entry.LiveData then
			local live = Util.deepClone(entry.LiveData)
			deriveOffline(live)
			return live
		end
		local ok, profile = pcall(function()
			return store:GetAsync(self.KeyFor(userId))
		end)
		if not ok then
			-- Distinguish a read error (retryable) from a missing profile
			-- (returns nil below with no failure report).
			Failure.Report({
				Subsystem = "OfflineRead",
				Key = tostring(userId),
				Error = profile,
				Category = "Persistence",
				Code = "OFFLINE_READ_FAIL",
				Message = tostring(profile),
				Context = { UserId = userId },
			})
			return nil
		end
		Health.ReportSuccess("OfflineRead")
		if not profile then
			return nil
		end
		-- A DataStore round trip turns a Scribe.MapOf("integer") key into its string
		-- form, and only the session load undid that, so an offline reader saw the raw
		-- strings. Coerce the copy, not the store's table.
		local snapshot = Util.deepClone(profile.Data)
		Template.CoerceMapKeys(compiled, snapshot)
		deriveOffline(snapshot)
		return snapshot
	end

	-- Serialize same-user offline read-modify-writes on THIS server. A view-mode
	-- SetAsync writes the whole GetAsync snapshot back, so two interleaved
	-- UpdateOffline cycles for one userId have the second clobber the first, silently
	-- dropping a grant and its dedupe marker while both report success. A per-userId
	-- FIFO lock makes each cycle read the prior's save. Concurrent offline writes from
	-- a DIFFERENT server remain a view-mode limitation.
	local offlineLocks: { [number]: { thread } } = {}
	local function acquireOffline(userId: number)
		local waiters = offlineLocks[userId]
		if waiters == nil then
			offlineLocks[userId] = {} -- lock now held, no waiters
			return
		end
		table.insert(waiters, coroutine.running())
		coroutine.yield() -- resumed by releaseOffline when it is our turn
	end
	local function releaseOffline(userId: number)
		local waiters = offlineLocks[userId]
		if waiters and #waiters > 0 then
			Sched.Resume(table.remove(waiters, 1) :: thread) -- next waiter takes the lock
		else
			offlineLocks[userId] = nil
		end
	end

	-- Applies `mutate` to an offline profile and saves it, returning
	-- (ok, reason, dataStoreFailed). Only a failing GetAsync/SetAsync sets the third:
	-- a precondition refusal or a throwing callback is a LOGIC error, and reporting
	-- those to Health would let ordinary refusals flip the server to Outage, which in
	-- turn refuses Robux grants. `mutate` runs against a CLONE, so a callback that
	-- errors partway commits nothing.
	--
	-- The active-session check is a pure read, deliberately. ProfileStore has no
	-- non-stealing acquire: the first StartSessionAsync attempt writes ForceLoadSession
	-- and publishes a session-end message, kicking an online player off another server,
	-- and EndSession only task.spawns its save so this could no longer promise the
	-- write landed. Losing the read-then-write race costs one clobbered write; closing
	-- it that way costs evicted players and eaten Robux.
	--- Turn an UpdateOfflineAsync outcome into Scribe's (ok, reason, dataStoreFailed).
	--- One table for updateOfflineProfile and RestoreVersion, so the two cannot come to
	--- disagree about which outcomes are infrastructure failures. Only "Failed" is.
	local function mapOfflineOutcome(outcome: string?, what: string): (boolean, string?, boolean)
		if outcome == "Written" then
			return true, nil, false
		elseif outcome == "SessionActive" then
			return false, "profile has an active session on another server", false
		elseif outcome == "Changed" then
			-- Somebody else wrote between the read and here. Nothing was written, so a
			-- caller that cares can simply try again against fresh data.
			return false, `profile changed while the {what} was being prepared`, false
		elseif outcome == "Missing" then
			return false, "profile does not exist", false
		end
		-- "Failed": the DataStore call itself did not land. Fail closed -- an offline
		-- write we cannot stand behind is what the receipt path turns into a
		-- granted-but-unsaved purchase.
		return false, `offline {what} did not complete`, true
	end

	local function updateOfflineProfile(
		userId: number,
		mutate: (data: { [string]: any }) -> ()
	): (boolean, string?, boolean)
		local readOk, profile = pcall(function()
			return store:GetAsync(self.KeyFor(userId))
		end)
		if not readOk then
			return false, tostring(profile), true
		end
		if not profile then
			return false, "profile does not exist", false
		end
		if sessionLooksLive(profile) then
			return false, "profile has an active session on another server", false
		end

		local draft = Util.deepClone(profile.Data)
		-- Same integer-key coercion the session load does, so the callback sees the keys
		-- its template declares rather than the DataStore's string forms. The commit
		-- writes them back as numbers, which the store re-encodes as for a live save.
		Template.CoerceMapKeys(compiled, draft)
		local mutateOk, mutateErr = pcall(mutate, draft)
		if not mutateOk then
			return false, tostring(mutateErr), false
		end
		-- The callback mutates raw data, bypassing Node.validateWrite, so
		-- unpersistable data (invalid UTF-8, a userdata/Instance value) would fail
		-- the whole profile save opaquely. Reject before committing.
		local bad = Util.findUnpersistable(draft)
		if bad ~= nil then
			return false, `unpersistable data ({bad.Detail}) at "{Util.pathString(bad.Path)}"`, false
		end

		-- Commit conditionally, in ONE call. `mutate` above is developer code and may
		-- yield for as long as it likes, so a player can join another server inside
		-- that window, and the offline receipt path runs it on every grant for an
		-- absent player. Getting it wrong is worse than a lost write: a view SetAsync
		-- sets session_owns_profile and clears ActiveSession, so committing over a live
		-- session DISOWNS the server holding the key, and everything it wrote since its
		-- last save is gone. The compare-and-set makes the check and the write one
		-- DataStore call, leaving no window between them.
		if type((store :: any).UpdateOfflineAsync) == "function" then
			local casOk, outcome = pcall(function()
				return (store :: any):UpdateOfflineAsync(
					self.KeyFor(userId),
					{
						SessionLoadCount = profile.SessionLoadCount,
						LastUpdate = profile.LastUpdate,
						-- The third fingerprint field, and the one that does the work.
						-- LastUpdate has one-second granularity, so two writers off one
						-- snapshot can both pass it, and a view-mode SetAsync (how
						-- RestoreVersion commits) moves neither of the other two at all.
						WriteIndex = profile.WriteIndex,
					},
					draft,
					{
						-- The same dead-session age Erase and RestoreVersion get through
						-- sessionLooksLive, and the one StartSessionAsync steals at.
						-- Without it the CAS refuses on ActiveSession ~= nil at ANY age,
						-- so a crashed server locks UpdateOffline out forever.
						StaleSessionAfter = ASSUME_DEAD_SECONDS,
					}
				)
			end)
			if not casOk then
				return false, tostring(outcome), true
			end
			return mapOfflineOutcome(outcome, "update")
		end

		-- Fallback for an injected store without the compare-and-set: re-read, then
		-- write, with the window that leaves.
		local recheckOk, latest = pcall(function()
			return store:GetAsync(self.KeyFor(userId))
		end)
		if not recheckOk then
			return false, tostring(latest), true
		end
		if sessionLooksLive(latest) then
			return false, "profile has an active session on another server", false
		end

		table.clear(profile.Data)
		for key, value in draft do
			profile.Data[key] = value
		end
		local saveOk, saveErr = commitViewProfile(profile, self.KeyFor(userId))
		if not saveOk then
			return false, saveErr, true
		end
		return true, nil, false
	end

	function self.UpdateOffline(userId: number, fn: (data: { [string]: any }) -> ()): (boolean, string?)
		if self.EntryForUserId(userId) then
			return false, "user has an active session on this server"
		end
		acquireOffline(userId)
		-- Still pcalled so an unexpected internal error cannot skip releaseOffline;
		-- such an error is not a DataStore failure either, so it does not report.
		local callOk, ok, reason, dataStoreFailed = pcall(updateOfflineProfile, userId, fn)
		releaseOffline(userId)
		if not callOk then
			return false, tostring(ok)
		end
		if not ok then
			if dataStoreFailed then
				-- Only a DataStore failure reports. A refusal (a live session, a changed
				-- key, a missing profile) is the compare-and-set working, and counting
				-- it against Health would make ordinary contention look like an outage.
				Failure.Report({
					Subsystem = "OfflineWrite",
					Key = tostring(userId),
					Error = reason,
					Category = "Persistence",
					Code = "OFFLINE_WRITE_FAIL",
					Message = tostring(reason),
					Context = { UserId = userId },
				})
			end
			return false, reason
		end
		Health.ReportSuccess("OfflineWrite")
		return true, nil
	end

	-- Version history and restore -----------------------------------------------

	function self.ListVersions(
		userId: number,
		limit: number?
	): { { VersionId: string, CreatedAt: number, Size: number? } }
		local out = {}
		local ok, err = pcall(function()
			local query = store:VersionQuery(self.KeyFor(userId), Enum.SortDirection.Descending)
			for _ = 1, limit or 25 do
				local profile = query:NextAsync()
				if not profile then
					break
				end
				table.insert(out, {
					VersionId = profile.KeyInfo.Version,
					CreatedAt = profile.KeyInfo.CreatedTime / 1000,
					Size = Util.approxSize(profile.Data),
				})
			end
		end)
		if not ok then
			Log.Warn("Persistence", "VERSION_QUERY_FAIL", tostring(err), { UserId = userId })
		end
		return out
	end

	function self.GetVersion(userId: number, versionId: string): { [string]: any }?
		local ok, profile = pcall(function()
			return store:GetAsync(self.KeyFor(userId), versionId)
		end)
		if not ok then
			-- A read ERROR is retryable and must not be mistaken for a missing
			-- version during a manual restore.
			Failure.Report({
				Subsystem = "VersionRead",
				Key = tostring(userId),
				Error = profile,
				Category = "Persistence",
				Code = "VERSION_READ_FAIL",
				Message = tostring(profile),
				Context = { UserId = userId, VersionId = versionId },
			})
			return nil
		end
		Health.ReportSuccess("VersionRead")
		if not profile then
			return nil -- version genuinely not found
		end
		-- Same integer-key coercion and derived fill as GetOffline: this is a raw
		-- DataStore read, so it carries stored fields only.
		local snapshot = Util.deepClone(profile.Data)
		Template.CoerceMapKeys(compiled, snapshot)
		deriveOffline(snapshot)
		return snapshot
	end

	function self.RestoreVersion(
		userId: number,
		versionId: string,
		opts: { RollBackReserved: boolean? }?
	): (boolean, string?)
		if Health.GetStatus() == "Outage" then
			return false, "data services are experiencing an outage"
		end
		if self.EntryForUserId(userId) then
			return false, "user has an active session on this server; restore requires no active session"
		end
		-- Both read by the logging below, so they live outside the pcall. `differed` is
		-- only set on a path that goes on to commit, so a failed restore logs nothing
		-- about a preservation that did not happen.
		local reservedRolledBack = opts ~= nil and opts.RollBackReserved == true
		local reservedDiffered = false
		-- The schema version the restore COMMITTED, and the one it replaced. Only set
		-- on the preserve path, and only used by the log below.
		local restoredSchemaVersion: number? = nil
		local previousSchemaVersion: number? = nil
		local ok, err = pcall(function()
			local live = store:GetAsync(self.KeyFor(userId))
			if sessionLooksLive(live) then
				error("profile has an active session on another server")
			end
			if not live then
				-- No live key to restore over. Profile:SetAsync onto an empty key throws
				-- inside ProfileStore's own transform and that error is swallowed, so we
				-- would report a successful restore for a write that never landed.
				-- Restoring after an Erase is exactly the flow that hits this.
				error("no live profile exists for this user to restore over (was it erased?)")
			end
			-- The fingerprint, taken from the SAME read that just cleared the liveness
			-- check. Everything below is preparation; the commit compares against this.
			local expected = {
				SessionLoadCount = live.SessionLoadCount,
				LastUpdate = live.LastUpdate,
				WriteIndex = live.WriteIndex,
			}
			local versionProfile = store:GetAsync(self.KeyFor(userId), versionId)
			if not versionProfile then
				error("version not found")
			end
			local data = versionProfile.Data
			-- THE RESERVED ROOT IS NOT PART OF THE ROLLBACK. Everything else in `data`
			-- is game state, and rolling that back is the point of a restore. `_Scribe`
			-- is the ledger of things that happened in the real world: receipts granted,
			-- gifts paid for, entitlements bought, the audit trail, cooldowns that
			-- started. None of those un-happen because an operator restored a backup, so
			-- rolling them back lets one PurchaseId grant twice, resurrects delivered
			-- gifts and strips paid credits and perks. Same rule as runMigrations above.
			--
			-- `live` is the read already taken for the liveness check and fingerprint,
			-- so preserving costs no extra DataStore call. DEEP-CLONED, not assigned by
			-- reference the way runMigrations does it: the `RestoredFrom` stamp below
			-- lands before the commit can still be refused, and an INJECTED store whose
			-- GetAsync hands back its own backing table would turn that stamp into a
			-- write into the live record.
			if not reservedRolledBack then
				local liveReserved = live.Data[Template.RESERVED_ROOT]
				if type(liveReserved) == "table" then
					local snapshotReserved = data[Template.RESERVED_ROOT]
					-- `Version` IS THE ONE MEMBER OF THIS ROOT THAT TRAVELS WITH THE GAME
					-- DATA, because it describes the SHAPE of the data the lines above just
					-- replaced with an older snapshot. Carrying the live number onto
					-- restored old-shaped data makes runMigrations return early, so the
					-- chain never re-runs and the profile is stuck at the pre-migration
					-- shape marked current; under a staged deploy an older server also
					-- fails closed on PROFILE_VERSION_AHEAD and kick-loops the player.
					--
					-- ABSENT MEANS 1, NOT "KEEP THE LIVE ONE": a snapshot with no reserved
					-- root is a LEGACY profile, which is the reading runMigrations gives it
					-- above, and the oldest profiles have the most migrations to miss.
					local snapshotVersion = if type(snapshotReserved) == "table"
							and type(snapshotReserved.Version) == "number"
						then snapshotReserved.Version
						else 1
					-- Version-aware ON PURPOSE (the migration call site is not; see
					-- reservedUnchanged). Without it the common case, a pre-deploy snapshot
					-- for a player who has bought nothing, reports no difference and hides
					-- the only change that alters what the next load does. A live root with
					-- nothing in the snapshot to compare against reads as "differed", which
					-- is right: everything in it was preserved.
					reservedDiffered = not reservedUnchanged(liveReserved, snapshotReserved, true)
					data[Template.RESERVED_ROOT] = Util.deepClone(liveReserved)
					data[Template.RESERVED_ROOT].Version = snapshotVersion
					restoredSchemaVersion = snapshotVersion
					previousSchemaVersion = if type(liveReserved.Version) == "number" then liveReserved.Version else 1
				end
				-- No live reserved root at all (a legacy or imported profile that never
				-- had one): there is nothing real-world to preserve, so the snapshot's
				-- own root -- or the empty fallback below -- stands.
			end
			if type(data[Template.RESERVED_ROOT]) ~= "table" then
				data[Template.RESERVED_ROOT] = {}
			end
			data[Template.RESERVED_ROOT].RestoredFrom = { VersionId = versionId, At = Clock.Now() }
			-- Commit through the SAME compare-and-set updateOfflineProfile uses, in one
			-- DataStore call. Re-reading the lock and then writing is two round trips,
			-- which narrows the window without closing it, and a session landing between
			-- them is DISOWNED: the view write clears ActiveSession, so the holder keeps
			-- accepting writes it can no longer persist. A version restore is exactly an
			-- offline write of a data table the caller prepared elsewhere, so there is
			-- no second primitive and no second fingerprint here.
			if type((store :: any).UpdateOfflineAsync) ~= "function" then
				-- An injected store without the compare-and-set keeps the old shape,
				-- window and all; it is the only thing available.
				local latest = store:GetAsync(self.KeyFor(userId))
				if sessionLooksLive(latest) then
					error("profile has an active session on another server")
				end
				local committed, commitErr = commitViewProfile(versionProfile, self.KeyFor(userId))
				if not committed then
					error(commitErr)
				end
				return
			end
			local outcome = (store :: any):UpdateOfflineAsync(self.KeyFor(userId), expected, data, {
				StaleSessionAfter = ASSUME_DEAD_SECONDS,
			})
			local restored, reason = mapOfflineOutcome(outcome, "restore")
			if not restored then
				error(
					if outcome == "Missing"
						then "no live profile exists for this user to restore over (was it erased?)"
						else reason
				)
			end
		end)
		if not ok then
			-- Symmetric with the PROFILE_RESTORED line below, and Warn rather than Error
			-- deliberately: the caller is already being told, so this is a record
			-- rather than an alert.
			Failure.Report({
				Subsystem = "Restore",
				Key = tostring(userId),
				Error = err,
				Category = "Persistence",
				Code = "PROFILE_RESTORE_FAIL",
				Message = tostring(err),
				Context = { UserId = userId, VersionId = versionId },
			})
			return false, tostring(err)
		end
		Health.ReportSuccess("Restore")
		Log.Warn("Persistence", "PROFILE_RESTORED", "profile restored from version history", {
			UserId = userId,
			VersionId = versionId,
			PlaceId = game.PlaceId,
			JobId = game.JobId,
			ReservedRolledBack = reservedRolledBack,
		})
		-- Only when it actually DIFFERED, and only after the commit landed. An operator
		-- running a restore must not have to guess whether the money moved with it;
		-- silence would read as "the whole profile went back".
		if reservedDiffered then
			Log.Warn(
				"Persistence",
				"RESTORE_RESERVED_PRESERVED",
				`the reserved "{Template.RESERVED_ROOT}" root differed from the restored snapshot and was PRESERVED, not `
					.. `rolled back: receipt dedupe, gift escrow, gift credits, perks, purchase logs and Timed are still `
					.. `as they were before the restore, because those record events that already happened. The schema `
					.. `Version is the one exception -- it describes the SHAPE of the game data, so it travels with it: `
					.. `now {restoredSchemaVersion}, was {previousSchemaVersion}, and any migration steps above `
					.. `{restoredSchemaVersion} re-run on the next load. Pass RollBackReserved = true only if that root `
					.. `is itself what you are repairing`,
				{
					UserId = userId,
					VersionId = versionId,
					PlaceId = game.PlaceId,
					JobId = game.JobId,
					SchemaVersion = restoredSchemaVersion,
					PreviousSchemaVersion = previousSchemaVersion,
				}
			)
		end
		return true, nil
	end

	-- GDPR ---------------------------------------------------------------------

	function self.Erase(userId: number): (boolean, string?)
		if Health.GetStatus() == "Outage" then
			return false, "data services are experiencing an outage"
		end
		local entry = self.EntryForUserId(userId)
		if entry then
			return false, "user has an active session on this server"
		end
		local ok, err = pcall(function()
			-- Fail closed if the user is active on another server: RemoveAsync
			-- bypasses the session lock, so a live session elsewhere would re-save
			-- and resurrect the "erased" profile, silently defeating the deletion
			-- (same guard as UpdateOffline/RestoreVersion).
			local profile = store:GetAsync(self.KeyFor(userId))
			if sessionLooksLive(profile) then
				error("profile has an active session on another server")
			end
			if not store:RemoveAsync(self.KeyFor(userId)) then
				error("RemoveAsync returned false")
			end
		end)
		if not ok then
			-- Same as Restore: without this a failed GDPR erase reaches no sink at all.
			Failure.Report({
				Subsystem = "Erase",
				Key = tostring(userId),
				Error = err,
				Category = "Persistence",
				Code = "PROFILE_ERASE_FAIL",
				Message = tostring(err),
				Context = { UserId = userId },
			})
			return false, tostring(err)
		end
		local lbOk, lbErr = ctx.Leaderboards.EraseUser(userId)
		Log.Warn("Persistence", "PROFILE_ERASED", "profile erased (GDPR)", {
			UserId = userId,
			PlaceId = game.PlaceId,
			JobId = game.JobId,
			LeaderboardOk = lbOk,
		})
		if not lbOk then
			-- The profile is gone but a leaderboard key was not removed; report
			-- failure so the operator retries (Erase is idempotent end to end).
			return false, lbErr
		end
		return true, nil
	end

	local function jsonSafe(value: any): any
		local t = type(value)
		if t == "buffer" then
			return "base64:" .. Util.base64FromBuffer(value)
		elseif t == "table" then
			local out = {}
			for k, v in value do
				out[k] = jsonSafe(v)
			end
			return out
		end
		return value
	end

	function self.Export(userId: number): string?
		local data = self.GetOffline(userId)
		if data == nil then
			return nil
		end
		local ok, encoded = pcall(function()
			return HttpService:JSONEncode(jsonSafe(data))
		end)
		if not ok then
			Log.Warn("Persistence", "EXPORT_ENCODE_FAIL", tostring(encoded), { UserId = userId })
			return nil
		end
		return encoded
	end

	-- Shutdown -------------------------------------------------------------------

	-- The BindToClose drain: stop accepting new sessions, flush the
	-- leaderboard queue, end every profile session, and wait within the
	-- budget. Exposed separately so the test harness can simulate shutdown.
	function self.Shutdown(budget: number?)
		self.Closing = true
		-- Before anything else: stop the store starting work this drain would then
		-- have to wait for. Its own BindToClose stands down (ExternalShutdown), so
		-- unless this runs, IsClosing never gets set and MessageAsync keeps retrying
		-- through the shutdown window.
		if type((ProfileStore :: any).BeginClose) == "function" then
			pcall((ProfileStore :: any).BeginClose)
		end
		local sessionCount = self.EntryCount
		Log.Info("Persistence", "SHUTDOWN_FLUSH", "shutting down; draining saves and leaderboards", {
			Sessions = sessionCount,
		})
		-- Single deadline shared by both phases so a slow leaderboard flush can
		-- never squeeze profile saves past Roblox's ~30s BindToClose window.
		-- Profile saves (player data) are started first; the leaderboard queue
		-- is rebuildable and gets whatever time remains.
		local deadline = Clock.Monotonic() + (budget or 25)
		-- Tear down profile-less Loading entries up front: one parked in a
		-- LoadFailurePolicy = "Wait" backoff sleeps up to 60s before noticing Closing
		-- and would hold the drain loop below to its full budget. Their
		-- StartSessionAsync cannot succeed anymore (the Cancel hook sees Closing), and
		-- the loader no-ops on TornDown when it wakes.
		local strandedLoading: { Entry } = {}
		for _, entry in self.Entries :: { [Player]: Entry } do
			if entry.State == "Loading" and entry.Profile == nil then
				table.insert(strandedLoading, entry)
			end
		end
		for _, entry in strandedLoading do
			teardown(entry, "shutdown")
		end
		-- Snapshot before running anything, the same two-phase shape as the stranded
		-- pass above. A hook gets the real accessor and can kick a player or end
		-- another session, and clearing keys mid-traversal is legal while ADDING one is
		-- undefined. Nothing can add today, since OnPlayerAdded refuses while Closing.
		local draining: { Entry } = {}
		for _, entry in self.Entries :: { [Player]: Entry } do
			if entry.Profile and entry.Profile:IsActive() then
				table.insert(draining, entry)
			end
		end

		-- Idempotent, because the cut-off below ends a parked hook's session on this
		-- thread and the hook then resumes into its own call to this.
		local function endSession(entry: Entry)
			if entry.LocalSessionEnd or not entry.Profile then
				return
			end
			entry.LocalSessionEnd = true
			entry.Profile:EndSession()
		end

		local hookDeadline = Clock.Monotonic() + math.max(0, deadline - Clock.Monotonic()) * HOOK_PHASE_SHARE
		local pending = 0
		local hooksSkipped = 0
		for _, entry in draining do
			if not (entry.Profile and entry.Profile:IsActive()) then
				continue -- a hook that already ran ended this one for us
			end
			if Clock.Monotonic() >= hookDeadline then
				-- Out of hook time. The save is not optional; the hook is.
				hooksSkipped += 1
				endSession(entry)
				continue
			end
			pending += 1
			Sched.Spawn(function()
				-- Per entry, the hook still runs strictly before ITS OWN EndSession:
				-- that ordering is the documented guarantee, and losing it is silent
				-- because EndSession destroys the tree synchronously and every later
				-- hook write raises into the contained LISTENER_ERROR path. What is
				-- relaxed is the ordering BETWEEN entries; Spawn runs inline until the
				-- hook yields, so a hook obeying the no-yield rule behaves exactly as it
				-- did as straight-line code and a yielding one parks alone.
				runLeavingHook(entry, "shutdown")
				pending -= 1
				endSession(entry)
			end)
		end
		while pending > 0 and Clock.Monotonic() < hookDeadline do
			Clock.Wait(HOOK_JOIN_POLL)
		end
		-- Whoever is still parked has run out of budget, and Luau cannot interrupt them.
		-- What they wrote before this point is already in the profile table and
		-- persists, so a timed-out hook is not an atomic one.
		local hooksTimedOut = 0
		for _, entry in draining do
			if entry.Profile and entry.Profile:IsActive() and not entry.LocalSessionEnd then
				hooksTimedOut += 1
				endSession(entry)
			end
		end
		if hooksSkipped > 0 then
			Metrics.Add("LeavingHooksSkipped", hooksSkipped)
		end
		if hooksTimedOut > 0 then
			Metrics.Add("LeavingHooksTimedOut", hooksTimedOut)
		end

		local lbBudget = math.max(0, math.min(deadline - Clock.Monotonic(), 20))
		ctx.Leaderboards.FlushAllBlocking(lbBudget)
		while next(self.Entries) ~= nil and Clock.Monotonic() < deadline do
			Clock.Wait(0.2)
		end
		-- Everything Scribe owns is released by now, so this is the job-drain wait:
		-- it keeps the process alive until the saves those releases started have
		-- actually landed, and sweeps up any profile Scribe does not know about.
		if type((ProfileStore :: any).AwaitClose) == "function" then
			pcall((ProfileStore :: any).AwaitClose)
		end
		Log.Info("Persistence", "SHUTDOWN_DONE", "shutdown drain complete", {
			Remaining = self.EntryCount,
			HooksSkipped = hooksSkipped,
			HooksTimedOut = hooksTimedOut,
		})
	end

	function self.BindShutdown()
		game:BindToClose(function()
			self.Shutdown(25)
		end)
	end

	-- Release the process-global signal connections this bundle installed.
	function self.Stop()
		-- FIRST, before anything is disconnected: the loader below reads it on its
		-- next turn, and a flag set after the yield-heavy teardown would let another
		-- round of attempts through.
		self.Stopped = true
		for _, connection in connections do
			pcall(function()
				connection:Disconnect()
			end)
		end
		table.clear(connections)
	end

	return self
end

return Persistence
