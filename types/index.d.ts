import type * as Schema from "./schema";
import type * as API from "./api";
import type * as Common from "./common";

declare const Scribe: Scribe.ScribeModule;

declare namespace Scribe {
    interface ScribeModule {
        /** Creates the server and client APIs from a shared template. */
        <T, S = {}, C = {}>(options: API.ScribeOptions<T, S, C>): API.Bundle<T, S, C>;
        /** Creates the server and client APIs from a shared template. */
        readonly new: <T, S = {}, C = {}>(this: void, options: API.ScribeOptions<T, S, C>) => API.Bundle<T, S, C>;
        readonly Version: string;
        /** Keeps a field and its subtree off the client. */
        readonly ServerOnly: <T>(this: void, value: T) => Schema.ServerOnly<T>;
        /** Replicates a root field to every client. */
        readonly Shared: <T>(this: void, value: T) => Schema.Shared<T>;
        /** Keeps a root field unsaved; its visibility wrappers still apply. */
        readonly Session: <T>(this: void, value: T) => Schema.Session<T>;
        /** Declares integer data with optional bounds. */
        readonly Int: (this: void, value: number, meta?: NumberMeta) => number;
        /** Declares floating-point data with optional bounds and wire precision. */
        readonly Number: (this: void, value: number, meta?: FloatMeta) => number;
        /** Declares large-range numbers; numeric strings are limited to 256 bytes. */
        readonly Big: (this: void, value?: number | string, meta?: BigMeta) => Schema.BigSchema;
        /** Declares string data with an optional byte limit. */
        readonly String: (this: void, value: string, meta?: StringMeta) => string;
        /** Restricts a string field to the declared members. */
        readonly Enum: <K extends string>(this: void, value: NoInfer<K>, members: readonly K[]) => Schema.EnumValue<K>;
        /** Stores up to 32 named booleans as one field. */
        readonly Flags: <K extends string>(this: void, members: readonly K[]) => Schema.Flags<K>;
        /** Declares a leaf reset to its default after SetTimed expires. */
        readonly Timed: <T>(this: void, value: T) => Schema.Timed<T>;
        /** Builds a default per profile with the supplied factory. */
        readonly Dynamic: <T>(this: void, factory: (this: void) => T) => T;
        /** Computes a read-only field from paths; annotate compute arguments explicitly. */
        readonly Derived: <T, A extends unknown[]>(this: void, output: T, inputs: readonly string[], compute: (this: void, ...args: A) => Schema.ValueOf<T>) => Schema.Derived<T>;
        /** Allows an absent leaf value without seeding the inner default. */
        readonly Optional: <T>(this: void, value: T) => Schema.Optional<T>;
        /** Declares a typed array with optional size and eviction limits. */
        readonly ArrayOf: <T>(this: void, shape: T, options?: ArrayOpts) => Schema.ArrayOf<T>;
        /** Declares unique scalar members with an optional size limit. */
        readonly SetOf: <T>(this: void, element: T, options?: SetOpts) => Schema.SetOf<T>;
        /** Declares a map with integer or string keys and a value schema. */
        readonly MapOf: <K extends "integer" | "string", T>(this: void, keyType: K, shape: T, options?: DictOpts) => Schema.MapOf<K, T>;
        /** Declares string-keyed values with a schema and optional limits. */
        readonly DictOf: <T>(this: void, shape: T, options?: DictOpts) => Schema.DictOf<T>;
        /** Declares Vector3 data, packed for storage and replication. */
        readonly Vector3: (this: void, value: Vector3) => Vector3;
        /** Declares Vector2 data, packed for storage and replication. */
        readonly Vector2: (this: void, value: Vector2) => Vector2;
        /** Declares Vector3int16 data, packed for storage and replication. */
        readonly Vector3int16: (this: void, value: Vector3int16) => Vector3int16;
        /** Declares Vector2int16 data, packed for storage and replication. */
        readonly Vector2int16: (this: void, value: Vector2int16) => Vector2int16;
        /** Declares packed CFrame data; Precision = "exact" preserves its f32 components. */
        readonly CFrame: (this: void, value: CFrame, meta?: CFrameMeta) => CFrame;
        /** Declares Color3 data, packed for storage and replication. */
        readonly Color3: (this: void, value: Color3) => Color3;
        /** Declares BrickColor data, packed for storage and replication. */
        readonly BrickColor: (this: void, value: BrickColor) => BrickColor;
        /** Declares UDim data, packed for storage and replication. */
        readonly UDim: (this: void, value: UDim) => UDim;
        /** Declares UDim2 data, packed for storage and replication. */
        readonly UDim2: (this: void, value: UDim2) => UDim2;
        /** Declares Rect data, packed for storage and replication. */
        readonly Rect: (this: void, value: Rect) => Rect;
        /** Declares NumberRange data, packed for storage and replication. */
        readonly NumberRange: (this: void, value: NumberRange) => NumberRange;
        /** Declares NumberSequence data, packed for storage and replication. */
        readonly NumberSequence: (this: void, value: NumberSequence) => NumberSequence;
        /** Declares ColorSequence data, packed for storage and replication. */
        readonly ColorSequence: (this: void, value: ColorSequence) => ColorSequence;
        /** Declares DateTime data, packed for storage and replication. */
        readonly DateTime: (this: void, value: DateTime) => DateTime;
        /** Declares EnumItem data, packed for storage and replication. */
        readonly EnumItem: <T extends EnumItem>(this: void, value: T) => T;
        /** Declares Font data, packed for storage and replication. */
        readonly Font: (this: void, value: Font) => Font;
        /** Declares PhysicalProperties data, packed for storage and replication. */
        readonly PhysicalProperties: (this: void, value: PhysicalProperties) => PhysicalProperties;
        /** Formats a number or Big value with suffixes and decimal places. */
        readonly Short: (this: void, value?: number | Schema.BigValue, decimals?: number) => string;
        /** Replaces suffixes used by Short; the first suffix must be empty. */
        readonly SetShortSuffixes: (this: void, suffixes: readonly string[]) => void;
        /** Sets process-wide options before any bundle is built; conflicting calls error. */
        readonly Configure: (this: void, config: Common.ConfigureOptions) => void;
        /** Returns the server bundle prefix, or PLAYER_ before setup and on clients. */
        readonly GetProfileKeyPrefix: (this: void) => string;
        /** Returns current DataStore health. */
        readonly GetStatus: (this: void) => Common.Status;
        /** Fires when data-service health changes, with the new and previous status. */
        readonly OnStatusChanged: Common.Signal<[Common.Status, Common.Status]>;
        /** Fires for each Error or Fatal log entry. */
        readonly OnIssue: Common.Signal<[Common.LogEntry]>;
        /** Adds a filtered, bounded log sink; returns its disconnect function. */
        readonly AddLogSink: (this: void, callback: (this: void, entry: Common.LogEntry) => void, options?: Common.LogSinkOptions) => Schema.Disconnect;
        /** Registers plugin actions; returned cleanup removes only this registration. */
        readonly RegisterAddon: (this: void, name: string, actions: Common.AddonActions) => Schema.Disconnect;
        /** Returns filtered retained logs, oldest first; Limit keeps the newest entries. */
        readonly GetRecentLogs: (this: void, filter?: Common.LogFilter) => Common.LogEntry[];
        /** Returns this context's counters and distribution summaries. */
        readonly GetMetrics: (this: void) => Common.Metrics;
        /** Returns recent distribution percentiles with sample age and window size. */
        readonly GetPercentiles: (this: void) => Common.PercentileSnapshot;
        /** Reads current DataStore allowances; Available is false if the query fails. */
        readonly GetBudgetSnapshot: (this: void) => Common.BudgetSnapshot;
        /** Returns cached board health without DataStore requests; empty on clients. */
        readonly GetLeaderboardSnapshot: (this: void) => Common.LeaderboardSnapshotEntry[];
        /** Distinguishes framework request failures from handler replies. */
        readonly RequestFailed: Common.RequestFailedMarker;
        /** Codec helpers for packing and unpacking Roblox datatypes. */
        readonly Datatypes: {
            /** Checks whether a datatype has a registered codec. */
            readonly IsSupported: (this: void, name: string) => boolean;
            /** Lists supported precision options, or returns `undefined` when none exist. */
            readonly PrecisionValues: (this: void, name: string) => string[] | undefined;
            /** Encodes a supported datatype into a buffer. */
            readonly Pack: <K extends keyof DatatypeValues>(this: void, name: K, value: DatatypeValues[K], precision?: K extends "CFrame" ? "exact" : never) => buffer;
            /** Decodes a buffer into the named datatype. */
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
    export type Accessor<T, Root extends boolean = false, Missing extends boolean = false, ReadOnly extends boolean = false, Closed extends boolean = false, Client extends boolean = false> = Schema.Accessor<T, Root, Missing, ReadOnly, Closed, Client>;
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
        readonly PurchaseReason: { readonly DataNotLoaded: "player data not loaded"; readonly InvalidCostSpec: "invalid Cost spec"; readonly InvalidCostAmount: "invalid Cost amount"; readonly InvalidCostPath: "invalid cost path"; readonly CostPathNotSpendable: "cost path is not a spendable number"; readonly InsufficientFunds: "insufficient funds"; readonly PaidRandomRestricted: "paid random items are not available for this account"; readonly PolicyPending: "cannot check account settings right now; try again in a moment"; readonly InvalidIdempotencyKey: "invalid IdempotencyKey"; };
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
