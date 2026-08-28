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
-- Crucially, Save() reads profile.Data AFTER firing OnSave, the same ordering
-- the real module uses, which is what the wipe guard's pointer swap relies on.

local ScribeRoot = script.Parent.Parent.Parent.Scribe
local Signal = require(ScribeRoot.Internal.Signal)
local Util = require(ScribeRoot.Internal.Util)

-- Mirrors the fork's shared sentinel: an owner that has opted out of retention
-- sees an empty table here, never stale data.
local RELEASED_LAST_SAVED = table.freeze({})

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
	-- Opt-in yield inside StartSessionAsync. Real ProfileStore's StartSessionAsync
	-- yields (WaitForStoreReady, then UpdateAsync), so a game's own PlayerAdded
	-- handler genuinely parks in Data.WaitForData while the load runs. The fake is
	-- synchronous by default, which makes that window zero-width and hides every
	-- ordering bug in it, so a spec that cares can widen it.
	fake.YieldOnSessionStart = false
	-- Called between profile.OnSave:Fire() and the write, which is where real
	-- ProfileStore spends its DataStore round trip: it fires OnSave, then reads
	-- profile.Data BY REFERENCE inside the UpdateAsync transform once the fetch
	-- returns. Nothing in the suite can reach a mid-save window without this.
	fake.MidSave = nil :: (() -> ())?
	fake.FailSaves = false
	fake.FailMessages = false
	-- Make a view read raise, the way a real GetAsync does under an outage. Needed
	-- because "the lock could not be confirmed" is a distinct outcome from "the
	-- lock is free", and the fail-closed paths that depend on the difference are
	-- otherwise unreachable from a spec.
	fake.FailReads = false
	-- Called inside a VERSION read, which is where RestoreVersion spends a round
	-- trip between checking the session lock and committing the restore. The fake
	-- is synchronous end to end, so without a hook here that window is zero-width
	-- and the re-check guarding it is unreachable from a spec.
	fake.MidVersionRead = nil :: (() -> ())?
	-- Fired at the LAST INSTANT before an offline commit lands, on BOTH commit
	-- paths -- the view-mode SetAsync and the compare-and-set. One seam for both,
	-- deliberately: a spec asserting "a session that lands in this window is not
	-- disowned" has to keep asserting the same thing when the call site moves from
	-- one primitive to the other, or the fix silently stops being tested.
	fake.MidOfflineCommit = nil :: (() -> ())?
	-- Fired on ENTRY to a live GetAsync, before it reads. The offline receipt path
	-- reads TWICE -- once to decide (GetOffline) and once inside the commit -- and
	-- the interesting orderings are the ones where something lands between them.
	fake.MidRead = nil :: ((profileKey: string) -> ())?

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
	-- The CAS fingerprint the vendored fork keeps in MetaData. Modelled because
	-- without it every TestCtx offline spec ran a path production does not have:
	-- `type(store.UpdateOfflineAsync) == "function"` was false, so Persistence took
	-- its injected-store FALLBACK, and the compare-and-set the library actually
	-- ships was unreached by the whole suite.
	fake.Meta = {} :: { [string]: { LastUpdate: number, WriteIndex: number, SessionLoadCount: number } }
	fake.SaveCounts = {} :: { [string]: number }
	fake.Constants = {} :: { [string]: number } -- records ProfileStore.SetConstant calls

	-- SHUTDOWN. Modelled because Scribe's own drain is built on it and CI could see
	-- neither half: Persistence guards both calls with `type(...) == "function"`,
	-- so with these absent the entire handshake was a no-op on every CI run.
	-- Measured before they existed: deleting `pcall(ProfileStore.BeginClose)` from
	-- Persistence.Shutdown left 1347/0/7, and deleting `pcall(ProfileStore.AwaitClose)`
	-- left 1347/0/7 -- two guarded calls to nothing, in the one code path whose whole
	-- job is not losing the last save of the session.
	fake.IsClosing = false

	-- Loads that have STARTED and not yet returned. The fork counts these
	-- (ActiveProfileLoadJobs) and AwaitClose waits on them; the fake can express the
	-- same state because StartSessionAsync yields under YieldOnSessionStart.
	fake.ActiveLoadJobs = 0

	function fake.SetConstant(name: string, value: number)
		fake.Constants[name] = value
	end

	--- Stop new sessions starting. Mirrors ProfileStore.BeginClose: the whole of its
	--- effect is the flag, and the flag's whole effect is StartSessionAsync
	--- returning nil.
	function fake.BeginClose()
		fake.IsClosing = true
	end

	--- Release whatever is still held, then wait for outstanding jobs.
	---
	--- Deliberately faithful to the fork rather than better than it, including one
	--- thing the fork gets arguably wrong: the active list is cloned ONCE, before the
	--- wait, so a load that was already yielding when AwaitClose began mints a
	--- session this drain never releases. BeginClose closes that window everywhere
	--- except for loads already past StartSessionAsync's own IsClosing check. A fake
	--- that quietly fixed it would hide the difference rather than surface it, which
	--- is the opposite of this file's job.
	---
	--- The release is EndSession, not Save: the fork calls
	--- `SaveProfileAsync(profile, true, ...)`, an ending-session save, and
	--- EndSession is the fake's spelling of exactly that signal order.
	function fake.AwaitClose()
		local held = table.clone(fake.ActiveProfiles)
		for _, profile in held do
			if profile:IsActive() then
				profile:EndSession()
			end
		end
		-- The job-drain wait, which is the half that matters when the owner has
		-- already released everything itself: it keeps the caller here until the
		-- loads still in flight have finished.
		while fake.ActiveLoadJobs > 0 do
			task.wait()
		end
	end

	--- Simulate ANOTHER SERVER force-loading `profileKey` and taking the session
	--- lock. The incumbent (if any) is dropped without a final save and its
	--- OnSessionEnd fires, exactly as ProfileStore does to a superseded session;
	--- the key is then free for the next StartSessionAsync to claim.
	--- Returns true if a live session was actually stolen.
	---
	--- Only reachable when two harnesses share one fake (TestCtx.make{ Fake = ... }):
	--- with a private fake per harness there is no second server to do the stealing.
	function fake.StealSession(profileKey: string, storeName: string?): boolean
		local key = `{storeName or "Default"}/{profileKey}`
		local profile = fake.ActiveProfiles[key]
		if not profile then
			return false
		end
		profile._steal()
		return true
	end

	--- Is `profileKey` currently session-locked by anyone on this shared disk?
	function fake.IsLocked(profileKey: string, storeName: string?): boolean
		return fake.ActiveProfiles[`{storeName or "Default"}/{profileKey}`] ~= nil
	end

	function fake.New(storeName: string, template: AnyTable?)
		local store = {} :: any
		store.Name = storeName
		store.Mock = store -- UseMock/DontSave switch to .Mock; same fake store

		local function fullKey(profileKey: string): string
			return `{storeName}/{profileKey}`
		end

		--- The per-key MetaData the real store keeps, created on demand.
		local function metaFor(key: string)
			local meta = fake.Meta[key]
			if not meta then
				-- SessionLoadCount is seeded from the SAME rule the view reports
				-- (below): a key with stored data was written by some earlier session,
				-- so its count is 1. Specs seed fake.Persisted directly all over the
				-- suite, and if the view and the compare-and-set disagreed about this
				-- field every such key would fingerprint as "Changed" forever.
				meta = {
					LastUpdate = 0,
					WriteIndex = 0,
					SessionLoadCount = if fake.Persisted[key] then 1 else 0,
				}
				fake.Meta[key] = meta
			end
			return meta
		end

		--- Every COMMITTING write bumps WriteIndex; only a non-overwriting one stamps
		--- LastUpdate. That asymmetry is the fork's (SaveProfileAsync's is_overwriting
		--- branch writes Data and clears the lock without touching LastUpdate), and it
		--- is exactly why LastUpdate alone could not see a view SetAsync.
		local function bumpWrite(key: string, stampLastUpdate: boolean)
			local meta = metaFor(key)
			meta.WriteIndex += 1
			if stampLastUpdate then
				meta.LastUpdate = os.time()
			end
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
			profile.HandlerCount = 0
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
			-- Mirrors the fork: fires exactly ONCE per save call whatever the outcome.
			-- Without it Persistence's in-flight counter only ever goes up, so every
			-- later error on the key is re-attributed to a save that finished long ago.
			profile.OnSettled = Signal.new()
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

			-- The fork's three named accessors, mirrored exactly. Persistence calls
			-- these instead of reading the fields, so a double that omitted one would
			-- fail on a nil call rather than drift quietly -- which is the point of
			-- naming them, and the reason they are worth carrying here.
			function profile.HasCompletedSave(_self: any): boolean
				return #profile.UserIds > 0
			end

			-- A live load has already run the session-start increment; a view has not,
			-- and sets view_mode. Same expression as the fork.
			function profile.SessionsStarted(_self: any): number
				return profile.SessionLoadCount + (if profile.view_mode == true then 1 else 0)
			end

			-- Mirrors the fork: retention is on unless the owner opts out, and the
			-- release happens AFTER OnAfterSave so the handler still sees the real
			-- table. Modelled here rather than left out, or the release would ship in
			-- every real save while being exercised by nothing in CI.
			function profile.SetRetainLastSaved(_self: any, retain: boolean?)
				profile._retainLastSaved = retain ~= false
			end

			function profile.SetSaveSource(_self: any, data: AnyTable)
				if type(data) ~= "table" then
					error("SetSaveSource expects a table")
				end
				profile.Data = data
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
			local function persist(saveContext: AnyTable?): boolean
				if fake.FailSaves then
					fake.OnError:Fire("mock save failure", storeName, profileKey)
					return false
				end
				-- Mirrors the fork's `save_context.SavedSource`: WHICH table this write
				-- serialized, recorded at write time rather than when OnSave fired.
				-- SetSaveSource is per-profile, so a swap made by a later save changes
				-- what an earlier one writes -- and a caller that read the pointer at
				-- snapshot time would describe a payload that never reached the key.
				-- Modelled here rather than left out, or the whole write-time verdict
				-- would ship in every real save while being exercised by nothing in CI.
				if saveContext then
					saveContext.SavedSource = profile.Data
				end
				local snapshot = Util.deepClone(profile.Data)
				fake.Persisted[key] = snapshot
				bumpWrite(key, true)
				-- A completed save is what puts UserIds in the datastore.
				fake.PersistedUserIds[key] = Util.deepClone(profile.UserIds)
				fake.SaveCounts[key] = (fake.SaveCounts[key] or 0) + 1
				recordVersion(profileKey, snapshot)
				profile.LastSavedData = snapshot
				-- Real delivery runs inside the save (ProfileStore.luau:1246-1270), so a
				-- handler observes a save already in flight.
				drainMailbox()
				profile.OnAfterSave:Fire(profile.LastSavedData)
				if profile._retainLastSaved == false then
					profile.LastSavedData = RELEASED_LAST_SAVED
				end
				return true
			end

			function profile.Save(_self: any)
				if not active then
					return
				end
				local saveContext = {}
				profile.OnSave:Fire(saveContext)
				if fake.MidSave then
					fake.MidSave()
				end
				local ok = persist(saveContext)
				profile.OnSettled:Fire(saveContext, if ok then "Saved" else "Failed")
			end

			--- The fork's yielding save. Mirrors src/Internal/Store: reports what
			--- happened to THIS call, and hands back the per-call context its OnSave
			--- handlers wrote to.
			---
			--- The fake persists synchronously, so there is no "in flight" state to
			--- model here -- which is exactly why the specs that care about overlapping
			--- saves run against the real vendored store under test/Sim instead.
			function profile.SaveAwait(_self: any): (string, { [string]: any })
				if not active then
					return "NotOwned", {}
				end
				local saveContext = {}
				profile.OnSave:Fire(saveContext)
				if fake.MidSave then
					fake.MidSave()
				end
				local outcome = if persist(saveContext) then "Saved" else "Failed"
				profile.OnSettled:Fire(saveContext, outcome)
				return outcome, saveContext
			end

			function profile.EndSession(_self: any)
				if not active then
					return
				end
				-- Real order (ProfileStore.luau:925-941, then :1171): OnSave, OnLastSave, the
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
				-- Observable, because "is the cross-server handler registered yet" is a
				-- question about load ORDERING that a spec otherwise cannot ask: the
				-- handler list is a local, and its only visible effect is a gift that
				-- happens to be in the mailbox.
				profile.HandlerCount = #messageHandlers
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

			-- End this session the way ANOTHER SERVER stealing the lock does, as
			-- opposed to profile:EndSession() (which is this server letting go). Real
			-- ProfileStore drops the session and fires OnSessionEnd WITHOUT a final
			-- save: the thief now owns the key, so writing here would clobber it. That
			-- asymmetry is the whole point -- Scribe distinguishes the two with
			-- entry.LocalSessionEnd, and nothing in the suite could reach the remote
			-- branch before shared-disk harnesses existed.
			function profile._steal()
				if not active then
					return
				end
				active = false
				if fake.ActiveProfiles[key] == profile then
					fake.ActiveProfiles[key] = nil
				end
				profile.OnSessionEnd:Fire()
			end

			return profile
		end

		--- The body, so the caller below can count the job around it on every exit.
		local function beginSession(profileKey: string, params: any?)
			if fake.YieldOnSessionStart then
				task.wait()
			end
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
			-- A session start is a committing write in the real store: its EditProfile
			-- bumps SessionLoadCount and stamps LastUpdate.
			local meta = metaFor(key)
			meta.SessionLoadCount += 1
			bumpWrite(key, true)
			fake.ActiveProfiles[key] = profile
			-- A load that lands DURING a shutdown releases what it just minted and
			-- hands back nothing (ProfileStore.luau:2353, "The server has initiated a
			-- shutdown by the time this profile was loaded"). The release happens here,
			-- inside the counted region, so AwaitClose's job-drain wait cannot return
			-- before it has finished -- which is why the fork can safely clone its
			-- active list once, up front.
			--
			-- The fake's first draft did NOT do this, and asserted in a progress note
			-- that the fork did not either. Measured across the whole 50 ms in-flight
			-- window at seven offsets, the fork leaves nothing active and returns nil
			-- every time; the fake left a live session behind. The note was wrong and
			-- the fake was wrong with it.
			if fake.IsClosing then
				profile:EndSession()
				return nil
			end
			return profile
		end

		function store.StartSessionAsync(_self: any, profileKey: string, params: any?)
			-- BEFORE the yield, and before anything else: the fork checks IsClosing at
			-- the very top of StartSessionAsync and returns nil, which is what stops the
			-- drain having to wait for work it just started. A load already past this
			-- point keeps going -- that window is real, and AwaitClose is where it shows.
			if fake.IsClosing then
				return nil
			end
			-- Counted for the whole of the call, yield included, because that is the
			-- span AwaitClose waits on.
			fake.ActiveLoadJobs += 1
			local ok, profile = pcall(beginSession, profileKey, params)
			fake.ActiveLoadJobs -= 1
			if not ok then
				error(profile, 0)
			end
			return profile
		end

		function store.GetAsync(_self: any, profileKey: string, version: string?)
			-- Views are refused while closing too, not just sessions. This one was
			-- MISSED in the first draft of the fake's shutdown support and caught by
			-- Conformance.spec's fork arm on its first run: the fork checks IsClosing
			-- at the top of GetAsync as well as StartSessionAsync, so during a drain a
			-- read answers nil there and answered real data here. Anything Scribe does
			-- with a view mid-shutdown -- GetOffline, the offline receipt path,
			-- ListVersions -- would have taken a different branch on each.
			if fake.IsClosing then
				return nil
			end
			if fake.MidRead and version == nil then
				fake.MidRead(profileKey)
			end
			if fake.FailReads then
				error("mock read failure", 0)
			end
			local key = fullKey(profileKey)
			local data: AnyTable? = nil
			local keyInfo = { Version = version or "live", CreatedTime = os.time() * 1000 }
			if version then
				if fake.MidVersionRead then
					fake.MidVersionRead()
				end
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
			--
			-- Read from the SAME meta the compare-and-set fingerprints against, rather
			-- than hardcoded to 1. The literal agreed with the meta only for a key that
			-- had seen exactly ONE session -- which every spec doing an offline write
			-- happened to be -- and disagreed by one per session after that, so a
			-- profile that had been joined twice fingerprinted as "Changed" forever and
			-- UpdateOfflineAsync could never commit. That made a two-server or
			-- across-a-deploy offline write (RestoreVersion after a migration, say)
			-- untestable for a reason that lived entirely in this double. metaFor seeds
			-- the count to 1 for a key whose data a spec wrote straight into
			-- fake.Persisted, so hand-seeded keys read exactly as they did before.
			view.SessionLoadCount = metaFor(key).SessionLoadCount
			-- The two fields the compare-and-set fingerprints on. The fork exposes both
			-- on Profile.New with the same `or 0` normalisation.
			view.LastUpdate = metaFor(key).LastUpdate
			view.WriteIndex = metaFor(key).WriteIndex
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
				if fake.MidOfflineCommit then
					fake.MidOfflineCommit()
				end
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
				-- `false`: the overwrite arm does NOT stamp LastUpdate. Modelling that
				-- faithfully is what lets a spec show a view write being invisible to a
				-- fingerprint built on LastUpdate alone.
				bumpWrite(key, false)
				recordVersion(profileKey, view.Data)
				-- A view-mode SetAsync CLEARS THE SESSION LOCK, and modelling that is
				-- the whole reason this line exists. ProfileStore's overwrite path sets
				-- session_owns_profile = true unconditionally and then writes
				-- MetaData.ActiveSession = nil, so an offline write lands on a live
				-- server's key and silently disowns it: the incumbent's next save finds
				-- it no longer owns the profile, writes nothing, and ends the session.
				--
				-- Without this the fake reported the clobbering write as a clean
				-- success with the live session still locked and still saving, so no
				-- TestCtx spec could express the bug -- or catch a broken fix for it.
				local incumbent = fake.ActiveProfiles[key]
				if incumbent and incumbent._steal then
					incumbent._steal()
				end
			end
			return view
		end

		--- The compare-and-set the fork ships, modelled to the same contract.
		---
		--- Its absence here was a §3.1 fake/fork split in its purest form: because the
		--- fake did not have this method, `type(store.UpdateOfflineAsync) == "function"`
		--- was FALSE under TestCtx, so every offline spec in the suite -- AuditFixes,
		--- OfflineWriteLock, HealthScope, Utf8Guard, FailureReport, Receipts,
		--- OfflineCooldowns -- exercised Persistence's injected-store fallback instead
		--- of the shipped path, and no mutation to the CAS could be seen by CI at all.
		---
		--- Returns "Written" | "SessionActive" | "Changed" | "Missing" | "Failed".
		--- A decline writes NOTHING, which here means: does not touch fake.Persisted,
		--- does not bump WriteIndex, and does not record a version.
		function store.UpdateOfflineAsync(
			_self: any,
			profileKey: string,
			expected: AnyTable,
			newData: AnyTable,
			options: AnyTable?
		)
			if fake.MidOfflineCommit then
				fake.MidOfflineCommit()
			end
			if fake.FailSaves then
				fake.OnError:Fire("mock save failure", storeName, profileKey)
				return "Failed"
			end
			local key = fullKey(profileKey)
			if fake.Persisted[key] == nil then
				return "Missing"
			end

			local meta = metaFor(key)
			if fake.ActiveProfiles[key] ~= nil then
				-- Same three clauses as the fork: no usable LastUpdate means LIVE,
				-- because refusing is the safe direction.
				local staleAfter = options and options.StaleSessionAfter
				if
					type(staleAfter) ~= "number"
					or type(meta.LastUpdate) ~= "number"
					or meta.LastUpdate <= 0
					or os.time() - meta.LastUpdate <= staleAfter
				then
					return "SessionActive"
				end
				-- Past the dead-session threshold: disown the incumbent, exactly as a
				-- session steal does. The fake already models that with _steal.
				local incumbent = fake.ActiveProfiles[key]
				if incumbent and incumbent._steal then
					incumbent._steal()
				end
				fake.ActiveProfiles[key] = nil
			end

			if
				meta.SessionLoadCount ~= expected.SessionLoadCount
				or meta.LastUpdate ~= expected.LastUpdate
				or (meta.WriteIndex or 0) ~= (expected.WriteIndex or 0)
			then
				return "Changed"
			end

			fake.Persisted[key] = Util.deepClone(newData)
			bumpWrite(key, true)
			recordVersion(profileKey, newData)
			return "Written"
		end

		function store.MessageAsync(_self: any, profileKey: string, message: any): (boolean, string?, boolean?)
			-- THE THIRD RETURN IS THE POINT OF THIS WHOLE METHOD NOW. The fork answers
			-- `provably_clean` alongside the boolean and the reason -- true only where
			-- NOTHING can have been written by the call -- because the first two values
			-- collapse three outcomes a caller with money on the line has to tell apart.
			-- Every branch below states which of the three it is, and a branch that
			-- says nothing reads as "cannot be sure", which is the cheap direction.
			--
			-- THE ENTRY GUARD, and the fake was silent on it. The fork checks IsClosing
			-- at the top of MessageAsync (ProfileStore.luau:2450) and returns BEFORE
			-- WaitForStoreReady and before the retry loop: zero attempts, zero
			-- UpdateAsync calls, nothing written. PROVABLY CLEAN, and it used to be
			-- spelled identically to the loop's give-up at :2645, which is ambiguous
			-- whenever any attempt could have written -- the collapse that ate a buyer's
			-- paid gift credit.
			--
			-- Modelled here rather than stubbed per-spec because the shape belongs to
			-- the store, not to any one caller: without it no TestCtx spec can reach
			-- a shutdown-window send at all, and a caller that eats a paid credit
			-- there looks green. It is also why the guard sits ABOVE FailMessages --
			-- the fork answers on IsClosing first, whatever else is set.
			if fake.IsClosing then
				return false, nil, true
			end
			-- AMBIGUOUS ON PURPOSE, and it must stay that way. FailMessages stands in
			-- for the fork's give-up exit: a retry loop that ran, made attempts that
			-- could each have committed before erroring, and ended at BindToClose with
			-- nothing to say. Two values, no claim of cleanliness. The pair of this
			-- branch and the one above is what GiftCreditShutdownSpend.spec reads to
			-- show the fork now separates them.
			if fake.FailMessages then
				return false
			end
			-- The queue is BOUNDED, and modelling that is the whole reason this branch
			-- exists. The real store caps undelivered messages per key; it used to
			-- enforce the cap by dropping the OLDEST entry and returning true, which is
			-- how a purchased gift could be destroyed silently. An unbounded mailbox
			-- here made that unreachable from CI -- no TestCtx spec could express the
			-- bug, or catch a broken fix for it.
			--
			-- Honours MAX_MESSAGE_QUEUE through the same SetConstant seam the real
			-- store uses, which fake.SetConstant already records.
			-- Real MessageAsync only COMMITS the message to GlobalUpdates; it never
			-- delivers (ProfileStore.luau:1667-1699). Delivery happens later, inside a
			-- save, or at MessageHandler registration. Delivering inline here meant a
			-- cross-server gift never arrived while a save was in flight, which is the
			-- exact condition the SaveGen waiter gate exists to handle.
			local key = fullKey(profileKey)
			local mailbox = fake.Mailboxes[key]
			if not mailbox then
				mailbox = {}
				fake.Mailboxes[key] = mailbox
			end
			local cap = fake.Constants.MAX_MESSAGE_QUEUE or 1000
			if #mailbox >= cap then
				-- PROVABLY CLEAN, by the other route. The fork's transform ran, saw the
				-- cap, set AbortWrite and committed nothing; here the insert below simply
				-- does not happen. One call of this fake is ONE attempt and cannot loop, so
				-- there are no earlier attempts for the fork's claim to be weighed against
				-- and it answers clean. NOT because it is the FIRST attempt: the fork
				-- classifies each failed attempt off its error rather than counting them, so
				-- a full inbox behind nothing but rejections and throttles is clean too. The
				-- ambiguous shape, a QueueFull that follows an attempt that may have
				-- written, cannot be produced by one call and is injected by the seam in
				-- GiftCreditSpendContract.spec instead.
				return false, "QueueFull", true
			end
			table.insert(mailbox, Util.deepClone(message))
			return true
		end

		function store.RemoveAsync(_self: any, profileKey: string): boolean
			local key = fullKey(profileKey)
			-- RemoveAsync deletes the key outright, lock included, so a live session
			-- elsewhere is disowned exactly as it is by a view write -- and worse: its
			-- next save finds no MetaData at all and throws inside ProfileStore's own
			-- transform. Modelled here for the same reason as SetAsync above.
			local incumbent = fake.ActiveProfiles[key]
			if incumbent and incumbent._steal then
				incumbent._steal()
			end
			fake.Persisted[key] = nil
			fake.PersistedUserIds[key] = nil
			fake.Versions[key] = nil
			fake.Mailboxes[key] = nil
			fake.Meta[key] = nil
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
