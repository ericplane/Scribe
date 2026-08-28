# Testing & Edit Mode

Play-testing a game that saves data is risky, because a bad play-test can overwrite your own profile or write a junk score onto a live leaderboard. Scribe has one option that closes off every store it touches, and a second mode that lets storybooks and UI components render real-looking data with no server running at all.

## Play-testing without touching live data

Set `Mode` in your options table and every subsystem that reaches a store reads it.

```lua
return Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",
    Mode = "Mock",   -- nothing this session reads or writes a real DataStore
})
```

| Mode | What happens |
| --- | --- |
| `"Live"` | The default. Real profiles, real leaderboards. |
| `"Mock"` | A full in-memory store for both profiles and leaderboards. Every profile loads as fresh template defaults. |
| `"NoSave"` | Loads the **real** profile as a snapshot and never saves it. Add `TargetUserId = <id>` to inspect one specific player. Leaderboards are mocked here too, because a board write is still a write. |

`Mode = "NoSave"` is the one to reach for when you want to validate your template against data that really exists. `Mode = "Mock"` tells you nothing about your stored shapes, because nothing was ever stored.

Two smaller options often ride along. `ResetData = true` loads every profile as template defaults and is **destructive**, so keep it out of anything you might publish. `Banner = false` silences the one-line startup message.

!!! warning "Not saving at all, in any mode?"
    Check **File, Experience Settings, Security, "Enable Studio Access to API Services"** before you debug anything else. With it off, ProfileStore falls back to an in-memory store on its own and prints `[ProfileStore]: Roblox API services unavailable - data will not be saved`, so `Mode = "Live"` behaves like `"Mock"` and nothing in your options table will change it.

??? note "The older UseMock and DontSave flags"
    `UseMock`, `DontSave` and `ViewedUserId` still work and map onto the three modes above, so an existing config keeps running. A new config never needs them. Set `Mode` alongside one of them and `Mode` wins, with a `MODE_OVERRIDES_LEGACY` warning at startup. See [configuration](./configuration#persistence-mode).

## Edit mode and storybooks

When `RunService:IsRunning()` is false, which covers a UI Labs or Hoarcekat storybook and the command bar, the client half of the bundle skips the transport and the handshake and initializes **instantly** to template defaults. `Observe` and `Changed` work normally, so a Scribe-backed component renders and live-updates with no server anywhere.

A story requires the same shared module a live client does and gets the client half back:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.EmberfallData).Client
```

Then seed the state your component reads. `Data.Mock` takes your template fields first and Scribe's own monetization and leaderboard state second:

```lua
Data.Mock({
    Coins = 1250,
    Gems = 40,
    Xp = 4200,                                -- Level follows: 5
    Inventory = {
        Emberblade = { Qty = 1, Rarity = "Epic" },
        HealthPotion = { Qty = 7, Rarity = "Common" },
    },
    Settings = { "Music", "Sfx" },            -- a Flags field is its enabled names
}, {
    Perks = { "VIP" },
    GiftCredits = { GemPack100 = 2 },
    Leaderboards = {
        TopLevel = {
            { Rank = 1, UserId = 101, Name = "Ava", Score = 42 },
            { Rank = 2, UserId = 102, Name = "Ben", Score = 37 },
        },
    },
})

Data.MockCommand("BuyPotion", function(count)
    return true
end)
```

`Xp = 4200` is the interesting line. `Level` is a [derived field](./derived), so you never seed it: the edit-mode client runs the same recompute the server does, and `Data.Level.Get()` returns `5`. Seed the inputs and the computed values follow.

The second argument takes four keys, each feeding one client API: `Perks` feeds [`Owns`](/api/Client#Owns) and [`ObserveOwned`](/api/Client#ObserveOwned), `GiftCredits` feeds [`GetGiftCredits`](/api/Client#GetGiftCredits), `Leaderboards` feeds [`GetLeaderboard`](/api/Client#GetLeaderboard), and `PurchaseLogs` feeds [`GetPurchases`](/api/Client#GetPurchases). `PurchaseLogs` takes `Robux` and `InGame` arrays holding whole log entries.

Both [`Mock`](/api/Client#Mock) and [`MockCommand`](/api/Client#MockCommand) error outside edit mode, so neither can leak into a real session.

??? note "Mock seeds go through the same validation as a live write"
    `Data.Mock` writes each root field with a normal accessor `Set`, so a seed for Emberfall's `Inventory` is checked against the element shape. An undeclared field is rejected, dictionary keys must be strings, array entries must run contiguously from 1, and the `MaxKeys = 200` cap still applies. A `Rarity` that is not one of the four declared members is refused exactly as it would be in a real session.

    Pass real datatypes rather than packed buffers. A `CFrame` seed is a `CFrame`, and Scribe packs it for you.

??? note "Why edit mode reports itself as the server"
    In edit mode `RunService:IsServer()` is **true**, so Scribe treats `IsRunning` as the deciding signal instead. With nothing running there is no server to build: no `ScribeTransport` folder appears in `ReplicatedStorage`, and touching the bundle's `.Server` half errors with an edit-mode message rather than starting a session. That is what lets one shared module serve both a live game and a storybook.

## Scribe Studio

For interactive testing, the [Scribe Studio](./studio-plugin) renders the whole diagnostics layer as a live dock. Inspect sessions, replay the change feed, simulate outages, invoke commands, and edit production profiles. It is the fastest way to exercise everything without writing throwaway scripts.

## Headless tests

Scribe's own suite runs in Studio under TestEZ and headless under [Lune](https://lune-org.github.io/docs), against a deterministic fake ProfileStore and a stub transport. The same entry point the harness uses lets you construct an isolated instance and drive the player lifecycle yourself, which is how you unit-test your own game logic without a live DataStore.

`Server.build` is internal. It is not on the bundle `Scribe({})` returns, and neither is the template compiler. Both live inside the package folder, which Wally's `Packages.Scribe` link module does not expose as children, so you reach them through `_Index`. It returns **two** values, the `Data` API and the context.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)
local ScribeRoot = ReplicatedStorage.Packages._Index["ericplane_scribe@{{version}}"].scribe
local Template = require(ScribeRoot.Internal.Template)
local Server = require(ScribeRoot.Server)

local options = {
    Template = { Coins = Scribe.Int(0, { Min = 0 }) },
    ProfileStoreIndex = "EmberfallTest",
    ProfileKeyPrefix = "PLAYER_",
    Mode = "Mock",
    TransportChannel = "Test", -- the default channel can only be bound once
    OwnReceipts = false,       -- do not touch MarketplaceService.ProcessReceipt
    KickOnSessionEnd = false,
    LogLevel = "Fatal",        -- build prints no load banner, so quiet the log
}

local compiled = Template.Compile(options.Template)
local Data, ctx = Server.build(options, compiled)

-- Nothing is wired to the engine, so drive the lifecycle by hand:
ctx.Persistence.OnPlayerAdded(player)
local data, reason = ctx.Persistence.WaitForData(player)
assert(data, reason)
data.Coins.Increment(50)
ctx.Persistence.OnPlayerRemoving(player)
```

The difference from `Server.new` is exactly that wiring. `build` connects no `PlayerAdded` or `PlayerRemoving` and binds no shutdown handler, so nothing happens until you call those yourself. Accessors are torn down with the entry, so read what you need before `OnPlayerRemoving`.

??? note "The knobs build gives you"
    `Template.Compile` takes an optional second argument that only matters if you test replicated purchase logs: `{ ReplicateRobuxLog = true, ReplicateInGameLog = true }`, which `Scribe({})` derives from the `PurchaseLog` option.

    Pass `ProfileStore = <your fake>` to swap the store entirely, and a custom `Transport` table instead of `TransportChannel` to capture frames as they are sent.

    Being internal, this entry point carries no compatibility promise the public API does.

??? tip "Looking for how Scribe itself is tested?"
    This page is about testing **your** game. Scribe's own correctness work, a deterministic simulation of a multi-server fleet with modelled latency, request budgets, injected faults and real contention, lives in the repository rather than in these guides. Run it with `lune run lune/run-tests`, and read `test/Sim/SCOPE.md` for the maintained list of what it does and does not cover.

## Where to next

- [Scribe Studio](./studio-plugin) is the interactive half of this page.
- [Configuration](./configuration#persistence-mode) has the full option table, including every legacy flag.
- [Diagnostics](./diagnostics) covers the logs, health status, and metrics you will read while testing.
- [Getting Started](./intro) if you have not built the Emberfall template yet.
