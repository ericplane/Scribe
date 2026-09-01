--!nonstrict
-- A complete, PRIVATE Scribe instance for one simulated server.
--
-- The freshness is the point. Scribe keeps real module-level state -- Health's
-- failure counters are plain locals, and a handful of failures inside a minute
-- flips the whole bundle to Outage, which gates the money paths. Share one Scribe
-- across N simulated servers and any faithful throttle model trips the entire
-- fleet at once, disqualifying every finding that touches Health at exactly the
-- CCU the study is about. Fresh copies cost about 17 ms each; that is the whole
-- price of the isolation.
--
-- NOTE WHAT IS *NOT* VIRTUALISED HERE, and why that is sound. ProfileStore needs a
-- fully virtual `os` and `task` because it is vendored and unseamed. Scribe does
-- not: every reading of time, every thread start and every random draw in src/
-- already routes through Internal/Clock, Internal/Sched and Internal/Rng, and CI
-- has a gate per seam that fails the build if a raw one reappears. So a simulated
-- Scribe gets the ordinary harness globals plus an Install() on ITS OWN copies of
-- those three seam modules -- and because the copies are private, installing does
-- not disturb any other server or any other spec.
--
-- The Rng stream is named per server (`jitter.<JobId>`) rather than derived as
-- seed + n. Rng.Stream mixes the label in, so two servers get genuinely
-- independent sequences; adjacent bare seeds would start one step apart in the
-- SAME sequence, which is exactly the correlation jitter exists to remove. A
-- fleet whose jitter is correlated models the herd as less severe than it is,
-- and that is the one direction this simulation must never err in.

local Loader = require(script.Parent.Loader)

local SimHost = __SimHost

local Bundle = {}
Bundle.__index = Bundle

--- Globals for a freshly-loaded Scribe module tree.
---
--- Copied from the harness's own, minus the two the loader must own: `require`
--- has to resolve through the private cache, and `script` is per module.
local function scribeGlobals()
	local env = {}
	for key, value in SimHost.BaseGlobals do
		if key ~= "require" and key ~= "script" then
			env[key] = value
		end
	end
	return env
end

--- A minimal RBXScriptSignal for one bundle's frame loop.
---
--- Fires SYNCHRONOUSLY on the calling thread, unlike the harness's own FakeSignal
--- which spawns each handler with Lune's real `task.spawn`. That difference is the
--- whole reason this exists: a handler spawned on a real Lune thread runs outside
--- the virtual scheduler, so a simulated server's flush would happen at wall-clock
--- time in an order the seed does not control -- and bit-for-bit replay is the one
--- property this simulation cannot trade away.
local function newFrameSignal()
	local handlers = {}
	local signal = {}
	function signal.Connect(_self: any, fn: (...any) -> ())
		local connection
		connection = {
			Connected = true,
			Disconnect = function()
				connection.Connected = false
				for index, handler in handlers do
					if handler == fn then
						table.remove(handlers, index)
						break
					end
				end
			end,
		}
		table.insert(handlers, fn)
		return connection
	end
	signal.connect = signal.Connect
	-- Errors are CAUGHT and COLLECTED, not raised and not swallowed, and both
	-- alternatives are worse in a way that matters here:
	--
	--   * raising propagates out of Server.Heartbeat into the universe's single
	--     tick-driver thread, killing it while Universe._ticking stays true -- so
	--     ensureTicking never restarts it and every later Run in that spec ticks
	--     nothing, silently.
	--   * swallowing (what the harness's own FakeSignal does, via task.spawn) means
	--     a throw inside the flush loop vanishes into stdout and the suite stays
	--     green -- which is the exact class of failure this whole tier exists to
	--     remove, reintroduced one layer down.
	--
	-- Roblox runs each bound handler independently, so one erroring must not stop
	-- the others; `Errors` is what a spec (or Guard) asserts is empty.
	local errors = {}
	function signal.Fire(_self: any, ...)
		-- Cloned before iterating: a handler that disconnects itself mid-fire would
		-- otherwise make the loop skip its neighbour.
		for _, fn in table.clone(handlers) do
			local ok, err = pcall(fn, ...)
			if not ok then
				table.insert(errors, tostring(err))
			end
		end
	end
	return signal, errors
end

--- A `game` for one bundle: the harness's, with a PRIVATE RunService.
---
--- Only RunService is replaced, and only its frame signals. Everything else
--- forwards, which matters more than it looks: test/Sim/Guard installs the
--- simulation's disk into the SHARED harness DataStoreService, and
--- src/Internal/Budget.luau:53 re-resolves that service on every call. A proxy
--- that rebuilt the service table instead of forwarding to it would hand Scribe a
--- DataStoreService with no disk behind it, and that surfaces as budget snapshots
--- quietly reporting "unavailable" rather than as an error.
---
--- Why a private signal at all: Scribe's replication flush loop is
--- `RunService.PostSimulation:Connect` (src/Server/Replication.luau:319). With the
--- harness's shared signal every simulated server in every universe hangs off ONE
--- object, so firing it would flush unrelated servers -- and nothing in the
--- simulation fires it, which is half of why replication has never run here.
local function bundleGame(jobId: string?)
	local baseGame = SimHost.BaseGlobals.game
	local baseRun = baseGame:GetService("RunService")
	local frame, errors = newFrameSignal()

	-- __index rather than a copy: IsStudio/IsServer/IsRunning must keep answering
	-- exactly what the harness answers.
	--
	-- PostSimulation ONLY. Aliasing Heartbeat to the same private signal looks
	-- harmless -- nothing in src/ outside the vendored store connects to it -- and
	-- is a live trap: the day a Bundle is built without an injected ProfileStore,
	-- Persistence falls through to require(Internal.Store), which loads a SECOND
	-- vendored store whose globals are the harness's (harness DataStoreService,
	-- harness JobId, the wrong disk) and whose entire autosave engine would then
	-- hang off this bundle's private frame. That is a phantom server, and it would
	-- look like it was working.
	local runService = setmetatable({ PostSimulation = frame }, { __index = baseRun })

	local proxy: any = setmetatable({
		-- Read off `game` directly by src/Server/Persistence.luau:3354 and :3427.
		-- Per-server here, where the harness has one value for the whole process: a
		-- fleet whose servers all report the same JobId cannot express a handoff.
		JobId = jobId or baseGame.JobId,
		GetService = function(_self: any, name: string)
			if name == "RunService" then
				return runService
			end
			return baseGame:GetService(name)
		end,
	}, { __index = baseGame })

	return proxy, frame, errors
end

export type Config = {
	Sched: any,
	Rng: any, -- that server's private jitter stream (test/Sim/Rng)
	Template: { [string]: any }?,
	Options: { [string]: any }?,
	ProfileStore: any, -- that server's ProfileStore module instance
	Transport: any,
	JobId: string?,
}

--- Build one server's Scribe.
function Bundle.new(config: Config)
	-- Checked before anything is built, so the message names the omission rather
	-- than whatever fails first downstream of it. A bundle without a stream still
	-- RUNS -- it falls back to Scribe's production generator, seeded from wall time
	-- and a JobId the harness does not set -- so every replay would differ and the
	-- digest specs would fail somewhere far from the cause.
	if config.Rng == nil then
		error("Bundle.new requires an Rng stream; without one the run is not replayable")
	end

	local root = SimHost.Root
	local cache = Loader.NewCache()
	local overrides = scribeGlobals()
	local gameProxy, frameSignal, frameErrors = bundleGame(config.JobId)
	overrides.game = gameProxy

	local Scribe = Loader.RequireFresh(root.Scribe, cache, overrides)
	local Template = Loader.RequireFresh(root.Scribe.Internal.Template, cache, overrides)
	local Server = Loader.RequireFresh(root.Scribe.Server, cache, overrides)
	local Clock = Loader.RequireFresh(root.Scribe.Internal.Clock, cache, overrides)
	local Sched = Loader.RequireFresh(root.Scribe.Internal.Sched, cache, overrides)
	local Rng = Loader.RequireFresh(root.Scribe.Internal.Rng, cache, overrides)
	local Health = Loader.RequireFresh(root.Scribe.Internal.Health, cache, overrides)
	-- Exported for the same reason Health is: Failure keeps module-level state (the
	-- log fold rides on Health's per-identity tally), so a spec that drives it has to
	-- drive THIS server's private copy or it is measuring whatever ran before it.
	local Failure = Loader.RequireFresh(root.Scribe.Internal.Failure, cache, overrides)

	-- Bind THIS copy's seams to the simulation clock. Private modules, so nothing
	-- outside this server observes the change and no reset can be forgotten by a
	-- spec that never knew it was installed.
	Clock.Install(config.Sched:ClockImpl())
	Sched.Install(config.Sched:SchedImpl())
	local stream = config.Rng
	Rng.Install({
		Next = function()
			return stream:NextNumber()
		end,
	})

	local options: { [string]: any } = {
		Template = config.Template or {
			Coins = Scribe.Int(0, { Min = 0 }),
			Level = Scribe.Int(1, { Min = 1 }),
		},
		Transport = config.Transport,
		ProfileStore = config.ProfileStore,
		ProfileStoreIndex = "Default",
		ProfileKeyPrefix = "PLAYER_",
		-- "Live" is the only mode that exercises what the simulation is for. Mock
		-- swaps in ProfileStore's in-memory store, and NoSave produces HALF-real
		-- traffic -- profiles stay real while leaderboards mock out -- which would
		-- silently exclude every OrderedDataStore request from a capacity study.
		Mode = "Live",
		OwnReceipts = false,
		KickOnSessionEnd = false,
		LogLevel = "Fatal",
		Banner = false,
	}
	for key, value in config.Options or {} do
		options[key] = value
	end

	local purchaseLog = options.PurchaseLog or {}
	local compiled = Template.Compile(options.Template, {
		ReplicateRobuxLog = purchaseLog.ReplicateRobux == true,
		ReplicateInGameLog = purchaseLog.ReplicateInGame == true,
		ServerStore = options.ServerStore,
	})

	-- build, not new: `new` also wires PlayerAdded/BindToClose to the real engine
	-- singletons, which are shared across every simulated server here.
	local Data, ctx = Server.build(options, compiled)

	return setmetatable({
		Scribe = Scribe,
		Data = Data,
		Ctx = ctx,
		Compiled = compiled,
		Options = options,
		Clock = Clock,
		Sched = Sched,
		Rng = Rng,
		Health = Health,
		Failure = Failure,
		FrameSignal = frameSignal,
		-- Anything the flush loop threw this run. Empty is the invariant; Guard
		-- asserts it so no spec has to remember to.
		FrameErrors = frameErrors,
		_config = config,
		_root = root,
		_cache = cache,
		_overrides = overrides,
	}, Bundle)
end

--- Fire this bundle's PostSimulation once: one frame of Scribe's REAL replication
--- flush loop.
---
--- Hand-calling Ctx.Replication.FlushEntry would be easier, and is exactly what
--- the non-sim harness used to do -- until someone measured that the production
--- loop, including its iteration over every entry, had executed zero times under
--- the whole suite. This drives the loop itself, for the same reason.
function Bundle.Step(self, dt: number?)
	self.FrameSignal:Fire(dt or 1 / 60)
end

--- The client REALM for this server: a second, independent module tree.
---
--- A client is a different Lua VM in production, and building one out of the
--- server's cache is not a shortcut, it is a wrong model with teeth. Measured on
--- the first version of this file:
---
---   * `Client.GetServiceStatus()` is literally `return Health.GetStatus()`
---     (src/Client/init.luau:610). Sharing the cache means it reads the SERVER's
---     Health, so it answered correctly with the transport disconnected -- a
---     status assertion that cannot fail.
---   * Worse in the other direction: a Status frame makes the client call
---     `Health.AdoptBroadcast` (src/Client/init.luau:240), which is `setStatus`
---     (src/Internal/Health.luau:326) and fires `OnStatusChanged` -- which
---     src/Server/Replication.luau:628 has wired to BroadcastStatus. A client
---     could therefore drive its own server into Outage, and Outage is the gate on
---     gifts, restores, erases and receipts. This file's header says the
---     per-server isolation exists for exactly this module.
---   * `Metrics` and `Log` are module locals too, so client counters landed in the
---     namespace six sim specs read, and a client built with LogLevel="Debug"
---     un-silenced the server's logger for the rest of the run.
---
--- So the client half gets its own cache, its own Clock/Sched/Rng installs and its
--- own compiled template. The template is COMPILED SEPARATELY on purpose: that is
--- what production does, and it means the handshake's schema-hash check is
--- actually exercised rather than trivially satisfied by a shared table.
---
--- One cache for all of a server's clients, not one per client. Per-client would
--- be the fully faithful model, but a fresh module tree costs ~17 ms and a server
--- has tens of players. The cost of that compromise is stated rather than hidden:
--- two clients on one simulated server cannot disagree about service status.
function Bundle.ClientRealm(self)
	if self._clientRealm then
		return self._clientRealm
	end
	local root = self._root
	local cache = Loader.NewCache()
	local overrides = table.clone(self._overrides)

	-- A client answers IsClient/IsServer the other way round. Not cosmetic:
	-- Transport.Resolve (src/Internal/Transport.luau:111) picks WHICH adapter
	-- members it validates from RunService:IsServer(), so a shared-realm client was
	-- being validated as a server. Flipping it means the simulation exercises the
	-- branch a real client takes.
	local baseGame = SimHost.BaseGlobals.game
	local baseRun = baseGame:GetService("RunService")
	local clientRun = setmetatable({
		IsServer = function()
			return false
		end,
		IsClient = function()
			return true
		end,
	}, { __index = baseRun })
	overrides.game = setmetatable({
		GetService = function(_self: any, name: string)
			if name == "RunService" then
				return clientRun
			end
			return baseGame:GetService(name)
		end,
	}, { __index = baseGame })

	local Client = Loader.RequireFresh(root.Scribe.Client, cache, overrides)
	local Template = Loader.RequireFresh(root.Scribe.Internal.Template, cache, overrides)
	local Clock = Loader.RequireFresh(root.Scribe.Internal.Clock, cache, overrides)
	local Sched = Loader.RequireFresh(root.Scribe.Internal.Sched, cache, overrides)
	local Rng = Loader.RequireFresh(root.Scribe.Internal.Rng, cache, overrides)
	local Health = Loader.RequireFresh(root.Scribe.Internal.Health, cache, overrides)
	local Metrics = Loader.RequireFresh(root.Scribe.Internal.Metrics, cache, overrides)

	local sched = self._config.Sched
	Clock.Install(sched:ClockImpl())
	Sched.Install(sched:SchedImpl())
	-- Its own named stream. The client's Hello retry is Clock.Wait(Rng.Jitter(n))
	-- (src/Client/init.luau:334); drawn from the server's `jitter.<JobId>` stream it
	-- would renumber every save-retry draw behind it, so the same seed with and
	-- without a client would schedule saves differently -- and the divergence would
	-- be blamed on replication.
	local stream = self._config.ClientRng
	if stream ~= nil then
		Rng.Install({
			Next = function()
				return stream:NextNumber()
			end,
		})
	end

	local purchaseLog = self.Options.PurchaseLog or {}
	local compiled = Template.Compile(self.Options.Template, {
		ReplicateRobuxLog = purchaseLog.ReplicateRobux == true,
		ReplicateInGameLog = purchaseLog.ReplicateInGame == true,
	})

	self._clientRealm = {
		Client = Client,
		Compiled = compiled,
		Clock = Clock,
		Sched = Sched,
		Rng = Rng,
		Health = Health,
		Metrics = Metrics,
	}
	return self._clientRealm
end

--- A real Scribe Client for one player on this server, in the client realm.
function Bundle.NewClient(self, transportAdapter: any, overrides: { [string]: any }?)
	local realm = self:ClientRealm()
	local options = table.clone(self.Options)
	options.Transport = transportAdapter
	for key, value in overrides or {} do
		options[key] = value
	end
	return realm.Client.new(options, realm.Compiled)
end

--- Release the seams this bundle installed.
---
--- Private copies, so this is tidiness rather than isolation -- but a bundle that
--- outlives its scheduler while still holding a virtual clock would report times
--- from a run that has already ended.
function Bundle.Teardown(self)
	if self.Data and self.Data.Stop then
		pcall(function()
			self.Data.Stop()
		end)
	end
	self.Clock.Reset()
	self.Sched.Reset()
	self.Rng.Reset()
	local realm = self._clientRealm
	if realm then
		realm.Clock.Reset()
		realm.Sched.Reset()
		realm.Rng.Reset()
	end
end

return Bundle
