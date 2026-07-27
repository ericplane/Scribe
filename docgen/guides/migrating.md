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

1. Set `ProfileStoreIndex` and `ProfileKeyPrefix` to match your current store name and key prefix. If your keys were the bare user id with no prefix at all, set `ProfileKeyPrefix = ""`.
2. Existing profiles load unchanged. `Data` is the template root, and the ProfileStore envelope (session metadata, `UserIds`, `GlobalUpdates`) is untouched.
3. New template fields fill in on load; `Migrations` reshape anything whose structure changed.

```lua
return Scribe({
    Template = template,
    ProfileStoreIndex = "PlayerData", -- your existing store name
    ProfileKeyPrefix = "Player_",      -- your existing key prefix ("" if there was none)
})
```

The prefix must match your existing keys exactly, because it is concatenated with the user id to form the key. Point Scribe at `"Player_"` when your stored keys are bare user ids and every player loads a blank profile, since `Player_123` is simply a different key from `123`.

:::danger Never build the ProfileStore envelope yourself
Do not copy old data in by writing DataStore values directly, for example `SetAsync(key, { Data = old, MetaData = {}, GlobalUpdates = {0, {} } })`. ProfileStore treats any value whose `Data`, `MetaData` and `GlobalUpdates` are all tables as a real profile and leaves that `MetaData` untouched, so the fields it would otherwise fill in are never added. Missing `MetaData.SessionLoadCount` is the one that bites: the next load throws `attempt to perform arithmetic (add) on nil and number` from `EditProfile`.

**The key does not heal itself.** The error is raised inside the DataStore transform, so nothing is ever written back, every retry reads the same broken value, and the player is stuck in a join loop. Scribe reports this as a `PROFILE_STORE_ERROR` with an opaque message, because Roblox traps transform errors before ProfileStore can see them.

Neither `UpdateOffline` nor `RestoreVersion` can repair such a key. Both write through a path that never sets `SessionLoadCount`, so they report success and the key still fails on the next join. Use [`Erase(userId)`](/api/Server#Erase), which deletes the key outright so the next join builds a correct profile, and re-import from your old store. Let ProfileStore create the profile and write your old data into `Data` afterwards, or adopt the existing keys in place as above.
:::

Your template's field names must match the keys already in the stored data (or a migration bridges the difference). **Validate against real data first** with `ViewedUserId` (loads that user's real profile read-only, never writes) before you point a live game at it. Note that `DontSave = true` is NOT a dry-run against real data: it swaps in a full in-memory mock store, so every profile loads as blank template defaults and validates nothing about your stored shapes.

A `ViewedUserId` dry-run checks your **template** against real stored data, not the **envelope** around it. It reads through `GetAsync`, which skips the session-start code that a normal join runs, so a malformed envelope like the one above reads back perfectly clean and only fails once a real player joins. A clean dry-run means your field names and shapes line up; it is not evidence that the profiles are loadable.

:::caution Adopting in place while you already have `Migrations`
Scribe stores its migration version under the reserved `_Scribe` root. Data written before you adopted Scribe has no such key, so it reads as **version 1** and every migration step from 2 upward then runs against your pre-Scribe shape on first load. Migration failure is fail-closed, so a step that throws kicks the player rather than loading them with half-migrated data. If you adopt in place while already carrying a `Migrations` table, make sure step 2 tolerates legacy input, or bridge the old shape in step 1 first.
:::

:::note Adding a field to a container element later
Add a field to an existing [`Scribe.ArrayOf` or `Scribe.DictOf`](./templates#typed-containers) element shape and Scribe fills it into every stored entry on load, just as it fills a new top-level field. This runs **after** your `Migrations`, so a rename migration still sees the old entry before any default lands. `Scribe.Optional` fields have no default, so they stay absent.
:::

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
Values like a **first-join date** belong in a field of _your_ template. ProfileStore's `FirstSessionTime` is stamped when the profile is first _created_, which for a game moving over is the migration moment, and it is read-only so it cannot be backdated (Scribe doesn't surface it either). Own the field and you carry the real date across from your old store, and keep it through any future move:

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

### Seeding into a typed container

Importing into a [`Scribe.ArrayOf` or `Scribe.DictOf`](./templates#typed-containers) works the same way, with one rule: `OnPlayerInit` hands you the raw profile table, which does **not** pack datatypes for you. Write a datatype element as a packed buffer with [`Scribe.Datatypes.Pack`](/api/Scribe#Datatypes):

```lua
Placed = Scribe.ArrayOf({
    Cf = Scribe.CFrame(CFrame.new()),
    Id = Scribe.String("", { MaxLength = 32 }),
}),

OnPlayerInit = function(player, data)
    if data.LegacyImported then return end
    local old = MyOldStore:Get(player)
    if old then
        local placed = {}
        for _, o in old.placedObjects do
            table.insert(placed, {
                Cf = Scribe.Datatypes.Pack("CFrame", CFrame.new(o.x, o.y, o.z)),
                Id = o.itemId,
            })
        end
        data.Placed = placed
    end
    data.LegacyImported = true
end,
```

Forget the `Pack` and the raw `CFrame` is flagged `PROFILE_UNPERSISTABLE` at load, and would fail the profile's next save. Once imported, `data.Placed[1].Cf.Get()` is a real `CFrame`, packed and unpacked for you from then on. Writing through the accessor tree instead of the raw table (as normal gameplay does) packs automatically, so this only comes up on the import path.

## Backfilling offline players

Most migrations never need this. With the read-and-seed approach above, every player is imported automatically the next time they log in, so you can leave the old store in place and let it drain on its own.

[`Data.UpdateOffline`](/api/Server#UpdateOffline) edits a profile that has no active session, and **fails closed** if the user is online elsewhere, so it can never clobber a live game. Your callback runs against a copy, so one that errors partway commits nothing. Always check its return value:

```lua
for _, userId in userIdsToImport do
    local old = MyOldStore:Get(userId)
    if old then
        local ok, err = Data.UpdateOffline(userId, function(data)
            if not data.LegacyImported then
                data.Coins = old.coins
                data.LegacyImported = true
            end
        end)
        if not ok then
            warn(`import failed for {userId}: {err}`)
        end
    end
end
```

:::caution It cannot create a profile
`UpdateOffline` edits data that already exists. A player who has never logged in since the cutover has no Scribe profile yet, so the call returns `(false, "profile does not exist")` and writes nothing. That is precisely the population a "retire the old store" batch job targets, so a batch job cannot finish the migration on its own. Keep the read-and-seed path above in place until those players log in, or accept that they import on first join.
:::

## Tips

- **Keep the legacy store readable** until you're confident. Don't delete old data the moment you cut over. The guard flag means a re-run is harmless.
- **Convert shapes explicitly**: copy field by field into your Scribe template rather than assigning the whole old table, so the result matches your declarators. Nothing on the raw import path checks that for you: `OnPlayerInit` and [`Data.UpdateOffline`](/api/Server#UpdateOffline) mutate the profile table directly, so bounds, enum members, `MaxLength`, and `ArrayOf` / `DictOf` element shapes are all unenforced there, and a mismatch surfaces as a wrong-typed read later rather than an error at the write.
- **Storability *is* checked.** Invalid UTF-8, a NaN/inf number, a table mixing array indices with string keys, or a raw Roblox datatype (see [above](#seeding-into-a-typed-container)) is reported as `PROFILE_UNPERSISTABLE` on load and refused outright by `UpdateOffline`.
- **Dry-run first** with `ViewedUserId`, or against a throwaway `ProfileStoreIndex` seeded with copies, before touching production. `DontSave = true` is not a dry-run: it swaps in an in-memory mock store, so nothing you see there came from real data.
