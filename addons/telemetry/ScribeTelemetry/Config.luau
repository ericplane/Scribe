--!strict
-- Validates and resolves the options handed to Start; a refusal names the field.

local Config = {}

local Transport = require(script.Parent.Transport)

export type Category = "Health" | "Issues" | "Warnings" | "Performance" | "Summaries"
export type MentionKind = "Fatal" | "Error" | "Outage" | "Degraded" | "Recovery" | "Performance"
-- One name, several, or false for nowhere.
export type Route = string | { string } | false

export type WebhookOptions = {
	Url: string,
	Enabled: boolean?,
	Mention: { RoleId: string, On: { MentionKind }?, Cooldown: number? }?,
}

export type RuleOptions = { Threshold: number?, MinSamples: number?, Enabled: boolean? }
export type RuleSetOptions = { SlowSaves: RuleOptions?, SaveFailures: RuleOptions?, Traffic: RuleOptions? }
export type WarningOptions = { Include: { string }?, Categories: { string }? }
export type IssueOptions = { ExcludeCodes: { string }?, ExcludeCategories: { string }? }
export type GroupingOptions = { Interval: number?, Expiry: number?, MaxGroups: number? }
export type SummaryOptions = { Enabled: boolean?, Interval: number? }
export type PerformanceOptions = { Interval: number?, Checks: number?, Rules: RuleSetOptions? }
export type LimitOptions = {
	MaxQueued: number?,
	MaxQueuedBytes: number?,
	PerDestination: number?,
	MaxAge: number?,
	MaxAttempts: number?,
	MaxRetryDelay: number?,
}

--- What Start accepts; only Webhooks is required, and the seams are for tests.
export type Options = {
	Webhooks: { [string]: WebhookOptions },
	Default: string?,
	Routes: { Health: Route?, Issues: Route?, Warnings: Route?, Performance: Route?, Summaries: Route? }?,
	Warnings: WarningOptions?,
	Issues: IssueOptions?,
	Grouping: GroupingOptions?,
	Summaries: SummaryOptions?,
	Performance: PerformanceOptions?,
	Limits: LimitOptions?,
	IncludePlayerIds: boolean?,
	Environment: string?,
	AllowStudio: boolean?,
	ReportHealthyStartup: boolean?,
	Http: Transport.Http?,
	Clock: Transport.Clock?,
	Scheduler: Transport.Scheduler?,
	Json: Transport.Json?,
	Jitter: (() -> number)?,
	Studio: boolean?,
}

export type Destination = {
	Name: string,
	Url: string,
	Enabled: boolean,
	MentionRoleId: string?,
	-- Which report kinds may mention the role: "Fatal", "Error", "Outage", "Degraded", "Recovery", "Performance".
	MentionOn: { [string]: boolean },
	MentionCooldown: number,
}

export type Rule = {
	Enabled: boolean,
	Threshold: number,
	MinSamples: number,
}

export type Resolved = {
	Destinations: { [string]: Destination },
	Default: string?,
	-- Per category: a list of destination names, false for explicitly off, nil for unset.
	Routes: { [string]: { string } | boolean },
	WarningCodes: { [string]: boolean },
	WarningCategories: { [string]: boolean },
	ExcludeCodes: { [string]: boolean },
	ExcludeCategories: { [string]: boolean },
	GroupInterval: number,
	GroupExpiry: number,
	MaxGroups: number,
	SummaryInterval: number,
	SummariesEnabled: boolean,
	PerformanceInterval: number,
	PerformanceChecks: number,
	Rules: { SlowSaves: Rule, SaveFailures: Rule, Traffic: Rule },
	MaxQueued: number,
	MaxQueuedBytes: number,
	PerDestinationQueued: number,
	MaxAge: number,
	MaxAttempts: number,
	MaxRetryDelay: number,
	IncludePlayerIds: boolean,
	Environment: string,
	AllowStudio: boolean,
	ReportHealthyStartup: boolean,
	BrandName: string,
	IconUrl: string,
	Urls: { string }, -- every configured URL, longest first, for redaction
}

Config.CATEGORIES = { "Health", "Issues", "Warnings", "Performance", "Summaries" }

-- Fixed, like the name beside it: every message is visibly Scribe's.
Config.LOGO_URL = "https://raw.githubusercontent.com/ericplane/Scribe/main/docgen/theme/assets/favicon.png"
Config.BRAND_NAME = "Scribe Telemetry"

-- Forwarded by default: warnings a developer acts on (docgen/guides/log-codes.md).
Config.DEFAULT_WARNING_CODES = {
	"PROFILE_SIZE",
	"SLOW_LOAD",
	"WIPE_GUARD_BLOCKED",
	"WIPE_GUARD_FORCED",
	"PURCHASE_ID_EVICTED",
	"PURCHASE_CLAIM_EVICTED",
	"GIFT_CREDIT_UNCONFIRMED",
	"PASS_PURCHASE_UNCONFIRMED",
	"LB_WRITE_DROPPED",
}

local MENTION_KINDS =
	{ Fatal = true, Error = true, Outage = true, Degraded = true, Recovery = true, Performance = true }

local function fail(message: string)
	error(`ScribeTelemetry: {message}`, 0)
end

local function number(value: any, field: string, default: number, min: number): number
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value ~= value or value < min then
		fail(`{field} must be a number of at least {min}`)
	end
	return value
end

local function boolean(value: any, field: string, default: boolean): boolean
	if value == nil then
		return default
	end
	if type(value) ~= "boolean" then
		fail(`{field} must be true or false`)
	end
	return value
end

local function set(list: any, field: string): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if list == nil then
		return out
	end
	if type(list) ~= "table" then
		fail(`{field} must be a list of strings`)
	end
	for _, item in list :: { any } do
		if type(item) ~= "string" then
			fail(`{field} must contain only strings`)
		end
		out[item] = true
	end
	return out
end

-- Discord, a proxy in front of it, or a service of your own; Discord refuses Roblox's servers.
local function isEndpointUrl(url: string): boolean
	return string.match(url, "^https?://[%w%.%-%[%]:]+[/?]") ~= nil
		or string.match(url, "^https?://[%w%.%-%[%]:]+$") ~= nil
end

--- The URL to post to. Discord answers a webhook with 204 and no body unless `wait=true`
--- is asked for, so that is added on Discord's path (a proxy keeps it) and nowhere else.
function Config.PostUrl(url: string): string
	if string.find(url, "/api/webhooks/", 1, true) == nil then
		return url
	end
	return url .. (if string.find(url, "?", 1, true) then "&wait=true" else "?wait=true")
end

local function destination(name: string, raw: any): Destination
	if type(raw) ~= "table" then
		fail(`Webhooks.{name} must be a table`)
	end
	if type(raw.Url) ~= "string" or not isEndpointUrl(raw.Url) then
		fail(`Webhooks.{name}.Url must be an http or https URL with a host`)
	end
	local mention = raw.Mention
	local roleId: string? = nil
	local on: { [string]: boolean } = {}
	local cooldown = 300
	if mention ~= nil then
		if type(mention) ~= "table" then
			fail(`Webhooks.{name}.Mention must be a table`)
		end
		if type(mention.RoleId) ~= "string" or string.match(mention.RoleId, "^%d+$") == nil then
			fail(`Webhooks.{name}.Mention.RoleId must be a role id as a string of digits`)
		end
		roleId = mention.RoleId
		for kind in set(mention.On or { "Fatal", "Outage" }, `Webhooks.{name}.Mention.On`) do
			if not MENTION_KINDS[kind] then
				fail(`Webhooks.{name}.Mention.On has an unknown kind "{kind}"`)
			end
			on[kind] = true
		end
		cooldown = number(mention.Cooldown, `Webhooks.{name}.Mention.Cooldown`, 300, 0)
	end
	return {
		Name = name,
		Url = raw.Url,
		Enabled = boolean(raw.Enabled, `Webhooks.{name}.Enabled`, true),
		MentionRoleId = roleId,
		MentionOn = on,
		MentionCooldown = cooldown,
	}
end

local function rule(raw: any, field: string, defaultMinSamples: number): Rule
	if raw == nil then
		return { Enabled = false, Threshold = 0, MinSamples = defaultMinSamples }
	end
	if type(raw) ~= "table" then
		fail(`{field} must be a table`)
	end
	if type(raw.Threshold) ~= "number" or raw.Threshold <= 0 then
		fail(`{field}.Threshold must be a positive number; there is no default`)
	end
	return {
		Enabled = boolean(raw.Enabled, `{field}.Enabled`, true),
		Threshold = raw.Threshold,
		MinSamples = number(raw.MinSamples, `{field}.MinSamples`, defaultMinSamples, 1),
	}
end

--- Resolves and validates `options`, raising a message that names the field otherwise.
function Config.Resolve(options: Options): Resolved
	if type(options) ~= "table" then
		fail("Start needs an options table")
	end
	if type(options.Webhooks) ~= "table" then
		fail("Webhooks must be a table of named destinations")
	end
	local destinations: { [string]: Destination } = {}
	local count = 0
	for name, raw in options.Webhooks do
		if type(name) ~= "string" or name == "" then
			fail("every Webhooks key must be a non-empty name")
		end
		destinations[name] = destination(name, raw)
		count += 1
	end
	if count == 0 then
		fail("Webhooks must name at least one destination")
	end

	local default: string? = options.Default
	if default ~= nil then
		if type(default) ~= "string" or destinations[default] == nil then
			fail(`Default names a destination that is not in Webhooks: "{tostring(default)}"`)
		end
	end

	local routes: { [string]: { string } | boolean } = {}
	local rawRoutes = options.Routes or {}
	if type(rawRoutes) ~= "table" then
		fail("Routes must be a table")
	end
	for category, route in rawRoutes do
		if not table.find(Config.CATEGORIES, category) then
			fail(`Routes.{tostring(category)} is not a report category; use {table.concat(Config.CATEGORIES, ", ")}`)
		end
		if route == false then
			routes[category] = false
		elseif type(route) == "string" then
			if destinations[route] == nil then
				fail(`Routes.{category} names a destination that is not in Webhooks: "{route}"`)
			end
			routes[category] = { route }
		elseif type(route) == "table" then
			local names = {}
			for _, item in route :: { any } do
				if type(item) ~= "string" or destinations[item] == nil then
					fail(`Routes.{category} names a destination that is not in Webhooks: "{tostring(item)}"`)
				end
				table.insert(names, item)
			end
			if #names == 0 then
				fail(`Routes.{category} is an empty list; use false to disable the category`)
			end
			routes[category] = names
		else
			fail(`Routes.{category} must be a destination name, a list of names, or false`)
		end
	end

	local warnings: WarningOptions = options.Warnings or {}
	if type(warnings) ~= "table" then
		fail("Warnings must be a table")
	end
	local issues: IssueOptions = options.Issues or {}
	if type(issues) ~= "table" then
		fail("Issues must be a table")
	end
	local grouping: GroupingOptions = options.Grouping or {}
	local summaries: SummaryOptions = options.Summaries or {}
	local performance: PerformanceOptions = options.Performance or {}
	local rules: RuleSetOptions = performance.Rules or {}
	local limits: LimitOptions = options.Limits or {}
	local tables: { [string]: any } =
		{ Grouping = grouping, Summaries = summaries, Performance = performance, Limits = limits, Rules = rules }
	for field, value in tables do
		if type(value) ~= "table" then
			fail(`{field} must be a table`)
		end
	end

	local environment = options.Environment
	if environment ~= nil and type(environment) ~= "string" then
		fail("Environment must be a string")
	end
	if (options :: any).IconUrl ~= nil or (options :: any).BrandName ~= nil then
		fail("IconUrl and BrandName are fixed to Scribe's own and cannot be set")
	end

	local urls: { string } = {}
	for _, dest in destinations do
		if table.find(urls, dest.Url) == nil then
			table.insert(urls, dest.Url)
		end
	end
	table.sort(urls, function(a: string, b: string)
		return #a > #b
	end)

	return {
		Destinations = destinations,
		Default = default,
		Routes = routes,
		Urls = urls,
		WarningCodes = set(warnings.Include or Config.DEFAULT_WARNING_CODES, "Warnings.Include"),
		WarningCategories = set(warnings.Categories, "Warnings.Categories"),
		ExcludeCodes = set(issues.ExcludeCodes, "Issues.ExcludeCodes"),
		ExcludeCategories = set(issues.ExcludeCategories, "Issues.ExcludeCategories"),
		GroupInterval = number(grouping.Interval, "Grouping.Interval", 60, 1),
		GroupExpiry = number(grouping.Expiry, "Grouping.Expiry", 600, 1),
		MaxGroups = number(grouping.MaxGroups, "Grouping.MaxGroups", 128, 1),
		SummariesEnabled = boolean(summaries.Enabled, "Summaries.Enabled", false),
		SummaryInterval = number(summaries.Interval, "Summaries.Interval", 1800, 60),
		PerformanceInterval = number(performance.Interval, "Performance.Interval", 60, 5),
		PerformanceChecks = number(performance.Checks, "Performance.Checks", 3, 1),
		Rules = {
			SlowSaves = rule(rules.SlowSaves, "Performance.Rules.SlowSaves", 20),
			SaveFailures = rule(rules.SaveFailures, "Performance.Rules.SaveFailures", 1),
			Traffic = rule(rules.Traffic, "Performance.Rules.Traffic", 1),
		},
		MaxQueued = number(limits.MaxQueued, "Limits.MaxQueued", 200, 1),
		MaxQueuedBytes = number(limits.MaxQueuedBytes, "Limits.MaxQueuedBytes", 262144, 1024),
		PerDestinationQueued = number(limits.PerDestination, "Limits.PerDestination", 64, 1),
		MaxAge = number(limits.MaxAge, "Limits.MaxAge", 900, 10),
		MaxAttempts = number(limits.MaxAttempts, "Limits.MaxAttempts", 5, 1),
		MaxRetryDelay = number(limits.MaxRetryDelay, "Limits.MaxRetryDelay", 300, 1),
		IncludePlayerIds = boolean(options.IncludePlayerIds, "IncludePlayerIds", false),
		Environment = environment or "production",
		AllowStudio = boolean(options.AllowStudio, "AllowStudio", false),
		ReportHealthyStartup = boolean(options.ReportHealthyStartup, "ReportHealthyStartup", false),
		BrandName = Config.BRAND_NAME,
		IconUrl = Config.LOGO_URL,
	}
end

export type Resolution = {
	Destinations: { Destination },
	Skipped: string?, -- "disabled", "unrouted" or "none-enabled" when the list is empty
}

--- The enabled destinations a category delivers to, deduplicated by webhook URL so two
--- names on one channel cannot deliver a report twice. An explicit `false` never falls
--- back to the default; an omitted route does.
function Config.Route(config: Resolved, category: string): Resolution
	local route = config.Routes[category]
	local names: { string }
	if route == false then
		return { Destinations = {}, Skipped = "disabled" }
	elseif route == nil then
		if config.Default == nil then
			return { Destinations = {}, Skipped = "unrouted" }
		end
		names = { config.Default :: string }
	else
		names = route :: { string }
	end
	local out: { Destination } = {}
	local seenUrl: { [string]: boolean } = {}
	for _, name in names do
		local dest = config.Destinations[name]
		if dest ~= nil and dest.Enabled and not seenUrl[dest.Url] then
			seenUrl[dest.Url] = true
			table.insert(out, dest)
		end
	end
	return { Destinations = out, Skipped = if #out == 0 then "none-enabled" else nil }
end

return Config
