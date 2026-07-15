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
	-- Server
	SendToClient: (self: any, player: Player, bytes: buffer) -> (),
	SendToAllClients: ((self: any, bytes: buffer) -> ())?,
	ListenServer: (self: any, callback: (player: Player, bytes: buffer) -> ()) -> (),
	-- Client
	SendToServer: (self: any, bytes: buffer) -> (),
	ListenClient: (self: any, callback: (bytes: buffer) -> ()) -> (),
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

export type LogCode =
	-- Persistence
	"DATASTORE_CRITICAL" | "DATASTORE_RECOVERED" | "EXPORT_ENCODE_FAIL" | "MIGRATED" | "MIGRATION_FAIL" | "OFFLINE_READ_FAIL" | "PROFILE_ERASED" | "PROFILE_LOADED" | "PROFILE_LOAD_FAIL" | "PROFILE_RESET" | "PROFILE_RESTORED" | "PROFILE_SIZE" | "PROFILE_STORE_ERROR" | "PROFILE_STORE_SIGNAL_MISSING" | "PROFILE_VERSION_AHEAD" | "SAVE_INTERVAL_CLAMPED" | "SAVE_INTERVAL_FAIL" | "SAVE_INTERVAL_SET" | "SHUTDOWN_DONE" | "SHUTDOWN_FLUSH" | "SIM_LOAD_FAILURE" | "SIM_SESSION_STEAL" | "STATUS_CHANGED" | "UNKNOWN_ROOT_KEYS" | "VERSION_QUERY_FAIL" | "VERSION_READ_FAIL"
	-- Integrity
	| "ANALYTICS_FAIL" | "ANOMALY" | "TIMED_SWEEP_FAIL" | "WIPE_GUARD_BLOCKED" | "WIPE_GUARD_CLEARED" | "WIPE_GUARD_FORCED" | "WIPE_GUARD_TRIPPED"
	-- Replication
	| "CLIENT_HANDSHAKE_TIMEOUT" | "INIT_APPLIED" | "INIT_SENT" | "OP_BEFORE_INIT" | "SCHEMA_MISMATCH" | "SERIALIZE_FAIL" | "SNAPSHOT_ROOT_DROPPED"
	-- Transport
	| "INBOUND_OVERSIZE" | "MALFORMED_FRAME" | "SEND_FAIL"
	-- Commands
	| "COMMAND_BAD_ARGS" | "COMMAND_ERROR" | "COMMAND_RATE_LIMITED" | "COMMAND_REPLY_ENCODE_FAIL" | "COMMAND_UNKNOWN" | "SIM_COMMAND"
	-- Monetization
	| "GRANT_FAIL" | "OWNERSHIP_CHECK_FAIL" | "PERK_GRANTED" | "PERK_REVOKED" | "RECEIPT_DUPLICATE" | "RECEIPT_GRANTED" | "RECEIPT_HANDLER_BOUND" | "RECEIPT_OFFLINE_RETRY" | "RECEIPT_RETRY" | "RECEIPT_UNKNOWN_PRODUCT" | "SIM_RECEIPT" | "UNDECLARED_CATEGORY" | "UNDECLARED_PERK"
	-- Gifting
	| "GIFT_CREDIT_ISSUED" | "GIFT_CREDIT_USED" | "GIFT_DELIVERY_RETRY" | "GIFT_INTENT_EXPIRED" | "GIFT_INTENT_WRITE_FAIL" | "GIFT_NO_INTENT" | "GIFT_RECEIPT_GRANTED" | "GIFT_RECIPIENT_ALREADY_OWNS" | "GIFT_UNKNOWN_PRODUCT" | "RECEIPT_DECLINED_PENDING_CREDIT" | "RECEIPT_HELD"
	-- Leaderboards
	| "LB_ERASE_FAIL" | "LB_QUEUE_OVERFLOW" | "LB_READ_FAIL" | "LB_SHUTDOWN_FLUSH" | "LB_WRITE_DROPPED" | "LB_WRITE_FAIL" | "SIM_LB_FLUSH"
	-- Lifecycle
	| "API_NAME_COLLISION" | "DEBUG_HOOK_ATTACHED" | "DEBUG_HOOK_ATTRIBUTION" | "DEBUG_HOOK_DUPLICATE" | "DEBUG_HOOK_ERROR" | "DEBUG_HOOK_FAIL" | "DEBUG_HOOK_WRITES" | "DEV_WARNING" | "LISTENER_ERROR" | "ON_PLAYER_INIT_ERROR" | "SERVER_STARTED" | "SIM_STATUS" | "SUBSYSTEM_HOOK_ERROR" | "UNKNOWN_OPTION"

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

export type SaveInfo = {
	LastSaveAt: number?,
	LastResult: ("Ok" | "Fail")?,
	Dirty: boolean,
}

export type Visibility = "Replicated" | "ServerOnly" | "Shared" | "Session"

export type LeaderboardEntry = {
	Rank: number,
	UserId: number,
	Name: string,
	Score: number,
}

export type LeaderboardConfig = {
	Stat: string,
	Limit: number?,
	Scale: number?,
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
}

export type PurchaseFilter = {
	Kind: ("Robux" | "InGame")?,
	Category: string?,
	ItemId: string?,
	Since: number?,
	Limit: number?,
}

export type Disconnect = () -> ()

-- ModuleScripts must return a value; this module only carries types.
return {}
