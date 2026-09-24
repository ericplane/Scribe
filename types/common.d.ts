import type { BigValue, Disconnect } from "./schema";

/** Arbitrary stored or external data is unknown until the caller validates it. */
export type UnknownRecord = { [key: string]: unknown };
export type PathSegment = string | number;
export type Path = ReadonlyArray<PathSegment>;
export type OpKind = "Init" | "Set" | "Insert" | "Remove" | "Clear";
export interface Op { Kind: OpKind; Path: Path; Value?: unknown; Index?: number; }

/** Transport functions are genuine colon methods; accessor/API functions are not. */
export interface ScribeTransport {
    readonly Name: string;
    readonly MaxFrameBytes?: number;
    SendToClient(player: Player, bytes: buffer): void;
    SendToAllClients?(bytes: buffer): void;
    ListenServer(callback: (this: void, player: Player, bytes: buffer) => void): void;
    SendToServer(bytes: buffer): void;
    ListenClient(callback: (this: void, bytes: buffer) => void): void;
    Release?(): void;
}

export interface Connection {
    readonly Connected: boolean;
    Disconnect(): void;
}
/** Read-only event surface. Scribe owns firing and destroying these signals. */
export interface Signal<Args extends unknown[]> {
    Connect(callback: (this: void, ...args: Args) => void): Connection;
    Once(callback: (this: void, ...args: Args) => void): Connection;
    Wait(): LuaTuple<Args>;
}

export type LogLevel = "Debug" | "Info" | "Warn" | "Error" | "Fatal";
/** Each sink has its own severity filter and bounded callback queue. */
export interface LogSinkOptions { Level?: LogLevel; MaxQueued?: number; }
export type LogCategory = "Persistence" | "Replication" | "Transport" | "Commands" | "Leaderboards" | "Monetization" | "Gifting" | "Integrity" | "Lifecycle" | "Derived" | "Exchanges";
/** Public diagnostic codes, kept in sync with src/Types.luau. */
export type LogCode =
    | "DATASTORE_CRITICAL"
    | "DATASTORE_RECOVERED"
    | "EXPORT_ENCODE_FAIL"
    | "LEGACY_IMPORTED"
    | "LEGACY_IMPORT_FAIL"
    | "MIGRATED"
    | "MESSAGE_SEND_FAIL"
    | "MESSAGE_QUEUE_FULL"
    | "MESSAGE_NO_LISTENER"
    | "MESSAGE_HANDLER_ERROR"
    | "MESSAGE_HANDLER_STALLED"
    | "MIGRATION_FAIL"
    | "MIGRATION_RECONCILE_DEPENDENT"
    | "MIGRATION_RESERVED_DISCARDED"
    | "MODE_OVERRIDES_LEGACY"
    | "OFFLINE_READ_FAIL"
    | "OFFLINE_WRITE_FAIL"
    | "NOSAVE_WRITE_REFUSED"
    | "PROFILE_ERASED"
    | "PROFILE_ERASE_FAIL"
    | "PROFILE_ERASE_PROGRESS_FAIL"
    | "PROFILE_ERASE_RESUMED"
    | "PROFILE_LOADED"
    | "PROFILE_LOAD_FAIL"
    | "PROFILE_RESET"
    | "PROFILE_RESTORED"
    | "PROFILE_RESTORE_FAIL"
    | "RESTORE_RESERVED_PRESERVED"
    | "PROFILE_SIZE"
    | "SLOW_LOAD"
    | "SLOW_IMPORT"
    | "SAVE_WAIT_TIMEOUT"
    | "PROFILE_STORE_ERROR"
    | "PROFILE_STORE_SIGNAL_MISSING"
    | "PROFILE_TOO_LARGE"
    | "PROFILE_UNPERSISTABLE"
    | "PROFILE_VERSION_AHEAD"
    | "SAVE_INTERVAL_CLAMPED"
    | "WIPE_GUARD_RATIO_CLAMPED"
    | "HEALTH_THRESHOLDS_CONFLICT"
    | "SAVE_INTERVAL_CONFLICT"
    | "SAVE_INTERVAL_FAIL"
    | "SAVE_INTERVAL_SET"
    | "SHUTDOWN_DONE"
    | "SHUTDOWN_FLUSH"
    | "SIM_LOAD_FAILURE"
    | "SIM_SESSION_STEAL"
    | "STATUS_CHANGED"
    | "UNKNOWN_ROOT_KEYS"
    | "VERSION_QUERY_FAIL"
    | "VERSION_READ_FAIL"
    | "ANALYTICS_FAIL"
    | "ANOMALY"
    | "ECONOMY_FIELDS_OVERFLOW"
    | "ECONOMY_FIELD_UNDECLARED"
    | "PROFILE_OVERWRITTEN"
    | "PROFILE_TOO_DEEP"
    | "PROFILE_SCHEMA_VIOLATION"
    | "TIMED_SWEEP_FAIL"
    | "WIPE_GUARD_BLOCKED"
    | "WIPE_GUARD_CLEARED"
    | "WIPE_GUARD_FORCED"
    | "WIPE_GUARD_TRIPPED"
    | "CLIENT_HANDSHAKE_TIMEOUT"
    | "FRAGMENT_REFUSED"
    | "INIT_APPLIED"
    | "INIT_SEND_FAIL"
    | "MIRROR_RESYNC"
    | "INIT_SENT"
    | "INIT_UNDELIVERED"
    | "OP_BEFORE_INIT"
    | "OUTBOUND_OVERSIZE"
    | "PROTOCOL_MISMATCH"
    | "SCHEMA_MISMATCH"
    | "SERIALIZE_FAIL"
    | "SNAPSHOT_ROOT_DROPPED"
    | "INBOUND_OVERSIZE"
    | "INBOUND_OVERSIZE_LIMIT"
    | "INBOUND_RATE_LIMITED"
    | "INBOUND_WORK_LIMIT"
    | "MALFORMED_FRAME"
    | "MALFORMED_FRAME_LIMIT"
    | "SEND_FAIL"
    | "COMMAND_BAD_ARGS"
    | "COMMAND_BAD_IDEMPOTENCY_KEY"
    | "COMMAND_ERROR"
    | "COMMAND_IDEM_EVICTED"
    | "COMMAND_IDEM_SATURATED"
    | "COMMAND_RATE_LIMITED"
    | "COMMAND_REPLY_ENCODE_FAIL"
    | "COMMAND_REPLY_TRUNCATED"
    | "COMMAND_UNKNOWN"
    | "SIM_COMMAND"
    | "GRANT_FAIL"
    | "GRANT_PARTIAL"
    | "GRANT_SEEDED_ELEMENT"
    | "RECEIPT_IN_FLIGHT"
    | "RECEIPT_HISTORY_FULL"
    | "OWNERSHIP_CHECK_FAIL"
    | "PASS_PURCHASE_UNCONFIRMED"
    | "PERK_GRANTED"
    | "PERK_REVOKED"
    | "PRODUCT_INFO_FAIL"
    | "POLICY_READ_FAIL"
    | "PAID_RANDOM_RECEIPT"
    | "PRODUCT_INFO_THROTTLED"
    | "PURCHASE_DUPLICATE"
    | "PURCHASE_CLAIM_EVICTED"
    | "PURCHASE_ID_EVICTED"
    | "RECEIPT_DUPLICATE"
    | "RECEIPT_GRANTED"
    | "RECEIPT_HANDLER_BOUND"
    | "RECEIPT_OFFLINE_RETRY"
    | "RECEIPT_RETRY"
    | "RECEIPT_UNKNOWN_PRODUCT"
    | "SIM_RECEIPT"
    | "UNDECLARED_CATEGORY"
    | "UNDECLARED_PERK"
    | "UNKNOWN_OWNS_KEY"
    | "GIFT_AIM_CAP_REACHED"
    | "GIFT_AIM_EXPIRED"
    | "GIFT_AIM_SETTLED"
    | "GIFT_CREDIT_ISSUED"
    | "GIFT_CREDIT_REFUND_FAIL"
    | "GIFT_CREDIT_UNCONFIRMED"
    | "GIFT_CREDIT_UNKNOWN_PRODUCT"
    | "GIFT_CREDIT_USED"
    | "GIFT_DELIVERY_RETRY"
    | "GIFT_INTENT_EXPIRED"
    | "GIFT_INTENT_WRITE_FAIL"
    | "GIFT_NO_INTENT"
    | "GIFT_RECEIPT_GRANTED"
    | "GIFT_RECIPIENT_ALREADY_OWNS"
    | "GIFT_UNKNOWN_PRODUCT"
    | "RECEIPT_DECLINED_PENDING_CREDIT"
    | "RECEIPT_HELD"
    | "LB_ERASE_FAIL"
    | "LB_INTERVAL_CLAMPED"
    | "LB_QUEUE_OVERFLOW"
    | "LB_READ_FAIL"
    | "LB_SCORE_OUT_OF_RANGE"
    | "LB_SHUTDOWN_FLUSH"
    | "LB_STAT_RESOLVE_FAIL"
    | "LB_UNKNOWN_BOARD"
    | "LB_BUDGET_DEFERRED"
    | "LB_WRITE_DROPPED"
    | "LB_WRITE_FAIL"
    | "SIM_LB_FLUSH"
    | "EXCHANGE_INIT_TAMPER"
    | "EXCHANGE_PARKED"
    | "EXCHANGE_REGISTRATION_REFUSED"
    | "EXCHANGE_RESET_REFUSED"
    | "EXCHANGE_RESOLVED"
    | "EXCHANGE_RESOLVE_ERROR"
    | "EXCHANGE_STORE_UNAVAILABLE"
    | "EXCHANGE_UNRESOLVED"
    | "DERIVED_ERROR"
    | "DERIVED_FEEDBACK"
    | "DERIVED_MISMATCH"
    | "API_NAME_COLLISION"
    | "DEBUG_HOOK_ATTACHED"
    | "DEBUG_HOOK_ATTRIBUTION"
    | "DEBUG_HOOK_DUPLICATE"
    | "DEBUG_HOOK_ERROR"
    | "DEBUG_HOOK_FAIL"
    | "DEBUG_HOOK_WRITES"
    | "DEV_WARNING"
    | "DYNAMIC_DEFAULT_FAILED"
    | "LISTENER_ERROR"
    | "ON_PLAYER_INIT_ERROR"
    | "PLAYER_LEAVING_HOOK_SLOW"
    | "SANDBOXED"
    | "SERVER_STARTED"
    | "SIM_STATUS"
    | "SUBSYSTEM_HOOK_ERROR"
    | "UNKNOWN_OPTION";
export interface LogEntry {
    At: number;
    Level: LogLevel;
    Category: LogCategory;
    Code: LogCode;
    Message: string;
    Context?: UnknownRecord;
}
export interface LogFilter { Level?: LogLevel; Category?: LogCategory; Code?: LogCode; Limit?: number; }
export type Status = "Healthy" | "Degraded" | "Outage";
export type SessionState = "Loading" | "Ready" | "SessionEnded";
/** The second GetState return is present only while the session is loading. */
export type LoadPhase = "WaitingForErase" | "AcquiringSession" | "ReadingProfile" | "Retrying" | "Initializing" | "Importing" | "ImportThrottled";
export type Visibility = "Replicated" | "ServerOnly" | "Shared";
export type LifecycleReason = "load-failed" | "migration-failed" | "erasing" | "session-ended" | "player-left" | "shutdown" | "still-loading" | "timeout";
export type RequestReason = "rate-limited" | "not-ready" | "unknown-command" | "bad-args" | "bad-idempotency-key" | "error" | "reply-encode-failed" | "timeout" | "send-failed" | "edit-mode" | "mock-error";
declare const requestFailedBrand: unique symbol;
/** Identity token returned only for framework refusals, never a handler result. */
export interface RequestFailedMarker { readonly [requestFailedBrand]: true; }
export type RequestFailure = LuaTuple<[false, RequestReason, RequestFailedMarker]>;
export type ProductState = "purchasable" | "owned" | "paid-random-restricted" | "policy-pending" | "not-loaded";
export type PurchaseReason = "player data not loaded" | "invalid Cost spec" | "invalid Cost amount" | "invalid cost path" | "cost path is not a spendable number" | "insufficient funds" | "paid random items are not available for this account" | "cannot check account settings right now; try again in a moment";
export type GiftReason = "buyer data not loaded" | "invalid recipient" | "cannot gift yourself" | "gift cooldown" | "product retired" | "too many pending gifts" | "data services are experiencing issues; try again later" | "recipient already owns this" | "could not reserve gift credit; try again later" | "could not deliver gift; try again later" | "gift delivery could not be confirmed; do not send it again" | "a gift of this item is already pending; try again shortly" | "could not record gift intent; try again later" | "paid random items are not available for this account" | "cannot check account settings right now; try again in a moment";
export type OperationResult = LuaTuple<[boolean, string | undefined]>;

export interface SaveInfo { LastSaveAt?: number; LastResult?: "Ok" | "Fail"; Dirty: boolean; Size?: number; }
export interface SaveEvent { Player: Player; Ok: boolean; Duration?: number; At: number; }
export interface Anomaly { Player: Player; Path: Path; Value?: unknown; Reason: string; }
export interface GiftReceived { FromUserId: number; Product: string; GiftId: string; }
export interface VersionRecord { VersionId: string; CreatedAt: number; Size?: number; }
export type ViolationKind = "WrongType" | "OutOfBounds" | "OverMaxLength" | "NotAMember" | "BadEncoding" | "UnknownKey";
export interface SchemaViolation { Path: Path; Kind: ViolationKind; Detail: string; Advisory?: boolean; }
export interface FlushOptions { Force?: boolean; Timeout?: number; }
export interface UpdateOfflineOptions { Validate?: boolean; }
export interface RestoreOptions { RollBackReserved?: boolean; }
export interface CooldownOptions { IncludeOfflineTime?: boolean; }
export interface MigrationContext {
    readonly AwaitBudget: (this: void, requestType: string, count?: number, timeout?: number) => LuaTuple<[boolean, Disconnect]>;
}

export type BigScore = Pick<BigValue, "M" | "E" | "Short" | "ToNumber" | "Log10">;
export interface LeaderboardEntry { Rank: number; UserId: number; Name: string; Score: number | BigScore; }
export type LeaderboardStatus = "Starting" | "Healthy" | "Degraded";
/** Cached board health; reading it makes no DataStore requests. */
export interface LeaderboardStatusInfo {
    Status: LeaderboardStatus;
    PendingWrites: number;
    RetryingWrites: number;
    RejectedWrites: number;
    LastReadAt?: number;
    ReadAge?: number;
    LastWriteAt?: number;
    LastReadError?: string;
    LastWriteError?: string;
}
/** A process-local bundle ID identifies the board's running bundle. */
export interface LeaderboardSnapshotEntry extends LeaderboardStatusInfo { BundleId: number; Name: string; }
export interface PassConfig { Id: number; Category?: string; }
export interface PurchaseFilter { Kind?: "Robux" | "InGame"; Category?: string; ItemId?: string; Since?: number; Limit?: number; }
/** RecordPurchase accepts game-defined fields, so only Kind is universally present. */
export interface PurchaseEntry extends UnknownRecord {
    Kind: "Robux" | "InGame";
    Ts?: number;
    Category?: string;
    ItemId?: string;
    Product?: string;
    PurchaseId?: string;
    PriceInRobux?: number;
    Currency?: string;
    Amount?: number;
    Meta?: UnknownRecord;
}
export interface PurchaseLogOptions { RobuxCap?: number; InGameCap?: number; ReplicateRobux?: boolean; ReplicateInGame?: boolean; PurchaseLogCategories?: ReadonlyArray<string>; }
export interface ProductInfo extends UnknownRecord {
    Name?: string;
    Description?: string;
    ProductId?: number;
    AssetId?: number;
    IconImageAssetId?: number;
    IsForSale?: boolean;
    PriceInRobux?: number;
    UserBasePriceInRobux?: number;
    PriceDiscountDetails?: UnknownRecord;
}
export interface PolicyInfo extends UnknownRecord { ArePaidRandomItemsRestricted?: boolean; }
export interface ReceiptInfo {
    PlayerId: number;
    ProductId: number;
    PurchaseId: string;
    CurrencySpent?: number;
    PlaceIdWherePurchased?: number;
}

export interface EconomyMeta {
    Flow?: "Source" | "Sink";
    TransactionType?: Enum.AnalyticsEconomyTransactionType | string;
    ItemSku?: string;
    Currency?: string;
    Fields?: UnknownRecord;
    Source?: string;
    Item?: string;
}
export type EconomyFieldSpec = string | { Name: string; Prefix?: boolean };
export interface EconomyCurrencyConfig { Label?: string; Fields?: ReadonlyArray<EconomyFieldSpec>; Resolve?: (this: void, player: Player) => UnknownRecord; }
export type EconomyLogFn = (this: void, player: Player, flowType: Enum.AnalyticsEconomyFlowType, currencyType: string, amount: number, endingBalance: number, transactionType: string, itemSku?: string, customFields?: UnknownRecord) => void;
export interface EconomyConfig { Resolve?: (this: void, player: Player) => UnknownRecord; Prefix?: boolean; Currencies?: { [currency: string]: EconomyCurrencyConfig }; LogEconomyEvent?: EconomyLogFn; }

export interface ExchangeableSpec { Path: ReadonlyArray<string>; Kind: "Key" | "Qty" | "Stack"; Count?: string; Identity?: ReadonlyArray<string>; Ignore?: ReadonlyArray<string>; }
export type ExchangeLeg =
    | { Path: Path; Kind: "Key"; Key: unknown; Amount?: never; Value?: unknown }
    | { Path: Path; Kind: "Qty"; Key?: never; Amount: number; Value?: unknown }
    | { Path: Path; Kind: "Stack"; Key: unknown; Amount: number; Value?: unknown };
export interface OpenLeg { Path: Path; Kind: "Key" | "Qty" | "Stack"; Key?: unknown; Amount?: number; }
export interface OpenExchange { Id: string; State: "Claimed" | "Staked" | "Delivering"; Partner?: number; Staked: OpenLeg[]; Owed: OpenLeg[]; Since?: number; }
export interface ExchangeAPI {
    readonly Attempt: (this: void, playerA: Player, basketA: ReadonlyArray<ExchangeLeg>, playerB: Player, basketB: ReadonlyArray<ExchangeLeg>) => LuaTuple<["Committed" | "Aborted" | undefined, string | undefined]>;
    readonly Open: (this: void, player: Player) => OpenExchange[];
    readonly Discard: (this: void, exchangeId: string) => OperationResult;
    readonly Settle: (this: void, exchangeId: string, verdict: "Commit" | "Abort") => OperationResult;
    readonly Redirect: (this: void, exchangeId: string, userId: number, newKey: string) => OperationResult;
}

export interface BudgetSnapshot { Available: boolean; Reason?: string; Budgets: { [requestType: string]: number }; At: number; }
export interface MetricObservation { Count: number; Average: number; Max: number; }
export type Metrics = { [name: string]: number | MetricObservation };
export interface Percentiles { P50: number; P90: number; P99: number; Samples: number; Age: number; Window: number; }
export type PercentileSnapshot = { [name: string]: Percentiles };
export interface AddonAction { Run: (this: void, args: unknown) => unknown; Writes?: boolean; }
export type AddonActions = { [name: string]: AddonAction };
export interface ConfigureOptions { AutoSaveInterval?: number; }
export interface StatusThresholds { FailWindow?: number; FailCount?: number; RecoverStreak?: number; }
export interface PeriodResetOptions { UtcOffset?: number; WeekStart?: "Monday" | "Tuesday" | "Wednesday" | "Thursday" | "Friday" | "Saturday" | "Sunday"; }

export interface MockState {
    Perks?: ReadonlyArray<string>;
    GiftCredits?: { [product: string]: number };
    PurchaseLogs?: { Robux?: ReadonlyArray<UnknownRecord>; InGame?: ReadonlyArray<UnknownRecord> };
    Leaderboards?: { [name: string]: ReadonlyArray<LeaderboardEntry> };
}

