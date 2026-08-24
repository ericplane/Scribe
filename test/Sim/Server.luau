--!nonstrict
-- One simulated Roblox server: its own ProfileStore instance, its own Scribe, its
-- own JobId, sharing one key space and one message bus with every other server.

local Loader = require(script.Parent.Loader)
local Env = require(script.Parent.Env)
local Bundle = require(script.Parent.Bundle)
local Link = require(script.Parent.Link)
local Rng = require(script.Parent.Rng)

-- Scribe's own vendored fork, not the Wally package -- the simulation has to
-- exercise the store that actually ships. Loaded as raw source rather than
-- required so each simulated server gets a private copy of the module state
-- (AutoSaveList, ActiveSessionCheck, DataStoreState) instead of one shared
-- singleton pretending to be a fleet.
local PROFILESTORE_PATH = "src/Internal/Store/ProfileStore.luau"

local SimHost = __SimHost

local Server = {}
Server.__index = Server

function Server.new(config)
	local sched = config.Sched

	local built = Env.Build({
		Sched = sched,
		Disk = config.Disk,
		Bus = config.Bus,
		Rng = Rng.Stream(config.Seed or 1, `guid.{config.JobId}`),
		JobId = config.JobId,
		PlaceId = config.PlaceId,
		ClockSkew = config.ClockSkew,
	})

	local Module = Loader.LoadChunk(Loader.Source(PROFILESTORE_PATH), built.Globals, `ProfileStore@{config.JobId}`)

	-- Per instance, because the instances are independent modules -- which is
	-- exactly the isolation the whole design rests on. Shortened deadlines let a
	-- bounded run reach conflict resolution and dead-session recovery, which at
	-- production values take 40 and 630 seconds.
	for name, value in config.Constants or {} do
		Module.SetConstant(name, value)
	end

	-- A private link ONLY when the caller did not bring a transport. Every
	-- pre-existing sim spec passes a StubTransport, so their wiring is untouched;
	-- a spec that wants clients simply omits Transport and gets one link per
	-- server, which is the shape a fleet actually has. Sharing one transport across
	-- N servers -- what Universe does with a supplied one -- cannot host clients at
	-- all: server 1's outbound frames and server 2's land in the same queue.
	local link = if config.Transport == nil
		then Link.new({
			Name = `link.{config.JobId}`,
			MaxFrameBytes = config.MaxFrameBytes,
			MaxFramesPerPump = config.MaxFramesPerPump,
		})
		else nil

	local self = setmetatable({
		JobId = config.JobId,
		Module = Module,
		Env = built,
		Link = link,
		Dead = false,
		Stopped = false,
		_sched = sched,
		-- Held only so Crash can sever it. nil when the caller supplied no bus, in
		-- which case Env handed this server the null message service and there is
		-- nothing to cut.
		_bus = config.Bus,
		_players = {},
		_playerCount = 0,
		_clients = {},
	}, Server)

	self.Bundle = Bundle.new({
		JobId = config.JobId,
		-- A stream of the client realm's own, for the reason the jitter one below
		-- gives: the client's Hello retry draws from it, and sharing the server's
		-- would renumber every save-retry draw behind it.
		ClientRng = Rng.Stream(config.Seed or 1, `client.{config.JobId}`),
		Sched = sched,
		-- A stream of its own, named per server for the same reason the guid one
		-- above is: jitter that correlated across the fleet would model the herd
		-- as gentler than it is.
		Rng = Rng.Stream(config.Seed or 1, `jitter.{config.JobId}`),
		Template = config.Template,
		Options = config.Options,
		ProfileStore = Module,
		Transport = if link then link:ServerAdapter() else config.Transport,
	})

	return self
end

--- One frame of THIS server, in the order Roblox runs one.
---
--- The order is load-bearing, not cosmetic. Inbound frames arrive first, so a
--- Hello delivered this frame is answered by an Init this frame; PostSimulation
--- then runs Scribe's flush loop, which is what turns queued ops into Diff frames;
--- outbound frames leave last. Reorder any two of these and a spec that "passes"
--- is measuring the harness rather than Scribe -- flushing before delivering
--- inbound, for instance, hides an entire frame of latency and makes the
--- handshake look instantaneous.
function Server.Frame(self, dt: number?)
	if self.Dead then
		return
	end
	if self.Link then
		self.Link:PumpToServer()
	end
	self.Bundle:Step(dt)
	if self.Link then
		self.Link:PumpToClient()
	end
end

--- Attach a real Scribe Client for `player` to this server.
---
--- Returns the client accessor. The handshake is NOT complete on return: the
--- client's Hello goes out on its connect thread, so the caller has to let the
--- scheduler run and at least one frame pass. `Server.SettleClients` does both.
function Server.AttachClient(self, player: any, options: { [string]: any }?)
	if self.Link == nil then
		error("sim: AttachClient needs a server built WITHOUT a Transport (it owns its own Link)", 2)
	end
	local adapter = self.Link:ClientAdapter(player)
	local client = self.Bundle:NewClient(adapter, options)
	table.insert(self._clients, { Player = player, Data = client })
	return client
end

--- Run frames until every attached client has completed its handshake, or give up.
---
--- Returns whether they all became ready. A bounded loop rather than a wait: an
--- unbounded one turns "the handshake broke" into the runner's 10-second timeout,
--- which proves nothing -- a spec has to be able to fail on an assertion.
function Server.SettleClients(self, frames: number?): boolean
	for _ = 1, frames or 16 do
		self._sched:Run(self._sched.Now + Env.FRAME_QUANTUM)
		self:Frame(Env.FRAME_QUANTUM)
		local allReady = true
		for _, record in self._clients do
			if not record.Data.IsReady() then
				allReady = false
				break
			end
		end
		if allReady then
			return true
		end
	end
	return false
end

function Server.ClientFor(self, player: any)
	for _, record in self._clients do
		if record.Player == player then
			return record.Data
		end
	end
	return nil
end

--- Fire this server's Heartbeat handlers once.
---
--- ProfileStore's entire autosave engine hangs off Heartbeat, so nothing periodic
--- happens on a server the universe stops ticking -- which is precisely what
--- makes Crash model a crash rather than a graceful exit.
function Server.Heartbeat(self, dt: number)
	if self.Dead then
		return
	end
	for _, handler in self.Env.HeartbeatHandlers do
		handler(dt)
	end
	self:Frame(dt)
end

function Server.PlayerCount(self): number
	return self._playerCount
end

--- Start a player's session. SPAWNS and returns immediately.
---
--- Never blocks the caller: a join contends for a session lock and can take tens
--- of virtual seconds, and a workload that waited for each join in turn would
--- serialise the very concurrency it exists to create.
function Server.Join(self, userId: number, player: any): thread
	if self.Dead then
		error(`sim: server {self.JobId} is dead and cannot accept joins`, 0)
	end
	self._players[userId] = player
	self._playerCount += 1
	return self._sched:Spawn(function()
		self.Bundle.Ctx.Persistence.OnPlayerAdded(player)
	end)
end

function Server.Leave(self, userId: number)
	local player = self._players[userId]
	if player == nil then
		return
	end
	self._players[userId] = nil
	self._playerCount -= 1
	-- The player is GONE before Scribe is told, exactly as Roblox orders it:
	-- PlayerRemoving fires with the player already out of Players. TestCtx.Leave has
	-- always done this (FakePlayer.leave, then OnPlayerRemoving); the simulation did
	-- not, and left Parent pointing at Players forever.
	--
	-- Not cosmetic. Persistence's StartSessionAsync Cancel guard is
	-- `player.Parent ~= Players or ...`, and OnPlayerRemoving deliberately does
	-- NOTHING for an entry still in Loading -- its own comment says "Loading sessions
	-- abort via the StartSessionAsync Cancel guard". With Parent never cleared that
	-- guard could not fire, so a player who left while their load was still in flight
	-- had it complete anyway, into a Ready entry nothing would ever tear down.
	-- Measured: two such entries survived a 300-step soak, autosaving forever.
	player.Parent = nil
	if self.Dead then
		return
	end
	self._sched:Spawn(function()
		self.Bundle.Ctx.Persistence.OnPlayerRemoving(player)
	end)
end

--- Kill the server outright: no drain, no session release.
---
--- Server-granular, never per player, and that is a real constraint rather than a
--- convenience. ProfileStore hard-errors if one module instance is asked to load
--- a key it already holds, so a "crashed" player whose session is retried on the
--- same instance would raise a harness error rather than model anything. A real
--- crash takes the whole server with it, and the locks it held stay on disk until
--- someone else steals them -- which is the scenario worth simulating.
function Server.Crash(self)
	self.Dead = true
	self._players = {}
	self._playerCount = 0
	-- And this is the part that makes it a crash rather than a label. Dead only
	-- stops Frame from stepping the bundle; the server's ProfileStore threads live
	-- in the SHARED scheduler and keep running either way, and its MessagingService
	-- subscriptions stayed live -- so a "crashed" server went on receiving the
	-- session-steal nudge, answering it, and performing a release save after the
	-- machine was supposed to be gone. Any crash-recovery spec written against that
	-- measures a fleet in which nothing ever really dies. See Bus.Sever.
	if self._bus then
		self._bus:Sever(self.JobId)
	end
end

--- Shut down gracefully, running whatever the server registered with
--- BindToClose, bounded by `budget` virtual seconds.
---
--- Roblox gives a closing server a limited window and then kills it regardless.
--- Modelling the budget rather than waiting indefinitely is what lets a spec ask
--- the interesting question: what is left unsaved when the window runs out?
function Server.Stop(self, budget: number)
	if self.Dead or self.Stopped then
		return
	end
	self.Stopped = true

	local finished = false
	self._sched:Spawn(function()
		for _, handler in self.Env.CloseHandlers do
			handler()
		end
		finished = true
	end)

	local deadline = self._sched.Now + (budget or 30)
	self._sched:Run(deadline)
	if not finished then
		-- The window expired with work outstanding. Not an error -- it is the
		-- production behaviour, and a spec may well be asserting on it.
		self.Dead = true
	end
	return finished
end

--- Run SCRIBE's own BindToClose drain, and report how much virtual time the call
--- itself consumed.
---
--- Stop cannot answer this question. It runs Env's CloseHandlers, which is
--- ProfileStore's BindToClose and nothing else -- Bundle builds with Server.build,
--- and BindShutdown lives in Server.new -- so Scribe's drain has never executed
--- under the simulation at all.
---
--- And it must not be SHAPED like Stop either. Stop drives the scheduler with
--- Run(deadline), and Run clamps Now to that deadline whether or not the work
--- finished (Scheduler.Run's time exit). A spec asking "did the drain stay inside
--- its budget" would then be measuring the bound it passed in, and would answer
--- yes on any code whatsoever.
---
--- So the clock is read INSIDE the drain thread, at the instant Shutdown returns.
--- That is the drain's own duration: unaffected by the outer run bound, and
--- unpolluted by the save jobs still in flight behind it. `nil` means the drain
--- had not returned by the time the run gave up, which is itself an answer.
function Server.Drain(self, budget: number): number?
	local sched = self._sched
	local startedAt = sched.Now
	local elapsed: number? = nil
	sched:Spawn(function()
		self.Bundle.Ctx.Persistence.Shutdown(budget)
		elapsed = sched.Now - startedAt
	end)
	-- Generously past the budget on purpose: a drain that overruns has to be
	-- allowed to finish and report the overrun, not be cut off at the number the
	-- spec is trying to test.
	sched:Run(startedAt + budget * 8)
	return elapsed
end

--- Run BOTH BindToClose handlers the way Roblox does: concurrently, each on its
--- own thread, waiting for all of them.
---
--- This is the shape neither Stop nor Drain has. Stop walks Env.CloseHandlers in
--- ONE thread, so handler 2 cannot start until handler 1 returns -- which hides
--- every interleaving between them, and an interleaving is the entire question
--- here. Drain calls Persistence.Shutdown directly, so Scribe's handler is not in
--- the list at all and never competes with ProfileStore's.
---
--- Roblox does not document the ORDER it invokes bound callbacks in, so a spec
--- that pins one order is asserting something nobody promised. `scribeFirst`
--- therefore selects the position of Scribe's handler and both are worth testing:
--- the invariant a shutdown has to hold is that leaving hooks run either way.
---
--- In production Scribe registers during Scribe() construction while
--- ProfileStore's registration waits behind `while DataStoreState == "NotReady"`,
--- so Scribe lands first today -- by accident of a DataStore round trip, not by
--- design. That accident is what this models and what a spec should pin.
function Server.Close(self, budget: number, scribeFirst: boolean?): boolean
	if self.Dead or self.Stopped then
		return true
	end
	self.Stopped = true

	local persistence = self.Bundle.Ctx.Persistence
	local handlers = {}
	local scribeHandler = function()
		persistence.Shutdown(budget)
	end
	if scribeFirst ~= false then
		table.insert(handlers, scribeHandler)
	end
	for _, handler in self.Env.CloseHandlers do
		table.insert(handlers, handler)
	end
	if scribeFirst == false then
		table.insert(handlers, scribeHandler)
	end

	-- Spawned, not called: Roblox runs bound callbacks in parallel, and Spawn runs
	-- each on the caller's stack until IT yields -- which is what lets an earlier
	-- handler claim state before a later one starts, exactly as production does.
	local outstanding = #handlers
	for _, handler in handlers do
		self._sched:Spawn(function()
			handler()
			outstanding -= 1
		end)
	end

	-- Generously past the budget, for the reason Drain gives: a drain that
	-- overruns must be allowed to finish and be observed overrunning, not cut off
	-- at the number the spec is trying to test.
	self._sched:Run(self._sched.Now + budget * 8)
	if outstanding > 0 then
		self.Dead = true
	end
	return outstanding == 0
end

--- Has every session this server holds finished starting or stopping?
function Server.SessionsSettled(self): boolean
	if self.Dead then
		return true
	end
	local persistence = self.Bundle.Ctx.Persistence
	for userId, player in self._players do
		local entry = persistence.EntryFor(player)
		if entry == nil then
			return false
		end
		local _ = userId
	end
	return true
end

function Server.Teardown(self)
	self.Bundle:Teardown()
	self.Dead = true
end

Server.PROFILESTORE_PATH = PROFILESTORE_PATH
Server.SimHost = SimHost

return Server
