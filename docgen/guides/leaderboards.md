# Leaderboards

All-time global leaderboards on a paced, deduplicated OrderedDataStore write queue. The queue flushes on stat change, join, leave, and `BindToClose`.

```lua
Leaderboards = {
    TopCoins = { Stat = "Coins", Limit = 100 },                  -- server-only (default)
    TopWins  = { Stat = "Wins",  Limit = 50, Replicate = true }, -- streamed to clients
},
```

`Stat` is a path into your template (`"Coins"`, `"Stats.Kills"`), and it must land on a **number field or a [`Scribe.Big`](/api/Scribe#Big)**. Scribe keeps that field's board updated automatically. Boards are **server-only by default**. Read them on the server with [`GetLeaderboard`](/api/Server#GetLeaderboard) / [`GetMyRank`](/api/Server#GetMyRank) (e.g. to render a physical board). Set `Replicate = true` to also stream a board to clients, which read it with the matching [client APIs](/api/Client#GetLeaderboard). Note the two `GetMyRank` signatures differ: the server takes the player first, `GetMyRank(player, name)`, and the client takes only `GetMyRank(name)`.

A client can never trigger an OrderedDataStore request either way.

`Stat` is checked at startup for every shape that can never rank. These are all boot errors naming the board:

- a path descending **through** a leaf field, or naming a field a [closed element shape](./templates#typed-containers) does not declare
- a field that is not a number, a `Scribe.Int`, or a `Scribe.Big`: a string, boolean, enum, flags, or datatype leaf
- a whole container rather than a leaf, typed or untyped
- a [`Scribe.Session`](./visibility) field, which resets every session while the board's entries outlive it

One case is still **not** caught, because it cannot be: a typo on a dynamic path. Any unknown key on an open container is a legitimate dynamic path, so `"Chars.main.Xp"` on a `Scribe.DictOf` is valid and a player missing that key is simply not tracked. If a board stays permanently empty and the config passed startup, a mistyped dynamic segment is the thing to check.

```lua
-- server: render a physical board
for _, entry in Data.GetLeaderboard("TopCoins", 10) do
    print(entry.Rank, entry.Name, entry.Score) -- { Rank, UserId, Name, Score }
end
local myRank = Data.GetMyRank(player, "TopCoins") -- player first on the server

-- client: a replicated board
Data.OnLeaderboard:Connect(function(boardName, entries) ... end)
local rank = Data.GetMyRank("TopWins")
```

Every one of these reads a cache, never a live store, so a board is empty until its own first refresh lands. The refresh loop starts 5 seconds after server start and staggers each board's first read across its interval, so with several boards declared the last one can take close to a full `RefreshInterval` to fill.

:::note How ranks are computed
`GetMyRank` returns a player's position **within the board's top `Limit`**, or `nil` if they sit outside it: a global rank of 100,284 on a `Limit = 100` board is simply `nil`. Each refresh pulls the top `Limit` in one `GetSortedAsync` shared by every player, so the lookup is a cached O(1) read. `nil` also means **not yet computed**: per-player ranks are recalculated only during a board's refresh, so a player who joins just after one has no rank until the next, up to a full `RefreshInterval` later, even if they genuinely sit in the top `Limit`. OrderedDataStore has no exact-rank primitive, and resolving a deep rank would mean paging 100k+ entries per query, so Scribe does not do it. To show something for players off the board, track a separate stat such as a personal best.
:::

:::note Universe-global stores
Boards are OrderedDataStores named `LB_<board>`, independent of `ProfileStoreIndex` and `ResetData`. Bumping your profile store index does **not** reset leaderboards, and renaming a board effectively resets it. Set a per-board `StoreName` to namespace one (e.g. for a test/prod split) or to intentionally share it across places. A **`Scribe.Big` board is named `LB_<board>_big<SigFigs>`**, always, even at the default `SigFigs`. A big is packed exponent-major and a plain numeric stat is packed as itself, so they are two key layouts, and two layouts must never share a store. Without the suffix, retyping a stat from `Scribe.Int` to `Scribe.Big` (which needs no migration and emits no warning) would silently reinterpret every key already written: a legacy `9e11` decodes as `9`, so a brand-new account with 100 outranks it.
:::

## Fractional stats: `Scale`

An OrderedDataStore key is an integer, so a plain numeric stat is stored as `round(value * Scale)` and divided back out on read, meaning the `Score` you get is in the field's own units either way. `Scale` defaults to 1, which is what a whole-number stat wants. At that default a fractional value is just rounded, so 3.47 and 3.42 both rank as 3. Raise it when the fraction is what separates players:

```lua
Leaderboards = {
    TopPlaytime = { Stat = "HoursPlayed", Scale = 100 },  -- rank to two decimals
    TopAccuracy = { Stat = "Stats.HitRate", Scale = 1000 }, -- a 0-1 ratio, three decimals
}
```

`Scale` must be a finite number greater than 0, checked at startup. The scaled value still has to stay inside 2^53, so a large `Scale` on an already-large stat buys decimals at the cost of range (see the [range guard](#resolution-vs-range-sigfigs) below). `Scale` is refused on a [`Scribe.Big`](#ranking-a-scribebig) stat, where the exponent packing already maps the value into the key space.

## Typed configs

Annotate config locals with the exported generic types and `Stat` autocompletes to the template's numeric leaf paths, while a product `Grant` receives the fully typed accessor tree:

```lua
type T = typeof(template)

local boards: { [string]: Scribe.LeaderboardConfig<T> } = {
    TopCoins = { Stat = "Coins" },       -- ✓ checked against the template
    TopKills = { Stat = "Stats.Kills" }, -- ✓ nested paths too
}

return Scribe({ Template = template, Leaderboards = boards, --[[ ...required fields... ]] })
```

The annotation is what enables strict checking: inside a single `Scribe({ ... })` literal Luau widens the string before the template type is known, so the annotated-local pattern is how you get autocomplete for `Stat` and `Cost.Path`.

## Refresh cadence

Each board re-reads its OrderedDataStore every 60 seconds by default. Set `RefreshInterval` per board to go **slower**, which is what most games want: a top-100 all-time board rarely needs minute-freshness, and every refresh spends from a `GetSortedAsync` budget that scales with player count.

```lua
Leaderboards = {
    TopCoins = { Stat = "Coins" },                          -- default 60s
    AllTimeDonors = { Stat = "Robux", RefreshInterval = 600 }, -- once every 10 minutes
}
```

Values below 60 seconds are clamped up and reported as `LB_INTERVAL_CLAMPED`. Going faster is nearly always the wrong tool: a sub-minute board is an *in-server* live scoreboard, and that should be a [`Scribe.Shared`](./visibility) root, which updates instantly and costs no DataStore requests at all. These boards are global and all-time.

Scribe also refuses at startup if the boards you declare would collectively read too often, because the total is what actually burns budget: ten boards at 60s costs more than one board at 15s, so a per-board floor alone controls the wrong thing. The ceiling is **12 `GetSortedAsync` reads per minute**, summed as `60 / RefreshInterval` over every board. Twelve boards at the default 60s exactly fit; the thirteenth refuses to boot. Raising `RefreshInterval` on the boards that tolerate it is what buys room for more, since `AllTimeDonors` above costs 0.1 reads/min instead of 1.

### Reacting to an update

Connect [`OnLeaderboard`](/api/Server#OnLeaderboard) instead of polling. It fires with `(boardName, entries)` when a board's contents actually change, and unlike the client signal it fires for **every** board, including server-only ones:

```lua
Data.OnLeaderboard:Connect(function(boardName, entries)
    if boardName ~= "TopCoins" then
        return
    end
    updateDisplay(entries)
end)
```

`entries` is rank-ordered, so `entries[1]` is rank 1 with the highest score, exactly what `GetLeaderboard` returns. A polling loop cannot align with the schedule (boards are staggered across their cycle), so it reads a cache anywhere from fresh to a full interval stale. `entries` is a fresh copy, so you can keep or mutate it freely.

The **client's** `OnLeaderboard` is the exception: it fires the very table it caches, not a copy. A client listener that sorts, trims, or annotates `entries` in place corrupts what the client's own `Data.GetLeaderboard` serves until the next board frame arrives. Copy it first, or read through `Data.GetLeaderboard`, which clones on the way out.

## Ranking a Scribe.Big

A [`Scribe.Big`](/api/Scribe#Big) field works as a stat with no extra setup. An OrderedDataStore key is an integer, and a Luau number stops being an exact integer at 2^53, so the raw value cannot be stored. It does not need to be: a big is already normalized to `1 <= |m| < 10` with an integer exponent, so Scribe packs it exponent-major (`e * 1e12 + floor(m * 1e11)` by default, see [`SigFigs`](#resolution-vs-range-sigfigs)). The exponent dominates and the mantissa breaks ties, which is a big's own comparison order, so ranking is **exact** with no logarithm and no precision loss in the ordering.

```lua
Coins = Scribe.Big(0, { Min = 0 }),
-- Leaderboards = { Top = { Stat = "Coins" } }

for _, entry in Data.GetLeaderboard("Top", 10) do
    -- Score is the big itself, not the packed key. It is typed
    -- `number | BigScore` because the board's kind is a runtime property of the
    -- name you passed, so narrow it once and the rest of the block is typed.
    local score = entry.Score
    if type(score) == "table" then
        print(entry.Name, score:Short())
    end
end
```

Two constraints follow from the key being an integer. The value must be **non-negative**, because the packing has no room for a sign, and the exponent must be within the board's cap (1e9006 by default). A score outside either is dropped and logged as `LB_SCORE_OUT_OF_RANGE` rather than ranked wrongly. `Scale` is refused on a big board, since the packing already maps the value into the key space.

### Resolution vs range: `SigFigs`

The exponent and the mantissa share one integer that has to stay under 2^53, so they compete. `SigFigs` decides how that budget is split, **per board**. It is the number of significant figures the ranking key keeps, and since the `Score` you read back is decoded from that key, it is also the number of figures the board can display.

```lua
Leaderboards = {
    -- A prestige currency: separate players who agree to 12 figures.
    TopCoins = { Stat = "Coins", SigFigs = 14 },
    -- Gems only need a rough ordering, over an enormous range.
    TopGems  = { Stat = "Gems", SigFigs = 6 },
}
```

Every extra figure costs a factor of ten of exponent range:

| `SigFigs` | Largest rankable value | Good for |
| --- | --- | --- |
| 6 | 1e9007199253 | a counter whose magnitude is the whole story |
| 9 | 1e9007198 | a middle ground |
| **12** (default) | **1e9006** | almost everything |
| 14 | 1e89 | separating near-identical prestige scores |
| 15 | 1e8 | not a big currency at all; use `Scribe.Int` |

The range is 1 to 15. Above 15 the mantissa alone would pass 2^53, and a big carries no more than about 15 significant digits anyway. A score past the board's cap is dropped and logged as `LB_SCORE_OUT_OF_RANGE`, naming both the cap and the `SigFigs` that set it. `SigFigs` is refused on a plain numeric stat: there the key **is** the value, and [`Scale`](#fractional-stats-scale) is the dial.

A big board is also **server-only**. The board frame writes each score as one f64, which a big does not fit into, so `Replicate = true` on a big stat is refused at startup rather than throwing on every broadcast. Read it on the server with `GetLeaderboard` or `OnLeaderboard`, and send whatever your UI needs over your own remote.

Separately, the range guard for **plain** numeric stats is 2^53, not int64. Past that a Luau number is no longer an exact integer, so a scaled score would be written with silently wrong low digits and tie against its neighbours. A stat with a large `Scale` can reach that, and Scribe drops the write rather than storing a corrupted key.
