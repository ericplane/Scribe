import type { Accessor, PlayerData, ValueOf, InputOf, ClientSchema, SharedSchema, ReadonlyAccessor, NumericPaths, Disconnect, Datatype, BigValue } from "./schema";
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
    Cost: { Path: NumericPaths<T, false>; Amount: number };
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
    readonly Get: (this: void, player: Player) => PlayerData<T>;
    readonly WaitForData: (this: void, player: Player, timeout?: number) => LuaTuple<[PlayerData<T> | undefined, LifecycleReason | undefined]>;
    readonly GetState: (this: void, player: Player) => LuaTuple<[SessionState, LoadPhase | undefined]>;
    readonly Batch: (this: void, player: Player, callback: (this: void) => void) => void;
    readonly Transaction: (this: void, player: Player, callback: (this: void) => void) => OperationResult;
    readonly Flush: (this: void, player: Player, options?: FlushOptions) => boolean;
    readonly GetSaveInfo: (this: void, player: Player) => SaveInfo;
    /** Offline/history reads are packed, potentially old schemas, not live accessor values. */
    readonly GetOffline: (this: void, userId: number) => UnknownRecord | undefined;
    readonly UpdateOffline: (this: void, userId: number, callback: (this: void, rawData: UnknownRecord) => void, options?: UpdateOfflineOptions) => LuaTuple<[boolean, string | undefined, SchemaViolation[] | undefined]>;
    readonly ListVersions: (this: void, userId: number, limit?: number) => VersionRecord[];
    readonly GetVersion: (this: void, userId: number, versionId: string) => UnknownRecord | undefined;
    readonly RestoreVersion: (this: void, userId: number, versionId: string, options?: RestoreOptions) => OperationResult;
    readonly Erase: (this: void, userId: number) => OperationResult;
    readonly Export: (this: void, userId: number) => string | undefined;
    readonly Command: RegisterCommand<C>;
    readonly GetLeaderboard: (this: void, name: string, limit?: number, offset?: number) => LeaderboardEntry[];
    readonly GetMyRank: (this: void, player: Player, name: string) => number | undefined;
    readonly GetLeaderboardRefreshIn: (this: void, name: string) => number | undefined;
    readonly GetLeaderboardStatus: (this: void, name: string) => LeaderboardStatusInfo | undefined;
    readonly GetLeaderboardResetIn: (this: void, name: string) => number | undefined;
    readonly PromptPurchase: (this: void, player: Player, name: string) => OperationResult;
    readonly GetProductState: (this: void, player: Player, name: string) => ProductState;
    readonly PromptGift: (this: void, buyer: Player, productName: string, recipientUserId: number) => OperationResult;
    readonly GetGiftCredits: (this: void, player: Player) => { [product: string]: number };
    readonly HandleReceipt: (this: void, receipt: ReceiptInfo) => Enum.ProductPurchaseDecision;
    readonly TryHandleReceipt: (this: void, receipt: ReceiptInfo) => Enum.ProductPurchaseDecision | undefined;
    readonly Owns: (this: void, player: Player, key: string) => boolean;
    readonly OwnsAsync: (this: void, player: Player, key: string, timeout?: number) => boolean;
    readonly ObserveOwned: (this: void, player: Player, key: string, callback: (this: void, owned: boolean) => void) => Disconnect;
    readonly GrantPerk: (this: void, player: Player, key: string) => void;
    readonly RevokePerk: (this: void, player: Player, key: string) => void;
    readonly Purchase: (this: void, player: Player, spec: PurchaseSpec<T>) => OperationResult;
    readonly RecordPurchase: (this: void, player: Player, entry: UnknownRecord) => void;
    readonly GetPurchases: (this: void, player: Player, filter?: PurchaseFilter) => PurchaseEntry[];
    readonly OnCooldown: (this: void, player: Player, key: string, seconds: number, options?: CooldownOptions) => LuaTuple<[boolean, number]>;
    readonly PeekCooldown: (this: void, player: Player, key: string) => LuaTuple<[boolean, number]>;
    readonly ClearCooldown: (this: void, player: Player, key: string) => void;
    readonly SendMessage: (this: void, userId: number, message: unknown) => boolean;
    readonly Exchange: ExchangeAPI;
    readonly OnSave: Signal<[SaveEvent]>;
    readonly SessionEnded: Signal<[Player, LifecycleReason]>;
    readonly OnAnomaly: Signal<[Anomaly]>;
    readonly OnGiftReceived: Signal<[Player, GiftReceived]>;
    readonly OnGiftCredit: Signal<[Player, string]>;
    readonly OnOwnershipChanged: Signal<[Player, string, boolean]>;
    readonly OnCooldownEnded: Signal<[Player, string]>;
    readonly OnLeaderboard: Signal<[string, LeaderboardEntry[]]>;
    readonly OnMessage: Signal<[Player, unknown]>;
    /** External ProfileStore implementation; narrow to its own public package type before use. */
    readonly ProfileStore: unknown;
    /** Escape hatch requiring explicit validation/assertion at its boundary. */
    readonly Raw: unknown;
    readonly Stop: (this: void) => void;
}
export type ServerData<T, S = {}, C = {}> = ServerAPI<T, C> & ServerStoreMember<S>;

/** Partial records for Mock; arrays and Roblox engine datatypes remain whole values. */
export type MockValues<T> = T extends Datatype | buffer | BigValue | ReadonlyArray<unknown> | ReadonlyMap<unknown, unknown> ? T : T extends object ? { [K in keyof T]?: MockValues<T[K]> } : T;
export interface ClientAPI<T, C = {}> {
    readonly IsReady: (this: void) => boolean;
    readonly WaitForData: (this: void, timeout?: number) => boolean;
    readonly Batch: (this: void, callback: (this: void) => void) => void;
    readonly Request: RequestFunction<C>;
    readonly RequestOnce: RequestOnceFunction<C>;
    readonly GetLeaderboard: (this: void, name: string, limit?: number) => LeaderboardEntry[];
    readonly GetMyRank: (this: void, name: string) => number | undefined;
    readonly OnLeaderboard: Signal<[string, LeaderboardEntry[]]>;
    readonly GetServiceStatus: (this: void) => Status;
    readonly OnServiceStatus: Signal<[Status]>;
    readonly GetShared: (this: void, playerOrUserId: Player | number) => SharedData<T> | undefined;
    readonly OnSharedChanged: Signal<[number, SharedData<T> | undefined]>;
    readonly Owns: (this: void, key: string) => boolean;
    readonly OwnsAsync: (this: void, key: string, timeout?: number) => boolean;
    readonly ObserveOwned: (this: void, key: string, callback: (this: void, owned: boolean) => void) => Disconnect;
    readonly OnOwnershipChanged: Signal<[string, boolean]>;
    readonly GetProductInfo: (this: void, name: string) => ProductInfo | undefined;
    readonly GetPrice: (this: void, name: string) => number | undefined;
    readonly GetProductInfoAsync: (this: void, name: string, timeout?: number) => ProductInfo | undefined;
    readonly GetPriceAsync: (this: void, name: string, timeout?: number) => number | undefined;
    readonly ObserveProductInfo: (this: void, name: string, callback: (this: void, info: ProductInfo | undefined) => void) => Disconnect;
    readonly PrefetchProductInfo: (this: void, names?: ReadonlyArray<string>) => void;
    readonly RefreshProductInfo: (this: void, name?: string) => void;
    /** Asks the server to validate and prompt for the local player. Success is not a completed purchase; a timeout may occur after the prompt opens. No automatic retry. */
    readonly PromptPurchase: (this: void, name: string) => LuaTuple<[boolean, string | undefined, RequestFailedMarker | undefined]>;
    readonly GetProductState: (this: void, name: string) => ProductState;
    readonly ObserveProductState: (this: void, name: string, callback: (this: void, state: ProductState) => void) => Disconnect;
    readonly GetSaveInfo: (this: void) => SaveInfo;
    readonly GetGiftCredits: (this: void) => { [product: string]: number };
    readonly GetPurchases: (this: void, filter?: PurchaseFilter) => PurchaseEntry[];
    readonly Mock: (this: void, values?: MockValues<InputOf<ClientSchema<T>>>, state?: MockState) => void;
    readonly MockCommand: MockCommand<C>;
    readonly Raw: unknown;
    readonly Stop: (this: void) => void;
}
/** Client field writes are local optimistic edits; server-owned roots remain read-only. */
export type ClientData<T, S = {}, C = {}> = Omit<PlayerData<ClientSchema<T>>, Extract<keyof PlayerData<ClientSchema<T>>, keyof ClientAPI<T, C> | "ServerStore">> & ClientAPI<T, C> & ClientStoreMember<S>;
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
