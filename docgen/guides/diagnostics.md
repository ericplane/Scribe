---
sidebar_position: 8
---

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

[`Scribe.GetMetrics()`](/api/Scribe#GetMetrics) exposes counters (saves, loads, receipt outcomes, queue depths, …) for developer/admin panels and load tests. Per-player save state ([`GetSaveInfo`](/api/Server#GetSaveInfo)) replicates to the owner for "Saved ✓ / Saving… / Unsaved changes" UI.

## Wipe guard

Every save is compared against the last good one. If top-level keys vanish or the payload collapses in size, `WIPE_GUARD_TRIPPED` fires along with the [`OnAnomaly`](/api/Server#OnAnomaly) signal.

- `WipeGuardPolicy = "Warn"` (default): log it and let the save through, since resets are sometimes legitimate.
- `WipeGuardPolicy = "Block"`: persist the last good snapshot instead, until you push the live data through with `Data.Flush(player, { Force = true })`.

## Data size

Scribe warns with the log code `PROFILE_SIZE` as a profile approaches the ~4 MB DataStore value ceiling, so you catch runaway growth before saves start failing.

## Seeing it live

Everything on this page (the log ring, health machine, metrics, and per-flush bandwidth) is rendered as an interactive dock by the **[Scribe Studio companion plugin](./studio-plugin)**, which also lets you simulate outages and profile traffic in Studio.
