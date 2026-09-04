# Diagnostics

When something goes wrong with player data, you want to know before the players tell you. Scribe reports every failure with a stable code, tracks whether the DataStore backend is healthy, and keeps a running set of counters you can put on an admin panel. Nothing is sent anywhere on its own, so you decide what leaves the server.

## Alerting on the two things that matter

Drop this in a server script beside your Emberfall bundle. It covers serious failures and service health, which is most of what you need on day one.

```lua
-- ServerScriptService/EmberfallDiagnostics.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)

-- Every Error and Fatal entry arrives here, whatever produced it.
Scribe.OnIssue:Connect(function(entry)
    warn(`[Emberfall] {entry.Code}: {entry.Message}`)
end)

-- "Healthy", "Degraded" or "Outage", derived from ProfileStore's error signals.
Scribe.OnStatusChanged:Connect(function(status)
    if status ~= "Healthy" then
        warn(`[Emberfall] data service is {status}`)
    end
end)
```

[`OnIssue`](/api/Scribe#OnIssue) fires for every `Error` and `Fatal` log entry, so a failed profile load, a tripped wipe guard and a broken migration all land in one place. [`OnStatusChanged`](/api/Scribe#OnStatusChanged) fires only when the health verdict actually moves, so it is quiet on a healthy server. Replace the `warn` calls with whatever your studio already uses for alerting.

## Reading the logs

Every entry is a plain table: `{ At, Level, Category, Code, Message, Context }`. `Level` is one of `Debug`, `Info`, `Warn`, `Error` or `Fatal`. `Code` is a stable string such as `PROFILE_LOAD_FAIL` or `WIPE_GUARD_TRIPPED` that never changes between versions, so it is safe to match on.

Entries land in a ring buffer holding 512 of them, and in any sinks you add.

```lua
-- Pull recent entries on demand. Oldest first, so the newest is the LAST element.
local recent = Scribe.GetRecentLogs({ Code = "PROFILE_LOAD_FAIL", Limit = 20 })

-- Or forward them somewhere as they happen.
local detach = Scribe.AddLogSink(function(entry)
    if entry.Level == "Error" or entry.Level == "Fatal" then
        MyBackend:Report(entry)
    end
end)
```

`Code`, `Level` and `Category` are typed string unions, so your editor autocompletes them both in a filter and on `entry` inside a sink. Raise the ring size with the `LogRingSize` option when 512 entries is not enough history. Scribe has no built-in webhooks: keep the credentials in your own game code.

Every code Scribe can emit, with its severity and its meaning, is in the [Log Code Reference](./log-codes). Skim that page once when you decide which codes to route to your own backend.

??? note "When to keep the detach function"
    [`AddLogSink`](/api/Scribe#AddLogSink) returns a function that removes the sink again. Calling it twice is a no-op rather than removing whoever took that slot since.

    Ignore the return value for a sink you register once at startup and keep forever, which is the normal case. Keep it when the sink has a lifetime: a hot-reloaded module, a bundle you `Stop()`, a test. The sink list is a module singleton that nothing else clears, and every log entry spawns one thread per registered sink, on the busiest failure path there is. A sink re-registered on every reload multiplies that cost with no other way to undo it.

## Service health

[`Scribe.GetStatus()`](/api/Scribe#GetStatus) reports `"Healthy"`, `"Degraded"` or `"Outage"`. The verdict is broadcast to clients too, so you can put a notice in the Emberfall UI when saves are struggling.

```lua
-- StarterPlayerScripts/EmberfallUi.client.luau
local Data = require(ReplicatedStorage.Shared.EmberfallData).Client

Data.OnServiceStatus:Connect(function(status)
    saveWarningLabel.Visible = status ~= "Healthy"
    saveWarningLabel.Text = "Your progress may save late."
end)
```

??? note "Degraded changes nothing on its own"
    Scribe reports `Degraded` and broadcasts it, and then behaves exactly as before. It is a signal for your game to act on: show a notice, pause the Emberfall shop, stop handing out gems.

    Only `Outage` gates anything inside Scribe, and only four things: receipts, gifts, restores and erases. Everything else keeps running.

    `Outage` lifts back to `Degraded` on its own once a full failure window passes with no failures at all, because a burst that ended should not keep refusing Robux forever. It lifts no further by itself. Returning to `Healthy` takes a streak of successful operations, since nobody reporting a failure is not evidence that anything worked.

## Metrics for an admin panel

[`Scribe.GetMetrics()`](/api/Scribe#GetMetrics) returns a flat snapshot. Plain counters and gauges are numbers. Timing and size distributions are `{ Count, Average, Max }` records.

```lua
local metrics = Scribe.GetMetrics()
print(`sessions {metrics.ActiveSessions}, saves ok {metrics.SavesOk}, failed {metrics.SavesFailed}`)
```

A key exists only once something has emitted it, so treat a missing key as zero rather than as an error.

These are the ones worth putting on a panel first.

| Key | Kind | Meaning |
| --- | --- | --- |
| `ActiveSessions` | gauge | Emberfall profiles held on this server right now |
| `ProfilesLoaded`, `ProfileLoadFailures` | counter | Loads that succeeded, and loads that did not |
| `SavesOk`, `SavesFailed` | counter | Save outcomes, counted once per save |
| `SaveDuration` | distribution | Seconds per save |
| `ProfileSize` | distribution | Approximate bytes of the last saved payload, against the 4 MB ceiling |
| `HealthStatus` | gauge | `0` Healthy, `1` Degraded, `2` Outage |
| `DataStoreErrors` | counter | DataStore errors seen against this bundle's store, counted per attempt |
| `WipeGuardTrips`, `Anomalies` | counter | Integrity events, each of which also fires [`OnAnomaly`](/api/Server#OnAnomaly) |
| `SchemaNodes` | gauge | Compiled template size, a useful canary for template growth |

Per-player save state is separate. [`Data.GetSaveInfo(player)`](/api/Server#GetSaveInfo) returns `{ LastSaveAt, LastResult, Dirty, Size }` and is mirrored to that player, so a "Saved" or "Unsaved changes" indicator in the Emberfall UI reads [the client copy](/api/Client#GetSaveInfo) with no round trip.

### Percentiles, not averages

[`Scribe.GetPercentiles()`](/api/Scribe#GetPercentiles) returns `{ P50, P90, P99 }` for every distribution, over a rolling window of the most recent 256 samples.

```lua
local saveDuration = Scribe.GetPercentiles().SaveDuration
if saveDuration and saveDuration.P99 > 2 then
    warn(`slowest Emberfall saves are taking {saveDuration.P99}s`)
end
```

An average over a few thousand fast saves will not move when one key goes slow, and the slow key is the one a player is waiting on. A name that has never been observed is absent from the result rather than present with zeroes, so `next()` on the result tells you whether anything has been measured at all.

The window is why `Count` in `GetMetrics` and the percentiles disagree. `Count` is all-time. The percentiles describe recent behaviour, on purpose.

## What a failing DataStore looks like

`DataStoreErrors` counts every failed attempt, and it is joined by one `DataStoreErrors_<Class>` counter per class: `Throttled`, `Failed`, `Unresolved` and `Rejected`. Those four are a reporting dimension. They tell **you** what to do, and with one exception they change nothing about what Scribe does.

| Class | Sent by Roblox as | What it means for you |
| --- | --- | --- |
| `Throttled` | `3xx` | The request was dropped because the throttle queue overflowed. Ask less often. |
| `Failed` | `502`, `503`, anything unrecognised | Transient service-side failure. A retry may work. |
| `Unresolved` | `504` | The call timed out and the write **may have landed**. This is the one class you cannot safely retry on the assumption it did not. |
| `Rejected` | `1xx`, oversize payloads, metadata caps | Permanently invalid. Every retry fails identically and something has to change. |

??? note "Why only Throttled changes Scribe's behaviour"
    `Throttled` collapses every throttled key into a single shared problem, so a join rush cannot walk a server to `Outage` on what is really one condition.

    `Failed`, `Unresolved` and `Rejected` are counted and logged and branch nowhere. Scribe treats them identically. It is your response that differs, which is the whole reason they are told apart in the first place. In particular Scribe does not retry `Failed` and skip `Rejected`, and ProfileStore's own retry policy knows nothing about the classification.

    Note also that `DataStoreErrors_Throttled` is not a general throttling signal. Ordinary budget exhaustion makes a request **wait** rather than fail, so a heavily throttled server can show zero here. Use [`Scribe.GetBudgetSnapshot()`](/api/Scribe#GetBudgetSnapshot) for that.

??? note "Why HealthFailures climbs while the status holds steady"
    `HealthFailures` counts every error, retries included, plus one `HealthFailures_<Subsystem>` counter per subsystem such as `ProfileStore`, `ProfileLoad` or `Leaderboards`.

    The health state machine counts distinct **problems** instead. One stuck profile retried hard is one problem however many errors it produces, and a throttle is one problem no matter how many keys it hits. Being throttled is the DataStore asking to be asked less often, which is what a crowd of players joining at once produces, not a store that cannot write. Sustained throttling still reaches `Degraded` on its own. Reaching `Outage` takes writes that genuinely failed.

    `FailuresCollapsed` counts the log lines suppressed because they repeated a problem already reported for the same subject inside the retry window. The failure itself is still counted. The entry that ends a fold carries `Context.Repeats`. A large `FailuresCollapsed` against a small `HealthFailures_<Subsystem>` is the shape of one stuck key being retried hard.

??? note "Two counters that look like failures and are not"
    `SaveWaitTimeouts` counts callers that gave up waiting for a save to confirm. That is **unresolved, not failed**. The save is often still in flight, so the same save may increment `SavesOk` shortly after the caller was told `false`. It is never counted in `SavesFailed`.

    `FlushesAlreadyDurable` counts [`Data.Flush`](/api/Server#Flush) calls answered with no DataStore request at all, because the profile was already on disk. A non-zero value is normal and good. It never counts a flush after a grant, which leaves the profile dirty by definition.

## Replication counters

These describe what Scribe is putting on the wire. Reach for them when the Emberfall join is slow, or when a template has grown and you want to see the cost.

??? note "Throughput and bandwidth keys"
    | Key | Kind | Meaning |
    | --- | --- | --- |
    | `Handshakes`, `DiffFlushes` | counter | Completed handshakes, and flushes of a player's diff queue |
    | `OpsQueued`, `OpsCoalesced`, `OpsSent` | counter | Ops entering the queue, folded together, and actually sent |
    | `FramesSent` | counter | Frames handed to the transport, counted per **delivery**, so a broadcast to 40 clients counts 40 |
    | `BytesOutPerSend` | distribution | Bytes per outbound **frame**, sampled once per frame produced rather than once per recipient |
    | `JoinBytes` | distribution | Bytes delivered to one client to complete one handshake |
    | `FlushEntriesPerFrame`, `FlushQueuedPerFrame` | distribution | Players flushed in one `PostSimulation` pass, and ops queued across them |

    `FramesSent` is what makes a `Shared` fanout visible: it grows with the square of the player count while `DiffFlushes` grows linearly. A transport that implements `SendToAllClients` counts one per broadcast, since Scribe hands over a single buffer and never learns the recipient count.

    The two `Flush*PerFrame` distributions are a cost measurement, not a backlog, because every entry with queued work flushes every frame. If `Max` ever approaches a meaningful share of your frame budget, that is the evidence for pacing the loop.

    **`JoinBytes` and `ProfileSize` disagree on purpose.** `ProfileSize` measures what is **stored**. `JoinBytes` measures what is **sent to one client at handshake**, which is the owner `Init` plus every `SharedInit` in the same call.

    A [`Scribe.Session`](./visibility) root is in `JoinBytes` and absent from `ProfileSize`, so the two can differ by orders of magnitude and that is correct. On a template with `Shared` fields the fanout is the larger part, and it grows with population.

    `JoinBytes` is a per-handshake sum, so it is not comparable with `BytesOutPerSend`, which samples per frame. It is sampled once per completed handshake, re-`Init`s included, so its `Count` equals `Handshakes` and neither separates joins from resyncs. Read `Max`. A snapshot that never reached the transport is not sampled at all, and `InitSendFailed` counts those.

??? note "Fragmentation, refusals and resyncs"
    | Key | Kind | Meaning |
    | --- | --- | --- |
    | `FramesFragmented`, `FragmentsSent` | counter | Logical frames that exceeded `MaxOutboundBytes` and had to be split, and the wire frames that split produced |
    | `FramesReassembled`, `FragmentsRefused` | counter | Client side: frames rebuilt from fragments, and fragments discarded unused |
    | `InitSendFailed`, `FragmentedSendFailed` | counter | A snapshot that never reached the transport, and a frame whose fragments only partly landed |
    | `MirrorResyncs` | counter | Clients whose mirror was rebuilt because a frame addressed to them did not reach the transport |
    | `MalformedFrames`, `InboundOversize`, `InboundRateLimited`, `InboundWorkLimited` | counter | Rejected inbound frames, see the [Transport codes](./log-codes) |
    | `ProtocolMismatch`, `SchemaMismatch`, `ReInitThrottled` | counter | Handshakes refused |

    Both fragmentation counters staying at zero means every frame your game emits already fits, which is the ordinary case. A rising `FramesFragmented` says some profile or diff has grown past the budget.

    A non-zero `FragmentsRefused` on a reliable ordered transport is a bug and not a network condition, because the transport contract forbids the loss and reordering that would otherwise explain it.

    `InitSendFailed` is the one that matters operationally: that client is left unloaded and will keep asking, which is why it is paired with the `INIT_UNDELIVERED` warning rather than retried silently forever. `MirrorResyncs` is the only signal that a mirror ever went stale, because a loaded client cannot ask for a resync itself.

    `InboundWorkLimited` counts frames refused for how much they would **allocate**, not for how large they are.

## Subsystem counters

??? note "Commands, monetization, leaderboards and analytics"
    | Key | Meaning |
    | --- | --- |
    | `CommandsReceived`, `CommandsHandled`, `CommandsRejected`, `CommandsRateLimited`, `CommandErrors` | Command dispatch outcomes, see [Commands & Requests](./commands) |
    | `CommandsDeduped` | Requests to an `Idempotent` command answered from the cache instead of running the handler |
    | `CommandIdemEvicted` | Unexpired idempotency records dropped to stay under the 64-per-player cap. A retry under one of those keys would run the handler again |
    | `ReceiptsReceived`, `ReceiptsGranted`, `ReceiptsRetried`, `ReceiptsDeclined`, `ReceiptsDuplicate` | Receipt outcomes for `CoinPack500` and `GemPack100` |
    | `ReceiptsPartial` | Receipts settled after a **yielding** `Grant` threw part way. The player may have received less than they paid for |
    | `PurchaseIdsEvicted`, `PurchaseClaimsEvicted` | Dedupe entries dropped by their count backstops. A retry under an evicted key would apply its purchase again |
    | `GiftPrompts`, `GiftsDelivered`, `OwnershipCheckFailures` | Gifting and pass ownership |
    | `PaidRandomRefused` | Prompts, soft-currency purchases and gift prompts refused on the paid random policy, restricted and pending alike |
    | `MessageQueueFull` | Sends refused because the recipient's message queue is at its 1,000-entry cap. Nothing already queued is lost, because the send is refused rather than evicting anything |
    | `MessageQueueFullAmbiguous` | The subset of those refusals where an earlier attempt inside the same call may already have queued the message. Non-zero means a refused send can still arrive, so a duplicate delivery is reconcilable rather than mysterious. Pair it with `Context.ProvablyClean` on the `MESSAGE_QUEUE_FULL` lines |
    | `GiftCreditsUnconfirmed` | Gift credits kept spent because the delivery write may have committed with its answer lost. Refunding one would let a single payment grant twice, so the credit is held and `GIFT_CREDIT_UNCONFIRMED` names it for manual reconciliation |
    | `LbWrites`, `LbWriteFailures`, `LbReadFailures`, `LbQueueOverflow`, `LbScoreOutOfRange`, `LbQueueDepth` | `TopLevel` board traffic |
    | `LbBudgetDeferred` | Board requests postponed because the DataStore budget was low. Only ever non-zero with `BudgetPolicy = "Defer"`, and nothing is dropped |
    | `EconomyEvents`, `EconomyEventFailures` | Analytics events emitted, and analytics events dropped |
    | `LegacyImports`, `LegacyImportFailures` | `ImportLegacyData` outcomes |
    | `MigrationsFailed` | Migration steps that threw or produced unpersistable data |
    | `BudgetWaiters` | Migration hooks currently parked on `AwaitBudget`, across every request type. A gauge, so it reads the moment rather than a total |
    | `BudgetQueued`, `BudgetGranted`, `BudgetTimedOut` | `AwaitBudget` outcomes. `Granted` includes grants that never queued, so `Queued` over `Granted` is the share of hooks that had to wait |
    | `BudgetWaitSeconds` | How long queued grants waited. Only queued ones, so an instant grant does not drag the distribution to zero. `Scribe.GetPercentiles()` carries its P50/P90/P99 |
    | `LeavingHooksSkipped`, `LeavingHooksTimedOut` | Exit hooks the shutdown drain could not afford. Both are zero on a server whose hooks return promptly |
    | `SnapshotRootDropped` | A top-level root that could not be serialized into a client's initial snapshot |

    `ReceiptsPartial` deserves a note. Its writes are already in the profile and cannot be rolled back, so the receipt is settled as delivered rather than retried, because retrying would re-apply them on every attempt. A non-zero value means a product's `Grant` both yields and can throw. Pair it with the `GRANT_PARTIAL` reports to find which one, and move the async work out of `Grant`.

    `LeavingHooksSkipped` counts hooks that never started because the hook phase's share of the shutdown budget was already spent. `LeavingHooksTimedOut` counts hooks still running when it expired, whose profiles were saved without their remaining writes. A non-zero count of either means shutdown is losing exit writes.

The counters are a library-level singleton per context. The server bundle owns everything above. `Scribe.GetMetrics()` on the client reports one key, `DiffsApplied`, the number of diff frames the client mirror has applied.

## Version and bundle skew

The server and the client compile their schemas from the **same shared module**, so a stale copy on one side is a real failure mode. Log the version once on each side at startup.

```lua
print("Scribe", Scribe.Version)  -- run this from a server script and from a LocalScript
```

Skew shows up at the handshake and never as a wrong value. The server refuses to replicate to a mismatched client and logs one warning:

- `PROTOCOL_MISMATCH` means the wire layout differs, so two different Scribe versions are running.
- `SCHEMA_MISMATCH` means the wire version matches but the templates diverged, so the client derived a different schema hash.

Both fail closed. On that client `Data.WaitForData()` returns `false` after its timeout and every field stays at its template default. There is no client-side log for either, so the server log ring is where you look. Only a custom cross-place transport can produce this on vanilla Roblox, since a normal place ships one copy of the shared module to both sides.

## Integrity guards

Every save is compared against the last good one. If top-level keys vanish or the payload collapses in size, `WIPE_GUARD_TRIPPED` fires and so does [`OnAnomaly`](/api/Server#OnAnomaly).

- `WipeGuardPolicy = "Warn"` is the default. The trip is logged and the save goes through, because a reset is sometimes legitimate.
- `WipeGuardPolicy = "Block"` persists the last good snapshot instead, until you push the live data through with `Data.Flush(player, { Force = true })`.

Scribe also warns with `PROFILE_SIZE` as a profile approaches the 4 MB DataStore value ceiling, so runaway Emberfall inventory growth shows up before saves start failing. The measurement is deliberately an upper bound on the stored encoding, so it reads slightly high rather than low and a profile is never nearer the ceiling than the number says.

## Seeing it live

Everything on this page, meaning the log ring, the health machine, the metrics and the per-flush bandwidth, is rendered as an interactive dock by the [Scribe Studio](./studio-plugin). It also lets you simulate outages and profile traffic without waiting for one to happen.

## Where to next

- [Log Code Reference](./log-codes) lists every code, its severity and what to do about it.
- [Scribe Studio](./studio-plugin) turns this page into a live dock you can watch while you play-test.
- [Configuration](./configuration) covers `LogRingSize`, `LogLevel`, `WipeGuardPolicy` and `BudgetPolicy`.
- [Session Lifecycle](./lifecycle) explains saves, exit hooks and the shutdown drain that several counters here measure.
- [Testing & Edit Mode](./testing) shows how to exercise these paths without touching live data.
