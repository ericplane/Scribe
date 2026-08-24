--!nonstrict
-- The view-mode back doors, and the live session they can disown.
--
-- UpdateOffline, RestoreVersion and Erase all write a key WITHOUT holding its
-- session lock. That is not merely "unsynchronised": ProfileStore's overwrite
-- path sets session_owns_profile = true unconditionally and then writes
-- MetaData.ActiveSession = nil, so an offline write CLEARS whichever server owns
-- the key. RemoveAsync deletes the lock along with everything else.
--
-- The victim finds out on its next save, which silently writes nothing, ends the
-- session and kicks the player. Two-sided data loss: everything the live session
-- wrote since its last save is discarded, and anything it committed after the
-- offline read is rolled back to that stale snapshot.
--
-- Each call site guards with a read of `profile.Session` -- but the read and the
-- write are separate round trips, and between them sits `mutate`, which is
-- DEVELOPER code and may yield for as long as it likes. The offline receipt path
-- runs it on every grant for an absent player, so this is the common route in,
-- not a contrived one.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)

	local function twoServers(options: { [string]: any }?)
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake, Options = options })
		local b = TestCtx.make({ Fake = fake, Options = options })
		return fake, a, b, function()
			b.Cleanup()
			a.Cleanup()
		end
	end

	describe("a session claimed while an offline write is in flight", function()
		it("refuses the write rather than disowning the live server", function()
			local fake, a, b, cleanup = twoServers()

			-- Give the user a stored profile, then release it, so the key exists and
			-- is unlocked when B begins.
			local first = a.Join(52001)
			a.Data.Flush(first)
			a.Leave(first)

			-- Nobody holds the key when B starts, so B's up-front guard passes.
			local rejoined
			local ok, reason = b.Data.UpdateOffline(52001, function(data)
				-- ...and the player joins A while B's callback runs. `mutate` is
				-- developer code: a web call, a wait, or simply a slow loop puts a
				-- real join inside this window.
				rejoined = a.Join(52001)
				data.Coins = 999
			end)

			-- The write must not be reported as a success it cannot honour.
			expect(`ok={ok}`).to.equal("ok=false")
			expect(`reason={string.find(tostring(reason), "another server", 1, true) ~= nil}`).to.equal("reason=true")

			-- And A must still own its session: still Ready, not kicked, lock held.
			expect(fake.IsLocked("PLAYER_52001")).to.equal(true)
			expect(a.Ctx.Persistence.GetState(rejoined)).to.equal("Ready")
			expect(`kicked={rejoined.Kicked}`).to.equal("kicked=nil")

			cleanup()
		end)

		it("does not roll a live server's data back to the stale snapshot", function()
			local fake, a, b, cleanup = twoServers()

			local playerA, _, dataA = a.Join(52002)
			dataA.Coins.Set(500)
			expect(a.Data.Flush(playerA)).to.equal(true)
			a.Leave(playerA)

			-- B reads while the key is free, then A takes it back mid-callback and
			-- writes something newer.
			b.Data.UpdateOffline(52002, function(data)
				local rejoined, _, live = a.Join(52002)
				live.Coins.Set(777)
				expect(a.Data.Flush(rejoined)).to.equal(true)
				data.Coins = 1
			end)

			-- The refused write must leave A's newer value alone.
			expect(fake.Persisted["Default/PLAYER_52002"].Coins).to.equal(777)

			cleanup()
		end)

		it("refuses an Erase while another server holds the key", function()
			-- Erase is the worst outcome of the three if it does land on a live
			-- session: RemoveAsync takes the key and the lock together, and the
			-- victim's next save then finds no MetaData at all and throws inside
			-- ProfileStore's own transform -- which for an ENDING save retries
			-- forever and holds the shutdown drain until Roblox kills the server.
			--
			-- Its window is already one round trip, though: the read sits immediately
			-- above the RemoveAsync with nothing in between, so there is no developer
			-- callback to widen it and nothing for a re-check to add. What is pinned
			-- here is that the existing guard genuinely refuses.
			local fake, a, b, cleanup = twoServers()

			local seed = a.Join(52004)
			a.Data.Flush(seed)
			a.Leave(seed)
			a.Join(52004) -- A holds it again, and now the key exists on disk

			local erased, reason = b.Data.Erase(52004)
			expect(`ok={erased}`).to.equal("ok=false")
			expect(`reason={string.find(tostring(reason), "another server", 1, true) ~= nil}`).to.equal("reason=true")
			expect(fake.IsLocked("PLAYER_52004")).to.equal(true)
			expect(fake.Persisted["Default/PLAYER_52004"]).to.be.ok()

			cleanup()
		end)
	end)

	describe("what still works", function()
		it("writes normally when nobody holds the key", function()
			-- The guard must not become a blanket refusal: the ordinary offline write
			-- is the entire point of the API.
			local fake, a, b, cleanup = twoServers()
			local seed = a.Join(52005)
			a.Data.Flush(seed)
			a.Leave(seed)

			local ok, reason = b.Data.UpdateOffline(52005, function(data)
				data.Coins = 42
			end)
			expect(`ok={ok} reason={reason}`).to.equal("ok=true reason=nil")
			expect(fake.Persisted["Default/PLAYER_52005"].Coins).to.equal(42)
			cleanup()
		end)

		it("still refuses up front when the session is already held", function()
			-- The pre-existing guard stays: this must be refused before the callback
			-- ever runs, not after it has done work.
			local fake, a, b, cleanup = twoServers()
			-- Seeded first. Without a stored profile the call refuses with "profile
			-- does not exist", which also leaves `ran` false -- so the assertion
			-- below would hold with the session guard deleted. A mutation removing
			-- that guard survived exactly this spec before the seed was added.
			local seed = a.Join(52006)
			a.Data.Flush(seed)
			a.Leave(seed)
			a.Join(52006)
			local ran = false
			local ok = b.Data.UpdateOffline(52006, function()
				ran = true
			end)
			expect(`ok={ok} ran={ran}`).to.equal("ok=false ran=false")
			expect(fake.IsLocked("PLAYER_52006")).to.equal(true)
			cleanup()
		end)

		it("recovers from a DEAD session at the same age Erase does", function()
			-- A9. UpdateOffline gated on sessionLooksLive, which allows a session whose
			-- LastUpdate is older than ASSUME_DEAD (630 s) -- and then handed off to a
			-- compare-and-set that refused on `ActiveSession ~= nil` with no age test at
			-- all. So Erase and RestoreVersion recovered from a crashed server and
			-- UpdateOffline never did, at any age, with the same false reason string.
			-- The allowance was ALSO mutation-dead: FakeProfileStore's view carried no
			-- LastUpdate, so sessionLooksLive short-circuited to `return true` on every
			-- CI path and the age comparison never ran.
			--
			-- Both operators are driven at BOTH ages against the same crashed holder,
			-- because the claim is that they AGREE -- one of them succeeding at 700 s is
			-- only interesting next to the other doing the same.
			local fake, a, _b, cleanup = twoServers()
			local now = os.time()

			local function crashedHolder(userId: number)
				local key = `Default/PLAYER_{userId}`
				fake.Persisted[key] = { Coins = 5 }
				fake.PersistedUserIds[key] = { userId }
				fake.ActiveProfiles[key] = { PlaceId = 1, JobId = "crashed-server" }
				fake.Meta[key] = { LastUpdate = now, WriteIndex = 0, SessionLoadCount = 1 }
				return key
			end

			local updateKey = crashedHolder(53001)
			local eraseKey = crashedHolder(53002)

			-- Fresh lock: both refuse.
			local updateFresh = a.Data.UpdateOffline(53001, function(data)
				data.Coins = 9
			end)
			local eraseFresh = a.Data.Erase(53002)

			-- Older than ASSUME_DEAD: both proceed.
			fake.Meta[updateKey].LastUpdate = now - 700
			fake.Meta[eraseKey].LastUpdate = now - 700
			local updateStale = a.Data.UpdateOffline(53001, function(data)
				data.Coins = 9
			end)
			local eraseStale = a.Data.Erase(53002)

			expect(
				`updateFresh={updateFresh} eraseFresh={eraseFresh} `
					.. `updateStale={updateStale} eraseStale={eraseStale} `
					.. `coins={fake.Persisted[updateKey].Coins} erased={fake.Persisted[eraseKey] == nil}`
			).to.equal("updateFresh=false eraseFresh=false updateStale=true eraseStale=true coins=9 erased=true")
			cleanup()
		end)

		it("refuses when the compare-and-set itself does not land", function()
			-- Fail closed. A commit we cannot stand behind is exactly what the offline
			-- receipt path turns into a granted-but-unsaved purchase.
			--
			-- This is the SHIPPED path. It used to be written against a failing
			-- verifying READ, which the compare-and-set does not have -- there is only
			-- one round trip now, which is the point of it. That version of the spec
			-- passed only because FakeProfileStore had no UpdateOfflineAsync at all, so
			-- TestCtx took Persistence's injected-store fallback and never reached the
			-- code Scribe actually runs. The fallback still exists, and still has its
			-- own case, below.
			local fake, a, b, cleanup = twoServers()
			local seed = a.Join(52008)
			a.Data.Flush(seed)
			a.Leave(seed)

			local ok, reason = b.Data.UpdateOffline(52008, function(data)
				data.Coins = 7
				-- The compare-and-set is the next thing that happens.
				fake.FailSaves = true
			end)
			fake.FailSaves = false

			expect(`ok={ok}`).to.equal("ok=false")
			expect(`reason={reason ~= nil}`).to.equal("reason=true")
			-- ...and nothing was written.
			expect(fake.Persisted["Default/PLAYER_52008"].Coins).never.to.equal(7)
			cleanup()
		end)

		it("refuses when the FALLBACK's verifying read cannot complete", function()
			-- The same claim for a game that injects its own store with no
			-- compare-and-set, which is the one case Persistence's read-then-write
			-- fallback still serves. Driven by removing the method, which is exactly
			-- how Persistence decides between the two paths.
			local fake, a, b, cleanup = twoServers()
			local seed = a.Join(52009)
			a.Data.Flush(seed)
			a.Leave(seed)

			local store = b.Ctx.Persistence.Store
			local realCas = store.UpdateOfflineAsync
			store.UpdateOfflineAsync = nil

			local ok, reason = b.Data.UpdateOffline(52009, function(data)
				data.Coins = 7
				-- The verifying read is the next thing that happens.
				fake.FailReads = true
			end)
			fake.FailReads = false
			store.UpdateOfflineAsync = realCas

			expect(`ok={ok}`).to.equal("ok=false")
			expect(`reason={reason ~= nil}`).to.equal("reason=true")
			expect(fake.Persisted["Default/PLAYER_52009"].Coins).never.to.equal(7)
			cleanup()
		end)

		it("refuses a RestoreVersion that would disown a live session", function()
			-- RestoreVersion reaches the same commitViewProfile through two version
			-- reads, so it has the same window and needs the same re-check.
			local fake, a, b, cleanup = twoServers()

			local seed, _, seedData = a.Join(52009)
			seedData.Coins.Set(11)
			a.Data.Flush(seed)
			seedData.Coins.Set(22)
			a.Data.Flush(seed)
			a.Leave(seed)

			local versions = b.Data.ListVersions(52009, 5)
			expect(#versions > 0).to.equal(true)

			-- A takes the key back DURING the restore -- after its up-front guard has
			-- passed and while it is reading the version. That is the window the
			-- re-check exists for; joining before the call would only exercise the
			-- guard that was already there.
			fake.MidVersionRead = function()
				fake.MidVersionRead = nil
				a.Join(52009)
			end
			local ok, reason = b.Data.RestoreVersion(52009, versions[#versions].VersionId)
			expect(`ok={ok}`).to.equal("ok=false")
			expect(`reason={string.find(tostring(reason), "another server", 1, true) ~= nil}`).to.equal("reason=true")
			expect(fake.IsLocked("PLAYER_52009")).to.equal(true)

			cleanup()
		end)

		it("refuses a RestoreVersion when the session lands AFTER the re-check", function()
			-- The window the re-check does NOT close, and the reason RestoreVersion
			-- needed the compare-and-set rather than one more read. The re-check is a
			-- SEPARATE DataStore round trip from the write, so a join that lands
			-- between them still disowns the holder: the view SetAsync sets
			-- session_owns_profile unconditionally and clears ActiveSession, and the
			-- holder finds out on its next autosave -- up to AUTO_SAVE_PERIOD later --
			-- having accepted writes the whole time that are now unpersistable, and
			-- having been rolled back to the restored snapshot.
			--
			-- MidOfflineCommit fires on BOTH commit primitives, so this spec asserts
			-- the same property before and after the call site moved.
			local fake, a, b, cleanup = twoServers()

			local seed, _, seedData = a.Join(52010)
			seedData.Coins.Set(11)
			a.Data.Flush(seed)
			seedData.Coins.Set(22)
			a.Data.Flush(seed)
			a.Leave(seed)

			local versions = b.Data.ListVersions(52010, 5)
			expect(#versions > 0).to.equal(true)

			fake.MidOfflineCommit = function()
				fake.MidOfflineCommit = nil
				a.Join(52010)
			end
			local ok, reason = b.Data.RestoreVersion(52010, versions[#versions].VersionId)
			fake.MidOfflineCommit = nil

			expect(`ok={ok}`).to.equal("ok=false")
			expect(`reason={string.find(tostring(reason), "another server", 1, true) ~= nil}`).to.equal("reason=true")
			-- The holder still owns the key, and still has its own data.
			expect(`locked={fake.IsLocked("PLAYER_52010")}`).to.equal("locked=true")
			expect(`coins={fake.Persisted["Default/PLAYER_52010"].Coins}`).to.equal("coins=22")

			cleanup()
		end)
	end)

	describe("the harness itself", function()
		it("models a view write clearing the session lock", function()
			-- The fake has to be able to EXPRESS the bug, or nothing above proves a
			-- fix. It could not until this session: view SetAsync wrote Persisted and
			-- left ActiveProfiles untouched, so a clobbering write looked like a
			-- clean success with the victim still locked and still saving.
			local fake, a, _, cleanup = twoServers()
			local seed = a.Join(52010)
			a.Data.Flush(seed)
			expect(fake.IsLocked("PLAYER_52010")).to.equal(true)

			local store = fake.New("Default")
			local view = store:GetAsync("PLAYER_52010")
			expect(view).to.be.ok()
			view:SetAsync()

			-- The live session has been disowned, which is what production does.
			expect(fake.IsLocked("PLAYER_52010")).to.equal(false)
			cleanup()
		end)
	end)
end
