---
sidebar_position: 11
---

# Migrating to Scribe

Moving an existing game onto Scribe. How you do it depends on where your data lives today.

:::note "Migration" means two different things
This page is about bringing an **existing game's data into Scribe**. It is _not_ the same as the [`Migrations` option](./lifecycle#migrations), which evolves your _own_ Scribe template across versions once you're already on Scribe. Don't reach for `Migrations` to import from another library.
:::

## From ProfileStore → adopt in place

Scribe sits directly on ProfileStore, so a game already using ProfileStore adopts Scribe **in place** with no data copy and no conversion. Point Scribe at the same store and your existing profiles load exactly as they are:

1. Set `ProfileStoreIndex` and `ProfileKeyPrefix` to match your current store name and key prefix.
2. Existing profiles load unchanged. `Data` is the template root, and the ProfileStore envelope (session metadata, `UserIds`, `GlobalUpdates`) is untouched.
3. `Reconcile` fills any newly added template fields; use `Migrations` to reshape anything whose structure changed.

```lua
return Scribe({
    Template = template,
    ProfileStoreIndex = "PlayerData", -- your existing store name
    ProfileKeyPrefix = "Player_",      -- your existing key prefix
})
```

Your template's field names must match the keys already in the stored data (or a migration bridges the difference). **Test against a copy first** with `DontSave = true` (loads real data, never writes) or `ViewedUserId` before you point a live game at it.

### Coming from ProfileService

ProfileStore is ProfileService's successor (same author), and it reads existing ProfileService profiles from the same keys with no conversion, so a ProfileService game adopts Scribe in place exactly like a ProfileStore one. Treat the switch as one-directional, though: once Scribe starts writing global updates through ProfileStore, the old ProfileService module may no longer load those same profiles. Run a Studio test with API access enabled before you ship the change.

## From DataStore2, a custom store, or anything else → read and seed

Other systems store data in a completely different layout, so there's no "point Scribe at it": you read each player's old data out once and write it into Scribe. There's no built-in importer (Scribe can't guess your old schema), but the hook is built for exactly this: **`OnPlayerInit`** runs on load, before the session goes Ready, receives the raw profile data, and is allowed to yield.

Add a one-time guard flag to your template, then import in `OnPlayerInit`:

```lua
local template = {
    Coins = 0,
    Inventory = {} :: { [string]: any },
    LegacyImported = false, -- the guard
}

return Scribe({
    Template = template,
    ProfileStoreIndex = "PlayerData",
    ProfileKeyPrefix = "PLAYER_",
    OnPlayerInit = function(player, data)
        if data.LegacyImported then
            return -- already imported; never run twice
        end

        local old = MyOldStore:Get(player)      -- read the legacy store (may yield, which is fine here)
        if old then
            data.Coins = old.coins
            data.Inventory = convertOldInventory(old.inventory)
        end

        data.LegacyImported = true
    end,
})
```

`OnPlayerInit` mutates the raw data **before** the player can touch it, so the first Ready state already reflects the imported values. The `LegacyImported` flag makes re-loads safe: the import only ever happens on a player's first Scribe load.

:::caution Preserve timestamps yourself instead of relying on the store's metadata
Values like a **first-join date** belong in a field of _your_ template, not in a store-specific timestamp. ProfileStore's `FirstSessionTime` is stamped when the profile is first _created_. For a game moving over, that's the migration moment. It's also read-only, so it can't be backdated (and Scribe doesn't surface it anyway). Owning the field means you carry the real date across from your old store, and it survives any future move:

```lua
FirstJoined = 0, -- in your template

OnPlayerInit = function(player, data)
    if data.LegacyImported then return end
    local old = MyOldStore:Get(player)
    -- real date from the old store, or now for genuinely new players
    data.FirstJoined = (old and old.firstJoined) or os.time()
    -- ...copy the rest...
    data.LegacyImported = true
end
```

:::

## Backfilling offline players

Most migrations never need this. With the read-and-seed approach above, every player is imported automatically the next time they log in, so you can leave the old store in place and let it drain on its own.

The one time you'd reach for a batch job is retiring the old store for good: before you can stop reading it, you have to import the stragglers who haven't logged in since the cutover. [`Data.UpdateOffline`](/api/Server#UpdateOffline) edits a profile that has no active session and **fails closed** if the user happens to be online elsewhere, so it can never clobber a live game:

```lua
for _, userId in userIdsToImport do
    local old = MyOldStore:Get(userId)
    if old then
        Data.UpdateOffline(userId, function(data)
            if not data.LegacyImported then
                data.Coins = old.coins
                data.LegacyImported = true
            end
        end)
    end
end
```

## Tips

- **Keep the legacy store readable** until you're confident. Don't delete old data the moment you cut over. The guard flag means a re-run is harmless.
- **Convert shapes explicitly**: copy field by field into your Scribe template rather than assigning the whole old table, so the result matches your declarators.
- **Dry-run first** with `DontSave = true`, or against a throwaway `ProfileStoreIndex`, before touching production.
