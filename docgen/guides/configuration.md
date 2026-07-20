---
sidebar_position: 5
---

# Configuration

Everything you can pass to `Scribe({ … })`. `Template`, `ProfileStoreIndex`, and `ProfileKeyPrefix` are required; every other option is optional with a sensible default. The whole table is typed as `ScribeOptions<T>`, so your editor autocompletes the field names and flags a wrong type or a misspelled key.

For the day-one essentials and a runnable example, see the [quick start](./intro). The feature guides go deeper on the options they use (monetization, leaderboards, testing, and so on); this page is the complete list in one place.

## Core

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `Template` **(required)** | `T` | Required, no default | Defines the shape and default values of every player's saved data. It must be a table; Scribe compiles it into the data schema and deep-freezes it, so it acts as the single immutable source of truth for what each player's data looks like. |
| `Transport` | `(ScribeTransport \| "Default")?` | "Default" (built-in two-RemoteEvent transport) | Selects the server-to-client replication channel. Leave it unset or set to "Default" to use the built-in transport backed by two RemoteEvents; supply a custom ScribeTransport adapter table only when you need to route replication through your own networking layer. |
| `Migrations` | `{ [number]: (data) -> () }?` | {} (no migrations; data version stays at 1) | Maps each data version number (an integer of 2 or greater) to a function that upgrades a player's stored data up to that version. Set this when your Template's shape changes over time so older profiles are migrated on load; omitting it keeps the data version pinned at 1 and runs no migrations. |
| `Economy` | `EconomyConfig?` | nil | Economy analytics configuration: per-currency labels, custom field declarations, and ambient value resolvers, plus the `LogEconomyEvent` test seam. Tagged `Increment`/`Decrement` calls emit `AnalyticsService:LogEconomyEvent` from it. See the [Economy Analytics](./economy) guide. |
| `OnPlayerInit` | `((player: Player, rawData, isNewProfile: boolean) -> ())?` | nil (no callback runs) | A callback invoked once per player right after their profile finishes loading, receiving the Player, their raw data table, and `isNewProfile` (true for a brand-new profile, a `ResetData` wipe, or a first-session crash recovery, so you can run starter-kit or welcome logic without a sentinel field). Use it for per-player setup that needs the freshly loaded data, such as building leaderstats or one-time grants; any error it throws is caught and logged rather than blocking the load. |

## Persistence & sessions

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `ProfileStoreIndex` **(required)** | `string` | Required, no default | The DataStore name your game's profiles live under, passed straight to ProfileStore.New. It is intentionally never defaulted so two games or a test build can't silently share one store; Scribe errors at construction if it is missing or empty. |
| `ProfileKeyPrefix` **(required)** | `string` | Required, no default | A per-player key prefix (for example "PLAYER_") that is concatenated with the user id to form each profile key. It is required and errors if missing or empty; change it only when you deliberately want a fresh, isolated key namespace. |
| `SaveInterval` | `number?` | 300 (ProfileStore's autosave period is left unchanged; values below 15 are clamped to 15) | Seconds between automatic profile saves. Set it to lose less progress on an unclean exit; note it configures ProfileStore's global AUTO_SAVE_PERIOD so it affects every bundle, must be a positive number, and is clamped up to the 15s floor because of DataStore write throttling. |
| `ProfileStore` | `any?` | Auto-discovered (Scribe locates the ProfileStore package in the usual Wally/Packages folders) | An explicit ProfileStore module, given as the module table itself or as a ModuleScript instance to require. Provide it when Scribe can't auto-find the package or you want to inject a specific build; otherwise it searches the common package roots and errors if none is found. |
| `UseMock` | `boolean?` | off (uses the real DataStore-backed store) | When true, routes all reads and writes through ProfileStore's in-memory Mock store so nothing touches live DataStores. Turn it on for tests and local experiments where you don't want to persist real data. |
| `ViewedUserId` | `number?` | nil (each player loads their own live profile with a normal session) | Loads another user's stored profile read-only via GetAsync instead of starting a session, and never saves. Set it for inspection or testing to view a specific player's data; if that profile isn't found the entry tears down. |
| `OverriddenUserId` | `number?` | nil (uses the joining player's real UserId) | Forces every joining player to load and save under this user id instead of their own. Useful in testing to pin all sessions to one known key; leave it unset in production so each player uses their real id. |
| `DontSave` | `boolean?` | off (writes persist normally) | When true, swaps in ProfileStore's Mock store just like UseMock so changes are held in memory and never written back to DataStores. Enable it when you want a normal session but with all persistence suppressed. |
| `ResetData` | `boolean?` | off (existing saved data is loaded as-is) | When true, wipes each loaded profile back to the template's persistent defaults on load and logs a reset warning. Use it deliberately to clear saved progress; leave it off so returning players keep their data. |
| `LoadFailurePolicy` | `("Kick" \| "Wait")?` | "Kick" | What to do when a player's profile repeatedly fails to load. "Kick" removes the player with the load-failure message, while "Wait" keeps them in a loading state and retries with backoff rather than ever falling back to template data. |
| `VersionAheadPolicy` | `("Kick" \| "Allow")?` | "Kick" | How to handle a stored profile whose migration version is newer than this server's code (a staged-deploy hazard). "Kick" fails closed and refuses the session, while "Allow" runs the older code against the newer data and only logs a warning. |
| `KickOnSessionEnd` | `boolean?` | true | When a player's data session ends unexpectedly (not a normal leave, and not during shutdown), Scribe kicks them so they can rejoin with a fresh session. Set it to false to keep such players in-game without a working data session. |
| `LoadFailureMessage` | `string?` | "We couldn't load your data. Please rejoin!" | The kick message shown when a profile fails to load under the "Kick" policy or when a migration fails. Set it to give players a branded or clearer explanation before they rejoin. |
| `SessionEndMessage` | `string?` | "Your data session has ended. Please rejoin!" | The kick message used when a session ends and KickOnSessionEnd is in effect. Customize it to match your game's tone or to tell players why they were removed. |

## Monetization & services

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `Leaderboards` | `{ [string]: LeaderboardConfig }?` | None (no leaderboards registered) | Registers all-time OrderedDataStore leaderboards keyed by name, each with a required Stat path plus optional Limit (clamped 1 to 100, default 100), Scale (default 1), Replicate (default false, meaning server-only and not streamed to clients), and StoreName (default `"LB_<name>"`). Set it when you want ranked global boards; a Stat that is missing or descends through a leaf field errors at startup. |
| `Products` | `{ [string]: ProductConfig }?` | None (no products registered) | Declares developer products by name, each with a numeric Id and optional Category, Grant callback, and Grants perk key. Set it so receipts, in-memory grants, and gifting can resolve a product; a non-numeric or duplicate Id errors at startup, and receipts for unregistered products are declined. |
| `Passes` | `{ [string]: PassConfig }?` | None (no passes registered) | Declares game passes by name, each with a numeric Id and optional Category. Set it so ownership is cached and refreshed and Data.Owns can report pass ownership; a non-numeric Id errors at startup. |
| `Perks` | `{ string }?` | None (no perk registry, perk names not validated) | A list of valid perk key names used only as a typo guard. When provided, granting or referencing a perk not in the list logs a dev-mode warning; when omitted, any perk key is accepted silently. |
| `OwnReceipts` | `boolean?` | true (this bundle binds MarketplaceService.ProcessReceipt) | Controls whether this bundle installs the single global MarketplaceService.ProcessReceipt callback. Leave it on for the primary bundle; set it to false on any secondary bundle (a second owner errors at startup) and route those receipts manually through Data.HandleReceipt. |
| `PurchaseLog` | `{ RobuxCap: number?, InGameCap: number?, ReplicateRobux: boolean?, ReplicateInGame: boolean?, PurchaseLogCategories: { string }? }?` | Omitted: RobuxCap and InGameCap each default to 100, logs stay server-only, no category registry | Tunes the per-player purchase log rings: RobuxCap and InGameCap bound how many Robux and in-game entries are kept (default 100 each, oldest dropped), ReplicateRobux and ReplicateInGame opt each kind into client replication (default false, server-only), and PurchaseLogCategories declares allowed category names for a dev-mode typo warning. Set it to raise the history size or to expose purchase history to clients. |

## Gifting

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `GiftCooldown` | `number?` | 5 | Minimum number of seconds a sender must wait between successive gift prompts. Raise it to throttle spammy or abusive gifting; a PromptGift call inside the window is rejected with "gift cooldown". |
| `GiftMaxPending` | `number?` | 20 | Maximum number of unresolved (pending) gift intents a single sender can have at once. Once this many gifts are awaiting their receipt, further PromptGift calls are rejected with "too many pending gifts" until some settle. |
| `GiftIntentTTL` | `number?` | 3600 | How long, in seconds, a recorded gift intent stays valid before it is treated as abandoned. After it expires the incoming purchase receipt is handled by NoGiftIntentPolicy instead of being delivered to the recipient; lengthen it if players routinely take a long time to complete the Robux prompt. |
| `AllowDuplicateGifts` | `boolean?` | false (off) | When off, gifting a perk product the recipient already owns is blocked at prompt time and any purchase that would double-grant is converted into a re-aimable gift credit for the buyer instead. Set it true to permit gifting perks the recipient already has. |
| `NoGiftIntentPolicy` | `("GrantOrCredit" \| "Hold")?` | "GrantOrCredit" | Decides what happens to a gift-product receipt that arrives with no matching (or expired) intent when the buyer already owns the perk. "GrantOrCredit" writes a durable unassigned gift credit the buyer can re-aim later; "Hold" declines the receipt (Roblox retries and eventually refunds) so no credit is minted. |

## Behaviour & limits

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `CommandRateLimit` | `number?` | 20 | Per-player ceiling on server command RPCs per second, enforced as a token bucket that refills at this rate and is capped at this value. Lower it to tighten protection against command spam, or raise it for clients that legitimately fire many commands per second. |
| `RequestTimeout` | `number?` | 10 | How many seconds a client command request waits for a server reply before it gives up and resolves with false and a "timeout" reason. Set it shorter for snappier failure handling or longer to tolerate slow round trips. |
| `MaxInboundBytes` | `number?` | 8192 | Maximum size in bytes of a single inbound frame the server will accept from a client; anything larger is dropped and logged as INBOUND_OVERSIZE. Raise it only if legitimate client requests exceed the limit, or lower it to harden against oversized payloads. |
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
| `LogLevel` | `("Debug" \| "Info" \| "Warn" \| "Error" \| "Fatal")?` | "Warn" on live servers, "Debug" in Studio | Sets the minimum severity that gets printed to the console; anything below this level is suppressed from output while still being kept in the in-memory ring buffer that Scribe.GetRecentLogs reads. Raise it (e.g. "Error") to quiet a noisy live game, or lower it (e.g. "Debug") when diagnosing an issue. An unrecognized value is silently ignored and the current level is kept. |
| `StatusThresholds` | `{ FailWindow: number?, FailCount: number?, RecoverStreak: number? }?` | `{ FailWindow = 60, FailCount = 3, RecoverStreak = 5 }` | Tunes the health state machine that moves the service between Healthy, Degraded, and Outage. FailWindow is the sliding window in seconds, FailCount is how many failures inside that window drop Healthy to Degraded, and RecoverStreak is how many consecutive successes step the status back down. Set it to make outage detection more or less sensitive; omitted fields keep their built-in values and the Outage threshold is derived automatically. |
| `Banner` | `boolean?` | true (prints the load banner) | Controls the single "Running Scribe vX.Y.Z ... initialized" line printed once when the bundle finishes loading on the server and client. Set it to false to silence that startup line in production or in tests. |
