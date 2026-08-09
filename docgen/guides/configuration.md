# Configuration

Everything you can pass to `Scribe({ … })`. `Template`, `ProfileStoreIndex`, and `ProfileKeyPrefix` are required; every other option is optional with a sensible default. The whole table is typed as `ScribeOptions<T>`, so your editor autocompletes the field names and flags a wrong type. It does **not** flag a misspelled key, because Luau does not reject unknown table keys, so a typo is silently ignored. Scribe warns about one at startup in Studio (`UNKNOWN_OPTION`); on a live server it passes unnoticed, so check the output once after editing your options.

## Persistence mode

`Mode` is one value that says where data comes from, whether a session is held, and whether anything saves. It defaults to `"Live"`.

```lua
Scribe({
    Template = template,
    ProfileStoreIndex = "PlayerData",
    ProfileKeyPrefix = "PLAYER_",
    Mode = "Live",
})
```

| Mode | Reads | Session | Saves |
| --- | --- | --- | --- |
| `Live` (default) | The real profile | Exclusive | Yes |
| `Mock` | ProfileStore's in-memory mock | Mock | To the mock only |
| `NoSave` | A snapshot of the real profile | None | Never |

`TargetUserId` pairs with any mode and loads that user's profile instead of the joining player's. `Mode = "NoSave", TargetUserId = 123` is the safe way to inspect a real profile: you see genuine stored data and nothing can write it back.

`Mode` is the only switch a play-test needs. Every subsystem that touches a store reads the resolved mode, not the legacy flags. Under both `Mock` and `NoSave`, declared [leaderboards](./leaderboards) swap to an in-memory ordered store as well, so a test session cannot write a score into a live OrderedDataStore; those boards start empty and are discarded when the session ends. `Mode = "Mock"` is also what unlocks receipt injection in [Scribe Studio](./studio-plugin), which refuses to inject against any other mode.

`Mode` **replaces** the older `UseMock`, `DontSave`, `ViewedUserId`, and `OverriddenUserId` flags. Those still work when `Mode` is absent, so no existing config changes; set `Mode` and they are ignored with a `MODE_OVERRIDES_LEGACY` warning at startup. The equivalents are below. That table is for reading an older config, not for writing a new one: `Mode` on its own covers everything the flags did, so a new config never needs both.

| Legacy | Mode |
| --- | --- |
| `UseMock = true` or `DontSave = true` | `Mode = "Mock"` |
| `ViewedUserId = id` | `Mode = "NoSave", TargetUserId = id` |
| `OverriddenUserId = id` | `Mode = "Live", TargetUserId = id` |

## Process-wide settings

A few settings belong to the whole game rather than to one bundle, because they configure ProfileStore itself. Set them once, before constructing any bundle:

```lua
Scribe.Configure({ AutoSaveInterval = 60 })
```

`AutoSaveInterval` is the autosave cadence. The per-bundle `SaveInterval` option still works and still wins where it is set, but ProfileStore's `AUTO_SAVE_PERIOD` is a module-wide constant: it applies to every Scribe bundle and to any direct ProfileStore use in the same game. If two bundles ask for different cadences, only one can win (the later one) and Scribe logs `SAVE_INTERVAL_CONFLICT`. Values under 15 seconds clamp up, since Roblox throttles per-key writes to about one per 6 seconds.

For the day-one essentials and a runnable example, see the [quick start](./intro). The feature guides go deeper on the options they use (monetization, leaderboards, testing, and so on); this page is the complete list in one place.

## Core

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `Template` **(required)** | `T` | Required, no default | Defines the shape and default values of every player's saved data. It must be a table; Scribe compiles it into the data schema and deep-freezes it, so it is the single immutable source of truth. |
| `Transport` | `(ScribeTransport \| "Default")?` | "Default" (built-in two-RemoteEvent transport) | Selects the server-to-client replication channel. Leave it unset or set to "Default" to use the built-in transport backed by two RemoteEvents; supply a custom ScribeTransport adapter table only when you need to route replication through your own networking layer. |
| `Migrations` | `{ [number]: (data) -> () }?` | {} (no migrations; data version stays at 1) | Maps each data version number (an integer of 2 or greater) to a function that upgrades a player's stored data up to that version. Set this when your Template's shape changes over time so older profiles are migrated on load; omitting it keeps the data version pinned at 1 and runs no migrations. |
| `MigrationShadow` | `boolean?` | off (no shadow run) | An audit aid for [migrations](./lifecycle#migrations). Scribe fills missing template keys with their defaults **before** migrations run, so a step guarded on `if data.Field == nil` sees a manufactured default and silently does nothing for returning players. With this on, Scribe re-runs the same chain a second time against the raw stored data and warns `MIGRATION_RECONCILE_DEPENDENT` when the two runs diverge, or when the raw run throws where the reconciled one did not. It runs only for a profile that has stored data below the current version (never for a new profile or a `ResetData` wipe). It is deliberately opt-in rather than automatic in Studio, because the shadow re-executes your migration bodies: any side effect in them fires twice, and a step using `math.random`, `os.time`, or an external write warns spuriously. Turn it on while auditing a new migration, then turn it off. Nothing gates it on Studio, so it also runs on a live server when set. |
| `Economy` | `EconomyConfig?` | nil | Economy analytics configuration: per-currency labels, custom field declarations, and ambient value resolvers, plus the `LogEconomyEvent` test seam. Tagged `Increment`/`Decrement` calls emit `AnalyticsService:LogEconomyEvent` from it. See the [Economy Analytics](./economy) guide. |
| `OnPlayerInit` | `((player: Player, rawData, isNewProfile: boolean) -> ())?` | nil (no callback runs) | A callback invoked once per player right after their profile finishes loading, receiving the Player, their raw data table, and `isNewProfile` (true for a brand-new profile, a `ResetData` wipe, or a first-session crash recovery, so you can run starter-kit or welcome logic without a sentinel field). Use it for per-player setup that needs the freshly loaded data, such as building leaderstats or one-time grants; any error it throws is caught and logged rather than blocking the load. |
| `OnPlayerLeaving` | `((player: Player, data, reason: LifecycleReason) -> ())?` | nil (no callback runs) | A callback invoked once per player as they leave, receiving the Player, their typed accessor tree, and the reason (`player-left`, `shutdown`, `session-ended`, ...). It runs BEFORE the final save, so anything it writes persists. This is where an accumulate-on-exit value belongs, such as playtime or a session summary: writing from your own `PlayerRemoving` handler races Scribe's, decided by connection order, and a write after teardown is lost. It runs at most once per session, and any error it throws is caught and logged rather than skipping the save it was meant to contribute to. |

## Persistence & sessions

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `ProfileStoreIndex` **(required)** | `string` | Required, no default | The DataStore name your game's profiles live under, passed straight to ProfileStore.New. It is intentionally never defaulted so two games or a test build can't silently share one store; Scribe errors at construction if it is missing or empty. |
| `ProfileKeyPrefix` **(required)** | `string` | Required, no default | A per-player key prefix (for example "PLAYER_") that is concatenated with the user id to form each profile key. It must be present and a string, so the choice is always deliberate, but `""` is valid and means the key is the bare user id. Use `""` when adopting a database whose keys were only the user id; change it otherwise only when you deliberately want a fresh, isolated key namespace. |
| `SaveInterval` | `number?` | 300 (ProfileStore's autosave period is left unchanged; values below 15 are clamped to 15) | Seconds between automatic profile saves. Set it to lose less progress on an unclean exit; note it configures ProfileStore's global AUTO_SAVE_PERIOD so it affects every bundle, must be a positive number, and is clamped up to the 15s floor because of DataStore write throttling. |
| `ProfileStore` | `any?` | Auto-discovered (Scribe locates the ProfileStore package in the usual Wally/Packages folders) | An explicit ProfileStore module, given as the module table itself or as a ModuleScript instance to require. Provide it when Scribe can't auto-find the package or you want to inject a specific build; otherwise it searches the common package roots and errors if none is found. |
| `UseMock` | `boolean?` | off (uses the real DataStore-backed store) | **Superseded by `Mode = "Mock"`.** When true, routes all reads and writes through ProfileStore's in-memory Mock store so nothing touches live DataStores. Turn it on for tests and local experiments where you don't want to persist real data. |
| `ViewedUserId` | `number?` | nil (each player loads their own live profile with a normal session) | **Superseded by `Mode = "NoSave", TargetUserId = id`.** Loads another user's stored profile read-only via GetAsync instead of starting a session, and never saves. Set it for inspection or testing to view a specific player's data; if that profile isn't found the entry tears down. |
| `OverriddenUserId` | `number?` | nil (uses the joining player's real UserId) | **Superseded by `Mode = "Live", TargetUserId = id`.** Forces every joining player to load and save under this user id instead of their own. Useful in testing to pin all sessions to one known key; leave it unset in production so each player uses their real id. |
| `DontSave` | `boolean?` | off (writes persist normally) | **Superseded by `Mode = "Mock"`.** When true, swaps in ProfileStore's Mock store just like UseMock so changes are held in memory and never written back to DataStores. Enable it when you want a normal session but with all persistence suppressed. |
| `ResetData` | `boolean?` | off (existing saved data is loaded as-is) | When true, wipes each loaded profile back to the template's persistent defaults on load and logs a reset warning. Use it deliberately to clear saved progress; leave it off so returning players keep their data. |
| `LoadFailurePolicy` | `("Kick" \| "Wait")?` | "Kick" | What to do when a player's profile repeatedly fails to load. "Kick" removes the player with the load-failure message, while "Wait" keeps them in a loading state and retries with backoff rather than ever falling back to template data. This applies only when the load actually returns without a profile, such as a session claimed by another server. It does not apply to a DataStore outage: ProfileStore retries internally and does not time out while the player is in the server, so the player stays in a loading state whichever policy is set. |
| `VersionAheadPolicy` | `("Kick" \| "Allow")?` | "Kick" | How to handle a stored profile whose migration version is newer than this server's code (a staged-deploy hazard). "Kick" fails closed and refuses the session, while "Allow" runs the older code against the newer data and only logs a warning. |
| `KickOnSessionEnd` | `boolean?` | true | When a player's data session ends unexpectedly (not a normal leave, and not during shutdown), Scribe kicks them so they can rejoin with a fresh session. Set it to false to keep such players in-game without a working data session. |
| `LoadFailureMessage` | `string?` | "We couldn't load your data. Please rejoin!" | The kick message shown when a profile fails to load under the "Kick" policy or when a migration fails. Set it to give players a branded or clearer explanation before they rejoin. |
| `SessionEndMessage` | `string?` | "Your data session has ended. Please rejoin!" | The kick message used when a session ends and KickOnSessionEnd is in effect. Customize it to match your game's tone or to tell players why they were removed. |

## Monetization & services

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `Leaderboards` | `{ [string]: LeaderboardConfig }?` | None (no leaderboards registered) | Registers all-time OrderedDataStore leaderboards keyed by name, each with a required Stat path plus optional Limit (clamped 1 to 100, default 100), Scale (default 1), SigFigs (`Scribe.Big` stats only, a whole number from 1 to 15, default 12: how many significant figures the ranking key carries, trading exponent range for resolution), Replicate (default false, meaning server-only and not streamed to clients), RefreshInterval (seconds between reads of that board, default 60 and clamped up to a 60 second floor), and StoreName (default `"LB_<name>"`, or `"LB_<name>_big<SigFigs>"` for a `Scribe.Big` stat, since exponent-major and plain-numeric are two key layouts that must never share a store). On a `Scribe.Big` stat, `Scale` and `Replicate` are both refused at startup: the exponent packing already maps the value into the key space, and a big Score does not fit the board frame's f64. Set it when you want ranked global boards; a Stat that is missing or descends through a leaf field errors at startup, as does a set of boards whose combined refresh rate would read the OrderedDataStore too often. Use `RefreshInterval` to read a board **less** often; for a live in-server scoreboard use [`Scribe.Shared`](./visibility) instead, which updates instantly at no DataStore cost. |
| `Products` | `{ [string]: ProductConfig }?` | None (no products registered) | Declares developer products by name, each with a numeric Id and optional Category, Grant callback, and Grants perk key. Set it so receipts, in-memory grants, and gifting can resolve a product; a non-numeric or duplicate Id errors at startup, and receipts for unregistered products are declined. |
| `Passes` | `{ [string]: PassConfig }?` | None (no passes registered) | Declares game passes by name, each with a numeric Id and optional Category. Set it so ownership is cached and refreshed and Data.Owns can report pass ownership; a non-numeric Id errors at startup. |
| `Perks` | `{ string }?` | None (no perk registry, perk names not validated) | A list of valid perk key names used only as a typo guard. When provided, granting or referencing a perk not in the list logs a dev-mode warning; when omitted, any perk key is accepted silently. |
| `OwnReceipts` | `boolean?` | true (this bundle binds MarketplaceService.ProcessReceipt) | Controls whether this bundle installs the single global MarketplaceService.ProcessReceipt callback. Leave it on for the primary bundle; set it to false on any secondary bundle (a second owner errors at startup) and route those receipts manually through Data.HandleReceipt. |
| `PurchaseLog` | `{ RobuxCap: number?, InGameCap: number?, ReplicateRobux: boolean?, ReplicateInGame: boolean?, PurchaseLogCategories: { string }? }?` | Omitted: RobuxCap and InGameCap each default to 100, logs stay server-only, no category registry | Tunes the per-player purchase log rings: RobuxCap and InGameCap bound how many Robux and in-game entries are kept (default 100 each, oldest dropped), ReplicateRobux and ReplicateInGame opt each kind into client replication (default false, server-only), and PurchaseLogCategories declares allowed category names for a dev-mode typo warning. Set it to raise the history size or to expose purchase history to clients. |
| `UserOwnsGamePassAsync` | `((userId: number, passId: number) -> boolean)?` | nil (calls `MarketplaceService:UserOwnsGamePassAsync`) | Replaces the Roblox call behind every pass-ownership check: the per-player ownership cache built at load, and the authoritative live re-check `Data.OwnsAsync` performs on each call. It exists as a test seam, because a headless run cannot patch a real service Instance; a spec passes a function that answers from a fixed ownership map. Leave it unset in production, and note that ordinary Studio play-testing with a real pass needs nothing here. |

## Gifting

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `GiftCooldown` | `number?` | 5 | Minimum number of seconds a sender must wait between successive gift prompts. Raise it to throttle spammy or abusive gifting; a PromptGift call inside the window is rejected with "gift cooldown". |
| `GiftMaxPending` | `number?` | 20 | Maximum number of unresolved (pending) gift intents a single sender can have at once. Once this many gifts are awaiting their receipt, further PromptGift calls are rejected with "too many pending gifts" until some settle. |
| `GiftIntentTTL` | `number?` | 3600 | How long, in seconds, a recorded gift intent stays valid before it is treated as abandoned. After it expires the incoming purchase receipt is handled by NoGiftIntentPolicy instead of being delivered to the recipient; lengthen it if players routinely take a long time to complete the Robux prompt. |
| `PurchaseIdTTL` | `number?` | 604800 (7 days) | How long a processed receipt's `PurchaseId` is remembered for de-duplication. Past this a retry can no longer arrive, so the entry is provably safe to forget, which keeps the ring small enough that the count backstop below never has to run. Lower it only if you know your retry window is shorter. |
| `MaxProcessedPurchaseIds` | `number?` | 200 | Hard ceiling on the de-duplication ring. When entries have **not** yet aged out and the ring is full, the oldest is dropped to make room and `PURCHASE_ID_EVICTED` is logged. That is the one eviction that could let a retried receipt grant twice, so raise this if you see it (a game with very high per-player purchase volume can outrun `PurchaseIdTTL`). |
| `AllowDuplicateGifts` | `boolean?` | false (off) | When off, gifting a perk product the recipient already owns is blocked at prompt time and any purchase that would double-grant is converted into a re-aimable gift credit for the buyer instead. Set it true to permit gifting perks the recipient already has. |
| `NoGiftIntentPolicy` | `("GrantOrCredit" \| "Hold")?` | "GrantOrCredit" | Decides what happens to a gift-product receipt that arrives with no matching (or expired) intent when the buyer already owns the perk. "GrantOrCredit" writes a durable unassigned gift credit the buyer can re-aim later; "Hold" declines the receipt (Roblox retries and eventually refunds) so no credit is minted. |

## Behaviour & limits

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `CommandRateLimit` | `number?` | 20 | Per-player ceiling on server command RPCs per second, enforced as a token bucket that refills at this rate and is capped at this value. Lower it to tighten protection against command spam, or raise it for clients that legitimately fire many commands per second. |
| `RequestTimeout` | `number?` | 10 | How many seconds a client command request waits for a server reply before it gives up and resolves with false and a "timeout" reason. Set it shorter for snappier failure handling or longer to tolerate slow round trips. |
| `MaxInboundBytes` | `number?` | 8192 | Maximum size in bytes of a single inbound frame the server will accept from a client; anything larger is dropped and logged as INBOUND_OVERSIZE. Raise it only if legitimate client requests exceed the limit, or lower it to harden against oversized payloads. |
| `MaxInboundFrameRate` | `number?` | `max(60, CommandRateLimit * 4)` | Per-player ceiling on **raw inbound frames per second**, spent before a frame is read at all. It is the only limit that covers every frame whatever its type, size, or validity (an oversized frame counts against no other budget). Unlike `CommandRateLimit` it drops silently rather than replying, so keep it well above that value: a client that trips this one is stranded until its `RequestTimeout` rather than told "rate-limited". Lower it only if you know what your busiest legitimate client sends. |
| `TransportChannel` | `string?` | nil (uses the shared "ScribeTransport" default folder) | Names the ReplicatedStorage folder and RemoteEvents this instance uses, isolating its traffic from other instances. Set a distinct channel when running more than one Scribe instance so they do not share RemoteEvents and fail decoding each other's frames. |

## Integrity

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `BoundsPolicy` | `("Clamp" \| "Reject")?` | "Clamp" | Controls how writes that violate a field's declared numeric bounds (or non-integer writes to an Int field) are handled. "Clamp" rounds and clamps the value into range while firing an anomaly, whereas "Reject" throws a validation error at the write site; set "Reject" when you want bad writes to fail loudly instead of being silently corrected. |
| `WipeGuardPolicy` | `("Warn" \| "Block")?` | "Warn" | Decides what the wipe guard does when a save looks like accidental data loss (top-level keys vanished or serialized size collapsed). "Warn" logs an error and fires an anomaly but still persists the data, while "Block" additionally holds the save and writes the last good snapshot instead until the guard clears or a forced flush; use "Block" for stronger protection against destructive saves. |
| `WipeGuardShrinkRatio` | `number?` | 0.6 | The fractional drop in serialized data size that trips the wipe guard, which only fires when the previous save exceeded 1024 bytes and the new size falls below old size times (1 - ratio). Raise it to require a larger collapse before flagging a suspected wipe, or lower it to catch smaller shrinkages. |

## Diagnostics

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `DevMode` | `boolean?` | true in Studio, false on a live server (`RunService:IsStudio()`) | The switch behind Scribe's developer guards: the warnings that catch a typo or a misuse instead of letting it fail quietly at runtime. It gates `UNKNOWN_ROOT_KEYS`, the **server-side** `API_NAME_COLLISION` scan (the client-side one is ungated and logs at Error on live servers too), `UNDECLARED_PERK`, `UNDECLARED_CATEGORY`, `UNKNOWN_OWNS_KEY`, `ECONOMY_FIELD_UNDECLARED`, `ECONOMY_FIELDS_OVERFLOW`, `LB_UNKNOWN_BOARD`, and the `DEV_WARNING` a `Decrement` called with a negative delta fires. Set it true in a headless or CI run, where the Studio default is false and every one of those warnings is otherwise absent; set it false to quiet them inside Studio. It is independent of the `UNKNOWN_OPTION` option-name scan, which is Studio-only either way. On the client it also gates the debug hook [Scribe Studio](./studio-plugin) reads for its client view. |
| `LogLevel` | `("Debug" \| "Info" \| "Warn" \| "Error" \| "Fatal")?` | "Warn" on live servers, "Debug" in Studio | Sets the minimum severity that gets printed to the console; anything below this level is suppressed from output while still being kept in the in-memory ring buffer that Scribe.GetRecentLogs reads. Raise it (e.g. "Error") to quiet a noisy live game, or lower it (e.g. "Debug") when diagnosing an issue. An unrecognized value is silently ignored and the current level is kept. |
| `StatusThresholds` | `{ FailWindow: number?, FailCount: number?, RecoverStreak: number? }?` | `{ FailWindow = 60, FailCount = 3, RecoverStreak = 5 }` | Tunes the health state machine that moves the service between Healthy, Degraded, and Outage. FailWindow is the sliding window in seconds, FailCount is how many failures inside that window drop Healthy to Degraded, and RecoverStreak is how many consecutive successes step the status back down. Set it to make outage detection more or less sensitive; omitted fields keep their built-in values and the Outage threshold is derived automatically. |
| `Banner` | `boolean?` | true (prints the load banner) | Controls the single "Running Scribe vX.Y.Z ... initialized" line printed once when the bundle finishes loading on the server and client. Set it to false to silence that startup line in production or in tests. |
