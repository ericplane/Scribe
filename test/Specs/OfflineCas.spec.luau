--!nonstrict
-- Compare-and-set for an offline write, against the REAL vendored store.
--
-- Writing to an absent player's key means reading it, letting developer code
-- decide what to change, then writing back -- and developer code can yield, so the
-- player can join a server inside that window. Losing that race is worse than a
-- lost write: a view SetAsync sets session_owns_profile unconditionally and clears
-- ActiveSession, so committing over a live session DISOWNS it. That server's next
-- save writes nothing, its player is kicked, and everything since its last save is
-- gone.
--
-- The old code re-read the lock and then wrote, which narrowed the window to one
-- round trip without closing it -- and said so in the public API docs. These pin
-- the replacement: the check and the write are one DataStore call, and a decline
-- writes NOTHING.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local universe

	local function build(overrides)
		local config = {
			Seed = 9090,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {},
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe, universe:Server(1)
	end

	local function record(uni, key)
		for _, e in uni.Disk.Keyspace:Each() do
			if e.Key == key then
				return e.Record
			end
		end
		return nil
	end

	--- Create the key, then leave so it is genuinely offline.
	local function seed(uni, server, userId)
		local player = FakePlayer.new(userId)
		server:Join(userId, player)
		uni:Run(2)
		server.Bundle.Data.Get(player).Coins.Set(100)
		server:Leave(userId)
		uni:Run(10)
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("offline compare-and-set", function()
		it("writes when the profile is offline and unchanged", function()
			local uni, server = build()
			seed(uni, server, 70001)
			local key = "PLAYER_70001"
			local store = server.Bundle.Ctx.Persistence.Store
			local before = record(uni, key).Value

			local outcome
			uni.Sched:Spawn(function()
				outcome = store:UpdateOfflineAsync(key, {
					SessionLoadCount = before.MetaData.SessionLoadCount,
					LastUpdate = before.MetaData.LastUpdate,
					WriteIndex = before.MetaData.WriteIndex,
				}, { Coins = 555, _Scribe = before.Data._Scribe })
			end)
			uni:Run(10)

			expect(outcome).to.equal("Written")
			expect(record(uni, key).Value.Data.Coins).to.equal(555)
		end)

		it("refuses the SECOND of two writers off one snapshot, whatever the timing", function()
			-- THE MONEY BUG. The fingerprint was `MetaData.LastUpdate`, stamped with
			-- os.time() -- ONE-SECOND granularity. Two writers holding the same
			-- snapshot whose first commit lands inside that same wall-clock second
			-- BOTH passed the check and were BOTH told "Written", and line 1599 is an
			-- assignment rather than a merge, so the first write -- including its
			-- markProcessedRaw purchase-dedup marker -- vanished. Data.UpdateOffline
			-- returns true to both callers, and Monetization answers PurchaseGranted
			-- on exactly that boolean.
			--
			-- Both calls run back-to-back on ONE scheduler thread against the Instant
			-- latency profile, so they land in the same virtual second by construction
			-- rather than by luck. The old spec never caught this because it faked a
			-- stale fingerprint by passing `LastUpdate - 1` instead of performing a
			-- real competing write.
			local uni, server = build()
			seed(uni, server, 70004)
			local key = "PLAYER_70004"
			local store = server.Bundle.Ctx.Persistence.Store
			local before = record(uni, key).Value

			local first, second, sameSecond
			uni.Sched:Spawn(function()
				-- One write to establish a fresh fingerprint, then the read, then both
				-- competing writers -- all inside ONE virtual second. That is the whole
				-- shape of the bug and the reason a naive version of this spec passes:
				-- if the snapshot is even one second older than the first commit, the
				-- one-second fingerprint happens to catch it and the hole is invisible.
				store:UpdateOfflineAsync(key, {
					SessionLoadCount = before.MetaData.SessionLoadCount,
					LastUpdate = before.MetaData.LastUpdate,
					WriteIndex = before.MetaData.WriteIndex,
				}, { Coins = 100, _Scribe = before.Data._Scribe })

				local startSecond = math.floor(uni.Sched.Now)
				local snap = record(uni, key).Value
				local expected = {
					SessionLoadCount = snap.MetaData.SessionLoadCount,
					LastUpdate = snap.MetaData.LastUpdate,
					WriteIndex = snap.MetaData.WriteIndex,
				}

				first = store:UpdateOfflineAsync(key, expected, { Coins = 111, _Scribe = before.Data._Scribe })
				second = store:UpdateOfflineAsync(key, expected, { Coins = 222, _Scribe = before.Data._Scribe })
				-- The premise, asserted rather than assumed: if the run ever drifts
				-- across a second boundary this spec must fail loudly instead of
				-- passing because the timing stopped colliding.
				sameSecond = math.floor(uni.Sched.Now) == startSecond
			end)
			uni:Run(10)

			expect(`sameSecond={sameSecond} first={first} second={second} coins={record(uni, key).Value.Data.Coins}`).to.equal(
				"sameSecond=true first=Written second=Changed coins=111"
			)
		end)

		it("sees a view SetAsync, which moves neither LastUpdate nor SessionLoadCount", function()
			-- The unconditional half, and it does not need a timing coincidence at
			-- all. SaveProfileAsync's is_overwriting branch writes Data and clears the
			-- lock but never stamps LastUpdate, and nothing bumps SessionLoadCount on
			-- that path -- so a view write leaves the CAS fingerprint byte-identical
			-- and a CAS off a pre-restore snapshot silently reverts it.
			--
			-- Scribe reaches that path from RestoreVersion and from the injected-store
			-- fallback in updateOfflineProfile, so this is the operator's restore being
			-- undone by a receipt that read the key a minute earlier.
			local uni, server = build()
			seed(uni, server, 70005)
			local key = "PLAYER_70005"
			local store = server.Bundle.Ctx.Persistence.Store
			local before = record(uni, key).Value
			local expected = {
				SessionLoadCount = before.MetaData.SessionLoadCount,
				LastUpdate = before.MetaData.LastUpdate,
				WriteIndex = before.MetaData.WriteIndex,
			}

			local outcome
			uni.Sched:Spawn(function()
				-- A view write, exactly as RestoreVersion commits one.
				local viewProfile = store:GetAsync(key)
				viewProfile.Data.Coins = 777
				viewProfile:SetAsync()
				-- ...and now the stale CAS, which must NOT land on top of it.
				outcome = store:UpdateOfflineAsync(key, expected, { Coins = 999, _Scribe = before.Data._Scribe })
			end)
			uni:Run(10)

			expect(`outcome={outcome} coins={record(uni, key).Value.Data.Coins}`).to.equal("outcome=Changed coins=777")
		end)

		it("refuses a stale fingerprint, and writes nothing", function()
			local uni, server = build()
			seed(uni, server, 70002)
			local key = "PLAYER_70002"
			local store = server.Bundle.Ctx.Persistence.Store
			local before = record(uni, key).Value

			local outcome
			uni.Sched:Spawn(function()
				outcome = store:UpdateOfflineAsync(key, {
					SessionLoadCount = before.MetaData.SessionLoadCount,
					LastUpdate = (before.MetaData.LastUpdate or 0) - 1, -- read something older
					-- The OTHER two fields are correct, so this isolates the LastUpdate
					-- arm of the comparison rather than passing for three reasons.
					WriteIndex = before.MetaData.WriteIndex,
				}, { Coins = 999, _Scribe = before.Data._Scribe })
			end)
			uni:Run(10)

			expect(outcome).to.equal("Changed")
			expect(record(uni, key).Value.Data.Coins).to.equal(100)
		end)

		it("commits no DataStore write at all when it declines", function()
			-- "A refusal writes nothing at all" is claimed in three places --
			-- ProfileStore.luau:754, src/Server/init.luau:376 and
			-- docgen/guides/migrating.md -- and was false. EditProfile "declines" by
			-- returning early, but transform_function returns latest_data on EVERY
			-- path, and UpdateAsync commits unless the transform returns nil. So a
			-- refusal minted a new key version and spent a write budget.
			--
			-- The key's VERSION is the assertion, not its value: the value was
			-- unchanged all along, which is exactly why this was invisible.
			local uni, server = build()
			seed(uni, server, 70006)
			local key = "PLAYER_70006"
			local store = server.Bundle.Ctx.Persistence.Store
			local before = record(uni, key)
			local versionBefore = before.Version

			local stale, sessionActive
			uni.Sched:Spawn(function()
				stale = store:UpdateOfflineAsync(key, {
					SessionLoadCount = before.Value.MetaData.SessionLoadCount,
					LastUpdate = (before.Value.MetaData.LastUpdate or 0) - 1,
					WriteIndex = -1,
				}, { Coins = 999, _Scribe = before.Value.Data._Scribe })
			end)
			uni:Run(10)

			-- ...and the same for a decline against a key that does not exist, which
			-- additionally MINTED a stub {GlobalUpdates = {0,{}}} key.
			local missingBefore = record(uni, "PLAYER_NOBODY")
			uni.Sched:Spawn(function()
				sessionActive = store:UpdateOfflineAsync("PLAYER_NOBODY", {
					SessionLoadCount = 0,
					LastUpdate = 0,
					WriteIndex = 0,
				}, { Coins = 1 })
			end)
			uni:Run(10)

			expect(
				`stale={stale} versions={record(uni, key).Version - versionBefore} `
					.. `missingBefore={missingBefore ~= nil} outcome={sessionActive} `
					.. `missingAfter={record(uni, "PLAYER_NOBODY") ~= nil}`
			).to.equal("stale=Changed versions=0 missingBefore=false outcome=Missing missingAfter=false")
		end)

		it("recovers past ASSUME_DEAD, the same age at which a session may be stolen", function()
			-- The fork's UpdateOfflineAsync refused unconditionally on
			-- `ActiveSession ~= nil`, with no age test at all -- while StartSessionAsync
			-- (:1884-1893) and Scribe's own sessionLooksLive both treat a session whose
			-- LastUpdate is older than ASSUME_DEAD (630 s) as dead. So Erase and
			-- RestoreVersion recovered from a crashed server and UpdateOffline never
			-- did, at ANY age, with the same false reason string.
			--
			-- The allowance is deliberately OPT-IN (a 4th argument) so the store's own
			-- default stays conservative for any other consumer, and it is evaluated
			-- INSIDE the transform -- deciding staleness on the pre-CAS GetAsync
			-- snapshot would be the exact read-then-write race the CAS exists to close.
			local uni, server = build()
			seed(uni, server, 70007)
			local key = "PLAYER_70007"
			local store = server.Bundle.Ctx.Persistence.Store

			-- The player comes back, and then the server dies holding the lock.
			local player = FakePlayer.new(70007)
			server:Join(70007, player)
			uni:Run(5)
			expect(record(uni, key).Value.MetaData.ActiveSession).never.to.equal(nil)
			server:Crash()

			local function attempt()
				local snap = record(uni, key).Value
				local outcome
				uni.Sched:Spawn(function()
					outcome = store:UpdateOfflineAsync(key, {
						SessionLoadCount = snap.MetaData.SessionLoadCount,
						LastUpdate = snap.MetaData.LastUpdate,
						WriteIndex = snap.MetaData.WriteIndex,
					}, { Coins = 42, _Scribe = snap.Data._Scribe }, { StaleSessionAfter = 630 })
				end)
				uni:Run(10)
				return outcome
			end

			local fresh = attempt()
			uni:Run(300)
			local halfway = attempt()
			uni:Run(400)
			local stale = attempt()

			expect(`fresh={fresh} at300={halfway} at700={stale} coins={record(uni, key).Value.Data.Coins}`).to.equal(
				"fresh=SessionActive at300=SessionActive at700=Written coins=42"
			)
		end)

		it("releases a session whose key was removed under it, and does not recreate the key", function()
			-- The Erase half of A6, and the brief's claim about it is REFUTED. A
			-- session starting inside Erase's window does NOT resurrect the profile:
			-- after RemoveAsync the key is absent, so the holder's next save enters
			-- UpdateAsync's missing-profile branch with no MetaData at all.
			--
			-- What it did instead was worse in a quieter way. Indexing MetaData threw
			-- INSIDE UpdateAsync's own pcall, so the save neither wrote nor released --
			-- and that repeated on every autosave. Measured before the fix: 200 virtual
			-- seconds at a 30 s autosave period and the session was still `Ready`,
			-- accepting writes it silently discarded, with no log line and no metric.
			--
			-- The fix is in the fork's save path rather than in Erase, because the
			-- wedge is reachable from ANY removal of a live key, not only from losing
			-- this race. A save that finds its key gone writes nothing and releases.
			local uni, server = build({
				Constants = {
					AUTO_SAVE_PERIOD = 30,
					SESSION_STEAL = 40,
					FIRST_LOAD_REPEAT = 5,
					ASSUME_DEAD = 630,
				},
			})
			local key = "PLAYER_70008"
			local store = server.Bundle.Ctx.Persistence.Store

			local player = FakePlayer.new(70008)
			server:Join(70008, player)
			uni:Run(3)
			server.Bundle.Data.Get(player).Coins.Set(4242)
			uni.Sched:Spawn(function()
				server.Bundle.Data.Flush(player)
			end)
			uni:Run(5)
			expect(record(uni, key).Value.Data.Coins).to.equal(4242)

			-- The erase wins the race: the key goes while the session is live.
			uni.Sched:Spawn(function()
				store:RemoveAsync(key)
			end)
			uni:Run(5)

			-- The holder plays on, and keeps autosaving.
			server.Bundle.Data.Get(player).Coins.Set(9999)
			uni:Run(200)

			local after = record(uni, key)
			expect(`present={after ~= nil and after.Value ~= nil} state={server.Bundle.Data.GetState(player)}`).to.equal(
				"present=false state=SessionEnded"
			)
		end)

		it("restores a version through the compare-and-set, and refuses one that would disown a session", function()
			-- RestoreVersion end to end against the REAL fork, which was unreachable
			-- until the disk model was repaired: test/Sim/Disk/Store.luau returned a
			-- nil keyInfo for a version read, so ProfileStore:GetAsync bailed,
			-- ListVersions returned {} and RestoreVersion could only ever answer
			-- "version not found". Measured before the repair: n=0 versions after a
			-- seeded write. The first assertion here is that gate.
			--
			-- Within one virtual hour the disk keeps ONE backup per key, tracking the
			-- latest write, so this cannot restore an OLDER value -- and does not need
			-- to. What is under test is the COMMIT: that it goes through the
			-- compare-and-set, stamps RestoredFrom, and refuses when the key has a live
			-- session rather than disowning it.
			local uni, server = build()
			seed(uni, server, 70009)
			local key = "PLAYER_70009"

			local out = {}
			uni.Sched:Spawn(function()
				out.Versions = server.Bundle.Data.ListVersions(70009, 5)
			end)
			uni:Run(20)
			expect(`versions={#(out.Versions or {})}`).to.equal("versions=1")

			uni.Sched:Spawn(function()
				out.Ok, out.Reason = server.Bundle.Data.RestoreVersion(70009, out.Versions[1].VersionId)
			end)
			uni:Run(20)

			local restoredFrom = record(uni, key).Value.Data._Scribe.RestoredFrom
			expect(`ok={out.Ok} stamped={restoredFrom ~= nil and restoredFrom.VersionId == out.Versions[1].VersionId}`).to.equal(
				"ok=true stamped=true"
			)

			-- ...and with the player back on the server, the same restore is refused.
			local player = FakePlayer.new(70009)
			server:Join(70009, player)
			uni:Run(5)
			uni.Sched:Spawn(function()
				out.Ok2, out.Reason2 = server.Bundle.Data.RestoreVersion(70009, out.Versions[1].VersionId)
			end)
			uni:Run(20)

			expect(
				`ok={out.Ok2} live={record(uni, key).Value.MetaData.ActiveSession ~= nil} `
					.. `state={server.Bundle.Data.GetState(player)}`
			).to.equal("ok=false live=true state=Ready")
		end)

		-- THE MONEY PROPERTY. Refusing is not enough; it must not touch the key,
		-- because clearing ActiveSession is what kicks the live player and rolls
		-- their session back to this snapshot.
		it("refuses while a session is live, and leaves the session intact", function()
			local uni, server = build()
			seed(uni, server, 70003)
			local key = "PLAYER_70003"
			local store = server.Bundle.Ctx.Persistence.Store
			local before = record(uni, key).Value

			-- The player comes back: the key now carries a live ActiveSession.
			local player = FakePlayer.new(70003)
			server:Join(70003, player)
			uni:Run(5)
			expect(record(uni, key).Value.MetaData.ActiveSession).never.to.equal(nil)

			local outcome
			uni.Sched:Spawn(function()
				outcome = store:UpdateOfflineAsync(key, {
					SessionLoadCount = before.MetaData.SessionLoadCount,
					LastUpdate = before.MetaData.LastUpdate,
					WriteIndex = before.MetaData.WriteIndex,
				}, { Coins = 1, _Scribe = before.Data._Scribe })
			end)
			uni:Run(10)

			expect(outcome).to.equal("SessionActive")
			-- The session survived, and the live player is still Ready.
			expect(record(uni, key).Value.MetaData.ActiveSession).never.to.equal(nil)
			expect(server.Bundle.Data.GetState(player)).to.equal("Ready")
		end)
	end)
end
