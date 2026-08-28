--!nocheck
-- selene: allow(unused_variable)
--
-- VENDORED FORK of ProfileStore v1.0.3.
--   Copyright (c) loleris / MAD STUDIO.
--   Licensed under the Apache License, Version 2.0. The full licence text ships
--   with the source package at licenses/ProfileStore-Apache-2.0.txt.
--   Upstream project: ProfileStore by MAD STUDIO, on GitHub under MadStudioRoblox.
--
-- No off-platform URLs anywhere, deliberately: Roblox flags links that send
-- players off-platform and the whole of src/ is packed into the released .rbxm.
-- Attribution is given by name, which is what the licence requires.
--
-- THIS FILE HAS BEEN MODIFIED BY SCRIBE, as Apache-2.0 section 4(b) requires it
-- to say. Every change is marked `SCRIBE PATCH` and nothing else is touched --
-- no reformatting, no renaming, no style fixes -- so a future upstream release
-- can still be diffed against this one. That is also why this file is excluded
-- from stylua and selene (see .styluaignore and selene.toml).
--
-- Most of the patches remove one defect class: a save that SUCCEEDS while
-- writing nothing, because the session was superseded. A boolean cannot report
-- that, so SaveProfileAsync answers "Saved" | "NotOwned" | "Failed".

--[[
MAD STUDIO (by loleris)

-[ProfileStore]---------------------------------------

	Periodic DataStore saving solution with session locking
	
	WARNINGS FOR "Profile.Data" VALUES:
	 	! Do not create numeric tables with gaps - attempting to store such tables will result in an error.
		! Do not create mixed tables (some values indexed by number and others by a string key)
			- only numerically indexed  data will be stored.
		! Do not index tables by anything other than numbers and strings.
		! Do not reference Roblox Instances
		! Do not reference userdata (Vector3, Color3, CFrame...) - Serialize userdata before referencing
		! Do not reference functions
		
	Members:
	
		ProfileStore.IsClosing          [bool]
			-- Set to true after a game:BindToClose() trigger
			
		ProfileStore.IsCriticalState    [bool]
			-- Set to true when ProfileStore experiences too many consecutive errors
		
		ProfileStore.OnError            [Signal] (message, store_name, profile_key)
			-- Most ProfileStore errors will be caught and passed to this signal
			
		ProfileStore.OnOverwrite        [Signal] (store_name, profile_key)
			-- Triggered when a DataStore key was likely used to store data that wasn't
			a ProfileStore profile or the ProfileStore structure was invalidly manually
			altered for that DataStore key
			
		ProfileStore.OnCriticalToggle   [Signal] (is_critical)
			-- Triggered when ProfileStore experiences too many consecutive errors
		
		ProfileStore.DataStoreState     [string] ("NotReady", "NoInternet", "NoAccess", "Access")
			-- This value resembles ProfileStore's access to the DataStore; The value starts
			as "NotReady" and will eventually change to one of the other 3 possible values.
	
	Functions:
	
		ProfileStore.New(store_name, template?) --> [ProfileStore]
			store_name   [string] -- DataStore name
			template     [table] or nil -- Profiles will default to given table (hard-copy) when no data was saved previously
			
		ProfileStore.SetConstant(name, value)
			name    [string]
			value   [number]
				
	Members [ProfileStore]:
	
		ProfileStore.Mock   [ProfileStore]
			-- Reflection of ProfileStore methods, but the methods will now query a mock
			DataStore with no relation to the real DataStore
			
		ProfileStore.Name   [string]
		
	Methods [ProfileStore]:
	
		ProfileStore:StartSessionAsync(profile_key, params?) --> [Profile] or nil
			profile_key [string] -- DataStore key
			params      nil or [table]: -- Custom params; E.g. {Steal = true}
				{
					Steal = true, -- Pass this to disregard an existing session lock
					Cancel = fn() -> (boolean), -- Pass this to create a request cancel condition.
						-- If the cancel function returns true, ProfileStore will stop trying to
						-- start the session and return nil
				}
			
		ProfileStore:MessageAsync(profile_key, message) --> is_success [bool]
			profile_key [string] -- DataStore key
			message     [table] -- Data to be messaged to the profile
			-- SCRIBE PATCH: two further returns, reason [string?] and
			-- provably_clean [bool?]; see the method body.
			
		ProfileStore:GetAsync(profile_key, version?) --> [Profile] or nil
			-- Reads a profile without starting a session - will not autosave
			profile_key   [string] -- DataStore key
			version       nil or [string] -- DataStore key version

		ProfileStore:VersionQuery(profile_key, sort_direction?, min_date?, max_date?) --> [VersionQuery]
			profile_key      [string]
			sort_direction   nil or [Enum.SortDirection]
			min_date         nil or [DateTime]
			max_date         nil or [DateTime]
			
		ProfileStore:RemoveAsync(profile_key) --> is_success [bool]
			-- Completely removes profile data from the DataStore / mock DataStore with no way to recover it.

	Methods [VersionQuery]:

		VersionQuery:NextAsync() --> [Profile] or nil -- (Yields)
			-- Returned profile is similar to profiles returned by ProfileStore:GetAsync()
		
	Members [Profile]:
	
		Profile.Data               [table]
			-- When the profile is active changes to this table are guaranteed to be saved
		Profile.LastSavedData      [table] (Read-only)
			-- Last snapshot of "Profile.Data" that has been successfully saved to the DataStore;
			Useful for proper developer product purchase receipt handling
		
		Profile.FirstSessionTime   [number] (Read-only)
			-- os.time() timestamp of the first profile session
			
		Profile.SessionLoadCount   [number] (Read-only) -- Amount of times a session was started for this profile
			
		Profile.Session            [table] (Read-only) {PlaceId = number, JobId = string} / nil
			-- Set to a table if this profile is in use by a server; nil if released

		Profile.RobloxMetaData     [table] -- Writable table that gets saved automatically and once the profile is released
		Profile.UserIds            [table] -- (Read-only) -- {user_id [number], ...} -- User ids associated with this profile

		Profile.KeyInfo            [DataStoreKeyInfo] -- Changes before OnAfterSave signal
		
		Profile.OnSave             [Signal] ()
			-- Triggered right before changes to Profile.Data are saved to the DataStore
			
		Profile.OnLastSave         [Signal] (reason [string]: "Manual", "External", "Shutdown")
			-- Triggered right before changes to Profile.Data are saved to the DataStore
			for the last time; A reason is provided for the last save:
				- "Manual"   - Profile:EndSession() was called
				- "Shutdown" - The server that has ownership of this profile is shutting down
				- "External" - Another server has started a session for this profile
			Note that this event will not trigger for when a profile session is ended by
			another server trying to take ownership of the session - this is impossible to
			do without compromising on ProfileStore's speed.
			
		Profile.OnSessionEnd       [Signal] ()
			-- Triggered when the profile session is terminated on this server
		
		Profile.OnAfterSave        [Signal] (last_saved_data)
			-- Triggered after a successful save
			last_saved_data [table] -- Profile.LastSavedData
			
		Profile.ProfileStore       [ProfileStore] -- ProfileStore object this profile belongs to
		Profile.Key                [string] -- DataStore key
		
	Methods [Profile]:
	
		Profile:IsActive() --> [bool] -- If "true" is returned, changes to Profile.Data are guaranteed to save;
			This guarantee is only valid until code yields (e.g. task.wait() is used).
			
		Profile:Reconcile() -- Fills in missing (nil) [string_key] = [value] pairs to the Profile.Data structure
			from the "template" argument that was passed to "ProfileStore.New()"
			
		Profile:HasCompletedSave() --> [bool] -- (SCRIBE PATCH) Whether a save for this profile
			has ever committed. Never true for a profile keyed on a negative user id
			outside mock, since AddUserId refuses those.
			
		Profile:SessionsStarted() --> [number] -- (SCRIBE PATCH) Profile.SessionLoadCount,
			normalized for view mode, which skips the session-start increment
			
		Profile:SetSaveSource(data) --> () -- (SCRIBE PATCH) Choose the table this profile
			serializes from. Per-profile, not per-save; see the note at the method.
			
		Profile:EndSession() -- Call after the server has finished working with this profile
			e.g., after the player leaves (Profile object will become inactive)

		Profile:AddUserId(user_id) -- Associates user_id with profile (GDPR compliance)
			user_id   [number]

		Profile:RemoveUserId(user_id) -- Removes user_id association with profile (safe function)
			user_id   [number]
			
		Profile:MessageHandler(fn) -- Sets a message handler for this profile
			fn [function] (message [table], processed [function]())
			-- The handler function receives a message table and a callback function;
			The callback function is to be called when a message has been processed
			- this will discard the message from the profile message cache; If the
			callback function is not called, other message handlers will also be triggered
			with unprocessed message data.
			
		Profile:Save() -- If the profile session is still active makes an UpdateAsync call
			to the DataStore to immediately save profile data

		Profile:SetAsync() -- Forcefully saves changes to the profile; Only for profiles
			loaded with ProfileStore:GetAsync() or ProfileStore:VersionQuery()
		
--]]

local AUTO_SAVE_PERIOD = 300 -- (Seconds) Time between when changes to a profile are saved to the DataStore
local LOAD_REPEAT_PERIOD = 10 -- (Seconds) Time between successive profile reads when handling a session conflict
local FIRST_LOAD_REPEAT = 5 -- (Seconds) Time between first and second profile read when handling a session conflict
local SESSION_STEAL = 40 -- (Seconds) Time until a session conflict is resolved with the waiting server stealing the session
local ASSUME_DEAD = 630 -- (Seconds) If a profile hasn't had updates for this long, quickly assume an active session belongs to a crashed server
local START_SESSION_TIMEOUT = 120 -- (Seconds) If a session can't be started for a profile for this long, stop repeating calls to the DataStore

local CRITICAL_STATE_ERROR_COUNT = 5 -- Assume critical state if this many issues happen in a short amount of time
local CRITICAL_STATE_ERROR_EXPIRE = 120 -- (Seconds) Individual issue expiration
local CRITICAL_STATE_EXPIRE = 120 -- (Seconds) Critical state expiration

local MAX_MESSAGE_QUEUE = 1000 -- Max messages saved in a profile that were sent using "ProfileStore:MessageAsync()"

----- Dependencies -----

-- local Util = require(game.ReplicatedStorage.Shared.Util)
-- local Signal = Util.Signal

-- SCRIBE PATCH: the error classifier, INJECTED rather than required, and the
-- file's only dependency of any kind.
--
-- MessageAsync's third return has to answer "could ANY attempt in this call have
-- written?", and the evidence is the error each failed attempt raised. Scribe
-- already owns that classifier in Internal/Failure.luau, so it is handed in rather
-- than restated here. Persistence installs it as it adopts the store module
-- (findProfileStoreModule), the single seam every route to this file goes through.
--
-- A require was tried first and is wrong. This file has no `require` and no
-- `script`, and that is load-bearing: the simulation loads it as raw source into a
-- synthetic global table so each simulated server gets a private copy of the module
-- state (test/Sim/Server.luau, test/Sim/Loader.luau). A require fails outright
-- there, and making it work would hand every simulated server the harness's one
-- shared Health/Log/Metrics graph.
--
-- Unset is exactly the old behaviour: absent a classifier every failed attempt
-- reads as "could have written", which is bit-for-bit what the attempt COUNT it
-- replaced computed. The field is declared with the module table below.

local Signal do

	local FreeRunnerThread

	--[[
		Yield-safe coroutine reusing by stravant;
		Source: the GoodSignal comparison thread on the Roblox DevForum.
		(SCRIBE PATCH: the two source URLs are removed rather than redacted at
		build time to comply with roblox development guidelines.)
	--]]

	local function AcquireRunnerThreadAndCallEventHandler(fn, ...)
		local acquired_runner_thread = FreeRunnerThread
		FreeRunnerThread = nil
		fn(...)
		-- The handler finished running, this runner thread is free again.
		FreeRunnerThread = acquired_runner_thread
	end

	local function RunEventHandlerInFreeThread(...)
		AcquireRunnerThreadAndCallEventHandler(...)
		while true do
			AcquireRunnerThreadAndCallEventHandler(coroutine.yield())
		end
	end

	local Connection = {}
	Connection.__index = Connection

	local SignalClass = {}
	SignalClass.__index = SignalClass

	function Connection:Disconnect()

		if self.is_connected == false then
			return
		end

		local signal = self.signal
		self.is_connected = false
		signal.listener_count -= 1

		if signal.head == self then
			signal.head = self.next
		else
			local prev = signal.head
			while prev ~= nil and prev.next ~= self do
				prev = prev.next
			end
			if prev ~= nil then
				prev.next = self.next
			end
		end

	end

	function SignalClass.New()

		local self = {
			head = nil,
			listener_count = 0,
		}
		setmetatable(self, SignalClass)

		return self

	end

	function SignalClass:Connect(listener: (...any) -> ())

		if type(listener) ~= "function" then
			error(`[{script.Name}]: \"listener\" must be a function; Received {typeof(listener)}`)
		end

		local connection = {
			listener = listener,
			signal = self,
			next = self.head,
			is_connected = true,
		}
		setmetatable(connection, Connection)

		self.head = connection
		self.listener_count += 1

		return connection

	end

	function SignalClass:GetListenerCount(): number
		return self.listener_count
	end

	function SignalClass:Fire(...)
		local item = self.head
		while item ~= nil do
			if item.is_connected == true then
				if not FreeRunnerThread then
					FreeRunnerThread = coroutine.create(RunEventHandlerInFreeThread)
				end
				task.spawn(FreeRunnerThread, item.listener, ...)
			end
			item = item.next
		end
	end

	function SignalClass:Wait()
		local co = coroutine.running()
		local connection
		connection = self:Connect(function(...)
			connection:Disconnect()
			task.spawn(co, ...)
		end)
		return coroutine.yield()
	end

	Signal = table.freeze({
		New = SignalClass.New,
	})

end

----- Private -----

local ActiveSessionCheck = {} -- {[session_token] = profile, ...}
-- SCRIBE PATCH: what LastSavedData becomes for an owner that has opted out of
-- retaining it. Frozen and shared, so releasing costs one field write and no
-- allocation -- and empty, which every existing consumer already reads as "there is
-- no baseline to compare against" (Scribe's own wipe guard tests exactly that).
local RELEASED_LAST_SAVED = table.freeze({})

local AutoSaveList = {} -- {profile, ...} -- Loaded profile table which will be circularly auto-saved
local IssueQueue = {} -- {issue_time, ...}

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local PlaceId = game.PlaceId
local JobId = game.JobId

local AutoSaveIndex = 1 -- Next profile to auto save
local LastAutoSave = os.clock()

local LoadIndex = 0

local ActiveProfileLoadJobs = 0 -- Number of active threads that are loading in profiles
local ActiveProfileSaveJobs = 0 -- Number of active threads that are saving profiles

local CriticalStateStart = 0 -- os.clock()

local IsStudio = RunService:IsStudio()
local DataStoreState: "NotReady" | "NoInternet" | "NoAccess" | "Access" = "NotReady"

local MockStore = {}
local UserMockStore = {}
local MockFlag = false

local OnError = Signal.New() -- (message, store_name, profile_key)
local OnOverwrite = Signal.New() -- (store_name, profile_key)

local UpdateQueue = { -- For stability sake, we won't do UpdateAsync calls for the same key until all previous calls finish
	--[[
		[session_token] = {
			coroutine, ...
		},
		...
	--]]
}

local function WaitInUpdateQueue(session_token) --> next_in_queue()

	local is_first = false

	if UpdateQueue[session_token] == nil then
		is_first = true
		UpdateQueue[session_token] = {}
	end

	local queue = UpdateQueue[session_token]

	if is_first == false then
		table.insert(queue, coroutine.running())
		coroutine.yield()
	end

	return function()
		local next_co = table.remove(queue, 1)
		if next_co ~= nil then
			coroutine.resume(next_co)
		else
			UpdateQueue[session_token] = nil
		end
	end

end

local function SessionToken(store_name, profile_key, is_mock)

	local session_token = "L_" -- Live

	if is_mock == true then
		session_token = "U_" -- User mock
	elseif DataStoreState ~= "Access" then
		session_token = "M_" -- Mock, cause no DataStore access
	end

	session_token ..= store_name .. "\0" .. profile_key

	return session_token

end

-- SCRIBE PATCH: buffers are COPIED, not shared. Upstream's DeepCopyTable and
-- ReconcileTable recurse on tables and pass everything else through by value,
-- which is wrong for a buffer, because a buffer IS a mutable reference.
-- (Upstream PR #22, unmerged.)
--
-- Scribe's persistent template contains buffers, so two copies were aliases:
-- template -> Data on every key mint, so every profile on the server shared one
-- buffer with the template and a write through any of them seeded every future
-- profile with the last player's bytes; and Data -> LastSavedData in Profile.New,
-- which the wipe guard diffs against live data -- aliased, it diffs live against
-- live and can never trip. Latent today only because Scribe's own datatype writes
-- always allocate a fresh buffer instead of writing through the existing one.
local function CopyBuffer(source)
	local size = buffer.len(source)
	local copy = buffer.create(size)
	buffer.copy(copy, 0, source, 0, size)
	return copy
end

local function DeepCopyTable(t)
	local copy = {}
	for key, value in pairs(t) do
		if type(value) == "table" then
			copy[key] = DeepCopyTable(value)
		elseif type(value) == "buffer" then -- SCRIBE PATCH
			copy[key] = CopyBuffer(value)
		else
			copy[key] = value
		end
	end
	return copy
end

local function ReconcileTable(target, template)
	for k, v in pairs(template) do
		if type(k) == "string" then -- Only string keys will be reconciled
			if target[k] == nil then
				if type(v) == "table" then
					target[k] = DeepCopyTable(v)
				elseif type(v) == "buffer" then -- SCRIBE PATCH: see CopyBuffer
					target[k] = CopyBuffer(v)
				else
					target[k] = v
				end
			elseif type(target[k]) == "table" and type(v) == "table" then
				ReconcileTable(target[k], v)
			end
		end
	end
end

local function RegisterError(error_message, store_name, profile_key) -- Called when a DataStore API call errors
	warn(`[{script.Name}]: DataStore API error (STORE:{store_name}; KEY:{profile_key}) - {tostring(error_message)}`)
	table.insert(IssueQueue, os.clock()) -- Adding issue time to queue
	OnError:Fire(tostring(error_message), store_name, profile_key)
end

local function RegisterOverwrite(store_name, profile_key) -- Called when a corrupted profile is loaded
	warn(`[{script.Name}]: Invalid profile was overwritten (STORE:{store_name}; KEY:{profile_key})`)
	OnOverwrite:Fire(store_name, profile_key)
end

local function NewMockDataStoreKeyInfo(params)

	local version_id_string = tostring(params.VersionId or 0)
	local meta_data = params.MetaData or {}
	local user_ids = params.UserIds or {}

	return {
		CreatedTime = params.CreatedTime,
		UpdatedTime = params.UpdatedTime,
		Version = string.rep("0", 16) .. "."
			.. string.rep("0", 10 - string.len(version_id_string)) .. version_id_string
			.. "." .. string.rep("0", 16) .. "." .. "01",

		GetMetadata = function()
			return DeepCopyTable(meta_data)
		end,

		GetUserIds = function()
			return DeepCopyTable(user_ids)
		end,
	}

end

local function MockUpdateAsync(mock_data_store, profile_store_name, key, transform_function, is_get_call) --> loaded_data, key_info

	local profile_store = mock_data_store[profile_store_name]

	if profile_store == nil then
		profile_store = {}
		mock_data_store[profile_store_name] = profile_store
	end

	local epoch_time = math.floor(os.time() * 1000)
	local mock_entry = profile_store[key]
	local mock_entry_was_nil = false

	if mock_entry == nil then
		mock_entry_was_nil = true
		if is_get_call ~= true then
			mock_entry = {
				Data = nil,
				CreatedTime = epoch_time,
				UpdatedTime = epoch_time,
				VersionId = 0,
				UserIds = {},
				MetaData = {},
			}
			profile_store[key] = mock_entry
		end
	end

	local mock_key_info = mock_entry_was_nil == false and NewMockDataStoreKeyInfo(mock_entry) or nil

	local transform, user_ids, roblox_meta_data = transform_function(mock_entry and mock_entry.Data, mock_key_info)

	if transform == nil then
		return nil
	else
		if mock_entry ~= nil and is_get_call ~= true then
			mock_entry.Data = DeepCopyTable(transform)
			mock_entry.UserIds = DeepCopyTable(user_ids or {})
			mock_entry.MetaData = DeepCopyTable(roblox_meta_data or {})
			mock_entry.VersionId += 1
			mock_entry.UpdatedTime = epoch_time
		end

		return DeepCopyTable(transform), mock_entry ~= nil and NewMockDataStoreKeyInfo(mock_entry) or nil
	end

end

local function UpdateAsync(profile_store, profile_key, transform_params, is_user_mock, is_get_call, version) --> loaded_data, key_info
	--transform_params = {
	--	ExistingProfileHandle = function(latest_data),
	--	MissingProfileHandle = function(latest_data),
	--	EditProfile = function(latest_data),
	--}

	local loaded_data, key_info
	
	local next_in_queue = WaitInUpdateQueue(SessionToken(profile_store.Name, profile_key, is_user_mock))

	local success = true

	local success, error_message = pcall(function()
		local transform_function = function(latest_data)

			local missing_profile = false
			local overwritten = false
			local global_updates = {0, {}}

			if latest_data == nil then

				missing_profile = true

			elseif type(latest_data) ~= "table" then

				missing_profile = true
				overwritten = true

			else

				if type(latest_data.Data) == "table" and type(latest_data.MetaData) == "table" and type(latest_data.GlobalUpdates) == "table" then

					-- Regular profile structure detected:

					latest_data.WasOverwritten = false -- Must be set to false if set previously
					global_updates = latest_data.GlobalUpdates

					if transform_params.ExistingProfileHandle ~= nil then
						transform_params.ExistingProfileHandle(latest_data)
					end

				elseif latest_data.Data == nil and latest_data.MetaData == nil and type(latest_data.GlobalUpdates) == "table" then

					-- Regular structure not detected, but GlobalUpdate data exists:

					latest_data.WasOverwritten = false -- Must be set to false if set previously
					global_updates = latest_data.GlobalUpdates or global_updates
					missing_profile = true

				else

					missing_profile = true
					overwritten = true

				end

			end

			-- Profile was not created or corrupted and no GlobalUpdate data exists:
			if missing_profile == true then
				latest_data = {
					-- Data = nil,
					-- MetaData = nil,
					GlobalUpdates = global_updates,
				}
				if transform_params.MissingProfileHandle ~= nil then
					transform_params.MissingProfileHandle(latest_data)
				end
			end

			-- Editing profile:
			if transform_params.EditProfile ~= nil then
				transform_params.EditProfile(latest_data)
			end

			-- SCRIBE PATCH: let a transform genuinely DECLINE. Every path below used
			-- to return latest_data, and UpdateAsync commits unless the transform
			-- returns nil -- so a refused compare-and-set still minted a key version,
			-- spent a write budget, and (on the missing-profile path above) created a
			-- stub key that had never existed.
			if transform_params.AbortWrite == true then
				return nil
			end

			-- Invalid data handling (Silently override with empty profile)
			if overwritten == true then
				latest_data.WasOverwritten = true -- Temporary tag that will be removed on first save
			end

			return latest_data, latest_data.UserIds, latest_data.RobloxMetaData
		end

		if is_user_mock == true then -- Used when the profile is accessed through ProfileStore.Mock

			loaded_data, key_info = MockUpdateAsync(UserMockStore, profile_store.Name, profile_key, transform_function, is_get_call)
			task.wait() -- Simulate API call yield

		elseif DataStoreState ~= "Access" then -- Used when API access is disabled

			loaded_data, key_info = MockUpdateAsync(MockStore, profile_store.Name, profile_key, transform_function, is_get_call)
			task.wait() -- Simulate API call yield

		else

			if is_get_call == true then

				if version ~= nil then

					local success, error_message = pcall(function()
						loaded_data, key_info = profile_store.data_store:GetVersionAsync(profile_key, version)
					end)

					if success == false and type(error_message) == "string" and string.find(error_message, "not valid") ~= nil then
						warn(`[{script.Name}]: Passed version argument is not valid; Traceback:\n` .. debug.traceback())
					end

				else

					loaded_data, key_info = profile_store.data_store:GetAsync(profile_key)

				end

				loaded_data = transform_function(loaded_data)

			else

				loaded_data, key_info = profile_store.data_store:UpdateAsync(profile_key, transform_function)

			end

		end

	end)

	next_in_queue()

	if success == true and type(loaded_data) == "table" then
		-- Invalid data handling:
		if loaded_data.WasOverwritten == true and is_get_call ~= true then
			RegisterOverwrite(
				profile_store.Name,
				profile_key
			)
		end
		-- Return loaded_data:
		return loaded_data, key_info
	elseif success == true and transform_params.AbortWrite == true then
		-- SCRIBE PATCH: a transform that DECLINED is not a DataStore error.
		--
		-- A refusal returns nil, and so does a FAILED call; this branch could not
		-- tell them apart, so every refusal warned, added an entry to IssueQueue
		-- (five inside the window flip IsCriticalState) and fired OnError -- which
		-- Scribe reports as PROFILE_STORE_ERROR and feeds into Health, where an
		-- Outage refuses Robux grants for every player on the server.
		-- UpdateOfflineAsync guards the same condition at its call site, but on the
		-- RETURN VALUE, by which time OnError has fired; both stay, because they
		-- answer different questions.
		--
		-- `success == true` is load-bearing: a transform that set AbortWrite and
		-- THEN hit a failing DataStore call must still be registered, so a genuine
		-- outage cannot hide behind a refusal.
		return nil
	else
		-- Error handling:
		-- SCRIBE PATCH: KEEP the error, do not only report it. RegisterError warns,
		-- queues an issue and fires OnError, and then the string is gone -- every
		-- failure class reached the caller as the same bare nil, which is what forced
		-- MessageAsync's `provably_clean` to be guessed from an attempt COUNT. See the
		-- note on `provably_clean` in MessageAsync for what is done with the class.
		--
		-- Written onto transform_params, which the caller already owns and already
		-- reads for AbortWrite and QueueFull, so the return signature is unchanged and
		-- the `table.pack(UpdateAsync(...))` in StartSessionAsync keeps its arity.
		transform_params.ErrorMessage = error_message
		RegisterError(
			error_message or "Undefined error",
			profile_store.Name,
			profile_key
		)
		-- Return nothing:
		return nil
	end

end

local function IsThisSession(session_tag)
	return session_tag[1] == PlaceId and session_tag[2] == JobId
end

local function ReadMockFlag(): boolean
	local is_mock = MockFlag
	MockFlag = false
	return is_mock
end

local function WaitForStoreReady(profile_store)
	while profile_store.is_ready == false do
		task.wait()
	end
end

local function AddProfileToAutoSave(profile)

	ActiveSessionCheck[profile.session_token] = profile

	-- Add at AutoSaveIndex and move AutoSaveIndex right:

	table.insert(AutoSaveList, AutoSaveIndex, profile)

	if #AutoSaveList > 1 then
		AutoSaveIndex = AutoSaveIndex + 1
	elseif #AutoSaveList == 1 then
		-- First profile created - make sure it doesn't get immediately auto saved:
		LastAutoSave = os.clock()
	end

end

local function RemoveProfileFromAutoSave(profile)

	ActiveSessionCheck[profile.session_token] = nil

	local auto_save_index = table.find(AutoSaveList, profile)

	if auto_save_index ~= nil then
		table.remove(AutoSaveList, auto_save_index)
		if auto_save_index < AutoSaveIndex then
			AutoSaveIndex = AutoSaveIndex - 1 -- Table contents were moved left before AutoSaveIndex so move AutoSaveIndex left as well
		end
		if AutoSaveList[AutoSaveIndex] == nil then -- AutoSaveIndex was at the end of the AutoSaveList - reset to 1
			AutoSaveIndex = 1
		end
	end

end

local function SaveProfileAsync(profile, is_ending_session, is_overwriting, last_save_reason)

	if type(profile.Data) ~= "table" then
		error(`[{script.Name}]: Developer code likely set "Profile.Data" to a non-table value! (STORE:{profile.ProfileStore.Name}; KEY:{profile.Key})`)
	end

	-- SCRIBE PATCH: a context owned by THIS call, handed to OnSave and returned to
	-- the caller, so a handler can record something about the save it is running
	-- inside. Anything stored on `entry` instead would be a single slot shared by
	-- every in-flight save. Existing handlers take no arguments and are unaffected.
	local save_context = {}
	profile.OnSave:Fire(save_context)
	if is_ending_session == true then
		profile.OnLastSave:Fire(last_save_reason or "Manual")
	end

	if is_ending_session == true and is_overwriting ~= true then
		if profile.roblox_message_subscription ~= nil then
			profile.roblox_message_subscription:Disconnect()
		end
		RemoveProfileFromAutoSave(profile)
		profile.OnSessionEnd:Fire()
	end

	ActiveProfileSaveJobs = ActiveProfileSaveJobs + 1

	-- Compare "SessionLoadCount" when writing to profile to prevent a rare case of repeat last save when the profile is loaded on the same server again

	local repeat_save_flag = true -- Released Profile save calls have to repeat until they succeed
	local exp_backoff = 1
	-- SCRIBE PATCH: what THIS call achieved. nil until a round trip settles it.
	local outcome: string? = nil

	while repeat_save_flag == true do

		if is_ending_session ~= true then
			repeat_save_flag = false
		end

		-- SCRIBE PATCH: the release a save performs when it turns out not to own the
		-- profile. Extracted so the removed-key path below can take the SAME one
		-- rather than growing a second copy that drifts.
		local function release_not_owned()
			if profile.roblox_message_subscription ~= nil then
				profile.roblox_message_subscription:Disconnect()
			end
			if profile:IsActive() == true then
				RemoveProfileFromAutoSave(profile)
				profile.OnSessionEnd:Fire()
			end
		end

		-- SCRIBE PATCH: set by the transform when the key has been REMOVED under this
		-- live session. See the note at its assignment.
		local key_removed = false
		local transform_params
		transform_params = {
				ExistingProfileHandle = nil,
				MissingProfileHandle = nil,
				AbortWrite = false,
				EditProfile = function(latest_data)
					
					-- Check if this session still owns the profile:

					local session_owns_profile = false

					if is_overwriting ~= true then

						-- SCRIBE PATCH: `type(latest_data.MetaData) == "table"`.
						--
						-- A key REMOVED under a live session (a GDPR erase that raced the
						-- session start) reaches this transform as UpdateAsync's
						-- missing-profile stub -- GlobalUpdates and nothing else. Indexing
						-- MetaData on it threw inside UpdateAsync's own pcall, so the save
						-- neither wrote nor released; and because that repeated on every
						-- autosave the session stayed ACTIVE FOREVER, accepting writes it
						-- silently discarded. Measured: 200 s at a 30 s autosave period,
						-- still Ready, every write gone. No MetaData means no ActiveSession,
						-- so leaving session_owns_profile false routes it to the same clean
						-- release a stolen session takes.
						if type(latest_data.MetaData) == "table" then
							local active_session = latest_data.MetaData.ActiveSession
							local session_load_count = latest_data.MetaData.SessionLoadCount

							if type(active_session) == "table" then
								session_owns_profile = IsThisSession(active_session)
									and session_load_count == profile.load_index
							end
						else
							-- The key is gone. Write NOTHING: committing here would
							-- recreate it as a GlobalUpdates-only stub, and an erased user
							-- whose key exists again answers Data.GetOffline as though the
							-- erase had not happened. Measured before this abort was added:
							-- keyShape=GlobalUpdates, getOffline=true.
							key_removed = true
							transform_params.AbortWrite = true
						end

					else
						session_owns_profile = true
					end

					-- We may only edit the profile if this server has ownership of the profile:

					if session_owns_profile == true then

						-- Clear processed updates (messages):

						local locked_updates = profile.locked_global_updates -- [index] = true, ...
						local active_updates = latest_data.GlobalUpdates[2]
						-- ProfileService module format: {{update_id, version_id, update_locked, update_data}, ...}
						-- ProfileStore module format: {{update_id, update_data}, ...}

						-- SCRIBE PATCH: `and profile.scribe_release_only ~= true`.
						--
						-- Retiring a message and persisting the data that message
						-- produced have to land in the SAME UpdateAsync, or delivery
						-- degrades from at-least-once to at-most-once. This sweep sat
						-- OUTSIDE the release-only gate below, so a release that
						-- deliberately writes no Data still deleted every update
						-- processed() had acknowledged: the gift was consumed into
						-- profile.Data, profile.Data was then not written, and the
						-- message that would have redelivered it was gone from the key.
						--
						-- Skipping the sweep leaves the update in storage, so the next
						-- session is handed it again. A duplicate delivery is recoverable
						-- (Scribe dedupes on ProcessedPurchaseIds) and a dropped one is
						-- not. Leaving the ids in locked_global_updates is safe: the
						-- prune after the round trip drops an id once storage stops
						-- listing it, and a release-only save is ending this session.
						if next(locked_updates) ~= nil and profile.scribe_release_only ~= true then
							local i = 1
							while i <= #active_updates do
								local update = active_updates[i]
								if locked_updates[update[1]] == true then
									table.remove(active_updates, i)
								else
									i += 1
								end
							end
						end

						-- Save profile data:

						-- SCRIBE PATCH: a release that deliberately writes no Data.
						--
						-- Scribe's three fail-closed load paths (a failed migration, a
						-- rejected schema check, a refused load) promise the stored bytes
						-- are left alone so the profile can be inspected and recovered.
						-- Ending the session breaks that: EndSession is
						-- SaveProfileAsync(..., is_ending_session), and by the time those
						-- paths run, profile.Data has already been through CoerceMapKeys,
						-- Reconcile, the version stamp and the whole migration chain.
						-- Measured: a rejected profile came back with template defaults
						-- backfilled into storage and the key version advanced twice.
						--
						-- The lock still has to be released or the player cannot rejoin
						-- anywhere, so this writes MetaData and nothing else. Data,
						-- RobloxMetaData and UserIds keep whatever is on the key.
						if profile.scribe_release_only ~= true then
							latest_data.Data = profile.Data
							-- SCRIBE PATCH: WHICH table this write serialized, recorded at WRITE
							-- time. A caller that decided what its payload was when ITS OnSave fired
							-- is describing the pointer as it stood at SNAPSHOT time, and the line
							-- above reads it now; see the hazard note on SetSaveSource.
							--
							-- The identity, not a verdict: the store has no idea what a wipe guard
							-- is. It reports which table went to the key and lets the caller compare
							-- that against whatever it considers live.
							save_context.SavedSource = profile.Data
							latest_data.RobloxMetaData = profile.RobloxMetaData
							latest_data.UserIds = profile.UserIds
						else
							-- SCRIBE PATCH: tell the caller this write carried no Data.
							--
							-- The outcome of a release-only save is still "Saved", and correctly
							-- so -- it IS a successful write, of MetaData. But an AwaitSave that
							-- reads only the outcome therefore answers TRUE for a save that put
							-- none of the caller's bytes on disk. Scribe's monetization path
							-- returns PurchaseGranted on that boolean and Roblox never retries a
							-- granted receipt, so the lie is paid Robux for data that was never
							-- stored. Measured on a prototype that set the flag on a Ready profile:
							-- one run minted 40 coins, another destroyed 40.
							--
							-- Recorded here in the transform rather than when OnSave fired:
							-- release-only is decided at WRITE time, and a save already on the wire
							-- when the flag was set writes no Data while an OnSave-time capture
							-- would still report that it did.
							save_context.ReleaseOnly = true
						end

						-- SCRIBE PATCH: bumped ABOVE the branch, so the OVERWRITE arm
						-- gets it too. That arm is the view-mode SetAsync that
						-- RestoreVersion commits through, and it stamps neither
						-- LastUpdate nor SessionLoadCount -- so before this counter a
						-- view write left the compare-and-set fingerprint byte-identical
						-- and a stale CAS silently reverted an operator's restore.
						latest_data.MetaData.WriteIndex = (latest_data.MetaData.WriteIndex or 0) + 1

						if is_overwriting ~= true then

							latest_data.MetaData.LastUpdate = os.time()

							if is_ending_session == true then
								latest_data.MetaData.ActiveSession = nil
							end

						else

							latest_data.MetaData.ActiveSession = nil
							latest_data.MetaData.ForceLoadSession = nil

						end

					end

				end,
		}

		local loaded_data, key_info = UpdateAsync(profile.ProfileStore, profile.Key, transform_params, profile.is_mock)

		if key_removed == true then
			-- Nothing was written and nothing can be: this session no longer owns a
			-- key that no longer exists. Release it the same way a stolen session is
			-- released, so the holder stops accepting writes it would silently drop.
			repeat_save_flag = false
			release_not_owned()
			outcome = "NotOwned"
			profile.OnAfterSave:Fire(profile.LastSavedData)
			break
		end

		if loaded_data ~= nil and key_info ~= nil then

			if is_overwriting == true then
				-- SCRIBE PATCH: the round trip returned, so an overwrite ends here having
				-- written. Unreachable today (no caller passes is_overwriting), assigned so
				-- it stays correct if one ever does.
				outcome = "Saved"
				break
			end
			
			repeat_save_flag = false
			
			-- SCRIBE PATCH: same missing-MetaData tolerance as the transform above --
			-- these three reads threw on a removed key too, one statement later.
			local latest_meta = if type(loaded_data.MetaData) == "table" then loaded_data.MetaData else nil
			local active_session = if latest_meta then latest_meta.ActiveSession else nil
			local session_load_count = if latest_meta then latest_meta.SessionLoadCount else nil
			local session_owns_profile = false

			if type(active_session) == "table" then
				session_owns_profile = IsThisSession(active_session) and session_load_count == profile.load_index
			end
			
			local force_load_session = if latest_meta then latest_meta.ForceLoadSession else nil
			local force_load_pending = false
			if type(force_load_session) == "table" then
				force_load_pending = not IsThisSession(force_load_session)
			end
			
			local is_active = profile:IsActive()
			
			-- If another server is trying to start a session for this profile - end the session:

			if force_load_pending == true and session_owns_profile == true then
				-- SCRIBE PATCH: report what THIS call achieved before handing over. The
				-- transform wrote and the bytes are on the key; breaking with `outcome`
				-- unassigned made `outcome or "Failed"` below report a failure for a save
				-- that persisted, which AwaitSave, Data.Flush and the receipt path all read.
				outcome = "Saved"
				if is_active == true then
					SaveProfileAsync(profile, true, false, "External")
				end
				break
			end
			
			-- Clearing processed update list / Detecting new updates:

			local locked_updates = profile.locked_global_updates -- [index] = true, ...
			local received_updates = profile.received_global_updates -- [index] = true, ...
			local active_updates = loaded_data.GlobalUpdates[2]

			local new_updates = {} -- {}, ...
			local still_pending = {} -- [index] = true, ...

			for _, update in ipairs(active_updates) do
				if locked_updates[update[1]] == true then
					still_pending[update[1]] = true
				elseif received_updates[update[1]] ~= true then
					received_updates[update[1]] = true
					table.insert(new_updates, update)
				end
			end

			for index in pairs(locked_updates) do
				if still_pending[index] ~= true then
					locked_updates[index] = nil
				end
			end

			-- Updating profile values:

			profile.KeyInfo = key_info
			-- SCRIBE PATCH: a removed key's stub carries no Data, and overwriting the
			-- last known good copy with nil would hand every OnAfterSave handler a nil.
			if loaded_data.Data ~= nil then
				profile.LastSavedData = loaded_data.Data
			end
			profile.global_updates = loaded_data.GlobalUpdates and loaded_data.GlobalUpdates[2] or {}

			if session_owns_profile == true then
				if is_active == true and is_ending_session ~= true then

					-- Processing new global updates (messages):

					for _, update in ipairs(new_updates) do

						local index = update[1]
						local update_data = update[#update] -- Backwards compatibility with ProfileService

						for _, handler in ipairs(profile.message_handlers) do

							local is_processed = false
							local processed_callback = function()
								is_processed = true
								locked_updates[index] = true
							end
							
							local send_update_data = DeepCopyTable(update_data)

							task.spawn(handler, send_update_data, processed_callback)

							if is_processed == true then
								break
							end

						end

					end

				end
			else
				release_not_owned()
			end

			-- SCRIBE PATCH: set BEFORE OnAfterSave fires, so a handler can never observe
			-- a settled save whose outcome has not been recorded yet.
			outcome = if session_owns_profile == true then "Saved" else "NotOwned"

			profile.OnAfterSave:Fire(profile.LastSavedData)

			-- SCRIBE PATCH: drop the decoded response once the handlers have seen it.
			--
			-- LastSavedData is a SECOND FULL COPY of the profile, held for the life of
			-- the session. Measured: 200 deep copies of ~22 KB profiles raised the heap
			-- counter by 18.2 MiB against the live set's 22.1 MiB -- 83%, and not 100%
			-- because deep copies share interned strings while the table structure and
			-- boxed values are duplicated in full.
			--
			-- Whether releasing hands that back is NOT measurable here: Luau exposes only
			-- collectgarbage("count") with no forced collect, so an end-to-end comparison
			-- measures the collector's schedule instead, and it returned a NEGATIVE delta.
			-- The claim that does not need the collector is that this table stops being
			-- retained for the whole session and becomes collectable as soon as the save
			-- that produced it is done with.
			--
			-- Released AFTER OnAfterSave so a handler computing a summary still receives
			-- the real thing; opt-in, so an owner that says nothing is unaffected.
			if profile.scribe_retain_last_saved == false then
				profile.LastSavedData = RELEASED_LAST_SAVED
			end

		elseif repeat_save_flag == true then
			
			-- DataStore call likely resulted in an error; Repeat the DataStore call shortly
			task.wait(exp_backoff)
			exp_backoff = math.min(if last_save_reason == "Shutdown" then 8 else 20, exp_backoff * 2)

		end

	end

	ActiveProfileSaveJobs = ActiveProfileSaveJobs - 1

	-- SCRIBE PATCH: nil means every attempt errored -- for a live (non-ending) save
	-- that is exactly one attempt, because repeat_save_flag is cleared on entry.
	local settled = outcome or "Failed"

	-- SCRIBE PATCH: the one place every call leaves, so the pairing with OnSave is
	-- exact. pcall'd because a handler that throws must not strand the save job
	-- count that was just decremented above.
	pcall(function()
		profile.OnSettled:Fire(save_context, settled)
	end)

	return settled, save_context

end

----- Public -----

--[[
	Saved profile structure:
	
	{
		Data = {},
		
		MetaData = {
			ProfileCreateTime = 0,
			SessionLoadCount = 0,
			ActiveSession = {place_id, game_job_id, unique_session_id} / nil,
			ForceLoadSession = {place_id, game_job_id} / nil,
			LastUpdate = 0, -- os.time()
			MetaTags = {}, -- Backwards compatibility with ProfileService
		},
		
		RobloxMetaData = {},
		UserIds = {},
		
		GlobalUpdates = {
			update_index,
			{
				{update_index, data}, ...
			},
		},
	}

--]]

export type JSONAcceptable = { JSONAcceptable } | { [string]: JSONAcceptable } | number | string | boolean | buffer

export type Profile<T> = {
	Data: T & JSONAcceptable,
	LastSavedData: T & JSONAcceptable,
	FirstSessionTime: number,
	SessionLoadCount: number,
	Session: {PlaceId: number, JobId: string}?,
	RobloxMetaData: JSONAcceptable,
	UserIds: {number},
	KeyInfo: DataStoreKeyInfo,
	OnSave: {Connect: (self: any, listener: () -> ()) -> ({Disconnect: (self: any) -> ()})},
	OnLastSave: {Connect: (self: any, listener: (reason: "Manual" | "External" | "Shutdown") -> ()) -> ({Disconnect: (self: any) -> ()})},
	OnSessionEnd: {Connect: (self: any, listener: () -> ()) -> ({Disconnect: (self: any) -> ()})},
	OnAfterSave: {Connect: (self: any, listener: (last_saved_data: T & JSONAcceptable) -> ()) -> ({Disconnect: (self: any) -> ()})},
	ProfileStore: JSONAcceptable,
	Key: string,

	IsActive: (self: any) -> (boolean),
	Reconcile: (self: any) -> (),
	EndSession: (self: any) -> (),
	AddUserId: (self: any, user_id: number) -> (),
	RemoveUserId: (self: any, user_id: number) -> (),
	MessageHandler: (self: any, fn: (message: JSONAcceptable, processed: () -> ()) -> ()) -> (),
	Save: (self: any) -> (),
	SetAsync: (self: any) -> (),
}

export type VersionQuery<T> = {
	NextAsync: (self: any) -> (Profile<T>?),
}

type ProfileStoreStandard<T> = {
	Name: string,
	StartSessionAsync: (self: any, profile_key: string, params: {Steal: boolean?}) -> (Profile<T>?),
	-- SCRIBE PATCH: (is_success, reason, provably_clean); see MessageAsync's body.
	MessageAsync: (self: any, profile_key: string, message: JSONAcceptable) -> (boolean, string?, boolean?),
	GetAsync: (self: any, profile_key: string, version: string?) -> (Profile<T>?),
	VersionQuery: (self: any, profile_key: string, sort_direction: Enum.SortDirection?, min_date: DateTime | number | nil, max_date: DateTime | number | nil) -> (VersionQuery<T>),
	RemoveAsync: (self: any, profile_key: string) -> (boolean),
}

export type ProfileStore<T> = {
	Mock: ProfileStoreStandard<T>,
} & ProfileStoreStandard<T>

type ConstantName = "AUTO_SAVE_PERIOD" | "LOAD_REPEAT_PERIOD" | "FIRST_LOAD_REPEAT" | "SESSION_STEAL"
| "ASSUME_DEAD" | "START_SESSION_TIMEOUT" | "CRITICAL_STATE_ERROR_COUNT" | "CRITICAL_STATE_ERROR_EXPIRE"
| "CRITICAL_STATE_EXPIRE" | "MAX_MESSAGE_QUEUE"

export type ProfileStoreModule = {
	IsClosing: boolean,
	IsCriticalState: boolean,
	OnError: {Connect: (self: any, listener: (message: string, store_name: string, profile_key: string) -> ()) -> ({Disconnect: (self: any) -> ()})},
	OnOverwrite: {Connect: (self: any, listener: (store_name: string, profile_key: string) -> ()) -> ({Disconnect: (self: any) -> ()})},
	OnCriticalToggle: {Connect: (self: any, listener: (is_critical: boolean) -> ()) -> ({Disconnect: (self: any) -> ()})},
	DataStoreState: "NotReady" | "NoInternet" | "NoAccess" | "Access",
	-- SCRIBE PATCH: see the Dependencies note. Optional, and nil is the pre-hook
	-- behaviour rather than a broken state.
	ClassifyError: ((message: any) -> string)?,
	New: <T>(store_name: string, template: (T & JSONAcceptable)?) -> (ProfileStore<T>),
	SetConstant: (name: ConstantName, value: number) -> ()
}

local Profile = {}
Profile.__index = Profile

function Profile.New(raw_data, key_info, profile_store, key, is_mock, session_token)

	local data = raw_data.Data or {}
	local session = raw_data.MetaData and raw_data.MetaData.ActiveSession or nil

	local global_updates = raw_data.GlobalUpdates and raw_data.GlobalUpdates[2] or {}
	local received_global_updates = {}

	for _, update in ipairs(global_updates) do
		received_global_updates[update[1]] = true
	end

	local self = {

		Data = data,
		LastSavedData = DeepCopyTable(data),

		FirstSessionTime = raw_data.MetaData and raw_data.MetaData.ProfileCreateTime or 0,
		SessionLoadCount = raw_data.MetaData and raw_data.MetaData.SessionLoadCount or 0,
		-- SCRIBE PATCH: exposed so a caller can fingerprint what it read and hand
		-- that to UpdateOfflineAsync. Every owning save stamps it, so a key that
		-- moved between the read and the write fails the comparison.
		LastUpdate = raw_data.MetaData and raw_data.MetaData.LastUpdate or 0,
		-- SCRIBE PATCH: the fingerprint LastUpdate cannot be on its own -- it has
		-- one-second granularity, and a view-mode SetAsync moves neither it nor
		-- SessionLoadCount. This counter moves on EVERY committing write; the full
		-- reasoning is at UpdateOfflineAsync.
		--
		-- `or 0` on read, and `or 0` on BOTH sides of the comparison in
		-- UpdateOfflineAsync: a profile saved by an older build carries no WriteIndex,
		-- and it must be exactly as permissive as it was before -- neither failing
		-- every CAS nor passing every one. The first post-upgrade write installs 1.
		WriteIndex = raw_data.MetaData and raw_data.MetaData.WriteIndex or 0,
		Session = session and {PlaceId = session[1], JobId = session[2]},

		RobloxMetaData = raw_data.RobloxMetaData or {},
		UserIds = raw_data.UserIds or {},
		KeyInfo = key_info,

		OnAfterSave = Signal.New(),
		OnSave = Signal.New(),
		-- SCRIBE PATCH: fires exactly ONCE per SaveProfileAsync call, whatever the
		-- outcome -- (save_context, "Saved" | "NotOwned" | "Failed").
		--
		-- OnSave and OnAfterSave cannot be paired up by an observer: OnSave fires per
		-- call, OnAfterSave only on success, so a save that fails leaves the pair
		-- unbalanced and anything counting in-flight saves leaks. Scribe tracked that
		-- in a single timestamp slot, and a failure arriving after a concurrent success
		-- had cleared it was dropped: LastResult stayed "Ok", Dirty stayed false, and
		-- SavesFailed never moved.
		OnSettled = Signal.New(),
		OnLastSave = Signal.New(),
		OnSessionEnd = Signal.New(),

		ProfileStore = profile_store,
		Key = key,

		load_timestamp = os.clock(),
		is_mock = is_mock,
		session_token = session_token or "",
		load_index = raw_data.MetaData and raw_data.MetaData.SessionLoadCount or 0,
		locked_global_updates = {},
		received_global_updates = received_global_updates,
		message_handlers = {},
		global_updates = global_updates,

	}
	setmetatable(self, Profile)

	return self

end

function Profile:IsActive()
	return ActiveSessionCheck[self.session_token] == self
end

function Profile:Reconcile()
	ReconcileTable(self.Data, self.ProfileStore.template)
end

-- SCRIBE PATCH: has a save for this profile ever committed?
--
-- This tells a returning player who has simply never earned anything from one
-- whose FIRST session crashed before its save landed. Those look identical by
-- every other measure -- SessionLoadCount advances when a session STARTS -- and
-- treating the second as "returning" skips their legacy import and their
-- migrations, then saves an empty profile over the top as canonical.
--
-- UserIds answers it, and the answer is a property of THIS module rather than
-- of the DataStore: the list is written to the key only as part of a completed
-- save (SaveProfileAsync's EditProfile, above), and neither key-minting path --
-- the MissingProfileHandle in StartSessionAsync nor the one in GetAsync --
-- seeds it.
--
-- ONE LIMIT: AddUserId no-ops for a NEGATIVE user id outside mock (it refuses
-- to hand Roblox's APIs one), so the signal never accumulates for a profile
-- keyed on one. A caller that mints negative ids must exclude them itself.
function Profile:HasCompletedSave()
	return #self.UserIds > 0
end

-- SCRIBE PATCH: how many sessions have been STARTED for this profile.
--
-- SessionLoadCount is incremented by the session-start transform, which a view
-- does not run (GetAsync passes EditProfile = nil), so a view of a profile that
-- has been loaded once reports 0 where a live load reports 1. A caller comparing
-- the raw field against 1 to mean "brand new" therefore judges every view brand
-- new -- which for Scribe's dry-run mode meant stamping the current version and
-- skipping every migration. Normalising it here means the caller no longer has
-- to know which mode it is in to read the number correctly.
function Profile:SessionsStarted()
	return self.SessionLoadCount + (if self.view_mode == true then 1 else 0)
end

-- SCRIBE PATCH: keep, or stop keeping, the decoded response of each save.
--
-- `LastSavedData` is a full second copy of the profile, retained for the whole
-- session. Pass `false` and it is released once OnAfterSave has fired, becoming
-- a shared frozen empty table, which reads as "no baseline" to anything that
-- checks rather than as stale data that could be mistaken for the real thing.
-- The handler still receives the real table, so a summary can be taken there.
--
-- Retention is ON unless this is called. Anything that needs the BYTES of the
-- last save -- Scribe's wipe guard under `WipeGuardPolicy = "Block"` writes them
-- back as the save payload -- must keep retention on.
function Profile:SetRetainLastSaved(retain)
	self.scribe_retain_last_saved = retain ~= false
end

-- SCRIBE PATCH: choose the table this profile serializes from.
--
-- Assigning profile.Data works and always has, but WHEN it works was stated
-- nowhere: SaveProfileAsync fires OnSave, and only afterwards does its
-- UpdateAsync transform read profile.Data, so a handler that swaps the pointer
-- inside OnSave changes what that save writes. Scribe's wipe guard depends on
-- exactly that.
--
-- THE HAZARD: this is per-PROFILE, not per-save. Saves overlap -- an autosave
-- tick can start while a Flush is in flight -- and the transform reads whatever
-- the pointer holds when IT runs, so a swap affects every transform that has not
-- run yet, including ones whose OnSave fired before the swap. Anything that must
-- be per-call belongs in the OnSave context table instead.
--
-- Validated the same way SaveProfileAsync validates it, so a bad value fails at
-- the assignment rather than at the next save with no clue who wrote it.
function Profile:SetSaveSource(data)
	if type(data) ~= "table" then
		error(`[{script.Name}]: SetSaveSource expects a table (got {typeof(data)})`)
	end
	self.Data = data
end

-- SCRIBE PATCH: end the session WITHOUT writing Data back.
--
-- For the fail-closed load paths: release the lock so the player can rejoin
-- elsewhere, but leave the stored bytes exactly as they were found. Everything
-- else about the release is unchanged, including the retry until the write lands.
function Profile:EndSessionWithoutSaving()
	if self:IsActive() == true then
		self.scribe_release_only = true
		task.spawn(SaveProfileAsync, self, true, nil, "Manual")
	end
end

function Profile:EndSession()
	if self:IsActive() == true then
		task.spawn(SaveProfileAsync, self, true, nil, "Manual") -- Call save function in a new thread with release_from_session = true
	end
end

function Profile:AddUserId(user_id) -- Associates user_id with profile (GDPR compliance)

	if type(user_id) ~= "number" or user_id % 1 ~= 0 then
		warn(`[{script.Name}]: Invalid UserId argument for :AddUserId() ({tostring(user_id)}); Traceback:\n` .. debug.traceback())
		return
	end

	if user_id < 0 and self.is_mock ~= true and DataStoreState == "Access" then
		return -- Avoid giving real Roblox APIs negative UserId's
	end

	if table.find(self.UserIds, user_id) == nil then
		table.insert(self.UserIds, user_id)
	end

end

function Profile:RemoveUserId(user_id) -- Removes user_id association with profile (safe function)

	if type(user_id) ~= "number" or user_id % 1 ~= 0 then
		warn(`[{script.Name}]: Invalid UserId argument for :RemoveUserId() ({tostring(user_id)}); Traceback:\n` .. debug.traceback())
		return
	end

	local index = table.find(self.UserIds, user_id)

	if index ~= nil then
		table.remove(self.UserIds, index)
	end

end

function Profile:SetAsync() -- Saves the profile to the DataStore and removes the session lock

	if self.view_mode ~= true then
		error(`[{script.Name}]: :SetAsync() can only be used in view mode`)
	end

	SaveProfileAsync(self, nil, true)

end

function Profile:MessageHandler(fn)

	if type(fn) ~= "function" then
		error(`[{script.Name}]: fn argument is not a function`)
	end

	if self.view_mode ~= true and self:IsActive() ~= true then
		return -- Don't process messages if the profile session was ended
	end

	local locked_updates = self.locked_global_updates
	table.insert(self.message_handlers, fn)

	for _, update in ipairs(self.global_updates) do

		local index = update[1]
		local update_data = update[#update] -- Backwards compatibility with ProfileService

		if locked_updates[index] ~= true then

			local processed_callback = function()
				locked_updates[index] = true
			end
			
			local send_update_data = DeepCopyTable(update_data)

			task.spawn(fn, send_update_data, processed_callback)

		end

	end

end

function Profile:Save()
	
	if self.view_mode == true then
		error(`[{script.Name}]: Can't save profile in view mode; Should you be calling :SetAsync() instead?`)
	end
	
	if self:IsActive() == false then
		warn(`[{script.Name}]: Attempted saving an inactive profile (STORE:{self.ProfileStore.Name}; KEY:{self.Key});`
			.. ` Traceback:\n` .. debug.traceback())
		return
	end
	
	-- Move the profile right behind the auto save index to delay the next auto save for it:
	RemoveProfileFromAutoSave(self)
	AddProfileToAutoSave(self)
	
	-- Perform save in new thread:
	task.spawn(SaveProfileAsync, self)

end

-- SCRIBE PATCH: Save(), but yields and reports what happened to THIS call.
--
-- Save() task.spawns the work and returns immediately, so a caller can only
-- watch OnAfterSave and guess which save it belonged to. Guessing is what Scribe
-- used to do, and it granted Robux receipts on saves that were still in flight.
function Profile:SaveAwait(): (string, { [string]: any })

	if self.view_mode == true then
		error(`[{script.Name}]: Can't save profile in view mode; Should you be calling :SetAsync() instead?`)
	end

	if self:IsActive() == false then
		-- No save was started, so there is no context to report from one.
		return "NotOwned", {}
	end

	-- Same auto-save reordering Save() does, so a confirmed save also delays the
	-- next tick rather than being immediately followed by one.
	RemoveProfileFromAutoSave(self)
	AddProfileToAutoSave(self)

	return SaveProfileAsync(self)

end

local ProfileStore: ProfileStoreModule = {

	IsClosing = false,
	IsCriticalState = false,
	-- SCRIBE PATCH: set by an owner that drives shutdown itself (see BindToClose).
	ExternalShutdown = false,
	-- SCRIBE PATCH: injected by whoever adopts this module -- Scribe does it in
	-- Persistence's findProfileStoreModule. Takes a DataStore error message and
	-- answers its class; MessageAsync reads it to decide whether a failed attempt
	-- could have written. nil means "assume every failure might have", which is the
	-- behaviour this file had before the hook existed.
	ClassifyError = nil,
	OnError = OnError, -- (message, store_name, profile_key)
	OnOverwrite = OnOverwrite, -- (store_name, profile_key)
	OnCriticalToggle = Signal.New(), -- (is_critical)
	DataStoreState = "NotReady", -- ("NotReady", "NoInternet", "NoAccess", "Access")

}
ProfileStore.__index = ProfileStore

-- SCRIBE PATCH: shutdown, split so an owner can interleave its own work.
--
-- BeginClose stops new work starting; AwaitClose releases whatever is still held
-- and waits for every outstanding job. Between the two, Scribe runs its leaving
-- hooks and ends its own sessions -- an ordering this file cannot provide on its
-- own, because BindToClose callbacks run concurrently. With everything already
-- released AwaitClose degrades to the job-drain wait, which is the part that
-- keeps the process alive until saves land.
function ProfileStore.BeginClose()
	ProfileStore.IsClosing = true
end

function ProfileStore.AwaitClose()
	-- Cloned because AutoSaveList changes as profiles are released.
	local on_close_save_job_count = 0
	local active_profiles = {}
	for index, profile in ipairs(AutoSaveList) do
		active_profiles[index] = profile
	end

	-- Releasing a profile can trigger listeners that release others, so re-check.
	for _, profile in ipairs(active_profiles) do
		if profile:IsActive() == true then
			on_close_save_job_count = on_close_save_job_count + 1
			task.spawn(function()
				SaveProfileAsync(profile, true, nil, "Shutdown")
				on_close_save_job_count = on_close_save_job_count - 1
			end)
		end
	end

	while on_close_save_job_count > 0 or ActiveProfileLoadJobs > 0 or ActiveProfileSaveJobs > 0 do
		task.wait()
	end
end

-- SCRIBE PATCH: compare-and-set for an OFFLINE profile.
--
-- Writing to an absent player's key means reading it, letting developer code
-- decide what to change, then writing back, and developer code can yield for as
-- long as it likes, so the player can join a server inside that window. A view
-- SetAsync does not merely race for the value: its overwrite path sets
-- session_owns_profile = true unconditionally and clears ActiveSession, so
-- committing over a live session DISOWNS it -- its next save writes nothing, its
-- player is kicked, and everything since its last save is gone.
--
-- So the check and the write are made one UpdateAsync. The mutation still cannot
-- happen in here, because a transform must not yield and developer code does; the
-- caller prepares `new_data` outside and this commits it only if the key still
-- looks the way they read it:
--
--   * still offline, and
--   * unchanged since the read, compared on SessionLoadCount, LastUpdate AND
--     WriteIndex. The first two alone were not enough: LastUpdate has one-second
--     granularity, so two writers off one snapshot whose first commit lands inside
--     that second both passed; and a view-mode SetAsync moves neither of them, so
--     an operator's RestoreVersion was invisible at any timing. WriteIndex moves
--     on every committing write and closes both.
--
-- "Still offline" means ActiveSession == nil, or -- when the caller passes
-- `options.StaleSessionAfter` -- a session whose LastUpdate is older than that,
-- the same rule StartSessionAsync uses to steal a dead session. Opt-in, so the
-- store's default stays conservative for any other consumer.
--
-- Returns "Written" | "SessionActive" | "Changed" | "Missing" | "Failed".
-- Unlike the view path, a decline writes NOTHING: the transform returns nil.
function ProfileStore:UpdateOfflineAsync(profile_key, expected, new_data, options)

	if type(profile_key) ~= "string" or #profile_key == 0 then
		error(`[{script.Name}]: Invalid profile_key`)
	end
	if type(expected) ~= "table" or type(new_data) ~= "table" then
		error(`[{script.Name}]: UpdateOfflineAsync needs an expected snapshot and a data table`)
	end

	local outcome = "Failed"
	local transform_params
	transform_params = {
		ExistingProfileHandle = nil,
		MissingProfileHandle = nil,
		-- Set by EditProfile on every declining path; UpdateAsync's transform
		-- returns nil when it is true, so a refusal commits nothing at all.
		AbortWrite = false,
		EditProfile = function(latest_data)

			if type(latest_data.Data) ~= "table" or type(latest_data.MetaData) ~= "table" then
				outcome = "Missing"
				transform_params.AbortWrite = true
				return
			end

			local active_session = latest_data.MetaData.ActiveSession
			if active_session ~= nil then
				local stale_after = options and options.StaleSessionAfter
				local last_update = latest_data.MetaData.LastUpdate
				-- The same three clauses StartSessionAsync uses at its own steal
				-- (ExistingProfileHandle, further down): no usable LastUpdate means
				-- LIVE, because refusing is the safe direction. Evaluated HERE rather
				-- than on the caller's pre-CAS snapshot, because deciding staleness out
				-- there is exactly the read-then-write race this closes.
				if
					type(stale_after) ~= "number"
					or type(last_update) ~= "number"
					or last_update <= 0
					or os.time() - last_update <= stale_after
				then
					outcome = "SessionActive"
					transform_params.AbortWrite = true
					return
				end
				-- Past the dead-session threshold, so take the lock off the key, the
				-- same disowning StartSessionAsync performs when it steals. Leaving it
				-- set would let the incumbent's next save overwrite this write wholesale,
				-- and Monetization has already answered PurchaseGranted on it.
				latest_data.MetaData.ActiveSession = nil
				latest_data.MetaData.ForceLoadSession = nil
			end

			if
				latest_data.MetaData.SessionLoadCount ~= expected.SessionLoadCount
				or latest_data.MetaData.LastUpdate ~= expected.LastUpdate
				or (latest_data.MetaData.WriteIndex or 0) ~= (expected.WriteIndex or 0)
			then
				outcome = "Changed"
				transform_params.AbortWrite = true
				return
			end

			latest_data.Data = new_data
			-- Stamped for the same reason an owning save stamps it: the next
			-- caller's "unchanged since I read it" check needs this write to be
			-- visible to it.
			latest_data.MetaData.LastUpdate = os.time()
			latest_data.MetaData.WriteIndex = (latest_data.MetaData.WriteIndex or 0) + 1
			outcome = "Written"

		end,
	}

	local loaded_data = UpdateAsync(self, profile_key, transform_params, self._is_user_mock)

	if loaded_data == nil and transform_params.AbortWrite ~= true then
		-- The call itself failed; whatever the transform decided is not authoritative
		-- because it may never have run. Guarded on AbortWrite because a DECLINE also
		-- returns nil, and reporting an ordinary refusal as "Failed" would send routine
		-- contention to Health and degrade the server to Outage.
		return "Failed"
	end

	return outcome

end

function ProfileStore.SetConstant(name, value)

	if type(value) ~= "number" then
		error(`[{script.Name}]: Invalid value type`)
	end

	if name == "AUTO_SAVE_PERIOD" then
		AUTO_SAVE_PERIOD = value
	elseif name == "LOAD_REPEAT_PERIOD" then
		LOAD_REPEAT_PERIOD = value
	elseif name == "FIRST_LOAD_REPEAT" then
		FIRST_LOAD_REPEAT = value
	elseif name == "SESSION_STEAL" then
		SESSION_STEAL = value
	elseif name == "ASSUME_DEAD" then
		ASSUME_DEAD = value
	elseif name == "START_SESSION_TIMEOUT" then
		START_SESSION_TIMEOUT = value
	elseif name == "CRITICAL_STATE_ERROR_COUNT" then
		CRITICAL_STATE_ERROR_COUNT = value
	elseif name == "CRITICAL_STATE_ERROR_EXPIRE" then
		CRITICAL_STATE_ERROR_EXPIRE = value
	elseif name == "CRITICAL_STATE_EXPIRE" then
		CRITICAL_STATE_EXPIRE = value
	elseif name == "MAX_MESSAGE_QUEUE" then
		MAX_MESSAGE_QUEUE = value
	else
		error(`[{script.Name}]: Invalid constant name was provided`)
	end

end

function ProfileStore.Test()
	return {
		ActiveSessionCheck = ActiveSessionCheck,
		AutoSaveList = AutoSaveList,
		ActiveProfileLoadJobs = ActiveProfileLoadJobs,
		ActiveProfileSaveJobs = ActiveProfileSaveJobs,
		MockStore = MockStore,
		UserMockStore = UserMockStore,
		UpdateQueue = UpdateQueue,
	}
end

function ProfileStore.New(store_name, template)

	template = template or {}

	if type(store_name) ~= "string" then
		error(`[{script.Name}]: Invalid or missing "store_name"`)
	elseif string.len(store_name) == 0 then
		error(`[{script.Name}]: store_name cannot be an empty string`)
	elseif string.len(store_name) > 50 then
		error(`[{script.Name}]: store_name is too long`)
	end

	if type(template) ~= "table" then
		error(`[{script.Name}]: Invalid template argument`)
	end

	local self
	self = {

		Mock = {

			Name = store_name,

			StartSessionAsync = function(_, profile_key)
				MockFlag = true
				return self:StartSessionAsync(profile_key)
			end,
			MessageAsync = function(_, profile_key, message)
				MockFlag = true
				return self:MessageAsync(profile_key, message)
			end,
			GetAsync = function(_, profile_key, version)
				MockFlag = true
				return self:GetAsync(profile_key, version)
			end,
			VersionQuery = function(_, profile_key, sort_direction, min_date, max_date)
				MockFlag = true
				return self:VersionQuery(profile_key, sort_direction, min_date, max_date)
			end,
			RemoveAsync = function(_, profile_key)
				MockFlag = true
				return self:RemoveAsync(profile_key)
			end
		},

		Name = store_name,

		template = template,
		data_store = nil,
		load_jobs = {},
		mock_load_jobs = {},
		is_ready = true,

	}
	setmetatable(self, ProfileStore)

	local options = Instance.new("DataStoreOptions")
	options:SetExperimentalFeatures({v2 = true})

	if DataStoreState == "NotReady" then

		-- The module is not sure whether DataStores are accessible yet:

		self.is_ready = false

		task.spawn(function()

			repeat task.wait() until DataStoreState ~= "NotReady"

			if DataStoreState == "Access" then
				self.data_store = DataStoreService:GetDataStore(store_name, nil, options)
			end

			self.is_ready = true

		end)

	elseif DataStoreState == "Access" then

		self.data_store = DataStoreService:GetDataStore(store_name, nil, options)

	end

	return self

end

-- SCRIBE PATCH: how far PAST the six-second boundary a DEFERRED nudge fires. One
-- frame, and the number is not arbitrary: the immediate path's test is `> 6`, so
-- a deferred fire landing exactly ON the boundary would sit on the equality case,
-- where float error rather than the code decides whether the spacing held. A fire
-- landing one ulp early would be a rate increase, and bounding the rate is the
-- only thing this throttle is for.
local NUDGE_FIRE_MARGIN = 1 / 60

-- SCRIBE PATCH: a nudge that arrives inside the throttle window is DEFERRED, not
-- dropped.
--
-- Upstream's `if os.clock() - last_roblox_message > 6 then` had no else branch, so
-- a second message inside six seconds was discarded outright. That looks like a 6x
-- delay and is not one. This nudge is the ONLY thing that gets a cross-server
-- request acted on quickly -- MessageAsync asking the holding server to auto-save
-- sooner, a session steal asking it to release -- so losing one drops the request
-- off the ~1s path onto the next autosave: AUTO_SAVE_PERIOD, 300 seconds by
-- default. Two servers touching the same player within six seconds is ordinary
-- traffic, not an edge case.
--
-- WHAT IS DEFERRED IS THE REQUEST, NEVER THE SPACING. The six seconds protect the
-- DataStore write budget (the numPlayers x 10 figure named below), so the deferred
-- save fires when the window expires and not a moment sooner, and every nudge that
-- arrived during it collapses into that ONE save. The maximum save rate is
-- unchanged; only the losses are gone.
--
-- ENDSESSION WINS THE MERGE. Merging an EndSession down into an ordinary save
-- would leave the lock held and put the stealing server back on the SESSION_STEAL
-- deadline, so the flag is sticky and the coalesced save is a release. The merge
-- the other way loses nothing: a release save writes Data too. Urgency wins the
-- MERGE and not the WINDOW: a release is a DataStore write like any other.
local function RobloxMessageSubscription(profile, unique_session_id)

	local last_roblox_message = 0
	
	-- SCRIBE PATCH: what a nudge inside the window leaves behind. `nudge_timer_armed`
	-- is what makes ten nudges one save rather than ten -- the timer is armed once
	-- per window and every later nudge only folds itself into the flags.
	local pending_end_session = false
	local nudge_timer_armed = false
	
	-- SCRIBE PATCH: the body of the window, extracted so the deferred fire runs the
	-- SAME code the immediate one does instead of a second copy that can drift apart
	-- from it. last_roblox_message is stamped BEFORE the IsActive test, exactly where
	-- upstream stamped it, so an inactive profile still consumes its window.
	local function ServeNudge(end_session)
		last_roblox_message = os.clock()
		if profile:IsActive() == true then
			if end_session == true then
				SaveProfileAsync(profile, true, false, "External")
			else
				profile:Save()
			end
		end
	end
	
	local roblox_message_subscription = MessagingService:SubscribeAsync("PS_" .. unique_session_id, function(message)
		if type(message.Data) == "table" and message.Data.LoadCount == profile.SessionLoadCount then
			-- High reaction rate, based on numPlayers × 10 DataStore budget as of writing
			if os.clock() - last_roblox_message > 6 then 
				ServeNudge(message.Data.EndSession == true)
			else
				-- SCRIBE PATCH: remember it rather than discarding it.
				pending_end_session = pending_end_session or message.Data.EndSession == true
				if nudge_timer_armed == false then
					nudge_timer_armed = true
					task.delay((last_roblox_message + 6 + NUDGE_FIRE_MARGIN) - os.clock(), function()
						nudge_timer_armed = false
						local end_session = pending_end_session
						pending_end_session = false
						-- ServeNudge's profile:IsActive() test is evaluated HERE, at FIRE time,
						-- and routing through it is the point. A session can end between a nudge
						-- arriving and its window expiring, and a save fired on a dead profile is
						-- a write from a session that no longer owns the key. Nothing cancels this
						-- timer -- Disconnect on the subscription cannot reach it -- so that test
						-- is what retires it, and it is why the timer is one-shot: the longest it
						-- can outlive a session is the one window it was already waiting out.
						ServeNudge(end_session)
					end)
				end
			end
		end
	end)

	if profile:IsActive() == true then
		profile.roblox_message_subscription = roblox_message_subscription
	else
		roblox_message_subscription:Disconnect()
	end

end

function ProfileStore:StartSessionAsync(profile_key, params)

	local is_mock = ReadMockFlag()

	if type(profile_key) ~= "string" then
		error(`[{script.Name}]: profile_key must be a string`)
	elseif string.len(profile_key) == 0 then
		error(`[{script.Name}]: Invalid profile_key`)
	elseif string.len(profile_key) > 50 then
		error(`[{script.Name}]: profile_key is too long`)
	end
	
	if params ~= nil and type(params) ~= "table" then
		error(`[{script.Name}]: Invalid params`)
	end
	
	params = params or {}

	if ProfileStore.IsClosing == true then
		return nil
	end
	
	WaitForStoreReady(self)

	local session_token = SessionToken(self.Name, profile_key, is_mock)

	if ActiveSessionCheck[session_token] ~= nil then
		error(`[{script.Name}]: Profile (STORE:{self.Name}; KEY:{profile_key}) is already loaded in this session`)
	end

	ActiveProfileLoadJobs = ActiveProfileLoadJobs + 1
	
	local is_user_cancel = false
	
	local function cancel_condition()
		if is_user_cancel == false then
			if params.Cancel ~= nil then
				is_user_cancel = params.Cancel() == true
			end
			return is_user_cancel
		end
		return true
	end
	
	local user_steal = params.Steal == true

	local force_load_steps = 0 -- Session conflict handling values
	local request_force_load = true
	local steal_session = false

	local start = os.clock()
	local exp_backoff = 1

	while ProfileStore.IsClosing == false and cancel_condition() == false do

		-- Load profile:

		-- SPECIAL CASE - If StartSessionAsync is called for the same key again before another StartSessionAsync finishes,
		-- grab the DataStore return for the new call. The early call will return nil. This is supposed to retain
		-- expected and efficient behavior in cases where a player would quickly rejoin the same server.

		LoadIndex += 1
		local load_id = LoadIndex
		local profile_load_jobs = is_mock == true and self.mock_load_jobs or self.load_jobs
		local profile_load_job = profile_load_jobs[profile_key] -- {load_id, {loaded_data, key_info} or nil}

		local loaded_data, key_info
		local unique_session_id = HttpService:GenerateGUID(false)

		if profile_load_job ~= nil then

			profile_load_job[1] = load_id -- Steal load job
			while profile_load_job[2] == nil do -- Wait for job to finish
				task.wait()
			end
			if profile_load_job[1] == load_id then -- Load job hasn't been double-stolen
				loaded_data, key_info = table.unpack(profile_load_job[2])
				profile_load_jobs[profile_key] = nil
			else
				ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
				return nil
			end

		else

			profile_load_job = {load_id, nil}
			profile_load_jobs[profile_key] = profile_load_job

			profile_load_job[2] = table.pack(UpdateAsync(
				self,
				profile_key,
				{
					ExistingProfileHandle = function(latest_data)

						if ProfileStore.IsClosing == true or cancel_condition() == true then
							return
						end

						local active_session = latest_data.MetaData.ActiveSession
						local force_load_session = latest_data.MetaData.ForceLoadSession

						if active_session == nil then
							latest_data.MetaData.ActiveSession = {PlaceId, JobId, unique_session_id}
							latest_data.MetaData.ForceLoadSession = nil
						elseif type(active_session) == "table" then
							if IsThisSession(active_session) == false then
								local last_update = latest_data.MetaData.LastUpdate
								if last_update ~= nil then
									if os.time() - last_update > ASSUME_DEAD then
										latest_data.MetaData.ActiveSession = {PlaceId, JobId, unique_session_id}
										latest_data.MetaData.ForceLoadSession = nil
										return
									end
								end
								if steal_session == true or user_steal == true then
									local force_load_interrupted = if force_load_session ~= nil then not IsThisSession(force_load_session) else true
									if force_load_interrupted == false or user_steal == true then
										latest_data.MetaData.ActiveSession = {PlaceId, JobId, unique_session_id}
										latest_data.MetaData.ForceLoadSession = nil
									end
								elseif request_force_load == true then
									latest_data.MetaData.ForceLoadSession = {PlaceId, JobId}
								end
							else
								latest_data.MetaData.ForceLoadSession = nil
							end
						end

					end,
					MissingProfileHandle = function(latest_data)
						
						local is_cancel = ProfileStore.IsClosing == true or cancel_condition() == true

						latest_data.Data = DeepCopyTable(self.template)
						latest_data.MetaData = {
							ProfileCreateTime = os.time(),
							SessionLoadCount = 0,
							WriteIndex = 0, -- SCRIBE PATCH: the compare-and-set fingerprint
							ActiveSession = if is_cancel == false then {PlaceId, JobId, unique_session_id} else nil,
							ForceLoadSession = nil,
							MetaTags = {}, -- Backwards compatibility with ProfileService
						}

					end,
					EditProfile = function(latest_data)

						if ProfileStore.IsClosing == true or cancel_condition() == true then
							return
						end

						local active_session = latest_data.MetaData.ActiveSession
						if active_session ~= nil and IsThisSession(active_session) == true then
							latest_data.MetaData.SessionLoadCount = latest_data.MetaData.SessionLoadCount + 1
							latest_data.MetaData.LastUpdate = os.time()
							-- SCRIBE PATCH: see the WriteIndex note in SaveProfileAsync.
							latest_data.MetaData.WriteIndex = (latest_data.MetaData.WriteIndex or 0) + 1
						end

					end,
				},
				is_mock
				))
			if profile_load_job[1] == load_id then -- Load job hasn't been stolen
				loaded_data, key_info = table.unpack(profile_load_job[2])
				profile_load_jobs[profile_key] = nil
			else
				ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
				return nil -- Load job stolen
			end
		end

		-- Handle load_data:

		if loaded_data ~= nil and key_info ~= nil then
			local active_session = loaded_data.MetaData.ActiveSession
			if type(active_session) == "table" then

				if IsThisSession(active_session) == true then

					-- Profile is now taken by this session:

					local profile = Profile.New(loaded_data, key_info, self, profile_key, is_mock, session_token)
					AddProfileToAutoSave(profile)
					
					if is_mock ~= true and DataStoreState == "Access" then
						
						-- Use MessagingService to quickly detect session conflicts and resolve them quickly:
						task.spawn(RobloxMessageSubscription, profile, unique_session_id) -- Blocking prevention
						
					end

					if ProfileStore.IsClosing == true or cancel_condition() == true then
						-- The server has initiated a shutdown by the time this profile was loaded
						SaveProfileAsync(profile, true) -- Release profile and yield until the DataStore call is finished
						profile = nil -- Don't return the profile object
					end

					ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
					return profile

				else
					
					if ProfileStore.IsClosing == true or cancel_condition() == true then
						ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
						return nil
					end

					-- Profile is taken by some other session:

					local force_load_session = loaded_data.MetaData.ForceLoadSession
					local force_load_interrupted = if force_load_session ~= nil then not IsThisSession(force_load_session) else true

					if force_load_interrupted == false then

						if request_force_load == false then
							force_load_steps = force_load_steps + 1
							if force_load_steps >= math.ceil(SESSION_STEAL / LOAD_REPEAT_PERIOD) then
								steal_session = true
							end
						end
						
						-- Request the remote server to end its session:
						if type(active_session[3]) == "string" then
							local session_load_count = loaded_data.MetaData.SessionLoadCount or 0
							task.spawn(MessagingService.PublishAsync, MessagingService, "PS_" .. active_session[3], {LoadCount = session_load_count, EndSession = true})
						end
						
						-- Attempt to load the profile again after a delay
						local wait_until = os.clock() + if request_force_load == true then FIRST_LOAD_REPEAT else LOAD_REPEAT_PERIOD
						repeat task.wait() until os.clock() >= wait_until or ProfileStore.IsClosing == true

					else
						-- Another session tried to load this profile:
						ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
						return nil
					end

					request_force_load = false -- Only request a force load once

				end

			else
				ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
				return nil -- In this scenario it is likely that this server started shutting down
			end
		else
			
			-- A DataStore call has likely ended in an error:

			local default_timeout = false

			if params.Cancel == nil then
				default_timeout = os.clock() - start >= START_SESSION_TIMEOUT
			end
			
			if default_timeout == true or ProfileStore.IsClosing == true or cancel_condition() == true then
				ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
				return nil
			end
			
			task.wait(exp_backoff)  -- Repeat the call shortly
			exp_backoff = math.min(20, exp_backoff * 2)
			
		end

	end

	ActiveProfileLoadJobs = ActiveProfileLoadJobs - 1
	return nil -- Game started shutting down or the request was cancelled - don't return the profile

end

function ProfileStore:MessageAsync(profile_key, message)

	local is_mock = ReadMockFlag()

	if type(profile_key) ~= "string" then
		error(`[{script.Name}]: profile_key must be a string`)
	elseif string.len(profile_key) == 0 then
		error(`[{script.Name}]: Invalid profile_key`)
	elseif string.len(profile_key) > 50 then
		error(`[{script.Name}]: profile_key is too long`)
	end

	if type(message) ~= "table" then
		error(`[{script.Name}]: message must be a table`)
	end

	if ProfileStore.IsClosing == true then
		-- SCRIBE PATCH: PROVABLY CLEAN. This guard sits above WaitForStoreReady and
		-- above the retry loop: zero attempts, nothing written and no way to have
		-- written anything. It used to answer the same bare `false` as the loop's
		-- give-up below, which is the opposite case, and Scribe's gift-credit spend ate
		-- a paid credit here for a delivery it never made.
		return false, nil, true
	end

	WaitForStoreReady(self)

	local exp_backoff = 1

	-- SCRIBE PATCH: `provably_clean`, the third return.
	--
	-- A caller with money on the line needs the one thing this method used to
	-- collapse: COULD ANYTHING HAVE BEEN WRITTEN? Neither of the two old values
	-- answers it. A bare `false` came from the IsClosing guard above, which attempts
	-- nothing, and from the end of the loop below, whose attempts may each have
	-- committed before erroring. `(false, "QueueFull")` describes the attempt that
	-- ANSWERED and says nothing about the attempts before it in the same call. Both
	-- directions were measured wrong in Scribe: a gift credit refunded on a QueueFull
	-- that followed a commit bought a SECOND grant off one payment, and a credit spent
	-- inside a shutdown window was eaten for a send never attempted.
	--
	-- So the third value is a POSITIVE claim: true only where nothing can have been
	-- written. Absent reads as false, and false means "cannot be sure" -- the cheap
	-- direction for an old caller, an old test double, or an exit added later that
	-- forgets the value.
	--
	-- IT IS NOT AN ATTEMPT COUNT, and a count is what made it cost the wrong way: it
	-- asks "was there a previous attempt?" instead of "could a previous attempt have
	-- written?". The loop repeats while UpdateAsync answers nil, and it answers nil for
	-- EVERY failure class, including the two that never reach storage, so one 3xx
	-- throttle in front of an ordinary full inbox ate a buyer's paid gift credit.
	--
	-- What replaces it is the error itself, classified once per failed attempt. Only
	-- "Rejected" (1xx: refused before storage, and refused identically forever) and
	-- "Throttled" (3xx: dropped at the queue, never dispatched) prove an attempt wrote
	-- nothing. "Unresolved" (504) cannot be proven either way, and "Failed" is the safe
	-- default, so an error family Roblox adds tomorrow lands on "cannot be sure".
	local provably_clean = true

	while ProfileStore.IsClosing == false do

		-- Updating profile:

		local transform_params
		transform_params = {
				ExistingProfileHandle = nil,
				MissingProfileHandle = nil,
				AbortWrite = false,
				-- SCRIBE PATCH: set when the queue is already full. See below.
				QueueFull = false,
				EditProfile = function(latest_data)

					local global_updates = latest_data.GlobalUpdates
					local update_list = global_updates[2]
					--{
					--	update_index,
					--	{
					--		{update_index, data}, ...
					--	},
					--},

					-- SCRIBE PATCH: REFUSE at the cap instead of evicting.
					--
					-- This was a `table.insert` followed by a loop dropping the OLDEST entry,
					-- which still returned true. Measured with the cap at 8 and 12 sends: every
					-- call reported success and the recipient received only sequences 5..12.
					-- Scribe's gift delivery treats that true as durable and clears the buyer's
					-- escrow, so a PURCHASED gift was destroyed with nothing recording it
					-- anywhere. Gifts and Data.SendMessage share this channel.
					--
					-- The reason to refuse is that the eviction is SILENT, not that the key is
					-- nearly full: a thousand gift-shaped messages is about 136 KB, 3.4% of the
					-- 4 MB key. No trim loop for a key inherited OVER the cap from an older
					-- build either, for the same reason -- it stays over cap, refusing sends,
					-- until its acks sweep it, which is visible and recoverable.
					if #update_list >= MAX_MESSAGE_QUEUE then
						transform_params.QueueFull = true
						transform_params.AbortWrite = true
						return
					end

					global_updates[1] += 1
					table.insert(update_list, {global_updates[1], message})

				end,
		}

		-- SCRIBE PATCH: transform_params is rebuilt on every pass, so `QueueFull` and
		-- `ErrorMessage` below are always THIS attempt's answer and never a stale one.
		--
		-- A RAISE OUT OF UpdateAsync IS NOT AN EXIT OF THIS FUNCTION, it is an exit of
		-- the CALL, and it carries no third value at all. UpdateAsync pcalls the
		-- DataStore itself, so what can still raise through here is the per-key update
		-- queue and any OnError handler inside RegisterError, either of which can fire
		-- after an attempt that may have committed. The caller's pcall reads absent as
		-- false and treats the call as ambiguous, which is both correct and cheap.
		local loaded_data = UpdateAsync(self, profile_key, transform_params, is_mock)

		if transform_params.QueueFull == true then
			-- Nothing was written BY THE ATTEMPT THAT ANSWERED: the transform ran, saw
			-- the cap, set AbortWrite and returned nil, so the UpdateAsync it sat inside
			-- committed nothing at all. The reason keeps existing callers source-compatible
			-- while letting one that cares tell a full inbox from a DataStore fault.
			--
			-- `provably_clean` turns that into a statement about the CALL, and it is carried
			-- in from the attempts BEFORE this one: a QueueFull on a later pass can be a
			-- refusal reported for a message an earlier pass of this same call already
			-- queued, and the caller must not read that as clean; but a QueueFull behind
			-- nothing but rejections and throttles still IS clean.
			return false, "QueueFull", provably_clean
		end

		if loaded_data ~= nil then
			
			local session_token = SessionToken(self.Name, profile_key, is_mock)
			
			local profile = ActiveSessionCheck[session_token]
			
			if profile ~= nil then
				
				-- The message was sent to a profile that is active in this server:
				profile:Save()
				
			else
				
				local meta_data = loaded_data.MetaData or {}
				local active_session = meta_data.ActiveSession
				local session_load_count = meta_data.SessionLoadCount or 0
				
				if type(active_session) == "table" and type(active_session[3]) == "string" then
					-- Request the remote server to auto-save sooner and receive the message:
					task.spawn(MessagingService.PublishAsync, MessagingService, "PS_" .. active_session[3], {LoadCount = session_load_count})
				end
				
			end

			return true

		else

			-- SCRIBE PATCH: classify the attempt that just failed, before backing off.
			-- `Rejected` and `Throttled` provably never reached storage, so an attempt in
			-- either leaves the call as clean as it found it. Everything else settles the
			-- claim to false for the rest of the call, with no way back: once one attempt
			-- might have written, no later attempt can unprove it. No classifier installed
			-- means no class, and no class means no proof.
			local classify = ProfileStore.ClassifyError
			local class = if classify ~= nil then classify(transform_params.ErrorMessage) else nil
			if class ~= "Rejected" and class ~= "Throttled" then
				provably_clean = false
			end

			task.wait(exp_backoff) -- A DataStore call has likely ended in an error - repeat the call shortly
			exp_backoff = math.min(20, exp_backoff * 2)

		end

	end

	-- SCRIBE PATCH: the give-up exit. Ambiguous whenever any attempt could have
	-- written, and clean otherwise -- which covers two cases and not one: IsClosing
	-- can flip while WaitForStoreReady yields, so the loop body never ran at all; and
	-- a loop that ran only into rejections and throttles never reached storage either,
	-- on a key that may not even exist.
	return false, nil, provably_clean

end

function ProfileStore:GetAsync(profile_key, version)

	local is_mock = ReadMockFlag()

	if type(profile_key) ~= "string" then
		error(`[{script.Name}]: profile_key must be a string`)
	elseif string.len(profile_key) == 0 then
		error(`[{script.Name}]: Invalid profile_key`)
	elseif string.len(profile_key) > 50 then
		error(`[{script.Name}]: profile_key is too long`)
	end

	if ProfileStore.IsClosing == true then
		return nil
	end

	WaitForStoreReady(self)

	if version ~= nil and (is_mock or DataStoreState ~= "Access") then
		return nil -- No version support in mock mode
	end

	local exp_backoff = 1

	while ProfileStore.IsClosing == false do

		-- Load profile:

		local loaded_data, key_info = UpdateAsync(
			self,
			profile_key,
			{
				ExistingProfileHandle = nil,
				MissingProfileHandle = function(latest_data)

					latest_data.Data = DeepCopyTable(self.template)
					latest_data.MetaData = {
						ProfileCreateTime = os.time(),
						SessionLoadCount = 0,
						WriteIndex = 0, -- SCRIBE PATCH: the compare-and-set fingerprint
						ActiveSession = nil,
						ForceLoadSession = nil,
						MetaTags = {}, -- Backwards compatibility with ProfileService
					}

				end,
				EditProfile = nil,
			},
			is_mock,
			true, -- Use :GetAsync()
			version -- DataStore key version
		)

		-- Handle load_data:

		if loaded_data ~= nil then

			if key_info == nil then
				return nil -- Load was successful, but the key was empty - return no profile object
			end

			local profile = Profile.New(loaded_data, key_info, self, profile_key, is_mock)
			profile.view_mode = true

			return profile

		else

			task.wait(exp_backoff) -- A DataStore call has likely ended in an error - repeat the call shortly
			exp_backoff = math.min(20, exp_backoff * 2)

		end

	end

	return nil -- Game started shutting down - don't return the profile

end

function ProfileStore:RemoveAsync(profile_key)

	local is_mock = ReadMockFlag()

	if type(profile_key) ~= "string" or string.len(profile_key) == 0 then
		error(`[{script.Name}]: Invalid profile_key`)
	end

	if ProfileStore.IsClosing == true then
		return false
	end

	WaitForStoreReady(self)

	local wipe_status = false
	
	local next_in_queue = WaitInUpdateQueue(SessionToken(self.Name, profile_key, is_mock))

	if is_mock == true then -- Used when the profile is accessed through ProfileStore.Mock

		local mock_data_store = UserMockStore[self.Name]

		if mock_data_store ~= nil then
			mock_data_store[profile_key] = nil
			if next(mock_data_store) == nil then
				UserMockStore[self.Name] = nil
			end
		end

		wipe_status = true
		task.wait() -- Simulate API call yield

	elseif DataStoreState ~= "Access" then -- Used when API access is disabled

		local mock_data_store = MockStore[self.Name]

		if mock_data_store ~= nil then
			mock_data_store[profile_key] = nil
			if next(mock_data_store) == nil then
				MockStore[self.Name] = nil
			end
		end

		wipe_status = true
		task.wait() -- Simulate API call yield

	else -- Live DataStore

		wipe_status = pcall(function()
			self.data_store:RemoveAsync(profile_key)
		end)

	end
	
	next_in_queue()

	return wipe_status

end

local ProfileVersionQuery = {}
ProfileVersionQuery.__index = ProfileVersionQuery

function ProfileVersionQuery.New(profile_store, profile_key, sort_direction, min_date, max_date, is_mock)

	local self = {
		profile_store = profile_store,
		profile_key = profile_key,
		sort_direction = sort_direction,
		min_date = min_date,
		max_date = max_date,

		query_pages = nil,
		query_index = 0,
		query_failure = false,

		is_query_yielded = false,
		query_queue = {},

		is_mock = is_mock,
	}
	setmetatable(self, ProfileVersionQuery)

	return self

end

function MoveVersionQueryQueue(self) -- Hidden ProfileVersionQuery method
	while #self.query_queue > 0 do

		local queue_entry = table.remove(self.query_queue, 1)

		task.spawn(queue_entry)

		if self.is_query_yielded == true then
			break
		end

	end
end

local VersionQueryNextAsyncStackingFlag = false
local WarnAboutVersionQueryOnce = false

function ProfileVersionQuery:NextAsync()

	local is_stacking = VersionQueryNextAsyncStackingFlag == true
	VersionQueryNextAsyncStackingFlag = false

	WaitForStoreReady(self.profile_store)

	if ProfileStore.IsClosing == true then
		return nil -- Silently fail :NextAsync() requests
	end

	if self.is_mock == true or DataStoreState ~= "Access" then
		if IsStudio == true and WarnAboutVersionQueryOnce == false then
			WarnAboutVersionQueryOnce = true
			warn(`[{script.Name}]: :VersionQuery() is not supported in mock mode!`)
		end
		return nil -- Silently fail :NextAsync() requests
	end

	local profile
	local is_finished = false

	local function query_job()

		if self.query_failure == true then
			is_finished = true
			return
		end

		-- First "next" call loads version pages:

		if self.query_pages == nil then

			self.is_query_yielded = true

			task.spawn(function()
				VersionQueryNextAsyncStackingFlag = true
				profile = self:NextAsync()
				is_finished = true
			end)

			local list_success, error_message = pcall(function()
				self.query_pages = self.profile_store.data_store:ListVersionsAsync(
					self.profile_key,
					self.sort_direction,
					self.min_date,
					self.max_date
				)
				self.query_index = 0
			end)

			if list_success == false or self.query_pages == nil then
				warn(`[{script.Name}]: Version query fail - {tostring(error_message)}`)
				self.query_failure = true
			end

			self.is_query_yielded = false

			MoveVersionQueryQueue(self)

			return

		end

		local current_page = self.query_pages:GetCurrentPage()
		local next_item = current_page[self.query_index + 1]

		-- No more entries:

		if self.query_pages.IsFinished == true and next_item == nil then
			is_finished = true
			return
		end

		-- Load next page when this page is over:

		if next_item == nil then

			self.is_query_yielded = true
			task.spawn(function()
				VersionQueryNextAsyncStackingFlag = true
				profile = self:NextAsync()
				is_finished = true
			end)

			local success, error_message = pcall(function()
				self.query_pages:AdvanceToNextPageAsync()
				self.query_index = 0
			end)

			if success == false or #self.query_pages:GetCurrentPage() == 0 then
				self.query_failure = true
			end

			self.is_query_yielded = false
			MoveVersionQueryQueue(self)

			return

		end

		-- Next page item:

		self.query_index += 1
		profile = self.profile_store:GetAsync(self.profile_key, next_item.Version)
		is_finished = true

	end

	if self.is_query_yielded == false then
		query_job()
	else
		if is_stacking == true then
			table.insert(self.query_queue, 1, query_job)
		else
			table.insert(self.query_queue, query_job)
		end
	end

	while is_finished == false do
		task.wait()
	end

	return profile

end

function ProfileStore:VersionQuery(profile_key, sort_direction, min_date, max_date)

	local is_mock = ReadMockFlag()

	if type(profile_key) ~= "string" or string.len(profile_key) == 0 then
		error(`[{script.Name}]: Invalid profile_key`)
	end

	-- Type check:

	if sort_direction ~= nil and (typeof(sort_direction) ~= "EnumItem"
		or sort_direction.EnumType ~= Enum.SortDirection) then
		error(`[{script.Name}]: Invalid sort_direction ({tostring(sort_direction)})`)
	end

	if min_date ~= nil and typeof(min_date) ~= "DateTime" and typeof(min_date) ~= "number" then
		error(`[{script.Name}]: Invalid min_date ({tostring(min_date)})`)
	end

	if max_date ~= nil and typeof(max_date) ~= "DateTime" and typeof(max_date) ~= "number" then
		error(`[{script.Name}]: Invalid max_date ({tostring(max_date)})`)
	end

	min_date = typeof(min_date) == "DateTime" and min_date.UnixTimestampMillis or min_date
	max_date = typeof(max_date) == "DateTime" and max_date.UnixTimestampMillis or max_date

	return ProfileVersionQuery.New(self, profile_key, sort_direction, min_date, max_date, is_mock)

end

-- DataStore API access check:

if IsStudio == true then

	task.spawn(function()

		local new_state = "NoAccess"

		local status, message = pcall(function()
			-- This will error if current instance has no Studio API access:
			DataStoreService:GetDataStore("____PS"):SetAsync("____PS", os.time())
		end)

		local no_internet_access = status == false and string.find(message, "ConnectFail", 1, true) ~= nil

		if no_internet_access == true then
			warn(`[{script.Name}]: No internet access - check your network connection`)
		end

		if status == false and
			(string.find(message, "403", 1, true) ~= nil or -- Cannot write to DataStore from studio if API access is not enabled
				string.find(message, "must publish", 1, true) ~= nil or -- Game must be published to access live keys
				no_internet_access == true) then -- No internet access

			new_state = if no_internet_access == true then "NoInternet" else "NoAccess"
			print(`[{script.Name}]: Roblox API services unavailable - data will not be saved`)
		else
			new_state = "Access"
			print(`[{script.Name}]: Roblox API services available - data will be saved`)
		end

		DataStoreState = new_state
		ProfileStore.DataStoreState = new_state

	end)

else
	
	DataStoreState = "Access"
	ProfileStore.DataStoreState = "Access"
	
end

-- Update loop:

RunService.Heartbeat:Connect(function()

	-- Auto saving:

	local auto_save_list_length = #AutoSaveList
	if auto_save_list_length > 0 then
		local auto_save_index_speed = AUTO_SAVE_PERIOD / auto_save_list_length
		local os_clock = os.clock()
		while os_clock - LastAutoSave > auto_save_index_speed do
			LastAutoSave = LastAutoSave + auto_save_index_speed
			local profile = AutoSaveList[AutoSaveIndex]
			if os_clock - profile.load_timestamp < AUTO_SAVE_PERIOD / 2 then
				-- This profile is freshly loaded - auto saving immediately is not necessary:
				profile = nil
				for _ = 1, auto_save_list_length - 1 do
					-- Move auto save index to the right:
					AutoSaveIndex = AutoSaveIndex + 1
					if AutoSaveIndex > auto_save_list_length then
						AutoSaveIndex = 1
					end
					profile = AutoSaveList[AutoSaveIndex]
					if os_clock - profile.load_timestamp >= AUTO_SAVE_PERIOD / 2 then
						break
					else
						profile = nil
					end
				end
			end
			-- Move auto save index to the right:
			AutoSaveIndex = AutoSaveIndex + 1
			if AutoSaveIndex > auto_save_list_length then
				AutoSaveIndex = 1
			end
			-- Perform save call:
			if profile ~= nil then
				task.spawn(SaveProfileAsync, profile) -- Auto save profile in new thread
			end
		end
	end

	-- Critical state handling:

	if ProfileStore.IsCriticalState == false then
		if #IssueQueue >= CRITICAL_STATE_ERROR_COUNT then
			ProfileStore.IsCriticalState = true
			ProfileStore.OnCriticalToggle:Fire(true)
			CriticalStateStart = os.clock()
			warn(`[{script.Name}]: Entered critical state`)
		end
	else
		if #IssueQueue >= CRITICAL_STATE_ERROR_COUNT then
			CriticalStateStart = os.clock()
		elseif os.clock() - CriticalStateStart > CRITICAL_STATE_EXPIRE then
			ProfileStore.IsCriticalState = false
			ProfileStore.OnCriticalToggle:Fire(false)
			warn(`[{script.Name}]: Critical state ended`)
		end
	end

	-- Issue queue:

	while true do
		local issue_time = IssueQueue[1]
		if issue_time == nil then
			break
		elseif os.clock() - issue_time > CRITICAL_STATE_ERROR_EXPIRE then
			table.remove(IssueQueue, 1)
		else
			break
		end
	end

end)

-- Release all loaded profiles when the server is shutting down:

task.spawn(function()

	while DataStoreState == "NotReady" do
		task.wait()
	end

	if DataStoreState ~= "Access" then

		game:BindToClose(function()
			-- SCRIBE PATCH: same opt-out as the live handler below.
			if ProfileStore.ExternalShutdown == true then
				return
			end
			ProfileStore.IsClosing = true
			task.wait() -- Mock shutdown delay
		end)

		return -- Don't wait for profiles to properly save in mock mode so studio could end the simulation faster

	end

	game:BindToClose(function()

		-- SCRIBE PATCH: stand down when the owner drives shutdown itself.
		--
		-- Roblox runs every bound callback CONCURRENTLY and documents no order, and
		-- both this and Scribe's drain want the same instant. This one releases every
		-- profile immediately -- RemoveProfileFromAutoSave runs synchronously inside
		-- SaveProfileAsync, before any DataStore call -- while Scribe's drain first
		-- collects the sessions whose profile is still IsActive() so it can run each
		-- player's leaving hook. Whoever is invoked first wins outright, because
		-- neither yields before it has taken what it needs.
		--
		-- Measured: with this handler first, ZERO leaving hooks run -- the drain's list
		-- comes back empty, so it skips nothing and reports nothing. It only works today
		-- because this registration waits behind `while DataStoreState == "NotReady"` (a
		-- DataStore round trip) while Scribe's happens during construction; a game that
		-- builds Scribe lazily gets the other order.
		--
		-- So the owner takes it over instead of racing it: BeginClose(), then AwaitClose()
		-- once its hooks have run and its sessions are ended.
		if ProfileStore.ExternalShutdown == true then
			return
		end

		ProfileStore.BeginClose()
		ProfileStore.AwaitClose()

	end)

end)

return ProfileStore