import type { Accessor, PlayerData, ValueOf, InputOf, ClientSchema, SharedSchema, ReadonlyAccessor, NumericPaths, Disconnect, Datatype, BigValue, BigOperand } from "./schema";
import type { UnknownRecord, ScribeTransport, Signal, LifecycleReason, SessionState, LoadPhase, Status, ProductState, RequestFailure, RequestFailedMarker, OperationResult, SaveInfo, SaveEvent, Anomaly, GiftReceived, VersionRecord, SchemaViolation, FlushOptions, UpdateOfflineOptions, RestoreOptions, CooldownOptions, MigrationContext, LeaderboardEntry, LeaderboardStatusInfo, PassConfig, PurchaseFilter, PurchaseEntry, PurchaseLogOptions, ProductInfo, PolicyInfo, ReceiptInfo, EconomyConfig, ExchangeableSpec, ExchangeAPI, LogLevel, StatusThresholds, PeriodResetOptions, MockState } from "./common";

export interface LeaderboardConfig<T = unknown> {
    Stat: NumericPaths<T, true>;
    Limit?: number;
    Scale?: number;
    SigFigs?: number;
    Replicate?: boolean;
    RefreshInterval?: number;
    /** Minimum seconds between changed-score writes per player/store (default 30, minimum 1). Ignored for Server scope. */
    WriteInterval?: number;
    StoreName?: string;
    Period?: "Daily" | "Weekly";
    Mode?: "Gain" | "Peak";
    Scope?: "Global" | "Server";
}
export interface ProductConfig<T = unknown> {
    Id: number;
    Category?: string;
    Grant?: (this: void, data: PlayerData<T>) => void;
    Grants?: string;
    PaidRandom?: boolean;
}
export interface PurchaseSpec<T = unknown> {
    /** Strings and BigValue amounts require a Big currency. */
    Cost: { Path: NumericPaths<T, true>; Amount: BigOperand };
    Category?: string;
    ItemId: string;
    Grant?: (this: void, data: PlayerData<T>) => void;
    Meta?: UnknownRecord;
    IdempotencyKey?: string;
    PaidRandom?: boolean;
}

/** A shared command contract maps each command name to its arguments and LuaTuple result. */
export type CommandArguments<F> = F extends (this: void, ...args: infer A) => unknown ? A : never;
export type CommandReturn<F> = F extends (this: void, ...args: never[]) => infer R ? R extends LuaTuple<unknown[]> ? R : never : never;
export type CommandHandler<F> = (this: void, player: Player, ...args: CommandArguments<F>) => CommandReturn<F>;
export interface CommandSpec { Args?: ReadonlyArray<unknown>; Idempotent?: boolean; }

/** Uncontracted commands deliberately expose unknown results instead of claiming inferred safety. */
export type RequestFunction<C> = keyof C extends never
    ? (this: void, name: string, ...args: unknown[]) => LuaTuple<unknown[]>
    : <K extends keyof C & string>(this: void, name: K, ...args: CommandArguments<C[K]>) => CommandReturn<C[K]> | RequestFailure;
export type RequestOnceFunction<C> = keyof C extends never
    ? (this: void, name: string, key: string, ...args: unknown[]) => LuaTuple<unknown[]>
    : <K extends keyof C & string>(this: void, name: K, key: string, ...args: CommandArguments<C[K]>) => CommandReturn<C[K]> | RequestFailure;
export type RegisterCommand<C> = keyof C extends never ? {
    <A extends unknown[], R>(this: void, name: string, handler: (this: void, player: Player, ...args: A) => R): void;
    <A extends unknown[], R>(this: void, name: string, spec: CommandSpec, handler: (this: void, player: Player, ...args: A) => R): void;
} : {
    <K extends keyof C & string>(this: void, name: K, handler: CommandHandler<C[K]>): void;
    <K extends keyof C & string>(this: void, name: K, spec: CommandSpec, handler: CommandHandler<C[K]>): void;
};
export type MockCommand<C> = keyof C extends never
    ? <A extends unknown[], R>(this: void, name: string, handler: (this: void, ...args: A) => R) => void
    : <K extends keyof C & string>(this: void, name: K, handler: C[K]) => void;

export type ServerStore<S> = { readonly [K in keyof S]: Accessor<S[K]> };
export type ClientServerStore<S> = { readonly [K in keyof ClientSchema<S>]: ReadonlyAccessor<ClientSchema<S>[K]> };
type ServerStoreMember<S> = keyof S extends never ? { readonly ServerStore?: never } : { readonly ServerStore: ServerStore<S> };
type ClientStoreMember<S> = keyof S extends never ? { readonly ServerStore?: never } : { readonly ServerStore: ClientServerStore<S> };
export type SharedData<T> = ValueOf<SharedSchema<ClientSchema<T>>>;

export interface ServerAPI<T, C = {}> {
    /** Returns the player's accessor tree; errors unless the profile is Ready. */
    readonly Get: (this: void, player: Player) => PlayerData<T>;
    /** Waits for a Ready profile, returning `undefined` and a reason on failure. */
    readonly WaitForData: (this: void, player: Player, timeout?: number) => LuaTuple<[PlayerData<T> | undefined, LifecycleReason | undefined]>;
    /** Reads session state and loading phase without yielding. */
    readonly GetState: (this: void, player: Player) => LuaTuple<[SessionState, LoadPhase | undefined]>;
    /** Groups writes into one replication flush and container notification pass. */
    readonly Batch: (this: void, player: Player, callback: (this: void) => void) => void;
    /** Runs non-yielding writes atomically in memory; does not save them. */
    readonly Transaction: (this: void, player: Player, callback: (this: void) => void) => OperationResult;
    /** Waits for pending changes to save; requires a Ready profile. */
    readonly Flush: (this: void, player: Player, options?: FlushOptions) => boolean;
    /** Reads the player's last save result and pending-change state. */
    readonly GetSaveInfo: (this: void, player: Player) => SaveInfo;
    /** Returns a raw profile snapshot; packed values may use an older schema. */
    readonly GetOffline: (this: void, userId: number) => UnknownRecord | undefined;
    /** Updates an offline profile, with optional template validation. */
    readonly UpdateOffline: (this: void, userId: number, callback: (this: void, rawData: UnknownRecord) => void, options?: UpdateOfflineOptions) => LuaTuple<[boolean, string | undefined, SchemaViolation[] | undefined]>;
    /** Lists saved profile versions for support tools. */
    readonly ListVersions: (this: void, userId: number, limit?: number) => VersionRecord[];
    /** Reads a historical raw snapshot, which may use an older schema. */
    readonly GetVersion: (this: void, userId: number, versionId: string) => UnknownRecord | undefined;
    /** Restores an existing offline profile while preserving reserved data by default. */
    readonly RestoreVersion: (this: void, userId: number, versionId: string, options?: RestoreOptions) => OperationResult;
    /** Deletes the profile and leaderboard records while blocking this user's joins. */
    readonly Erase: (this: void, userId: number) => OperationResult;
    /** Serializes a profile to JSON, or returns `undefined` when absent. */
    readonly Export: (this: void, userId: number) => string | undefined;
    /** Registers a validated, rate-limited command for Ready players. */
    readonly Command: RegisterCommand<C>;
    /** Reads cached board results without a live DataStore request. */
    readonly GetLeaderboard: (this: void, name: string, limit?: number, offset?: number) => LeaderboardEntry[];
    /** Reads the player's rank from the leaderboard cache. */
    readonly GetMyRank: (this: void, player: Player, name: string) => number | undefined;
    /** Reads the next scheduled refresh delay; `undefined` until scheduled. */
    readonly GetLeaderboardRefreshIn: (this: void, name: string) => number | undefined;
    /** Reads board health without a DataStore request. */
    readonly GetLeaderboardStatus: (this: void, name: string) => LeaderboardStatusInfo | undefined;
    /** Reads the time remaining in a periodic board's current period. */
    readonly GetLeaderboardResetIn: (this: void, name: string) => number | undefined;
    /** Opens a validated product or pass prompt; success does not mean the purchase completed. */
    readonly PromptPurchase: (this: void, player: Player, name: string) => OperationResult;
    /** Reads the ownership and policy state used by purchase prompts. */
    readonly GetProductState: (this: void, player: Player, name: string) => ProductState;
    /** Gifts a product perk using a credit or a paid prompt with a saved recipient. */
    readonly PromptGift: (this: void, buyer: Player, productName: string, recipientUserId: number) => OperationResult;
    /** Reads the player's unassigned gift credits. */
    readonly GetGiftCredits: (this: void, player: Player) => { [product: string]: number };
    /** Processes a Scribe receipt with persisted deduplication. */
    readonly HandleReceipt: (this: void, receipt: ReceiptInfo) => Enum.ProductPurchaseDecision;
    /** Processes known products and returns `undefined` for another receipt handler. */
    readonly TryHandleReceipt: (this: void, receipt: ReceiptInfo) => Enum.ProductPurchaseDecision | undefined;
    /** Reads cached pass, perk, or Roblox Plus ownership without yielding. */
    readonly Owns: (this: void, player: Player, key: string) => boolean;
    /** Verifies uncached pass ownership with Roblox before returning. */
    readonly OwnsAsync: (this: void, player: Player, key: string, timeout?: number) => boolean;
    /** Reports ownership now and on changes; returns a disconnect function. */
    readonly ObserveOwned: (this: void, player: Player, key: string, callback: (this: void, owned: boolean) => void) => Disconnect;
    /** Grants a perk through Scribe's ownership state. */
    readonly GrantPerk: (this: void, player: Player, key: string) => void;
    /** Removes a granted perk from Scribe's ownership state. */
    readonly RevokePerk: (this: void, player: Player, key: string) => void;
    /** Debits, grants, and logs atomically; failures roll back the purchase. */
    readonly Purchase: (this: void, player: Player, spec: PurchaseSpec<T>) => OperationResult;
    /** Adds a game-defined entry to the in-game purchase log. */
    readonly RecordPurchase: (this: void, player: Player, entry: UnknownRecord) => void;
    /** Reads filtered purchase history, newest first. */
    readonly GetPurchases: (this: void, player: Player, filter?: PurchaseFilter) => PurchaseEntry[];
    /** Starts an inactive cooldown; returns its previous state and seconds left. */
    readonly OnCooldown: (this: void, player: Player, key: string, seconds: number, options?: CooldownOptions) => LuaTuple<[boolean, number]>;
    /** Reads cooldown state without starting or extending it. */
    readonly PeekCooldown: (this: void, player: Player, key: string) => LuaTuple<[boolean, number]>;
    /** Clears a stored cooldown. */
    readonly ClearCooldown: (this: void, player: Player, key: string) => void;
    /** Queues a durable message; receiving handlers must tolerate repeats. */
    readonly SendMessage: (this: void, userId: number, message: unknown) => boolean;
    /** Trades declared value between players and recovers unfinished exchanges. */
    readonly Exchange: ExchangeAPI;
    /** Fires after each save attempt, including failures. */
    readonly OnSave: Signal<[SaveEvent]>;
    /** Fires when a player's session ends. */
    readonly SessionEnded: Signal<[Player, LifecycleReason]>;
    /** Fires when data validation or integrity checks detect an anomaly. */
    readonly OnAnomaly: Signal<[Anomaly]>;
    /** Fires when a player receives a gift. */
    readonly OnGiftReceived: Signal<[Player, GiftReceived]>;
    /** Fires when a player receives an unassigned gift credit. */
    readonly OnGiftCredit: Signal<[Player, string]>;
    /** Fires when effective ownership changes after load. */
    readonly OnOwnershipChanged: Signal<[Player, string, boolean]>;
    /** Fires when a cooldown expires during an active session. */
    readonly OnCooldownEnded: Signal<[Player, string]>;
    /** Fires when cached board contents change. */
    readonly OnLeaderboard: Signal<[string, LeaderboardEntry[]]>;
    /** Delivers durable messages; handlers must be idempotent. */
    readonly OnMessage: Signal<[Player, unknown]>;
    /** External ProfileStore implementation; narrow to its own public package type before use. */
    readonly ProfileStore: unknown;
    /** Escape hatch requiring explicit validation/assertion at its boundary. */
    readonly Raw: unknown;
    /** Stops this bundle's workers and releases its listeners. */
    readonly Stop: (this: void) => void;
}
export type ServerData<T, S = {}, C = {}> = ServerAPI<T, C> & ServerStoreMember<S>;

/** Partial records for Mock; arrays and Roblox engine datatypes remain whole values. */
export type MockValues<T> = T extends Datatype | buffer | BigValue | ReadonlyArray<unknown> | ReadonlyMap<unknown, unknown> ? T : T extends object ? { [K in keyof T]?: MockValues<T[K]> } : T;
export interface ClientAPI<T, C = {}> {
    /** Reads snapshot readiness without yielding. */
    readonly IsReady: (this: void) => boolean;
    /** Waits for the first snapshot, returning false on timeout. */
    readonly WaitForData: (this: void, timeout?: number) => boolean;
    /** Coalesces local container notifications; writes stay on this client. */
    readonly Batch: (this: void, callback: (this: void) => void) => void;
    /** Sends a command to the server and waits for its reply. */
    readonly Request: RequestFunction<C>;
    /** Sends a keyed command so retries reuse a retained server result. */
    readonly RequestOnce: RequestOnceFunction<C>;
    /** Reads the replicated leaderboard cache without requesting a refresh. */
    readonly GetLeaderboard: (this: void, name: string, limit?: number) => LeaderboardEntry[];
    /** Finds the local player's rank in the replicated board. */
    readonly GetMyRank: (this: void, name: string) => number | undefined;
    /** Fires when a replicated leaderboard changes. */
    readonly OnLeaderboard: Signal<[string, LeaderboardEntry[]]>;
    /** Reads the replicated data-service health. */
    readonly GetServiceStatus: (this: void) => Status;
    /** Fires when the replicated service health changes. */
    readonly OnServiceStatus: Signal<[Status]>;
    /** Reads another player's replicated Shared roots. */
    readonly GetShared: (this: void, playerOrUserId: Player | number) => SharedData<T> | undefined;
    /** Fires when another player's Shared roots change or are removed. */
    readonly OnSharedChanged: Signal<[number, SharedData<T> | undefined]>;
    /** Reads mirrored ownership after the profile loads. */
    readonly Owns: (this: void, key: string) => boolean;
    /** Waits for the server's initial ownership sync before reading the mirror. */
    readonly OwnsAsync: (this: void, key: string, timeout?: number) => boolean;
    /** Reports ownership now and on changes; returns a disconnect function. */
    readonly ObserveOwned: (this: void, key: string, callback: (this: void, owned: boolean) => void) => Disconnect;
    /** Fires for ownership changes after the initial baseline. */
    readonly OnOwnershipChanged: Signal<[string, boolean]>;
    /** Reads cached player-specific marketplace info, fetching on demand. */
    readonly GetProductInfo: (this: void, name: string) => ProductInfo | undefined;
    /** Reads the local player's cached Robux price, or `undefined` while loading. */
    readonly GetPrice: (this: void, name: string) => number | undefined;
    /** Waits for marketplace info, returning `undefined` on timeout or failure. */
    readonly GetProductInfoAsync: (this: void, name: string, timeout?: number) => ProductInfo | undefined;
    /** Waits for the local player's Robux price. */
    readonly GetPriceAsync: (this: void, name: string, timeout?: number) => number | undefined;
    /** Reports cached product info and updates; returns a disconnect function. */
    readonly ObserveProductInfo: (this: void, name: string, callback: (this: void, info: ProductInfo | undefined) => void) => Disconnect;
    /** Warms selected product info in one batch. */
    readonly PrefetchProductInfo: (this: void, names?: ReadonlyArray<string>) => void;
    /** Invalidates cached marketplace info and starts fresh reads. */
    readonly RefreshProductInfo: (this: void, name?: string) => void;
    /** Asks the server to validate and prompt for the local player. Success is not a completed purchase; a timeout may occur after the prompt opens. No automatic retry. */
    readonly PromptPurchase: (this: void, name: string) => LuaTuple<[boolean, string | undefined, RequestFailedMarker | undefined]>;
    /** Reads the mirrored ownership and policy state for shop UI. */
    readonly GetProductState: (this: void, name: string) => ProductState;
    /** Reports shop state now and on changes; returns a disconnect function. */
    readonly ObserveProductState: (this: void, name: string, callback: (this: void, state: ProductState) => void) => Disconnect;
    /** Reads the owner's replicated save status. */
    readonly GetSaveInfo: (this: void) => SaveInfo;
    /** Reads unassigned gift credits from the local mirror. */
    readonly GetGiftCredits: (this: void) => { [product: string]: number };
    /** Reads purchase history only when its replication is enabled. */
    readonly GetPurchases: (this: void, filter?: PurchaseFilter) => PurchaseEntry[];
    /** Seeds local mirror data in edit mode only. */
    readonly Mock: (this: void, values?: MockValues<InputOf<ClientSchema<T>>>, state?: MockState) => void;
    /** Registers an edit-mode command handler without a server. */
    readonly MockCommand: MockCommand<C>;
    /** Exposes the raw API; validate or assert its type before use. */
    readonly Raw: unknown;
    /** Releases this bundle's listeners, retry loop, and mirror. */
    readonly Stop: (this: void) => void;
}
type ClientTree<T> = Accessor<ClientSchema<T>, true, false, false, false, true>;
/** Client writes are local; server-owned roots and timer deadlines are read-only. */
export type ClientData<T, S = {}, C = {}> = Omit<ClientTree<T>, Extract<keyof ClientTree<T>, keyof ClientAPI<T, C> | "ServerStore">> & ClientAPI<T, C> & ClientStoreMember<S>;
export interface Bundle<T, S = {}, C = {}> { readonly Server: ServerData<T, S, C>; readonly Client: ClientData<T, S, C>; }

/** Both templates share root field IDs. Broad dictionaries are validated at runtime. */
type DisjointStoreRoots<T, S> = string extends keyof T | keyof S ? unknown : { [K in keyof T & keyof S]?: never };
export interface ScribeOptions<T, S = {}, C = {}> {
    Template: T;
    ServerStore?: S & DisjointStoreRoots<NoInfer<T>, NoInfer<S>>;
    Transport?: ScribeTransport | "Default";
    Migrations?: { [version: number]: (this: void, data: UnknownRecord) => void };
    UserOwnsGamePassAsync?: (this: void, userId: number, passId: number) => boolean;
    GetProductInfoAsync?: (this: void, assetId: number, infoType: Enum.InfoType) => ProductInfo | undefined;
    GetPolicyInfoAsync?: (this: void, player: Player) => PolicyInfo | undefined;
    DevMode?: boolean;
    IsRunning?: boolean;
    MigrationShadow?: boolean;
    ImportLegacyData?: (this: void, player: Player, userId: number, migration: MigrationContext) => UnknownRecord | undefined;
    MigrationConcurrency?: number;
    OnPlayerInit?: (this: void, player: Player, rawData: UnknownRecord, isNewProfile: boolean, migration: MigrationContext) => void;
    OnPlayerLeaving?: (this: void, player: Player, data: PlayerData<T>, reason: LifecycleReason) => void;
    ProfileStoreIndex: string;
    ProfileKeyPrefix: string;
    SaveInterval?: number;
    /** A supplied ProfileStore module/module script is an external integration boundary. */
    ProfileStore?: unknown;
    Mode?: "Live" | "Mock" | "NoSave";
    TargetUserId?: number;
    UseMock?: boolean;
    ViewedUserId?: number;
    OverriddenUserId?: number;
    DontSave?: boolean;
    ResetData?: boolean;
    LoadFailurePolicy?: "Kick" | "Wait";
    LoadTimeout?: number;
    EraseJoinTimeout?: number;
    VersionAheadPolicy?: "Kick" | "Allow";
    KickOnSessionEnd?: boolean;
    LoadFailureMessage?: string;
    LegacyImportFailureMessage?: string;
    MigrationFailureMessage?: string;
    VersionAheadMessage?: string;
    SchemaFailureMessage?: string;
    RateLimitedMessage?: string;
    ErasingMessage?: string;
    SessionEndMessage?: string;
    SessionStolenMessage?: string;
    SessionInterruptedMessage?: string;
    Leaderboards?: { [name: string]: LeaderboardConfig<T> };
    PeriodReset?: PeriodResetOptions;
    Products?: { [name: string]: ProductConfig<T> };
    /** Historical products still settle receipts and existing gifts, without offering new sales. */
    RetiredProducts?: { [name: string]: ProductConfig<T> };
    Passes?: { [name: string]: PassConfig };
    Perks?: ReadonlyArray<string>;
    OwnReceipts?: boolean;
    Exchangeable?: { [name: string]: ExchangeableSpec };
    PurchaseLog?: PurchaseLogOptions;
    GiftCooldown?: number;
    GiftMaxPending?: number;
    GiftIntentTTL?: number;
    /** Legacy default for purchase-claim and gift-aim retention; receipt history remains fixed at 30 days. */
    PurchaseIdTTL?: number;
    /** @deprecated Ignored. Completed receipt IDs are no longer evicted to meet a count cap. */
    MaxProcessedPurchaseIds?: number;
    /** Receipt-history admission budget, from 1 to 2097152 bytes (default 1048576). */
    MaxReceiptHistoryBytes?: number;
    PurchaseClaimTTL?: number;
    MaxPurchaseClaims?: number;
    AllowDuplicateGifts?: boolean;
    NoGiftIntentPolicy?: "GrantOrCredit" | "Hold";
    Economy?: EconomyConfig;
    CommandRateLimit?: number;
    RequestTimeout?: number;
    MaxInboundBytes?: number;
    MaxInboundRetainedBytes?: number;
    MaxOutboundBytes?: number;
    MaxInboundFrameRate?: number;
    TransportChannel?: string;
    BoundsPolicy?: "Clamp" | "Reject";
    WipeGuardPolicy?: "Warn" | "Block";
    SchemaPolicy?: "Warn" | "Reject";
    BudgetPolicy?: "Defer";
    WipeGuardShrinkRatio?: number;
    LogLevel?: LogLevel;
    /** Severity retained by GetRecentLogs, independently of console and sink filters. */
    LogRingLevel?: LogLevel;
    LogRingSize?: number;
    StatusThresholds?: StatusThresholds;
    Banner?: boolean;
    StudioHook?: boolean;
}
