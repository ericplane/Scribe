--!strict
-- Persistence on ProfileStore: session lifecycle, fail-closed
-- migrations, offline access, version history/restore, save observability,
-- wipe guard, and BindToClose.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Internal = script.Parent.Parent.Internal
local Util = require(Internal.Util)
local Node = require(Internal.Node)
local Template = require(Internal.Template)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)
local Signal = require(Internal.Signal)

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
	SaveWaiters: { thread },
	Blocked: boolean,
	ForceSaveOnce: boolean,
	LastSavedSize: number?,
	SizeWarned: boolean,
	TornDown: boolean,
	-- Replication state (owned by Replication.luau)
	HelloReceived: boolean,
	HandshakeReady: boolean,
	LastInitAt: number,
	Queue: { any },
	QueueIndex: { [string]: number },
	SharedQueue: { any },
	MalformedCount: number,
	-- Commands state
	RateTokens: number,
	RateLast: number,
	-- Monetization state
	GiftLastAt: number,
}

local SIZE_WARN_BYTES = 3.5 * 1024 * 1024 -- warn approaching the ~4 MB DataStore ceiling
local MIN_SAVE_INTERVAL = 15 -- seconds; below this, per-key DataStore throttling causes save failures

local function findProfileStoreModule(injected: any): any
	if type(injected) == "table" then
		return injected
	end
	if typeof(injected) == "Instance" and injected:IsA("ModuleScript") then
		return require(injected) :: any
	end
	local packageRoot = script.Parent.Parent
	local searchRoots: { Instance? } = {
		packageRoot.Parent, -- wally sibling links
		ServerScriptService:FindFirstChild("ServerPackages"),
		ServerStorage:FindFirstChild("ServerPackages"),
		ServerScriptService:FindFirstChild("Packages"),
		ReplicatedStorage:FindFirstChild("Packages"),
	}
	for _, root in searchRoots do
		if root then
			local found = root:FindFirstChild("ProfileStore")
			if found and found:IsA("ModuleScript") then
				local ok, mod = pcall(require, found)
				if ok then
					return mod
				end
			end
		end
	end
	error(
		"Scribe: could not locate the ProfileStore module. Install lm-loleris/profilestore via Wally, "
			.. "or pass it explicitly: Scribe({ ..., ProfileStore = path.To.ProfileStore })",
		0
	)
end

function Persistence.new(ctx: any)
	local self = {} :: any
	local options = ctx.Options
	local compiled: Template.Compiled = ctx.Compiled

	-- Storage location is explicit and never defaulted (see Scribe() guard).
	local storeIndex = options.ProfileStoreIndex
	if type(storeIndex) ~= "string" or storeIndex == "" then
		error("Scribe: ProfileStoreIndex is required — name your game's DataStore explicitly", 0)
	end
	if type(options.ProfileKeyPrefix) ~= "string" or options.ProfileKeyPrefix == "" then
		error('Scribe: ProfileKeyPrefix is required — set a per-player key prefix (e.g. "PLAYER_")', 0)
	end

	local ProfileStore = findProfileStoreModule(options.ProfileStore)
	local persistentDefaults = Template.BuildDefaults(compiled, "Persistent")
	local baseStore = ProfileStore.New(storeIndex, persistentDefaults)
	local store = if options.UseMock or options.DontSave then baseStore.Mock else baseStore

	-- Autosave cadence. ProfileStore autosaves each profile once per
	-- AUTO_SAVE_PERIOD (default 300s); SaveInterval lowers it so less progress
	-- is at risk on an unclean exit (crash/timeout). Data.Flush stays available
	-- for immediate saves at grant-critical moments regardless.
	-- CAVEAT: AUTO_SAVE_PERIOD is a ProfileStore GLOBAL — this affects every
	-- Scribe bundle and any direct ProfileStore use in the game; the last
	-- configured value wins. Floored at 15s because Roblox throttles per-key
	-- writes (~1 per 6s), and saving faster than that just produces failures.
	if options.SaveInterval ~= nil then
		local interval = options.SaveInterval
		if type(interval) ~= "number" or interval ~= interval or interval <= 0 then
			error("Scribe: SaveInterval must be a positive number of seconds", 0)
		end
		if interval < MIN_SAVE_INTERVAL then
			Log.Warn(
				"Persistence",
				"SAVE_INTERVAL_CLAMPED",
				`SaveInterval below the {MIN_SAVE_INTERVAL}s floor (DataStore write throttling); clamping`,
				{ Requested = interval, Applied = MIN_SAVE_INTERVAL }
			)
			interval = MIN_SAVE_INTERVAL
		end
		if type(ProfileStore.SetConstant) == "function" then
			local ok, err = pcall(ProfileStore.SetConstant, "AUTO_SAVE_PERIOD", interval)
			if ok then
				Log.Info("Persistence", "SAVE_INTERVAL_SET", "autosave interval configured", { Seconds = interval })
			else
				Log.Warn("Persistence", "SAVE_INTERVAL_FAIL", tostring(err), {})
			end
		end
	end

	self.Store = store
	self.Entries = {} :: { [Player]: Entry }
	self.Closing = false
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

	-- Resume an AwaitSave waiter. With a synchronous store (tests, fast final
	-- saves) the completion can fire before the waiter reaches its yield;
	-- Roblox's task.defer refuses non-suspended coroutines, so wait for the
	-- suspension explicitly instead.
	local function resumeWaiter(thread: thread, ok: boolean)
		if coroutine.status(thread) == "suspended" then
			task.spawn(thread, ok)
		else
			task.defer(function()
				if coroutine.status(thread) == "suspended" then
					task.spawn(thread, ok)
				end
			end)
		end
	end

	local function resumeWaiters(entry: Entry, ok: boolean)
		local waiters = entry.SaveWaiters
		entry.SaveWaiters = {}
		for _, thread in waiters do
			resumeWaiter(thread, ok)
		end
	end

	-- ProfileStore health signals (member names verified against v1.0.3).
	local baseStoreName = storeIndex
	local okErr = pcall(function()
		ProfileStore.OnError:Connect(function(message: string, storeName: string, profileKey: string)
			-- OnError is module-global and fires for EVERY DataStore error
			-- (loads, view reads, version queries, other stores). Only our store
			-- counts toward Health, and only an in-flight SAVE should mark a
			-- save failure — otherwise a throttled version read for an online
			-- player would spuriously fail their receipts/save state.
			if storeName ~= baseStoreName then
				return
			end
			Health.ReportFailure("ProfileStore")
			Log.Warn("Persistence", "PROFILE_STORE_ERROR", tostring(message), { Store = storeName, Key = profileKey })
			for _, entry in self.Entries :: { [Player]: Entry } do
				if entry.Key == profileKey and entry.SaveT0 ~= nil then
					entry.SaveInfo.LastResult = "Fail"
					ctx.Signals.OnSave:Fire({ Player = entry.Player, Ok = false, Duration = nil, At = os.time() })
					Metrics.Add("SavesFailed")
					self.UpdateSaveInfoMirror(entry)
					resumeWaiters(entry, false)
				end
			end
		end)
	end)
	if not okErr then
		Log.Warn("Persistence", "PROFILE_STORE_SIGNAL_MISSING", "ProfileStore.OnError not connectable; save-failure observability disabled", {})
	end
	local okCrit = pcall(function()
		ProfileStore.OnCriticalToggle:Connect(function(isCritical: boolean)
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
		for _, entry in self.Entries :: { [Player]: Entry } do
			if entry.UserId == userId then
				return entry
			end
		end
		return nil
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
			})
		end
	end

	-- Wipe guard: compare against the last successful save.
	local function wipeGuardCheck(entry: Entry): (boolean, string?)
		local profile = entry.Profile
		local live = entry.LiveData
		if not profile or not live then
			return false, nil
		end
		local lastSaved = profile.LastSavedData
		if type(lastSaved) ~= "table" or next(lastSaved) == nil then
			return false, nil
		end
		local missing = {}
		for key in lastSaved do
			if live[key] == nil then
				table.insert(missing, tostring(key))
			end
		end
		if #missing > 0 then
			return true, `top-level keys vanished: {table.concat(missing, ", ")}`
		end
		local ratio = options.WipeGuardShrinkRatio or 0.6
		local oldSize = entry.LastSavedSize or Util.approxSize(lastSaved)
		local newSize = Util.approxSize(live)
		if oldSize and newSize and oldSize > 1024 and newSize < oldSize * (1 - ratio) then
			return true, `serialized size collapsed {oldSize} -> {newSize} bytes`
		end
		return false, nil
	end

	local function onProfileSaving(entry: Entry)
		entry.SaveT0 = os.clock()
		local profile = entry.Profile
		if not profile or not entry.LiveData then
			return
		end

		if entry.ForceSaveOnce then
			entry.ForceSaveOnce = false
			if entry.Blocked then
				entry.Blocked = false
				profile.Data = entry.LiveData
				Log.Warn("Integrity", "WIPE_GUARD_FORCED", "blocked save forced through", { Player = entry.Player })
			end
			return
		end

		local tripped, reason = wipeGuardCheck(entry)
		if tripped then
			Log.Error("Integrity", "WIPE_GUARD_TRIPPED", reason :: string, { Player = entry.Player })
			Metrics.Add("WipeGuardTrips")
			ctx.Signals.OnAnomaly:Fire({
				Player = entry.Player,
				Path = {},
				Value = nil,
				Reason = "WipeGuard: " .. (reason :: string),
			})
			if (options.WipeGuardPolicy or "Warn") == "Block" then
				-- Persist the last good snapshot instead; the live tree keeps
				-- its own root table. Unblocked when the guard passes again or
				-- via Data.Flush(player, { Force = true }).
				if not entry.Blocked then
					entry.Blocked = true
				end
				profile.Data = Util.deepClone(profile.LastSavedData)
				Log.Warn("Integrity", "WIPE_GUARD_BLOCKED", "save held; persisting last good snapshot", {
					Player = entry.Player,
				})
			end
		elseif entry.Blocked then
			entry.Blocked = false
			profile.Data = entry.LiveData
			Log.Info("Integrity", "WIPE_GUARD_CLEARED", "wipe guard cleared; live data persists again", {
				Player = entry.Player,
			})
		end
	end

	local function onProfileSaved(entry: Entry, lastSavedData: any)
		local duration = if entry.SaveT0 then os.clock() - entry.SaveT0 else nil
		entry.SaveT0 = nil -- save settled; OnError should no longer attribute a failure here
		entry.SaveInfo.LastSaveAt = os.time()
		entry.SaveInfo.LastResult = "Ok"
		entry.SaveInfo.Dirty = entry.Blocked -- blocked saves persisted old data; live data is still unsaved
		Metrics.Add("SavesOk")
		if duration then
			Metrics.Observe("SaveDuration", duration)
		end
		Health.ReportSuccess("Saves")
		ctx.Signals.OnSave:Fire({ Player = entry.Player, Ok = true, Duration = duration, At = os.time() })

		local size = Util.approxSize(lastSavedData)
		if size then
			entry.LastSavedSize = size
			Metrics.Observe("ProfileSize", size)
			if size > SIZE_WARN_BYTES and not entry.SizeWarned then
				entry.SizeWarned = true
				Log.Warn("Persistence", "PROFILE_SIZE", `profile approaching the ~4 MB DataStore ceiling ({size} bytes)`, {
					Player = entry.Player,
					Bytes = size,
				})
			elseif size <= SIZE_WARN_BYTES then
				entry.SizeWarned = false
			end
		end

		self.UpdateSaveInfoMirror(entry)
		resumeWaiters(entry, true)
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
				Log.Error("Persistence", "PROFILE_VERSION_AHEAD", "stored version is newer than this server's; failing closed", {
					Player = entry.Player,
					Stored = stored,
					Current = currentVersion,
				})
				return false
			end
			Log.Warn("Persistence", "PROFILE_VERSION_AHEAD", "stored version is newer than this server's (VersionAheadPolicy=Allow)", {
				Player = entry.Player,
				Stored = stored,
				Current = currentVersion,
			})
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
		if type(work[Template.RESERVED_ROOT]) ~= "table" then
			work[Template.RESERVED_ROOT] = {}
		end
		work[Template.RESERVED_ROOT].Version = currentVersion
		table.clear(data)
		for k, v in work do
			data[k] = v
		end
		Log.Info("Persistence", "MIGRATED", `profile migrated {stored} -> {currentVersion}`, { Player = entry.Player })
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
				local visibility = if schema then schema.Visibility else Template.VisibilityOf(compiled, op.Path)
				if visibility ~= "Session" and not entry.SaveInfo.Dirty then
					entry.SaveInfo.Dirty = true
					task.defer(function()
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
		})
	end

	local function teardown(entry: Entry, reason: string?)
		if entry.TornDown then
			return
		end
		entry.TornDown = true
		self.EndReasons[entry.Player] = reason or "session-ended"

		-- SessionEnded fires before the (default-on) kick.
		ctx.Signals.SessionEnded:Fire(entry.Player, reason)
		setState(entry, "SessionEnded", reason)

		ctx.Replication.OnEntryRemoved(entry)
		ctx.Leaderboards.OnUnload(entry)
		ctx.Monetization.OnUnload(entry)
		ctx.Timed.OnUnload(entry)

		if entry.Tree then
			entry.Tree:Destroy()
		end
		resumeWaiters(entry, false)

		if
			options.KickOnSessionEnd ~= false
			and not self.Closing
			and reason ~= "left"
			and entry.Player.Parent == Players
		then
			entry.Player:Kick(options.SessionEndMessage or "Your data session has ended. Please rejoin!")
		end

		self.Entries[entry.Player] = nil
		Metrics.Set("ActiveSessions", Util.count(self.Entries))
	end

	local function finishLoad(entry: Entry)
		local profile = entry.Profile :: any
		local player = entry.Player

		profile:AddUserId(entry.UserId)
		profile:Reconcile()

		if options.ResetData then
			local fresh = Util.deepClone(persistentDefaults)
			table.clear(profile.Data)
			for k, v in fresh do
				profile.Data[k] = v
			end
			Log.Warn("Persistence", "PROFILE_RESET", "profile reset via ResetData option", { Player = player })
		end

		if not runMigrations(entry, profile.Data) then
			-- Fail-closed: never persist a half-migrated profile. Migrations ran
			-- on a clone, so profile.Data is untouched; ending the session saves
			-- the unmodified original.
			profile:EndSession()
			if player.Parent == Players then
				player:Kick(options.LoadFailureMessage or "We couldn't load your data. Please rejoin!")
			end
			teardown(entry, "migration-failed")
			return
		end

		if ctx.DevMode then
			local unknown = Template.UnknownRootKeys(compiled, profile.Data)
			if #unknown > 0 then
				Log.Warn("Persistence", "UNKNOWN_ROOT_KEYS", "profile contains top-level keys absent from the template "
					.. "(removing keys is a migration's job)", {
					Player = player,
					Keys = table.concat(unknown, ", "),
				})
			end
		end

		if options.OnPlayerInit then
			Util.safeCall(function(err)
				Log.Error("Lifecycle", "ON_PLAYER_INIT_ERROR", err, { Player = player })
			end, options.OnPlayerInit, player, profile.Data)
		end

		profile.OnSave:Connect(function()
			onProfileSaving(entry)
		end)
		profile.OnAfterSave:Connect(function(lastSavedData: any)
			onProfileSaved(entry, lastSavedData)
		end)
		profile.OnSessionEnd:Connect(function()
			teardown(entry, if player.Parent == Players then "session-end" else "left")
		end)

		-- If the player left (or the session was stolen) during the yielding
		-- migration/OnPlayerInit above, OnSessionEnd already fired with no
		-- listener attached. IsActive() is reliably false by now (EndSession
		-- deactivates synchronously), so tear down instead of finishing a Ready
		-- session for a departed player that would leak forever.
		if not profile:IsActive() then
			teardown(entry, if player.Parent == Players then "session-end" else "left")
			return
		end

		buildTree(entry)
		entry.SaveInfo.Dirty = false
		self.UpdateSaveInfoMirror(entry)
		setState(entry, "Ready", nil)
		Metrics.Add("ProfilesLoaded")
		Metrics.Set("ActiveSessions", Util.count(self.Entries))
		Log.Info("Persistence", "PROFILE_LOADED", "profile session started", { Player = player })

		-- Register the cross-server gift handler FIRST and independently: it only
		-- needs the tree, and it must not be lost if a subsystem hook below
		-- throws (e.g. a misconfigured leaderboard Stat path).
		profile:MessageHandler(function(message: any, processed: () -> ())
			ctx.Monetization.OnProfileMessage(entry, message, processed)
			-- User-level cross-server messages (Data.SendMessage) ride the same
			-- channel, tagged distinctly so they never collide with gift delivery.
			if type(message) == "table" and message.ScribeMessage == true then
				ctx.Signals.OnMessage:Fire(entry.Player, message.Data)
				processed()
			end
		end)

		-- Post-Ready subsystem hooks are isolated so one failing hook can't abort
		-- initialization of the others (or strand the load thread).
		local function runHook(name: string, hook: (any) -> ...any)
			local ok, err = pcall(hook, entry)
			if not ok then
				Log.Error("Lifecycle", "SUBSYSTEM_HOOK_ERROR", `{name} hook failed: {tostring(err)}`, { Player = player })
			end
		end
		runHook("Timed", ctx.Timed.OnLoad)
		runHook("Monetization", ctx.Monetization.OnLoad)
		runHook("Leaderboards", ctx.Leaderboards.OnLoad)
		runHook("Replication", ctx.Replication.OnEntryReady)
	end

	local function loadProfile(entry: Entry)
		local player = entry.Player

		if options.ViewedUserId then
			-- View mode (testing): read someone's profile, never save.
			local ok, profile = pcall(function()
				return store:GetAsync(self.KeyFor(options.ViewedUserId))
			end)
			if ok and profile then
				entry.Profile = profile
				finishLoad(entry)
			else
				Log.Error("Persistence", "PROFILE_LOAD_FAIL", "ViewedUserId profile not found", { Player = player })
				teardown(entry, "load-failed")
			end
			return
		end

		local attempt = 0
		while not self.Closing do
			attempt += 1
			local ok, profile = pcall(function()
				return store:StartSessionAsync(entry.Key, {
					Cancel = function()
						return player.Parent ~= Players or self.Closing
					end,
				})
			end)

			if player.Parent ~= Players then
				if ok and profile then
					profile:EndSession()
				end
				teardown(entry, "left")
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

			Health.ReportFailure("ProfileLoad")
			Metrics.Add("ProfileLoadFailures")
			Log.Error("Persistence", "PROFILE_LOAD_FAIL", `profile failed to load (attempt {attempt})`, {
				Player = player,
				Attempt = attempt,
			})

			if (options.LoadFailurePolicy or "Kick") == "Kick" then
				player:Kick(options.LoadFailureMessage or "We couldn't load your data. Please rejoin!")
				teardown(entry, "load-failed")
				return
			end
			-- "Wait": stay in Loading, keep retrying with backoff; never fall
			-- back to template data on a live account.
			task.wait(math.min(5 * attempt, 60))
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
		local userId = options.OverriddenUserId or player.UserId
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
			SaveWaiters = {},
			Blocked = false,
			ForceSaveOnce = false,
			LastSavedSize = nil,
			SizeWarned = false,
			TornDown = false,
			HelloReceived = false,
			HandshakeReady = false,
			LastInitAt = 0,
			Queue = {},
			QueueIndex = {},
			SharedQueue = {},
			MalformedCount = 0,
			RateTokens = options.CommandRateLimit or 20,
			RateLast = os.clock(),
			GiftLastAt = 0,
		}
		self.Entries[player] = entry
		task.spawn(loadProfile, entry)
	end

	function self.OnPlayerRemoving(player: Player)
		local entry = self.Entries[player]
		if not entry then
			return
		end
		if entry.Profile and entry.Profile:IsActive() then
			entry.Profile:EndSession() -- final save; OnSessionEnd triggers teardown
		elseif entry.State ~= "Loading" then
			-- (Loading sessions abort via the StartSessionAsync Cancel guard.)
			teardown(entry, "left")
		end
	end

	-- Public API ------------------------------------------------------------------

	function self.WaitForData(player: Player): (any?, string?)
		for _ = 1, 600 do
			local entry = self.Entries[player]
			if entry then
				if entry.State == "Ready" then
					return entry.Tree.Accessor, nil
				elseif entry.State == "SessionEnded" then
					return nil, entry.FailReason or "session-ended"
				end
				entry.StateChanged:Wait()
			else
				local endedReason = self.EndReasons[player]
				if endedReason then
					return nil, endedReason
				end
				if player.Parent ~= Players then
					return nil, "player-left"
				end
				task.wait(0.1)
			end
		end
		return nil, "timeout"
	end

	function self.GetState(player: Player): string
		local entry = self.Entries[player]
		return if entry then entry.State else "SessionEnded"
	end

	-- Force an immediate save. Returns true once the save is confirmed.
	function self.Flush(player: Player, opts: { Force: boolean? }?): boolean
		local entry = self.Entries[player]
		if not entry or not entry.Profile or entry.State ~= "Ready" then
			return false
		end
		if opts and opts.Force then
			entry.ForceSaveOnce = true
		end
		return self.AwaitSave(entry, 15)
	end

	-- Trigger profile:Save() and yield until OnAfterSave/OnError/timeout.
	function self.AwaitSave(entry: Entry, timeout: number): boolean
		local profile = entry.Profile
		if not profile or not profile:IsActive() then
			return false
		end
		local thread = coroutine.running()
		table.insert(entry.SaveWaiters, thread)
		local done = false
		task.delay(timeout, function()
			if not done then
				local idx = table.find(entry.SaveWaiters, thread)
				if idx then
					table.remove(entry.SaveWaiters, idx)
					resumeWaiter(thread, false)
				end
			end
		end)
		-- Deferred so this thread is already suspended when a synchronous store
		-- completes the save (and fires OnAfterSave) immediately.
		task.defer(function()
			pcall(function()
				profile:Save()
			end)
		end)
		local ok = coroutine.yield()
		done = true
		return ok == true
	end

	function self.GetSaveInfo(player: Player): { LastSaveAt: number?, LastResult: ("Ok" | "Fail")?, Dirty: boolean }
		local entry = self.Entries[player]
		if not entry then
			return { LastSaveAt = nil, LastResult = nil, Dirty = false }
		end
		return table.clone(entry.SaveInfo)
	end

	-- Offline access ----------------------------------------------------------

	function self.GetOffline(userId: number): { [string]: any }?
		local entry = self.EntryForUserId(userId)
		if entry and entry.State == "Ready" and entry.LiveData then
			return Util.deepClone(entry.LiveData)
		end
		local ok, profile = pcall(function()
			return store:GetAsync(self.KeyFor(userId))
		end)
		if not ok then
			-- Distinguish a read error (retryable) from a missing profile
			-- (returns nil below with no failure report).
			Health.ReportFailure("OfflineRead")
			Log.Warn("Persistence", "OFFLINE_READ_FAIL", tostring(profile), { UserId = userId })
			return nil
		end
		Health.ReportSuccess("OfflineRead")
		return if profile then Util.deepClone(profile.Data) else nil
	end

	function self.UpdateOffline(userId: number, fn: (data: { [string]: any }) -> ()): (boolean, string?)
		if self.EntryForUserId(userId) then
			return false, "user has an active session on this server"
		end
		local ok, err = pcall(function()
			local profile = store:GetAsync(self.KeyFor(userId))
			if not profile then
				error("profile does not exist")
			end
			-- Fail closed if the user is active on another server: SetAsync
			-- overwrites through the session lock and would clobber live data
			-- (same guard as RestoreVersion).
			if profile.Session then
				error("profile has an active session on another server")
			end
			fn(profile.Data)
			profile:SetAsync()
		end)
		if not ok then
			Health.ReportFailure("OfflineWrite")
			return false, tostring(err)
		end
		Health.ReportSuccess("OfflineWrite")
		return true, nil
	end

	-- Version history and restore -----------------------------------------------

	function self.ListVersions(userId: number, limit: number?): { { VersionId: string, CreatedAt: number, Size: number? } }
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
			Health.ReportFailure("VersionRead")
			Log.Warn("Persistence", "VERSION_READ_FAIL", tostring(profile), { UserId = userId, VersionId = versionId })
			return nil
		end
		Health.ReportSuccess("VersionRead")
		if not profile then
			return nil -- version genuinely not found
		end
		return Util.deepClone(profile.Data)
	end

	function self.RestoreVersion(userId: number, versionId: string): (boolean, string?)
		if Health.GetStatus() == "Outage" then
			return false, "data services are experiencing an outage"
		end
		if self.EntryForUserId(userId) then
			return false, "user has an active session on this server; restore requires no active session"
		end
		local ok, err = pcall(function()
			local live = store:GetAsync(self.KeyFor(userId))
			if live and live.Session then
				error("profile has an active session on another server")
			end
			local versionProfile = store:GetAsync(self.KeyFor(userId), versionId)
			if not versionProfile then
				error("version not found")
			end
			local data = versionProfile.Data
			if type(data[Template.RESERVED_ROOT]) ~= "table" then
				data[Template.RESERVED_ROOT] = {}
			end
			data[Template.RESERVED_ROOT].RestoredFrom = { VersionId = versionId, At = os.time() }
			versionProfile:SetAsync()
		end)
		if not ok then
			Health.ReportFailure("Restore")
			return false, tostring(err)
		end
		Health.ReportSuccess("Restore")
		Log.Warn("Persistence", "PROFILE_RESTORED", "profile restored from version history", {
			UserId = userId,
			VersionId = versionId,
			PlaceId = game.PlaceId,
			JobId = game.JobId,
		})
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
			if not store:RemoveAsync(self.KeyFor(userId)) then
				error("RemoveAsync returned false")
			end
		end)
		if not ok then
			Health.ReportFailure("Erase")
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
		local sessionCount = Util.count(self.Entries)
		Log.Info("Persistence", "SHUTDOWN_FLUSH", "shutting down; draining saves and leaderboards", {
			Sessions = sessionCount,
		})
		-- Single deadline shared by both phases so a slow leaderboard flush can
		-- never squeeze profile saves past Roblox's ~30s BindToClose window.
		-- Profile saves (player data) are started first; the leaderboard queue
		-- is rebuildable and gets whatever time remains.
		local deadline = os.clock() + (budget or 25)
		for _, entry in self.Entries :: { [Player]: Entry } do
			if entry.Profile and entry.Profile:IsActive() then
				task.spawn(function()
					entry.Profile:EndSession()
				end)
			end
		end
		local lbBudget = math.max(0, math.min(deadline - os.clock(), 20))
		ctx.Leaderboards.FlushAllBlocking(lbBudget)
		while next(self.Entries) ~= nil and os.clock() < deadline do
			task.wait(0.2)
		end
		Log.Info("Persistence", "SHUTDOWN_DONE", "shutdown drain complete", {
			Remaining = Util.count(self.Entries),
		})
	end

	function self.BindShutdown()
		game:BindToClose(function()
			self.Shutdown(25)
		end)
	end

	return self
end

return Persistence
