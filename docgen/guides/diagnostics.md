# Diagnostics

Scribe is built to be observable in production. Every failure has a stable code, and even allows you to send logs off-platform (i.e. to your backend server).

## Structured logs

Logs carry a stable machine-readable code (`PROFILE_LOAD_FAIL`, `MIGRATION_FAIL`, `WIPE_GUARD_TRIPPED`, `LB_WRITE_FAIL`, `MALFORMED_FRAME`, …), a category, a message, and a context table. They land in a 512-entry ring buffer and in any sinks you add.

```lua
Scribe.GetRecentLogs({ Code = "PROFILE_LOAD_FAIL", Limit = 20 }) -- oldest first; the newest is last
Scribe.AddLogSink(function(entry) forwardToMyPipeline(entry) end) -- your own forwarding
Scribe.OnIssue:Connect(function(entry) alert(entry) end)          -- every Error/Fatal
```

The default sink uses [LogService structured logging](https://devforum.roblox.com/t/full-release-debug-faster-with-new-structured-logging-methods/4668415) (one stable template per code, so Creator Analytics aggregates by code) with a `print`/`warn` fallback. Scribe has **no built-in webhooks**.

Every code Scribe can emit, with its severity and meaning, is listed in the [Log Code Reference](./log-codes). That is the page to skim when you decide which codes to route to your own backend.

## Service health

[`Scribe.GetStatus()`](/api/Scribe#GetStatus) reports `"Healthy" | "Degraded" | "Outage"`, fed by ProfileStore's error signals. It broadcasts to clients so you can show players a "your progress may save late" notice:

```lua
Scribe.OnStatusChanged:Connect(function(status) ... end)  -- server
Data.OnServiceStatus:Connect(function(status) ... end)    -- client
```

## Metrics and save state

[`Scribe.GetMetrics()`](/api/Scribe#GetMetrics) returns a flat snapshot for developer/admin panels and load tests. Plain counters and gauges are numbers; timing and size distributions are `{ Count, Average, Max }` records. Per-player save state ([`GetSaveInfo`](/api/Server#GetSaveInfo)) replicates to the owner for "Saved ✓ / Saving… / Unsaved changes" UI.

The keys a panel usually wants:

| Key | Kind | Meaning |
| --- | --- | --- |
| `ProfilesLoaded`, `ProfileLoadFailures` | counter | Profile loads attempted successfully vs failed |
| `ActiveSessions` | gauge | Profiles currently held on this server |
| `SavesOk`, `SavesFailed` | counter | Save outcomes |
| `SaveDuration` | distribution | Seconds per save |
| `ProfileSize` | distribution | Approximate bytes of the last saved payload, against the ~4 MB ceiling |
| `WipeGuardTrips`, `Anomalies`, `SnapshotRootDropped` | counter | Integrity events; each one also fires [`OnAnomaly`](/api/Server#OnAnomaly) |
| `MigrationsFailed` | counter | Migration steps that threw or produced unpersistable data. Logged as [`MIGRATION_FAIL`](./log-codes#persistence), with no `OnAnomaly` |
| `HealthStatus` | gauge | `0` Healthy, `1` Degraded, `2` Outage |
| `HealthFailures` | counter | Failed DataStore operations, plus one `HealthFailures_<Subsystem>` counter per subsystem (`ProfileStore`, `ProfileLoad`, `Leaderboards`, `OfflineRead`, …) |
| `Handshakes`, `DiffFlushes`, `OpsQueued`, `OpsCoalesced`, `OpsSent` | counter | Replication throughput |
| `BytesOutPerSend` | distribution | Bytes per outbound frame |
| `MalformedFrames`, `InboundOversize`, `InboundRateLimited` | counter | Rejected inbound frames, see the [Transport codes](./log-codes#transport) |
| `PurchaseIdsEvicted` | counter | Un-expired receipt ids dropped by the ring's count backstop, see [`PURCHASE_ID_EVICTED`](./log-codes#monetization) |
| `CommandsReceived`, `CommandsHandled`, `CommandsRejected`, `CommandsRateLimited`, `CommandErrors` | counter | Command dispatch outcomes |
| `ReceiptsReceived`, `ReceiptsGranted`, `ReceiptsRetried`, `ReceiptsDeclined`, `ReceiptsDuplicate` | counter | Receipt outcomes |
| `GiftPrompts`, `GiftsDelivered`, `OwnershipCheckFailures` | counter | Monetization side |
| `LbWrites`, `LbWriteFailures`, `LbReadFailures`, `LbQueueOverflow`, `LbScoreOutOfRange` | counter | Leaderboard traffic |
| `LbQueueDepth` | gauge | Pending leaderboard writes |
| `EconomyEvents`, `EconomyEventFailures` | counter | Analytics events emitted vs dropped |
| `SchemaNodes` | gauge | Compiled schema size, useful as a template-growth canary |

A key exists only once something has emitted it, so treat a missing key as zero rather than as an error. The counters are a **library-level singleton per context**: the server bundle owns everything above, while `Scribe.GetMetrics()` on the client reports only `DiffsApplied`, the count of diff frames the client mirror has applied.

## Version and bundle skew

[`Scribe.Version`](/api/Scribe#Version) is the library version string (`"1.3.1"`). Log it once on each side at startup, because server and client compile their schemas from the *same shared module*, and a stale copy on one side is the failure this catches:

```lua
print("Scribe", Scribe.Version)  -- run it from a server script and from a LocalScript
```

Skew shows up at the handshake, never as a wrong value. The server refuses to replicate to a mismatched client and logs one Warn:

- [`PROTOCOL_MISMATCH`](./log-codes#replication): the wire layout differs, so two different Scribe versions are running.
- [`SCHEMA_MISMATCH`](./log-codes#replication): same wire version, divergent templates, so the client derived a different schema hash.

Both fail closed, so on that client `Data.WaitForData()` returns `false` after its timeout and every field stays at its template default. There is no client-side log for either, so the server log ring is where you look. Only a custom cross-place transport can produce this on vanilla Roblox, since a normal place ships one version of the shared module to both sides.

## Wipe guard

Every save is compared against the last good one. If top-level keys vanish or the payload collapses in size, `WIPE_GUARD_TRIPPED` fires along with the [`OnAnomaly`](/api/Server#OnAnomaly) signal.

- `WipeGuardPolicy = "Warn"` (default): log it and let the save through, since resets are sometimes legitimate.
- `WipeGuardPolicy = "Block"`: persist the last good snapshot instead, until you push the live data through with `Data.Flush(player, { Force = true })`.

## Data size

Scribe warns with the log code `PROFILE_SIZE` as a profile approaches the ~4 MB DataStore value ceiling, so you catch runaway growth before saves start failing.

## Seeing it live

Everything on this page (the log ring, health machine, metrics, and per-flush bandwidth) is rendered as an interactive dock by the **[Scribe Studio companion plugin](./studio-plugin)**, which also lets you simulate outages and profile traffic in Studio.
