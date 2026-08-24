# Session Lifecycle

A player's profile does not exist the instant they join. Scribe has to fetch it from a DataStore, reconcile it against your template, and take a session lock on it, and all of that takes time. Knowing that sequence is the difference between smooth joins and a mysterious "data for Ava is Loading" error.

This page follows one session from the moment a player arrives to the moment their last save lands.

## Waiting for data

Never read a player's data before it is ready. Ask for it and handle both answers:

```lua
Players.PlayerAdded:Connect(function(player)
    local data, reason = Data.WaitForData(player)
    if not data then
        if reason ~= Scribe.Reason.PlayerLeft then
            warn(`Emberfall: no data for {player.Name}, {reason}`)
        end
        return
    end

    local folder = Instance.new("Folder")
    folder.Name = "leaderstats"

    local level = Instance.new("IntValue")
    level.Name = "Level"
    level.Parent = folder

    data.Level.Observe(function(value)
        level.Value = value
    end)

    folder.Parent = player
end)
```

[`Data.WaitForData(player, timeout?)`](/api/Server#WaitForData) yields until the profile is Ready, up to `timeout` seconds (60 by default), and returns `(accessor?, reason?)`. `Observe` fires immediately with the current value and again on every change, so the leaderstat is correct from the first frame.

Once a session is Ready, `Data[player]` and [`Data.Get(player)`](/api/Server#Get) hand you the same accessor without yielding. Both **error** while a profile is still Loading, so use them after `WaitForData`, or inside a [`Command`](/api/Server#Command) handler, which only runs once the caller is Ready. [`Data.GetState(player)`](/api/Server#GetState) answers `"Loading"`, `"Ready"` or `"SessionEnded"` at any moment without yielding.

## When there is no data

`reason` is one of exactly seven values, available as the `Scribe.LifecycleReason` type and the `Scribe.Reason` constants table. The `SessionEnded` signal carries the same set.

| Reason | `Scribe.Reason` | Meaning | Retry? |
| --- | --- | --- | --- |
| `player-left` | `PlayerLeft` | The player left. By far the most common, and usually not an error. | no |
| `still-loading` | `StillLoading` | The wait elapsed while the load was **still in flight**. Nothing has failed. | **yes** |
| `timeout` | `Timeout` | The wait elapsed and Scribe has no session for this player at all. | no |
| `load-failed` | `LoadFailed` | The profile could not be loaded. | no |
| `migration-failed` | `MigrationFailed` | A migration errored, so the profile was released unmigrated. | no |
| `session-ended` | `SessionEnded` | The session ended while the player was still in game. | no |
| `shutdown` | `Shutdown` | The server is closing. | no |

Only one of them is worth retrying:

```lua
local data, reason = Data.WaitForData(player)
if not data and reason == Scribe.Reason.StillLoading then
    data = Data.WaitForData(player, 60)   -- still coming, give it the rest of the load window
end
```

??? note "Why `still-loading` and `timeout` are different values"
    `WaitForData` waits 60 seconds by default, while a load is given [`LoadTimeout`](./configuration) seconds, 120 by default and floored at 60. So there is a band where the default wait runs out over a load that is simply taking its time and is going to succeed. A cross-server handoff waits out ProfileStore's session-steal window, about 40 seconds, and a slow DataStore stretches that further.

    That band used to report `timeout`, the same value a player Scribe has no session for gets, so the two were indistinguishable. The default wait was deliberately **not** raised to match the load deadline: a bounded wait that tells you the truth is worth more than a longer one that does not, and a caller who wants to wait longer can say so.

    If you branch on `timeout` today, handle `still-loading` alongside it.

## On the client

The client mirror never errors. Accessor reads return **template defaults** until the first snapshot arrives, then `Observe` and `Changed` fire with the real values. For reactive UI that is all you need:

```lua
Data.Coins.Observe(function(coins)
    coinLabel.Text = tostring(coins)
end)
```

To gate one-shot startup logic, use [`Data.IsReady()`](/api/Client#IsReady), which does not yield, or [`Data.WaitForData(timeout?)`](/api/Client#WaitForData), which yields until loaded and returns `false` if it times out after 30 seconds by default, so it never hangs:

```lua
if Data.WaitForData() then
    showMainMenu(Data.Level.Get())
end
```

## OnPlayerInit

`OnPlayerInit` runs once per player, right after their profile finishes loading and before they are Ready. It receives the Player, their **raw** data table, and whether this is a brand-new profile:

```lua
Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",

    OnPlayerInit = function(player, rawData, isNewProfile)
        if isNewProfile then
            rawData.Coins = 500   -- Emberfall's starter purse
        end
    end,
})
```

`isNewProfile` is true for a genuinely new profile, a `ResetData` wipe, and a first-session crash recovery, so you can run starter kits and welcome flows without keeping your own sentinel field. An error thrown here is caught and logged rather than blocking the load.

The table you get is the raw profile data, not the accessor tree, so writes here bypass the usual validation. Scribe scans the result afterwards and reports anything unstorable as `PROFILE_UNPERSISTABLE`. For a value that depends only on the profile itself, such as a creation timestamp, prefer [`Scribe.Dynamic`](./templates), which is declared in the template and runs per profile automatically.

Because it is the raw table, [derived fields](./derived) are not in it. They are computed, never stored, and Scribe evaluates them right after this hook and before the session is Ready. A value you would otherwise compute here and write is usually a derived field.

:::caution Datatype fields need packing here
Bypassing the accessor also bypasses [datatype packing](./datatypes). A raw assignment stores the userdata itself, which no DataStore can serialize:

```lua
OnPlayerInit = function(player, data)
    data.Checkpoint = Vector3.new(0, 12, 0)                                   -- PROFILE_UNPERSISTABLE
    data.Checkpoint = Scribe.Datatypes.Pack("Vector3", Vector3.new(0, 12, 0))  -- correct
end,
```

Reads are unaffected either way: `data.Checkpoint.Get()` still hands back a real `Vector3`. The same applies inside a [migration](./profiles#migrations), which also receives raw data.
:::

## Migrations

If your template has changed shape since a profile was written, Scribe runs your migration chain during the load, between reconciling the stored data and `OnPlayerInit`. Migrations are fail-closed: a step that throws ends the session with a kick and the `migration-failed` reason, and nothing is stamped or saved.

Writing that chain is its own topic, because a migration step edits the stored profile rather than a live session. [Offline Profiles](./profiles#migrations) covers it.

## Saving

Scribe autosaves each profile every `SaveInterval` seconds, 300 by default. Lower it to shrink the window of progress a crash can cost. It also saves when a player leaves and on `BindToClose`.

For a grant you do not want to lose, force a save:

```lua
Data.Purchase(player, spec)
Data.Flush(player, { Force = true })   -- persist immediately
```

[`Flush`](/api/Server#Flush) yields until the save is confirmed and returns whether it landed. `Force = true` also pushes the save through if the [wipe guard](./diagnostics) had blocked it.

Flushing costs nothing when there is nothing to save. If the profile has not changed since its last successful save and none is still in flight, `Flush` answers `true` straight away with no DataStore request. So flushing on a checkpoint or a timer is cheap, and flushing after a grant still always saves, because a grant leaves the profile dirty by definition.

:::caution A `false` from `Flush` does not mean the save failed
`Flush` waits at most `Timeout` seconds, 15 by default, and then returns `false` even though the save may still complete afterwards. It also returns `false` immediately, without attempting a save at all, if the profile is not Ready, which a `Flush` fired from `PlayerAdded` before `WaitForData` always is.

Log it or retry the flush. Never re-grant the purchase on `false`, or you double-grant the common case.
:::

Watch save state for "Saving... / Saved" UI:

```lua
Data.OnSave:Connect(function(info)
    -- { Player, Ok, Duration, At }
end)

local info = Data.GetSaveInfo(player)   -- { LastSaveAt, LastResult, Dirty, Size }
```

??? note "Reads that answer with a default while a profile is loading"
    `Owns`, `GetPurchases`, `GetGiftCredits` and `GetSaveInfo` answer with `false`, `{}` and `{ Dirty = false }` respectively while a profile is still Loading. Gate ownership logic behind `WaitForData` so a VIP owner is not treated as a non-owner on join.

??? note "Writing a burst of changes at once"
    Several writes in a row each replicate on their own frame. [`Data.Batch`](/api/Server#Batch) coalesces them into one flush, and [`Data.Transaction`](/api/Server#Transaction) additionally makes them all-or-nothing. Both are covered in [Cross-Key Transactions](./transactions), along with what "atomic" does and does not mean here.

## Session end

When a session ends, whether the player left or another server stole the session, [`SessionEnded`](/api/Server#SessionEnded) fires with `(player, reason)`. With `KickOnSessionEnd = true`, the default, the player is also kicked so their client cannot keep acting on stale data.

```lua
Data.SessionEnded:Connect(function(player, reason)
    if reason == Scribe.Reason.SessionEnded then
        analytics:Log("session_stolen", player.UserId)
    end
end)
```

## Working with signals

`OnSave` and `SessionEnded` are [signals](/api/Signal), and so is every other `On…` member on `Data`, `Client` and `Scribe`. They all work the same way:

```lua
local conn = Data.OnSave:Connect(function(info) end)   -- runs on every save
conn:Disconnect()                                      -- stop listening

Data.OnSave:Once(function(info) end)                   -- runs once, then detaches
local info = Data.OnSave:Wait()                        -- yields for the next one
```

Every handler runs on its own thread, so yielding inside one holds up neither the other handlers nor Scribe. A handler that errors is reported with its traceback and the signal keeps working, which is why a broken analytics call cannot stop a save. Do not depend on two handlers running in a particular order; if one step has to follow another, put both in the same handler.

## Writing on the way out

`OnPlayerLeaving` is the counterpart to `OnPlayerInit`. It runs **before the final save**, so whatever it writes persists. This is where the accumulate-on-exit pattern belongs:

```lua
Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",

    OnPlayerLeaving = function(player, data, reason)
        local joined = joinedAt[player.UserId]
        if joined then
            data.Stats.Playtime.Increment(os.time() - joined)
        end
    end,
})
```

You get the same typed accessor as anywhere else, so writes are validated and bounded rather than dropped raw into the profile. `reason` is the usual [`LifecycleReason`](/api/Scribe#Reason), so you can skip expensive work on `shutdown` when the deadline is short.

Doing this from your own `Players.PlayerRemoving` handler instead is a race against Scribe's, decided by connection order, and a write that lands after teardown is silently lost.

**The hook must not yield.** Do the async work during the session and only write here. On a normal leave, a hook parked on a `task.wait` or a DataStore call holds that player's session open for as long as it waits.

??? note "What happens to the hook on shutdown"
    On shutdown the hook no longer holds up anybody else. Every player's hook starts at once, and each one still runs before its own final save. But it is now bounded: the hook phase gets three quarters of Scribe's shutdown budget, which is its slice of Roblox's roughly 30 second `BindToClose` window and is 25 seconds by default. The rest belongs to the leaderboard flush.

    Two things follow for a hook that runs long. Once that share is spent, remaining hooks are **skipped** so their profiles can still save. A hook already parked when the share expires is **cut off**: Scribe stops waiting and saves without it. A cut-off hook is not atomic. Whatever it wrote before the cut is already in the profile and persists, and what it writes afterwards raises into the same contained error path as a throw.

    `SHUTDOWN_DONE` reports both counts, and they are also the `LeavingHooksSkipped` and `LeavingHooksTimedOut` counters in [diagnostics](./diagnostics).

??? note "The hook does not run in every teardown"
    It is skipped when the profile never reached Ready, when another server steals the session mid-play, because that path tears the entry down without a local leave, and on shutdown when the hook phase has spent its share of the budget before reaching that player.

    Those are exactly the sessions an accumulate-on-exit counter would most want, so treat the hook as best-effort bookkeeping rather than the only place a value is ever written. If the hook throws, the error is logged and the save continues, costing you that hook's remaining writes rather than the whole session.

??? note "Shutting a bundle down inside a test or a simulation"
    A Scribe bundle is normally built once and lives for the whole server, so a game never needs this. A **process** that builds many bundles, such as a test suite or a simulation standing up a fleet of servers, otherwise accumulates immortal loops and listeners and ends up measuring that accumulation rather than Scribe.

    [`Data.Stop()`](/api/Server#Stop) releases everything one bundle holds: the timed-field sweep, the leaderboard write pacer and refresh cycle, the per-frame replication flush, the Players and MarketplaceService listeners, the ProfileStore signal handlers, and `MarketplaceService.ProcessReceipt` if this bundle owns it.

    ```lua
    local bundle = Scribe({ Template = template, ProfileStoreIndex = "EmberfallTest", ProfileKeyPrefix = "T_" })
    local Data = bundle.Server

    -- ... run the test ...

    Data.Flush(player, { Force = true })   -- Stop does NOT save
    Data.Stop()
    ```

    It is idempotent, and it deliberately does **not** save, so flush first if the data matters. Loaded sessions are left alone: drop the bundle and they go with it. See [Testing & Edit Mode](./testing).

## Where to next

- [Offline Profiles](./profiles) covers everything that happens to a profile when the player is not here: version history, rollbacks, migrations, and erasure.
- [Cross-Key Transactions](./transactions) explains `Batch`, `Transaction`, and what atomicity means for one player's tree.
- [Configuration](./configuration) lists `SaveInterval`, `LoadTimeout`, `KickOnSessionEnd` and the rest.
- [Diagnostics](./diagnostics) is where save failures, the wipe guard, and the shutdown counters surface.
- [Commands & Requests](./commands) is how the client asks the server to change something after it is Ready.
