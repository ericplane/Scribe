# Session Lifecycle

Profiles load asynchronously and save on a cadence. Knowing the lifecycle is the difference between smooth joins and mysterious "data for X is Loading" errors.

## Loading

Always wait for data before reading it:

```lua
Players.PlayerAdded:Connect(function(player)
    local data, reason = Data.WaitForData(player)
    if not data then
        -- reason says why; see the table below
        return
    end
    -- ...use data...
end)
```

| API                                              | Purpose                                                                      |
| ------------------------------------------------ | ---------------------------------------------------------------------------- |
| [`WaitForData(player, timeout?)`](/api/Server#WaitForData) | Yields until Ready (up to `timeout` seconds, default 60); returns `(accessor?, reason?)`. Handle the `nil` branch. |
| [`GetState(player)`](/api/Server#GetState)       | `"Loading" \| "Ready" \| "SessionEnded"`, without yielding.                  |

### Why data was unavailable

When `WaitForData` returns no tree, `reason` is one of exactly six values, also available as the `Scribe.LifecycleReason` type and the `Scribe.Reason` constants table. The `SessionEnded` signal carries the same set.

| Reason | `Scribe.Reason` | Meaning |
| --- | --- | --- |
| `player-left` | `PlayerLeft` | The player left. By far the most common, and usually not an error. |
| `timeout` | `Timeout` | The wait elapsed before the profile reached Ready. |
| `load-failed` | `LoadFailed` | The profile could not be loaded. |
| `migration-failed` | `MigrationFailed` | A migration errored, so the profile was released unmigrated. |
| `session-ended` | `SessionEnded` | The session ended while the player was still in game. |
| `shutdown` | `Shutdown` | The server is closing. |

```lua
if reason == Scribe.Reason.PlayerLeft then
    return -- routine
end
```

`Data[player]` and `Data.Get(player)` **error** while a profile is Loading. Use them only after `WaitForData`, or inside a [`Command`](/api/Server#Command) handler (which only runs once the caller is Ready).

### On the client

The client mirror never errors: accessor reads return **template defaults** until the first snapshot arrives, then `Observe`/`Changed` fire with the real values. For reactive UI, that's all you need. To gate one-shot startup logic, use [`Data.IsReady()`](/api/Client#IsReady) (non-yielding) or [`Data.WaitForData(timeout?)`](/api/Client#WaitForData), which yields until loaded and returns `false` if it times out (default 30s), so it never hangs:

```lua
if Data.WaitForData() then
    showMainMenu(Data.Coins.Get())
end
```

## OnPlayerInit

`OnPlayerInit` runs once per player right after their profile finishes loading and before they are Ready, receiving the Player, their **raw** data table, and whether this is a brand-new profile:

```lua
OnPlayerInit = function(player, rawData, isNewProfile)
    if isNewProfile then
        rawData.Coins = 500 -- starter grant, only for a first-time player
    end
end,
```

`isNewProfile` is true for a genuinely new profile, a `ResetData` wipe, and a first-session crash recovery, so you can run starter kits and welcome flows without keeping your own sentinel field. Use it for per-player setup that needs the freshly loaded data, such as building leaderstats. An error it throws is caught and logged rather than blocking the load.

The table you get is the raw profile data, not the accessor tree, so writes here bypass the usual validation: Scribe scans it afterwards and reports anything unstorable as `PROFILE_UNPERSISTABLE`. For a value that depends only on the profile itself (a creation timestamp, a seed), prefer [`Scribe.Dynamic`](./templates), which is declared in the template and runs per profile automatically.

:::caution Datatype fields need packing here
Bypassing the accessor also bypasses [datatype packing](./templates#roblox-datatype-fields). A `Scribe.DateTime`, `Scribe.Vector3`, or `Scribe.CFrame` field stores a packed buffer, and the accessor converts for you, but a raw assignment stores the userdata itself, which no DataStore can serialize:

```lua
OnPlayerInit = function(player, data)
    data.Joined = DateTime.now()                                   -- PROFILE_UNPERSISTABLE
    data.Joined = Scribe.Datatypes.Pack("DateTime", DateTime.now()) -- correct
end,
```

Reads are unaffected either way: `data.Joined.Get()` still hands back a real `DateTime`. The same applies inside a [migration](#migrations), which also receives raw data. Often the simpler fix is to store the plain unix number in a `Scribe.Int` field and build the `DateTime` where you use it.
:::

## Saving

Scribe autosaves each profile every `SaveInterval` seconds (default **300**; lower it to shrink the window of progress lost to a crash). It also saves on leave and on `BindToClose`. For a grant or purchase you don't want to lose, force a save:

```lua
Data.Purchase(player, spec)
Data.Flush(player, { Force = true })  -- persist immediately
```

`Flush` yields until the save is confirmed and returns whether it landed. `Force = true` also pushes the save through if the [wipe guard](./diagnostics#wipe-guard) had blocked it.

A `false` return does **not** mean "the save did not happen". `Flush` waits at most `Timeout` seconds (default **15**, also passed in `opts`) and then returns `false` even though the save may still complete afterwards, and it returns `false` immediately, without attempting a save at all, if the profile is not Ready (a `Flush` fired from `PlayerAdded` before `WaitForData` always does). Log it or retry the flush, but never re-grant the purchase on `false`, or you double-grant the common case.

Observe save state for "Saving… / Saved ✓" UI:

```lua
Data.OnSave:Connect(function(info)
    -- { Player, Ok, Duration, At }
end)
local info = Data.GetSaveInfo(player) -- { LastSaveAt, LastResult, Dirty, Size }
```

:::note Not-ready reads return defaults
`Owns`, `GetPurchases`, `GetGiftCredits`, and `GetSaveInfo` answer with `false`/`{}`/`{ Dirty = false }` while a profile is still Loading. Gate ownership logic behind `WaitForData` so a VIP owner isn't treated as a non-owner on join.
:::

## Session end

When a session ends (leave, or a session stolen by another server), [`SessionEnded`](/api/Server#SessionEnded) fires with `(player, reason)`. With `KickOnSessionEnd = true` (the default) the player is also kicked, so their client can't keep acting on stale data.

## Batching and transactions

By default each write replicates on the next frame. Two server helpers change that for a burst of writes:

- **`Batch`** coalesces every write inside it into a **single replication flush**, so the client gets one update instead of many, and collapses each **container** `Changed` to one fire carrying the batch's end state. Leaf `Changed`, `OnChildChanged`, `OnInsert` and `OnRemove` are transitions and still fire once per write. Reach for it on bulk updates. **It must not yield**, and unlike `Transaction` below, nothing detects it when it does: a `task.wait` or DataStore call inside a batch holds that player's replication flush and every coalesced container `Changed` until the batch returns, and any unrelated write landing on the same tree in the meantime is swept into the same flush.
- **`Transaction`** runs writes **atomically**: if the function throws, every write inside is rolled back and it returns `(false, error)`; on success, `(true, nil)`. It also batches, so it is already a single flush. The function **must not yield** (no `task.wait`, DataStore, or MarketplaceService calls inside it): a yield is refused with `(false, error)` and rolled back, because a concurrent write landing during the yield could be pulled into the transaction. Do any async work before or after. A rollback also drops the economy events a tagged `Increment` / `Decrement` inside it would have logged, so a reverted transaction never reaches your analytics. A plain `Batch` gives you none of that: it defers the replication flush, but a throw inside it leaves every write that already ran in place.

```lua
-- Batch: one replication flush and one Changed for a bulk update
Data.Batch(player, function()
    for _, item in starterKit do
        Data[player].Inventory.Insert(item)
    end
end)

-- Transaction: all-or-nothing. A throw in a later step undoes the earlier writes.
local ok, err = Data.Transaction(player, function()
    Data[player].Coins.Decrement(price)
    grantItemOrThrow(player, itemId) -- if this errors, the Decrement rolls back too
end)
if not ok then
    -- nothing changed; `err` explains why
end
```

Both run synchronously on the server accessor, and transactions can't nest.

For the specific economy case of spending in-game currency on an item, [`Purchase`](./monetization#soft-currency-purchases) is a purpose-built atomic transaction: it checks funds, debits, grants, and writes a purchase-log entry as one all-or-nothing step, which is why it lives with the rest of [monetization](./monetization).

## Cross-server messaging

Send a durable message to another player's profile from any server with [`SendMessage`](/api/Server#SendMessage). It arrives at [`OnMessage`](/api/Server#OnMessage) on whatever server that player is active on, and is queued for offline players until their next load.

```lua
-- sender (any server)
local delivered = Data.SendMessage(recipientUserId, { Kind = "TradeOffer", Item = "Sword_001" })
if not delivered then
    -- the offer never left this server; don't tell the sender it did
end

-- recipient's server
Data.OnMessage:Connect(function(player, message)
    if message.Kind == "TradeOffer" then
        -- ...
    end
end)
```

`SendMessage` **yields** (it is a `MessageAsync` round trip) and returns whether the message was committed. Check the return: on failure it logs [`MESSAGE_SEND_FAIL`](./log-codes) and returns `false`, and a sender UI that assumes success reports a trade offer that was never delivered.

Messages ride ProfileStore's global-update channel, so keep them small and infrequent (this is for coordination, not chat). Scribe's own gift delivery uses the same channel with a separate tag, so the two never collide.

### The ProfileStore escape hatch

For the rare store-level operation Scribe doesn't wrap (a version query with a different sort order or date bound, a raw `MessageAsync` outside Scribe's envelope, and so on), [`Data.ProfileStore`](/api/Server#ProfileStore) exposes the underlying ProfileStore instance. It **bypasses Scribe's schema, replication, and session guarantees**, so treat it as read-mostly and never mutate an active-session profile through it. Most games never need it; prefer the typed API and `SendMessage`.

## Offline profiles, version history, and erasure

Support tickets ("my inventory vanished, roll me back") and GDPR requests act on a player who isn't in front of you. These take a `userId` rather than a `Player`, and **every one of them yields**, so call them from a [`Command`](/api/Server#Command) handler, an admin panel, or a batch task, never from a per-frame path. The [Studio plugin](./studio-plugin)'s Production panel wraps the same operations in UI when you'd rather click than write a command.

| API | Returns | What it does |
| --- | --- | --- |
| [`GetOffline(userId)`](/api/Server#GetOffline) | `data?` | Read-only snapshot of the raw profile table. |
| [`UpdateOffline(userId, fn)`](/api/Server#UpdateOffline) | `(ok, reason?)` | Runs `fn(data)` against a copy of the raw profile and saves it. |
| [`ListVersions(userId, limit?)`](/api/Server#ListVersions) | `{ { VersionId, CreatedAt, Size } }` | Version history, newest first, up to `limit` (default **25**). `CreatedAt` is Unix seconds. |
| [`GetVersion(userId, versionId)`](/api/Server#GetVersion) | `data?` | Raw data of one historical version, for inspection or diffing. |
| [`RestoreVersion(userId, versionId)`](/api/Server#RestoreVersion) | `(ok, reason?)` | Rolls the live key back to that version. |
| [`Export(userId)`](/api/Server#Export) | `json?` | The profile as a JSON string, buffers base64-encoded. |
| [`Erase(userId)`](/api/Server#Erase) | `(ok, reason?)` | Deletes the profile and the user's leaderboard entries. |

**The session lock is the rule.** Every write here (`UpdateOffline`, `RestoreVersion`, `Erase`) **fails closed** when the user has an active session, whether on this server or on any other, and returns `(false, reason)` saying which. None of them steal the lock, because stealing it would evict a player from the server they're actually playing on. `RestoreVersion` and `Erase` additionally refuse while [service health](./diagnostics#service-health) reports an `Outage`. So the operational order is: get the player out of the game, then act, then let them rejoin.

**Reads don't fail closed, and `nil` is ambiguous.** `GetOffline` returns a clone of the live data when that user is already Ready on *this* server, and otherwise reads the DataStore directly, which for a player active on *another* server is the last committed bytes rather than what they're looking at right now. `Export` reads through it, so it inherits the same behaviour. It returns `nil` both for a profile that doesn't exist and for a read that errored, and only the [`OFFLINE_READ_FAIL`](./log-codes) log tells the two apart. `GetVersion` behaves the same way (`VERSION_READ_FAIL`), and `ListVersions` returns whatever it gathered before an error, so an empty list is not proof of no history (check for `VERSION_QUERY_FAIL`).

### Rolling a profile back

```lua
local versions = Data.ListVersions(userId, 10) -- newest first
local target = versions[1]
if not target then
    return -- no history, or the query failed
end

local snapshot = Data.GetVersion(userId, target.VersionId)
if not snapshot then
    return -- version missing, or the read failed
end
print(`restoring {userId} to {target.VersionId}, Coins {snapshot.Coins}`)

local ok, reason = Data.RestoreVersion(userId, target.VersionId)
if not ok then
    warn(`restore failed: {reason}`)
end
```

A restore stamps `RestoredFrom = { VersionId, At }` into the profile's reserved `_Scribe` block, so a later read shows where the data came from. It needs a live key to write over: restoring a profile that was erased fails with `no live profile exists for this user to restore over`.

### Editing an offline profile

`UpdateOffline` mutates the **raw** profile table, the same shape `OnPlayerInit` receives, so declarator rules (bounds, enum members, `MaxLength`, element shapes) are not enforced there, though unpersistable values are still refused outright. Your callback runs against a copy, so one that errors partway commits nothing. It cannot create a profile: a user who has never joined returns `(false, "profile does not exist")`. Same-user calls on one server are serialized so they can't clobber each other, but two servers writing the same offline profile at once still can, so run backfills from one place. [Migrating to Scribe](./migrating#backfilling-offline-players) walks through the bulk-import version.

### GDPR export and erase

```lua
local json = Data.Export(userId) -- nil if missing, unreadable, or unencodable
if json then
    -- hand it to the requester through your own channel
end

local ok, reason = Data.Erase(userId)
if not ok then
    warn(`erase incomplete, retry: {reason}`)
end
```

Export first: `Erase` removes the live key outright, and `RestoreVersion` refuses afterwards because it has nothing to restore over. `Erase` deletes the profile and then the user's leaderboard entries; if the profile is gone but a leaderboard key survived, it returns `(false, reason)` so you retry. The whole call is idempotent, so retrying it is safe.

## Migrations

`Migrations` evolve your **own** Scribe data shape over time (this is not how you import from another data library; see [Migrating to Scribe](./migrating) for that). When your template changes, bump the version with a migration step. Migrations are **fail-closed**: if any step throws, nothing is stamped, nothing is saved, and the session ends with a kick. A half-migrated profile can never persist.

:::caution Template defaults are backfilled *before* your step runs
Scribe reconciles the stored data against the current template first, so every missing template key already holds its default by the time step 2 sees it. A step guarded on `if data.Field == nil`, or written as `data.Field = data.Field or 0`, therefore reads the default instead of the absence and silently does nothing for returning players. Key your steps off something the reconcile cannot manufacture: a field you removed from the template, or a value only stored data could hold.

Set `MigrationShadow = true` while you are writing a chain. Scribe then re-runs the same steps against the raw pre-reconcile bytes and warns under [`MIGRATION_RECONCILE_DEPENDENT`](./log-codes) wherever the two results diverge. It is opt-in, not automatic, and it **re-executes your migration bodies**, so keep them pure functions of `data` while it is on.
:::

```lua
Migrations = {
    -- Renaming Coins to Gems. `Coins` is gone from the template, so nothing
    -- backfills it and its presence is a real signal; `Gems` is in the template,
    -- so it already holds the default and has to be overwritten.
    [2] = function(data)
        if data.Coins ~= nil then
            data.Gems = data.Coins
            data.Coins = nil
        end
    end,
    [3] = function(data) data.Inventory = convertLegacy(data.Inventory) end,
},
```

Each profile stores the version its last successful run stamped, so **never renumber or remove a step you have shipped**: a profile stamped `3` resumes at step `4`, and repointing `3` at different code can no longer reach it. Following from that, the table has to be contiguous from `2` up to your highest key. A gap fails loudly at startup (`Scribe: Migrations table is missing step 3`) rather than being skipped.

One exception to fail-closed: a returning profile whose stored data is still nothing but current-template defaults is loaded un-migrated and left **unstamped** rather than kicked, because it has no stored progress to protect. Its chain retries on every join and lands as soon as the migration is fixed. It still logs `MIGRATION_FAIL` at Error, plus a Warn explaining the carve-out. The consequence for testing: a broken deploy kicks players with real progress while a barely-touched test account loads normally, so "my account loaded fine" is not evidence the step ran.

:::caution Staged deploys
During a rolling deploy, a player whose data a new server already migrated can land on a still-running old server. By default (`VersionAheadPolicy = "Kick"`) Scribe fails closed there too, refusing to run old code against newer-shaped data. When you ship a migration, shut down old servers so players don't bounce between kicking instances.
:::

## Coming from another data library?

If you're moving an existing game onto Scribe (from ProfileService, DataStore2, or a custom store), see [Migrating to Scribe](./migrating).

## Writing on the way out

`OnPlayerLeaving` is the counterpart to [`OnPlayerInit`](#onplayerinit). It runs **before the final save**, so whatever it writes persists. This is where the accumulate-on-exit pattern belongs:

```lua
Scribe({
    Template = template,
    ProfileStoreIndex = "PlayerData",
    ProfileKeyPrefix = "PLAYER_",

    OnPlayerLeaving = function(player, data, reason)
        local joined = joinedAt[player.UserId]
        if joined then
            data.Playtime.Increment(os.time() - joined)
        end
    end,
})
```

You get the same typed accessor as anywhere else, so writes are validated and bounded rather than dropped raw into the profile. `reason` is the usual [`LifecycleReason`](/api/Scribe#Reason), so you can skip expensive work on `shutdown` when the deadline is short.

Doing this from your own `Players.PlayerRemoving` handler instead is a race against Scribe's, decided by connection order, and a write that lands after teardown is silently lost.

Two limits on the hook:

- **It must not yield.** On shutdown it runs synchronously inside the drain loop, before the final save is spawned, against a single ~25 second budget shared by every player still in the server (Scribe's slice of Roblox's ~30 second `BindToClose`). One hook parked on a `task.wait` or a DataStore call delays every other player's final save. Do the async work during the session and only write here.
- **It does not run in every teardown.** It is skipped when the profile never reached Ready, and when another server steals the session mid-play (that path tears the entry down without a local leave, so no hook fires). Those are exactly the sessions an accumulate-on-exit counter would most want, so treat the hook as best-effort bookkeeping rather than the only place a value is ever written.

If the hook throws, the error is logged and the save continues. It costs you that hook's remaining writes, not the whole session.
