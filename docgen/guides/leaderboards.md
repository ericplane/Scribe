---
sidebar_position: 7
---

# Leaderboards

All-time global leaderboards on a paced, deduplicated OrderedDataStore write queue. The queue flushes on stat change, join, leave, and `BindToClose`.

```lua
Leaderboards = {
    TopCoins = { Stat = "Coins", Limit = 100 },                  -- server-only (default)
    TopWins  = { Stat = "Wins",  Limit = 50, Replicate = true }, -- streamed to clients
},
```

`Stat` is a path into your template (`"Coins"`, `"Stats.Kills"`), and Scribe keeps that field's board updated automatically. Boards are **server-only by default**. Read them on the server with [`GetLeaderboard`](/api/Server#GetLeaderboard) / [`GetMyRank`](/api/Server#GetMyRank) (e.g. to render a physical board). Set `Replicate = true` to also stream a board to clients, which read it with the matching [client APIs](/api/Client#GetLeaderboard).

A client can never trigger an OrderedDataStore request either way.

`Stat` is checked at startup only for shapes that can never work: a path descending through a leaf field, or naming a field a [closed element shape](./templates#typed-containers) does not declare. A typo on an ordinary field is **not** caught, since any unknown key on an open container is a legitimate dynamic path; it simply never produces a score. A path through a container, like `"Chars.main.Xp"` on a `Scribe.DictOf`, is fine, and a player missing that key is silently not tracked.

```lua
-- server: render a physical board
for _, entry in Data.GetLeaderboard("TopCoins", 10) do
    print(entry.Rank, entry.Name, entry.Score) -- { Rank, UserId, Name, Score }
end

-- client: a replicated board
Data.OnLeaderboard:Connect(function(boardName, entries) ... end)
local rank = Data.GetMyRank("TopWins")
```

:::note How ranks are computed
`GetMyRank` returns a player's position **within the board's top `Limit`**, or `nil` if they sit outside it: a global rank of 100,284 on a `Limit = 100` board is simply `nil`. Each refresh pulls the top `Limit` in one `GetSortedAsync` shared by every player, so the lookup is a cached O(1) read. OrderedDataStore has no exact-rank primitive, and resolving a deep rank would mean paging 100k+ entries per query, so Scribe does not do it. To show something for players off the board, track a separate stat such as a personal best.
:::

:::note Universe-global stores
Boards are OrderedDataStores named `LB_<board>`, independent of `ProfileStoreIndex` and `ResetData`. Bumping your profile store index does **not** reset leaderboards, and renaming a board effectively resets it. Set a per-board `StoreName` to namespace one (e.g. for a test/prod split) or to intentionally share it across places.
:::

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

Scribe also refuses at startup if the boards you declare would collectively read too often, because the total is what actually burns budget: ten boards at 60s costs more than one board at 15s, so a per-board floor alone controls the wrong thing.

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
