# Offline Profiles

Use these tools to inspect saved data, correct a profile, restore an older version, or erase a player's data.

**Before you start:** the examples use the server's `Data` bundle and the `Coins`, `Gems`, and `Level` fields from [Emberfall](./emberfall). These operations take a Roblox `userId`, not a `Player`, and **all yield**. Run them in a server script. If an admin panel or [`Command`](/api/Server#Command) calls them, check that the caller has permission.

- [Read saved data](#reading-a-stored-profile) to inspect a support issue.
- [Edit a profile](#editing-an-offline-profile) to correct a value or grant compensation.
- [Restore a version](#rolling-a-profile-back) to recover earlier game data.
- [Export or erase](#gdpr-export-and-erase) to handle a data request.
- [Migrate a template](#migrations) to update old data when players next join.

**Before any offline write, have the player leave the game.** Scribe refuses a write while a live session owns their profile.

## Reading a stored profile

```lua
local userId = 123456 -- replace with the user's Roblox ID
local snapshot = Data.GetOffline(userId)
if snapshot then
    print(`User {userId} has {snapshot.Coins} coins and is level {snapshot.Level}`)
end
```

[`GetOffline`](/api/Server#GetOffline) returns a read-only snapshot. Read its values directly: `snapshot.Coins`, not `snapshot.Coins.Get()`.

[Derived fields](./derived) are calculated when all their inputs are saved fields. Emberfall's `Level` uses saved `Xp`, so it appears in the snapshot too.

!!! warning "A missing result does not prove the profile is missing"
    `GetOffline` and `GetVersion` return `nil` for both missing data and a failed read. Check the logs for `OFFLINE_READ_FAIL` or `VERSION_READ_FAIL` before deciding what happened. `ListVersions` can return a partial or empty list after an error; check for `VERSION_QUERY_FAIL`.

    If the player is Ready on this server, `GetOffline` copies their current data. If they are playing on another server, it reads their last saved data. `Export` follows the same rule.

## Editing an offline profile

`UpdateOffline` edits the **raw** profile table: use `data.Gems`, not `data.Gems.Get()`. For admin tools, pass `{ Validate = true }` so Scribe rejects changes that break your template's rules:

```lua
local ok, reason = Data.UpdateOffline(userId, function(data)
    data.Gems = (data.Gems or 0) + 100   -- an apology grant
end, { Validate = true })
if not ok then
    warn(`could not grant: {reason}`)
end
```

Your callback runs against a copy, so an error commits nothing. It cannot create a profile: a user who has never joined returns `(false, "profile does not exist")`. Validation is opt-in; omitting it keeps the raw editing behavior used by migration and repair tools.

### Validating the change

Validation checks changed values against your template: types, bounds, integers, enums, string lengths, container limits, and closed-record keys. An invalid change writes nothing. The reason names the path, and a third return gives structured findings:

```lua
local ok, reason, violations = Data.UpdateOffline(userId, function(data)
    data.Gems = "lots"
end, { Validate = true })
-- ok = false
-- reason = 'the change does not match the template at "Gems": expected int, got string'
-- violations[1] = { Path = { "Gems" }, Kind = "WrongType", Detail = "expected int, got string" }
```

Validation checks **your change**, so an unrelated legacy field can remain invalid if you leave it untouched. Changing an invalid value to another invalid value is refused. Nothing is clamped or corrected for you.

It also refuses writes to Scribe's reserved `_Scribe` root, [derived fields](./derived), and [`Scribe.Session`](./visibility) fields. The profile's schema version must match this build before the callback runs. Load an older profile in a session to migrate it first.

??? note "Validation of already-invalid data"
    Changing `Coins = -1` to `-9999` is refused. The same rule covers changing an out-of-range `Scribe.Big`, replacing an undeclared flag with another, rewriting a misplaced buffer, or adding an overlong dictionary key.

    You may edit entries inside an already-overfull container, but may not grow it further. A set's size is its number of distinct members. If the profile already has 256 or more violations, validation refuses the operation because the bounded scan cannot safely compare all changes.

    These refusals do not count against [service health](./diagnostics). The live-session and conditional-write checks still apply.

??? note "When raw editing is intentional"
    Omitting `Validate` allows schema-breaking changes for migration or repair work, while still rejecting values the DataStore cannot serialize. Scribe also uses the raw path internally for reserved gift and credit records. Prefer `Validate = true` for ordinary administrative grants and corrections.

The callback may yield. When it finishes, Scribe writes only if the profile still has no live session and its stored data has not changed since the callback's copy was read.

If it returns `"profile changed while the update was being prepared"`, this attempt wrote nothing. Retry against a fresh read.

Keep external side effects out of the callback: a retry runs that code again. See [Migrating to Scribe](./migrating) for bulk imports.

??? note "A custom store may not give you the compare-and-set"
    The single-call guarantee above comes from the store Scribe ships. If you inject your own through the [`ProfileStore`](./configuration) option and it has no `UpdateOfflineAsync`, both `UpdateOffline` and `RestoreVersion` fall back to re-reading the lock and then writing, which narrows the window to one round trip without closing it. The `"profile changed while the update was being prepared"` reason cannot occur on such a store, because there is no fingerprint to compare against.

`UpdateOffline` does not calculate derived fields. Edit their saved inputs instead.

## The session lock

`UpdateOffline`, `RestoreVersion`, and `Erase` return `(false, reason)` while the user has a live session on any server. They do not force the player out of that session.

For a support ticket: have the player leave, make the change, then let them rejoin.

`RestoreVersion` and `Erase` also refuse while [service health](./diagnostics) reports an outage. An erase temporarily prevents **that user** from joining while their data is being removed; other players can join normally.

??? note "How an offline write avoids a racing join"
    For `UpdateOffline` and `RestoreVersion`, the lock check and write happen in one conditional store operation (a compare-and-set). A new session cannot slip between the check and the write.

    All three write operations treat a session whose last write is older than the store's 630-second dead-session threshold as dead. That lets an operation proceed after the owning server crashes. The default autosave interval is 300 seconds, so the threshold exceeds two missed autosaves.

??? note "How `Erase` keeps a join out while it runs"
    Removing leaderboard history can take minutes. Because DataStore deletion cannot be conditional, Scribe coordinates the sweep with a saved marker:

    1. **Mark the profile.** A conditional write records the erase attempt, its progress, and a five-minute lease. If no profile exists, it creates a marker-only placeholder that is removed with the sweep.
    2. **Refuse joins for this user.** A server that loads the marker releases the session without saving, then reports `erasing` with `ErasingMessage`. On the erasing server, the join waits up to `EraseJoinTimeout` (ten seconds by default) before the same refusal.
    3. **Renew while sweeping.** Each checkpoint renews the lease. Another erase is refused while the lease is live. If renewals keep failing, the attempt stops rather than continuing without ownership.
    4. **Check again before deletion.** Checkpoints and the final removal verify that the marker still belongs to this attempt. A fresh profile or a replacement attempt is left alone. Scribe also checks for a live session immediately before `RemoveAsync`.

    A failed attempt releases its lease so a retry can resume immediately. If that release also fails, or the server crashes, wait for the lease to expire; the next attempt resumes from saved progress.

    A joining server may briefly hold the marked session while releasing it. If the erase sees that session, it safely refuses and can be retried. One storage limitation remains: a removal request already sent to Roblox could stay outstanding beyond the lease. The checks happen before that request, not inside an atomic conditional delete.

## Rolling a profile back

Inspect the version first, then restore it while the player is offline. This example assumes you have chosen `userId` in your admin tool.

```lua
local versions = Data.ListVersions(userId, 10)   -- newest first
local target = versions[1] -- example only: inspect and choose the version you intend
if not target then
    return   -- no history, or the query failed
end

local snapshot = Data.GetVersion(userId, target.VersionId)
if not snapshot then
    return   -- version missing, or the read failed
end
print(`restoring {userId} to {target.VersionId}, Coins {snapshot.Coins}`)

local ok, reason = Data.RestoreVersion(userId, target.VersionId)
if not ok then
    warn(`restore failed: {reason}`)
end
```

Check that the snapshot contains the data you intend to recover. The newest version is not necessarily the right one.

A successful restore records `RestoredFrom = { VersionId, At }` in `_Scribe`. It requires an existing profile: an erased profile returns `no live profile exists for this user to restore over`.

!!! danger "A restore does not roll back the money"
    Your game fields return to the chosen snapshot. Scribe keeps the current purchase records, pending gifts, gift credits, perks, purchase log, and cooldowns in `_Scribe`. Restoring yesterday's inventory does not cancel today's purchase or make its receipt grantable again.

    **The schema version is the exception.** It returns to the snapshot's version so the restored data can run through migrations on its next load. A snapshot without a version uses version 1.

??? note "What rolling the reserved root back would actually break"
    Restoring old purchase records can grant the same `PurchaseId` twice, revive a delivered gift, remove a pending gift, or strip paid credits and perks.

    When the preserved state differs from the snapshot, `RESTORE_RESERVED_PRESERVED` records that choice and both schema versions. [Migrations](#migrations) also preserve `_Scribe`, apart from updating its version.

    For a deliberate repair of `_Scribe` itself, `RollBackReserved` restores it too. **Export the current profile first and account for the purchase and gift risks above.**

    ```lua
    local ok, reason = Data.RestoreVersion(userId, target.VersionId, { RollBackReserved = true })
    ```

    The schema version normally follows the restored data because keeping the newer number would skip migrations that the older data still needs. An older server also refuses data with a newer version by default (`PROFILE_VERSION_AHEAD`).

## GDPR export and erase

```lua
local json = Data.Export(userId)   -- nil if missing, unreadable, or unencodable
if json then
    -- hand it to the requester through your own channel
end

local ok, reason = Data.Erase(userId)
if not ok then
    warn(`erase incomplete, retry: {reason}`)
end
```

Export first. `Erase` removes the live key outright, and `RestoreVersion` refuses afterwards because it has nothing to restore over.

`Erase` removes leaderboard entries first and deletes the profile only after the sweep succeeds. A year of daily entries can take many requests, so show the operation as in progress rather than promising an immediate reset.

| Result | What to do |
| --- | --- |
| `true` | The erase finished, including when another server already finished it. |
| `false` after a sweep or budget failure | Keep the reason in your admin log and retry. The profile and progress marker remain, so the retry resumes where it stopped, even after a server restart. |
| `false` because ownership changed or the profile was recreated | The old attempt leaves the new state alone. Inspect it before intentionally starting a fresh erase. |

Under `BudgetPolicy = "Defer"`, each removal waits for `OrderedRemove` budget. A wait exceeding thirty seconds returns `false` for a later retry. Repeating an unfinished erase is safe; the [session-lock details](#the-session-lock) explain how attempts coordinate.

## Migrations

Use `Migrations` when you change the shape of data already saved with Scribe. To import from another library, follow [Migrating to Scribe](./migrating).

Add a numbered step to your server bundle's options. This example converts the old `Bag` field into `Inventory`:

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

For a profile with saved progress, a failed step refuses the load: Scribe saves no partial changes, leaves the version unchanged, and kicks the player. A profile containing only template defaults has a special retry behavior described below.

**Keep every shipped step at its original number.** A profile at version `3` resumes at step `4`; editing step `3` will not rerun it. Number steps consecutively from `2`. A gap fails at startup, for example: `Scribe: Migrations table is missing step 3`.

!!! warning "Template defaults are backfilled before your step runs"
    Missing fields in ordinary records, including nested ones, already have their template defaults when your step runs. Checking `if data.Inventory == nil` can therefore skip the conversion you meant to run.

    Check for the **old field**, such as `Bag` above, or an old value that the template cannot supply. Typed container element defaults are filled after migrations.

??? note "Shadow mode, for while you are writing a chain"
    `MigrationShadow = true` runs the steps again on a copy taken before defaults were filled in. Different results log `MIGRATION_RECONCILE_DEPENDENT`. Because this **runs your callbacks again**, only change `data` inside them; do not send messages or perform other external actions.

**Only migrate your own fields.** You can read `_Scribe`, but changes to it are discarded and logged as `MIGRATION_RESERVED_DISCARDED`. Scribe preserves its purchase and gift records and updates only the schema version.

!!! warning "Test real saved progress and retire old servers"
    A returning profile containing only current-template defaults can load after a failed migration. Its version stays unchanged, the failure is logged as `MIGRATION_FAIL`, and the chain retries on the next join. A nearly empty test account loading successfully does **not** prove the migration works for players with progress.

    A player migrated by a new server may then join an older server. By default, that server refuses the newer data and kicks them with `VersionAheadMessage`. Shut down old servers when you deploy a migration so players do not keep landing on incompatible code.

## Cross-server messages

[`SendMessage`](/api/Server#SendMessage) sends a small message to a player's profile. [`OnMessage`](/api/Server#OnMessage) handles it on their active server, or when they next join if they are offline.

This is a notification pattern. `ava` is the sending `Player`; `offerId`, `seenOffer`, and `showGiftPrompt` are values and helpers your game supplies. Use a stable offer ID and make the prompt safe to show again.

```lua
-- Sender, on any server. Note what is sent: a NOTIFICATION, not the item.
local sent = Data.SendMessage(userId, {
    Kind = "GiftOffer",
    OfferId = offerId,        -- your own id, so a repeat is recognisable
    From = ava.UserId,
    Product = "GemPack100",
})
if not sent then
    -- Delivery is not confirmed. Retry the same OfferId; do not promise success.
end

-- Recipient's server.
Data.OnMessage:Connect(function(player, message)
    if message.Kind == "GiftOffer" and not seenOffer(player, message.OfferId) then
        showGiftPrompt(player, message)
    end
end)
```

**A message can arrive more than once.** Include your own ID and make repeat handling safe. This is called *idempotency*: handling the same ID twice must not grant an item twice.

Scribe removes the message only after the handler returns successfully and a save persists its changes. With no listener (`MESSAGE_NO_LISTENER`), a thrown error (`MESSAGE_HANDLER_ERROR`), or a failed save, the message stays queued. It is delivered again on the next session, not on every save.

Keep the handler short and avoid yielding or calling `Flush` inside it. Let it return so Scribe can save the changes and acknowledge the message together.

| Send result | Meaning |
| --- | --- |
| `true` | The message was committed to the recipient's queue. It may not have been handled yet. |
| `false` | Delivery is unconfirmed. Retry the same ID rather than assuming it was lost. |

A profile can hold **1,000 undelivered messages**. A full queue refuses new sends and logs `MESSAGE_QUEUE_FULL`; watch `MessageQueueFull` in [Diagnostics](./diagnostics). If it stays full, check whether handlers are returning successfully and their changes are saving.

Keep messages small and infrequent. They use ProfileStore's stored message queue, not a chat transport.

!!! warning "Never put the only copy of something valuable in a message"
    Save the pending gift on the sender before sending. If sending fails, that record must still let you retry without charging again.

    For game items or currency, follow the [transaction and outbox pattern](./transactions#when-the-rule-mentions-two-players). For paid gifts, use Scribe's [gifting support](./gifting), which keeps a pending record on the buyer until the recipient's profile has accepted it durably.

??? note "The ProfileStore escape hatch"
    For the rare store-level operation Scribe does not wrap, such as a version query with a different sort order or a raw `MessageAsync` outside Scribe's envelope, [`Data.ProfileStore`](/api/Server#ProfileStore) exposes the underlying ProfileStore instance.

    It **bypasses Scribe's schema, replication and session guarantees**, so treat it as read-mostly and never mutate an active-session profile through it. Most games never need it.

## The seven operations

| API | Returns | What it does |
| --- | --- | --- |
| [`GetOffline(userId)`](/api/Server#GetOffline) | `data?` | Read-only snapshot of the raw profile table. |
| [`UpdateOffline(userId, fn, opts?)`](/api/Server#UpdateOffline) | `(ok, reason?, violations?)` | Edit a profile; `{ Validate = true }` checks changes against the template. |
| [`ListVersions(userId, limit?)`](/api/Server#ListVersions) | `{ { VersionId, CreatedAt, Size } }` | List versions, newest first; default limit 25. `CreatedAt` is Unix seconds. |
| [`GetVersion(userId, versionId)`](/api/Server#GetVersion) | `data?` | The raw data of one historical version, for inspection or diffing. |
| [`RestoreVersion(userId, versionId, opts?)`](/api/Server#RestoreVersion) | `(ok, reason?)` | Rolls the live key back to that version. |
| [`Export(userId)`](/api/Server#Export) | `json?` | The profile as a JSON string, with buffers base64-encoded. |
| [`Erase(userId)`](/api/Server#Erase) | `(ok, reason?)` | Remove leaderboard entries, then the profile. An interrupted sweep can resume. |

The [Scribe Studio](./studio-plugin) wraps the same operations in a Production panel when you would rather click than write a command.

## Where to next

- [Session Lifecycle](./lifecycle) is the live half of this story, from join to final save.
- [Migrating to Scribe](./migrating) covers importing profiles written by another library.
- [Scribe Studio](./studio-plugin) puts these operations behind a panel instead of a command.
- [Monetization](./monetization) explains what lives in the reserved root a restore preserves.
- [Diagnostics](./diagnostics) is where the offline read and version query failures surface.
