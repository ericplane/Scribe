# Configuration

This page is the complete list of everything you can pass to `Scribe({ ... })`. Three options are required and every other one has a default that is right for most games, so you can read the first section and skip the rest until you need something.

The whole table is typed as `ScribeOptions<T>`, so your editor autocompletes the names and flags a wrong type. It does not flag a **misspelled** name, because Luau accepts unknown table keys. Scribe catches those itself and warns at startup in Studio with `UNKNOWN_OPTION`.

## The three you must set

Here is Emberfall's whole configuration on day one:

```lua
-- ReplicatedStorage/Shared/EmberfallData.luau
return Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",
})
```

| Option | What it is |
| --- | --- |
| `Template` | The table that declares your data shape. See [Declaring Your Template](./templates). |
| `ProfileStoreIndex` | The DataStore name your profiles live under. |
| `ProfileKeyPrefix` | Prefixed onto each user id to form the key, so Ava's profile is `PLAYER_101`. |

Scribe errors at construction if any of the three is missing.

??? note "Why the store name and prefix have no defaults"
    A default would let two games, or a test build and a live build, silently share one store. Naming your own is the one place Scribe makes you be deliberate rather than helpful.

    `ProfileKeyPrefix` may be `""`, and that means the key is the bare user id. Use it when you are adopting a database whose keys were only the user id. Otherwise change it only when you deliberately want a fresh, isolated key namespace, and understand that changing it on a live game hides every existing profile.

## Persistence mode

`Mode` is one value that says where data comes from, whether a session is held, and whether anything saves. It defaults to `"Live"`.

```lua
Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",
    Mode = "Mock",
})
```

| Mode | Reads | Session | Saves |
| --- | --- | --- | --- |
| `Live` (default) | The real profile | Exclusive | Yes |
| `Mock` | ProfileStore's in-memory mock | Mock | To the mock only |
| `NoSave` | A snapshot of the real profile | None | Never |

`TargetUserId` pairs with any mode and loads that user's profile instead of the joining player's. `Mode = "NoSave", TargetUserId = 101` is the safe way to inspect Ava's real profile: you see genuine stored data and nothing can write it back.

`Mode` is the only switch a play-test needs. Under both `Mock` and `NoSave`, declared [leaderboards](./leaderboards) swap to an in-memory ordered store too, so a test session cannot write a score into a live OrderedDataStore. Those boards start empty and are discarded when the session ends. `Mode = "Mock"` is also what unlocks receipt injection in [Scribe Studio](./studio-plugin), which refuses to inject against any other mode.

??? note "Reading an older config that still uses the flags"
    `Mode` replaces four older flags. They still work when `Mode` is absent, so no existing config has to change. Set `Mode` and they are ignored with a `MODE_OVERRIDES_LEGACY` warning at startup.

    | Legacy | Mode |
    | --- | --- |
    | `UseMock = true` or `DontSave = true` | `Mode = "Mock"` |
    | `ViewedUserId = id` | `Mode = "NoSave", TargetUserId = id` |
    | `OverriddenUserId = id` | `Mode = "Live", TargetUserId = id` |

    This table is for reading an old config, not for writing a new one. `Mode` on its own covers everything the flags did.

## Process-wide settings

A few settings belong to the whole game rather than to one bundle, because they configure ProfileStore itself. Set them once, before constructing any bundle:

```lua
Scribe.Configure({ AutoSaveInterval = 60 })
```

`AutoSaveInterval` is the autosave cadence. The per-bundle `SaveInterval` option still works and still wins where it is set, but ProfileStore's `AUTO_SAVE_PERIOD` is a module-wide constant. It applies to every Scribe bundle and to any direct ProfileStore use in the same game. If two bundles ask for different cadences only the later one wins, and Scribe logs `SAVE_INTERVAL_CONFLICT`.

## Core

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `Template` **(required)** | `T` | none | Declares the shape and defaults of every player's saved data. Scribe compiles it into the schema and deep-freezes it. |
| `Transport` | `(ScribeTransport \| "Default")?` | `"Default"` | Picks the server-to-client replication channel. Supply an adapter table only to route replication through your own networking layer. See [Custom Transports](./transports). |
| `Migrations` | `{ [number]: (data) -> () }?` | `{}` | Maps each data version from 2 upward to a function that upgrades stored data to it. See [Offline Profiles](./profiles#migrations). |
| `MigrationShadow` | `boolean?` | off | Re-runs your migration chain a second time against the raw pre-reconcile data and warns where the two disagree. |
| `ServerStore` | `{ [string]: any }?` | none | Declares a second tree owned by the server rather than by any player: one table for the whole server, never saved, replicated to everyone. See [The Server Store](./server-store). |
| `Economy` | `EconomyConfig?` | none | Per-currency labels, custom field declarations, and resolvers for Roblox's economy dashboard. See [Economy Analytics](./economy). |
| `ImportLegacyData` | `((player, userId, migration) -> table?)?` | none | Adopts data from another library, once, before reconcile and before migrations. The third argument is a [`MigrationContext`](/api/types#migrationcontext): `migration.AwaitBudget(requestType, count?, timeout?)` paces reads on the DataStore budget and returns `(granted, release)`. See [Migrating to Scribe](./migrating). |
| `OnPlayerInit` | `((player, rawData, isNewProfile, migration) -> ())?` | none | Runs once per player right after their profile loads, against the raw data table. The fourth argument is the same [`MigrationContext`](/api/types#migrationcontext), so `AwaitBudget` is available here too, for a game already on Scribe with stores left to move. See [Session Lifecycle](./lifecycle#onplayerinit). |
| `MigrationConcurrency` | `number?` | 2 | How many `ImportLegacyData` hooks may run at once. The only hard bound on what a migrating server spends, because `AwaitBudget` is cooperative. |
| `OnPlayerLeaving` | `((player, data, reason) -> ())?` | none | Runs once per player as they leave, **before** the final save, so anything it writes persists. |

??? note "What `MigrationShadow` is actually catching"
    Scribe fills missing template keys with their defaults **before** migrations run. So a migration step guarded on `if data.Field == nil then` sees a manufactured default rather than a genuine absence, and silently does nothing for returning players. That is the bug this option finds.

    Turning it on re-executes your migration bodies a second time, against the raw stored data, and warns on any divergence. Keep migration steps free of side effects outside `data` or the shadow run will perform them twice. It is an audit aid for a staging deploy, not something to leave on in production.

## Persistence & sessions

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `ProfileStoreIndex` **(required)** | `string` | none | The DataStore name profiles live under, passed straight to `ProfileStore.New`. |
| `ProfileKeyPrefix` **(required)** | `string` | none | Concatenated with the user id to form each key. `""` is valid and means a bare user id. |
| `SaveInterval` | `number?` | 300 | Seconds between automatic saves. Values below 15 are raised to 15. It sets ProfileStore's global period, so it affects every bundle. |
| `ProfileStore` | `any?` | auto-discovered | An explicit ProfileStore module or ModuleScript. Set it only when auto-discovery fails or you need a specific build. |
| `ResetData` | `boolean?` | off | Wipes each loaded profile back to template defaults and logs a reset warning. Deliberate destruction, so leave it off. |
| `LoadTimeout` | `number?` | 120 | Seconds one session attempt may take before `LoadFailurePolicy` applies. Floored at 60. |
| `LoadFailurePolicy` | `("Kick" \| "Wait")?` | `"Kick"` | What to do when a load keeps failing. `"Kick"` removes the player. `"Wait"` retries with backoff and never serves template data. |
| `VersionAheadPolicy` | `("Kick" \| "Allow")?` | `"Kick"` | What to do with a profile written by a newer deploy. `"Kick"` fails closed. `"Allow"` runs older code against newer data and warns. |
| `KickOnSessionEnd` | `boolean?` | `true` | Kicks a player whose session ends unexpectedly, so they can rejoin with a working one. |
| `LoadFailureMessage` | `string?` | "We couldn't load your data. Please rejoin!" | The kick message under the `"Kick"` load policy. Setting it overrides the four **load** causes below, so an existing config keeps one voice; it does not reach the session-end rows. |
| `LegacyImportFailureMessage` | `string?` | "We couldn't check your existing data…" | Shown when `ImportLegacyData` threw, so the load fails closed rather than starting the player empty. |
| `MigrationFailureMessage` | `string?` | "We couldn't update your data to this version of the game…" | Shown when the migration chain could not complete. |
| `VersionAheadMessage` | `string?` | "Your data is from a newer version of the game than this server…" | Shown when `VersionAheadPolicy = "Kick"` fails closed on a profile a newer deploy already migrated. Their data is fine; this server is the old one. |
| `SchemaFailureMessage` | `string?` | "Your saved data doesn't match this version of the game…" | Shown when `SchemaPolicy = "Reject"` rejects the stored profile. |
| `RateLimitedMessage` | `string?` | "Roblox's data service is busy right now…" | Shown when the load failed and the DataStore's last error for that key was a throttle (a 3xx code). The one load failure worth rejoining for. |
| `SessionEndMessage` | `string?` | "Your data session has ended. Please rejoin!" | The kick message when `KickOnSessionEnd` fires. Setting it overrides both causes below. |
| `SessionStolenMessage` | `string?` | "Your data was opened on another server…" | Shown when another server took the profile, which is what almost every unexpected session end actually is. |
| `SessionInterruptedMessage` | `string?` | "Your data session ended before it finished loading…" | Shown when the session went away mid-load, so the player never had a session to lose. |
| `UseMock`, `DontSave`, `ViewedUserId`, `OverriddenUserId` | | | Superseded by [`Mode`](#persistence-mode). |

??? note "Why the kick messages are split by cause"
    A player who is told "we couldn't load your data" cannot tell a throttle that clears in
    ten seconds from a profile that will never load again, and neither can whoever reads
    their support report. Each cause names itself instead.

    The rate-limited wording is earned, not guessed. `StartSessionAsync` answers `nil` and
    carries no reason of its own, so Scribe reads the DataStore error the store reported for
    that key and uses the throttle wording only for a 3xx code. A 5xx is the service failing,
    not throttling, and gets the ordinary load message; see [Diagnostics](./diagnostics) for
    the same classification behind the counters.

    The session-end kick splits the same way. "Your data session has ended" hid the one cause
    it nearly always is: another server holds the profile now, because the player opened the
    experience somewhere else. That is `SessionStolenMessage`, and it is decided by the same
    `LocalSessionEnd` flag Scribe already uses to tell "we ended this" from "someone took it".

    The two families do not leak into each other. Load causes fall back to
    `LoadFailureMessage`, session-end causes to `SessionEndMessage`, so wording your load
    failures has not thereby worded your session ends.

    Every one of them still defers to `LoadFailureMessage` when you set it, so nothing about
    an existing config changes. Name a specific one to override just that cause.

??? note "Why `LoadTimeout` has a 60 second floor"
    ProfileStore's own `START_SESSION_TIMEOUT` only applies when no `Cancel` hook is passed, and Scribe always passes one. Without `LoadTimeout`, a DataStore outage would park a joining player in `Loading` forever and `LoadFailurePolicy` would never be reached.

    The floor is not cosmetic. A cross-server handoff legitimately takes tens of seconds, because ProfileStore steals a held session after about 40 seconds rather than reporting a failure. A shorter deadline would abort ordinary rejoins and kick players who were never in trouble. Values below 60 are raised to it.

    Under `LoadFailurePolicy = "Wait"` this bounds each attempt, not the total wait. The retry backoff is jittered by up to a quarter either way, so a fleet that lost the DataStore at one instant does not retry in unison. That is why the gaps between `PROFILE_LOAD_FAIL` entries look irregular.

## Monetization & services

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `Products` | `{ [string]: ProductConfig }?` | none | Declares developer products by name, each with an `Id` and an optional `Category`, `Grant` and `Grants`. See [Monetization](./monetization). |
| `Passes` | `{ [string]: PassConfig }?` | none | Declares game passes by name, each with an `Id` and an optional `Category`. |
| `Perks` | `{ string }?` | none | A list of valid perk names, used only as a typo guard. Without it any perk name is accepted silently. |
| `Leaderboards` | `{ [string]: LeaderboardConfig }?` | none | Registers all-time OrderedDataStore boards. See [Leaderboards](./leaderboards). |
| `OwnReceipts` | `boolean?` | `true` | Whether this bundle installs the single global `ProcessReceipt` callback. Set false on a secondary bundle and route its receipts through `Data.HandleReceipt`. |
| `PurchaseLog` | table | caps of 100, server-only | Tunes the per-player purchase history rings. |
| `UserOwnsGamePassAsync` | `((userId, passId) -> boolean)?` | the real service call | A test seam for pass ownership. Leave it unset in production. |
| `GetProductInfoAsync` | `((assetId, infoType) -> table?)?` | the real service call | A test seam for the client's price reads. Leave it unset in production. |

Emberfall's money config is two products and one pass:

```lua
Products = {
    CoinPack500 = { Id = 1234567890, Category = "Currency" },
    GemPack100  = { Id = 1234567891, Category = "Currency" },
},
Passes = { VIP = { Id = 987654321 } },
Perks  = { "VIP" },
```

??? note "The `PurchaseLog` sub-options"
    | Key | Default | What it does |
    | --- | --- | --- |
    | `RobuxCap` | 100 | How many Robux purchase entries a player keeps. The oldest is dropped. |
    | `InGameCap` | 100 | The same, for soft-currency entries written by `RecordPurchase`. |
    | `ReplicateRobux` | `false` | Streams the Robux log to that player's client. |
    | `ReplicateInGame` | `false` | Streams the in-game log to that player's client. |
    | `PurchaseLogCategories` | none | Declares allowed category names, for a dev-mode typo warning. |

    Raise the caps to keep more history, and set the replicate flags when a shop UI wants to render a player's own purchase history without a round trip.

??? note "Leaderboard config keys, in one place"
    Each board takes a required `Stat` and these optional keys.

    | Key | Default | Notes |
    | --- | --- | --- |
    | `Limit` | 100 | Entries kept, clamped to 1 through 100. |
    | `Scale` | 1 | Multiplier for a fractional stat. Refused on a `Scribe.Big`. |
    | `SigFigs` | 12 | `Scribe.Big` stats only, 1 through 15. Trades exponent range for resolution. |
    | `Replicate` | `false` | Streams the board to clients. Refused on a `Scribe.Big`. |
    | `RefreshInterval` | 60 | Approximate seconds between reads, floored at 60 and jittered by up to a quarter. |
    | `StoreName` | `"LB_<name>"` | A `Scribe.Big` board is `"LB_<name>_big<SigFigs>"`, because the two key layouts must never share a store. |

    A `Stat` that is missing, or that descends through a leaf, errors at startup. So does a set of boards whose combined refresh rate would read the OrderedDataStore too often. Use `RefreshInterval` to read a board **less** often, which is how you buy room for more boards.

??? note "A live in-server scoreboard is a different tool, and it has a cost"
    A [`Scribe.Shared`](./visibility) root updates instantly at no DataStore cost, which makes it tempting for a scoreboard. Read it as a decision rather than a shortcut, because `Shared` broadcasts the value to **every** client in the server.

    That is right for a number meant to be public: a round score, a wave number, a team total. It is the wrong default for a spendable currency. Publishing Emberfall's `Coins` publishes more than the balance, because the number **moving** is itself information. Every other player can see the instant someone spends or gifts, and can infer what they did from the size of the dip. It is also a permanent competitive read on everyone's economy, and once players have it you cannot quietly take it back.

    If you want a live board over a currency, mirror only what you actually want published, such as a rank or a bucketed tier, into a `Shared` root and leave the real balance on the owner-only default.

## Gifting

These bound how many gifts are in flight and how long Scribe remembers a settled purchase. The defaults suit a normal game, so reach for them only when you see the matching log code.

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `GiftCooldown` | `number?` | 5 | Seconds a sender waits between gift prompts. A call inside the window is refused with `"gift cooldown"`. |
| `GiftMaxPending` | `number?` | 20 | Unresolved gift intents one sender may hold. Past it, `PromptGift` refuses with `"too many pending gifts"`. |
| `GiftIntentTTL` | `number?` | 3600 | Seconds a recorded intent stays valid. After that the receipt falls to `NoGiftIntentPolicy`. |
| `AllowDuplicateGifts` | `boolean?` | `false` | When off, gifting a perk the recipient already owns is blocked at prompt time and becomes a re-aimable credit. |
| `NoGiftIntentPolicy` | `("GrantOrCredit" \| "Hold")?` | `"GrantOrCredit"` | What to do with a gift receipt that has no matching intent. `"Hold"` declines it so Roblox refunds. |
| `PurchaseIdTTL` | `number?` | 604800 | Seconds a processed receipt's `PurchaseId` is remembered, for de-duplication. |
| `MaxProcessedPurchaseIds` | `number?` | 200 | Hard ceiling on that de-duplication ring. |
| `PurchaseClaimTTL` | `number?` | `PurchaseIdTTL` | Seconds a `Data.Purchase` `IdempotencyKey` claim is remembered. |
| `MaxPurchaseClaims` | `number?` | 1000 | Ceiling on live claims per profile. |

??? note "Two idempotency stores, and which knob belongs to which"
    These are two separate mechanisms and it is easy to tune the wrong one.

    **The receipt ring** dedupes **Roblox receipts**. Its window is Roblox's retry window, which is not yours to shorten, so leave `PurchaseIdTTL` at a week unless you know better. `MaxProcessedPurchaseIds` is the hard ceiling: when entries have not yet aged out and the ring is full, the oldest is dropped and `PURCHASE_ID_EVICTED` is logged. That is the only eviction that drops an entry Roblox could still retry a receipt for, so raise the ceiling if you ever see it. The age prune is the other way an entry leaves the ring, and it is silent by design: past the window no receipt retry can still reach it.

    **The claim store** dedupes **your own** `Data.Purchase` calls, which your code retries in seconds rather than days. Lowering `PurchaseClaimTTL` is the right way to bound what a heavy shop accumulates. `MaxPurchaseClaims` is a runaway guard rather than a working limit: claims expire on their own, so reaching 1000 means a player buys faster than the TTL drains. The claim nearest to expiring is dropped and `PURCHASE_CLAIM_EVICTED` is logged. Prefer shortening the TTL to raising the cap.

## Exchanging

One option, and nothing is exchangeable until it names the path. Every entry is proved safe to move **at startup**, so a mistake here stops the server rather than surfacing mid-exchange with value already in escrow.

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `Exchangeable` | `{ [string]: LegSpec }?` | none | The paths players may exchange, each with the kind of move allowed. Absent means exchanging is off entirely. |

Each entry is a `LegSpec`:

| Field | Type | Required | What it does |
| --- | --- | --- | --- |
| `Path` | `{ string }` | yes | A top-level field or container, never a path inside one. |
| `Kind` | `"Key" \| "Qty" \| "Stack"` | yes | A whole container entry, an amount of a bounded `Scribe.Int`, or part of one stacked entry. |
| `Count` | `string?` | `Stack` on a record element | The element field holding how many. Omit it when the element IS the count, as in a `DictOf(Scribe.Int(...))`. |
| `Identity` | `{ string }?` | `Stack` on a record element | Element fields that travel with a split. Both halves keep them. |
| `Ignore` | `{ string }?` | no | Element fields that do NOT travel. The receiver's copy starts at the declared default and the giver keeps theirs. Valid on `Key` and `Stack`. |

```lua
Exchangeable = {
    Money = { Path = { "Coins" },     Kind = "Qty" },
    Pet   = { Path = { "Pets" },      Kind = "Key",   Ignore = { "TotalDamageDealt" } },
    Item  = { Path = { "Inventory" }, Kind = "Stack",
              Count = "Qty", Identity = { "ItemId", "Rarity" }, Ignore = { "TimesUsed" } },
    Ore   = { Path = { "Resources" }, Kind = "Stack" },
}
```

??? note "Why a `Stack` must account for every element field"
    A split **duplicates** whatever it does not drop. `{ Qty = 5, Rarity = 3 }` split by two becomes `{ Qty = 3, Rarity = 3 }` and `{ Qty = 2, Rarity = 3 }`. For `Rarity` that is correct, because it describes the item. For a field like `TimesUsed` it is a mint, and no check inside the exchange can tell the two apart: the count itself is exactly conserved either way.

    Only you know which is which, so every declared element field must appear in `Identity` or `Ignore`. One in neither **refuses to start** and names the field. That is deliberate rather than strict for its own sake: the day you add a field to the element is exactly the day you want to be asked whether it duplicates.

    A `Key` leg duplicates nothing, so its `Ignore` is optional and a field you do not list simply travels, which always conserves.

!!! warning "`Ignore` destroys the field in transit"
    An ignored field goes nowhere. It is not held, not escrowed, and not returned by an abort. Never ignore anything that represents value.

The full list of shapes Scribe refuses to start on, and why each one is unsafe to move, is in [Exchange](./exchange.md).

## Behaviour & limits

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `CommandRateLimit` | `number?` | 20 | Command RPCs per second per player, as a token bucket that refills at this rate and caps at it. |
| `RequestTimeout` | `number?` | 10 | Seconds a client request waits for a reply before resolving with `false` and `"timeout"`. |
| `MaxInboundBytes` | `number?` | 8192 | Largest inbound frame the server accepts. Anything larger is dropped and logged as `INBOUND_OVERSIZE`. |
| `MaxInboundRetainedBytes` | `number?` | 131072 | How much memory a single inbound frame may **materialise** before it is refused with `INBOUND_WORK_LIMIT`. |
| `MaxOutboundBytes` | `number?` | 65536 | The largest buffer handed to the transport in one call. Anything larger is fragmented and reassembled transparently. |
| `MaxInboundFrameRate` | `number?` | `max(60, CommandRateLimit * 4)` | Raw inbound frames per second per player, counted before a frame is read at all. |
| `TransportChannel` | `string?` | `"ScribeTransport"` | Names the folder and RemoteEvents this bundle uses. Set a distinct one when running two bundles. |

??? note "Why byte size and retained size are two separate limits"
    `MaxInboundBytes` measures the wire. `MaxInboundRetainedBytes` measures what decoding it costs in memory, counting every table, array slot, hash node, string and buffer the decoder materialises.

    They come apart badly. An 8 KB frame spent on one string retains 8 KB. The same 8 KB spent on one-byte booleans retains a quarter of a megabyte of array storage, and the recursion cap does not help, because a flat table of four thousand siblings is depth 1.

    The default is `MaxInboundBytes * 16`, and that 16 is a **ceiling to reason about, not a guarantee**. It came from the tagged encoding, where a hash pair cost four bytes. Two encodings have been added since and neither holds the figure. The measured worst cases, each pinned as an exact assertion in the test suite:

    | Shape | Ratio |
    | --- | --- |
    | Generic or dense array of scalars | 16.0 to 1 |
    | Tagged dynamic string keys | 16.6 to 1 |
    | Static struct of scalars | 30.2 to 1 |
    | Dense array of **table** elements | 48.0 to 1 |
    | Static struct of **table** children | 59.4 to 1 |

    Read the two table rows. A nested empty table costs the sender two bytes and retains a whole table on top of the slot its parent already paid for. That is the honest cost of a cheap-to-write, expensive-to-hold shape, and every byte of it is charged before the recursive decode.

    The two struct rows are bounded by your own schema, since an attacker can pick the widest struct **you declared** and cannot invent a wider one. The dense path has no such bound, which makes 48.0 the more dangerous number despite being the smaller. None of these paths is reachable from untrusted input today, because the server's dispatcher accepts only `Hello` and `Command`, and command arguments take the generic codec. It matters the day a server-inbound frame carries a schema-typed value. Refusals are counted separately from the malformed budget and never end a session.

??? note "What fragmentation buys, and the number behind the default"
    An `Init` snapshot is **one op per root**, so its size is the player's whole profile and no op-count limit can divide it. What a ceiling buys is **wire occupancy**. An unsplit snapshot holds the channel until it gets through, and every diff, command reply and status frame queued behind it waits. The cost of a large frame is paid by everything else that player is doing, not just by the join.

    A custom transport is also free to refuse a payload outright. Before fragmentation existed that left the client re-`Hello`ing forever without loading, so declare [`MaxFrameBytes`](./transports) on your adapter if that is your channel.

    Roblox does not document a payload ceiling to set this against, so the default sits far below any plausible one while leaving ordinary traffic unsplit. A diff is bytes to a few kilobytes. The `Init` snapshot of a 1,000-record inventory measures 29,811 bytes, pinned by a spec so the figure and the encoder cannot drift apart.

??? note "Keep the frame rate limit well above the command limit"
    `MaxInboundFrameRate` is the only limit covering every frame whatever its type, size or validity, and an oversized frame counts against no other budget. Unlike `CommandRateLimit` it drops **silently** rather than replying. A client that trips it is stranded until its `RequestTimeout` instead of being told it was rate-limited, so keep the two well apart.

## Integrity

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `BoundsPolicy` | `("Clamp" \| "Reject")?` | `"Clamp"` | What an out-of-bounds write does. `"Clamp"` pins it into range and fires an anomaly. `"Reject"` throws at the write site. |
| `WipeGuardPolicy` | `("Warn" \| "Block")?` | `"Warn"` | What the wipe guard does when a save looks like accidental loss. `"Block"` also holds the save and rewrites the last good snapshot. |
| `WipeGuardShrinkRatio` | `number?` | 0.6 | The fractional size drop that trips the guard. Clamped to 0.05 through 0.95. |
| `SchemaPolicy` | `("Warn" \| "Reject")?` | follows `DevMode` | Checks stored data against the template on load. See below. |
| `BudgetPolicy` | `"Defer"?` | off | Paces the leaderboard background loops on the DataStore request budget. |

### Checking stored data against the template

`SchemaPolicy` walks a profile's **stored** shape against the compiled template as it loads, after reconcile has backfilled anything the template has gained.

- `"Warn"` logs each violation and fires `OnAnomaly`, but still loads the player. This is what you want while you are finding out what is wrong.
- `"Reject"` additionally fails the load closed for the violations that warrant it. The player is kicked with `load-failed`, and the stored bytes are **left exactly as they were found**. The session lock is released so they can rejoin elsewhere, but nothing is written back, so a rejected profile is genuinely quarantined rather than rewritten by the load that rejected it.

Absent, the policy follows [`DevMode`](#diagnostics): `"Warn"` while you develop, and nothing at all on a live server. An explicit value always wins, in both directions.

**Set `"Warn"` and read a day of `PROFILE_SCHEMA_VIOLATION` before you set `"Reject"`.** The report tells you what your stored data actually contains, and a migration is the fix for anything it turns up.

??? note "Why the default is Studio-only"
    Left off everywhere, five kinds of stored damage were reported by nothing: a wrong type, a value outside a declared bound, an over-`MaxLength` string, a value outside an enum or flag set, and a key a closed record does not declare.

    Turned on live, though, the report is mostly noise on any game that has evolved its template. A retired enum member, a tightened bound, or a removed field all report on every profile written before the edit. An undeclared key is reported **once per stored element**, so one retired field on a 40-item inventory produces 32 violations, which is the whole per-load cap, crowding out anything more interesting.

    In Studio those reports reach the person who just made the edit and can still decide whether it needs a migration. On a live server they would print on every join and overwrite the diagnostic ring. Set `SchemaPolicy = "Warn"` explicitly once your template has stopped moving.

??? note "Everything the walk checks"
    Wrong types. Declared numeric bounds, including a [`Scribe.Big`](/api/Scribe#Big)'s, compared at full precision so a bound past the double range still orders correctly. `MaxLength`. Enum and flag membership. Invalid UTF-8. Keys a closed record does not declare.

    Container shape and caps too: `MaxItems` on an [`ArrayOf`](/api/Scribe#ArrayOf) or [`SetOf`](/api/Scribe#SetOf), counted on membership for a set the way the write path counts it, `MaxKeys` and `MaxKeyLength` on a [`DictOf`](/api/Scribe#DictOf), array entries running contiguously from 1, and a table that mixes array indices with string keys.

    A **bounded `Scribe.Big`** went unchecked before Scribe 1.4. A profile whose stored value is outside its bounds, from a raw write through `UpdateOffline`, `OnPlayerInit` or a migration, or from a bound tightened after the value was stored, used to load silently and is now reported. Turn the policy on as `"Warn"` first if that is possible in your data.

    A declared untyped bag is **not** exempt. A `Bag = {}` in a template compiles to a table node with no children rather than to an `any` leaf, so the walk descends into it. Only the bag's contents are unchecked, because its children resolve to `any` and it declares no caps.

    `MaxKeyLength` counts **bytes**, here and at the write boundary alike. A three-character CJK key is nine bytes and trips a cap of eight.

??? note "Only one container finding can end a session, and that is deliberate"
    A table that **mixes array indices with string keys** is the one stored shape that fails the DataStore save of the whole profile, because JSON has no encoding for it. Under `"Reject"` that one ends the session and kicks, which preserves data that would otherwise be lost silently at the next save.

    The other six container findings are advisory. They are reported, logged and fired on `OnAnomaly`, but never a reject, not even under `"Reject"`. They are an array with a hole in it, which after a DataStore round trip comes back as string keys `"1"` and `"3"` rather than as a sparse array, an `ArrayOf` entry stored under a string key, an array index that is not a positive integer, and the three caps `MaxItems`, `MaxKeys` and `MaxKeyLength`. Every one of those saves perfectly well, since JSON stores a sparse array as an object, so there is no data to preserve by kicking.

    Two of them would be actively wrong as a gate. The **caps** fire on a state Scribe's own write path calls legal: a write to a container already over its cap in storage is allowed, because the containers refuse only **growth** past the stored size, so that a rolling deploy which lowers a cap does not strand every profile a newer server wrote. Rejecting the same bytes on load would have the library contradict itself. The **off-shape** group is reachable from ordinary gameplay code, since mutating the live table a container `Get()` hands back is a documented way to reach the data, and one `live[5] = x` on a two-entry array is enough. Under a rejecting policy that would kick the player on every rejoin, permanently, because the stored bytes are deliberately left alone for the next load to fail on again.

    An over-`MaxLength` **string** still rejects, and is not one of the six. A string has no growth-only tolerance anywhere, since the write path refuses or truncates it, so an over-length stored string is a genuine mismatch rather than a tolerated one.

??? note "What the wipe guard measures, and how to break it"
    The guard fires only when the previous save exceeded 1024 bytes and the new size falls below the old size times `1 - WipeGuardShrinkRatio`. At the default of 0.6, a profile has to lose 60 percent of its serialized size in one save.

    The ratio is clamped to 0.05 through 0.95 and warns `WIPE_GUARD_RATIO_CLAMPED` outside that, because both ends are traps. At or below zero every shrink trips the guard, and under `"Block"` it then keeps tripping, since the unblock check is the same comparison, so the session's live data never persists again. At or above one the comparison can never be true and the guard is silently off.

??? note "What `BudgetPolicy = \"Defer\"` paces, and what it never touches"
    It paces the two leaderboard **background** loops, the write queue and the refresh cycle, holding a request back while the relevant DataStore pool is down to its last slot. Nothing is dropped: a write stays queued and a refresh stays due, each retrying next tick, so the only effect is that boards update more slowly under pressure and log `LB_BUDGET_DEFERRED`.

    It works the other way too. When the write queue has genuinely backed up and the ordered-write allowance has room, the pacer drains several queued scores per tick instead of one, bounded by the reported allowance and a hard ceiling. With no backlog it behaves exactly as it does without the policy, so the dedup window that collapses a burst of score changes into a single write is untouched.

    It deliberately touches **no save path**. Receipts, session-end saves and the shutdown drain are all durability-critical and are never deferred. It is inert under a mock mode and inert whenever the engine cannot answer the budget query. Read the raw numbers yourself with [`Scribe.GetBudgetSnapshot`](/api/Scribe#GetBudgetSnapshot).

## Diagnostics

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `DevMode` | `boolean?` | `true` in Studio | Turns on the developer guards: the warnings that catch a typo instead of letting it fail quietly later. |
| `IsRunning` | `boolean?` | `RunService:IsRunning()` | A test seam. `false` builds only the edit-mode client half, which is how a storybook or the command bar gets a tree with no server. Leave it unset in a real place. |
| `LogLevel` | `("Debug" \| "Info" \| "Warn" \| "Error" \| "Fatal")?` | `"Warn"` live, `"Debug"` in Studio | The minimum severity printed to the console. Everything still enters the ring. |
| `LogRingSize` | `number?` | 512 | How many entries [`Scribe.GetRecentLogs`](/api/Scribe#GetRecentLogs) retains. |
| `StatusThresholds` | `{ FailWindow, FailCount, RecoverStreak }?` | `{ 60, 3, 5 }` | Tunes the health machine that moves the service between Healthy, Degraded and Outage. |
| `Banner` | `boolean?` | `true` | Prints one "Running Scribe vX.Y.Z" line when the bundle loads. |

??? note "Exactly what `DevMode` gates"
    It supplies the default for [`SchemaPolicy`](#checking-stored-data-against-the-template), and it gates `UNKNOWN_ROOT_KEYS`, the **server-side** `API_NAME_COLLISION` scan, `UNDECLARED_PERK`, `UNDECLARED_CATEGORY`, `UNKNOWN_OWNS_KEY`, `ECONOMY_FIELD_UNDECLARED`, `ECONOMY_FIELDS_OVERFLOW`, `LB_UNKNOWN_BOARD`, and the `DEV_WARNING` a `Decrement` with a negative delta fires. The client-side name-collision scan is ungated and logs at Error on live servers too.

    Set it `true` in a headless or CI run, where the Studio default is `false` and every one of those warnings is otherwise absent. Set it `false` to quiet them inside Studio. It is independent of the `UNKNOWN_OPTION` scan, which is Studio-only either way. On the client it also gates the debug hook [Scribe Studio](./studio-plugin) reads.

??? note "`LogRingSize` is the only knob a bug report depends on"
    `LogLevel` controls what reaches the console. Every entry enters the ring whatever its level, and past `LogRingSize` the oldest is overwritten. So the ring is the only thing that decides what a bug report can still see.

    Raise it when you are diagnosing something that unfolds over a long session, because 512 entries is a few minutes on a busy server. Leave it alone otherwise: the ring is a **process singleton shared by every bundle**, so the last value applied wins and the memory is paid for the whole server's life. Resizing keeps what it can and drops the oldest that no longer fit, so setting it is a configuration change rather than a request to forget.

    A value below 1, or of the wrong type, is **silently ignored** and 512 is used. There is no warning, so check what you passed if `GetRecentLogs` returns less than you expected. There is no upper bound either, so an absurd value fails inside the allocation rather than being clamped.

??? note "How the health thresholds count"
    Repeated failures of the **same operation on the same subject** count once per retry window rather than once per attempt. One profile that can never be saved shows as Degraded instead of taking the whole server to Outage and refusing every other player's Robux.

    The thresholds count failures per window, not players, so a small server in a genuine outage escalates just as fast as a full one. `FailWindow` is the sliding window in seconds, `FailCount` is how many failures inside it drop Healthy to Degraded, and `RecoverStreak` is how many consecutive successes step the status back. Omitted fields keep their built-in values, and the Outage threshold is derived automatically. See [Diagnostics](./diagnostics).

## Where to next

- [Getting Started](./getting-started) is the two-minute version of this page.
- [Testing & Edit Mode](./testing) puts `Mode` to work.
- [Security](./security) covers the limits above from the attacker's side.
- [Log Code Reference](./log-codes) explains every code named here.
