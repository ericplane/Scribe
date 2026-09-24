--!strict
-- ScribeTelemetry: Scribe's health, failures, selected warnings, performance rules and
-- periodic summaries, reported to Discord webhooks through the public diagnostics API.

local RunService = game:GetService("RunService")

local Config = require(script.Config)
local Diagnostics = require(script.Diagnostics)
local Format = require(script.Format)
local LeaderboardMonitor = require(script.LeaderboardMonitor)
local Preview = require(script.Preview)
local Router = require(script.Router)
local Sanitize = require(script.Sanitize)
local Transport = require(script.Transport)

export type Options = Config.Options
export type PreviewKind = Preview.Kind
export type Stats = Transport.Stats & {
	State: string,
	Reports: number,
	Previews: number,
	Skipped: { [string]: number },
	Filtered: { [string]: number },
	Groups: number,
	EncodeFailures: number,
	LastTickError: string?,
	Leaderboards: { State: string, Monitored: number, Omitted: number, SnapshotAge: number?, LastError: string? },
}
export type Handle = {
	Test: (self: Handle, destination: string) -> (boolean, string?),
	Preview: (self: Handle, destination: string, kind: PreviewKind?) -> (boolean, string?),
	Flush: (self: Handle, timeout: number?) -> boolean,
	GetStats: (self: Handle) -> Stats,
	Stop: (self: Handle) -> (),
}
export type LogEntry = {
	At: number,
	Level: string,
	Category: string,
	Code: string,
	Message: string,
	Context: { [string]: any }?,
}
--- The slice of the Scribe module the add-on reads; the real module satisfies it.
export type ScribeModule = {
	Version: string?,
	AddLogSink: (sink: (entry: LogEntry) -> (), options: { Level: string? }?) -> () -> (),
	OnStatusChanged: { Connect: (self: any, fn: (new: string, old: string?) -> ()) -> any },
	GetStatus: () -> string,
	GetMetrics: () -> { [string]: any },
	GetPercentiles: () -> { [string]: any },
	GetBudgetSnapshot: (() -> { [string]: any })?,
	GetLeaderboardSnapshot: (() -> { LeaderboardMonitor.Entry })?,
	GetProfileKeyPrefix: (() -> string)?,
	RegisterAddon: ((name: string, actions: { [string]: { Run: (args: any) -> any, Writes: boolean? } }) -> () -> ())?,
}

local ScribeTelemetry = {}
ScribeTelemetry.Version = "1.0.0"
ScribeTelemetry.LogoUrl = Config.LOGO_URL
ScribeTelemetry.DefaultWarningCodes = table.freeze(table.clone(Config.DEFAULT_WARNING_CODES))

local PRIORITY = { Health = 3, Issues = 3, Warnings = 2, Leaderboards = 2, Performance = 2, Summaries = 1, Test = 1 }
local TICK = 1
local MESSAGE_MAX = 1500

-- One running add-on per Scribe module, weakly keyed.
local active: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function defaultHttp()
	return {
		Post = function(url: string, body: string): Transport.Response
			local HttpService = game:GetService("HttpService")
			local ok, result = pcall(function()
				return HttpService:RequestAsync({
					Url = Config.PostUrl(url),
					Method = "POST",
					Headers = { ["Content-Type"] = "application/json" },
					Body = body,
				})
			end)
			if not ok then
				return { Ok = false, Error = tostring(result) }
			end
			return {
				Ok = result.Success == true,
				Status = result.StatusCode,
				Headers = result.Headers,
				Body = result.Body,
				Error = if result.Success then nil else result.StatusMessage,
			}
		end,
	}
end

local function defaultScheduler()
	return {
		Spawn = function(fn: () -> ())
			task.spawn(fn)
		end,
		Wait = function(seconds: number)
			task.wait(seconds)
		end,
	}
end

local function defaultClock()
	return { Now = os.time, Monotonic = os.clock }
end

local function defaultJson()
	local HttpService = game:GetService("HttpService")
	return {
		Encode = function(value: any): string
			return HttpService:JSONEncode(value)
		end,
		Decode = function(text: string): any
			return HttpService:JSONDecode(text)
		end,
	}
end

local function gameMeta(environment: string, scribeVersion: string): Format.Meta
	local function read(name: string, fallback: any): any
		local ok, value = pcall(function()
			return (game :: any)[name]
		end)
		return if ok and value ~= nil then value else fallback
	end
	return {
		PlaceId = read("PlaceId", 0),
		PlaceVersion = read("PlaceVersion", 0),
		JobId = tostring(read("JobId", "")),
		ScribeVersion = scribeVersion,
		Environment = environment,
	}
end

local function duration(seconds: number): string
	if seconds < 10 then
		return string.format("%.2fs", seconds)
	elseif seconds < 60 then
		return `{math.floor(seconds)}s`
	elseif seconds < 3600 then
		return `{math.floor(seconds / 60)}m {math.floor(seconds % 60)}s`
	end
	return `{math.floor(seconds / 3600)}h {math.floor((seconds % 3600) / 60)}m`
end

local function clockText(at: number): string
	local ok, text = pcall(function()
		return os.date("!%H:%M:%S UTC", at)
	end)
	return if ok then text else tostring(at)
end

local function bytesText(n: number): string
	if n >= 1048576 then
		return string.format("%.1f MB", n / 1048576)
	elseif n >= 1024 then
		return string.format("%.1f KB", n / 1024)
	end
	return `{math.floor(n)} B`
end

local Handle = {}
Handle.__index = Handle

function ScribeTelemetry.Start(Scribe: ScribeModule, options: Options): Handle
	for _, name in { "AddLogSink", "GetStatus", "GetMetrics", "GetPercentiles" } do
		if type(Scribe) ~= "table" or type((Scribe :: any)[name]) ~= "function" then
			error(`ScribeTelemetry: the first argument must be the Scribe module (missing {name})`, 0)
		end
	end
	if type(Scribe.OnStatusChanged) ~= "table" or type(Scribe.OnStatusChanged.Connect) ~= "function" then
		error("ScribeTelemetry: the first argument must be the Scribe module (missing OnStatusChanged)", 0)
	end
	local config = Config.Resolve(options)
	if active[Scribe] then
		error("ScribeTelemetry: already started for this Scribe module; Stop() the running one first", 0)
	end

	local self: any = setmetatable({}, Handle)
	self.scribe = Scribe
	self.config = config
	self.deps = {
		Http = options.Http or defaultHttp(),
		Clock = options.Clock or defaultClock(),
		Scheduler = options.Scheduler or defaultScheduler(),
		Json = options.Json or defaultJson(),
		Jitter = options.Jitter or math.random,
	}
	self.meta = gameMeta(config.Environment, tostring(Scribe.Version or "unknown"))
	self.brand = { Name = config.BrandName, IconUrl = config.IconUrl }
	self.running = false
	self.skipped = {} :: { [string]: number }
	self.filtered = { Issues = 0, Warnings = 0, Ignored = 0 }
	self.reports = 0
	self.previews = 0
	self.mentionedAt = {} :: { [string]: number }
	self.nextId = 0

	local register = Scribe.RegisterAddon
	if register ~= nil then
		self.unregister = register("Telemetry", {
			Status = {
				Run = function()
					return self:studioStatus()
				end,
			},
			Preview = {
				Run = function(args: any)
					local ok, why = self:Preview(tostring(args.Destination), args.Kind)
					return { Ok = ok, Reason = why }
				end,
				Writes = true,
			},
		})
	end

	-- `options.Studio` is a test seam.
	local studio = false
	if options.Studio ~= nil then
		studio = options.Studio == true
	else
		pcall(function()
			studio = RunService:IsStudio()
		end)
	end
	if studio and not config.AllowStudio then
		self.state = "DisabledInStudio"
		return self
	end

	active[Scribe] = true
	self.state = "Running"
	self.running = true
	self.transport = Transport.new({
		MaxQueued = config.MaxQueued,
		MaxQueuedBytes = config.MaxQueuedBytes,
		PerDestinationQueued = config.PerDestinationQueued,
		MaxAge = config.MaxAge,
		MaxAttempts = config.MaxAttempts,
		MaxRetryDelay = config.MaxRetryDelay,
	}, self.deps)
	for name, dest in config.Destinations do
		self.transport:AddDestination(name, dest.Url)
	end
	self.router = Router.new(config.GroupInterval, config.GroupExpiry, config.MaxGroups, self.deps.Clock.Monotonic, {
		First = function(record)
			self:reportRecord(record)
		end,
		Summary = function(group)
			self:reportGroup(group)
		end,
	})

	-- Health first: an incident already underway is reported before anything else.
	local status = Scribe.GetStatus()
	self.status = status
	self.statusSince = nil :: number?
	self.statusChanged = (Scribe.OnStatusChanged :: any):Connect(function(new: string, old: string?)
		if self.running then
			self:onStatus(new, old)
		end
	end)
	if status ~= "Healthy" then
		self:reportHealth(nil, status, nil)
	elseif config.ReportHealthyStartup then
		self:reportStartup()
	end

	self.removeSink = Scribe.AddLogSink(function(entry)
		if self.running then
			self:onLog(entry)
		end
	end, { Level = "Warn" })

	self.lastSummary = { At = self.deps.Clock.Monotonic(), Metrics = Scribe.GetMetrics() }
	self.lastPerformance = { At = self.deps.Clock.Monotonic(), Metrics = self.lastSummary.Metrics }
	local startMetrics = self.lastSummary.Metrics
	local savesSoFar = if type(startMetrics) == "table" and type(startMetrics.SaveDuration) == "table"
		then tonumber(startMetrics.SaveDuration.Count) or 0
		else 0
	self.rules = {
		SlowSaves = { Streak = 0, Active = false, LastCount = savesSoFar },
		SaveFailures = { Streak = 0, Active = false },
		Traffic = { Streak = 0, Active = false },
	}
	self.summaryDue = self.deps.Clock.Monotonic() + config.SummaryInterval
	self.performanceDue = self.deps.Clock.Monotonic() + config.PerformanceInterval
	self.leaderboards = LeaderboardMonitor.new(
		Scribe,
		config,
		self.deps.Clock.Monotonic,
		function(entry, previous, observedFor)
			self:reportLeaderboard(entry, previous, observedFor)
		end
	)
	self.leaderboards:Poll()
	self.deps.Scheduler.Spawn(function()
		while self.running do
			self.deps.Scheduler.Wait(TICK)
			if not self.running then
				break
			end
			local ok, err = pcall(self.tick, self)
			if not ok then
				self.lastTickError = tostring(err)
			end
		end
	end)
	return self
end

-- Reports ----------------------------------------------------------------------

function Handle.newId(self: any): string
	self.nextId += 1
	local server = if self.meta.JobId == "" then "studio" else string.sub(self.meta.JobId, 1, 8)
	return string.format("%s-%04x", server, self.nextId % 65536)
end

function Handle.mentionFor(self: any, dest: Config.Destination, kind: string?): string?
	if kind == nil or dest.MentionRoleId == nil or not dest.MentionOn[kind] then
		return nil
	end
	local now = self.deps.Clock.Monotonic()
	local last = self.mentionedAt[dest.Name]
	if last ~= nil and now - last < dest.MentionCooldown then
		return nil
	end
	self.mentionedAt[dest.Name] = now
	return dest.MentionRoleId
end

local PREVIEW_NOTE = "Synthetic data from telemetry:Preview(); nothing here happened on this server."

--- Routes one report to its category's destinations, or records why it went nowhere.
--- Under a preview it goes to that destination alone, below every real report.
function Handle.report(self: any, draft: any, groupKey: string?, preview: any?)
	if not self.running then
		return
	end
	if preview ~= nil then
		local fields = table.clone(draft.Fields)
		table.insert(fields, { Name = "Preview", Value = PREVIEW_NOTE, Inline = false })
		local report: Format.Report = {
			Id = self:newId(),
			Kind = draft.Kind,
			Category = draft.Category,
			Severity = draft.Severity,
			Title = `PREVIEW: {draft.Title}`,
			Code = draft.Code,
			Description = draft.Description,
			Fields = fields,
			At = self.deps.Clock.Now(),
			MentionKind = nil,
			Priority = 0,
		}
		self.previews += 1
		local ok, why = self:deliver(preview.Destination, report, nil)
		if not ok and preview.Failure == nil then
			preview.Failure = why
		end
		return
	end
	local resolution = Config.Route(self.config, draft.Category)
	if resolution.Skipped ~= nil then
		self.skipped[draft.Category] = (self.skipped[draft.Category] or 0) + 1
		return
	end
	local report: Format.Report = {
		Id = self:newId(),
		Kind = draft.Kind,
		Category = draft.Category,
		Severity = draft.Severity,
		Title = draft.Title,
		Code = draft.Code,
		Description = draft.Description,
		Fields = draft.Fields,
		At = self.deps.Clock.Now(),
		MentionKind = draft.MentionKind,
		Priority = PRIORITY[draft.Category] or 1,
	}
	self.reports += 1
	for _, dest in resolution.Destinations do
		self:deliver(dest, report, groupKey)
	end
end

function Handle.reportStartup(self: any, preview: any?)
	self:report({
		Category = "Health",
		Kind = "Health",
		Severity = "Info",
		Title = "Scribe Telemetry started",
		Description = `Scribe reports **Healthy** on this server.`,
		Fields = {},
		MentionKind = nil,
	}, nil, preview)
end

local REFUSALS = {
	["dead-destination"] = "destination is dead",
	overflow = "queue is full",
	stopped = "telemetry is stopped",
}

function Handle.deliver(
	self: any,
	dest: Config.Destination,
	report: Format.Report,
	groupKey: string?
): (boolean, string?)
	local payload = Format.Payload(report, self.meta, self.brand, self:mentionFor(dest, report.MentionKind))
	local ok, encoded = pcall(self.deps.Json.Encode, payload)
	if not ok then
		self.encodeFailures = (self.encodeFailures or 0) + 1
		return false, "the report could not be encoded"
	end
	local queued, why =
		self.transport:Enqueue(dest.Name, report.Id, report.Category, groupKey, report.Priority, encoded)
	if queued then
		return true, nil
	end
	local reason = REFUSALS[why] or tostring(why)
	if why == "dead-destination" then
		local stats = self.transport:Stats().Destinations[dest.Name]
		if stats and stats.LastError then
			reason ..= `: {stats.LastError}`
		end
	end
	return false, reason
end

local function contextFields(context: { [string]: any }?): { Format.Field }
	local fields = {}
	if context == nil then
		return fields
	end
	local keys = {}
	for key in context do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		local value = context[key]
		local text = if type(value) == "table" then "" else tostring(value)
		if type(value) == "table" then
			local parts: { string } = {}
			for k, v in value :: { [any]: any } do
				table.insert(parts, `{k}={tostring(v)}`)
			end
			table.sort(parts)
			text = table.concat(parts, ", ")
		end
		table.insert(fields, { Name = key, Value = text, Inline = #text < 24 })
		if #fields >= 8 then
			break
		end
	end
	return fields
end

function Handle.reportRecord(self: any, record: Router.Record, preview: any?)
	local fields = contextFields(record.Context)
	table.insert(fields, 1, { Name = "Code", Value = `{record.LogCategory}/{record.Code}`, Inline = true })
	table.insert(fields, 2, { Name = "At", Value = clockText(record.At), Inline = true })
	if record.Repeats > 0 then
		table.insert(fields, 3, {
			Name = "Upstream",
			Value = `Scribe folded {record.Repeats} earlier repeat(s) into this entry before it reached telemetry`,
			Inline = false,
		})
	end
	self:report({
		Category = record.Category,
		Kind = record.Kind,
		Severity = record.Severity,
		Title = `{record.Severity}: {record.Code}`,
		Code = record.Code,
		Description = record.Message,
		Fields = fields,
		MentionKind = if record.Severity == "Fatal" or record.Severity == "Error" then record.Severity else nil,
	}, nil, preview)
end

function Handle.reportGroup(self: any, group: Router.Group, preview: any?)
	local sample = group.Sample
	local description =
		`**{group.WindowCount}** more occurrence(s) of {sample.Code} since the last report; **{group.Count}** observed by telemetry since the group opened.`
	if group.Upstream > 0 then
		description ..= ` Scribe itself folded a further {group.Upstream} repeat(s) before they reached telemetry, so the underlying total is higher than the count here.`
	end
	self:report({
		Category = sample.Category,
		Kind = "Repeat",
		Severity = sample.Severity,
		Title = `Still occurring: {sample.Code}`,
		Code = sample.Code,
		Description = description,
		Fields = {
			{ Name = "First", Value = clockText(group.FirstAt), Inline = true },
			{ Name = "Latest", Value = clockText(group.LatestAt), Inline = true },
			{ Name = "Subject", Value = sample.Subject or "none", Inline = true },
			{ Name = "Last message", Value = sample.Message, Inline = false },
		},
		MentionKind = nil,
	}, group.Key, preview)
end

function Handle.reportHealth(self: any, previous: string?, current: string, observedFor: number?, preview: any?)
	local severity: string
	local title: string
	local mention: string?
	if current == "Healthy" then
		severity, title, mention = "Recovery", `Recovered: {previous or "?"} \u{2192} Healthy`, "Recovery"
	elseif current == "Degraded" and previous == "Outage" then
		severity, title, mention = "Degraded", "Partial recovery: Outage \u{2192} Degraded", "Recovery"
	elseif current == "Outage" then
		severity, title, mention = "Outage", `Outage{if previous then ` (was {previous})` else ""}`, "Outage"
	else
		severity, title, mention = "Degraded", `Degraded{if previous then ` (was {previous})` else ""}`, "Degraded"
	end
	local observed = if observedFor ~= nil
		then `{duration(observedFor)} in {previous or "the previous state"} before this change`
		else "already active when telemetry started; its start time is not known here"
	self:report({
		Category = "Health",
		Kind = "Health",
		Severity = severity,
		Title = title,
		Description = "Scribe's observed data-service condition on this server, from its own DataStore traffic. It says nothing about other servers or Roblox as a whole.",
		Fields = {
			{ Name = "Previous", Value = previous or "unknown", Inline = true },
			{ Name = "Current", Value = current, Inline = true },
			{ Name = "At", Value = clockText(self.deps.Clock.Now()), Inline = true },
			{ Name = "Observed", Value = observed, Inline = false },
		},
		MentionKind = mention,
	}, nil, preview)
end

function Handle.reportLeaderboard(
	self: any,
	entry: LeaderboardMonitor.Entry,
	previous: string?,
	observedFor: number?,
	preview: any?
)
	local safe = self:recordFrom("Leaderboards", "Warn", "LEADERBOARD_HEALTH", "Leaderboards", entry.Name, {
		LastReadError = entry.LastReadError,
		LastWriteError = entry.LastWriteError,
	}, 0)
	local recovered = entry.Status == "Healthy"
	local label = `{Sanitize.Truncate(safe.Message, 96)} (bundle {entry.BundleId})`
	local fields: { Format.Field } = {
		{ Name = "Board", Value = label, Inline = false },
		{ Name = "Status", Value = `{previous or "unknown"} → {entry.Status}`, Inline = true },
		{
			Name = "Cache age",
			Value = if entry.ReadAge then duration(entry.ReadAge) else "no successful refresh",
			Inline = true,
		},
		{ Name = "Pending writes", Value = tostring(entry.PendingWrites), Inline = true },
		{ Name = "Retrying writes", Value = tostring(entry.RetryingWrites), Inline = true },
		{ Name = "Rejected writes", Value = tostring(entry.RejectedWrites), Inline = true },
		{
			Name = "Observed",
			Value = if observedFor
				then `{duration(observedFor)} since the previous state was observed`
				else "already degraded when first observed",
			Inline = false,
		},
	}
	for _, field in contextFields(safe.Context) do
		table.insert(fields, field)
	end
	self:report({
		Category = "Leaderboards",
		Kind = "Health",
		Severity = if recovered then "Recovery" else "Degraded",
		Title = `{if recovered then "Leaderboard recovered" else "Leaderboard degraded"}: {label}`,
		Description = "Cached leaderboard health on this server. Profile-saving health is reported separately.",
		Fields = fields,
		MentionKind = if recovered then "Recovery" else "Degraded",
	}, nil, preview)
end

function Handle.leaderboardFields(self: any): { Format.Field }
	local monitor = self.leaderboards
	if monitor == nil or monitor.State ~= "Available" then
		return {
			{
				Name = "Leaderboard health",
				Value = if monitor
					then `{monitor.State}{if monitor.LastError then `: {monitor.LastError}` else ""}`
					else "Unavailable",
				Inline = false,
			},
		}
	end
	local healthy, degraded, starting, pending, retrying, rejected = 0, 0, 0, 0, 0, 0
	for _, entry in monitor.Entries do
		healthy += if entry.Status == "Healthy" then 1 else 0
		degraded += if entry.Status == "Degraded" then 1 else 0
		starting += if entry.Status == "Starting" then 1 else 0
		pending += entry.PendingWrites
		retrying += entry.RetryingWrites
		rejected += entry.RejectedWrites
	end
	local overview = if #monitor.Entries == 0
		then "No active leaderboards"
		else `{healthy} healthy · {degraded} degraded · {starting} starting\n{pending} pending · {retrying} retrying · {rejected} rejected writes`
	if monitor.Omitted > 0 then
		overview ..= `\n{monitor.Omitted} boards omitted by MaxBoards; counts cover monitored boards only`
	end
	if monitor.ObservedAt ~= nil then
		overview ..= `\nSnapshot {duration(math.max(0, self.deps.Clock.Monotonic() - monitor.ObservedAt))} ago`
	end
	local fields: { Format.Field } = { { Name = "Leaderboard health", Value = overview, Inline = false } }
	local entries: { LeaderboardMonitor.Entry } = table.clone(monitor.Entries)
	local rank: { [string]: number } = { Degraded = 1, Starting = 2, Healthy = 3 }
	table.sort(entries, function(a: LeaderboardMonitor.Entry, b: LeaderboardMonitor.Entry)
		if rank[a.Status] ~= rank[b.Status] then
			return rank[a.Status] < rank[b.Status]
		end
		if a.PendingWrites ~= b.PendingWrites then
			return a.PendingWrites > b.PendingWrites
		end
		if a.BundleId ~= b.BundleId then
			return a.BundleId < b.BundleId
		end
		return a.Name < b.Name
	end)
	local lines: { string } = {}
	for i = 1, math.min(5, #entries) do
		local entry = entries[i]
		local safe = self:recordFrom("Leaderboards", "Info", "LEADERBOARD_HEALTH", "Leaderboards", entry.Name, nil, 0)
		local age = if entry.ReadAge then duration(entry.ReadAge) else "no refresh"
		table.insert(
			lines,
			`{Sanitize.Truncate(safe.Message, 64)} (bundle {entry.BundleId}): {entry.Status}; {entry.PendingWrites} pending, {entry.RetryingWrites} retrying, {entry.RejectedWrites} rejected; cache {age}`
		)
	end
	if #entries > 5 then
		table.insert(lines, `+{#entries - 5} more monitored boards`)
	end
	if #lines > 0 then
		table.insert(fields, { Name = "Leaderboard details", Value = table.concat(lines, "\n"), Inline = false })
	end
	return fields
end

-- Collection ---------------------------------------------------------------------

function Handle.onStatus(self: any, new: string, old: string?)
	local previous = old or self.status
	local now = self.deps.Clock.Monotonic()
	local observedFor = if self.statusSince ~= nil then now - self.statusSince else nil
	self.status = new
	self.statusSince = now
	if new == previous then
		return
	end
	self:reportHealth(previous, new, observedFor)
end

--- One log entry as the router sees it, sanitised.
function Handle.recordFrom(
	self: any,
	category: string,
	level: string,
	code: string,
	logCategory: string,
	message: string,
	context: any,
	repeats: number,
	at: number?
): Router.Record
	local config: Config.Resolved = self.config
	-- Asked per entry: a bundle started after the add-on may use another prefix.
	local prefix: string? = nil
	if type(self.scribe.GetProfileKeyPrefix) == "function" then
		local ok, value = pcall(self.scribe.GetProfileKeyPrefix)
		if ok and type(value) == "string" then
			prefix = value
		end
	end
	local options: Sanitize.Options =
		{ IncludePlayerIds = config.IncludePlayerIds, Urls = config.Urls, KeyPrefix = prefix }
	return {
		Category = category,
		Kind = if category == "Issues" then "Issue" else "Warning",
		Severity = level,
		Code = code,
		LogCategory = logCategory,
		Subject = Sanitize.Subject(context, options),
		Message = Sanitize.Text(message, MESSAGE_MAX, options),
		Context = Sanitize.Snapshot(context, options),
		Repeats = repeats,
		At = at or self.deps.Clock.Now(),
	}
end

function Handle.onLog(self: any, entry: any)
	local config: Config.Resolved = self.config
	local level = tostring(entry.Level)
	local code = tostring(entry.Code)
	local logCategory = tostring(entry.Category)
	local category: string? = nil
	if level == "Error" or level == "Fatal" then
		if not (config.ExcludeCodes[code] or config.ExcludeCategories[logCategory]) then
			category = "Issues"
		end
	elseif level == "Warn" then
		if (config.WarningCodes[code] or config.WarningCategories[logCategory]) and not config.ExcludeCodes[code] then
			category = "Warnings"
		end
	end
	if category == nil then
		self.filtered.Ignored += 1
		return
	end
	self.filtered[category] += 1
	local context = entry.Context
	local repeats = 0
	if type(context) == "table" then
		repeats = (tonumber(context.Repeats) or 0) + (tonumber(context.Suppressed) or 0)
	end
	self.router:Offer(
		self:recordFrom(category, level, code, logCategory, entry.Message, context, repeats, tonumber(entry.At))
	)
end

local function counter(metrics: { [string]: any }, name: string): number?
	local value = metrics[name]
	return if type(value) == "number" then value else nil
end

local function delta(current: { [string]: any }, previous: { [string]: any }, name: string): number?
	local a, b = counter(current, name), counter(previous, name)
	if a == nil then
		return nil
	end
	return math.max(0, a - (b or 0))
end

local function percentileText(p: any, format: (number) -> string): string
	if type(p) ~= "table" then
		return "no samples"
	end
	local window = if type(p.Window) == "number" then duration(p.Window) else "?"
	local age = if type(p.Age) == "number" then duration(p.Age) else "?"
	return `p50 {format(p.P50)} \u{00B7} p90 {format(p.P90)} \u{00B7} p99 {format(p.P99)} ({p.Samples or "?"} samples over {window}, newest {age} ago)`
end

type SummaryInputs = {
	Status: string,
	Elapsed: number,
	Metrics: { [string]: any },
	Previous: { [string]: any },
	Percentiles: { [string]: any },
	Budget: { [string]: any }?,
	LeaderboardFields: { Format.Field }?,
}

function Handle.summarise(self: any)
	local now = self.deps.Clock.Monotonic()
	local metrics = self.scribe.GetMetrics()
	local previous = self.lastSummary
	self.lastSummary = { At = now, Metrics = metrics }
	local budget: { [string]: any }? = nil
	if type(self.scribe.GetBudgetSnapshot) == "function" then
		local ok, snapshot = pcall(self.scribe.GetBudgetSnapshot)
		if ok and type(snapshot) == "table" then
			budget = snapshot
		end
	end
	self:reportSummary({
		Status = tostring(self.scribe.GetStatus()),
		Elapsed = math.max(1, now - previous.At),
		Metrics = metrics,
		Previous = previous.Metrics,
		Percentiles = self.scribe.GetPercentiles(),
		Budget = budget,
		LeaderboardFields = self:leaderboardFields(),
	})
end

function Handle.reportSummary(self: any, inputs: SummaryInputs, preview: any?)
	local metrics, percentiles, elapsed = inputs.Metrics, inputs.Percentiles, inputs.Elapsed
	local function count(name: string): string
		local d = delta(metrics, inputs.Previous, name)
		return if d == nil then "n/a" else tostring(d)
	end
	local bytes = delta(metrics, inputs.Previous, "BytesOut")
	local fields: { Format.Field } = {
		{ Name = "Profile health", Value = inputs.Status, Inline = true },
		{ Name = "Sessions", Value = tostring(counter(metrics, "ActiveSessions") or "n/a"), Inline = true },
		{ Name = "Interval", Value = duration(elapsed), Inline = true },
		{
			Name = "Loads",
			Value = `{count("ProfilesLoaded")} ok, {count("ProfileLoadFailures")} failed`,
			Inline = true,
		},
		{ Name = "Saves", Value = `{count("SavesOk")} ok, {count("SavesFailed")} failed`, Inline = true },
		{ Name = "Bytes out", Value = if bytes == nil then "n/a" else `{bytesText(bytes / elapsed)}/s`, Inline = true },
		{ Name = "Save duration", Value = percentileText(percentiles.SaveDuration, duration), Inline = false },
		{ Name = "Profile size", Value = percentileText(percentiles.ProfileSize, bytesText), Inline = false },
	}
	for _, field in inputs.LeaderboardFields or {} do
		table.insert(fields, field)
	end
	for _, field in Diagnostics.Fields(metrics, inputs.Previous, percentiles) do
		table.insert(fields, field)
	end
	local snapshot = inputs.Budget
	if snapshot ~= nil then
		if snapshot.Available then
			local parts = {}
			for _, name in { "UpdateAsync", "GetAsync", "GetSortedAsync", "SetIncrementSortedAsync", "OrderedRemove" } do
				local remaining = snapshot.Budgets[name]
				if remaining ~= nil then
					table.insert(parts, `{name} {remaining}`)
				end
			end
			table.insert(fields, {
				Name = "DataStore budget",
				Value = if #parts > 0 then table.concat(parts, " \u{00B7} ") else "n/a",
				Inline = false,
			})
		else
			table.insert(fields, {
				Name = "DataStore budget",
				Value = `not readable here ({snapshot.Reason or "no reason"})`,
				Inline = false,
			})
		end
	end
	self:report({
		Category = "Summaries",
		Kind = "Summary",
		Severity = "Info",
		Title = `Summary: last {duration(elapsed)} on this server`,
		Code = nil,
		Description = "Counts are the change over the interval; percentiles are over Scribe's rolling sample window, which is not the interval.",
		Fields = fields,
		MentionKind = nil,
	}, nil, preview)
end

function Handle.evaluatePerformance(self: any)
	local config: Config.Resolved = self.config
	local now = self.deps.Clock.Monotonic()
	local metrics = self.scribe.GetMetrics()
	local percentiles = self.scribe.GetPercentiles()
	local previous = self.lastPerformance
	local elapsed = math.max(1, now - previous.At)
	self.lastPerformance = { At = now, Metrics = metrics }

	local function evaluate(name: string, rule: Config.Rule, evidence: boolean, qualifies: boolean, detail: string)
		if not rule.Enabled then
			return
		end
		local state = self.rules[name]
		if not evidence then
			return
		end
		if qualifies then
			state.Streak += 1
			if not state.Active and state.Streak >= config.PerformanceChecks then
				state.Active = true
				self:reportPerformance(name, detail, state.Streak, false)
			end
		else
			state.Streak = 0
			if state.Active then
				state.Active = false
				self:reportPerformance(name, detail, 0, true)
			end
		end
	end

	local slow = config.Rules.SlowSaves
	local saveP = percentiles.SaveDuration
	local saveCount = if type(metrics.SaveDuration) == "table" then tonumber(metrics.SaveDuration.Count) or 0 else 0
	local fresh = saveCount - self.rules.SlowSaves.LastCount >= slow.MinSamples
	self.rules.SlowSaves.LastCount = saveCount
	local slowEvidence = fresh and type(saveP) == "table" and (tonumber(saveP.Samples) or 0) >= slow.MinSamples
	evaluate(
		"SlowSaves",
		slow,
		slowEvidence,
		slowEvidence and saveP.P99 > slow.Threshold,
		if slowEvidence
			then `Save p99 is {duration(saveP.P99)} against a threshold of {duration(slow.Threshold)}`
			else ""
	)

	local failures = delta(metrics, previous.Metrics, "SavesFailed")
	local perMinute = if failures ~= nil then failures / (elapsed / 60) else 0
	evaluate(
		"SaveFailures",
		config.Rules.SaveFailures,
		failures ~= nil,
		failures ~= nil and failures > 0 and perMinute > config.Rules.SaveFailures.Threshold,
		string.format(
			"Save failures at %.1f per minute against a threshold of %.1f",
			perMinute,
			config.Rules.SaveFailures.Threshold
		)
	)

	local bytes = delta(metrics, previous.Metrics, "BytesOut")
	local perSecond = if bytes ~= nil then bytes / elapsed else 0
	evaluate(
		"Traffic",
		config.Rules.Traffic,
		bytes ~= nil,
		bytes ~= nil and bytes > 0 and perSecond > config.Rules.Traffic.Threshold,
		`Outbound traffic at {bytesText(perSecond)}/s against a threshold of {bytesText(config.Rules.Traffic.Threshold)}/s`
	)
end

function Handle.reportPerformance(
	self: any,
	name: string,
	detail: string,
	streak: number,
	cleared: boolean,
	preview: any?
)
	if cleared then
		self:report({
			Category = "Performance",
			Kind = "Performance",
			Severity = "Recovery",
			Title = `Performance cleared: {name}`,
			Code = name,
			Description = detail,
			Fields = {},
			MentionKind = nil,
		}, nil, preview)
		return
	end
	self:report({
		Category = "Performance",
		Kind = "Performance",
		Severity = "Performance",
		Title = `Performance: {name}`,
		Code = name,
		Description = `{detail} for {streak} consecutive checks of {duration(self.config.PerformanceInterval)}.`,
		Fields = {},
		MentionKind = "Performance",
	}, nil, preview)
end

function Handle.tick(self: any)
	local now = self.deps.Clock.Monotonic()
	self.router:Tick()
	self.leaderboards:Tick()
	if now >= self.performanceDue then
		self.performanceDue = now + self.config.PerformanceInterval
		self:evaluatePerformance()
	end
	if self.config.SummariesEnabled and now >= self.summaryDue then
		self.summaryDue = now + self.config.SummaryInterval
		self:summarise()
	end
end

-- Lifecycle ----------------------------------------------------------------------

--- Sends a test message to one destination, outside the routes. Returns false with a
--- reason when it could not be queued.
function Handle.Test(self: any, destinationName: string): (boolean, string?)
	if self.state ~= "Running" then
		return false, self.state
	end
	local dest = self.config.Destinations[destinationName]
	if dest == nil then
		return false, `no destination named "{tostring(destinationName)}"`
	end
	if not dest.Enabled then
		return false, "destination is disabled"
	end
	local report: Format.Report = {
		Id = self:newId(),
		Kind = "Test",
		Category = "Test",
		Severity = "Info",
		Title = "Test message",
		Code = nil,
		Description = `Scribe Telemetry can reach **{dest.Name}** from this server.`,
		Fields = {
			{ Name = "Scribe", Value = self.meta.ScribeVersion, Inline = true },
			{ Name = "Telemetry", Value = ScribeTelemetry.Version, Inline = true },
		},
		At = self.deps.Clock.Now(),
		MentionKind = nil,
		Priority = 1,
	}
	return self:deliver(dest, report, nil)
end

--- Synthetic examples of the add-on's reports to one destination: the real builders, a
--- PREVIEW title, no mention, the normal queue. `kind` is "All", a group, or one scenario.
function Handle.Preview(self: any, destinationName: string, kind: PreviewKind?): (boolean, string?)
	if self.state ~= "Running" then
		return false, self.state
	end
	local dest = self.config.Destinations[destinationName]
	if dest == nil then
		return false, `no destination named "{tostring(destinationName)}"`
	end
	if not dest.Enabled then
		return false, "destination is disabled"
	end
	local context = { Destination = dest, Failure = nil :: string? }
	local chosen: string = if kind == nil then "All" else kind
	local ok, why = pcall(Preview.Run, self, chosen, context)
	if not ok then
		return false, tostring(why)
	end
	if why ~= nil then
		return false, why
	end
	if self.state ~= "Running" then
		return false, self.state
	end
	if context.Failure ~= nil then
		return false, context.Failure
	end
	return true, nil
end

--- The state, enabled destinations and preview kinds, for the plugin.
function Handle.studioStatus(self: any): { [string]: any }
	local destinations = {}
	for name, dest in self.config.Destinations do
		if dest.Enabled then
			table.insert(destinations, name)
		end
	end
	table.sort(destinations)
	return { State = self.state, Destinations = destinations, Kinds = Preview.KINDS }
end

--- Waits up to `timeout` seconds for the queues to drain.
function Handle.Flush(self: any, timeout: number?): boolean
	if self.state ~= "Running" then
		return true
	end
	return self.transport:Flush(timeout or 5)
end

function Handle.GetStats(self: any): Stats
	local stats: { [string]: any } = if self.transport
		then self.transport:Stats()
		else {
			Queued = 0,
			QueuedBytes = 0,
			Delivered = 0,
			Retries = 0,
			Uncertain = 0,
			Dropped = Transport.EmptyDropped(),
			Destinations = {},
		}
	stats.State = self.state
	stats.Reports = self.reports
	stats.Previews = self.previews
	stats.Skipped = table.clone(self.skipped)
	stats.Filtered = table.clone(self.filtered)
	stats.Groups = if self.router then self.router.count else 0
	stats.EncodeFailures = self.encodeFailures or 0
	stats.LastTickError = self.lastTickError
	local monitor = self.leaderboards
	stats.Leaderboards = {
		State = if monitor then monitor.State else self.state,
		Monitored = if monitor then #monitor.Entries else 0,
		Omitted = if monitor then monitor.Omitted else 0,
		SnapshotAge = if monitor and monitor.ObservedAt
			then math.max(0, self.deps.Clock.Monotonic() - monitor.ObservedAt)
			else nil,
		LastError = if monitor then monitor.LastError else nil,
	}
	return stats
end

--- Stops everything: the sink, the status connection, the workers and the queues. Safe
--- to call twice.
function Handle.Stop(self: any)
	local unregister: (() -> ())? = self.unregister
	if unregister ~= nil then
		unregister()
		self.unregister = nil
	end
	if self.state ~= "Running" then
		self.state = "Stopped"
		return
	end
	self.state = "Stopped"
	self.running = false
	self.leaderboards:Stop()
	if self.removeSink then
		(self.removeSink :: () -> ())()
		self.removeSink = nil
	end
	if self.statusChanged then
		self.statusChanged:Disconnect()
		self.statusChanged = nil
	end
	self.transport:Stop()
	self.router:Clear()
	active[self.scribe] = nil
end

return ScribeTelemetry
