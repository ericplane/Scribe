# Derived Fields

Some values are not really data. A player's level is just their XP put through a formula, and storing it means storing the same fact twice. A derived field lets you declare the formula once and read the answer like any other field, without ever writing it.

Reach for one whenever you catch yourself recomputing a value in a `Changed` listener and writing the result back.

## Level from Xp

Emberfall's `Level` is computed from `Xp`. Here is the slice of the template that does it:

```lua
local function levelForXp(xp: number): number
    return math.min(100, math.floor(xp / 1000) + 1)
end

local template = {
    Xp    = Scribe.Int(0, { Min = 0 }),
    Level = Scribe.Derived(Scribe.Int(1, { Min = 1, Max = 100 }), { "Xp" }, levelForXp),
}
```

Now award XP and the level follows on its own:

```lua
local data = Data.WaitForData(player)

data.Xp.Increment(2500)
print(data.Level.Get())  --> 3

data.Level.Observe(function(level)
    print(`{player.Name} is level {level}`)
end)
```

`Level` has no `Set`, no `Update` and no `Increment`. Those methods are absent from its type, so a write is a red squiggle before it is ever a runtime error. There is one source of truth, and changing `levelForXp` fixes every player at once with no migration and no backfill.

## Declaring one

[`Scribe.Derived(output, inputs, compute)`](/api/Scribe#Derived) takes three arguments.

- **`output`** is an ordinary declarator that supplies the type and the bounds. `Scribe.Int`, `Scribe.Number`, `Scribe.String`, `Scribe.Enum`, or a plain boolean. The field validates and clamps exactly like a normal one, which is why `Level` can cap itself at 100.
- **`inputs`** are dotted paths to fields you declared statically, in the same syntax a [leaderboard](./leaderboards) `Stat` uses. They arrive as `compute`'s arguments, in order.
- **`compute`** is a pure function of those inputs.

Inputs may be nested, so `"Stats.Deaths"` is a valid path. A path that does not resolve to a declared field is a startup error rather than a `nil` at runtime.

| Allowed as an input | Not allowed |
| --- | --- |
| `Scribe.Int`, `Scribe.Number`, `Scribe.String`, `Scribe.Enum`, a boolean | a record or a container such as `Inventory` |
| `Scribe.Big`, which arrives as the big value object | [`Scribe.Flags`](./containers#named-booleans), whose read shape is a mutable list |
| a [datatype](./datatypes) field such as `Scribe.Vector3` | a `buffer` |
| `Scribe.Optional(...)`, where the argument may be `nil` | [`Scribe.Timed`](./time), including Emberfall's `LastDaily` |
| another derived field | a container entry, or any runtime key |
| | the reserved `_Scribe` and `_ScribeSession` roots |

??? note "Why a timed field cannot be an input"
    A [`Scribe.Timed`](./time) field lapses on the wall clock rather than on a write. An expired-but-uncleared timer therefore reads one way in a live session and another way in a stored profile, so the same bytes would derive two different values depending on when you looked. Store an expiry timestamp in a `Scribe.Int` and derive from that instead.

### Chaining

A derived field may read another one. Scribe orders the graph when the template compiles and rejects cycles:

```lua
Level = Scribe.Derived(Scribe.Int(1, { Min = 1, Max = 100 }), { "Xp" }, levelForXp),
Rank = Scribe.Derived(Scribe.String(""), { "Level" }, rankForLevel),  -- settles after Level
```

## Where a derived field lives

A derived field is never persisted, so it has to be a **root** field, or sit inside a [`Scribe.Session`](./visibility) root:

```lua
Level   = Scribe.Derived(...),                          -- correct: a root field
Runtime = Scribe.Session({ Level = Scribe.Derived(...) }),  -- correct: inside a Session root
Stats   = { Level = Scribe.Derived(...) },              -- startup error: Stats persists
```

Scribe saves data one root at a time, so a computed value under a persisted root would be written into the profile and saved, which is the one thing it must never be. Wrapping it in `Scribe.Session` yourself is redundant and refused, and so are `Scribe.Timed`, `Scribe.Dynamic` and `Scribe.Optional`, none of which mean anything for a value nothing writes.

## Who computes it, and what crosses the wire

Both realms require your shared module, so `levelForXp` exists on the client too. When the client can already see every input, sending the result would be wasted bandwidth. The client recomputes instead, and there is no second copy to drift.

Scribe decides this per field when the template compiles, from the visibility you declared. The server always computes every derived field. It **sends** one only when some member of the output's audience cannot see all of its inputs.

| Output | Inputs | Result |
| --- | --- | --- |
| default, owner-visible | all owner-visible or `Shared` | computed on both realms, **0 bytes** |
| `Scribe.Shared` | all `Shared` | computed by every client, **0 bytes** |
| default, owner-visible | any `ServerOnly` | the server computes and replicates it |
| `Scribe.Shared` | any owner-only input | the server computes and replicates it |
| `Scribe.ServerOnly` | anything | never leaves the server |

Emberfall's `Level` reads `Xp`, which the owner can see, so it costs nothing on the wire. A field reading something the client cannot see is different:

```lua
Suspicion = Scribe.ServerOnly(Scribe.Int(0, { Min = 0, Max = 100 })),

-- The client cannot see Suspicion, so the server computes this one and sends it.
Watchlisted = Scribe.Derived(false, { "Suspicion" }, function(s) return s >= 80 end),
```

That is a deliberate **projection**: the client learns something about a value it can never read. Often that is exactly what you want, but be deliberate about how much the projection gives away. [Security](./security) covers the reasoning.

??? tip "Client writes move a derived field immediately"
    Client writes are optimistic and local only, so a client-side `data.Xp.Set(9000)` recomputes the local `Level` on the spot. That is fine for responsive UI, and the server's value still wins on the next diff. A field the server transmits instead updates only when the server's op lands. See [Commands & Requests](./commands) for the authoritative path.

## When it recomputes

A recompute is an ordinary write, so everything you already know applies. It validates against the output declarator, an unchanged result fires nothing and sends nothing, and `Changed` and `Observe` behave as usual.

| You do | It recomputes |
| --- | --- |
| a plain `Set` or `Increment` on an input | immediately |
| a [`Data.Batch`](/api/Server#Batch) of several input writes | **once**, at the end of the batch |
| a [`Data.Transaction`](/api/Server#Transaction) | once, inside it, committing or rolling back with its inputs |
| a client receiving a diff frame | once per frame |
| a profile load | once, before the session is Ready |
| [`Data.Mock`](/api/Client#Mock) in a storybook | once, after the seed |

Reads settle first, so a derived field can never hand you a value its inputs have already moved past. That holds mid-batch too:

```lua
Data.Batch(player, function()
    data.Xp.Set(4200)
    data.Stats.Deaths.Increment(1)
    print(data.Level.Get())  --> 5, not the pre-batch level
end)
```

Reading a derived field mid-batch is the one case that fires its `Changed` before the batch ends, because the recompute has to happen at that moment. That matches how any leaf write inside a batch already behaves. Only *container* fires coalesce to the end.

??? note "What `compute` must not do"
    `compute` must be pure. It must not yield, and it must not write. Scribe calls it once per realm at startup to seed the field's default, so a function that throws or returns the wrong type fails the template rather than the first write.

    At runtime a throwing function is contained. The field keeps its previous value, [`DERIVED_ERROR`](./log-codes) is logged once for that field, and the write that triggered the recompute still succeeds.

    `os.time()`, `math.random`, and anything else that differs per call or per realm are what "pure" excludes. In Studio, Scribe cross-checks: the server sends its own value for fields the client computes locally, and a disagreement logs `DERIVED_MISMATCH`. That check costs nothing in production, where the value is not sent at all.

??? note "Reading a derived field on an offline profile"
    Derived values are computed, so a stored profile does not contain them. [`Data.GetOffline`](/api/Server#GetOffline) and [`Data.Export`](/api/Server#Export) fill them in over the snapshot they return, for every root-level field whose inputs are all stored. A chain counts, since each link is filled before the next one reads it. Emberfall's `Level` is filled in because `Xp` persists.

    A field reading a [`Scribe.Session`](./visibility) input is **omitted** from an offline read rather than filled from a default. Session state does not exist in a stored profile, and inventing one would be worse than its absence.

    [`Data.UpdateOffline`](/api/Server#UpdateOffline) does not expose derived fields at all. Its table is written straight back to the DataStore, and a computed value landing in storage is the thing this feature exists to prevent. See [Offline Profiles](./profiles).

??? note "Ranking a derived field on a leaderboard"
    `Level` is a legal leaderboard `Stat`, which is why Emberfall's `TopLevel` board works:

    ```lua
    Leaderboards = {
        TopLevel = { Stat = "Level", Limit = 100, Replicate = true },
    },
    ```

    A derived stat is accepted when every one of its inputs persists, because the board has to be able to rank a player who is not online. `Xp` persists, so `Level` qualifies. A derived field reading a `Scribe.Session` input does not, and is refused when the template compiles. See [Leaderboards](./leaderboards).

??? note "Seeding one in a storybook"
    A derived field needs no special handling in [edit mode](./testing). Seed the inputs and the value follows:

    ```lua
    Data.Mock({ Xp = 12000, Coins = 500 })
    Data.Level.Get()  --> 13
    ```

    Seeding the derived field itself is a write, so it fails exactly as a write would.

??? note "Converting a stored field into a derived one"
    If Emberfall shipped with `Level` as a stored `Scribe.Int` and you are converting it now, the old key stays behind in every existing profile. Delete it in a [migration](./profiles#migrations), or it lingers forever and turns up in the unknown-root-key warning:

    ```lua
    Migrations = {
        [2] = function(data)
            data.Level = nil -- now derived from Xp
        end,
    },
    ```

## What the counters say

[`Scribe.GetMetrics()`](/api/Scribe#GetMetrics) counts `DerivedRecomputes`, `DerivedErrors`, and `DerivedOpsSuppressed`. That last one is recomputes that updated a field without costing a byte, which is the transmit rule paying for itself. The three [log codes](./log-codes) are `DERIVED_ERROR`, `DERIVED_FEEDBACK` (a `Changed` listener that keeps writing an input from inside the recompute it triggered), and `DERIVED_MISMATCH`.

## Where to next

- [Replication & Visibility](./visibility) sets who receives a derived field, and therefore whether it crosses the wire at all.
- [Declaring Your Template](./templates) covers the output declarators a derived field can use.
- [Leaderboards](./leaderboards) ranks `Level` without you storing it.
- [Offline Profiles](./profiles) explains what a derived field looks like in a stored profile.
- [Diagnostics](./diagnostics) is where the derived counters and log codes surface.
