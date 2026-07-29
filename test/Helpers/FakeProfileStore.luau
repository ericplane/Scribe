--!strict
-- Deterministic ProfileStore stand-in for the test harness. Implements the
-- exact surface Scribe uses (verified against lm-loleris/profilestore 1.0.3):
-- New/Mock/StartSessionAsync/GetAsync/MessageAsync/RemoveAsync/VersionQuery,
-- profile Data/LastSavedData/OnSave/OnAfterSave/OnSessionEnd/IsActive/
-- Reconcile/EndSession/AddUserId/MessageHandler/Save/SetAsync/Key/KeyInfo.
--
-- Unlike the real module (and its .Mock), saves are synchronous and only
-- happen when requested, so tests are deterministic. Failure injection:
--   fake.FailNextLoad / fake.FailSaves / fake.FailMessages
-- Crucially, Save() reads profile.Data AFTER firing OnSave — the same ordering
-- the real module uses — which is what the wipe guard's pointer swap relies on.

local ScribeRoot = script.Parent.Parent.Parent.Scribe
local Signal = require(ScribeRoot.Internal.Signal)
local Util = require(ScribeRoot.Internal.Util)

local FakeProfileStore = {}

type AnyTable = { [string]: any }

local function reconcileInto(target: AnyTable, template: AnyTable)
	for key, value in template do
		if type(key) == "string" then
			if target[key] == nil then
				target[key] = Util.deepClone(value)
			elseif type(target[key]) == "table" and type(value) == "table" then
				reconcileInto(target[key], value)
			end
		end
	end
end

--- Creates a fake ProfileStore *module* (inject via options.ProfileStore).
function FakeProfileStore.new()
	local fake = {} :: any

	fake.OnError = Signal.new() -- (message, storeName, profileKey)
	fake.OnOverwrite = Signal.new()
	fake.OnCriticalToggle = Signal.new()
	fake.IsCriticalState = false
	fake.DataStoreState = "Access"

	fake.FailNextLoad = false
	fake.FailSaves = false
	fake.FailMessages = false

	-- Persisted state shared by every store the module creates, keyed
	-- "<storeName>/<profileKey>".
	fake.Persisted = {} :: { [string]: AnyTable }
	-- UserIds as the datastore would hold them, plus an opt-in for "persisted but
	-- never actually saved" (a first session that crashed before its first save).
	fake.PersistedUserIds = {} :: { [string]: { number } }
	fake.NeverSaved = {} :: { [string]: boolean }
	fake.Versions = {} :: { [string]: { { VersionId: string, Data: AnyTable, CreatedTime: number } } }
	fake.Mailboxes = {} :: { [string]: { any } }
	fake.ActiveProfiles = {} :: { [string]: any }
	fake.SaveCounts = {} :: { [string]: number }
	fake.Constants = {} :: { [string]: number } -- records ProfileStore.SetConstant calls

	function fake.SetConstant(name: string, value: number)
		fake.Constants[name] = value
	end

	function fake.New(storeName: string, template: AnyTable?)
		local store = {} :: any
		store.Name = storeName
		store.Mock = store -- UseMock/DontSave switch to .Mock; same fake store

		local function fullKey(profileKey: string): string
			return `{storeName}/{profileKey}`
		end

		local function recordVersion(profileKey: string, data: AnyTable)
			local key = fullKey(profileKey)
			local list = fake.Versions[key]
			if not list then
				list = {}
				fake.Versions[key] = list
			end
			table.insert(list, 1, {
				VersionId = Util.guid(),
				Data = Util.deepClone(data),
				CreatedTime = os.time() * 1000,
			})
			if #list > 8 then
				table.remove(list)
			end
		end

		local function newProfile(profileKey: string)
			local key = fullKey(profileKey)
			local persisted = fake.Persisted[key]
			local profile = {} :: any
			profile.Key = profileKey
			profile.ProfileStore = store
			profile.Data = if persisted then Util.deepClone(persisted) else Util.deepClone(template or {})
			profile.LastSavedData = Util.deepClone(profile.Data)
			profile.FirstSessionTime = os.time()
			-- Mirror ProfileStore: a brand-new key's first session is 1; a returning
			-- (already-persisted) profile is >1.
			profile.SessionLoadCount = if persisted then 2 else 1
			profile.RobloxMetaData = {}
			-- Mirror ProfileStore: UserIds reaches the datastore only as part of a
			-- COMPLETED save, and neither key-minting path seeds it. Scribe uses a
			-- non-empty list to prove a prior save happened, so a hand-seeded
			-- fake.Persisted entry must look like "a returning player who saved" or
			-- roughly thirty existing specs would silently reclassify. Opt into the
			-- crashed-first-session shape with fake.NeverSaved[key] = true.
			profile.UserIds = if fake.PersistedUserIds[key]
				then Util.deepClone(fake.PersistedUserIds[key])
				elseif persisted and not fake.NeverSaved[key] then { 1 }
				else {}
			profile.KeyInfo = { Version = "live", CreatedTime = os.time() * 1000 }
			profile.OnSave = Signal.new()
			profile.OnLastSave = Signal.new()
			profile.OnSessionEnd = Signal.new()
			profile.OnAfterSave = Signal.new()

			local active = true
			local messageHandlers: { (message: any, processed: () -> ()) -> () } = {}

			function profile.IsActive(_self: any): boolean
				return active
			end

			function profile.Reconcile(_self: any)
				reconcileInto(profile.Data, template or {})
			end

			function profile.AddUserId(_self: any, userId: number)
				if not table.find(profile.UserIds, userId) then
					table.insert(profile.UserIds, userId)
				end
			end

			function profile.RemoveUserId(_self: any, userId: number)
				local index = table.find(profile.UserIds, userId)
				if index then
					table.remove(profile.UserIds, index)
				end
			end

			-- Synchronous save. Ordering matches the real module: OnSave fires
			-- first, then profile.Data is read for serialization.
			-- Deliver any queued cross-server messages. Real ProfileStore keeps an
			-- acked update in the file with a Locked flag and only sweeps it on a LATER
			-- save, so delivery is at-least-once; an unacked message is redelivered.
			local function drainMailbox()
				local mailbox = fake.Mailboxes[key]
				if not mailbox or #mailbox == 0 then
					return
				end
				local remaining = {}
				for _, message in mailbox do
					local consumed = false
					for _, handler in messageHandlers do
						handler(Util.deepClone(message), function()
							consumed = true
						end)
						if consumed then
							break
						end
					end
					if not consumed then
						table.insert(remaining, message)
					end
				end
				fake.Mailboxes[key] = if #remaining > 0 then remaining else nil
			end

			-- The write itself, without the surrounding signal order, so EndSession can
			-- run it at the point the real library does.
			local function persist()
				if fake.FailSaves then
					fake.OnError:Fire("mock save failure", storeName, profileKey)
					return
				end
				local snapshot = Util.deepClone(profile.Data)
				fake.Persisted[key] = snapshot
				-- A completed save is what puts UserIds in the datastore.
				fake.PersistedUserIds[key] = Util.deepClone(profile.UserIds)
				fake.SaveCounts[key] = (fake.SaveCounts[key] or 0) + 1
				recordVersion(profileKey, snapshot)
				profile.LastSavedData = snapshot
				-- Real delivery runs inside the save (ProfileStore.luau:885-908), so a
				-- handler observes a save already in flight.
				drainMailbox()
				profile.OnAfterSave:Fire(profile.LastSavedData)
			end

			function profile.Save(_self: any)
				if not active then
					return
				end
				profile.OnSave:Fire()
				persist()
			end

			function profile.EndSession(_self: any)
				if not active then
					return
				end
				-- Real order (ProfileStore.luau:715-741, :924): OnSave, OnLastSave, the
				-- session is dropped so IsActive() is already FALSE, OnSessionEnd, and
				-- only THEN the write, with OnAfterSave last. The fake used to save
				-- first and tear down after, so every save-completion handler ran
				-- against a live entry that in production is already torn down.
				profile.OnSave:Fire()
				profile.OnLastSave:Fire("Manual")
				active = false
				fake.ActiveProfiles[key] = nil
				profile.OnSessionEnd:Fire()
				persist()
			end

			local function deliver(message: any): boolean
				for _, handler in messageHandlers do
					local consumed = false
					handler(message, function()
						consumed = true
					end)
					if consumed then
						return true
					end
				end
				return false
			end

			function profile.MessageHandler(_self: any, handler: (message: any, processed: () -> ()) -> ())
				table.insert(messageHandlers, handler)
				local mailbox = fake.Mailboxes[key]
				if mailbox then
					local remaining = {}
					for _, message in mailbox do
						if not deliver(message) then
							table.insert(remaining, message)
						end
					end
					fake.Mailboxes[key] = if #remaining > 0 then remaining else nil
				end
			end

			profile._deliver = deliver
			return profile
		end

		function store.StartSessionAsync(_self: any, profileKey: string, params: any?)
			if fake.FailNextLoad then
				fake.FailNextLoad = false
				fake.OnError:Fire("mock load failure", storeName, profileKey)
				return nil
			end
			if params and type(params.Cancel) == "function" and params.Cancel() then
				return nil
			end
			local key = fullKey(profileKey)
			if fake.ActiveProfiles[key] then
				return nil -- session locked
			end
			local profile = newProfile(profileKey)
			fake.ActiveProfiles[key] = profile
			return profile
		end

		function store.GetAsync(_self: any, profileKey: string, version: string?)
			local key = fullKey(profileKey)
			local data: AnyTable? = nil
			local keyInfo = { Version = version or "live", CreatedTime = os.time() * 1000 }
			if version then
				for _, record in fake.Versions[key] or {} do
					if record.VersionId == version then
						data = Util.deepClone(record.Data)
						keyInfo.CreatedTime = record.CreatedTime
						break
					end
				end
			else
				local persisted = fake.Persisted[key]
				data = if persisted then Util.deepClone(persisted) else nil
			end
			if data == nil then
				return nil
			end

			-- Real ProfileStore builds a view with Profile.New(...) then sets
			-- view_mode = true, so a view carries every signal and method a session
			-- profile does; only saving differs (SetAsync instead of Save, and
			-- IsActive() is false so no save path fires). Build it the same way, or
			-- a view-mode load (Mode = "NoSave", legacy ViewedUserId) hits a missing
			-- member the moment it reaches finishLoad.
			local view = newProfile(profileKey)
			view.Data = data
			view.KeyInfo = keyInfo
			-- Real GetAsync reports the RAW stored count: it passes EditProfile = nil,
			-- so the session-start increment never runs. newProfile models a LIVE load
			-- (2 for stored data), which is one too high for a view and hides the
			-- new-vs-returning divergence entirely.
			view.SessionLoadCount = if fake.Persisted[key] then 1 else 0
			view.view_mode = true
			view.Session = if fake.ActiveProfiles[key] then { PlaceId = 0, JobId = "mock" } else nil
			function view.IsActive(_self: any): boolean
				return false
			end
			function view.Save(_self: any)
				error("Can't save profile in view mode; Should you be calling :SetAsync() instead?")
			end
			function view.EndSession(_self: any) end
			function view.SetAsync(_view: any)
				-- Real SetAsync returns NOTHING and cannot throw for an infrastructure
				-- failure: the DataStore fault is swallowed by ProfileStore's own pcall,
				-- routed to RegisterError (which fires OnError), and the call returns
				-- normally having written nothing. Throwing here let every offline-write
				-- spec take a branch production can never reach, hiding the fact that
				-- Scribe reported those unwritten saves as successful commits.
				if fake.FailSaves then
					fake.OnError:Fire("mock save failure", storeName, profileKey)
					return
				end
				fake.Persisted[key] = Util.deepClone(view.Data)
				fake.PersistedUserIds[key] = Util.deepClone(view.UserIds)
				recordVersion(profileKey, view.Data)
			end
			return view
		end

		function store.MessageAsync(_self: any, profileKey: string, message: any): boolean
			if fake.FailMessages then
				return false
			end
			-- Real MessageAsync only COMMITS the message to GlobalUpdates; it never
			-- delivers (ProfileStore.luau:1633-1730). Delivery happens later, inside a
			-- save, or at MessageHandler registration. Delivering inline here meant a
			-- cross-server gift never arrived while a save was in flight, which is the
			-- exact condition the SaveGen waiter gate exists to handle.
			local key = fullKey(profileKey)
			local mailbox = fake.Mailboxes[key]
			if not mailbox then
				mailbox = {}
				fake.Mailboxes[key] = mailbox
			end
			table.insert(mailbox, Util.deepClone(message))
			return true
		end

		function store.RemoveAsync(_self: any, profileKey: string): boolean
			local key = fullKey(profileKey)
			fake.Persisted[key] = nil
			fake.PersistedUserIds[key] = nil
			fake.Versions[key] = nil
			fake.Mailboxes[key] = nil
			return true
		end

		function store.VersionQuery(_self: any, profileKey: string, _sortDirection: any?)
			local key = fullKey(profileKey)
			local list = fake.Versions[key] or {}
			local index = 0
			return {
				NextAsync = function()
					index += 1
					local record = list[index]
					if not record then
						return nil
					end
					return {
						Data = Util.deepClone(record.Data),
						KeyInfo = { Version = record.VersionId, CreatedTime = record.CreatedTime },
					}
				end,
			}
		end

		return store
	end

	return fake
end

return FakeProfileStore
