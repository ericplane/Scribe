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
| How long do saves take? | `p.SaveDuration` | This is a DataStore round trip, so it is network time, not your frame budget. A rising p99 means the backend, not your code. |
| How much frame time is replication costing? | `p.FlushDuration` | Seconds per frame that Scribe spent flushing. Nothing is recorded on idle frames, so this describes busy frames only. |
| How big are my profiles? | `p.ProfileSize` | Bytes, against a 4 MB per-key ceiling. Scribe warns on its own at 3.5 MB. |

Every one is a distribution with `P50`, `P90` and `P99`. **Read the p99, not the average.** One slow join is weather; a moved p99 is a problem, and a mean hides both.

## Is it healthy right now

```lua
if Scribe.GetStatus().Status ~= "Healthy" then ... end
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

So the rule for reading this: **`Scribe.Flush` is Scribe's frame cost.** If you are hunting a frame-rate problem, that label is the whole of Scribe's contribution to it.

## In the memory view

Scribe's long-lived threads are tagged `Scribe`, so their allocations are attributable in the Developer Console.

!!! warning "What the tag does not cover"
    Roblox attributes an allocation to the thread that is **running**. Scribe's own background work (the loader, the autosave, the leaderboard pacer, the timed sweep) is tagged. A write you make from your own code runs on **your** thread and stays under your own category, even though it allocates inside Scribe. So the tag shows you what Scribe does on its own, not the total cost of the data layer.

The other memory question, how big a profile is, is answered by `ProfileSize` above, which is a real recursive byte walk rather than an estimate.

## In Studio

The [Scribe Studio plugin](./studio-plugin) streams the whole metric set once a second into a twenty-minute ring, which is the fastest way to see a shape rather than a snapshot. It is Studio-only, so it answers "is this getting worse as I play" and not "what is my live server doing".

## What is deliberately not measured

- **Per-accessor read and write timings.** The instrumentation would cost more than the operation.
- **Total memory held by Scribe.** No API reports it, and the per-thread tag above is the honest partial answer.
- **Anything on the client.** The client mirror has its own counters in `GetMetrics`, but no timers.

If you need one of these, say so on the repo rather than working around it: each is a deliberate omission with a reason, and reasons can change.
