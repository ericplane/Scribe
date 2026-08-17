# Derived Fields

A **derived field** is computed from other declared fields instead of accepting writes. Scribe recomputes it whenever an input changes, never persists it, and replicates it only when the receiving realm cannot compute it for itself.

```lua
local template = {
    Team  = Scribe.Enum("Civilian", { "Civilian", "Police", "EMS" }),
    Stats = {
        PoliceXP = Scribe.Int(0, { Min = 0 }),
        EMSXP    = Scribe.Int(0, { Min = 0 }),
    },

    Rank = Scribe.Derived(
        Scribe.Enum("Recruit", { "Recruit", "Officer", "Sergeant", "Paramedic" }),
        { "Team", "Stats.PoliceXP", "Stats.EMSXP" },
        function(team, policeXp, emsXp)
            if team == "Police" then return policeRank(policeXp) end
            if team == "EMS" then return emsRank(emsXp) end
            return "Recruit"
        end
    ),
}
```

```lua
data.Stats.PoliceXP.Increment(50)
data.Rank.Get()      --> recomputed already
data.Rank.Observe(function(rank) label.Text = rank end)
data.Rank.Set("Sergeant")  --> error: it is computed from Team, Stats.PoliceXP, Stats.EMSXP
```

The point is that the rank has **one** source of truth. Change the XP curve and every player's rank is correct on the next read — no migration, no backfill, nothing stale in storage. Contrast the hand-rolled version (seed it in `OnPlayerInit`, recompute it in a `Changed` listener, write it with `Set`), which stores a second copy that goes stale the moment the formula changes, fires once per write inside a batch, and restores as its own independent value when a [transaction](./lifecycle) rolls back.

## Declaring one

[`Scribe.Derived(output, inputs, compute)`](/api/Scribe#Derived) takes three arguments:

- **`output`** — an ordinary declarator supplying the type and bounds: `Scribe.Int`, `Scribe.Number`, `Scribe.String`, `Scribe.Enum`, or a plain boolean. The field validates and clamps exactly like a normal one.
- **`inputs`** — dotted paths to **statically declared** fields, in the same syntax a [leaderboard](./leaderboards) `Stat` uses. They arrive as `compute`'s arguments, in order.
- **`compute`** — a pure function of those inputs.

Inputs may be nested (`"Stats.PoliceXP"`), and they must exist in the template: a path that does not resolve to a declared field is a startup error, not a `nil` at runtime.

| Input may be | Not an input |
| --- | --- |
| `Scribe.Int`, `Scribe.Number`, `Scribe.String`, `Scribe.Enum`, a boolean | a record or a container |
| `Scribe.Big` (arrives as the Big object) | [`Scribe.Flags`](./templates#sets-of-named-booleans) — its read shape is a mutable list |
| a datatype field (`Scribe.Vector3`, …) | a `buffer` |
| `Scribe.Optional(...)` — the argument may be `nil` | [`Scribe.Timed`](./templates#timed-fields) — see below |
| another derived field | a container entry, or any runtime key |
| | `_Scribe` / `_ScribeSession` internals |

A `Scribe.Timed` input is refused because a timed field lapses on the wall clock rather than on a write: an expired-but-uncleared timer reads one way online and another in a stored profile, so the same data would derive two different values. Store an expiry field and derive from that instead.

### Chaining

A derived field may read another one. Scribe orders the graph at compile time and rejects cycles:

```lua
Rank     = Scribe.Derived(Scribe.Enum("Recruit", RANKS), { "Team", "PoliceXP" }, rankFor),
RankIcon = Scribe.Derived(Scribe.String(""), { "Rank" }, iconFor),   -- settles after Rank
```

### Purity

`compute` must be pure, must not yield, and must not write. Scribe calls it once per realm at startup to seed the field's default, so a function that throws or returns the wrong type fails the template rather than the first write. At runtime a throwing function is contained: the field keeps its previous value, [`DERIVED_ERROR`](./log-codes#derived) is logged once per field, and the write that triggered it still succeeds.

`os.time()`, `math.random`, and anything else that differs per call or per realm are what "pure" excludes. In Studio, Scribe cross-checks: the server sends its own value for fields the client computes locally, and a disagreement logs [`DERIVED_MISMATCH`](./log-codes#derived). That check costs nothing in production, where the value is not sent at all.

## Where a derived field lives

A derived field never persists, so it must be a **root** field, or live inside a [`Scribe.Session`](./visibility) root:

```lua
Rank    = Scribe.Derived(...),                                  -- ✅ root
Runtime = Scribe.Session({ Rank = Scribe.Derived(...) }),        -- ✅ inside a Session root
Stats   = { Rank = Scribe.Derived(...) },                        -- ❌ startup error: Stats persists
```

Scribe stores data per root, so a computed value under a persisted root would be written into the profile and saved — the one thing it must never be. Wrapping it in `Scribe.Session` yourself is redundant and refused; so are `Scribe.Timed`, `Scribe.Dynamic`, and `Scribe.Optional`, none of which mean anything for a value nothing writes.

## Who computes, and what crosses the wire

Your template module is required by **both** realms, so the compute function exists on the client too. When the client can already see every input, sending the result would be wasted bandwidth — it recomputes locally instead, and there is no second copy to drift.

Scribe decides this per field, at compile time, from the visibility you declared:

> The server always computes every derived field. It **sends** one only when some member of the output's audience cannot see all of its inputs.

| Output | Inputs | Result |
| --- | --- | --- |
| *(default)* owner-visible | all owner-visible or `Shared` | computed on both realms, **0 bytes** |
| `Scribe.Shared` | all `Shared` | computed by every client, **0 bytes** |
| *(default)* owner-visible | any `ServerOnly` | the server computes and replicates it |
| `Scribe.Shared` | any owner-only input | the server computes and replicates it |
| `Scribe.ServerOnly` | anything | never leaves the server |

```lua
Suspicion   = Scribe.ServerOnly(Scribe.Int(0, { Min = 0, Max = 100 })),
-- The client cannot see Suspicion, so the server sends this one:
Watchlisted = Scribe.Derived(false, { "Suspicion" }, function(s) return s >= 80 end),
```

That last pattern is a deliberate **projection** of server-only data: the client learns something about a value it can never read. That is often exactly what you want (a rank from secret XP), but it is worth being deliberate about how much the projection reveals — see [Security](./security#derived-projections).

One visible consequence of local computation: a derived field tracks the client's own optimistic writes. Client writes are local-only, so a client-side `PoliceXP.Set(...)` updates the local rank immediately; a transmitted field updates when the server's op lands instead.

## When it recomputes

A recompute is an ordinary write, so everything you already know applies: it validates against the output declarator, an unchanged result fires nothing and sends nothing, and `Changed` / `Observe` behave as usual.

| You do | It recomputes |
| --- | --- |
| a plain `Set` on an input | immediately |
| [`Data.Batch`](/api/Server#Batch) of N input writes | **once**, at the end of the batch |
| [`Data.Transaction`](/api/Server#Transaction) | once, inside the transaction — it commits or rolls back with its inputs |
| a client receiving a diff frame | once per frame |
| profile load | once, before the session is `Ready` |
| [`Data.Mock`](/api/Client#Mock) in a storybook | once, after the seed |

Reads settle first, so a derived field can never hand back a value its inputs have moved past — including mid-batch:

```lua
Data.Batch(player, function()
    data.Team.Set("Police")
    data.Stats.PoliceXP.Set(150)
    print(data.Rank.Get())  --> "Sergeant", not the pre-batch value
end)
```

Reading a derived field mid-batch is the one case that fires its `Changed` before the batch ends, because the recompute has to happen then. That matches how any leaf write inside a batch already behaves; only *container* fires coalesce to the end.

## Offline reads

Derived values are computed, so a stored profile does not contain them. [`Data.GetOffline`](/api/Server#GetOffline) and [`Data.Export`](/api/Server#Export) fill them in over the snapshot they return, for every root-level field whose inputs are all stored (a chain of derived fields counts, since each is filled before the next reads it).

A field reading a `Scribe.Session` input is **omitted** from an offline read rather than filled from a default: session state does not exist in a stored profile, and inventing one would be worse than its absence.

[`Data.UpdateOffline`](/api/Server#UpdateOffline) does not expose derived fields at all. Its table is written back to the DataStore, and a computed value landing in storage is the thing this feature exists to prevent.

## Storybooks

A derived field needs no special handling in [edit mode](./testing#edit-mode-storybooks). Seed the inputs and the value follows:

```lua
Data.Mock({ Team = "Police", Stats = { PoliceXP = 12000 } })
Data.Rank.Get()  --> "Sergeant"
```

Seeding the derived field itself is a write, so it errors like any other write would.

## Diagnostics

[`Scribe.GetMetrics()`](/api/Scribe#GetMetrics) counts `DerivedRecomputes`, `DerivedErrors`, and `DerivedOpsSuppressed` — recomputes that updated a field without costing a byte, which is the transmit rule paying for itself. The three [log codes](./log-codes#derived) are `DERIVED_ERROR`, `DERIVED_FEEDBACK` (a `Changed` listener that keeps writing an input from inside the recompute it triggered), and `DERIVED_MISMATCH`.

## Adopting one

Converting a field you already store into a derived one leaves the old key behind in every existing profile. Delete it in a [migration](./migrating), or it lingers forever and shows up in the unknown-root-key warning:

```lua
Migrations = {
    [2] = function(data)
        data.Rank = nil -- now derived from Team + PoliceXP
    end,
},
```
