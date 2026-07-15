---
sidebar_position: 4
---

# Session Lifecycle

Profiles load asynchronously and save on a cadence. Knowing the lifecycle is the difference between smooth joins and mysterious "data for X is Loading" errors.

## Loading

Always wait for data before reading it:

```lua
Players.PlayerAdded:Connect(function(player)
    local data, reason = Data.WaitForData(player)
    if not data then
        -- reason is "load-failed" | "timeout" | "session-end"; the player is being kicked
        return
    end
    -- ...use data...
end)
```

| API                                              | Purpose                                                                      |
| ------------------------------------------------ | ---------------------------------------------------------------------------- |
| [`WaitForData(player)`](/api/Server#WaitForData) | Yields until Ready; returns `(accessor?, reason?)`. Handle the `nil` branch. |
| [`GetState(player)`](/api/Server#GetState)       | `"Loading" \| "Ready" \| "SessionEnded"`, without yielding.                  |

`Data[player]` and `Data.Get(player)` **error** while a profile is Loading. Use them only after `WaitForData`, or inside a [`Command`](/api/Server#Command) handler (which only runs once the caller is Ready).

### On the client

The client mirror never errors: accessor reads return **template defaults** until the first snapshot arrives, then `Observe`/`Changed` fire with the real values. For reactive UI, that's all you need. To gate one-shot startup logic, use [`Data.IsReady()`](/api/Client#IsReady) (non-yielding) or [`Data.WaitForData(timeout?)`](/api/Client#WaitForData), which yields until loaded and returns `false` if it times out (default 30s), so it never hangs:

```lua
if Data.WaitForData() then
    showMainMenu(Data.Coins.Get())
end
```

## Saving

Scribe autosaves each profile every `SaveInterval` seconds (default **300**; lower it to shrink the window of progress lost to a crash). It also saves on leave and on `BindToClose`. For a grant or purchase you don't want to lose, force a save:

```lua
Data.Purchase(player, spec)
Data.Flush(player, { Force = true })  -- persist immediately
```

`Flush` yields until the save finishes and returns whether it succeeded. `Force = true` also pushes the save through if the [wipe guard](./diagnostics#wipe-guard) had blocked it.

Observe save state for "Saving… / Saved ✓" UI:

```lua
Data.OnSave:Connect(function(info)
    -- { Player, Ok, Duration, At }
end)
local info = Data.GetSaveInfo(player) -- { LastSaveAt, LastResult, Dirty }
```

:::note Not-ready reads return defaults
`Owns`, `GetPurchases`, `GetGiftCredits`, and `GetSaveInfo` answer with `false`/`{}`/`{ Dirty = false }` while a profile is still Loading. Gate ownership logic behind `WaitForData` so a VIP owner isn't treated as a non-owner on join.
:::

## Session end

When a session ends (leave, or a session stolen by another server), [`SessionEnded`](/api/Server#SessionEnded) fires with `(player, reason)`. With `KickOnSessionEnd = true` (the default) the player is also kicked, so their client can't keep acting on stale data.

## Batching and transactions

By default each write replicates on the next frame. Two server helpers change that for a burst of writes:

- **`Batch`** coalesces every write inside it into a **single replication flush and one `Changed` pass**, so the client gets one update instead of many. Reach for it on bulk updates.
- **`Transaction`** runs writes **atomically**: if the function throws, every write inside is rolled back and it returns `(false, error)`; on success it returns `(true, nil)`. A transaction also batches, so it is already a single flush.

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
Data.SendMessage(recipientUserId, { Kind = "TradeOffer", Item = "Sword_001" })

-- recipient's server
Data.OnMessage:Connect(function(player, message)
    if message.Kind == "TradeOffer" then
        -- ...
    end
end)
```

Messages ride ProfileStore's global-update channel, so keep them small and infrequent (this is for coordination, not chat). Scribe's own gift delivery uses the same channel with a separate tag, so the two never collide.

### The ProfileStore escape hatch

For the rare store-level operation Scribe doesn't wrap (version reads, raw `MessageAsync`, and so on), [`Data.ProfileStore`](/api/Server#ProfileStore) exposes the underlying ProfileStore instance. It **bypasses Scribe's schema, replication, and session guarantees**, so treat it as read-mostly and never mutate an active-session profile through it. Most games never need it; prefer the typed API and `SendMessage`.

## Migrations

`Migrations` evolve your **own** Scribe data shape over time (this is not how you import from another data library; see [Migrating to Scribe](./migrating) for that). When your template changes, bump the version with a migration step. Migrations are **fail-closed**: if any step throws, nothing is stamped, nothing is saved, and the session ends with a kick. A half-migrated profile can never persist.

```lua
Migrations = {
    [2] = function(data) data.Gems = data.Gems or 0 end,
    [3] = function(data) data.Inventory = convertLegacy(data.Inventory) end,
},
```

:::caution Staged deploys
During a rolling deploy, a player whose data a new server already migrated can land on a still-running old server. By default (`VersionAheadPolicy = "Kick"`) Scribe fails closed there too, refusing to run old code against newer-shaped data. When you ship a migration, shut down old servers so players don't bounce between kicking instances.
:::

## Coming from another data library?

If you're moving an existing game onto Scribe (from ProfileService, DataStore2, or a custom store), see [Migrating to Scribe](./migrating).
