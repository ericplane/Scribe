--!nonstrict
-- N simulated servers over one key space and one virtual clock.
--
-- WHAT THIS SIMULATION DOES AND DOES NOT COVER IS WRITTEN DOWN, in SCOPE.md next
-- to this file. Read it before trusting a green run: the harness is ~5,000 lines,
-- and size reads as coverage unless something says otherwise. It said nothing
-- once, and 183 passing tests turned out to produce zero replication frames.

local Scheduler = require(script.Parent.Scheduler)
local Rng = require(script.Parent.Rng)
local Digest = require(script.Parent.Digest)
local Disk = require(script.Parent.Disk)
local Server = require(script.Parent.Server)
local Bus = require(script.Parent.Bus)

local Universe = {}
Universe.__index = Universe

-- How often the universe fires every server's Heartbeat, in virtual seconds.
--
-- One second, not one frame. ProfileStore's finest internal deadline is
-- FIRST_LOAD_REPEAT at 5s, so a 1s tick stays comfortably below every deadline it
-- checks while costing 60x fewer scheduler steps than a 60 Hz tick -- measured,
-- with the autosave count identical at both. A 5s tick is faster still and sits
-- exactly ON that deadline, which is why it is not the default.
local TICK_PERIOD = 1.0

function Universe.new(config)
	local seed = config.Seed or 1
	local sched = Scheduler.new(seed)

	local self = setmetatable({
		Seed = seed,
		Sched = sched,
		Servers = {},
		TickPeriod = config.TickPeriod or TICK_PERIOD,
		_ticking = false,
		_driverAlive = false,
		_nextJob = 0,
	}, Universe)

	self.Disk = config.Disk
		or Disk.new({
			Sched = sched,
			Rng = Rng.Stream(seed, "disk.latency"),
			VersionRng = Rng.Stream(seed, "disk.versionid"),
			FaultRng = Rng.Stream(seed, "disk.fault"),
			LatencyProfile = config.LatencyProfile or "Nominal",
			ValueBytes = config.ValueBytes,
			BudgetMode = config.BudgetMode,
			NoBudget = config.NoBudget,
			PlayerCount = function(jobId)
				local server = self:ServerByJob(jobId)
				return if server then server:PlayerCount() else 0
			end,
			CCU = function()
				return self:CCU()
			end,
		})

	self.Bus = config.Bus
		or Bus.new({
			Sched = sched,
			Rng = Rng.Stream(seed, "bus"),
			Latency = config.BusLatency,
			DropRate = config.BusDropRate,
		})

	-- StatusThresholds is REQUIRED, not defaulted.
	--
	-- Health flips to Degraded after three failures in a sixty-second window and to
	-- Outage at six, and Outage refuses gifts, restores, erases and receipts. A
	-- realistic throttle model at high CCU crosses those defaults trivially, so a
	-- scenario that has not thought about them would stumble into Outage and report
	-- the same finding every run -- an artefact of the thresholds, presented as a
	-- property of Scribe. Studying Outage is legitimate; arriving there by accident
	-- is not, so the choice has to be made out loud.
	if config.StatusThresholds == nil then
		error("sim: Universe.new requires StatusThresholds -- pick them deliberately, see the note in Universe.luau", 2)
	end
	config.Options = config.Options or {}
	config.Options.StatusThresholds = config.StatusThresholds

	self._config = config

	for _ = 1, config.Servers or 1 do
		self:AddServer()
	end
	return self
end

function Universe.AddServer(self, jobId: string?)
	self._nextJob += 1
	local id = jobId or `sim-server-{self._nextJob}`
	local server = Server.new({
		Sched = self.Sched,
		Disk = self.Disk,
		Bus = self.Bus,
		JobId = id,
		Seed = self.Seed,
		ClockSkew = self._config.ClockSkew,
		Constants = self._config.Constants,
		Template = self._config.Template,
		Options = self._config.Options,
		Transport = self._config.Transport,
		-- Only meaningful when Transport is omitted and each server mints its own
		-- Link: they model a channel that refuses an oversize payload and one that
		-- drains slower than the server fills it.
		MaxFrameBytes = self._config.MaxFrameBytes,
		MaxFramesPerPump = self._config.MaxFramesPerPump,
	})
	table.insert(self.Servers, server)
	return server
end

function Universe.Server(self, index: number)
	return self.Servers[index]
end

function Universe.ServerByJob(self, jobId: string)
	for _, server in self.Servers do
		if server.JobId == jobId then
			return server
		end
	end
	return nil
end

--- Live players across every server: the experience budget's CCU term.
function Universe.CCU(self): number
	local total = 0
	for _, server in self.Servers do
		if not server.Dead then
			total += server:PlayerCount()
		end
	end
	return total
end

--- Start the tick driver, once -- and ONCE is guarded on the driver still being
--- alive, not on the ticking flag.
---
--- The two are not the same, and the difference was a live bug: Quiesce clears
--- `_ticking`, but the driver thread is parked in Wait and does not observe that
--- until it next wakes. A `Run` in between -- which `Settle` does on its first
--- line -- saw `_ticking == false`, spawned a SECOND driver and set the flag back
--- to true, so the original woke into a loop that was live again. Measured before
--- this fix: 20 of the simulation's universes ran two drivers, ticking at 1.5-2x
--- the configured rate, and Quiesce's own docstring ("stop ticking, so a Settle
--- can reach a genuinely quiescent state") was false for exactly the four spec
--- files that call it.
local function ensureTicking(self)
	-- Quiesce is STICKY, and that is the second half of the same bug the comment
	-- above records. Clearing `_ticking` stops the driver -- but the driver does not
	-- observe it until it next wakes, and by then Settle has already run its first
	-- `Run`, seen `_driverAlive == false`, and started a fresh driver. Measured on
	-- the SCRIBE_SOAK=1 fault-burst run: Quiesce at t=1020, driver 1 exits at
	-- t=1021, `Settle`'s own first Run starts driver 2 at t=1025, and heartbeats
	-- then continue for the whole 300-second settle window. So `Quiesce`'s
	-- docstring -- "stop ticking, so a Settle can reach a genuinely quiescent
	-- state" -- was false for every caller, and the gate below could never pass
	-- while ANY profile was still loaded, because ProfileStore's autosave engine
	-- runs off Heartbeat and writes forever at AUTO_SAVE_PERIOD.
	--
	-- Nothing resumes a quiesced universe: every caller in test/Specs quiesces and
	-- then either settles or discards the universe, so a sticky flag costs nothing
	-- and needs no matching Resume.
	if self._quiesced then
		return
	end
	if self._driverAlive then
		return
	end
	self._driverAlive = true
	self._ticking = true
	self.Sched:Spawn(function()
		while self._ticking do
			self.Sched:Wait(self.TickPeriod)
			for _, server in self.Servers do
				server:Heartbeat(self.TickPeriod)
			end
		end
		self._driverAlive = false
	end)
end

--- Advance the world by `seconds` of virtual time.
---
--- ALWAYS bounded, and it has to be. The tick driver keeps a sleeper permanently
--- queued, and the scheduler only takes its time exit when nothing is runnable --
--- so an unbounded Run would never return, burn to the step limit, and set the
--- sticky Stalled flag, which then reads as a workload bug rather than a harness
--- one.
function Universe.Run(self, seconds: number, stepLimit: number?): number
	ensureTicking(self)
	return self.Sched:Run(self.Sched.Now + seconds, stepLimit)
end

--- Run until the storage layer has gone quiet, up to `maxSeconds`. The liveness
--- gate every later assertion depends on.
---
--- NOT "no thread is alive". That predicate is unreachable here, and it is worth
--- recording why because it is the obvious thing to reach for: Scribe keeps its
--- flush loop running and ProfileStore keeps its autosave engine and message
--- subscription running, both by design and both for the lifetime of the server.
--- A gate that can never pass is worse than no gate, because it gets disabled
--- rather than fixed.
---
--- The meaningful question is whether the STORAGE settled: nothing in flight, and
--- no new writes landing. Both halves are needed -- in-flight alone dips to zero
--- between a save and its retry, and quiet-writes alone would accept a run whose
--- requests are all still on their way.
function Universe.Settle(self, maxSeconds: number): boolean
	local deadline = self.Sched.Now + maxSeconds
	local quietRounds = 0

	while self.Sched.Now < deadline do
		local writesBefore = self.Disk.Stats.Writes
		self:Run(math.min(5, deadline - self.Sched.Now))

		if self.Disk:InFlight() == 0 and self.Disk.Stats.Writes == writesBefore then
			quietRounds += 1
			-- Two consecutive quiet windows, not one: a retry backoff can leave a
			-- single window looking idle while a save is still pending behind it.
			if quietRounds >= 2 then
				return true
			end
		else
			quietRounds = 0
		end

		if self.Sched.Deadlocked then
			return false
		end
	end
	return false
end
--- Stop ticking, so a Settle can reach a genuinely quiescent state. Permanent:
--- see ensureTicking for why a non-sticky version of this did nothing.
function Universe.Quiesce(self)
	self._ticking = false
	self._quiesced = true
end

function Universe.Crash(self, index: number)
	self.Servers[index]:Crash()
end

function Universe.Stop(self, index: number, budget: number)
	return self.Servers[index]:Stop(budget)
end

--- A stable fingerprint of everything the run produced.
---
--- Deliberately over the DISK, not over the servers: what persisted is the thing
--- that has to replay identically, and per-server bookkeeping contains thread
--- identities and table addresses that differ between runs by design.
function Universe.Digest(self): string
	local snapshot = {}
	for _, entry in self.Disk.Keyspace:Each() do
		table.insert(snapshot, {
			Store = entry.Store,
			Key = entry.Key,
			Version = entry.Record.Version,
			Value = entry.Record.Value,
		})
	end
	return Digest.Of({
		Keys = snapshot,
		Stats = {
			Writes = self.Disk.Stats.Writes,
			Reads = self.Disk.Stats.Reads,
			Conflicts = self.Disk.Stats.Conflicts,
		},
	})
end

function Universe.Destroy(self)
	self._ticking = false
	for _, server in self.Servers do
		server:Teardown()
	end
	self.Servers = {}
end

Universe.TICK_PERIOD = TICK_PERIOD

return Universe
