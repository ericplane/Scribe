--!nonstrict
-- One simulated server's complete global table.
--
-- This is the whole trick. ProfileStore reaches the outside world exclusively
-- through globals -- game:GetService, game.PlaceId/.JobId, Instance.new, task.*,
-- os.*, typeof, Enum, coroutine, script -- and has exactly one `require` in the
-- file, which is inside a comment. So handing it a different global table hands
-- it a different world: a virtual clock, a seeded scheduler, a distinct server
-- identity, and a modelled disk. The vendored library is never patched, never
-- forked, and never reimplemented, so what the simulation exercises is the real
-- session-lock protocol rather than a model of it.
--
-- Everything here is per server EXCEPT os.time and the disk, which are shared.
-- That split is not stylistic; see the two notes below.

local Loader = require(script.Parent.Loader)

local SimHost = __SimHost

local Env = {}

-- A Roblox server runs at 60 Hz, and `task.wait()` with no argument means "next
-- frame", not "immediately". See the long note on Wait below -- this constant is
-- the difference between a simulation that runs and one that spins forever.
local FRAME_QUANTUM = 1 / 60

-- Every server in a universe shares a PlaceId, as they would in production; only
-- JobId distinguishes them. ProfileStore's IsThisSession compares both.
local SIM_PLACE_ID = 1234

export type Config = {
	Sched: any,
	Disk: any,
	Bus: any,
	Rng: any,
	JobId: string,
	PlaceId: number?,
	ClockSkew: number?,
	PlayerCount: (() -> number)?,
}

--- Build the global table for one simulated server.
function Env.Build(cfg: Config)
	local sched = cfg.Sched
	local skew = cfg.ClockSkew or 0
	local placeId = cfg.PlaceId or SIM_PLACE_ID

	----------------------------------------------------------------------------
	-- Time
	----------------------------------------------------------------------------
	local os_ = {
		-- ONE wall clock for the whole universe, deliberately not per server.
		--
		-- ProfileStore's dead-session recovery compares a LastUpdate timestamp
		-- written by a DIFFERENT server against this server's os.time (the
		-- ASSUME_DEAD path). Give each server its own wall clock and that
		-- comparison is between two unrelated number lines: a crashed server's key
		-- either never looks stale or always does, and crash recovery -- one of
		-- the main things worth simulating -- stops meaning anything.
		time = function()
			return math.floor(sched.Now)
		end,
		-- Per-server monotonic, and allowed to be skewed. Real servers do not
		-- agree on os.clock, and code that assumes they do is exactly the kind of
		-- bug a simulation should be able to express.
		clock = function()
			return sched.Now + skew
		end,
		date = os.date,
		difftime = os.difftime,
	}

	----------------------------------------------------------------------------
	-- Scheduling
	----------------------------------------------------------------------------
	local task_ = {
		spawn = function(target: any, ...)
			-- Both overloads. task.spawn(fn) starts and runs immediately;
			-- task.spawn(thread) resumes one already parked.
			if type(target) == "thread" then
				sched:Resume(target, ...)
				return target
			end
			return sched:Spawn(target, ...)
		end,
		defer = function(fn: any, ...)
			return sched:Defer(fn, ...)
		end,
		delay = function(seconds: number, fn: any, ...)
			return sched:Delay(seconds, fn, ...)
		end,
		--- Yield for `seconds`, or ONE FRAME when that is nil or non-positive.
		---
		--- THE hard blocker of the whole design, and it is worth stating plainly
		--- because the obvious implementation is silently fatal.
		---
		--- ProfileStore waits out a session conflict with
		---     repeat task.wait() until os.clock() >= wait_until
		--- and does the same shape of thing while waiting for DataStore access,
		--- for a load job, and in both BindToClose drains. If `task.wait()` were a
		--- free yield -- straight back onto the ready queue, no time passing --
		--- that loop never terminates: virtual time only advances when NOTHING is
		--- runnable, and this thread is always runnable. Measured, before this
		--- constant existed: 400,000 scheduler steps burned across 1.20 virtual
		--- seconds, the waiting server never acquiring the session.
		---
		--- Note this is the exact OPPOSITE of Clock.Wait(0), which is a free yield
		--- on purpose -- Scribe's own loops use it to cooperate without claiming
		--- to have slept. Same word, two behaviours; they must never share an
		--- implementation. The difference is that Scribe's loops are seamed and
		--- yield on real conditions, while this stands in for an engine frame.
		wait = function(seconds: number?): number
			if seconds == nil or seconds <= 0 then
				return sched:Wait(FRAME_QUANTUM)
			end
			return sched:Wait(seconds)
		end,
		cancel = function() end,
	}

	----------------------------------------------------------------------------
	-- coroutine, with resume accounted for
	----------------------------------------------------------------------------
	-- ProfileStore hands its per-key update queue off with a raw
	-- coroutine.resume, which the kernel cannot observe -- so a thread dying
	-- inside it would leak a Live count, and Run reports a deadlock whenever
	-- nothing is runnable while Live > 0. Unrouted, EVERY clean run would report a
	-- deadlock. ResumeRaw keeps coroutine.resume's exact contract.
	local coroutine_ = table.clone(coroutine)
	coroutine_.resume = function(co: thread, ...)
		return sched:ResumeRaw(co, ...)
	end

	----------------------------------------------------------------------------
	-- Services
	----------------------------------------------------------------------------
	local heartbeatHandlers = {}
	local closeHandlers = {}

	local heartbeat = {
		Connect = function(_self, fn)
			table.insert(heartbeatHandlers, fn)
			local connection
			connection = {
				Connected = true,
				Disconnect = function()
					connection.Connected = false
					for index, handler in heartbeatHandlers do
						if handler == fn then
							table.remove(heartbeatHandlers, index)
							break
						end
					end
				end,
			}
			return connection
		end,
	}

	local services = {
		-- ProfileStore's ENTIRE autosave engine hangs off Heartbeat, so the
		-- universe drives it; nothing here fires on its own.
		RunService = {
			Heartbeat = heartbeat,
			PostSimulation = heartbeat,
			-- Pinned false so DataStoreState resolves to "Access" synchronously at
			-- load, skipping the Studio API-access probe (which would otherwise
			-- issue a real-looking SetAsync during module load, before the
			-- simulation has begun).
			IsStudio = function()
				return false
			end,
			IsServer = function()
				return true
			end,
			IsClient = function()
				return false
			end,
			IsRunning = function()
				return true
			end,
		},

		HttpService = {
			-- Its own Rng stream: these ids become Bus topic names and end up in
			-- persisted data, so they must replay identically without perturbing
			-- the scheduler's stream.
			GenerateGUID = function(_self, _wrapped)
				local hex = "0123456789abcdef"
				local out = table.create(36)
				for i = 1, 36 do
					if i == 9 or i == 14 or i == 19 or i == 24 then
						out[i] = "-"
					else
						local index = cfg.Rng:NextInteger(16)
						out[i] = string.sub(hex, index, index)
					end
				end
				return table.concat(out)
			end,
		},

		DataStoreService = cfg.Disk and cfg.Disk:ServiceFor(cfg.JobId) or nil,

		-- With no Bus supplied, a NULL message service: subscribes succeed, publishes
		-- go nowhere. ProfileStore requires this service at load, so it cannot simply
		-- be absent.
		--
		-- What that costs is worth naming rather than hiding. The steal notification
		-- rides MessagingService, so without a bus a contending server falls back to
		-- ProfileStore's polling path -- the handoff still completes, just later. A
		-- run on a null bus therefore models a SLOWER handoff than production, never
		-- a faster one, which is the safe direction: it cannot hide a race, only
		-- stretch it.
		MessagingService = cfg.Bus and cfg.Bus:ServiceFor(cfg.JobId) or {
			SubscribeAsync = function()
				cfg.Sched:Wait(0.05)
				return { Disconnect = function() end }
			end,
			PublishAsync = function()
				cfg.Sched:Wait(0.05)
			end,
		},
	}

	local game_ = {
		PlaceId = placeId,
		JobId = cfg.JobId,
		GetService = function(_self, name: string)
			local service = services[name]
			if service == nil then
				error(`sim: server {cfg.JobId} has no service "{name}"`, 0)
			end
			return service
		end,
		-- Captured, never invoked here. A simulated shutdown runs these
		-- deliberately, with a budget, because that is the interesting part.
		BindToClose = function(_self, fn)
			table.insert(closeHandlers, fn)
		end,
	}

	----------------------------------------------------------------------------
	-- Enum identity and typeof
	----------------------------------------------------------------------------
	-- ProfileStore guards VersionQuery with
	--   typeof(sort_direction) ~= "EnumItem" or sort_direction.EnumType ~= Enum.SortDirection
	-- and Scribe reaches it (src/Server/Persistence.luau:3112). BOTH halves have to
	-- hold: measured, a string EnumType is rejected, and so is the enum object when
	-- typeof still answers "table". Only this pair passes -- and the typeof lie is
	-- scoped to the environments built here, never installed globally, because two
	-- src modules branch on typeof(x) == "EnumItem" and currently take the false
	-- branch under the shim.
	local function typeof_(value: any): string
		if SimHost.IsEnumItem(value) then
			return "EnumItem"
		end
		return SimHost.Typeof(value)
	end

	local instance_ = {
		new = function(className: string)
			if className == "DataStoreOptions" then
				return {
					SetExperimentalFeatures = function() end,
				}
			end
			error(`sim: Instance.new("{className}") is not modelled`, 0)
		end,
	}

	----------------------------------------------------------------------------
	local env = Loader.BaseEnv()
	env.os = os_
	env.task = task_
	env.coroutine = coroutine_
	env.game = game_
	env.Enum = SimHost.Enum -- the very object Scribe holds; identity matters
	env.typeof = typeof_
	env.Instance = instance_
	env.script = { Name = "ProfileStore" }

	return {
		Globals = env,
		Services = services,
		HeartbeatHandlers = heartbeatHandlers,
		CloseHandlers = closeHandlers,
		FrameQuantum = FRAME_QUANTUM,
	}
end

Env.FRAME_QUANTUM = FRAME_QUANTUM
Env.PLACE_ID = SIM_PLACE_ID

return Env
