--!strict
-- Health status machine with hysteresis.
-- Healthy -> Degraded (N failures within a window, or critical state on)
--         -> Outage (sustained) ; recovers on a success streak.
-- Library-level singleton. On the client this only stores the broadcast status.

local Signal = require(script.Parent.Signal)
local Log = require(script.Parent.Log)
local Metrics = require(script.Parent.Metrics)

export type Status = "Healthy" | "Degraded" | "Outage"

local Health = {}

Health.OnStatusChanged = Signal.new() :: Signal.Signal<Status, Status> -- (newStatus: Status, oldStatus: Status)

local thresholds = {
	FailWindow = 60, -- seconds
	FailCount = 3, -- failures within window: Healthy -> Degraded
	RecoverStreak = 5, -- consecutive successes to step one state down
	OutageFailCount = 8, -- failures within window: -> Outage
	CriticalOutageDelay = 30, -- seconds of sustained ProfileStore critical state -> Outage
}

local status: Status = "Healthy"
local failures: { number } = {}
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

local function pruneFailures(now: number)
	local cutoff = now - thresholds.FailWindow
	while failures[1] and failures[1] < cutoff do
		table.remove(failures, 1)
	end
end

local function evaluate()
	local now = os.clock()
	pruneFailures(now)
	local recent = #failures

	if criticalSince and now - criticalSince >= thresholds.CriticalOutageDelay then
		setStatus("Outage")
		return
	end

	if recent >= thresholds.OutageFailCount then
		setStatus("Outage")
	elseif recent >= thresholds.FailCount or criticalSince then
		if status == "Healthy" then
			setStatus("Degraded")
		end
	end
end

function Health.Configure(config: { FailWindow: number?, FailCount: number?, RecoverStreak: number? }?)
	if not config then
		return
	end
	thresholds.FailWindow = config.FailWindow or thresholds.FailWindow
	thresholds.FailCount = config.FailCount or thresholds.FailCount
	thresholds.RecoverStreak = config.RecoverStreak or thresholds.RecoverStreak
	thresholds.OutageFailCount = math.max(thresholds.FailCount * 2, thresholds.FailCount + 1)
end

-- Report a failed DataStore/OrderedDataStore/MessageAsync operation.
function Health.ReportFailure(subsystem: string)
	successStreak = 0
	table.insert(failures, os.clock())
	Metrics.Add("HealthFailures")
	Metrics.Add("HealthFailures_" .. subsystem)
	evaluate()
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
		setStatus(if status == "Outage" then "Degraded" else "Healthy")
	end
end

-- Bound to ProfileStore.OnCriticalToggle.
function Health.SetCritical(isCritical: boolean)
	if isCritical then
		criticalSince = criticalSince or os.clock()
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
