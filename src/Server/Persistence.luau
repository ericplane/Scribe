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
	-- Monotonic count of save ATTEMPTS started (OnSave = payload serialized). A
	-- completing save only covers writes made BEFORE its payload snapshot, so
	-- waiters carry the generation current at registration and are resumed only
	-- by a save that STARTED after they registered.
	SaveGen: number,
	DirtyAtSaveStart: boolean?,
	SaveWaiters: { { Thread: thread, Gen: number } },
	Blocked: boolean,
	ForceSaveOnce: boolean,
	WipeGuardRebaselinePending: boolean?,
	LocalSessionEnd: boolean?, -- set before every locally-initiated EndSession
	SessionStolen: boolean?, -- OnSessionEnd fired that we did not initiate (external steal)
	LastSavedSize: number?,
	LiveSize: number?, -- approx bytes measured at the start of the last save attempt
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
	MalformedBlocked: boolean?, -- crossed the malformed-frame limit; inbound frames ignored
	LastMalformedLog: number?, -- os.clock of the last emitted malformed-frame log/anomaly
	-- Commands state
	RateTokens: number,
	RateLast: number,
	RateLimitedCount: number?, -- consecutive rate-limited frames (decays when quiet)
	LastRateLimitAt: number?, -- os.clock of the last rate-limited frame
	LastRateLimitLog: number?, -- os.clock of the last emitted COMMAND_RATE_LIMITED
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

	-- Resume ALL waiters (failure/teardown paths: a failed save answers every
	-- pending waiter with false, which is the safe retry direction).
	local function resumeWaiters(entry: Entry, ok: boolean)
		local waiters = entry.SaveWaiters
		entry.SaveWaiters = {}
		for _, waiter in waiters do
			resumeWaiter(waiter.Thread, ok)
		end
	end

	-- Resume only the waiters COVERED by the just-completed save: those registered
	-- before its payload snapshot (Gen < entry.SaveGen). A waiter registered while
	-- the save was in flight wrote AFTER the payload was serialized, so acking it
	-- would report durability for data that exists only in memory (e.g. returning
	-- PurchaseGranted for an unsaved grant). Those stay queued for the next save,
	-- which their own AwaitSave already triggered.
	local function resumeCoveredWaiters(entry: Entry, ok: boolean)
		local waiters = entry.SaveWaiters
		local kept: { { Thread: thread, Gen: number } } = {}
		local covered: { thread } = {}
		for _, waiter in waiters do
			if waiter.Gen < entry.SaveGen then
				table.insert(covered, waiter.Thread)
			else
				table.insert(kept, waiter)
			end
		end
		entry.SaveWaiters = kept
		for _, thread in covered do
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
					-- Attribute this failure to the in-flight save AT MOST ONCE, then
					-- clear SaveT0. A real save failure fires OnError (never
					-- OnAfterSave/onProfileSaved), so without clearing it here SaveT0
					-- lingers and every later unrelated same-key error (an operator
					-- view read or version query on this online player) would keep
					-- re-reporting the same save as failed.
					entry.SaveT0 = nil
					entry.SaveInfo.LastResult = "Fail"
					-- Classify a likely-oversize failure distinctly from a transient
					-- throttle/outage: a profile already over the size-warning threshold
					-- will fail EVERY UpdateAsync (unrecoverable) until it is trimmed,
					-- which the developer must act on differently from "retry later".
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
					ctx.Signals.OnSave:Fire({ Player = entry.Player, Ok = false, Duration = nil, At = os.time() })
					Metrics.Add("SavesFailed")
					self.UpdateSaveInfoMirror(entry)
					resumeWaiters(entry, false)
				end
			end
		end)
	end)
	if not okErr then
		Log.Warn(
			"Persistence",
			"PROFILE_STORE_SIGNAL_MISSING",
			"ProfileStore.OnError not connectable; save-failure observability disabled",
			{}
		)
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
				Size = entry.LastSavedSize,
			})
		end
	end

	-- Deep-compare stored profile data against the current template defaults,
	-- skipping Scribe.Dynamic leaves (their declaration-time samples differ per
	-- server boot) and comparing packed datatype buffers by content. Used to detect
	-- a profile whose first session hard-crashed before its first save: durably
	-- template-shaped, but SessionLoadCount already advanced past 1.
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
		-- This save's payload is serialized NOW: bump the generation (used to gate
		-- which AwaitSave waiters the completion covers) and reset Dirty so it
		-- re-accumulates from writes landing AFTER the payload snapshot. The pre-
		-- snapshot state is kept so a FAILED save can restore it (OnError path).
		entry.SaveGen += 1
		entry.DirtyAtSaveStart = entry.SaveInfo.Dirty
		entry.SaveInfo.Dirty = false
		local profile = entry.Profile
		if not profile or not entry.LiveData then
			return
		end

		-- Measure the payload on the way IN, not only on save success. A profile that
		-- balloons past the ~4 MB DataStore ceiling makes every UpdateAsync throw, so
		-- the success-path size check below would never run for it and the developer
		-- would see only generic, retryable-looking failures. Warn (and fire an
		-- anomaly) here regardless of the save's outcome, latched to once per crossing.
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
				profile.Data = entry.LiveData
				Log.Warn("Integrity", "WIPE_GUARD_FORCED", "blocked save forced through", { Player = entry.Player })
			end
			return
		end

		if entry.WipeGuardRebaselinePending then
			-- First save after a reshaping migration: the LastSavedData baseline
			-- predates the migration, so a comparison would false-trip on any key the
			-- migration intentionally removed. The flag is cleared on save SUCCESS
			-- (onProfileSaved), not here: this hook fires per ATTEMPT, and clearing on
			-- a failed attempt would re-arm the guard against the stale pre-migration
			-- baseline (under Block policy: a permanent stall persisting old data).
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
		-- ProfileStore fires OnAfterSave even when the session was STOLEN and nothing
		-- local persisted; teardown already resumed waiters false. Skip the success
		-- bookkeeping only for steals: a locally-initiated final save (clean leave,
		-- shutdown drain, migration fail-closed) genuinely persisted and its metrics
		-- and Health success must still be recorded, or shutdown skews Health.
		if entry.TornDown and entry.SessionStolen then
			return
		end
		local duration = if entry.SaveT0 then os.clock() - entry.SaveT0 else nil
		entry.SaveT0 = nil -- save settled; OnError should no longer attribute a failure here
		entry.SaveInfo.LastSaveAt = os.time()
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
		ctx.Signals.OnSave:Fire({ Player = entry.Player, Ok = true, Duration = duration, At = os.time() })

		-- Record the size that actually persisted (the warning + anomaly are owned by
		-- the pre-save check in onProfileSaving, which also fires when a save fails).
		local size = Util.approxSize(lastSavedData)
		if size then
			entry.LastSavedSize = size
			entry.LiveSize = size
			Metrics.Observe("ProfileSize", size)
		end

		self.UpdateSaveInfoMirror(entry)
		-- A BLOCKED save persisted the last-good snapshot, NOT the live data (Dirty
		-- stayed set above), so it is NOT durable. Report that honestly to AwaitSave
		-- waiters: acking success here would let a receipt/gift path return
		-- PurchaseGranted for a grant that lives only in memory, losing paid Robux
		-- (Roblox never retries a granted receipt). Not-durable makes the receipt
		-- retry until the block clears and the grant truly persists. Only waiters
		-- COVERED by this save's payload are answered; later registrants wait for
		-- the follow-up save their own AwaitSave triggered.
		resumeCoveredWaiters(entry, not entry.Blocked)
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
		if type(work[Template.RESERVED_ROOT]) ~= "table" then
			work[Template.RESERVED_ROOT] = {}
		end
		work[Template.RESERVED_ROOT].Version = currentVersion
		table.clear(data)
		for k, v in work do
			data[k] = v
		end
		Log.Info("Persistence", "MIGRATED", `profile migrated {stored} -> {currentVersion}`, { Player = entry.Player })
		-- The migration may legitimately remove/rename top-level keys, but the wipe
		-- guard's baseline (profile.LastSavedData) still holds the PRE-migration shape
		-- until the first save commits. Skip the guard for that first save so an
		-- intentional key removal does not trip it (which under WipeGuardPolicy="Block"
		-- would re-persist the old data and permanently stall the migration). The
		-- first save re-establishes the baseline; the guard resumes normally after.
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

		-- A brand-new profile's very first session ever. In-place ProfileStore/
		-- ProfileService adoption keeps the SessionLoadCount from the old game, so
		-- returning/legacy players are NOT flagged new and still migrate normally.
		local isNew = profile.SessionLoadCount == 1

		-- Decide which Scribe.Dynamic fields to seed, BEFORE Reconcile backfills
		-- their baseline: all of them on a brand-new profile, plus any the STORED
		-- data is missing (a field added to the template after this profile was
		-- created). Reading the stored data first is the safety guarantee -- a
		-- saved value IS present, so it is never flagged and never overwritten.
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
				-- field's FROZEN declaration-time sample -- so a returning player
				-- who resets must be re-seeded exactly like a new profile, or they
				-- keep the shared sample instead of a freshly-generated value.
				if isNew or options.ResetData or not present then
					table.insert(dynamicToSeed, node)
				end
			end
		end

		profile:AddUserId(entry.UserId)
		profile:Reconcile()

		-- A hard crash inside the very first session persists template-shaped data
		-- with the default Version (the new-profile stamp below only mutated memory)
		-- while SessionLoadCount advanced past 1. Detect that shape -- stored data
		-- still identical to the current template, ignoring per-boot Dynamic samples
		-- -- and treat the profile as fresh, or every migration would run against
		-- effectively new-player defaults (the double-apply hazard the stamp
		-- prevents). Gated to migrating profiles only, so the deep compare is rare.
		local freshAsTemplate = false
		if not isNew and not options.ResetData then
			local storedReserved = profile.Data[Template.RESERVED_ROOT]
			local storedVersion = if type(storedReserved) == "table"
					and type(storedReserved.Version) == "number"
				then storedReserved.Version
				else 1
			if storedVersion < currentVersion then
				freshAsTemplate = equalsTemplateDefaults(profile.Data)
				if freshAsTemplate then
					Log.Info(
						"Persistence",
						"PROFILE_LOADED",
						"stored data is template-fresh (first session crashed before saving); treating as new",
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

		-- Fresh data (a brand-new profile, or a ResetData wipe) is built entirely
		-- from the CURRENT template, so it is already at the latest version --
		-- stamp it and let runMigrations no-op. Migrations reshape OLDER stored
		-- data; running them against fresh defaults double-applies (e.g. a one-time
		-- compensation grant handed to a new player, or a rename step overwriting a
		-- field's default with nil). Returning/legacy profiles keep their stored
		-- version and migrate as before.
		if isNew or options.ResetData or freshAsTemplate then
			local reserved = profile.Data[Template.RESERVED_ROOT]
			if type(reserved) == "table" then
				reserved.Version = currentVersion
			end
		end

		if not runMigrations(entry, profile.Data) then
			-- Fail-closed: never persist a half-migrated profile. Migrations ran
			-- on a clone, so profile.Data is untouched; ending the session saves
			-- the unmodified original.
			entry.LocalSessionEnd = true
			profile:EndSession()
			if player.Parent == Players then
				player:Kick(options.LoadFailureMessage or "We couldn't load your data. Please rejoin!")
			end
			teardown(entry, "migration-failed")
			return
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
			-- (freshAsTemplate) all mean "this player has no prior saved data", which is
			-- exactly what first-session logic (starter kits, welcome flows) needs.
			local isNewProfile = isNew or options.ResetData == true or freshAsTemplate
			Util.safeCall(function(err)
				Log.Error("Lifecycle", "ON_PLAYER_INIT_ERROR", err, { Player = player })
			end, options.OnPlayerInit, player, profile.Data, isNewProfile)
		end

		-- Scribe.Dynamic factories and OnPlayerInit write raw into profile.Data
		-- WITHOUT passing Node.validateWrite (the tree wraps this table only after
		-- this point). Unpersistable data introduced there -- invalid UTF-8, or a
		-- userdata/Instance/function value -- would fail the ENTIRE next save (or
		-- replication) opaquely, with no path in the log. Scan once here and
		-- surface the exact location loudly instead -- non-fatal, because the
		-- library cannot safely rewrite developer data; the developer fixes it.
		local badInit = Util.findUnpersistable(profile.Data)
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

		profile.OnSave:Connect(function()
			onProfileSaving(entry)
		end)
		profile.OnAfterSave:Connect(function(lastSavedData: any)
			onProfileSaved(entry, lastSavedData)
		end)
		profile.OnSessionEnd:Connect(function()
			-- A session end WE did not initiate (and not the shutdown drain) is an
			-- external steal: its final save persists nothing locally, so save
			-- bookkeeping must not report success for it (onProfileSaved checks this).
			entry.SessionStolen = not entry.LocalSessionEnd and not self.Closing
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
				Log.Error(
					"Lifecycle",
					"SUBSYSTEM_HOOK_ERROR",
					`{name} hook failed: {tostring(err)}`,
					{ Player = player }
				)
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
			SaveGen = 0,
			DirtyAtSaveStart = nil,
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
			entry.LocalSessionEnd = true
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
		-- Record the save generation current at registration: only a save that
		-- STARTS after this point serializes this caller's writes into its payload.
		table.insert(entry.SaveWaiters, { Thread = thread, Gen = entry.SaveGen })
		local done = false
		task.delay(timeout, function()
			if not done then
				for idx, waiter in entry.SaveWaiters do
					if waiter.Thread == thread then
						table.remove(entry.SaveWaiters, idx)
						resumeWaiter(thread, false)
						break
					end
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

	-- Serialize same-user offline read-modify-writes on THIS server. A ProfileStore
	-- view-mode SetAsync writes the whole GetAsync snapshot back, so two UpdateOffline
	-- cycles for one userId that interleave (Get_A, Get_B, Set_A, Set_B) would have
	-- the second clobber the first with stale data -- silently dropping a grant (and
	-- its ProcessedPurchaseIds dedup marker) while both report success. A per-userId
	-- FIFO lock forces the cycles to run one at a time so each reads the prior's save.
	-- (Concurrent offline writes from a DIFFERENT server remain a view-mode limitation
	-- inherent to writing without holding the session lock.)
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
			task.spawn(table.remove(waiters, 1) :: thread) -- next waiter takes the lock
		else
			offlineLocks[userId] = nil
		end
	end

	function self.UpdateOffline(userId: number, fn: (data: { [string]: any }) -> ()): (boolean, string?)
		if self.EntryForUserId(userId) then
			return false, "user has an active session on this server"
		end
		acquireOffline(userId)
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
			-- The callback mutates profile.Data raw, bypassing Node.validateWrite, so
			-- unpersistable data (invalid UTF-8, or a userdata/Instance value) would
			-- make SetAsync fail the whole profile opaquely. Reject before writing.
			local bad = Util.findUnpersistable(profile.Data)
			if bad ~= nil then
				error(`unpersistable data ({bad.Detail}) at "{Util.pathString(bad.Path)}"`)
			end
			profile:SetAsync()
		end)
		releaseOffline(userId)
		if not ok then
			Health.ReportFailure("OfflineWrite")
			return false, tostring(err)
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
			-- Fail closed if the user is active on another server: RemoveAsync
			-- bypasses the session lock, so a live session elsewhere would re-save
			-- and resurrect the "erased" profile, silently defeating the deletion
			-- (same guard as UpdateOffline/RestoreVersion).
			local profile = store:GetAsync(self.KeyFor(userId))
			if profile and profile.Session then
				error("profile has an active session on another server")
			end
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
		-- Tear down profile-less Loading entries up front: one parked in a
		-- LoadFailurePolicy="Wait" backoff sleeps up to 60s before noticing Closing,
		-- which would otherwise hold the drain loop below to its FULL budget during
		-- exactly the DataStore incidents the budget is meant to protect. Their
		-- StartSessionAsync cannot succeed anymore (the Cancel hook sees Closing),
		-- and the loader no-ops on TornDown when it wakes.
		local strandedLoading: { Entry } = {}
		for _, entry in self.Entries :: { [Player]: Entry } do
			if entry.State == "Loading" and entry.Profile == nil then
				table.insert(strandedLoading, entry)
			end
		end
		for _, entry in strandedLoading do
			teardown(entry, "shutdown")
		end
		for _, entry in self.Entries :: { [Player]: Entry } do
			if entry.Profile and entry.Profile:IsActive() then
				entry.LocalSessionEnd = true
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
