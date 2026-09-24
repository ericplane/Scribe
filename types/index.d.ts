import type * as Schema from "./schema";
import type * as API from "./api";
import type * as Common from "./common";

declare const Scribe: Scribe.ScribeModule;

declare namespace Scribe {
    interface ScribeModule {
        <T, S = {}, C = {}>(options: API.ScribeOptions<T, S, C>): API.Bundle<T, S, C>;
        readonly new: <T, S = {}, C = {}>(this: void, options: API.ScribeOptions<T, S, C>) => API.Bundle<T, S, C>;
        readonly Version: string;
        readonly ServerOnly: <T>(this: void, value: T) => Schema.ServerOnly<T>;
        readonly Shared: <T>(this: void, value: T) => Schema.Shared<T>;
        readonly Session: <T>(this: void, value: T) => Schema.Session<T>;
        readonly Int: (this: void, value: number, meta?: NumberMeta) => number;
        readonly Number: (this: void, value: number, meta?: FloatMeta) => number;
        readonly Big: (this: void, value?: number | string, meta?: BigMeta) => Schema.BigSchema;
        readonly String: (this: void, value: string, meta?: StringMeta) => string;
        readonly Enum: <K extends string>(this: void, value: NoInfer<K>, members: readonly K[]) => Schema.EnumValue<K>;
        readonly Flags: <K extends string>(this: void, members: readonly K[]) => Schema.Flags<K>;
        readonly Timed: <T>(this: void, value: T) => Schema.Timed<T>;
        readonly Dynamic: <T>(this: void, factory: (this: void) => T) => T;
        /** Annotate compute arguments: the enclosing template is not in scope here. */
        readonly Derived: <T, A extends unknown[]>(this: void, output: T, inputs: readonly string[], compute: (this: void, ...args: A) => Schema.ValueOf<T>) => Schema.Derived<T>;
        readonly Optional: <T>(this: void, value: T) => Schema.Optional<T>;
        readonly ArrayOf: <T>(this: void, shape: T, options?: ArrayOpts) => Schema.ArrayOf<T>;
        readonly SetOf: <T>(this: void, element: T, options?: SetOpts) => Schema.SetOf<T>;
        readonly MapOf: <K extends "integer" | "string", T>(this: void, keyType: K, shape: T, options?: DictOpts) => Schema.MapOf<K, T>;
        readonly DictOf: <T>(this: void, shape: T, options?: DictOpts) => Schema.DictOf<T>;
        readonly Vector3: (this: void, value: Vector3) => Vector3;
        readonly Vector2: (this: void, value: Vector2) => Vector2;
        readonly Vector3int16: (this: void, value: Vector3int16) => Vector3int16;
        readonly Vector2int16: (this: void, value: Vector2int16) => Vector2int16;
        readonly CFrame: (this: void, value: CFrame, meta?: CFrameMeta) => CFrame;
        readonly Color3: (this: void, value: Color3) => Color3;
        readonly BrickColor: (this: void, value: BrickColor) => BrickColor;
        readonly UDim: (this: void, value: UDim) => UDim;
        readonly UDim2: (this: void, value: UDim2) => UDim2;
        readonly Rect: (this: void, value: Rect) => Rect;
        readonly NumberRange: (this: void, value: NumberRange) => NumberRange;
        readonly NumberSequence: (this: void, value: NumberSequence) => NumberSequence;
        readonly ColorSequence: (this: void, value: ColorSequence) => ColorSequence;
        readonly DateTime: (this: void, value: DateTime) => DateTime;
        readonly EnumItem: <T extends EnumItem>(this: void, value: T) => T;
        readonly Font: (this: void, value: Font) => Font;
        readonly PhysicalProperties: (this: void, value: PhysicalProperties) => PhysicalProperties;
        readonly Short: (this: void, value?: number | Schema.BigValue, decimals?: number) => string;
        readonly SetShortSuffixes: (this: void, suffixes: readonly string[]) => void;
        readonly Configure: (this: void, config: Common.ConfigureOptions) => void;
        readonly GetProfileKeyPrefix: (this: void) => string;
        readonly GetStatus: (this: void) => Common.Status;
        readonly OnStatusChanged: Common.Signal<[Common.Status, Common.Status]>;
        readonly OnIssue: Common.Signal<[Common.LogEntry]>;
        readonly AddLogSink: (this: void, callback: (this: void, entry: Common.LogEntry) => void, options?: Common.LogSinkOptions) => Schema.Disconnect;
        readonly RegisterAddon: (this: void, name: string, actions: Common.AddonActions) => Schema.Disconnect;
        readonly GetRecentLogs: (this: void, filter?: Common.LogFilter) => Common.LogEntry[];
        readonly GetMetrics: (this: void) => Common.Metrics;
        readonly GetPercentiles: (this: void) => Common.PercentileSnapshot;
        readonly GetBudgetSnapshot: (this: void) => Common.BudgetSnapshot;
        readonly GetLeaderboardSnapshot: (this: void) => Common.LeaderboardSnapshotEntry[];
        readonly RequestFailed: Common.RequestFailedMarker;
        readonly Datatypes: {
            readonly IsSupported: (this: void, name: string) => boolean;
            readonly PrecisionValues: (this: void, name: string) => string[] | undefined;
            readonly Pack: <K extends keyof DatatypeValues>(this: void, name: K, value: DatatypeValues[K], precision?: K extends "CFrame" ? "exact" : never) => buffer;
            readonly Unpack: <K extends keyof DatatypeValues>(this: void, name: K, bytes: buffer) => DatatypeValues[K];
            readonly NONFINITE: "Scribe:nonfinite:";
        };

    }

    interface NumberMeta { Min?: number; Max?: number; }
    interface DatatypeValues {
        Vector3: Vector3; Vector2: Vector2; Vector3int16: Vector3int16; Vector2int16: Vector2int16;
        CFrame: CFrame; Color3: Color3; BrickColor: BrickColor; UDim: UDim; UDim2: UDim2;
        Rect: Rect; NumberRange: NumberRange; NumberSequence: NumberSequence; ColorSequence: ColorSequence;
        DateTime: DateTime; EnumItem: EnumItem; Font: Font; PhysicalProperties: PhysicalProperties;
    }
    interface FloatMeta extends NumberMeta { Precision?: number | "f32"; }
    interface BigMeta { Min?: number | string; Max?: number | string; }
    interface StringMeta { MaxLength?: number; }
    interface CFrameMeta { Precision?: "exact"; }
    interface ArrayOpts { MaxItems?: number; Evict?: "Front" | "Back"; }
    interface SetOpts { MaxItems?: number; }
    interface DictOpts { MaxKeys?: number; MaxKeyLength?: number; }
    type MapKeyType = "integer" | "string";
    export type ServerOnly<T> = Schema.ServerOnly<T>;
    export type Shared<T> = Schema.Shared<T>;
    export type Session<T> = Schema.Session<T>;
    export type Timed<T> = Schema.Timed<T>;
    export type Derived<T> = Schema.Derived<T>;
    export type Optional<T> = Schema.Optional<T>;
    export type ArrayOf<T> = Schema.ArrayOf<T>;
    export type DictOf<T> = Schema.DictOf<T>;
    export type MapOf<K extends "integer" | "string", T> = Schema.MapOf<K, T>;
    export type SetOf<T> = Schema.SetOf<T>;
    export type Flags<K extends string = string> = Schema.Flags<K>;
    export type EnumValue<K extends string> = Schema.EnumValue<K>;
    export type BigSchema = Schema.BigSchema;
    export type Disconnect = Schema.Disconnect;
    export type BigOperand = Schema.BigOperand;
    export type BigValue = Schema.BigValue;
    export type Datatype = Schema.Datatype;
    export type AtomicValue = Schema.AtomicValue;
    export type ValueOf<T> = Schema.ValueOf<T>;
    export type DeepReadonly<T> = Schema.DeepReadonly<T>;
    export type InputOf<T> = Schema.InputOf<T>;
    export type ElementInput<T> = Schema.ElementInput<T>;
    export type ClientSchema<T> = Schema.ClientSchema<T>;
    export type SharedSchema<T> = Schema.SharedSchema<T>;
    export type ReadableNode<T> = Schema.ReadableNode<T>;
    export type Accessor<T, Root extends boolean = false, Missing extends boolean = false, ReadOnly extends boolean = false, Closed extends boolean = false> = Schema.Accessor<T, Root, Missing, ReadOnly, Closed>;
    export type PlayerData<T> = Schema.PlayerData<T>;
    export type ReadonlyAccessor<T, Root extends boolean = false> = Schema.ReadonlyAccessor<T, Root>;
    export type NumericPaths<T, IncludeBig extends boolean = false, Depth extends unknown[] = []> = Schema.NumericPaths<T, IncludeBig, Depth>;
    export type LeaderboardConfig<T = unknown> = API.LeaderboardConfig<T>;
    export type ProductConfig<T = unknown> = API.ProductConfig<T>;
    export type PurchaseSpec<T = unknown> = API.PurchaseSpec<T>;
    export type CommandArguments<F> = API.CommandArguments<F>;
    export type CommandReturn<F> = API.CommandReturn<F>;
    export type CommandHandler<F> = API.CommandHandler<F>;
    export type CommandSpec = API.CommandSpec;
    export type RequestFunction<C> = API.RequestFunction<C>;
    export type RequestOnceFunction<C> = API.RequestOnceFunction<C>;
    export type RegisterCommand<C> = API.RegisterCommand<C>;
    export type MockCommand<C> = API.MockCommand<C>;
    export type ServerStore<S> = API.ServerStore<S>;
    export type ClientServerStore<S> = API.ClientServerStore<S>;
    export type SharedData<T> = API.SharedData<T>;
    export type ServerAPI<T, C = {}> = API.ServerAPI<T, C>;
    export type ServerData<T, S = {}, C = {}> = API.ServerData<T, S, C>;
    export type MockValues<T> = API.MockValues<T>;
    export type ClientAPI<T, C = {}> = API.ClientAPI<T, C>;
    export type ClientData<T, S = {}, C = {}> = API.ClientData<T, S, C>;
    export type Bundle<T, S = {}, C = {}> = API.Bundle<T, S, C>;
    export type ScribeOptions<T, S = {}, C = {}> = API.ScribeOptions<T, S, C>;
    export type UnknownRecord = Common.UnknownRecord;
    export type PathSegment = Common.PathSegment;
    export type Path = Common.Path;
    export type OpKind = Common.OpKind;
    export type Op = Common.Op;
    export type ScribeTransport = Common.ScribeTransport;
    export type Connection = Common.Connection;
    export type Signal<Args extends unknown[]> = Common.Signal<Args>;
    export type LogLevel = Common.LogLevel;
    export type LogCategory = Common.LogCategory;
    export type LogCode = Common.LogCode;
    export type LogEntry = Common.LogEntry;
    export type LogSinkOptions = Common.LogSinkOptions;
    export type LogFilter = Common.LogFilter;
    export type Status = Common.Status;
    export type SessionState = Common.SessionState;
    export type LoadPhase = Common.LoadPhase;
    export type Visibility = Common.Visibility;
    export type LifecycleReason = Common.LifecycleReason;
    export type RequestReason = Common.RequestReason;
    export type RequestFailedMarker = Common.RequestFailedMarker;
    export type RequestFailure = Common.RequestFailure;
    export type ProductState = Common.ProductState;
    export type PurchaseReason = Common.PurchaseReason;
    export type GiftReason = Common.GiftReason;
    export type OperationResult = Common.OperationResult;
    export type SaveInfo = Common.SaveInfo;
    export type SaveEvent = Common.SaveEvent;
    export type Anomaly = Common.Anomaly;
    export type GiftReceived = Common.GiftReceived;
    export type VersionRecord = Common.VersionRecord;
    export type ViolationKind = Common.ViolationKind;
    export type SchemaViolation = Common.SchemaViolation;
    export type FlushOptions = Common.FlushOptions;
    export type UpdateOfflineOptions = Common.UpdateOfflineOptions;
    export type RestoreOptions = Common.RestoreOptions;
    export type CooldownOptions = Common.CooldownOptions;
    export type MigrationContext = Common.MigrationContext;
    export type BigScore = Common.BigScore;
    export type LeaderboardEntry = Common.LeaderboardEntry;
    export type LeaderboardStatus = Common.LeaderboardStatus;
    export type LeaderboardStatusInfo = Common.LeaderboardStatusInfo;
    export type LeaderboardSnapshotEntry = Common.LeaderboardSnapshotEntry;
    export type PassConfig = Common.PassConfig;
    export type PurchaseFilter = Common.PurchaseFilter;
    export type PurchaseEntry = Common.PurchaseEntry;
    export type PurchaseLogOptions = Common.PurchaseLogOptions;
    export type ProductInfo = Common.ProductInfo;
    export type PolicyInfo = Common.PolicyInfo;
    export type ReceiptInfo = Common.ReceiptInfo;
    export type EconomyMeta = Common.EconomyMeta;
    export type EconomyFieldSpec = Common.EconomyFieldSpec;
    export type EconomyCurrencyConfig = Common.EconomyCurrencyConfig;
    export type EconomyLogFn = Common.EconomyLogFn;
    export type EconomyConfig = Common.EconomyConfig;
    export type ExchangeableSpec = Common.ExchangeableSpec;
    export type ExchangeLeg = Common.ExchangeLeg;
    export type OpenLeg = Common.OpenLeg;
    export type OpenExchange = Common.OpenExchange;
    export type ExchangeAPI = Common.ExchangeAPI;
    export type BudgetSnapshot = Common.BudgetSnapshot;
    export type MetricObservation = Common.MetricObservation;
    export type Metrics = Common.Metrics;
    export type Percentiles = Common.Percentiles;
    export type PercentileSnapshot = Common.PercentileSnapshot;
    export type AddonAction = Common.AddonAction;
    export type AddonActions = Common.AddonActions;
    export type ConfigureOptions = Common.ConfigureOptions;
    export type StatusThresholds = Common.StatusThresholds;
    export type PeriodResetOptions = Common.PeriodResetOptions;
    export type MockState = Common.MockState;
    interface ScribeModule {
        readonly Reason: { readonly LoadFailed: "load-failed"; readonly MigrationFailed: "migration-failed"; readonly Erasing: "erasing"; readonly SessionEnded: "session-ended"; readonly PlayerLeft: "player-left"; readonly Shutdown: "shutdown"; readonly StillLoading: "still-loading"; readonly Timeout: "timeout"; };
        readonly RequestReason: { readonly RateLimited: "rate-limited"; readonly NotReady: "not-ready"; readonly UnknownCommand: "unknown-command"; readonly BadArgs: "bad-args"; readonly BadIdempotencyKey: "bad-idempotency-key"; readonly Error: "error"; readonly ReplyEncodeFailed: "reply-encode-failed"; readonly Timeout: "timeout"; readonly SendFailed: "send-failed"; readonly EditMode: "edit-mode"; readonly MockError: "mock-error"; };
        readonly PurchaseReason: { readonly DataNotLoaded: "player data not loaded"; readonly InvalidCostSpec: "invalid Cost spec"; readonly InvalidCostAmount: "invalid Cost amount"; readonly InvalidCostPath: "invalid cost path"; readonly CostPathNotSpendable: "cost path is not a spendable number"; readonly InsufficientFunds: "insufficient funds"; readonly PaidRandomRestricted: "paid random items are not available for this account"; readonly PolicyPending: "cannot check account settings right now; try again in a moment"; };
        readonly GiftReason: { readonly ProductRetired: "product retired"; readonly BuyerDataNotLoaded: "buyer data not loaded"; readonly InvalidRecipient: "invalid recipient"; readonly CannotGiftYourself: "cannot gift yourself"; readonly GiftCooldown: "gift cooldown"; readonly TooManyPending: "too many pending gifts"; readonly DataServicesDown: "data services are experiencing issues; try again later"; readonly RecipientAlreadyOwns: "recipient already owns this"; readonly CreditReserveFailed: "could not reserve gift credit; try again later"; readonly DeliveryFailed: "could not deliver gift; try again later"; readonly DeliveryUnconfirmed: "gift delivery could not be confirmed; do not send it again"; readonly AlreadyPending: "a gift of this item is already pending; try again shortly"; readonly IntentRecordFailed: "could not record gift intent; try again later"; readonly PaidRandomRestricted: "paid random items are not available for this account"; readonly PolicyPending: "cannot check account settings right now; try again in a moment"; };
        readonly ProductState: { readonly Purchasable: "purchasable"; readonly Owned: "owned"; readonly PaidRandomRestricted: "paid-random-restricted"; readonly PolicyPending: "policy-pending"; readonly NotLoaded: "not-loaded"; };
        readonly OpKind: { readonly Init: "Init"; readonly Set: "Set"; readonly Insert: "Insert"; readonly Remove: "Remove"; readonly Clear: "Clear"; };
        readonly LogLevel: { readonly Debug: "Debug"; readonly Info: "Info"; readonly Warn: "Warn"; readonly Error: "Error"; readonly Fatal: "Fatal"; };
        readonly LogCategory: { readonly Persistence: "Persistence"; readonly Replication: "Replication"; readonly Transport: "Transport"; readonly Commands: "Commands"; readonly Leaderboards: "Leaderboards"; readonly Monetization: "Monetization"; readonly Gifting: "Gifting"; readonly Integrity: "Integrity"; readonly Lifecycle: "Lifecycle"; readonly Derived: "Derived"; readonly Exchanges: "Exchanges"; };
        readonly Status: { readonly Healthy: "Healthy"; readonly Degraded: "Degraded"; readonly Outage: "Outage"; };
        readonly LeaderboardStatus: { readonly Starting: "Starting"; readonly Healthy: "Healthy"; readonly Degraded: "Degraded"; };
        readonly SessionState: { readonly Loading: "Loading"; readonly Ready: "Ready"; readonly SessionEnded: "SessionEnded"; };
        readonly LoadPhase: { readonly WaitingForErase: "WaitingForErase"; readonly AcquiringSession: "AcquiringSession"; readonly ReadingProfile: "ReadingProfile"; readonly Retrying: "Retrying"; readonly Initializing: "Initializing"; readonly Importing: "Importing"; readonly ImportThrottled: "ImportThrottled"; };
        readonly Visibility: { readonly Replicated: "Replicated"; readonly ServerOnly: "ServerOnly"; readonly Shared: "Shared"; };
        readonly LifecycleReason: ScribeModule["Reason"];
    }
}

export = Scribe;
