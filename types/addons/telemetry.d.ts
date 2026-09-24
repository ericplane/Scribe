import type Scribe from "@rbxts/scribe";

/** Optional server-side diagnostics reporter. Importing it does not start reporting. */
declare namespace ScribeTelemetry {
	const Version: string;
	const LogoUrl: string;
	const DefaultWarningCodes: readonly string[];
	type LogEntry = Scribe.LogEntry;

	type Category = "Health" | "Issues" | "Warnings" | "Performance" | "Summaries" | "Leaderboards";
	type MentionKind = "Fatal" | "Error" | "Outage" | "Degraded" | "Recovery" | "Performance";
	type Route<Destination extends string = string> = Destination | readonly Destination[] | false;
	type PreviewKind =
		| "All" | "Health" | "Issues" | "Warnings" | "Grouping" | "Performance" | "Leaderboards" | "Summaries" | "Formatting"
		| "HealthyStartup" | "Degraded" | "Outage" | "PartialRecovery" | "Recovery" | "IncidentUnderway"
		| "Warning" | "Error" | "Fatal" | "Repeat" | "UpstreamSuppressed"
		| "SlowLoad" | "SlowLeavingHook" | "ReceiptCapacity" | "ReceiptRoutingRetry"
		| "LeaderboardDegraded" | "LeaderboardRecovery"
		| "SlowSaves" | "SlowSavesCleared" | "SaveFailures" | "SaveFailuresCleared" | "Traffic" | "TrafficCleared"
		| "Summary" | "SummaryNoSamples" | "SummaryNoBudget" | "LongMessage" | "RedactedContext";

	interface WebhookOptions {
		Url: string;
		Enabled?: boolean;
		Mention?: { RoleId: string; On?: readonly MentionKind[]; Cooldown?: number };
	}
	interface RuleOptions {
		/** Positive threshold; a rule has no default threshold. */
		Threshold: number;
		MinSamples?: number;
		Enabled?: boolean;
	}
	interface RuleSetOptions {
		SlowSaves?: RuleOptions;
		SaveFailures?: RuleOptions;
		Traffic?: RuleOptions;
	}
	interface WarningOptions { Include?: readonly string[]; Categories?: readonly string[] }
	interface IssueOptions { ExcludeCodes?: readonly string[]; ExcludeCategories?: readonly string[] }
	interface GroupingOptions { Interval?: number; Expiry?: number; MaxGroups?: number }
	interface SummaryOptions { Enabled?: boolean; Interval?: number }
	/** Observes cached leaderboard snapshots; never requests a leaderboard refresh. */
	interface LeaderboardOptions { Enabled?: boolean; Interval?: number; MaxBoards?: number }
	interface PerformanceOptions { Interval?: number; Checks?: number; Rules?: RuleSetOptions }
	interface LimitOptions {
		MaxQueued?: number;
		MaxQueuedBytes?: number;
		PerDestination?: number;
		MaxAge?: number;
		MaxAttempts?: number;
		MaxRetryDelay?: number;
	}
	interface HttpResponse {
		Ok: boolean;
		Status?: number;
		Headers?: { [name: string]: string | undefined };
		Body?: string;
		Error?: string;
	}
	interface Http { readonly Post: (this: void, url: string, body: string) => HttpResponse }
	interface Clock { readonly Now: (this: void) => number; readonly Monotonic: (this: void) => number }
	interface Scheduler { readonly Spawn: (this: void, callback: (this: void) => void) => void; readonly Wait: (this: void, seconds: number) => void }
	interface Json { readonly Encode: (this: void, value: unknown) => string; readonly Decode: (this: void, text: string) => unknown }

	interface Options<Destination extends string = string> {
		Webhooks: { [K in Destination]: WebhookOptions };
		Default?: NoInfer<Destination>;
		Routes?: Partial<Record<Category, Route<NoInfer<Destination>>>>;
		Warnings?: WarningOptions;
		Issues?: IssueOptions;
		Grouping?: GroupingOptions;
		Summaries?: SummaryOptions;
		Leaderboards?: LeaderboardOptions;
		Performance?: PerformanceOptions;
		Limits?: LimitOptions;
		IncludePlayerIds?: boolean;
		Environment?: string;
		AllowStudio?: boolean;
		ReportHealthyStartup?: boolean;
		/** Dependency seams for tests. Omit in normal game code. */
		Http?: Http;
		Clock?: Clock;
		Scheduler?: Scheduler;
		Json?: Json;
		Jitter?: (this: void) => number;
		Studio?: boolean;
	}

	interface Dropped {
		Overflow: number;
		Expired: number;
		Malformed: number;
		DeadDestination: number;
		Exhausted: number;
		Stopped: number;
		Coalesced: number;
	}
	interface DestinationStats {
		State: "Ready" | "Dead" | "Stopped";
		Queued: number;
		Delivered: number;
		Failures: number;
		LastDeliveredAt?: number;
		LastError?: string;
	}
	type LeaderboardMonitorState = "Available" | "Unavailable" | "Disabled" | "DisabledInStudio" | "Stopped";
	interface LeaderboardStats {
		State: LeaderboardMonitorState;
		Monitored: number;
		Omitted: number;
		SnapshotAge?: number;
		LastError?: string;
	}
	interface Stats<Destination extends string = string> {
		State: "Running" | "DisabledInStudio" | "Stopped";
		Queued: number;
		QueuedBytes: number;
		Delivered: number;
		Retries: number;
		Uncertain: number;
		Dropped: Dropped;
		LastDeliveredAt?: number;
		/** Empty when disabled in Studio; entries must be checked before reading. */
		Destinations: Partial<Record<Destination, DestinationStats>>;
		Reports: number;
		Previews: number;
		Skipped: Partial<Record<Category, number>>;
		Filtered: { Issues: number; Warnings: number; Ignored: number };
		Groups: number;
		EncodeFailures: number;
		LastTickError?: string;
		Leaderboards: LeaderboardStats;
	}
	interface Handle<Destination extends string = string> {
		Test(destination: Destination): LuaTuple<[boolean, string | undefined]>;
		Preview(destination: Destination, kind?: PreviewKind): LuaTuple<[boolean, string | undefined]>;
		Flush(timeout?: number): boolean;
		GetStats(): Stats<Destination>;
		Stop(): void;
	}
	type ScribeModule = Pick<typeof Scribe,
		"AddLogSink" | "GetStatus" | "GetMetrics" | "GetPercentiles"
	> & { readonly OnStatusChanged: Pick<typeof Scribe.OnStatusChanged, "Connect"> }
	& Partial<Pick<typeof Scribe, "Version" | "GetBudgetSnapshot" | "GetLeaderboardSnapshot" | "GetProfileKeyPrefix" | "RegisterAddon">>;

	/** One handle may run per Scribe module. Stop the previous handle before starting another. */
	function Start<Destination extends string>(scribe: ScribeModule, options: Options<Destination>): Handle<Destination>;
}

export = ScribeTelemetry;
