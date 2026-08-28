# Offline Profiles

Sooner or later you have to act on a player who is not in front of you. A support ticket says Ben's inventory vanished. A GDPR request arrives. A template change needs backfilling across every profile you have ever written. All of those work on the stored profile rather than a live session.

Everything on this page takes a `userId` rather than a `Player`, and **every one of these calls yields**, so run them from a [`Command`](/api/Server#Command) handler, an admin panel, or a batch task, never from a per-frame path.

## Reading a stored profile

```lua
local snapshot = Data.GetOffline(ben.UserId)
if snapshot then
    print(`Ben has {snapshot.Coins} coins and is level {snapshot.Level}`)
end
```

[`GetOffline`](/api/Server#GetOffline) hands back a read-only snapshot of the raw profile table. It is the raw shape, not the accessor tree, so you read `snapshot.Coins` rather than `snapshot.Coins.Get()`.

[Derived fields](./derived) are filled in over the snapshot for you, which is why `snapshot.Level` is there even though nothing ever stored it. A derived field is filled whenever all of its inputs persist, and Emberfall's `Level` reads `Xp`, which does.

## The seven operations

| API | Returns | What it does |
| --- | --- | --- |
| [`GetOffline(userId)`](/api/Server#GetOffline) | `data?` | Read-only snapshot of the raw profile table. |
| [`UpdateOffline(userId, fn)`](/api/Server#UpdateOffline) | `(ok, reason?)` | Runs `fn(data)` against a copy of the raw profile and saves it. |
| [`ListVersions(userId, limit?)`](/api/Server#ListVersions) | `{ { VersionId, CreatedAt, Size } }` | Version history, newest first, up to `limit` (25 by default). `CreatedAt` is Unix seconds. |
| [`GetVersion(userId, versionId)`](/api/Server#GetVersion) | `data?` | The raw data of one historical version, for inspection or diffing. |
| [`RestoreVersion(userId, versionId, opts?)`](/api/Server#RestoreVersion) | `(ok, reason?)` | Rolls the live key back to that version. |
| [`Export(userId)`](/api/Server#Export) | `json?` | The profile as a JSON string, with buffers base64-encoded. |
| [`Erase(userId)`](/api/Server#Erase) | `(ok, reason?)` | Deletes the profile and the user's leaderboard entries. |

The [Scribe Studio](./studio-plugin) wraps the same operations in a Production panel when you would rather click than write a command.

## The session lock

Every **write** here (`UpdateOffline`, `RestoreVersion`, `Erase`) **fails closed** when the user has a live session, whether on this server or any other, and returns `(false, reason)` saying which. None of them steal a live lock, because that would evict a player from the server they are actually playing on.

So the operational order for a support ticket is: get the player out of the game, then act, then let them rejoin.

For `UpdateOffline` and `RestoreVersion` the check and the write are a single compare-and-set, so there is no window between them in which a session can appear. All three treat a session whose last write is older than the store's dead-session threshold of 630 seconds as **dead** and proceed, because otherwise a crashed server would lock a profile out of all three forever. A healthy server autosaves every 300 seconds, so 630 seconds of silence is two missed autosaves.

??? note "Why `Erase` is the one that can still lose a race"
    `Erase` is two operations by necessity, because no DataStore primitive deletes conditionally. A session that starts between its check and its `RemoveAsync` still loses.

    That outcome is the intended one. The erase completes, and the session it interrupts is one whose data was being deleted anyway. That session is released cleanly rather than left holding a key that no longer exists.

    `RestoreVersion` and `Erase` additionally refuse while [service health](./diagnostics) reports an outage.

??? note "Reads do not fail closed, and `nil` is ambiguous"
    `GetOffline` returns a clone of the live data when that user is already Ready on *this* server, and otherwise reads the DataStore directly. For a player active on *another* server that is the last committed bytes rather than what they are looking at right now. `Export` reads through it and inherits the same behaviour.

    It returns `nil` both for a profile that does not exist and for a read that errored, and only the `OFFLINE_READ_FAIL` [log entry](./log-codes) tells the two apart. `GetVersion` behaves the same way and logs `VERSION_READ_FAIL`. `ListVersions` returns whatever it gathered before an error, so an empty list is not proof of no history: check for `VERSION_QUERY_FAIL`.

## Rolling a profile back

```lua
local versions = Data.ListVersions(ben.UserId, 10)   -- newest first
local target = versions[1]
if not target then
    return   -- no history, or the query failed
end

local snapshot = Data.GetVersion(ben.UserId, target.VersionId)
if not snapshot then
    return   -- version missing, or the read failed
end
print(`restoring {ben.UserId} to {target.VersionId}, Coins {snapshot.Coins}`)

local ok, reason = Data.RestoreVersion(ben.UserId, target.VersionId)
if not ok then
    warn(`restore failed: {reason}`)
end
```

Always read the version before you restore it. `GetVersion` is how you confirm the snapshot actually contains the inventory Ben says he lost.

A restore stamps `RestoredFrom = { VersionId, At }` into the profile's reserved `_Scribe` block, so a later read shows where the data came from. It needs a live key to write over, so restoring a profile that was erased fails with `no live profile exists for this user to restore over`.

!!! danger "A restore does not roll back the money"
    Your own fields go back to the snapshot, which is the whole point. The reserved `_Scribe` root is carried across from the live profile untouched.

    That root is not game state. It is the record of things that happened in the real world: the receipt-dedupe ring, gift escrow and gift credits, perks, the purchase log, and running cooldowns. Ben does not un-buy `GemPack100` because you restored yesterday's backup, so rolling that root back would not undo a mistake, it would create one.

??? note "What rolling the reserved root back would actually break"
    A granted receipt would be forgotten and grantable a **second** time off the same `PurchaseId`. A delivered gift would be resurrected, or an undelivered paid one destroyed. Paid credits and perks would be stripped, and the audit trail rewound.

    This is the same rule [migrations](#migrations) follow: a migration step that edits `_Scribe` has the edit discarded. When the preserved root differs from the snapshot's, the restore logs `RESTORE_RESERVED_PRESERVED`, so the operator running it can see that the money state stayed where it was.

    If `_Scribe` is *itself* what is broken, a corrupt dedupe ring or a gift record that cannot be delivered, opt in and roll it back with the rest:

    ```lua
    local ok, reason = Data.RestoreVersion(userId, target.VersionId, { RollBackReserved = true })
    ```

    That is the dangerous direction, and it is deliberately the one you have to ask for. Take an [`Export`](/api/Server#Export) first.

    **The schema version is the one exception, and it travels with the game data.** It lives inside `_Scribe`, but it is the one member of that root that records no real-world event. It describes the *shape* of the data the restore just rolled back, so it rolls back too.

    Keeping the live number on older-shaped data would tell the library that profile is already current, and [migrations](#migrations) only run when the stored version is *behind*, so the step meant to fix that data up would be skipped on that profile forever. It would also put the stored version ahead of an older server mid-deploy, which fails closed with `PROFILE_VERSION_AHEAD` and kicks the player.

    A snapshot with no version at all, meaning a legacy profile, restores as version 1 and re-migrates on the next load. The `RESTORE_RESERVED_PRESERVED` entry names both numbers, so the version move is never silent.

## Editing an offline profile

`UpdateOffline` mutates the **raw** profile table, the same shape `OnPlayerInit` receives. Declarator rules (bounds, enum members, `MaxLength`, element shapes) are not enforced there, though unpersistable values are still refused outright:

```lua
local ok, reason = Data.UpdateOffline(ben.UserId, function(data)
    data.Gems = (data.Gems or 0) + 100   -- an apology grant
end)
if not ok then
    warn(`could not grant: {reason}`)
end
```

Your callback runs against a copy, so one that errors partway commits nothing. It cannot create a profile: a user who has never joined returns `(false, "profile does not exist")`.

The callback may yield for as long as it likes, including a web call or a slow loop, because nothing it does can widen the window. The commit is a compare-and-set, so the write lands only if, at that instant, the profile is still free of a live session **and** still byte for byte the one your callback was handed.

That adds one reason worth handling beyond the obvious two: `"profile changed while the update was being prepared"`. Nothing was written, so retrying against a fresh read is always safe, and it is the right response, because your callback saw data that is now stale. Two servers backfilling the same profile therefore cannot clobber one another. [Migrating to Scribe](./migrating) walks through the bulk-import version.

??? note "A custom store may not give you the compare-and-set"
    The single-call guarantee above comes from the store Scribe ships. If you inject your own through the [`ProfileStore`](./configuration) option and it has no `UpdateOfflineAsync`, both `UpdateOffline` and `RestoreVersion` fall back to re-reading the lock and then writing, which narrows the window to one round trip without closing it. The `"profile changed while the update was being prepared"` reason cannot occur on such a store, because there is no fingerprint to compare against.

`UpdateOffline` does not expose derived fields at all. Its table is written straight back to the DataStore, and a computed value landing in storage is the thing derived fields exist to prevent.

## GDPR export and erase

```lua
local json = Data.Export(ben.UserId)   -- nil if missing, unreadable, or unencodable
if json then
    -- hand it to the requester through your own channel
end

local ok, reason = Data.Erase(ben.UserId)
if not ok then
    warn(`erase incomplete, retry: {reason}`)
end
```

Export first. `Erase` removes the live key outright, and `RestoreVersion` refuses afterwards because it has nothing to restore over.

`Erase` deletes the profile and then the user's leaderboard entries. If the profile is gone but a leaderboard key survived, it returns `(false, reason)` so you retry. The whole call is idempotent, so retrying is safe.

## Migrations

`Migrations` evolve your **own** data shape over time. This is not how you import from another data library, which is [Migrating to Scribe](./migrating). When your template changes, bump the version with a step:

```lua
Migrations = {
    -- Emberfall used to store a flat Bag of item ids. Inventory is a DictOf now.
    [2] = function(data)
        if data.Bag ~= nil then
            data.Inventory = {}
            for _, itemId in data.Bag do
                data.Inventory[itemId] = { Qty = 1, Rarity = "Common" }
            end
            data.Bag = nil
        end
    end,
},
```

Migrations are **fail-closed**. If any step throws, nothing is stamped, nothing is saved, and the session ends with a kick. A half-migrated profile can never persist.

Each profile stores the version its last successful run stamped, so **never renumber or remove a step you have shipped**. A profile stamped `3` resumes at step `4`, and repointing `3` at different code can no longer reach it. Following from that, the table has to be contiguous from `2` up to your highest key. A gap fails loudly at startup with `Scribe: Migrations table is missing step 3` rather than being skipped.

!!! warning "Template defaults are backfilled before your step runs"
    Scribe reconciles the stored data against the current template first, so every missing template key already holds its default by the time step 2 sees it. A step guarded on `if data.Inventory == nil`, or written as `data.Coins = data.Coins or 0`, therefore reads the default instead of the absence and silently does nothing for returning players.

    Key your steps off something the reconcile cannot manufacture: a field you removed from the template, like `Bag` above, or a value only stored data could hold.

??? note "Shadow mode, for while you are writing a chain"
    Set `MigrationShadow = true` and Scribe re-runs the same steps against the raw pre-reconcile bytes, warning under `MIGRATION_RECONCILE_DEPENDENT` wherever the two results diverge. It is opt-in rather than automatic, and it **re-executes your migration bodies**, so keep them pure functions of `data` while it is on.

??? note "Your step is handed the whole profile table, `_Scribe` included"
    A migration step receives the raw stored table, and that table has a reserved `_Scribe` root next to your own keys. **Migrate your own keys only.**

    A step that rebuilds the profile from a whitelist, such as `local out = { Coins = data.Coins }`, or that clears the table wholesale, would destroy receipt idempotency, so a receipt Roblox retries would be granted a second time, and it would strand gifts that were already paid for.

    Scribe therefore **discards** any change your chain makes to `_Scribe`. The stored reserved state is kept and only its `Version` is re-stamped, so nothing is lost. Because a silently reverted edit is its own trap, the discard is reported at Error as `MIGRATION_RESERVED_DISCARDED`. If you see it, that step is doing nothing on every load and needs rewriting. Reading `_Scribe` is harmless. Writing to it is not supported.

??? note "Two things a migration deploy will surprise you with"
    **A near-empty account is not a test.** A returning profile whose stored data is still nothing but current-template defaults is loaded un-migrated and left **unstamped** rather than kicked, because it has no stored progress to protect. Its chain retries on every join and lands as soon as the migration is fixed. It still logs `MIGRATION_FAIL` at Error, plus a warning explaining the carve-out. So a broken deploy kicks players with real progress while a barely-touched test account loads normally, and "my account loaded fine" is not evidence the step ran.

    **A rolling deploy bounces players.** A player whose data a new server already migrated can land on a still-running old server. By default (`VersionAheadPolicy = "Kick"`) Scribe fails closed there too, refusing to run old code against newer-shaped data. When you ship a migration, shut old servers down so players do not bounce between kicking instances.

## Cross-server messages

Send a message to another player's profile from any server with [`SendMessage`](/api/Server#SendMessage). It arrives at [`OnMessage`](/api/Server#OnMessage) on whatever server that player is active on, and is queued for offline players until their next load.

```lua
-- Sender, on any server. Note what is sent: a NOTIFICATION, not the item.
local sent = Data.SendMessage(ben.UserId, {
    Kind = "GiftOffer",
    OfferId = offerId,        -- your own id, so a repeat is recognisable
    From = ava.UserId,
    Product = "GemPack100",
})
if not sent then
    -- The offer never left this server. Do not tell Ava it did.
end

-- Recipient's server.
Data.OnMessage:Connect(function(player, message)
    if message.Kind == "GiftOffer" and not seenOffer(player, message.OfferId) then
        showGiftPrompt(player, message)
    end
end)
```

**Delivery is at-least-once, so the handler must be idempotent.** A message leaves the recipient's key only once your `OnMessage` handler has returned without raising, and only in the same write that persists what that handler did. Anything short of that keeps the message: nothing was connected yet (`MESSAGE_NO_LISTENER`), the handler threw (`MESSAGE_HANDLER_ERROR`), or the save carrying its effect never landed. The message is then handed to you again on that player's next load, once per session rather than once per save.

Payloads carry no id of their own, so put one in yours and ignore a repeat. Scribe fails in this direction on purpose: a duplicate is recoverable, a dropped message is not.

**`SendMessage` yields and returns whether the message was committed.** A recipient holds at most 1,000 undelivered messages, and a send past that is refused, returns `false` and logs `MESSAGE_QUEUE_FULL`. So this is a reliable handoff you must check, not fire-and-forget. A queue that stays full is almost always a handler that never acknowledges a message, because an unacknowledged entry occupies its slot forever. Watch `MessageQueueFull` in [diagnostics](./diagnostics).

Messages ride ProfileStore's global-update channel, so keep them small and infrequent. This is for coordination, not chat.

??? note "Never put the only copy of something valuable in a message"
    Send a message that *points at* value, not one that *carries* it. If Ava gives the sword away before the message is committed, a refused or unread message destroys it.

    Scribe's own gift delivery works this way. The purchase is escrowed on the **buyer's** profile first and only cleared once the recipient's key has durably accepted it, so a refused send leaves the gift retryable rather than gone. See [Monetization](./monetization).

??? note "The ProfileStore escape hatch"
    For the rare store-level operation Scribe does not wrap, such as a version query with a different sort order or a raw `MessageAsync` outside Scribe's envelope, [`Data.ProfileStore`](/api/Server#ProfileStore) exposes the underlying ProfileStore instance.

    It **bypasses Scribe's schema, replication and session guarantees**, so treat it as read-mostly and never mutate an active-session profile through it. Most games never need it.

## Where to next

- [Session Lifecycle](./lifecycle) is the live half of this story, from join to final save.
- [Migrating to Scribe](./migrating) covers importing profiles written by another library.
- [Scribe Studio](./studio-plugin) puts these operations behind a panel instead of a command.
- [Monetization](./monetization) explains what lives in the reserved root a restore preserves.
- [Diagnostics](./diagnostics) is where the offline read and version query failures surface.
