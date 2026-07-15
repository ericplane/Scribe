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
			profile.SessionLoadCount = 1
			profile.RobloxMetaData = {}
			profile.UserIds = {}
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
			function profile.Save(_self: any)
				if not active then
					return
				end
				profile.OnSave:Fire()
				if fake.FailSaves then
					fake.OnError:Fire("mock save failure", storeName, profileKey)
					return
				end
				local snapshot = Util.deepClone(profile.Data)
				fake.Persisted[key] = snapshot
				fake.SaveCounts[key] = (fake.SaveCounts[key] or 0) + 1
				recordVersion(profileKey, snapshot)
				profile.LastSavedData = snapshot
				profile.OnAfterSave:Fire(profile.LastSavedData)
			end

			function profile.EndSession(_self: any)
				if not active then
					return
				end
				profile.OnLastSave:Fire("Manual")
				profile:Save()
				active = false
				fake.ActiveProfiles[key] = nil
				profile.OnSessionEnd:Fire()
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

			local view = {} :: any
			view.Key = profileKey
			view.Data = data
			view.KeyInfo = keyInfo
			view.Session = if fake.ActiveProfiles[key] then { PlaceId = 0, JobId = "mock" } else nil
			function view.SetAsync(_view: any)
				if fake.FailSaves then
					error("mock save failure")
				end
				fake.Persisted[key] = Util.deepClone(view.Data)
				recordVersion(profileKey, view.Data)
				fake.OnOverwrite:Fire(storeName, profileKey)
			end
			return view
		end

		function store.MessageAsync(_self: any, profileKey: string, message: any): boolean
			if fake.FailMessages then
				return false
			end
			local key = fullKey(profileKey)
			local active = fake.ActiveProfiles[key]
			if active and active._deliver(Util.deepClone(message)) then
				return true
			end
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
