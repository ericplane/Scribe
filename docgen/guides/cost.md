# What Scribe Costs

Scribe holds all of your player data, so when a server gets slow or a join feels long it is the first thing you will suspect. This page is how you check rather than guess.

Everything here is already running. There is no flag to enable and no overhead to opt into.

## The four numbers worth watching

```lua
local m = Scribe.GetMetrics()
local p = Scribe.GetPercentiles()
```

| Question | Read | What good looks like |
| --- | --- | --- |
| How long did my player wait to load? | `p.LoadDuration` | A p99 under a couple of seconds. It is measured from the **join**, so it includes the queue, retries and any migration. |
| How long do saves take? | `p.SaveDuration` | Elapsed time from the moment a save is queued to its return: the serialization, any wait behind the request budget, and the DataStore round trip. It is wall-clock time a save spent, not frame time; the serialization is the only part that runs on a frame, and the rest is waiting. Read a rising p99 next to `GetBudgetSnapshot` before deciding where it came from. |
| How much frame time is replication costing? | `p.FlushDuration` | Seconds per frame that Scribe spent flushing. Nothing is recorded on idle frames, so this describes busy frames only. |
| How big are my profiles? | `p.ProfileSize` | An estimate of the data payload's size in its stored encoding, sized to read high per value rather than low. The record around it, the store's own metadata and any queued messages, is not in it, so the whole key can be larger than the number. Scribe warns on its own at 3.5 MB against the 4 MB per-key ceiling. |
| How much am I sending? | `m.BytesOut` | Bytes the transport accepted, fragment headers included, summed over every recipient: a unicast once, a broadcast once per session. Roblox's own network overhead is not in it, and a client kept connected past its session's end receives broadcasts it does not count. Sample it twice and divide by the seconds between for a rate. |
| Sending what? | `m.BytesOutDiff`, `m.BytesOutInit`, `m.BytesOutSharedDiff`, ... | The same bytes split by frame kind, one counter per kind the wire has: `Init`, `Diff`, `SharedInit`, `SharedDiff`, `SharedGone`, `CommandReply`, `Leaderboard`, `Status`. `m.BytesOutResync` is the snapshot frames, as the transport accepted them, sent to a client that already had one, so it overlaps the others; a first join retried after a refused send is not a repair. |

The durations and sizes are distributions with `P50`, `P90` and `P99`; the byte counts are counters. **Read the p99, not the average.** One slow join is weather; a moved p99 is a problem, and a mean hides both.

Every distribution also reports `Samples`, `Age` and `Window`: how many samples the percentiles were taken over (at most 256), how many seconds since the newest, and how many seconds the ring spans from its oldest sample to its newest. A p99 with a `Window` of four seconds describes one burst; the same number with a `Window` of four hours describes the afternoon. A dashboard that shows the percentile without the window is showing a number it cannot vouch for.

## Is it healthy right now

```lua
if Scribe.GetStatus() ~= "Healthy" then ... end
```

`GetStatus` sits on a hysteresis machine that deliberately collapses a throttle burst into one subject and a retried key onto a cooldown, so a join rush cannot walk a server to `Outage` while nothing is actually wrong. Pair it with `Scribe.GetBudgetSnapshot()` when you want to know whether you are near a DataStore request limit rather than in a failure.

## Two logs that page you rather than waiting to be read

| Code | Level | Fires when |
| --- | --- | --- |
| `SLOW_LOAD` | Warn | A profile took longer than ten seconds to load. |
| `PROFILE_SIZE` | Warn | A profile passed 3.5 MB and is approaching the per-key ceiling. |

`SLOW_LOAD` names the player, so it is directly actionable. `LoadDuration` tells you whether it was one player or a trend.

## In the MicroProfiler

One label, `Scribe.Flush`: a single frame of replication across every player.

**Only one, and for a reason worth knowing.** A MicroProfiler annotation belongs to a thread's current synchronous slice. Yield inside one and the annotation is gone, so closing it reports `No active profile annotation` and the engine logs an error for every call. The load waits on a DataStore and a migration is a function you wrote that may wait on anything, so neither can be a span at all.

That is not a gap. Anything that yields is measured with a metric instead, and `LoadDuration` answers the question a span could not: a load spends almost all of its time waiting, which costs you no frame time.

So the rule for reading this: **`Scribe.Flush` is the replication flush**, the per-frame work Scribe does on its own thread. It is not all of Scribe's frame time. A write you make, the `Changed` and `Observe` listeners it fires, a derived recompute and the serialization of a save all run on the thread that called them, so they show under your own labels, and `FlushDuration` is the metric form of the same span.

## In the memory view

Scribe's long-lived threads are tagged `Scribe`, so their allocations are attributable in the Developer Console.

!!! warning "What the tag does not cover"
    Roblox attributes an allocation to the thread that is **running**. Scribe's own background work (the loader, the autosave, the leaderboard pacer, the timed sweep) is tagged. The pacer and the sweeps park while they have nothing to do, so an idle server pays for none of them. A write you make from your own code runs on **your** thread and stays under your own category, even though it allocates inside Scribe. So the tag shows you what Scribe does on its own, not the total cost of the data layer.

The other memory question, how big a profile is, is answered by `ProfileSize` above, an estimate from a recursive walk of the data payload, excluding the record around it.

## Per command

Every registered command has three metrics of its own, named after it: `CommandDuration:<name>`, a distribution of elapsed seconds per call including whatever the handler awaited, the same boundary as the client timers; `CommandActive:<name>`, a gauge of the calls open right now; and `CommandErrors:<name>`, a counter of handlers that threw. Names are bounded by what you registered, since an unregistered name is refused before dispatch, so the set cannot grow under a client's control. On the client, `RequestTimeouts:<name>` counts requests to that command that ran out their `RequestTimeout`, and `RequestTimeouts` sums them; the server cannot know a client gave up, so this is the one place the number exists. Request names are the client's to choose, so the named series are capped at 32; a timeout under any later name counts as `RequestTimeouts:Other`.

## On the client

The same two calls from a `LocalScript` return the client's own numbers, and the client has three timers of its own. Each is seconds of elapsed time per frame received, from the first byte decoded to the end of the dispatch, and where a listener sits decides what it includes. `Changed` and `Observe` handlers run inline, so `InitApplyDuration` and `DiffApplyDuration` count them in full, waits included: one that yields holds the frame. `OnSharedChanged` handlers run on their own threads, so `SharedApplyDuration` counts one up to its first yield and nothing after it. None of them is CPU time or a total per rendered frame.

| Read | Measures |
| --- | --- |
| `p.InitApplyDuration` | Applying the join snapshot, one sample per handshake |
| `p.DiffApplyDuration` | Decoding and applying one diff to the mirror |
| `p.SharedApplyDuration` | Applying one other player's Shared update, including the derived recompute and the clone `OnSharedChanged` receives |

Idle frames record nothing, as on the server. A p99 that climbs with player count suggests a Shared root that is too large or too busy; one that climbs with time suggests a listener of yours. Either is a place to look, not a verdict.

## In Studio

The [Scribe Studio plugin](./studio-plugin) streams the whole metric set once a second into a twenty-minute ring, which is the fastest way to see a shape rather than a snapshot. It is Studio-only, so it answers "is this getting worse as I play" and not "what is my live server doing".

## What is deliberately not measured

- **Per-accessor read and write timings.** The instrumentation would cost more than the operation.
- **Total memory held by Scribe.** No API reports it, and the per-thread tag above is the honest partial answer.
- **Client memory.** The client has the timers above and no memory category; the Developer Console's client view is the honest answer.

If you need one of these, say so on the repo rather than working around it: each is a deliberate omission with a reason, and reasons can change.
