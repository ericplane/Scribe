# Migrating to Scribe

This page is about moving a game that already has live player data onto Scribe. How you do it depends entirely on where that data lives today. If it is in ProfileStore or ProfileService, you adopt it in place and copy nothing. If it is anywhere else, you read each player's old record once and write it into Scribe on their next join.

???+ note "Two different things are called migration"
    This page covers bringing an **existing game's data into Scribe**.

    That is not the same as the [`Migrations` option](./lifecycle#migrations), which evolves your **own** Scribe template across versions once you are already on Scribe. Do not reach for `Migrations` to import from another library.

## Already on ProfileStore: adopt in place

Scribe sits directly on ProfileStore, so a game already using ProfileStore adopts Scribe with no data copy and no conversion at all. Point Scribe at the same store and your existing profiles load exactly as they are.

```lua
return Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData", -- your existing store name
    ProfileKeyPrefix = "Player_",              -- your existing key prefix
})
```

Three things follow from that. Existing profiles load unchanged, and the ProfileStore envelope around them, meaning session metadata, `UserIds` and `GlobalUpdates`, is untouched. New template fields fill in on load. Anything whose structure changed is reshaped by a `Migrations` step.

The prefix must match your existing keys **exactly**, because it is concatenated with the user id to form the key. If your keys were bare user ids with no prefix, write `ProfileKeyPrefix = ""`. Point Scribe at `"Player_"` when your stored keys are bare ids and every player loads a blank profile, because `Player_123` is simply a different key from `123`.

Your template's field names must match the keys already in the stored data, or a migration must bridge the difference. So before you point a live game at it, do a dry run.

## The dry run

`Mode = "NoSave"` loads a real profile as a snapshot and never writes it. No session is held, no save path runs, and leaderboard writes go to a mock store. Add `TargetUserId` to pin one specific player.

```lua
return Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "Player_",

    Mode = "NoSave",
    TargetUserId = 101,     -- load Ava's real profile, read-only
    SchemaPolicy = "Warn",  -- report every mismatch instead of refusing
})
```

Pair it with `SchemaPolicy = "Warn"` the first time, never `"Reject"`. The stored-shape check then reports everything about the imported data that does not match your template, and `"Warn"` lets you read that as a list rather than meeting one item at a time.

`Mode = "Mock"` is **not** a dry run against real data. It swaps in a full in-memory mock store, so every profile loads as blank template defaults and validates nothing about your stored shapes.

??? note "What a clean dry run does and does not prove"
    A `NoSave` run checks your **template** against real stored data. It does not check the **envelope** around that data. It reads through `GetAsync`, which skips the session-start code a normal join runs, so a malformed envelope reads back perfectly clean and only fails once a real player joins.

    Some of what `SchemaPolicy` reports is advisory and would not kick anyone even under `"Reject"`: containers over a `MaxKeys` you have only just declared, and arrays with holes in them. Old data had no reason to avoid either. Imported data is also exactly where the findings that **do** reject turn up, though: a table mixing array indices with string keys, a wrong type, a value outside a bound you have just added.

!!! danger "Never build the ProfileStore envelope yourself"
    Do not copy old data in by writing DataStore values directly, for example `SetAsync(key, { Data = old, MetaData = {}, GlobalUpdates = {0, {} } })`. ProfileStore treats any value whose `Data`, `MetaData` and `GlobalUpdates` are all tables as a real profile and leaves that `MetaData` untouched, so the fields it would otherwise fill in are never added. Missing `MetaData.SessionLoadCount` is the one that bites: the next load throws `attempt to perform arithmetic (add) on nil and number` from `EditProfile`.

    **The key does not heal itself.** The error is raised inside the DataStore transform, so nothing is ever written back, every retry reads the same broken value, and the player is stuck in a join loop. Scribe reports this as a `PROFILE_STORE_ERROR` with an opaque message, because Roblox traps transform errors before ProfileStore can see them.

    Neither `UpdateOffline` nor `RestoreVersion` can repair such a key. Both write through a path that never sets `SessionLoadCount`, so they report success and the key still fails on the next join. Use [`Erase(userId)`](/api/Server#Erase), which deletes the key outright so the next join builds a correct profile, then re-import from your old store. That is the GDPR erasure path, so it also clears the user from every leaderboard, and a `false` return can mean the profile went but a board key did not. Retry rather than assuming nothing happened.

!!! warning "Adopting in place while you already have Migrations"
    Scribe stores its migration version under the reserved `_Scribe` root. Data written before you adopted Scribe has no such key, so it reads as **version 1**, and every migration step from 2 upward then runs against your pre-Scribe shape on first load. Migration failure is fail-closed, so a step that throws kicks the player rather than loading them with half-migrated data.

    If you adopt in place while already carrying a `Migrations` table, **step 2 itself must tolerate legacy input**. There is no step 1 to bridge in: keys below 2 are rejected at startup with `Scribe: Migrations keys must be integers >= 2`. `OnPlayerInit` cannot pre-bridge either, because it runs after the migration chain.

### Coming from ProfileService

ProfileStore is ProfileService's successor, by the same author, and it reads existing ProfileService profiles from the same keys with no conversion. So a ProfileService game adopts Scribe in place exactly like a ProfileStore one.

Treat the switch as one-directional. Once Scribe starts writing global updates through ProfileStore, the old ProfileService module may no longer load those same profiles. Run a Studio test with API access enabled before you ship the change.

## Coming from anything else: import on first load

DataStore2, a hand-rolled store, or any other library keeps data in a layout Scribe cannot guess, so there is nothing to point at. You read each player's old record once and hand it back. The hook built for this is **`ImportLegacyData`**. It receives the player and the user id Scribe is loading, it is allowed to yield, and it returns a plain table of top-level keys for Scribe to adopt.

```lua
local template = {
    Coins = Scribe.Int(0, { Min = 0 }),
    Gems  = Scribe.Int(0, { Min = 0 }),
    Xp    = Scribe.Int(0, { Min = 0 }),
    Inventory = Scribe.DictOf({
        Qty    = Scribe.Int(1, { Min = 1, Max = 999 }),
        Rarity = Scribe.Enum("Common", RARITIES),
    }, { MaxKeys = 200 }),
}

return Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",

    ImportLegacyData = function(player, userId)
        local old = OldEmberfallStore:Get(userId) -- may yield, which is fine here
        if old == nil then
            return nil -- nothing to carry over, so treat them as a new player
        end

        return {
            Coins = old.coins,
            Gems = old.gems,
            Xp = old.xp,
            Inventory = convertOldBag(old.bag),
        }
    end,
})
```

There is no guard field, and nothing to add to your template for one. Scribe decides whether to run the hook from its own save history rather than from a value in your data, so it runs only for a player Scribe has never completed a save for. If the load fails, or the player leaves before that first save lands, the next join tries again.

The adopted keys are written before everything else the load does, and that ordering is the whole reason to use the hook rather than copying the record in yourself. Reconcile fills in every template field the old library never had, integer map keys are coerced to the type you declared, the profile enters the migration chain at version 1 and runs every step you have written, and the stored-shape check reads the imported values on the load that imported them. The player is also not reported as new to `OnPlayerInit`, so a starter kit gated on `isNewProfile` does not land on top of an imported inventory.

Pair the cutover with `SchemaPolicy = "Warn"`, for the same reason you paired the dry run with it. Every imported value that does not match a declarator is then listed on the load that imported it.

!!! danger "Return nil only when you know there is nothing to carry"
    `nil` means "this player has nothing in the old store", and Scribe acts on it by loading them as a new player. If your read failed and you cannot tell which it was, **throw**. The two answers are indistinguishable to Scribe, and only one of them is safe to act on.

    A throw refuses the load. Scribe releases the profile, kicks the player with your `LoadFailureMessage`, counts `LegacyImportFailures` and logs `LEGACY_IMPORT_FAIL`. The next join imports normally, because a refused load records no completed save against that key. Returning `nil` from a read that failed does the opposite: the player loads empty, their first save makes that emptiness canonical, and the import never runs for them again.

Scribe never adopts a top-level key beginning with `_Scribe`. That covers the reserved `_Scribe` root, which holds purchase dedupe ids, gift escrow, granted perks, `Scribe.Timed` deadlines and the migration version, and it covers `_ScribeSession`, which is rebuilt every session. Every other key in the table you return is copied straight in.

!!! warning "Do not combine an import with adopting in place"
    `ImportLegacyData` decides whether a player is new to Scribe by asking whether a completed save has ever recorded a user id against their key. A profile written by a library that never recorded one carries no such mark, so it reads as never saved and the hook fires for a genuine returning player on their first join after the cutover. Whatever your importer returns is then written straight over the top-level keys they already had.

    Pick one path per store. Adopt in place when the data is already in ProfileStore or ProfileService, and use `ImportLegacyData` when it lives somewhere Scribe cannot read.

??? warning "Three ways an import quietly does nothing"
    **A return value that is neither a table nor `nil` is discarded**, with no log and no counter. An importer that ends in `return true`, or that hands its values back in the wrong order, looks exactly like an ordinary new player.

    **An empty table still counts as an import.** The profile runs the whole migration chain from version 1 and the player is not reported as new to `OnPlayerInit`, neither of which is what you want for someone who had nothing. Return `nil`, not `{}`.

    **A key your template does not declare is stored but unreadable.** `data.Coins.Get()` hands back the template default while `LEGACY_IMPORTED` reports the key as adopted. Only DevMode names it, as `UNKNOWN_ROOT_KEYS`. A lowercase `coins` where the template says `Coins` is the usual way in.

??? note "When the hook does not run"
    Scribe skips the import for a player whose profile has already completed a save, under `ResetData`, and under `Mode = "NoSave"`. None of the three is logged, so an import that appears to do nothing on an account you have already tested with is almost always the first of them. [`Data.Erase(userId)`](/api/Server#Erase) deletes the key outright, so the next join imports again, which is how you retry against a **test** account. Never do that to a live one: it clears them from every leaderboard, and anything they earned since the cutover goes with it.

    `Mode = "Mock"` does **not** skip the hook. Your importer still runs and still reads your old store, so give it its own guard if that read costs a request you would rather not spend in tests.

??? warning "Your declarators are not enforced on the table you return"
    Bounds, enum members, `MaxLength`, and `ArrayOf` or `DictOf` element shapes are all unenforced on imported values, and the same is true inside [`Data.UpdateOffline`](/api/Server#UpdateOffline) and `Migrations` bodies. A mismatch surfaces later as a wrong-typed read rather than as an error at the write, so build the table field by field rather than handing back the old record whole.

    Storability **is** checked. Invalid UTF-8, a NaN or infinite number, a table mixing array indices with string keys, or a raw Roblox datatype is reported as `PROFILE_UNPERSISTABLE` on load and refused outright by `UpdateOffline`. From inside a `Migrations` step the same value is `MIGRATION_FAIL` instead, which is fail-closed and kicks the player.

??? note "Carry your own first-join date"
    A value like a first-join date belongs in a field of **your** template. ProfileStore's `FirstSessionTime` is stamped when the profile is first created, which for a game moving over is the migration moment, and it is read-only so it cannot be backdated. Scribe does not surface it either.

    Own the field and you carry the real date across from your old store, and keep it through any future move:

    ```lua
    FirstJoined = 0, -- in your template

    ImportLegacyData = function(player, userId)
        local old = OldEmberfallStore:Get(userId)
        if old == nil then
            return nil
        end
        return {
            -- the real date from the old store, not the moment they moved over
            FirstJoined = old.firstJoined or os.time(),
            -- carry the rest here
        }
    end,
    ```

??? note "If you already shipped the OnPlayerInit recipe"
    An earlier version of this page imported inside `OnPlayerInit`, guarded by a `LegacyImported` field in the template. Move the read into `ImportLegacyData`, and delete the old hook body and the template field in the same change.

    Leaving both in place is worse than either alone. The two hooks fire on the same load, `ImportLegacyData` adopts the record first, Reconcile then backfills `LegacyImported` to its declared default of `false`, and your old importer reads that `false` and imports a second time over the fresh data.

    Nobody needs backfilling. Players who already imported under the old recipe have completed a save, so the new hook skips them.

### Seeding a datatype into a typed container

Importing into a typed container works the same way, with one rule: the table you hand back does **not** pack datatypes for you. Say Emberfall also stores the objects a player has placed at their camp:

```lua
Camp = Scribe.ArrayOf({
    Cf = Scribe.CFrame(CFrame.new()),
    Id = Scribe.String("", { MaxLength = 32 }),
}, { MaxItems = 100 }),

ImportLegacyData = function(player, userId)
    local old = OldEmberfallStore:Get(userId)
    if old == nil then
        return nil
    end

    local placed = {}
    for _, o in old.campObjects do
        table.insert(placed, {
            Cf = Scribe.Datatypes.Pack("CFrame", CFrame.new(o.x, o.y, o.z)),
            Id = o.itemId,
        })
    end
    return { Camp = placed }
end,
```

Forget the `Pack` and the raw `CFrame` is flagged `PROFILE_UNPERSISTABLE` at load, and would fail the profile's next save. Once imported, `data.Camp[1].Cf.Get()` is a real `CFrame`, packed and unpacked for you from then on. Writing through the accessor tree, as normal gameplay does, packs automatically. This only comes up where you touch stored data directly: `ImportLegacyData`, `OnPlayerInit`, [`UpdateOffline`](/api/Server#UpdateOffline), and [`Migrations`](./lifecycle#migrations) bodies.

??? note "Adding a field to a container element later"
    Add a field to an existing `Scribe.ArrayOf` or `Scribe.DictOf` element shape and Scribe fills it into every stored entry on load, just as it fills a new top-level field. This runs **after** your `Migrations`, so a rename migration still sees the old entry before any default lands. `Scribe.Optional` fields have no default, so they stay absent.

## Backfilling offline players

Most migrations never need this. With the import hook above, every player is carried over automatically the next time they log in, so you can leave the old store in place and let it drain on its own.

If you do want to push the import out, [`Data.UpdateOffline`](/api/Server#UpdateOffline) edits a profile that has no active session. It **fails closed** if the user is online elsewhere, so it can never clobber a live game, and the commit is a compare-and-set, so a refusal writes nothing and two jobs racing the same key cannot overwrite each other. Your callback runs against a copy, so one that errors partway commits nothing. Always check the return value:

```lua
for _, userId in userIdsToImport do
    local old = OldEmberfallStore:Get(userId)
    if old then
        local ok, err = Data.UpdateOffline(userId, function(data)
            data.Coins = old.coins
        end)
        if not ok then
            warn(`import failed for {userId}: {err}`)
        end
    end
end
```

The loser of a race gets `"profile changed while the update was being prepared"` and should retry against a fresh read.

One overlap to know about if you run this against a store you have already cut over. `UpdateOffline` edits the key without recording a completed save, and a completed save is exactly what tells the import hook a player has already been carried over. So a player whose first Scribe session ended before its save landed still counts as un-imported, and the hook overwrites your backfill on their next join. That is harmless when both read the same old record, and it is data loss when the backfill was the more recent of the two.

??? warning "UpdateOffline cannot create a profile"
    It edits data that already exists. A player who has never logged in since the cutover has no Scribe profile yet, so the call returns `(false, "profile does not exist")` and writes nothing.

    That is precisely the population a "retire the old store" batch job targets, which means a batch job cannot finish the migration on its own. Keep the import hook in place until those players log in, or accept that they are carried over on first join.

## Upgrading Scribe itself

These are the changes in recent releases that need something from you. Everything not listed here is backward compatible.

### WaitForData gained a still-loading reason

`LifecycleReason` has a seventh member, `still-loading` (`Scribe.Reason.StillLoading`), and `WaitForData` now returns it where it previously returned `timeout`: the case where the wait elapsed while the profile was **still loading**. `timeout` is still returned, and now means only that Scribe has no session for that player at all.

Nothing else changed. There is no new call, no new option, and the wait is bounded exactly as before. If your code branches on the reason, check it:

```lua
local data, reason = Data.WaitForData(player)
if not data then
    -- BEFORE: this caught both cases.
    if reason == "timeout" then retryOrKick(player) end

    -- AFTER: a load still in flight is very likely to succeed, so it is
    -- worth waiting for rather than kicking over.
    if reason == Scribe.Reason.StillLoading then
        data = Data.WaitForData(player, 60)
    elseif reason == Scribe.Reason.Timeout then
        retryOrKick(player)
    end
end
```

Code that only tests `if not data then` is unaffected. See [Session Lifecycle](./lifecycle#when-there-is-no-data) for why the split exists.

### Profile.LastSavedData is released after each save

This only matters if you reach through the [`Data.ProfileStore`](/api/Server#ProfileStore) escape hatch and read `LastSavedData` off a live profile. Scribe now tells the store to stop retaining it, because it holds the decoded response of every save, a second full copy of the profile, for the whole session. Scribe needs only a summary, which top-level keys it had and its size, and records that itself as each save lands. After the first successful save of a session the field is an empty table.

`WipeGuardPolicy = "Block"` keeps the full copy, because that policy writes those bytes back as the save payload.

Nothing in Scribe's own API changes. For the size of the last save, use [`Data.GetSaveInfo(player)`](/api/Server#GetSaveInfo) and read its `Size`, which is maintained for exactly this and costs nothing.

### Cooldown keys starting with @ are reserved

`Data.OnCooldown`, `Data.PeekCooldown` and `Data.ClearCooldown` now raise on a key beginning with `@`. Scribe keeps its own idempotency claims in the same store, so that namespace was shared by accident. Lapsed claims arrived at `OnCooldownEnded` wearing keys the game never set, and `Data.ClearCooldown(player, "@pi|...")` could clear a purchase claim, which is the one operation that lets a retry apply a purchase twice.

Almost nothing is affected, because `@` is a strange first character for a cooldown key. If you use one, rename it. A game already colliding with `@pi|` was sharing a namespace with real money.

### Failure logs are folded

Repeated failures of one subject inside the retry window now produce **one** log entry rather than one per attempt, matching the rule the health status machine already used. Alerting that counted `PROFILE_STORE_ERROR` or `PROFILE_LOAD_FAIL` entries to gauge severity should read the `HealthFailures` or `DataStoreErrors` counters instead, which still count every attempt, or read `Context.Repeats` on the folded entry. See [Log codes](./log-codes#repeated-failures-are-folded).

Three failures that previously logged nothing now do: `OFFLINE_WRITE_FAIL`, `PROFILE_RESTORE_FAIL` and `PROFILE_ERASE_FAIL`, all at `Warn`, so `Scribe.OnIssue` is unaffected.

## Where to next

- [Session Lifecycle](./lifecycle) covers `Migrations`, the option that evolves your template once you are on Scribe.
- [Testing](./testing) has the full `Mode` table behind the dry run above.
- [Configuration](./configuration) lists `SchemaPolicy`, `BoundsPolicy`, and everything else you will set during a cutover.
- [Diagnostics](./diagnostics) is where `PROFILE_UNPERSISTABLE` and friends show up while you are watching an import.
