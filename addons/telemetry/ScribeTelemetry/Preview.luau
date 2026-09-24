--!strict
-- Synthetic examples of every report the add-on sends, built by the real builders.

local Router = require(script.Parent.Router)

local Preview = {}

export type Kind =
	"All"
	| "Health"
	| "Issues"
	| "Warnings"
	| "Grouping"
	| "Performance"
	| "Leaderboards"
	| "Summaries"
	| "Formatting"
	| "HealthyStartup"
	| "Degraded"
	| "Outage"
	| "PartialRecovery"
	| "Recovery"
	| "IncidentUnderway"
	| "Warning"
	| "Error"
	| "Fatal"
	| "Repeat"
	| "UpstreamSuppressed"
	| "SlowLoad"
	| "SlowLeavingHook"
	| "ReceiptCapacity"
	| "ReceiptRoutingRetry"
	| "LeaderboardDegraded"
	| "LeaderboardRecovery"
	| "SlowSaves"
	| "SlowSavesCleared"
	| "SaveFailures"
	| "SaveFailuresCleared"
	| "Traffic"
	| "TrafficCleared"
	| "Summary"
	| "SummaryNoSamples"
	| "SummaryNoBudget"
	| "LongMessage"
	| "RedactedContext"

export type Scenario = { Name: string, Group: string, Run: (handle: any, preview: any) -> () }

local USER = 1234567

local function issue(level: string, code: string, category: string, message: string, context: { [string]: any })
	return function(handle: any, preview: any)
		handle:reportRecord(handle:recordFrom("Issues", level, code, category, message, context, 0), preview)
	end
end

local function warning(code: string, category: string, message: string, context: { [string]: any }, repeats: number?)
	return function(handle: any, preview: any)
		handle:reportRecord(
			handle:recordFrom("Warnings", "Warn", code, category, message, context, repeats or 0),
			preview
		)
	end
end

local function health(previous: string?, current: string, observedFor: number?)
	return function(handle: any, preview: any)
		handle:reportHealth(previous, current, observedFor, preview)
	end
end

local function performance(name: string, detail: string, streak: number, cleared: boolean)
	return function(handle: any, preview: any)
		handle:reportPerformance(name, detail, streak, cleared, preview)
	end
end

local function summary(shape: string)
	return function(handle: any, preview: any)
		local metrics = {
			ActiveSessions = 42,
			ProfilesLoaded = 180,
			ProfileLoadFailures = 1,
			SavesOk = 620,
			SavesFailed = 2,
			BytesOut = 52428800,
			ReceiptHistoryRefusals = 1,
			LogSinkDropped = 12,
			LogSinkErrors = 2,
			LbWrites = 1240,
			LbWritesSkipped = 810,
			LbReadFailures = 2,
			LbWriteFailures = 3,
			LbQueueDepth = 4,
			LbBudgetDeferred = 18,
			LbQueueOverflow = 0,
		}
		local percentiles: { [string]: any } = {
			SaveDuration = { P50 = 0.42, P90 = 0.9, P99 = 1.6, Samples = 620, Window = 600, Age = 3 },
			ProfileSize = { P50 = 24000, P90 = 61000, P99 = 118000, Samples = 180, Window = 600, Age = 12 },
			ProfileLoadDuration = { P50 = 0.6, P90 = 1.8, P99 = 5.2, Samples = 180, Window = 600, Age = 12 },
			LoadDuration = { P50 = 0.9, P90 = 2.4, P99 = 8.5, Samples = 180, Window = 600, Age = 12 },
			PlayerLeavingHookDuration = { P50 = 0.01, P90 = 0.2, P99 = 1.1, Samples = 150, Window = 600, Age = 18 },
		}
		local budget: { [string]: any }? = {
			Available = true,
			Budgets = { UpdateAsync = 812, GetAsync = 954, SetIncrementSortedAsync = 190 },
		}
		if shape == "nosamples" then
			metrics = { ActiveSessions = 0, ProfilesLoaded = 0, ProfileLoadFailures = 0, SavesOk = 0, SavesFailed = 0 }
			percentiles = {}
		elseif shape == "nobudget" then
			budget = { Available = false, Reason = "budget API unavailable in this context" }
		end
		handle:reportSummary({
			Status = "Healthy",
			Elapsed = handle.config.SummaryInterval,
			Metrics = metrics,
			Previous = { LbWrites = 1000, LbWritesSkipped = 500, LbBudgetDeferred = 10 },
			Percentiles = percentiles,
			Budget = budget,
			LeaderboardFields = {
				{
					Name = "Leaderboard health",
					Value = "1 healthy · 0 degraded · 0 starting\n4 pending · 0 retrying · 0 rejected writes",
				},
				{
					Name = "Leaderboard details",
					Value = "TopCoins (bundle 1): Healthy; 4 pending, 0 retrying, 0 rejected; cache 2.00s",
				},
			},
		}, preview)
	end
end

local function repeatGroup(handle: any, preview: any)
	local now = handle.deps.Clock.Now()
	local sample = handle:recordFrom(
		"Issues",
		"Error",
		"SAVE_FAILED",
		"Persistence",
		"UpdateAsync failed: 502 (Bad Gateway); the profile stays in memory and the next autosave retries",
		{ Attempt = 2, UserId = USER },
		0
	)
	handle:reportGroup(
		{
			Key = "preview",
			Sample = sample,
			FirstAt = now - 900,
			LatestAt = now,
			Count = 14,
			WindowCount = 6,
			Upstream = 3,
			SummaryDue = nil,
			LastSeen = 0,
			Touched = 0,
		} :: Router.Group,
		preview
	)
end

local manyKeys: { [string]: any } = {}
for i = 1, 10 do
	manyKeys[`Key{i}`] = `value {i}`
end

Preview.SCENARIOS = table.freeze({
	{
		Name = "HealthyStartup",
		Group = "Health",
		Run = function(handle: any, preview: any)
			handle:reportStartup(preview)
		end,
	},
	{ Name = "Degraded", Group = "Health", Run = health("Healthy", "Degraded", 3 * 3600 + 120) },
	{ Name = "Outage", Group = "Health", Run = health("Degraded", "Outage", 240) },
	{ Name = "PartialRecovery", Group = "Health", Run = health("Outage", "Degraded", 95) },
	{ Name = "Recovery", Group = "Health", Run = health("Degraded", "Healthy", 1500) },
	{ Name = "IncidentUnderway", Group = "Health", Run = health(nil, "Outage", nil) },
	{
		Name = "LeaderboardDegraded",
		Group = "Leaderboards",
		Run = function(handle: any, preview: any)
			handle:reportLeaderboard({
				BundleId = 1,
				Name = "TopCoins",
				Status = "Degraded",
				PendingWrites = 8,
				RetryingWrites = 3,
				RejectedWrites = 0,
				ReadAge = 180,
				LastReadError = "HTTP 503 (Service Unavailable)",
				LastWriteError = "OrderedDataStore write throttled",
			}, "Healthy", 120, preview)
		end,
	},
	{
		Name = "LeaderboardRecovery",
		Group = "Leaderboards",
		Run = function(handle: any, preview: any)
			handle:reportLeaderboard({
				BundleId = 1,
				Name = "TopCoins",
				Status = "Healthy",
				PendingWrites = 0,
				RetryingWrites = 0,
				RejectedWrites = 0,
				ReadAge = 2,
			}, "Degraded", 300, preview)
		end,
	},
	{
		Name = "Warning",
		Group = "Warnings",
		Run = warning(
			"PROFILE_SIZE",
			"Persistence",
			"Profile is 3.9 MB of the 4 MB DataStore limit; saves fail once it grows past it",
			{ Bytes = 3900000, Limit = 4194304, UserId = USER, Root = "Inventory" }
		),
	},
	{
		Name = "Error",
		Group = "Issues",
		Run = issue(
			"Error",
			"SAVE_FAILED",
			"Persistence",
			"UpdateAsync failed after 3 attempts: 502 (Bad Gateway); the profile stays in memory and the next autosave retries",
			{ Attempt = 3, UserId = USER, Store = "PlayerData" }
		),
	},
	{
		Name = "Fatal",
		Group = "Issues",
		Run = issue(
			"Fatal",
			"LOAD_FAILED",
			"Persistence",
			"The profile could not be loaded after 5 attempts; the player was kicked so nothing is written over their data",
			{ Attempts = 5, UserId = USER, LastError = "HTTP 500 (Internal Server Error)" }
		),
	},
	{ Name = "Repeat", Group = "Grouping", Run = repeatGroup },
	{
		Name = "SlowLoad",
		Group = "Warnings",
		Run = warning("SLOW_LOAD", "Persistence", "profile load exceeded 10s; inspect its phase and store errors", {
			UserId = USER,
			Phase = "ProfileAcquisition",
			Duration = 12.4,
		}),
	},
	{
		Name = "SlowLeavingHook",
		Group = "Warnings",
		Run = warning("PLAYER_LEAVING_HOOK_SLOW", "Lifecycle", "OnPlayerLeaving exceeded 10s before the final save", {
			UserId = USER,
			Reason = "Left",
			Duration = 11.2,
		}),
	},
	{
		Name = "ReceiptCapacity",
		Group = "Issues",
		Run = issue(
			"Error",
			"RECEIPT_HISTORY_FULL",
			"Monetization",
			"receipt history is full; grant deferred without dropping recent completed IDs",
			{
				UserId = USER,
				Bytes = 1048590,
				Limit = 1048576,
				ProfileBytes = 1700000,
			}
		),
	},
	{
		Name = "ReceiptRoutingRetry",
		Group = "Warnings",
		Run = warning(
			"RECEIPT_RETRY",
			"Monetization",
			"gift route or recipient proof unavailable; letting Roblox retry",
			{
				UserId = USER,
				Product = "GiftVIP",
				PurchaseId = "preview-receipt",
			}
		),
	},
	{
		Name = "UpstreamSuppressed",
		Group = "Grouping",
		Run = warning(
			"LB_WRITE_FAIL",
			"Leaderboards",
			"leaderboard write is still pending after repeated failures; retrying with backoff",
			{ Board = "TopCoins", UserId = USER },
			12
		),
	},
	{
		Name = "SlowSaves",
		Group = "Performance",
		Run = performance("SlowSaves", "Save p99 is 2.4s against a threshold of 2s", 3, false),
	},
	{
		Name = "SlowSavesCleared",
		Group = "Performance",
		Run = performance("SlowSaves", "Save p99 is 800ms against a threshold of 2s", 0, true),
	},
	{
		Name = "SaveFailures",
		Group = "Performance",
		Run = performance("SaveFailures", "Save failures at 4.0 per minute against a threshold of 1.0", 3, false),
	},
	{
		Name = "SaveFailuresCleared",
		Group = "Performance",
		Run = performance("SaveFailures", "Save failures at 0.0 per minute against a threshold of 1.0", 0, true),
	},
	{
		Name = "Traffic",
		Group = "Performance",
		Run = performance("Traffic", "Outbound traffic at 260 KB/s against a threshold of 200 KB/s", 3, false),
	},
	{
		Name = "TrafficCleared",
		Group = "Performance",
		Run = performance("Traffic", "Outbound traffic at 40 KB/s against a threshold of 200 KB/s", 0, true),
	},
	{ Name = "Summary", Group = "Summaries", Run = summary("full") },
	{ Name = "SummaryNoSamples", Group = "Summaries", Run = summary("nosamples") },
	{ Name = "SummaryNoBudget", Group = "Summaries", Run = summary("nobudget") },
	{
		Name = "LongMessage",
		Group = "Formatting",
		Run = issue(
			"Error",
			"LONG_MESSAGE",
			"Preview",
			string.rep("A long message that would otherwise run past what an embed can carry. ", 60),
			manyKeys
		),
	},
	{
		Name = "RedactedContext",
		Group = "Formatting",
		Run = warning(
			"REDACTED",
			"Preview",
			"A message naming a webhook https://discord.com/api/webhooks/1234/abcd and a player",
			{
				UserId = USER,
				PlayerId = 7654321,
				RecipientId = 1111111,
				Note = "player ids are redacted unless IncludePlayerIds is on",
			}
		),
	},
} :: { Scenario })

local kinds = { "All" }
local seen: { [string]: boolean } = {}
for _, scenario in Preview.SCENARIOS do
	if not seen[scenario.Group] then
		seen[scenario.Group] = true
		table.insert(kinds, scenario.Group)
	end
end
for _, scenario in Preview.SCENARIOS do
	table.insert(kinds, scenario.Name)
end
--- Every kind, in menu order.
Preview.KINDS = table.freeze(kinds)

--- Runs the scenarios `kind` names on `handle` under `preview`; returns why nothing ran, or nil.
function Preview.Run(handle: any, kind: string, preview: any): string?
	local ran = 0
	for _, scenario in Preview.SCENARIOS do
		if kind == "All" or kind == scenario.Group or kind == scenario.Name then
			scenario.Run(handle, preview)
			ran += 1
		end
	end
	if ran == 0 then
		return `no preview named "{tostring(kind)}"`
	end
	return nil
end

return Preview
