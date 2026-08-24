--!nonstrict
-- Can the REAL vendored ProfileStore run inside a simulated environment?
--
-- Everything downstream rests on this. If a per-server global table is enough to
-- give the library a virtual clock, a seeded scheduler and its own server
-- identity, then the simulation exercises the actual session-lock protocol. If it
-- is not, the alternative is a hand-written imitation of that protocol -- which
-- would be asserting the model against itself.
--
-- These specs deliberately use a trivial in-memory store rather than the modelled
-- Disk. The question here is whether the ENVIRONMENT holds; disk fidelity is a
-- separate concern with its own specs, and mixing them would make a failure in
-- either look like a failure in both.

local PROFILESTORE_PATH = "src/Internal/Store/ProfileStore.luau"

return function()
	local Root = script.Parent.Parent.Parent
	local Loader = require(Root.Test.Sim.Loader)
	local Env = require(Root.Test.Sim.Env)
	local Scheduler = require(Root.Test.Sim.Scheduler)
	local Rng = require(Root.Test.Sim.Rng)

	-- Sim-backed BY DEFAULT: building an environment is the thing this file is about,
	-- and only the headless runner can do it, so under Studio those nodes report SKIP
	-- rather than each failing the same way. See test/Sim/Available.
	--
	-- `itPortable` is the exception, kept deliberately narrow: exactly one node here
	-- asks a question about Loader.BaseEnv that needs no host capability at all, and
	-- it should keep running everywhere. Anything added to this file gets the gate
	-- unless someone opts it out on purpose.
	local itPortable = it
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP

	--- A store with no latency, no failures and no budget: enough for ProfileStore
	--- to make progress, and nothing more.
	local function stubDisk(shared)
		local function keyInfo(version, userIds)
			return {
				Version = tostring(version),
				CreatedTime = 0,
				UpdatedTime = 0,
				GetUserIds = function()
					return userIds or {}
				end,
				GetMetadata = function()
					return {}
				end,
			}
		end

		local store = {}
		store.__index = store

		function store:UpdateAsync(key, transform)
			-- Every real DataStore call yields, and a store that returned
			-- synchronously would hide every interleaving worth finding.
			self._wait()
			local bucket = shared[self._name]
			if bucket == nil then
				bucket = {}
				shared[self._name] = bucket
			end
			local entry = bucket[key]
			local value, userIds =
				transform(entry and entry.Value or nil, keyInfo(entry and entry.Version or 0, entry and entry.UserIds))
			if value == nil then
				return nil, keyInfo(entry and entry.Version or 0)
			end
			local version = (entry and entry.Version or 0) + 1
			bucket[key] = { Value = value, Version = version, UserIds = userIds }
			return value, keyInfo(version, userIds)
		end

		function store:GetAsync(key)
			self._wait()
			local entry = shared[self._name] and shared[self._name][key]
			if entry == nil then
				return nil, nil
			end
			return entry.Value, keyInfo(entry.Version, entry.UserIds)
		end

		function store:RemoveAsync(key)
			self._wait()
			if shared[self._name] then
				shared[self._name][key] = nil
			end
			return true
		end

		function store:ListVersionsAsync()
			self._wait()
			return {
				GetCurrentPage = function()
					return {}
				end,
				IsFinished = true,
				AdvanceToNextPageAsync = function() end,
			}
		end

		function store:GetVersionAsync()
			self._wait()
			return nil, nil
		end

		return function(wait)
			return {
				GetDataStore = function(_self, name)
					return setmetatable({ _name = name, _wait = wait }, store)
				end,
				GetOrderedDataStore = function(_self, name)
					return setmetatable({ _name = name, _wait = wait }, store)
				end,
				GetRequestBudgetForRequestType = function()
					return 1000
				end,
			}
		end
	end

	--- Build one simulated server's ProfileStore instance.
	local function newServer(sched, shared, jobId, seed)
		local built = Env.Build({
			Sched = sched,
			Disk = nil,
			Bus = nil,
			Rng = Rng.Stream(seed, "guid." .. jobId),
			JobId = jobId,
		})
		built.Services.DataStoreService = stubDisk(shared)(function()
			sched:Wait(0.05)
		end)
		built.Services.MessagingService = {
			SubscribeAsync = function()
				sched:Wait(0.05)
				return { Disconnect = function() end }
			end,
			PublishAsync = function()
				sched:Wait(0.05)
			end,
		}

		local ProfileStore = Loader.LoadChunk(Loader.Source(PROFILESTORE_PATH), built.Globals, `ProfileStore@{jobId}`)
		return { PS = ProfileStore, Built = built }
	end

	--- Fire every server's Heartbeat once. ProfileStore's autosave engine hangs
	--- off it, so nothing periodic happens unless the universe drives it.
	local function tick(servers)
		for _, server in servers do
			for _, handler in server.Built.HeartbeatHandlers do
				handler(1 / 60)
			end
		end
	end

	describe("ProfileStore under a simulated environment", function()
		it("loads two instances that are genuinely independent", function()
			local sched = Scheduler.new(1)
			local shared = {}
			local a = newServer(sched, shared, "server-A", 1)
			local b = newServer(sched, shared, "server-B", 1)

			expect(a.PS).never.to.equal(b.PS)
			-- Not shared state wearing two names: each carries its own module
			-- globals, which is what makes them separate servers rather than one
			-- server counted twice.
			expect(a.PS.OnError).never.to.equal(b.PS.OnError)
		end)

		it("resolves DataStoreState to Access synchronously at load", function()
			-- IsStudio is pinned false so the module skips its API-access probe.
			-- If this ever became "NotReady", every store would defer its
			-- construction into a task.spawn and the first session would hang.
			local sched = Scheduler.new(1)
			local server = newServer(sched, {}, "server-A", 1)
			expect(server.PS.DataStoreState).to.equal("Access")
		end)

		it("runs a whole session on virtual time", function()
			local sched = Scheduler.new(1)
			local shared = {}
			local server = newServer(sched, shared, "server-A", 1)
			local store = server.PS.New("SimStore", { Coins = 0 })

			local profile
			sched:Spawn(function()
				profile = store:StartSessionAsync("player_1", {
					Cancel = function()
						return false
					end,
				})
			end)
			sched:Run(sched.Now + 60)

			expect(profile).never.to.equal(nil)
			expect(profile.Data.Coins).to.equal(0)

			profile.Data.Coins = 250
			sched:Spawn(function()
				profile:EndSession()
			end)
			sched:Run(sched.Now + 60)

			expect(shared.SimStore.player_1.Value.Data.Coins).to.equal(250)
		end)

		it("holds a session lock the other server can see", function()
			local sched = Scheduler.new(7)
			local shared = {}
			local a = newServer(sched, shared, "server-A", 1)
			local storeA = a.PS.New("SimStore", { Coins = 0 })

			sched:Spawn(function()
				local profile = storeA:StartSessionAsync("player_1", {
					Cancel = function()
						return false
					end,
				})
				profile.Data.Coins = 100
				profile:Save()
			end)
			sched:Run(sched.Now + 60)

			local session = shared.SimStore.player_1.Value.MetaData.ActiveSession
			expect(session).never.to.equal(nil)
			expect(session[1]).to.equal(Env.PLACE_ID)
			expect(session[2]).to.equal("server-A")
		end)

		it("passes ProfileStore's Enum guard on VersionQuery", function()
			-- The measurement that decides whether version reads are reachable at
			-- all. ProfileStore rejects a sort direction unless typeof() answers
			-- "EnumItem" AND EnumType is identity-equal to the enum object. A
			-- string EnumType fails; so does the object alone. Scribe reaches this
			-- guard through Persistence's version-history path, so a sim that
			-- failed it would report a broken feature that works in production --
			-- diverging in the one direction a simulation must never diverge.
			local sched = Scheduler.new(1)
			local server = newServer(sched, {}, "server-A", 1)
			local store = server.PS.New("SimStore", { Coins = 0 })

			local query, err
			sched:Spawn(function()
				local ok, result = pcall(function()
					return store:VersionQuery("player_1", Enum.SortDirection.Descending)
				end)
				query, err = result, if ok then nil else result
			end)
			sched:Run(sched.Now + 60)

			expect(err).to.equal(nil)
			expect(query).never.to.equal(nil)
		end)

		it("gives every server ONE wall clock but its own monotonic clock", function()
			-- os.time is shared on purpose. ProfileStore's dead-session recovery
			-- compares a LastUpdate written by a DIFFERENT server against this
			-- server's os.time; per-server wall clocks would make that a comparison
			-- between unrelated number lines, and a crashed server's key would
			-- either never look stale or always look stale.
			--
			-- os.clock is per-server for the opposite reason: real servers do not
			-- agree on it, and code that assumes they do is a bug worth expressing.
			local sched = Scheduler.new(1)
			local a = Env.Build({ Sched = sched, Rng = Rng.new(1), JobId = "A", ClockSkew = 0 })
			local b = Env.Build({ Sched = sched, Rng = Rng.new(1), JobId = "B", ClockSkew = 500 })

			expect(a.Globals.os.time()).to.equal(b.Globals.os.time())
			expect(b.Globals.os.clock() - a.Globals.os.clock()).to.equal(500)
		end)

		it("makes an argumentless task.wait cost a frame, not nothing", function()
			-- ProfileStore waits out a session conflict with
			--   repeat task.wait() until os.clock() >= wait_until
			-- Virtual time only advances when nothing is runnable, so a free yield
			-- there is an infinite loop: the thread is always runnable, the clock
			-- never moves, and the condition never becomes true.
			local sched = Scheduler.new(1)
			local built = Env.Build({ Sched = sched, Rng = Rng.new(1), JobId = "A" })
			local before = sched.Now
			sched:Spawn(function()
				built.Globals.task.wait()
			end)
			sched:Run()
			expect(sched.Now > before).to.equal(true)
		end)

		it("terminates ProfileStore's conflict wait loop", function()
			-- The same property, exercised through the real loop rather than a
			-- single call: B contends for a key A holds, which is the code path
			-- that spins forever on a free yield (measured: 400,000 steps, 1.20
			-- virtual seconds, never acquiring).
			local sched = Scheduler.new(11)
			local shared = {}
			local a = newServer(sched, shared, "server-A", 1)
			local b = newServer(sched, shared, "server-B", 2)

			-- Set on each instance separately -- they are independent modules, and
			-- that this is necessary is itself the isolation being relied on.
			for _, server in { a, b } do
				server.PS.SetConstant("SESSION_STEAL", 10)
				server.PS.SetConstant("FIRST_LOAD_REPEAT", 2)
				server.PS.SetConstant("LOAD_REPEAT_PERIOD", 3)
				-- Also the autosave period, and NOT incidentally. The handoff is
				-- cooperative: B marks the key for force-load, and A only notices
				-- the next time it SAVES. Left at the 300s default, A would not look
				-- until five virtual minutes had passed -- with no message bus here
				-- to nudge it sooner -- and the wait would read as a spin.
				server.PS.SetConstant("AUTO_SAVE_PERIOD", 20)
			end

			local storeA = a.PS.New("SimStore", { Coins = 0 })
			local storeB = b.PS.New("SimStore", { Coins = 0 })

			local profileA
			sched:Spawn(function()
				profileA = storeA:StartSessionAsync("player_1", {
					Cancel = function()
						return false
					end,
				})
				profileA.Data.Coins = 100
				profileA:Save()
			end)
			sched:Run(sched.Now + 30)
			expect(profileA).never.to.equal(nil)

			-- B now contends. Both servers keep ticking, because the handoff is
			-- cooperative: A only notices on a Heartbeat-driven save.
			local profileB
			sched:Spawn(function()
				profileB = storeB:StartSessionAsync("player_1", {
					Cancel = function()
						return false
					end,
				})
			end)
			local startedAt = sched.Now
			sched:Spawn(function()
				while sched.Now - startedAt < 600 and profileB == nil do
					sched:Wait(1)
					tick({ a, b })
				end
			end)
			sched:Run(startedAt + 601)

			expect(sched.Stalled).to.equal(false)
			expect(profileB).never.to.equal(nil)
			-- B inherited what A had written, rather than a fresh template.
			expect(profileB.Data.Coins).to.equal(100)
			-- ...and A knows it lost the session.
			expect(profileA:IsActive()).to.equal(false)
		end)

		it("leaves no thread unaccounted for after a contended handoff", function()
			-- ProfileStore parks threads on its per-key update queue with a raw
			-- coroutine.yield and wakes them with a raw coroutine.resume. The kernel
			-- cannot see either, so unless the environment routes coroutine.resume
			-- through ResumeRaw, every such thread leaks a Live count -- and a run
			-- with Live > 0 and nothing runnable is reported as a DEADLOCK. Without
			-- the routing, a perfectly clean run would fail its own liveness gate.
			local sched = Scheduler.new(5)
			local shared = {}
			local server = newServer(sched, shared, "server-A", 1)
			local store = server.PS.New("SimStore", { Coins = 0 })

			local profile
			sched:Spawn(function()
				profile = store:StartSessionAsync("player_1", {
					Cancel = function()
						return false
					end,
				})
			end)
			sched:Run(sched.Now + 30)
			expect(profile).never.to.equal(nil)

			-- Concurrent saves on one key: exactly what the update queue serialises.
			for i = 1, 6 do
				sched:Spawn(function()
					profile.Data.Coins = i * 10
					profile:Save()
				end)
			end
			sched:Run(sched.Now + 120)

			sched:Spawn(function()
				profile:EndSession()
			end)
			sched:Run(sched.Now + 120)

			expect(sched.Live).to.equal(0)
			expect(sched.Deadlocked).to.equal(false)
			expect(sched:Settled()).to.equal(true)
		end)
		it("routes the environment's coroutine.resume through the kernel", function()
			-- Tested at the wiring rather than through ProfileStore, because the leak
			-- only bites when a resumed thread DIES INSIDE the foreign resume. In a
			-- queued save it does not -- it resumes, issues its update, and yields
			-- again on the disk -- so the scenario that looks like the obvious test
			-- passes whether the wiring is there or not.
			--
			-- What must hold is simply that a thread woken through the environment's
			-- coroutine.resume is accounted for. ProfileStore hands its update queue
			-- off exactly this way.
			local sched = Scheduler.new(1)
			local built = Env.Build({ Sched = sched, Rng = Rng.new(1), JobId = "A" })

			local parked
			built.Globals.task.spawn(function()
				parked = coroutine.running()
				coroutine.yield()
				-- returns immediately on resume, so it dies INSIDE that resume
			end)
			expect(sched.Live).to.equal(1)

			built.Globals.coroutine.resume(parked)
			expect(sched.Live).to.equal(0)
			expect(sched:Settled()).to.equal(true)
		end)

		itPortable("withholds every per-server global from the base environment", function()
			-- BaseEnv omits these on purpose. Each is per-server -- the clock, the
			-- scheduler, the server identity -- and a default would hand a simulated
			-- server the REAL one silently. An omission fails loudly at the first
			-- use; a default returns a confident wrong answer forever.
			local base = Loader.BaseEnv()
			for _, name in { "os", "task", "game", "typeof", "Enum", "Instance", "script", "require" } do
				expect(base[name]).to.equal(nil)
			end
			-- ...while the stdlib it DOES provide is present.
			expect(base.table).to.equal(table)
			expect(base.coroutine).to.equal(coroutine)
		end)
		it("gives each cache its own copy of a module", function()
			-- What makes two simulated servers two servers. Scribe keeps Health's
			-- failure counters in module locals, so a shared copy would let one
			-- server's DataStore failures trip another server's outage detector --
			-- and at high CCU a faithful throttle model would flip the whole fleet
			-- at once, disqualifying every finding that depends on Health.
			local cacheA, cacheB = Loader.NewCache(), Loader.NewCache()

			local rngA = Loader.RequireFresh(Root.Test.Sim.Rng, cacheA)
			local rngB = Loader.RequireFresh(Root.Test.Sim.Rng, cacheB)
			expect(rngA).never.to.equal(rngB)

			-- ...and neither is the harness's own copy.
			expect(rngA).never.to.equal(Rng)

			-- Within one cache a module is required once, as Roblox does it.
			expect(Loader.RequireFresh(Root.Test.Sim.Rng, cacheA)).to.equal(rngA)

			-- The fresh copies still work.
			expect(rngA.new(5):NextInteger(100)).to.equal(rngB.new(5):NextInteger(100))
		end)
		it("fast-forwards ProfileStore's own autosave deadline", function()
			-- ProfileStore measures AUTO_SAVE_PERIOD against its own os.clock,
			-- inside a vendored module Scribe's Clock seam cannot reach. The whole
			-- point of a per-server environment is that this still fast-forwards.
			local sched = Scheduler.new(1)
			local shared = {}
			local servers = { newServer(sched, shared, "server-A", 1) }
			servers[1].PS.SetConstant("AUTO_SAVE_PERIOD", 60)
			local store = servers[1].PS.New("SimStore", { Coins = 0 })

			local profile
			sched:Spawn(function()
				profile = store:StartSessionAsync("player_1", {
					Cancel = function()
						return false
					end,
				})
			end)
			sched:Run(sched.Now + 60)
			expect(profile).never.to.equal(nil)

			profile.Data.Coins = 777

			-- Drive Heartbeat across ten virtual minutes.
			local startedAt = sched.Now
			sched:Spawn(function()
				while sched.Now - startedAt < 600 do
					sched:Wait(1)
					tick(servers)
				end
			end)
			sched:Run(startedAt + 601)

			expect(sched.Now >= startedAt + 600).to.equal(true)
			-- An autosave landed without anyone calling Save().
			expect(shared.SimStore.player_1.Value.Data.Coins).to.equal(777)
		end)

		it("still reports a DataStore failure that lands AFTER the transform declined", function()
			-- The `success == true` half of UpdateAsync's decline branch, which is the
			-- one thing keeping an OUTAGE from hiding behind a refusal.
			--
			-- That branch reads `success == true and transform_params.AbortWrite == true`
			-- -> return nil quietly. Drop the first half and any call whose transform
			-- happened to decline stops being reported, however badly the call then
			-- failed: DataStoreErrors stops counting, Health stops degrading, and a
			-- genuine outage is invisible for as long as refusals keep occurring. The
			-- comment on that branch says so; nothing held it, and dropping the half
			-- left the whole suite green.
			--
			-- Not reachable through test/Sim/Disk: its fault model draws BEFORE the
			-- transform runs and raises immediately, so the transform never gets to
			-- decline. The combination needs a store that invokes the transform and
			-- THEN fails -- Roblox's "Unresolved" class, a response lost after the
			-- server already applied it. That is what this stub is.
			local sched = Scheduler.new(1)
			local built = Env.Build({
				Sched = sched,
				Disk = nil,
				Bus = nil,
				Rng = Rng.Stream(9, "guid.lost"),
				JobId = "lost-response",
			})
			built.Services.MessagingService = {
				SubscribeAsync = function()
					sched:Wait(0.05)
					return { Disconnect = function() end }
				end,
				PublishAsync = function()
					sched:Wait(0.05)
				end,
			}
			local transformRan = false
			built.Services.DataStoreService = {
				GetDataStore = function()
					return {
						UpdateAsync = function(_self, _key, transform)
							sched:Wait(0.05)
							-- A profile whose fingerprint cannot match what the caller
							-- passes below, so the transform declines with "Changed".
							transform({
								Data = {},
								MetaData = {
									ProfileCreateTime = 0,
									SessionLoadCount = 9,
									LastUpdate = 9,
									WriteIndex = 9,
									ActiveSession = nil,
									ForceLoadSession = nil,
									MetaTags = {},
								},
								GlobalUpdates = { 0, {} },
							})
							transformRan = true
							error("DataStoreService: 504: Datastore request timed out", 0)
						end,
					}
				end,
				GetRequestBudgetForRequestType = function()
					return 100
				end,
			}

			local ProfileStore = Loader.LoadChunk(Loader.Source(PROFILESTORE_PATH), built.Globals, "ProfileStore@lost")
			local errors = 0
			ProfileStore.OnError:Connect(function()
				errors += 1
			end)

			local outcome
			sched:Spawn(function()
				local store = ProfileStore.New("Lost", { Coins = 0 })
				outcome = store:UpdateOfflineAsync("player_lost", {
					SessionLoadCount = 1,
					LastUpdate = 1,
					WriteIndex = 1,
				}, { Coins = 5 })
			end)
			sched:Run(sched.Now + 10)

			-- transformRan is the anti-vacuity guard: without it a store that failed
			-- BEFORE the transform would satisfy the error count for the ordinary
			-- reason and pin nothing.
			expect(`transformRan={transformRan} outcome={tostring(outcome)} errors={errors}`).to.equal(
				"transformRan=true outcome=Changed errors=1"
			)
		end)
	end)
end
