--!strict
-- Health status machine with hysteresis.
-- Healthy -> Degraded (N failures within a window, or critical state on)
--         -> Outage (sustained) ; recovers on a success streak.
-- Library-level singleton. On the client this only stores the broadcast status.

local Signal = require(script.Parent.Signal)
local Log = require(script.Parent.Log)
local Metrics = require(script.Parent.Metrics)
local Clock = require(script.Parent.Clock)

export type Status = "Healthy" | "Degraded" | "Outage"

local Health = {}

Health.OnStatusChanged = Signal.new() :: Signal.Signal<Status, Status> -- (newStatus: Status, oldStatus: Status)

local thresholds = {
	FailWindow = 60, -- seconds
	FailCount = 3, -- failures within window: Healthy -> Degraded
	RecoverStreak = 5, -- consecutive successes to step one state down
	-- Failures within window -> Outage. Derived by the same formula Configure uses, so a
	-- StatusThresholds table that leaves FailCount alone cannot silently shift it.
	OutageFailCount = math.max(3 * 2, 3 + 1),
	CriticalOutageDelay = 30, -- seconds of sustained ProfileStore critical state -> Outage
}

-- A throttle is one problem no matter how many keys hit it, so every throttled failure
-- in a subsystem shares this subject. Being throttled is not the store being broken, and
-- counting a join burst as N problems drives the server past Outage, which refuses Robux
-- receipts while nothing is wrong. Not namespaced per key: the burst is simultaneous, so
-- per-key dedup would let N through at once.
local THROTTLE_SUBJECT = "~throttled"

-- Smallest gap between two failures of the same operation that counts as two separate
-- problems. ProfileStore retries a failing key on its own backoff and every attempt
-- arrives here, so without this one stuck profile reaches Outage alone. Set above
-- ProfileStore's 20 s backoff ceiling so a genuinely new failure of the same key counts.
local RETRY_COOLDOWN = 25

local status: Status = "Healthy"
-- Sorted by At: entries are only ever appended with a non-decreasing monotonic clock,
-- and pruneFailures depends on that to stop at the first survivor.
local failures: { { At: number, Id: string? } } = {}
-- Newest in-window failure per identity, for the retry cooldown. The cooldown is shorter
-- than the window, so pruneFailures is enough to bound this.
local lastAt: { [string]: number } = {}
local counts: { [string]: number } = {}
-- How many reports have been folded into the identity's current live problem, so the
-- line eventually logged can say how many it stands for. Kept beside `counts` because
-- `forget` retires an identity at the right moment; a tally that outlives its identity
-- is a leak on a long-lived server.
local folded: { [string]: number } = {}
-- Maintained incrementally so evaluate() stays O(1) on a path that only runs while
-- things are already going wrong.
local distinctIds = 0
local unkeyed = 0
local successStreak = 0
local criticalSince: number? = nil

local function setStatus(new: Status)
	if new == status then
		return
	end
	local old = status
	status = new
	Metrics.Set("HealthStatus", if new == "Healthy" then 0 elseif new == "Degraded" then 1 else 2)
	if new == "Healthy" then
		Log.Info("Persistence", "STATUS_CHANGED", `service status {old} -> {new}`, { From = old, To = new })
	else
		Log.Warn("Persistence", "STATUS_CHANGED", `service status {old} -> {new}`, { From = old, To = new })
	end
	Health.OnStatusChanged:Fire(new, old)
end

local function forget(entry: { At: number, Id: string? })
	local id = entry.Id
	if id == nil then
		unkeyed -= 1
		return
	end
	local left = (counts[id] or 1) - 1
	if left <= 0 then
		counts[id] = nil
		lastAt[id] = nil
		folded[id] = nil
		distinctIds -= 1
	else
		counts[id] = left
	end
end

local function pruneFailures(now: number)
	local cutoff = now - thresholds.FailWindow
	while failures[1] and failures[1].At < cutoff do
		forget(table.remove(failures, 1) :: any)
	end
end

-- Lifting Outage once the failures stop -------------------------------------
--
-- evaluate() only ever escalates, and a quiet server never calls it, so without this a
-- burst that ends leaves the status at Outage forever, with no traffic to feed the
-- success streak that would lift it.
--
-- The step condition is that the window is genuinely empty, not that the count dipped
-- below the Outage threshold: with a sparse failure stream, which the retry cooldown
-- guarantees for a few keys, the count dips constantly between retries and the status
-- would flap, opening the money gate mid-outage. It stops at Degraded, because "nobody
-- reported a failure" is not evidence anything worked; reaching Healthy costs a streak.
local DECAY_MIN_DELAY = 1 -- seconds; the horizon can land on the prune boundary, where an entry survives
local decayPending = false
local armDecay: () -> ()

local function decayCheck()
	decayPending = false
	if status ~= "Outage" then
		return
	end
	pruneFailures(Clock.Monotonic())
	-- Re-armed on every path, not just the one that steps: a check that declines and then
	-- dies is a decay that never happens.
	if criticalSince or #failures > 0 then
		armDecay()
		return
	end
	successStreak = 0
	setStatus("Degraded")
	armDecay()
end

function armDecay()
	if decayPending or status ~= "Outage" then
		return
	end
	decayPending = true
	local newest = failures[#failures]
	local now = Clock.Monotonic()
	local delay = if newest then (newest.At + thresholds.FailWindow) - now else thresholds.FailWindow
	Clock.Delay(math.max(delay, DECAY_MIN_DELAY), decayCheck)
end

local function evaluate()
	local now = Clock.Monotonic()
	pruneFailures(now)
	local recent = #failures

	if criticalSince and now - criticalSince >= thresholds.CriticalOutageDelay then
		-- ProfileStore's critical flag has no key dimension, so one permanently-failing
		-- profile trips it unaided. Treat it as corroboration, not an independent trigger:
		-- it forces Outage only when Scribe's own failures span more than one operation.
		if distinctIds + unkeyed >= 2 then
			setStatus("Outage")
			-- Without this re-arm, the critical-state path is the one entry to Outage that
			-- never schedules a decay, so a server that escalated here and then went quiet
			-- stays in Outage forever.
			armDecay()
			return
		end
	end

	if recent >= thresholds.OutageFailCount then
		setStatus("Outage")
	elseif recent >= thresholds.FailCount or criticalSince then
		if status == "Healthy" then
			setStatus("Degraded")
		end
	end
	armDecay()
end

-- What has been explicitly configured, and which conflicts have been reported. This
-- machine is a library-level singleton, so a second bundle in the same process retunes
-- the first's Outage gate, the gate that refuses Robux grants during a DataStore
-- failure. The later value still wins, matching SAVE_INTERVAL_CONFLICT, but it warns.
local configured: { [string]: number } = {}
local conflictWarned: { [string]: true } = {}

local CONFIGURABLE = { "FailWindow", "FailCount", "RecoverStreak" }

function Health.Configure(config: { FailWindow: number?, FailCount: number?, RecoverStreak: number? }?)
	if not config then
		return
	end
	for _, field in CONFIGURABLE do
		local requested = (config :: any)[field]
		if requested ~= nil then
			local existing = configured[field]
			-- Once per field, not once per call: a process that rebuilds bundles would
			-- otherwise turn one real signal into a line per build.
			if existing ~= nil and existing ~= requested and not conflictWarned[field] then
				conflictWarned[field] = true
				-- "Persistence" because the health machine has no subsystem of its own in
				-- the Types.LogSubsystem union.
				Log.Warn(
					"Persistence",
					"HEALTH_THRESHOLDS_CONFLICT",
					"the health thresholds are a process global shared by every Scribe bundle and were already set "
						.. "to a different value; the later value wins. Set them once, identically, in every bundle.",
					{ Field = field, Existing = existing, Requested = requested }
				)
			end
			local live: any = thresholds
			live[field] = requested
			configured[field] = requested
		end
	end
	thresholds.OutageFailCount = math.max(thresholds.FailCount * 2, thresholds.FailCount + 1)
end

-- The thresholds as they currently stand, copied so a reader cannot edit the singleton
-- by accident. OutageFailCount is the interesting member: it gates money, it is rebuilt
-- from FailCount on every Configure, and there is otherwise no way to see which won.
function Health.Thresholds(): { [string]: number }
	return table.clone(thresholds)
end

-- Put the singleton back to its declared defaults, including the record of what has
-- been configured, so the first Configure after a teardown is not compared against a
-- bundle that no longer exists.
function Health.ResetThresholds()
	thresholds.FailWindow = 60
	thresholds.FailCount = 3
	thresholds.RecoverStreak = 5
	thresholds.OutageFailCount = math.max(3 * 2, 3 + 1)
	thresholds.CriticalOutageDelay = 30
	table.clear(configured)
	table.clear(conflictWarned)
end

--- Report a failed DataStore/OrderedDataStore/MessageAsync operation.
---
--- `key` identifies the subject of the operation (a profile key, a user id) so repeated
--- failures of the same thing collapse into one problem; omit it only where there is no
--- subject. Of the `class` verdicts only "Throttled" changes anything: see
--- THROTTLE_SUBJECT.
---
--- Returns `(counted, folded)`. `counted` is whether the report became a distinct
--- problem rather than being absorbed into a live one. `folded` is how many reports were
--- absorbed: on a counted call the previous problem's tally, now flushed; on an absorbed
--- call the running tally including this one.
function Health.ReportFailure(subsystem: string, key: string?, class: string?): (boolean, number)
	successStreak = 0
	-- The metric still counts every report; only the state machine below dedupes.
	Metrics.Add("HealthFailures")
	Metrics.Add("HealthFailures_" .. subsystem)

	local now = Clock.Monotonic()
	-- Namespaced by subsystem so a version read and a save failure on the same key stay
	-- independent problems. Subsystem names are fixed internal literals and never contain
	-- the separator, so the pair cannot be ambiguous.
	local id = if class == "Throttled"
		then subsystem .. "|" .. THROTTLE_SUBJECT
		elseif key ~= nil then subsystem .. "|" .. key
		else nil
	local flushed = 0
	if id ~= nil then
		local seen = lastAt[id]
		if seen ~= nil and now - seen < RETRY_COOLDOWN then
			-- Same operation, still inside its retry window: already counted.
			local tally = (folded[id] or 0) + 1
			folded[id] = tally
			evaluate()
			return false, tally
		end
		lastAt[id] = now
		flushed = folded[id] or 0
		folded[id] = nil
		local n = (counts[id] or 0) + 1
		counts[id] = n
		if n == 1 then
			distinctIds += 1
		end
	else
		unkeyed += 1
	end
	table.insert(failures, { At = now, Id = id })
	evaluate()
	return true, flushed
end

-- Report a successful operation; a streak steps the status back down.
function Health.ReportSuccess(_subsystem: string?)
	if status == "Healthy" then
		successStreak = 0
		return
	end
	successStreak += 1
	if successStreak >= thresholds.RecoverStreak and not criticalSince then
		successStreak = 0
		table.clear(failures)
		table.clear(lastAt)
		table.clear(counts)
		table.clear(folded)
		distinctIds = 0
		unkeyed = 0
		setStatus(if status == "Outage" then "Degraded" else "Healthy")
	end
end

-- Bound to ProfileStore.OnCriticalToggle.
function Health.SetCritical(isCritical: boolean)
	if isCritical then
		if not criticalSince then
			criticalSince = Clock.Monotonic()
			-- evaluate() runs only on ReportFailure/SetCritical, so a sustained critical
			-- window with no further failures would never escalate. It re-reads elapsed
			-- time, so a cleared or freshly-reset critical state won't escalate early.
			Clock.Delay(thresholds.CriticalOutageDelay, function()
				if criticalSince then
					evaluate()
				end
			end)
		end
		evaluate()
	else
		criticalSince = nil
		-- Leave recovery to the success streak.
	end
end

function Health.GetStatus(): Status
	return status
end

-- Client side: adopt a status broadcast from the server.
function Health.AdoptBroadcast(new: Status)
	setStatus(new)
end

return Health
