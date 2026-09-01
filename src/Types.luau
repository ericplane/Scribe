--!strict
-- Shared type definitions for Scribe.

export type PathSegment = string | number
export type Path = { PathSegment }

export type OpKind = "Init" | "Set" | "Insert" | "Remove" | "Clear"

export type Op = {
	Kind: OpKind,
	Path: Path,
	Value: unknown?,
	Index: number?,
}

export type ScribeTransport = {
	Name: string,
	-- The largest buffer this channel wants handed to it in one call. Read once at
	-- construction, and it wins over MaxOutboundBytes only when it is smaller, so it
	-- can never raise a game's configured budget. Declare it when the adapter's own
	-- framing changes the arithmetic, such as base64 inflating by 4/3.
	MaxFrameBytes: number?,
	-- Server
	SendToClient: (self: any, player: Player, bytes: buffer) -> (),
	SendToAllClients: ((self: any, bytes: buffer) -> ())?,
	ListenServer: (self: any, callback: (player: Player, bytes: buffer) -> ()) -> (),
	-- Client
	SendToServer: (self: any, bytes: buffer) -> (),
	ListenClient: (self: any, callback: (bytes: buffer) -> ()) -> (),
	-- Optional. Client.Stop calls it to disconnect what ListenClient connected.
	Release: ((self: any) -> ())?,
}

export type LogLevel = "Debug" | "Info" | "Warn" | "Error" | "Fatal"
export type LogCategory =
	"Persistence"
	| "Replication"
	| "Transport"
	| "Commands"
	| "Leaderboards"
	| "Monetization"
	| "Gifting"
	| "Integrity"
	| "Lifecycle"
	| "Derived"
	| "Exchanges"

export type LogCode =
	-- Persistence
	"DATASTORE_CRITICAL"
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
	| "PROFILE_ERASED"
	| "PROFILE_ERASE_FAIL"
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
	-- Integrity
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
	-- Replication
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
	-- Transport
	| "INBOUND_OVERSIZE"
	| "INBOUND_OVERSIZE_LIMIT"
	| "INBOUND_RATE_LIMITED"
	| "INBOUND_WORK_LIMIT"
	| "MALFORMED_FRAME"
	| "MALFORMED_FRAME_LIMIT"
	| "SEND_FAIL"
	-- Commands
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
	-- Monetization
	| "GRANT_FAIL"
	| "GRANT_PARTIAL"
	| "GRANT_SEEDED_ELEMENT"
	| "RECEIPT_IN_FLIGHT"
	| "OWNERSHIP_CHECK_FAIL"
	| "PASS_PURCHASE_UNCONFIRMED"
	| "PERK_GRANTED"
	| "PERK_REVOKED"
	| "PRODUCT_INFO_FAIL"
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
	-- Gifting
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
	-- Leaderboards
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
	-- Exchanges
	| "EXCHANGE_INIT_TAMPER"
	| "EXCHANGE_PARKED"
	| "EXCHANGE_REGISTRATION_REFUSED"
	| "EXCHANGE_RESET_REFUSED"
	| "EXCHANGE_RESOLVED"
	| "EXCHANGE_RESOLVE_ERROR"
	| "EXCHANGE_STORE_UNAVAILABLE"
	| "EXCHANGE_UNRESOLVED"
	-- Derived
	| "DERIVED_ERROR"
	| "DERIVED_FEEDBACK"
	| "DERIVED_MISMATCH"
	-- Lifecycle
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
	| "SANDBOXED"
	| "SERVER_STARTED"
	| "SIM_STATUS"
	| "SUBSYSTEM_HOOK_ERROR"
	| "UNKNOWN_OPTION"

export type LogEntry = {
	At: number,
	Level: LogLevel,
	Category: LogCategory,
	Code: LogCode,
	Message: string,
	Context: { [string]: any }?,
}

export type Status = "Healthy" | "Degraded" | "Outage"

export type SessionState = "Loading" | "Ready" | "SessionEnded"

-- Why a data session ended, or why waiting for data did not produce a tree.
-- `WaitForData`'s second return, the `SessionEnded` signal and `GetState`'s stored
-- reason all use this exact set, so a caller can branch exhaustively.
export type LifecycleReason =
	"load-failed" -- the profile could not be loaded (DataStore failure, or the session could not be acquired)
	| "migration-failed" -- a migration step errored, so the profile was released unmigrated (fail-closed)
	| "session-ended" -- the session ended while the player was still in the game (usually stolen by another server)
	| "player-left" -- the player left; the most common reason by far
	| "shutdown" -- the server is closing
	| "still-loading" -- the wait elapsed while the load was still in flight, and may yet succeed
	| "timeout" -- the wait elapsed and Scribe has no session for this player at all

-- The fixed reasons Scribe itself answers a Client.Request with. A handler may
-- return any (false, string) of its own, so a caller types the second return as
-- `string?` and treats a non-member as a handler message. Membership is not proof of
-- a framework refusal either: a handler can return `false, "timeout"`
-- byte-identically. RequestFailed at the bottom of this file, appended as a third
-- value to every refusal here, is the attribution; this union is only the vocabulary.
export type RequestReason =
	"rate-limited" -- over CommandRateLimit; the handler never ran
	| "not-ready" -- the caller's profile is not Ready
	| "unknown-command" -- nothing is registered under that name
	| "bad-args" -- arity or Args-spec mismatch
	| "bad-idempotency-key" -- a key was sent to a command that is not Idempotent, or omitted from one that is
	| "error" -- the handler threw; the traceback goes to COMMAND_ERROR, never to the client
	| "reply-encode-failed" -- the handler succeeded but its return value could not be encoded
	| "timeout" -- client-side: no reply within RequestTimeout
	| "send-failed" -- client-side: the transport raised while sending
	| "edit-mode" -- client-side: not running, and no MockCommand is registered
	| "mock-error" -- client-side: edit mode, and the MockCommand handler threw

-- The fixed refusals of Data.Purchase. A Grant that throws passes the transaction's
-- own error text through instead, so this is not exhaustive over the second return.
export type PurchaseReason =
	"player data not loaded"
	| "invalid Cost spec"
	| "invalid Cost amount"
	| "invalid cost path"
	| "cost path is not a spendable number"
	| "insufficient funds"

-- The fixed refusals of Data.PromptGift. Two more are interpolated (`unknown
-- product "<name>"` and `purchase prompt failed: <err>`) and cannot be members.
--
-- "could not deliver gift" and "gift delivery could not be confirmed" must not be
-- collapsed in a UI: the first means the gift did not go out and the buyer's credit
-- is back, the second means the write may have committed with its answer lost, so a
-- retry would mint a fresh gift id the recipient's dedupe cannot recognise and grant
-- twice off one payment.
export type GiftReason =
	"buyer data not loaded"
	| "invalid recipient"
	| "cannot gift yourself"
	| "gift cooldown"
	| "too many pending gifts"
	| "data services are experiencing issues; try again later"
	| "recipient already owns this"
	| "could not reserve gift credit; try again later"
	| "could not deliver gift; try again later"
	| "gift delivery could not be confirmed; do not send it again"
	| "a gift of this item is already pending; try again shortly"
	| "could not record gift intent; try again later"

export type SaveInfo = {
	LastSaveAt: number?,
	LastResult: ("Ok" | "Fail")?,
	Dirty: boolean,
	Size: number?, -- approx bytes of the last successful save (nil before the first)
}

export type Visibility = "Replicated" | "ServerOnly" | "Shared"

-- The read shape of a Scribe.Big, spelled out here rather than imported so Types
-- stays dependency-free. Kept in sync with Internal.Big.
export type BigScore = {
	M: number,
	E: number,
	Short: (self: any, decimals: number?) -> string,
	ToNumber: (self: any) -> number,
	Log10: (self: any) -> number,
}

export type LeaderboardEntry = {
	Rank: number,
	UserId: number,
	Name: string,
	-- A big board hands back the big itself, not the packed OrderedDataStore key,
	-- so this is not always a number.
	Score: number | BigScore,
}

export type LeaderboardConfig = {
	Stat: string,
	Limit: number?,
	Scale: number?,
	SigFigs: number?, -- Scribe.Big stats only: ranking-key significant figures, 1 to 15 (default 12)
	Replicate: boolean?, -- default false: server-only (Data.GetLeaderboard on the server); true streams the board to clients
}

export type ProductConfig = {
	Id: number,
	Category: string?,
	Grant: ((data: any) -> ())?,
	Grants: string?,
}

export type PassConfig = {
	Id: number,
	Category: string?,
}

export type PurchaseSpec = {
	Cost: { Path: string, Amount: number },
	Category: string?,
	ItemId: string,
	Grant: ((data: any) -> ())?,
	Meta: { [string]: any }?,
	-- Optional. Two calls carrying the same key apply once: the repeat returns the
	-- original outcome without debiting or granting again. A FAILED purchase claims
	-- nothing, so retrying after a refusal still works. Max 64 bytes, valid UTF-8.
	IdempotencyKey: string?,
}

export type PurchaseFilter = {
	Kind: ("Robux" | "InGame")?,
	Category: string?,
	ItemId: string?,
	Since: number?,
	Limit: number?,
}

-- Economy analytics -----------------------------------------------------------

-- The tag passed to Increment/Decrement to auto-emit LogEconomyEvent. All
-- fields are optional: an untagged Increment writes the value without emitting.
export type EconomyMeta = {
	Flow: ("Source" | "Sink")?, -- default: Increment -> Source, Decrement -> Sink
	TransactionType: (Enum.AnalyticsEconomyTransactionType | string)?, -- default "Gameplay"; an EnumItem's .Name is used
	ItemSku: string?,
	Currency: string?, -- override the logged currency label (default: the field's name)
	Fields: { [string]: any }?, -- per-event custom-field values, keyed by declared field name
	-- Accepted aliases for the pre-1.1 tag shape.
	Source: string?, -- alias of TransactionType
	Item: string?, -- alias of ItemSku
}

-- One declared custom-field slot: a plain name (uses the currency/global Prefix
-- default) or a name with its own Prefix override.
export type EconomyFieldSpec = string | { Name: string, Prefix: boolean? }

export type EconomyCurrencyConfig = {
	Label: string?, -- logged currency name (default: the field's name)
	Fields: { EconomyFieldSpec }?, -- up to 3 dimensions -> CustomField01/02/03, in order
	Resolve: ((player: Player) -> { [string]: any })?, -- ambient values for THIS currency, merged over the global Resolve
}

-- The seam Analytics.Economy calls; defaults to AnalyticsService:LogEconomyEvent.
-- Override it (e.g. in tests) to capture emitted events.
export type EconomyLogFn = (
	player: Player,
	flowType: Enum.AnalyticsEconomyFlowType,
	currencyType: string,
	amount: number,
	endingBalance: number,
	transactionType: string,
	itemSku: string?,
	customFields: { [string]: any }?
) -> ()

export type EconomyConfig = {
	Resolve: ((player: Player) -> { [string]: any })?, -- ambient values shared across every currency
	Prefix: boolean?, -- format custom-field values as "Team - Red" (default true)
	Currencies: { [string]: EconomyCurrencyConfig }?,
	LogEconomyEvent: EconomyLogFn?, -- advanced/test seam; defaults to AnalyticsService:LogEconomyEvent
}

export type Disconnect = () -> ()

-- The marker Client.Request appends to every refusal that is Scribe's rather than a
-- handler's. Declared here so both realms share one identity: src/init.luau
-- re-exports it as Scribe.RequestFailed, and src/Client/init.luau returns this exact
-- table.
--
-- Identity rather than a string is the mechanism: Wire.EncodeGeneric serialises
-- tables by value and has no representation for a reference, so nothing a handler
-- returns can decode to this table, where a boolean or a string in the same slot
-- would be forgeable in one line of game code. Frozen because it is a module
-- singleton shared by every bundle in the process.
local RequestFailed = table.freeze({})

-- This module is otherwise types only; RequestFailed is the one runtime value.
return { RequestFailed = RequestFailed }
