# Testing & Edit Mode

## Testing in Studio safely

A handful of options let you play-test without touching (or corrupting) live data:

| Option | Effect |
| --- | --- |
| `Mode = "Mock"` | Full in-memory mock store: profiles AND leaderboards. Nothing is read from or written to real DataStores; every profile loads as fresh template defaults. |
| `Mode = "NoSave"` | Load the REAL profile as a snapshot and never save it. This is the option for validating real data safely. Add `TargetUserId = <id>` to inspect one specific player. Leaderboards use the mock store here too, since a board write is a write. |
| `ResetData = true` | **Destructive**: every profile loads as template defaults. Development only. |
| `Banner = false` | Silence the one-line load banner. |

`Mode` is the whole answer. Every subsystem that touches a store reads the **resolved** mode, so declared [leaderboards](./leaderboards) swap to an in-memory ordered store under both `"Mock"` and `"NoSave"`, and a play-test cannot publish a score into a live OrderedDataStore. `Mode = "Mock"` is also what unlocks receipt injection in [Scribe Studio](./studio-plugin). The older `UseMock` / `DontSave` / `ViewedUserId` flags still work and map onto these modes, but a new config never needs them: set `Mode` alongside one and it wins, with a `MODE_OVERRIDES_LEGACY` warning at startup. See [configuration](./configuration#persistence-mode).

:::tip Not saving at all, in any mode?
Check **File → Experience Settings → Security → "Enable Studio Access to API Services"** before you debug anything else. With it off, ProfileStore falls back to an in-memory store on its own and prints `[ProfileStore]: Roblox API services unavailable - data will not be saved`, so `Mode = "Live"` behaves like `"Mock"` and nothing you do in the options table will change it.
:::

## Edit mode & storybooks

When `RunService:IsRunning()` is false (a UI Labs / Hoarcekat storybook, or the command bar), the client module skips the transport and handshake entirely and initializes **instantly** to template defaults. `Observe` and `Changed` work normally, so Scribe-backed components render and live-update without a running server.

A story requires the same shared bundle module a live client does — `require(ReplicatedStorage.Source.Data).Client` — and gets the client half. Edit mode reports `RunService:IsServer()` as **true**, so `Scribe(options)` treats `IsRunning` as the deciding signal: with nothing running there is no server to build, no `ScribeTransport` folder is created in `ReplicatedStorage`, and touching `.Server` errors with an edit-mode message rather than starting a session.

[Derived fields](./derived) need nothing extra here: seed their inputs and the computed value follows, because the edit-mode client runs the same recompute the server does.

Seed realistic state with the mock helpers (edit mode only):

```lua
Data.Mock({
    Coins = 1250,
    Inventory = { Sword = { Health = 100, Dmg = 5 } },
}, {
    Perks = { "VIP" },
    GiftCredits = { StarterPack = 2 },
    Leaderboards = { TopCoins = { { Rank = 1, UserId = 1, Name = "You", Score = 1250 } } },
    PurchaseLogs = {
        Robux = { { PurchaseId = "p1", Product = "StarterPack", Category = "Bundle", PriceInRobux = 99, Ts = os.time() } },
        InGame = { { Category = "Shop", ItemId = "Sword", Ts = os.time() } },
    },
})

Data.MockCommand("EquipItem", function(itemId) return true end)
```

The first argument seeds your own template fields. The second seeds the Scribe-owned state that the monetization and leaderboard APIs read, and it takes four keys: `Perks` (feeds [`Owns`](/api/Client#Owns) and [`ObserveOwned`](/api/Client#ObserveOwned)), `GiftCredits` ([`GetGiftCredits`](/api/Client#GetGiftCredits)), `Leaderboards` ([`GetLeaderboard`](/api/Client#GetLeaderboard)), and `PurchaseLogs` ([`GetPurchases`](/api/Client#GetPurchases)). `PurchaseLogs` takes `Robux` and `InGame` arrays, each holding whole log entries. Seeding it works regardless of the `PurchaseLog` replication flags: those flags govern what a live server sends, and edit mode replicates nothing.

:::note Mock seeds go through the same validation as a live write
`Data.Mock` writes each root field with a normal accessor `Set`, so a seed for a [`Scribe.ArrayOf`](/api/Scribe#ArrayOf) or [`Scribe.DictOf`](/api/Scribe#DictOf) field is checked against the element shape: an undeclared field is rejected, array entries must run contiguously from 1, dictionary keys must be strings, and the size caps still apply. Pass real datatypes (a `CFrame`, not a packed buffer); Scribe packs them for you.
:::

Both [`Mock`](/api/Client#Mock) and [`MockCommand`](/api/Client#MockCommand) error outside edit mode, so they can't leak into a real session.

## Scribe Studio

For interactive testing, the **[Scribe Studio companion plugin](./studio-plugin)** renders the whole diagnostics layer as a live dock: inspect sessions, replay the change feed, simulate outages, invoke commands, and even edit production profiles. It's the fastest way to exercise everything without writing throwaway scripts.

## Headless tests

Scribe's own suite runs both in Studio (TestEZ) and headless via [Lune](https://lune-org.github.io/docs), against a deterministic fake ProfileStore and a stub transport. The same `Server.build` entry point the harness uses lets you construct isolated instances and drive the player lifecycle yourself, which is how you unit-test your own game logic against Scribe without a live DataStore.

`Server.build` is internal: it is not on the bundle `Scribe({})` returns, and neither is the template compiler. Both live inside the package folder, which Wally's `Packages.Scribe` link module does not expose as children, so reach them through `_Index`. `build` returns **two** values, the `Data` API and the context:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)
local ScribeRoot = ReplicatedStorage.Packages._Index["ericplane_scribe@{{version}}"].scribe
local Template = require(ScribeRoot.Internal.Template)
local Server = require(ScribeRoot.Server)

local options = {
    Template = { Coins = Scribe.Int(0, { Min = 0 }) },
    ProfileStoreIndex = "Test",
    ProfileKeyPrefix = "PLAYER_",
    Mode = "Mock",
    TransportChannel = "Test", -- the default channel can only be bound once
    OwnReceipts = false,       -- don't touch MarketplaceService.ProcessReceipt
    KickOnSessionEnd = false,
    LogLevel = "Fatal",        -- `build` prints no load banner, so quiet the log
}

local compiled = Template.Compile(options.Template)
local Data, ctx = Server.build(options, compiled)

-- Nothing is wired to the engine, so drive the lifecycle by hand:
ctx.Persistence.OnPlayerAdded(player)
local data, reason = ctx.Persistence.WaitForData(player) -- (accessor?, reason?)
assert(data, reason)
data.Coins.Increment(50)
ctx.Persistence.OnPlayerRemoving(player)
```

The difference from `Server.new` is exactly that wiring: `build` connects no `PlayerAdded` / `PlayerRemoving` and binds no shutdown handler, so nothing happens until you call those yourself. Accessors are torn down with the entry, so read what you need before `OnPlayerRemoving`. `Template.Compile`'s second argument is optional and only matters if you test replicated purchase logs (`{ ReplicateRobuxLog = true, ReplicateInGameLog = true }`, which `Scribe({})` derives from the `PurchaseLog` option). Pass `ProfileStore = <your fake>` to swap the store entirely, and a custom `Transport` table instead of `TransportChannel` to capture frames.

Being internal, this entry point carries no compatibility promise the public API does.
