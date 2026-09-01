# Log Code Reference

Every diagnostic Scribe emits carries a stable, machine-readable `Code`. The string never changes between versions, so you can route, filter and alert on exactly the events you care about without parsing messages. This page lists all of them, grouped by category.

## Routing the codes you care about

Add a sink and pick what leaves your server. Scribe sends nothing anywhere on its own.

```lua
-- ServerScriptService/EmberfallDiagnostics.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)

Scribe.AddLogSink(function(entry)
    -- entry = { At, Level, Category, Code, Message, Context }
    if entry.Level == "Error" or entry.Level == "Fatal" then
        MyBackend:Report(entry)                     -- everything serious
    elseif entry.Code == "PROFILE_SIZE" or entry.Code == "WIPE_GUARD_TRIPPED" then
        MyBackend:Report(entry)                     -- specific codes to watch
    end
end)

-- Or pull recent entries on demand.
Scribe.GetRecentLogs({ Code = "PROFILE_LOAD_FAIL", Limit = 50 })
Scribe.GetRecentLogs({ Level = "Error", Limit = 100 }) -- Level filters by minimum severity
```

`Code`, `Level` and `Category` are typed string unions, so your editor autocompletes them both in a `GetRecentLogs` filter and on `entry` inside a sink. Typing `Code = "PRO` suggests every code beginning with `PRO`.

## Reading a row

Each entry is `{ At, Level, Category, Code, Message, Context }`.

| Level | What it means for you |
| --- | --- |
| `Debug` | Detail for when you are already investigating something. |
| `Info` | A normal event worth a record, such as a profile loading. |
| `Warn` | Something is off, and the game keeps working. |
| `Error` | Something failed. Also fires [`Scribe.OnIssue`](/api/Scribe#OnIssue). |
| `Fatal` | Something failed and cannot recover. Also fires `OnIssue`. |

Each section heading below **is** the entry's `Category` value, so a row's section is exactly what a `Category` filter matches. `Context` carries structured fields that vary by code: the player, a data path, byte counts, store names and so on.

<a id="repeated-failures-are-folded"></a>

??? note "Repeated failures are folded into one line"
    These codes are emitted once per problem rather than once per retry: `PROFILE_STORE_ERROR`, `PROFILE_LOAD_FAIL`, `OFFLINE_READ_FAIL`, `VERSION_READ_FAIL`, `LB_ERASE_FAIL`, `PROFILE_ERASE_FAIL`, `PROFILE_RESTORE_FAIL`, `OFFLINE_WRITE_FAIL`, `MESSAGE_SEND_FAIL`, `GIFT_DELIVERY_RETRY` and `PROFILE_OVERWRITTEN`. Repeated failures of the same subject inside the retry window collapse into the first line.

    Nothing is lost. The first failure of a subject always logs. The line that ends a fold carries `Context.Repeats`, the number of attempts folded into the previous line. The `HealthFailures` and `DataStoreErrors` counters still count every attempt, and `FailuresCollapsed` counts the suppressed lines. See [Diagnostics](./diagnostics).

    A failure with no subject to fold on logs every time.

??? note "Codes that never reach you"
    Rows marked _(Studio only)_ come from the [Scribe Studio](./studio-plugin)'s simulation tools. They cannot fire on a live server, so you can leave them out of production alerting entirely. Rows that say _in DevMode_ are gated the same way in practice, because dev mode defaults to `RunService:IsStudio()` unless you turn `DevMode` on yourself.

    The console filters separately. The built-in sink forwards entries to Roblox's structured `LogService` output keyed by `Code`, so Creator Analytics aggregates by code rather than by message text, and it forwards only entries at or above the `LogLevel` option. That defaults to `Warn` on a live server and `Debug` in Studio.

    Entries below the threshold are still written to the ring buffer and still reach your own sinks, so `GetRecentLogs` sees them even when the console does not.

## Persistence

| Code | Level | Meaning |
| --- | --- | --- |
| `DATASTORE_CRITICAL` | Error | ProfileStore reported the DataStore backend has entered a sustained failure state, so loads and saves are likely failing platform wide. |
| `MESSAGE_SEND_FAIL` | Warn | A cross-server message could not be delivered. Usually a DataStore outage. `SendMessage` returns `false` for the same condition. `Context.ProvablyClean` is `true` only when nothing reached storage; otherwise the write may have committed and lost its answer, so treat the message as retryable rather than lost. |
| `MESSAGE_QUEUE_FULL` | Error | The recipient already holds the maximum 1,000 undelivered messages, so the send was refused and `SendMessage` returned `false`. Nothing already queued is destroyed. `Context.ProvablyClean` is `true` when no attempt in that call reached storage; `false` means an earlier attempt may already have queued the message, so it can still arrive. |
| `MESSAGE_NO_LISTENER` | Warn | A cross-server message arrived for an active session with nothing connected to `Data.OnMessage`. It was not acknowledged, so it is handed to the game again on the next load. Usually a startup race. |
| `MESSAGE_HANDLER_ERROR` | Error | An `OnMessage` handler threw. The message was not acknowledged and is redelivered next session, so a handler that throws deterministically stays stuck until it is fixed. |
| `MESSAGE_HANDLER_STALLED` | Warn | An `OnMessage` handler had not returned when the session ended, so the message was not acknowledged and is redelivered next load. `Context.Outstanding` counts the open deliveries. |
| `MIGRATION_FAIL` | Error / Warn | A migration step threw, or the migrated result contained unpersistable data caught by a scan before the commit. Migrations run on a clone, so the session is aborted and the unmodified original persists rather than half-migrated data. |
| `MIGRATION_RESERVED_DISCARDED` | Error | A migration step changed the reserved `_Scribe` root and that change was discarded. Only `Version` was re-stamped. That root is library owned, and it holds the receipt dedupe ring, gift escrow, gift credits, perks, purchase logs and `Scribe.Timed` deadlines. |
| `MIGRATION_RECONCILE_DEPENDENT` | Warn | Opt-in only, with `MigrationShadow = true`. A migration step behaves differently against the raw stored data than against the reconciled data. Turn the option on while auditing a migration and off again afterwards, because the shadow re-runs your migration bodies and fires their side effects twice. |
| `LEGACY_IMPORTED` | Info | `ImportLegacyData` returned a table and Scribe adopted its top-level keys. The profile then enters the migration chain at version 1 and runs every step. Keys under `_Scribe` and `_ScribeSession` are never adopted, and the profile is not reported as new to `OnPlayerInit`. |
| `LEGACY_IMPORT_FAIL` | Error | `ImportLegacyData` threw, so Scribe refused the load rather than starting the player empty. Loading them empty would commit an empty profile as canonical and strand the legacy data forever. |
| `PROFILE_LOAD_FAIL` | Error | A profile could not be loaded. Under the default `LoadFailurePolicy = "Kick"` the player is kicked and the code fires once. Under `"Wait"` nobody is kicked and the load retries. |
| `PROFILE_VERSION_AHEAD` | Error / Warn | The stored profile's version is newer than this server's code knows about. It fires as `Error` and kicks under `VersionAheadPolicy = "Kick"`, or as `Warn` and proceeds under `"Allow"`. Either way it signals a mixed or staged deploy. |
| `PROFILE_SCHEMA_VIOLATION` | Error / Warn | The opt-in `SchemaPolicy` check found the stored profile does not match the compiled template: a wrong type, a value outside a declared bound, an over-length string, a value outside an enum, invalid UTF-8, an undeclared key, or a container whose shape or caps changed. |
| `EXPORT_ENCODE_FAIL` | Warn | A data export could not JSON-encode a player's profile, so `Export` returns nil instead of a payload. |
| `OFFLINE_READ_FAIL` | Warn | An offline read of a non-active user's profile errored, so `GetOffline` returns nil. This is a retryable read failure and not a genuinely missing profile. |
| `OFFLINE_WRITE_FAIL` | Warn | `UpdateOffline` could not complete because the DataStore call itself failed, so nothing was stored. A refused write, such as a live session elsewhere or a key that changed under the update, is the compare-and-set working and does not fire this. |
| `PROFILE_ERASED` | Warn | A profile was permanently removed through the erase path. The log records the audit context and whether the leaderboard keys were cleared too. |
| `PROFILE_ERASE_FAIL` | Warn | An erase did not complete, so the profile is still stored and the erase must be retried. A leaderboard key that survived a profile removal reports separately as `LB_ERASE_FAIL`. |
| `PROFILE_RESET` | Warn | A profile was wiped back to template defaults because `ResetData` was enabled. Expected in testing, alarming in production. |
| `PROFILE_RESTORED` | Warn | A profile was rolled back to an earlier version. The log records the restored version and the audit context. |
| `PROFILE_RESTORE_FAIL` | Warn | A restore did not complete, so the stored profile is unchanged. The version was not found, a live session held the key, the live key no longer exists, or the commit failed. |
| `RESTORE_RESERVED_PRESERVED` | Warn | A restore rolled the profile back, and the library-owned `_Scribe` root was kept as it was live rather than rolled back with it. That root records events that already happened in the real world, such as settled receipts and spent cooldowns. |
| `SLOW_IMPORT` | Warn | An `ImportLegacyData` hook ran for longer than thirty seconds. The hook is unbounded on purpose and holds the session lock throughout, so this separates one patiently waiting on the DataStore budget from one that has hung. |
| `SLOW_LOAD` | Warn | A profile took longer than ten seconds to load. Measured from the JOIN, not from the DataStore call, so it covers the queue, the retries and any migration: it is what the player waited through. Read the `LoadDuration` percentiles alongside it, because one slow join is weather and a moved p99 is a problem. |
| `PROFILE_SIZE` | Warn | The profile passed the size-warning threshold and is approaching the 4 MB per-key ceiling. Measured before each save attempt, so it still fires when that save then fails. It stays latched until the size drops back. Also fires `OnAnomaly`. |
| `PROFILE_STORE_ERROR` | Warn | ProfileStore reported a DataStore error against this bundle's store. `Context.Class` is `Throttled`, `Failed`, `Unresolved` or `Rejected`, and `Context.Code` is the numeric prefix Roblox sent. A nil code means the message did not carry one. |
| `PROFILE_STORE_SIGNAL_MISSING` | Warn | ProfileStore's error or critical-state signal could not be connected, so save-failure observability for this bundle is off. |
| `PROFILE_TOO_LARGE` | Error | A save failed while the profile is already over the 3.5 MB warning threshold, so the cause is the 4 MB ceiling rather than a throttle. It will not recover on retry. Every later save, including the leave save, keeps failing until the profile is trimmed. |
| `MODE_OVERRIDES_LEGACY` | Warn | `Mode` was set alongside a legacy persistence flag. `Mode` wins and the legacy flag is ignored. Remove the flag to silence this. |
| `SAVE_INTERVAL_CLAMPED` | Warn | The requested `SaveInterval` was below the throttling floor and was raised to it. |
| `SAVE_INTERVAL_CONFLICT` | Warn | Two bundles asked for different autosave cadences. ProfileStore's autosave period is process wide, so the later value wins. Set it once with `Scribe.Configure`. |
| `HEALTH_THRESHOLDS_CONFLICT` | Warn | Two bundles asked for different `StatusThresholds`. The health machine is a library-level singleton, so the thresholds are process wide and the later value wins -- which means one bundle can loosen the Outage gate that refuses Robux for every other bundle. Emitted once per field. Set them once, identically, in every bundle. |
| `SAVE_INTERVAL_FAIL` | Warn | Applying the configured `SaveInterval` threw, so the autosave cadence was not changed. |
| `SAVE_INTERVAL_SET` | Info | The configured `SaveInterval` was applied successfully. |
| `WIPE_GUARD_RATIO_CLAMPED` | Warn | The configured `WipeGuardShrinkRatio` was outside the usable range and was clamped. At or below zero every shrink trips the guard. At or above one it can never trip. |
| `SAVE_WAIT_TIMEOUT` | Warn | A caller waiting on a save gave up. This is unresolved, not failed: the save often lands moments later, so `SavesOk` may increment for the very save the caller was told `false` about. Counted as `SaveWaitTimeouts`. |
| `SIM_LOAD_FAILURE` | Warn | _(Studio only.)_ The Studio plugin armed or triggered a simulated load failure. |
| `SIM_SESSION_STEAL` | Warn | _(Studio only.)_ The Studio plugin force-ended an active session to exercise the session-lock path. |
| `STATUS_CHANGED` | Warn / Info | The health machine moved between Healthy, Degraded and Outage. `Info` when returning to Healthy, `Warn` when degrading. Also fires `OnStatusChanged`. |
| `UNKNOWN_ROOT_KEYS` | Warn | In DevMode, a loaded profile carried top-level keys the template does not declare. That is schema drift a migration should remove. |
| `VERSION_QUERY_FAIL` | Warn | Enumerating a profile's version history failed, so `ListVersions` returns whatever partial results it gathered. |
| `VERSION_READ_FAIL` | Warn | Reading a specific historical version errored, so `GetVersion` returns nil. This is a retryable read failure and not a missing version. |
| `DATASTORE_RECOVERED` | Info | The DataStore backend left its critical state, so the earlier outage has cleared. |
| `MIGRATED` | Info | A stored profile was upgraded through one or more migration steps and committed. |
| `PROFILE_LOADED` | Info | A profile finished loading and reached `Ready`, so the data tree is live. |
| `SHUTDOWN_FLUSH` | Info | Shutdown began. New sessions are refused and the save and leaderboard queues are draining. |
| `SHUTDOWN_DONE` | Info | The shutdown drain finished. It reports sessions left un-drained when the budget expired, exit hooks skipped for want of budget, and hooks cut off while still running. Ideally all three are zero. |

## Integrity

| Code | Level | Meaning |
| --- | --- | --- |
| `PROFILE_OVERWRITTEN` | Error | ProfileStore could not recognise the stored value for a key as a profile and replaced it with a fresh template. The session starts from defaults and the previous data is gone. The overwritten profile comes back at load count 1, so it is otherwise indistinguishable from a first-time player. |
| `WIPE_GUARD_TRIPPED` | Error | Just before a save, the wipe guard detected an implausible collapse in the data. Also fires `OnAnomaly`. |
| `ANOMALY` | Warn | An implausible or suspicious write was detected at a specific path. Often an exploit attempt, sometimes a logic bug. `OutOfBounds` and `OverMaxLength` follow `BoundsPolicy`. Also fires `OnAnomaly`. |
| `PROFILE_TOO_DEEP` | Warn | The stored data is nested deeper than the 24-level write limit. Those leaves load and read correctly, and every write to them is refused at runtime. Flatten the shape or migrate it. |
| `TIMED_SWEEP_FAIL` | Warn | The periodic sweep errored while resetting a lapsed `Scribe.Timed` field, so that field may be left stale. |
| `WIPE_GUARD_BLOCKED` | Warn | The wipe guard tripped under `WipeGuardPolicy = "Block"`, so the pending save is held and the last known-good snapshot is persisted instead. |
| `WIPE_GUARD_FORCED` | Warn | A save the wipe guard had blocked was forced through with `Data.Flush(player, { Force = true })`, overriding the guard. |
| `WIPE_GUARD_CLEARED` | Info | A previously blocked profile passed the check again and resumed saving normally. |
| `ANALYTICS_FAIL` | Debug | Logging an economy event threw, so that event never reached the analytics dashboards. One failure is noise. A sustained stream is a broken pipeline. |
| `ECONOMY_FIELD_UNDECLARED` | Warn | In DevMode, a tagged `Increment` or `Decrement` passed a custom field name the currency did not declare in its `Economy` config, so it was not recorded. Usually a typo. |
| `ECONOMY_FIELDS_OVERFLOW` | Warn | In DevMode, a currency declares more than the three custom-field slots Roblox allows, so the fields past the third are dropped. |

## Replication

| Code | Level | Meaning |
| --- | --- | --- |
| `SERIALIZE_FAIL` | Error | Encoding a replication frame threw, so some queued value could not be put on the wire and the affected ops were not sent as-is. The message carries the encode error. |
| `SNAPSHOT_ROOT_DROPPED` | Error | A top-level root could not be serialized into a client's initial snapshot, so that client receives everything except that root. Also fires `OnAnomaly`. |
| `INIT_APPLIED` | Debug | The client finished applying the initial snapshot, so its mirror now matches the server. This is the normal end of the join handshake and needs no action. |
| `INIT_SENT` | Debug | The server sent a player their initial snapshot. Pair it with `INIT_APPLIED` on the client to see a join complete end to end. |
| `INIT_SEND_FAIL` | Error | The initial snapshot for one player was refused by the transport. The player is deliberately not marked ready, so the client's own retry can still succeed. Counted as `InitSendFailed`. |
| `CLIENT_HANDSHAKE_TIMEOUT` | Warn | A client never sent its Hello frame within the handshake timeout, so replication never started for them. Most often the bundle was never required on the client. A `LocalScript` has to require it to begin the handshake. |
| `INIT_UNDELIVERED` | Warn | The client did send Hello, and the snapshot Scribe built in reply never reached the transport. The one innocent cause is a transport refusing a payload this size, so the message names `MaxOutboundBytes`. |
| `MIRROR_RESYNC` | Warn | A frame addressed to one client could not be delivered, so their mirror no longer matches the server and Scribe is re-sending the whole snapshot. This is a repair rather than a loss, and it names a transport that is refusing frames. |
| `OUTBOUND_OVERSIZE` | Warn | A single outbound frame needed more fragments than Scribe considers reasonable, which is 16, or roughly a megabyte at the default `MaxOutboundBytes`. The frame is still delivered, so this is a cost report. For an `Init` the message names the largest roots by encoded wire bytes. |
| `OP_BEFORE_INIT` | Warn | Client side. A diff frame arrived before the initial snapshot was applied, which is a protocol ordering error. The client re-sends Hello to request a fresh snapshot. |
| `PROTOCOL_MISMATCH` | Warn | A client's wire version differs from the server's, so two different Scribe versions are running. Replication is refused for that client. |
| `SCHEMA_MISMATCH` | Warn | Same wire version, divergent templates, so the client derived a different schema hash. Replication is refused for that client. |

??? note "Two codes for the same symptom, and why"
    `CLIENT_HANDSHAKE_TIMEOUT` and `INIT_UNDELIVERED` both mean a client never got its data, and they are separate codes because the fix is different.

    `CLIENT_HANDSHAKE_TIMEOUT` means the client never asked. Check that a `LocalScript` requires the Emberfall shared module, or that a custom client transport adapter is present and working.

    `INIT_UNDELIVERED` means the client asked and the answer never left. Check `MaxOutboundBytes` against what your channel actually accepts, and look at the `JoinBytes` distribution in [`Scribe.GetMetrics`](/api/Scribe#GetMetrics) to see how large the snapshot has grown.

    `MIRROR_RESYNC` matters more than it looks. A loaded client cannot ask for a resync itself, because every Hello is gated on the client not yet being loaded, so this is the only signal that a mirror ever went stale.

## Transport

| Code | Level | Meaning |
| --- | --- | --- |
| `INBOUND_OVERSIZE` | Warn | An inbound frame exceeded `MaxInboundBytes` and was dropped before decoding, so it does not count toward the malformed-frame budget. Logged at most once per second per player, while `InboundOversize` counts every occurrence. |
| `INBOUND_OVERSIZE_LIMIT` | Warn | A player reached the oversize-frame limit of 32 in one session, so the server stops dispatching their inbound frames for the rest of the session. Scribe cannot build a frame over the limit itself, so the one innocent cause is a `MaxInboundBytes` set below what this game's own commands produce. |
| `INBOUND_WORK_LIMIT` | Warn | A frame would have retained more bytes than `MaxInboundRetainedBytes` allows, so it was dropped part way through decoding. No reply is sent. Raise the option if your own client legitimately sends payloads this large. |
| `INBOUND_RATE_LIMITED` | Warn | A player sent raw frames faster than `MaxInboundFrameRate`, so the frame was dropped before it was read. It drops silently, because replying is the amplification the limit exists to avoid. |
| `MALFORMED_FRAME` | Warn | A frame could not be decoded or dispatched. On the server the per-player malformed count rises and `OnAnomaly` fires. Throttled to once per second per player. |
| `MALFORMED_FRAME_LIMIT` | Warn | A player reached the malformed-frame limit of 32 in one session, so the server stops dispatching their inbound frames for the rest of the session. A real client never sends malformed frames. |
| `SEND_FAIL` | Warn | The transport adapter threw while sending an outbound buffer. Usually an adapter fault, a player who just disconnected, or a sandboxed Scribe package. |
| `FRAGMENT_REFUSED` | Debug | Client side. A fragment was discarded for a gap, a replay, or a declared length past the reassembly cap. The logical frame is abandoned and the next one starts clean. Counted as `FragmentsRefused`. |

??? note "Why the size limits are three separate ceilings"
    They catch three different things, and a single number could not.

    `INBOUND_OVERSIZE` is about raw bytes. `INBOUND_WORK_LIMIT` is about how much memory a frame **retains** once decoded: 8 KB of one-byte booleans retains a quarter of a megabyte of array storage while 8 KB of one string retains 8 KB, and the depth cap does not see it either, because a flat table of four thousand siblings is only one level deep. `INBOUND_RATE_LIMITED` is about how often frames arrive, and it is the only ceiling that sees every frame whatever its type, size or validity.

    Oversize keeps its own session budget rather than counting toward the malformed one, because the two say different things. A malformed frame was decoded and failed. An oversize frame was never read. A shared counter would let either mask the other.

    The work limit is deliberately kept out of the malformed budget as well, because an over-budget frame may be a legitimate payload from your own client and it must not be able to block that player's session.

    The inbound frame rate sits well above `CommandRateLimit` by default, so a chatty but legitimate client hits `COMMAND_RATE_LIMITED`, which does reply, long before this. Reaching `INBOUND_RATE_LIMITED` means traffic no real client produces.

    A non-zero `FRAGMENT_REFUSED` count on a reliable ordered transport is a bug in an adapter, not a network condition. The [transport contract](./transports) forbids the loss and reordering that would explain it.

## Commands

| Code | Level | Meaning |
| --- | --- | --- |
| `COMMAND_ERROR` | Error | A handler threw. The caller gets a generic `error` reply and the traceback stays on the server. |
| `COMMAND_BAD_ARGS` | Warn | An argument failed the registered `Args` spec, so the request was rejected with `bad-args`. Throttled to once per second per player, while `CommandsRejected` counts every occurrence. Sending more arguments than declared is rejected the same way but is not logged at all. |
| `COMMAND_RATE_LIMITED` | Warn | A player sent commands faster than `CommandRateLimit`, so the request was rejected with `rate-limited`. Throttled to once per second per player. Past a sustained flood the rejection reply is dropped too. |
| `COMMAND_UNKNOWN` | Warn | A client invoked a name the registry does not hold, so it was rejected with `unknown-command`. Usually version skew, sometimes probing. The throttle clock is per code, so this and `COMMAND_BAD_ARGS` do not throttle each other. |
| `COMMAND_REPLY_ENCODE_FAIL` | Warn | A handler returned a value the wire cannot carry, such as an `Instance` or a function, so the caller sees `reply-encode-failed`. The handler's writes still stand. |
| `COMMAND_REPLY_TRUNCATED` | Warn | A handler returned more than the eight values a reply frame carries, so the caller saw trailing nils. Pack the extras into a table. |
| `COMMAND_BAD_IDEMPOTENCY_KEY` | Warn | The command's idempotency requirement and the request disagreed, or the key was empty, over 64 bytes, or not valid UTF-8. The handler never ran. |
| `COMMAND_IDEM_EVICTED` | Warn | A player's 64-record idempotency cache was full, so the oldest settled record was dropped. A retry under that key will run the handler a second time. Also counted as `CommandIdemEvicted`. |
| `COMMAND_IDEM_SATURATED` | Warn | All 64 records were still in flight, so there was nothing safe to evict and the new request was refused with `rate-limited`. That means 64 handlers are yielding at once for one player. |
| `SIM_COMMAND` | Info | _(Studio only.)_ A developer invoked a command through the Studio plugin rather than a real client. |

??? note "Why an idempotency mismatch is refused rather than downgraded"
    A caller who believes a command is deduplicated and is wrong is worse off than one who knows it is not, so `COMMAND_BAD_IDEMPOTENCY_KEY` refuses in both directions and never quietly falls back to a plain request. See [Commands & Requests](./commands).

    `COMMAND_IDEM_EVICTED` exists for the same reason. Reaching it needs far more distinct keys in flight than a real client produces, and when it happens the protection is genuinely gone for those keys, so it is reported rather than dropped silently.

    `COMMAND_IDEM_SATURATED` is the other end of the same cache. Dropping an in-flight record would strand every duplicate parked on it, so nothing is dropped and the new request is refused instead. Look for a handler that never returns, or a client deliberately holding them open.

## Monetization

| Code | Level | Meaning |
| --- | --- | --- |
| `GRANT_FAIL` | Error | A product's `Grant` threw, so the grant was aborted fail-closed and the receipt returns `NotProcessedYet` for Roblox to retry. There is a bug in the `Grant` function. |
| `GRANT_PARTIAL` | Error | A product's `Grant` yielded and then threw. The writes it made before throwing are already in the profile and cannot be taken back, so the receipt is settled as delivered once instead of retried. The purchase log entry is marked `Partial`. Counted as `ReceiptsPartial`. |
| `GRANT_SEEDED_ELEMENT` | Warn | _(DevMode only.)_ A `Grant` brought a container element into existence by writing through a key that named none, so the element was seeded from its defaults. When the key came from stored data, that is a dangling dereference and the player gets goods on something they can never see. |
| `RECEIPT_IN_FLIGHT` | Warn | The same buyer and purchase id were already being processed on this server, so this delivery was refused and left for Roblox to retry. Seeing it occasionally is the guard working. Seeing it constantly means something is re-invoking `ProcessReceipt` concurrently. |
| `RECEIPT_UNKNOWN_PRODUCT` | Error | A receipt arrived for a product id that is not in `Products`, so it cannot be granted and is deferred. Add the product to the registry. |
| `OWNERSHIP_CHECK_FAIL` | Warn | A game-pass ownership call errored, so the check could not be resolved and is treated as not owned. Frequent hits point at a Roblox API problem. |
| `PASS_PURCHASE_UNCONFIRMED` | Warn | A game-pass purchase reported success but the ownership check did not confirm it, so nothing was credited and no purchase-history entry was written. A genuine purchase the API had not caught up with is credited on the player's next load. Frequent hits point at API lag; a steady stream for one player is worth looking at. |
| `RECEIPT_OFFLINE_RETRY` | Warn | An offline receipt could not read the buyer's saved profile, so the purchase is deferred for Roblox to retry. Repeated hits suggest DataStore read problems. |
| `RECEIPT_RETRY` | Warn | A grant was applied in memory but the save did not confirm within the timeout, so the receipt returns `NotProcessedYet`. This is safe because the grant is idempotent. Persistent hits point at save latency. |
| `PURCHASE_CLAIM_EVICTED` | Warn | A profile held `MaxPurchaseClaims` live `Data.Purchase` claims, so the one nearest to expiring was dropped. A retry under that key would apply the purchase a second time. |
| `PURCHASE_ID_EVICTED` | Warn | The receipt dedupe ring was full of ids that have not yet passed `PurchaseIdTTL`, so the oldest were dropped. If Roblox retries a receipt whose id was dropped, it is granted a second time. Raise `MaxProcessedPurchaseIds`. |
| `UNDECLARED_CATEGORY` | Warn | In DevMode, a purchase-log entry used a category string that is not in the declared set. Usually a typo. |
| `UNDECLARED_PERK` | Warn | In DevMode, a perk key was granted or referenced that is not in the `Perks` registry. Usually a typo. |
| `UNKNOWN_OWNS_KEY` | Warn | In DevMode, `Owns` or `OwnsAsync` was called with a key that is not a registered pass, a declared perk, a product grant, or `RobloxPlus`, so it will always return false. Warned once per key. |
| `PRODUCT_INFO_FAIL` | Warn | _(Client.)_ Marketplace refused every attempt to read a pass or product's info, so its price stays `nil` rather than falling back to the undiscounted catalog price. Usually rate limiting. The read is retried by the next `GetProductInfo` call. |
| `PRODUCT_INFO_THROTTLED` | Warn | _(Client.)_ A product info read failed and will be retried with backoff. Roblox rate-limits `GetProductInfoAsync` and does not publish the limit. |
| `SIM_RECEIPT` | Warn | _(Studio only.)_ The Studio plugin injected a mock receipt. Injection requires the resolved `Mode = "Mock"`, so no real store is ever touched. |
| `PERK_GRANTED` | Info | A perk flag was set on a ready player. |
| `PERK_REVOKED` | Info | A perk flag was cleared on a ready player. |
| `PURCHASE_DUPLICATE` | Info | A `Data.Purchase` carried an idempotency key that had already been applied, so the grant was skipped and the call returned success. Keys expire at `PurchaseClaimTTL`. |
| `RECEIPT_DUPLICATE` | Info | A receipt whose purchase id was already processed was re-acknowledged, returning `PurchaseGranted` without granting again. Normal Roblox retry behaviour. |
| `RECEIPT_GRANTED` | Info | A purchase was applied and durably saved. This is the expected success path for `CoinPack500` and `GemPack100`. |
| `RECEIPT_HANDLER_BOUND` | Info | Scribe bound `MarketplaceService.ProcessReceipt` and now handles developer-product receipts. Set `OwnReceipts = false` if your game runs its own handler. |

??? note "Two receipt codes worth understanding"
    **`GRANT_PARTIAL`.** A yielding `Grant` cannot run inside a transaction, so it runs without rollback. When it throws half way, its writes are already in the profile. Answering `NotProcessedYet` would make Roblox retry and re-apply those writes on every attempt, which in testing produced 1000, then 2000, then 3000 coins, all persisted. Settling the receipt as delivered once is the smaller loss, and the code is raised so an operator can compensate the player by hand.

    The fix is always the same. Move the async work out of `Grant`, either before the prompt or afterwards through `OnSave`, and the grant becomes atomic again. See [Monetization](./monetization).

    **`RECEIPT_IN_FLIGHT`.** The persisted dedupe ring is a completion record, written only after the grant commits. Between the duplicate check and that write, a second delivery of the same receipt would otherwise see "not yet granted" and grant again. Every yield in that window widens it, including a yielding `Grant`, an offline round trip, or a gift's cross-server message.

    The guard never waits. It refuses immediately and leaves the retry to Roblox. By the time Roblox retries, the first call has either marked the receipt processed, so the retry answers `PurchaseGranted`, or failed, so the retry is clean.

## Gifting

| Code | Level | Meaning |
| --- | --- | --- |
| `GIFT_CREDIT_REFUND_FAIL` | Error | A gift delivery failed AFTER the buyer's paid credit had been spent, and the buyer had already left, so the refund had to go to their stored profile -- and that write failed too. The credit is lost and needs restoring by hand; the code names the user and the product. |
| `GIFT_INTENT_WRITE_FAIL` | Error | The durable save of a pending gift intent failed right before prompting, so the prompt is refused and no Robux is charged. |
| `GIFT_UNKNOWN_PRODUCT` | Error | A cross-server gift message referenced a product name this server does not have, which is a deploy mismatch. The message is kept so a later deploy can process it, and delivery is stalled until then. |
| `GIFT_AIM_CAP_REACHED` | Warn | The buyer's durable gift-aim store is at its cap. Either a prompt was refused before any Robux moved, or a stale intent could not be archived at load and its recipient was forgotten. |
| `GIFT_AIM_EXPIRED` | Warn | A durable gift aim passed the receipt-retry horizon with its purchase unsettled and was dropped. It names the recipient and product so the gift can be compensated by hand. A receipt arriving after this is granted to the buyer. |
| `GIFT_AIM_SETTLED` | Warn | A receipt arrived after its gift intent had been swept as stale and was settled from the durable aim, so it reached the recipient it was paid for rather than the buyer. |
| `GIFT_CREDIT_ISSUED` | Warn | A giftable perk was bought with no gift intent while the buyer already owns it, under `NoGiftIntentPolicy = "GrantOrCredit"`, so a re-aimable credit was written instead of a no-op grant. Also fires `OnGiftCredit`. |
| `GIFT_CREDIT_UNCONFIRMED` | Warn | A gift bought with a paid credit could neither be confirmed delivered nor proved undelivered, so the credit was deliberately NOT refunded: the gift may already be queued, and handing the credit back would let one payment grant twice under a fresh id. It names the buyer, the product and the recipient so the rare genuine loss can be compensated by hand. |
| `GIFT_DELIVERY_RETRY` | Warn | Cross-server gift delivery failed, so the receipt returns `NotProcessedYet` and Roblox will retry. Repeated hits point at a DataStore messaging problem. |
| `GIFT_INTENT_EXPIRED` | Warn | A stored gift intent outlived the intent TTL, which is an abandoned prompt. It is cleared and any incoming receipt falls through to the no-intent policy. Normal cleanup. |
| `GIFT_NO_INTENT` | Warn | A giftable perk was bought with no matching intent and the buyer does not already own it, so the perk was granted to the buyer. An expected fallback. |
| `GIFT_RECIPIENT_ALREADY_OWNS` | Warn | Between prompt and receipt the recipient acquired the perk anyway, so the purchase became a re-aimable credit for the buyer rather than a wasted grant. Also fires `OnGiftCredit`. |
| `RECEIPT_DECLINED_PENDING_CREDIT` | Warn | A no-intent perk purchase arrived while the buyer already owns the perk and still holds an unused credit, so the purchase was declined and Roblox refunds it. |
| `RECEIPT_HELD` | Warn | A no-intent perk purchase arrived while the buyer already owns the perk under `NoGiftIntentPolicy = "Hold"`, so the receipt is held for retry instead of auto-crediting. |
| `GIFT_CREDIT_UNKNOWN_PRODUCT` | Warn | A player holds gift credits keyed by a product name that is no longer in `Products`. The paid credits are unspendable until the product returns or a migration renames the key. They are never deleted automatically. |
| `GIFT_CREDIT_USED` | Info | A buyer redeemed an existing credit to deliver a gift, so no new purchase was charged. |
| `GIFT_RECEIPT_GRANTED` | Info | A gift purchase was durably delivered to the intended recipient and logged as sent. |

## Leaderboards

| Code | Level | Meaning |
| --- | --- | --- |
| `LB_ERASE_FAIL` | Error | A board removal failed during user erasure, so the player's score may still sit on at least one board and the erase must be retried. One entry per erase, with `Context.Boards` listing every board that failed. |
| `LB_INTERVAL_CLAMPED` | Warn | A board's `RefreshInterval` was below the 60 second floor and was raised to it. A sub-minute board is almost always an in-server scoreboard, which belongs in [`Scribe.Shared`](./visibility) at no DataStore cost. |
| `LB_QUEUE_OVERFLOW` | Warn | The write queue hit its cap, so the oldest pending score write was dropped. Score updates are arriving faster than the pacer can persist them. |
| `LB_READ_FAIL` | Warn | A board refresh failed, so its rankings could not be updated this cycle. Store failures are throttled to one line per code every 30 seconds, and the line carries how many it suppressed; the counters keep counting every attempt. Studio with API access off is reported once for the whole session instead, because it is a setting rather than an outage. |
| `LB_BUDGET_DEFERRED` | Warn | Under `BudgetPolicy = "Defer"`, a background request was postponed because the DataStore budget was down to the reserve. Nothing is dropped, and boards update more slowly until the allowance recovers. Logged at most once per 30 seconds. |
| `LB_WRITE_DROPPED` | Warn | A score write was abandoned after three failed retries with no newer value superseding it, so that update was lost. Throttled the same way as `LB_READ_FAIL`. |
| `LB_SCORE_OUT_OF_RANGE` | Warn | The score fell outside what an ordered key can hold, so the write was dropped rather than queued, since it would be rejected on every attempt. Lower `Scale`, or bound the stat. |
| `LB_WRITE_FAIL` | Warn | One score write attempt failed. It may still be retried up to the retry limit. Throttled the same way as `LB_READ_FAIL`. |
| `LB_STAT_RESOLVE_FAIL` | Warn | A board's `Stat` path failed to resolve for one player at load, so that board is not tracking them this session. The other boards are unaffected. |
| `LB_UNKNOWN_BOARD` | Warn | In DevMode, a board name was requested that is not declared in the `Leaderboards` option. Board names are case sensitive, so `"toplevel"` does not match `TopLevel`. Warned once per name. |
| `LB_SHUTDOWN_FLUSH` | Info | The write queue was drained during shutdown, reporting how many writes landed and how many remained. |
| `SIM_LB_FLUSH` | Info | _(Studio only.)_ A developer drained the write queue from the Studio plugin. |

??? note "Why board failures never move the health status"
    Leaderboard read and write failures deliberately do not feed the global health machine. Routine ordered-store throttling would otherwise flip the status to `Outage`, and `Outage` blocks Robux receipts. A slow `TopLevel` board must never stop players buying `GemPack100`.

    `LB_SCORE_OUT_OF_RANGE` fires for two different reasons and the message says which. On a plain numeric stat, the score multiplied by the board's `Scale` passed the exact-integer range an ordered key can hold without losing its low digits. On a [`Scribe.Big`](./leaderboards) stat, the score was negative, because the packing has no sign bit, or its exponent passed the board's cap for its configured significant figures. `Scale` does not apply to a big board.

    A sustained `LB_BUDGET_DEFERRED` means the server produces score changes faster than its ordered-write allowance can carry them. Raise `RefreshInterval`, or write fewer distinct stats.

## Exchange

Every one of these is about an exchange in progress. None of them means value was lost: the design's whole claim is that an exchange conserves whatever happens to it, and these say WHERE it currently is. See [Exchange](./exchange).

| Code | Level | Meaning |
| --- | --- | --- |
| `EXCHANGE_INIT_TAMPER` | Error | `OnPlayerInit` or a `Scribe.Dynamic` factory changed the in-flight exchange ledger. Those hooks receive the profile directly, before the tree exists, so the usual refusal has nothing to refuse through. The change is reverted; find the line that writes into `_Scribe`. |
| `EXCHANGE_PARKED` | Warn | A delivery could not be applied, usually because the destination is full or the key is taken. The item is waiting in the player's inbox and is retried on every load and on the sweep. Nothing is lost. |
| `EXCHANGE_REGISTRATION_REFUSED` | Error | A `Exchangeable` declaration names a path that cannot be moved safely. Raised at startup, by name; see [Exchange](./exchange). |
| `EXCHANGE_RESET_REFUSED` | Error | `ResetData` was asked to wipe a profile holding an in-flight or undelivered exchange. Refused, because the wipe would take the escrow with it and leave nothing to return. Resolve or discard the exchange first. |
| `EXCHANGE_RESOLVED` | Info | An interrupted exchange reached its terminal state on load or on the sweep. |
| `EXCHANGE_RESOLVE_ERROR` | Error | Resolving one exchange raised. Other exchanges on the same profile are unaffected; this one keeps its value and is retried. |
| `EXCHANGE_STORE_UNAVAILABLE` | Error | The verdict key could not be reached, so no exchange can be started or resolved on this server. Scribe deliberately does NOT fall back to a local store: a verdict nothing else can see is worse than no verdict. |
| `EXCHANGE_UNRESOLVED` | Warn | An exchange could not be resolved this time, usually because no verdict could be established. The value stays where it is and the next load or sweep tries again. |

## Derived

| Code | Level | Meaning |
| --- | --- | --- |
| `DERIVED_ERROR` | Error | A [derived field](./derived)'s compute function threw. The field keeps its previous value and the write that triggered the recompute still succeeds, so the symptom is a field that stops tracking its inputs. Logged once per field per session. |
| `DERIVED_FEEDBACK` | Error | A `Changed` listener kept writing an input from inside the recompute its own field triggered, so the settle pass gave up after four rounds. Move the write out of the listener, or derive the value instead of writing it. |
| `DERIVED_MISMATCH` | Warn | _(DevMode only.)_ The server computed a different value than this realm did for a field both compute locally, so the compute function is not pure. Look for `os.time`, `math.random`, or an upvalue that differs between the two realms. The server's value is applied. |

A derived compute runs on both realms, which is what makes Emberfall's `Level` free to replicate: only `Xp` crosses the wire. Outside DevMode nothing is sent, so nothing is compared, which is why an impure compute has to be caught in Studio before it ships. See [Derived Fields](./derived).

## Lifecycle

| Code | Level | Meaning |
| --- | --- | --- |
| `LISTENER_ERROR` | Error | A listener or callback you supplied threw while processing a data change. Scribe caught it and reported it. |
| `ON_PLAYER_INIT_ERROR` | Error | The `OnPlayerInit` callback threw while initializing a newly loaded profile. |
| `DYNAMIC_DEFAULT_FAILED` | Error | A `Scribe.Dynamic` factory threw while seeding a field on a brand-new profile, so that field keeps its declaration-time baseline. |
| `PROFILE_UNPERSISTABLE` | Error | A value in the loaded profile cannot be stored and would fail the whole save: invalid UTF-8, an unserializable value, a table mixing array indices with string keys, or a table nested past 64 levels. Scribe logs the exact path and leaves the value in place for you to fix. Also fires `OnAnomaly`. |
| `SUBSYSTEM_HOOK_ERROR` | Error | An internal load hook for Timed, Monetization, Leaderboards or Replication errored when a player's entry became ready. |
| `API_NAME_COLLISION` | Warn / Error | A template field name collides with a reserved accessor or method name, so that field is unreachable through the typed API. Rename it. |
| `DEV_WARNING` | Warn | In DevMode, a call pattern that is almost certainly a bug was detected. The current case is `Decrement` with a negative delta, which adds instead of subtracting. The message names the path. |
| `SANDBOXED` | Warn | The Scribe package has Roblox's `Sandboxed` property set, so it cannot fire its replication events and nothing will sync. Set `Sandboxed = false` on the Scribe package and on ProfileStore. Usually caused by inserting Scribe from the toolbox instead of syncing from source. |
| `UNKNOWN_OPTION` | Warn | In Studio, an option key passed to Scribe was not recognised and would be silently ignored. Boot the game in Studio at least once after changing options, or the typo goes unreported. |
| `DEBUG_HOOK_DUPLICATE` | Warn | _(Studio only.)_ A second debug hook tried to attach, so only the first bundle is inspectable in the plugin. |
| `DEBUG_HOOK_ERROR` | Warn | _(Studio only.)_ The debug bridge dropped a diagnostic chunk. Only the inspector view is affected. |
| `DEBUG_HOOK_FAIL` | Warn | _(Studio only.)_ Attaching the debug hook errored, so the game runs normally and is not inspectable this session. |
| `DEBUG_HOOK_WRITES` | Warn | _(Studio only.)_ The plugin toggled its ability to write to live data. |
| `SIM_STATUS` | Warn | _(Studio only.)_ The plugin forced the health status for testing, which broadcasts the new status. Also fires `OnStatusChanged`. |
| `DEBUG_HOOK_ATTACHED` | Info | _(Studio only.)_ The Studio plugin finished its handshake and attached. |
| `DEBUG_HOOK_ATTRIBUTION` | Info | _(Studio only.)_ The plugin turned write-source attribution on or off. |
| `SERVER_STARTED` | Info | The Scribe server finished initializing, reporting the field count and the transport name. |

??? note "Two lifecycle checks worth knowing"
    The client reports a shadowed **root** field at `Error`, on live servers as well as in Studio, because that is the case where `Data.Coins` silently turns from an accessor into a method.

    The server's checks stay at `Warn` and are gated on `DevMode`. Those are a root name matching a `Data` API name, and any field named like an accessor method such as `Get`. `DevMode` defaults to Studio but is an ordinary option, so a headless or CI run can turn it on.

    Both realms scan after the whole `Data` surface is built, so a name assigned late in construction is judged like any other. See [Configuration](./configuration).

    **`PROFILE_UNPERSISTABLE` runs on every load.** The scan covers the whole profile, not only what load-time code wrote, and there is no option to turn it off.

    The usual source is a `Scribe.Dynamic` factory or the `OnPlayerInit` hook, both of which bypass the accessor write guard. Corruption that came straight out of the DataStore is reported the same way. The entry is non-fatal and names the exact path, because the alternative is a save that fails silently forever.

## Where to next

- [Diagnostics](./diagnostics) shows the counters and health machine these codes accompany.
- [Scribe Studio](./studio-plugin) renders the log ring as a filterable live panel.
- [Configuration](./configuration) covers `LogLevel`, `LogRingSize` and `DevMode`, which decide which of these you actually see.
- [Commands & Requests](./commands) explains the `COMMAND_*` codes from the caller's side.
- [Monetization](./monetization) explains the receipt and gift codes in the order they actually happen.
