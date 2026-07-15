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
`GetMyRank` returns a player's position **within the board's top `Limit`**, or `nil` if they sit outside it. A rank of 100,284 on a `Limit = 100` board is simply `nil` (they are not on the board). The lookup itself is a cached, O(1) read: each refresh pulls the top `Limit` in a single `GetSortedAsync` call shared by every player, so there is no per-player scanning and no paging toward a deep rank. OrderedDataStore has no exact-rank primitive, and resolving a global rank of 100,284 would mean paging through 100k+ entries on every query, so Scribe does not do it. If you want to show something for players off the board, track a separate stat (such as a personal best) and display that.
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
