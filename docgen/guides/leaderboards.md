# Leaderboards

A leaderboard ranks a numeric field in your template. By default it is an all-time ranking shared across every server, stored in an OrderedDataStore. You can also rank daily or weekly progress, or only the players on the current server.

| You want to rank... | Start here |
| --- | --- |
| Every player's all-time score | [Your first board](#your-first-board) |
| Progress earned today or this week | [Daily and weekly boards](#daily-and-weekly-boards) |
| Players currently in this server | [A board for this server](#a-board-for-this-server) |
| Very large `Scribe.Big` values | [Ranking a Scribe.Big](#ranking-a-scribebig) |

The examples use `Level` from the [Emberfall template](./emberfall). Replace it with any supported numeric field in your own template.

## Your first board

Add a `Leaderboards` table to the shared module. Each entry names a `Stat`, which is a path into your template.

```lua
Leaderboards = {
    TopLevel = { Stat = "Level", Limit = 100, Replicate = true },
},
```

That is all of it. Scribe watches `Level` on every loaded player, queues a write whenever it changes, and re-reads the top 100 in the background. On the server, read the board back like this:

```lua
for _, entry in Data.GetLeaderboard("TopLevel", 10) do
    print(entry.Rank, entry.Name, entry.Score)
end

local myRank = Data.GetMyRank(player, "TopLevel")
```

Each entry is `{ Rank, UserId, Name, Score }`, rank-ordered, so the first one is rank 1 with the highest score. `Score` comes back in the field's own units.

`Level` is worth pausing on. It is a [derived field](./derived), computed from `Xp` and never written directly, and a board can still rank it because every input persists. Scribe reproduces the value exactly on load, which is the only property a board actually needs.

## Showing a board to players

Boards are server-only by default. That is right for a physical board you build out of parts, and wrong for a UI panel. `Replicate = true` streams the board to every client, which then reads it with the matching client calls:

```lua
-- client
for _, entry in Data.GetLeaderboard("TopLevel", 10) do
    row(entry.Rank).Text = `{entry.Name} - level {entry.Score}`
end

local myRank = Data.GetMyRank("TopLevel")
```

Note the two `GetMyRank` signatures differ. The server takes the player first, `GetMyRank(player, name)`, and the client takes only `GetMyRank(name)`. A client can never trigger an OrderedDataStore request either way, on either realm.

### Reacting to an update

Connect [`OnLeaderboard`](/api/Server#OnLeaderboard) instead of polling. It fires with `(boardName, entries)` when a board's contents actually change:

```lua
Data.OnLeaderboard:Connect(function(boardName, entries)
    if boardName ~= "TopLevel" then
        return
    end
    redrawBoard(entries)
end)
```

A polling loop cannot align with the schedule, because boards are staggered across their cycle, so it reads a cache anywhere from fresh to a full interval stale. The server's signal fires for every board, including server-only ones.

!!! warning "The client's `OnLeaderboard` hands you the table it caches"
    On the server, `entries` is a fresh copy you may keep or mutate freely. The **client's** signal is the exception: it fires the very table it caches, not a clone. A client listener that sorts, trims, or annotates `entries` in place corrupts what that client's own `Data.GetLeaderboard` serves until the next board frame arrives. Copy it first, or read through `GetLeaderboard`, which clones on the way out.

## When a board fills in

Every read hits a cache, never a live store, so a board is empty until its own first refresh lands. The refresh loop starts about five seconds after the server boots and staggers each board's first read across its interval, so with several boards declared the last one can take close to a full `RefreshInterval` to fill.

`GetMyRank` returns a player's position **within the board's top `Limit`**, or `nil` if they sit outside it. `nil` also means "not computed yet", so a player who joins just after a refresh has no rank until the next one.

??? note "Why there is no exact global rank"
    A global rank of 100,284 on a `Limit = 100` board is simply `nil`. Each refresh pulls the top `Limit` in one `GetSortedAsync` shared by every player on the server, which makes a rank lookup a cached O(1) read.

    OrderedDataStore has no exact-rank primitive. Resolving a deep rank would mean paging through 100,000 or more entries on every query, so Scribe does not do it. To show something for players off the board, track a separate stat such as a personal best.

## Refresh cadence

Each board re-reads its store every 60 seconds by default. Set `RefreshInterval` per board to go **slower**, which is what most games want:

```lua
Leaderboards = {
    TopLevel = { Stat = "Level", Limit = 100, Replicate = true }, -- default 60s
    TopCoins = { Stat = "Coins", RefreshInterval = 600 },         -- every 10 minutes
},
```

A top-100 all-time board rarely needs minute-freshness, and every refresh spends from a `GetSortedAsync` budget that scales with player count. Values below 60 seconds are clamped up and reported as `LB_INTERVAL_CLAMPED`.

`Data.GetLeaderboardRefreshIn(name)` is the seconds until a board next reads, for a "refreshes in" label. It is `0` while a due refresh waits on the request budget, and `nil` until the loop has scheduled its first cycle a few seconds after boot. It is server-side; a client label reads it through a `Scribe.Shared` field or a Command.

Scribe also refuses at startup if your boards would collectively read too often. The ceiling is **12 reads per minute**, summed as `60 / RefreshInterval` across every board, so twelve boards at the default exactly fit and the thirteenth will not boot. `TopCoins` above costs 0.1 reads per minute instead of 1, which is how you buy room for more boards.

??? tip "If you wanted a live in-server scoreboard, declare `Scope = \"Server\"`"
    Going faster than a minute is nearly always a sign that what you want is the players on *this* server, not a global board. That is [a server-scoped board](#a-board-for-this-server), which reads nothing from a store and refreshes every five seconds by default.

    Be deliberate about what you rank. A replicated board shows every player's score to everyone here, and a stat that moves the moment a player spends or gifts lets others infer what they did from the size of the movement. Rank a score, a tier, or a bucketed figure, and leave the real balance on the owner-only default.

## Daily and weekly boards

A board resets on a period by declaring one. It is otherwise an ordinary board: same store cost, same refresh, same `Replicate`, same reads.

```lua
Leaderboards = {
    Wins       = { Stat = "Wins", Replicate = true },
    WinsDaily  = { Stat = "Wins", Period = "Daily", Replicate = true },
    WinsWeekly = { Stat = "Wins", Period = "Weekly" },
    BestCombo  = { Stat = "Combo", Period = "Daily", Mode = "Peak" },
},
```

**What goes on the board is not the stat.** A player with 5,000 lifetime wins who won twice today ranks at 2. Scribe keeps a small baseline per periodic board in the profile and writes the difference:

| `Mode` | writes | for |
| --- | --- | --- |
| `Gain` (default) | the stat now minus the stat when the period began, floored at 0 | cumulative stats: wins, XP, coins earned |
| `Peak` | the highest value seen this period | high-score stats: best combo, longest streak |

The baseline is saved in the profile. Rejoining within the same period keeps it; rejoining after a rollover starts the new period at zero. A stat that falls below its period start ranks at 0.

**A reset starts a new store; it does not delete the old period.** That lets Scribe read previous winners and keeps servers on the same schedule.

??? note "Period store names and retained history"
    `WinsDaily` writes to names such as `LB_WinsDaily_d20708`; `WinsWeekly` uses names such as `LB_WinsWeekly_w2958`. The reset clock determines the index, so no cross-server reset message is needed.

    Old period stores remain. They use storage and add work to a user's [erasure](#erasure). If you need to remove old stores in bulk, use the Creator Hub's Data Stores Manager rather than expecting a rollover to clean them up.

### The reset clock

One clock per bundle, because a game has one audience:

```lua
PeriodReset = { UtcOffset = -8, WeekStart = "Monday" },
```

`UtcOffset` is in hours from UTC, fractional allowed for the half-hour zones, from -12 to 14; the default is 0. `WeekStart` is a day name; the default is Monday. So a US-West game rolls its day at 08:00 UTC and its week on Monday in that clock.

It is a fixed offset. Luau has no timezone database, so a region with daylight saving sees the reset move by an hour twice a year unless you move the offset with it. Changing the offset shifts every period index, so one partial period appears at the change and every player's baseline resets once. Do it between periods.

### Time to the reset

`Data.GetLeaderboardResetIn(name)` is the seconds until the board's current period ends, on the reset clock above, for a "resets in" label. It is always above zero, since at the instant of rollover the next period has begun, and `nil` for a board with no `Period`. Server-side, like `GetLeaderboardRefreshIn`.

### Reading the previous period

On the server, use `Data.GetLeaderboard(name, limit, -1)` to read the previous period. It is not replicated automatically; forward it through a Command if your client shows previous winners.

Scribe reads that period at the first refresh after rollover and once more at the next refresh, to include late leave saves. It then serves the cached result for the rest of the current period. Treat the first result as provisional while that second read is still due.

??? note "Overlapping refreshes and shutdown"
    Only one refresh runs per board. A scheduled refresh is skipped if the previous one is still running. Concurrent `RefreshNow` calls share at most one waiting refresh, so slow requests do not build an unbounded queue.

    `Stop` prevents waiting refreshes from starting. An in-flight refresh finishes its current read and goes no further. This keeps cache updates and the two previous-period reads from racing one another.

### Cost

Writes scale with the number of boards on a stat, but the pacer's dedup window already collapses a burst into one write per board, so three boards on `Wins` is three writes per player per settle, not three per increment. Reads are one more `GetSortedAsync` per periodic board per `RefreshInterval`, and the startup guard above counts them. Nothing runs per frame, the pacer parks while its queue is empty, and a bundle with only server boards never starts it.

!!! warning "Upgrading to 2.4.0 changes the schema hash"
    The baseline lives under the reserved `_Scribe` root, and a new child there changes the hash both realms compare at handshake. Deploy your server and client together, as with any template change, even if you declare no periodic board.

## A board for this server

`Scope = "Server"` ranks the players on this server and nothing else. There is no store behind it and no request spent on it: every refresh sorts the online players' stat in memory, five seconds apart by default and no faster than one.

```lua
Leaderboards = {
    RoundWins  = { Stat = "Wins", Scope = "Server", Replicate = true, RefreshInterval = 2 },
    TodayHere  = { Stat = "Wins", Scope = "Server", Period = "Daily" },
},
```

It composes with `Period`, because the baseline is per player, not per board: `TodayHere` ranks the players here by what they earned today. `GetMyRank` works, `Replicate` works, and a server board is exempt from the read guard and from the migration reserve, since it reads nothing. A player who leaves drops off at the next refresh. `offset = -1` answers an empty list, since nothing was stored.

## Erasure

Roblox does not erase your stores for you. On a right-to-be-forgotten request it messages you, and deletes automatically only what matches the RTBF deletion templates you configure, where `{UserId}` is the only token and the store name is a literal. Roblox's own example lists an ordered leaderboard as user data, so board entries are in scope.

A lifetime board fits one template, and with it Roblox erases that board without anyone calling anything:

```json
{ "key_template": { "data_store_type": "ORDERED", "data_store_name": "LB_Wins", "key_pattern": "{UserId}", "scope_pattern": "global" } }
```

A periodic board would need a template per day or week. `Data.Erase` therefore removes those entries itself, from the player's first recorded period through the current one, **before deleting the profile**. A server-scoped board stores nothing and needs no removal.

A long history can take time. Each period costs one `RemoveAsync`, paced against `OrderedRemove` budget under `BudgetPolicy = "Defer"`. Scribe saves progress every twenty-five removals and on failure. If the sweep returns `(false, reason)`, retry: the profile remains and the sweep resumes from its checkpoint. Only the user being erased is prevented from rejoining during the work; [Offline Profiles](./profiles#gdpr-export-and-erase) explains the outcomes.

The profile records which kind of period its baseline belongs to. Change a board from `Daily` to `Weekly` (or back) and the player's next write closes the old range on record and starts a new one, so the erase sweeps the daily stores they wrote to under their own names rather than skipping them, and a board that became daily does not sweep every day since the epoch. A baseline written before this record carried a kind is taken to be in the board's current kind.

## What a `Stat` may be

A `Stat` is a dotted path (`"Level"`, `"Stats.Playtime"`) that must land on a number field, a `Scribe.Int`, or a [`Scribe.Big`](./big-numbers). Scribe checks the shape at startup and refuses to boot with an error naming the board, so these never reach production:

- a path descending **through** a leaf field, or naming a field a closed element shape does not declare
- a field that is not numeric: a string, boolean, enum, flags, or datatype leaf
- a whole container rather than a leaf
- a [`Scribe.Session`](./visibility) field, which resets every session while the board's entries outlive it
- a derived field that reads session-only state, since its value is not reproducible across sessions

One case is not caught, because it cannot be: a typo in a dynamic path. Any unknown key on an open container is a legitimate dynamic path, so `"Inventory.EmberLantrn.Qty"` on a `DictOf` is valid, and a player without that key is simply not tracked. If a board stays permanently empty and the config passed startup, a mistyped dynamic segment is the first thing to check.

??? note "Universe-global stores, and why renaming a board resets it"
    Boards live in OrderedDataStores named `LB_<board>`, independent of `ProfileStoreIndex` and `ResetData`. Bumping your profile store index does **not** reset leaderboards, and renaming a board effectively resets it. Set a per-board `StoreName` to namespace one for a test and production split, or to intentionally share it across places.

    A `Scribe.Big` board is named `LB_<board>_big<SigFigs>`, always, even at the default. A big is packed exponent-major and a plain numeric stat is packed as itself, so they are two key layouts, and two layouts must never share a store. Without the suffix, retyping a stat from `Scribe.Int` to `Scribe.Big` (which needs no migration and emits no warning) would silently reinterpret every key already written: a legacy `9e11` would decode as `9`, so a brand-new account with 100 would outrank it.

## Fractional stats: `Scale`

An OrderedDataStore key is an integer, so a plain numeric stat is stored as `round(value * Scale)` and divided back out on read. `Scale` defaults to 1, which is what a whole-number stat such as `Level` or `Coins` wants. At that default a fractional value is just rounded, so 3.47 and 3.42 both rank as 3.

Raise it when the fraction is what separates players:

```lua
Leaderboards = {
    TopPlaytime = { Stat = "Stats.Playtime", Scale = 100 },  -- rank to two decimals
},
```

`Scale` must be a finite number greater than 0, checked at startup. The scaled value still has to stay inside 2^53, so a large `Scale` on an already-large stat buys decimals at the cost of range. Past 2^53 a Luau number is no longer an exact integer, so Scribe drops the write and logs `LB_SCORE_OUT_OF_RANGE` rather than storing a key with silently wrong low digits.

`Scale` is refused on a `Scribe.Big` stat, where the exponent packing already maps the value into the key space.

## Ranking a Scribe.Big

Emberfall's prestige mode pays `Essence`, a [`Scribe.Big`](./big-numbers) whose totals run past `2^53`. A big stat ranks like any other, with no separate rank field and no lossy conversion:

```lua
Essence = Scribe.Big(0, { Min = 0 }),
-- Leaderboards = { TopEssence = { Stat = "Essence" } }

for _, entry in Data.GetLeaderboard("TopEssence", 10) do
    local score = entry.Score
    if type(score) == "table" then
        print(entry.Name, score:Short())
    end
end
```

`Score` is typed `number | BigScore`, because whether a board is big is a runtime property of the name you passed. Narrow it once, as above, and the rest of the block is typed.

Two constraints follow from the key being an integer. The value must be **non-negative**, since the packing has no room for a sign, and its exponent must sit within the board's cap. A score outside either is dropped and logged as `LB_SCORE_OUT_OF_RANGE` rather than ranked wrongly.

A big board is also **server-only**. `Replicate = true` on a big stat is refused at startup. Read it on the server and send whatever your UI needs over your own remote.

??? note "Why ranking a big is exact"
    A big is already normalized to a mantissa in `[1, 10)` with an integer exponent, so Scribe packs it exponent-major: `e * 1e12 + floor(m * 1e11)` at the default. The exponent dominates and the mantissa breaks ties, which is a big's own comparison order. Ranking is therefore exact, with no logarithm and no precision loss in the ordering.

    The board frame writes each score as one f64, which a big does not fit into. Sending one would throw inside the broadcast, during a joining client's handshake, and that player would silently lose every other player's `Shared` data. Refusing `Replicate` at boot is cheaper than shipping a board that breaks the handshake.

### Resolution vs range: SigFigs

The exponent and the mantissa share one integer that has to stay under 2^53, so they compete for it. `SigFigs` decides how that budget is split, per board. It is the number of significant figures the ranking key keeps, and since `Score` is decoded from that key, it is also how many figures the board can display.

```lua
Leaderboards = {
    TopEssence = { Stat = "Essence", SigFigs = 14 },  -- separate near-identical scores
    TopBanked  = { Stat = "Banked", SigFigs = 6 },    -- rough order over a huge range
},
```

Every extra figure costs a factor of ten of exponent range:

| `SigFigs` | Largest rankable value | Good for |
| --- | --- | --- |
| 6 | 1e9007199253 | a counter whose magnitude is the whole story |
| 9 | 1e9007198 | a middle ground |
| **12** (default) | **1e9006** | almost everything |
| 14 | 1e89 | separating near-identical prestige scores |
| 15 | 1e8 | not a big currency at all, use `Scribe.Int` |

The range is 1 to 15. Above 15 the mantissa alone would pass 2^53, and a big carries no more than about 15 significant digits anyway. A score past the board's cap is dropped and logged as `LB_SCORE_OUT_OF_RANGE`, naming both the cap and the `SigFigs` that set it.

`SigFigs` is refused on a plain numeric stat. There the key **is** the value, and [`Scale`](#fractional-stats-scale) is the dial.

## Roblox's built-in leaderboard UI

Roblox can render a persistent leaderboard in your experience with no UI code, reading an
OrderedDataStore directly. Scribe's boards are ordinary OrderedDataStores, so they work with it.
Follow the
[Creator Hub instructions](https://create.roblox.com/docs/players/leaderboards#configure-a-leaderboard-in-creator-hub)
and give it two things:

| It asks for | Give it |
| --- | --- |
| Data store name | `LB_<BoardName>`, using the name you gave the board in `Leaderboards` |
| Key template | `{UserId}` |

So a board declared as `TopLevel` lives in `LB_TopLevel`. If you set `StoreName` on the board
yourself, use that name instead.

!!! warning "A `Scribe.Big` board cannot be shown this way"
    A big board stores a packed integer, not the score, so the built-in UI would rank players
    correctly and then display a number that is not theirs. Use `Data.GetLeaderboard` and your own
    UI for those, as in the section above.

## Typed configs

Annotate the config as its own local and `Stat` autocompletes to your template's numeric leaf paths:

```lua
type T = typeof(template)

local boards: { [string]: Scribe.LeaderboardConfig<T> } = {
    TopLevel = { Stat = "Level", Limit = 100, Replicate = true },
    TopPlaytime = { Stat = "Stats.Playtime" },
}

return Scribe({ Template = template, Leaderboards = boards, --[[ ...required fields... ]] })
```

The annotation is what enables the strict check. Inside a single `Scribe({ ... })` literal, Luau widens the string before the template type is known, so the annotated-local pattern is how you get autocomplete for `Stat` and for `Cost.Path`. Past 32 numeric leaf paths both fall back to plain `string`: the union of every path is what would push a template that size past the type solver's budget, and startup still refuses a path that is not in the template.

## Where to next

- [Derived Fields](./derived) for how `Level` is computed, and why a derived stat is rankable.
- [Replication & Visibility](./visibility) for sharing individual player values alongside a board.
- [Configuration](./configuration#monetization-services) for every leaderboard option in one table.
- [Diagnostics](./diagnostics) for the queue and budget counters behind the write pacer.
- [Log Code Reference](./log-codes#leaderboards) for every `LB_` code and what to do about it.
