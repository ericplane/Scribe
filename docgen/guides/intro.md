---
sidebar_position: 1
---

# Getting Started

Scribe is persistent, fully-typed, automatically-replicated player data for Roblox, built on [ProfileStore](https://github.com/lm-loleris/ProfileStore). You declare your data shape once, and Scribe handles saving, session locking, and streaming it to clients. The whole accessor tree is typed end to end.

## Install

With [Wally](https://wally.run):

```toml
[dependencies]
Scribe = "ericplane/scribe@{{version}}"
```

ProfileStore is a dependency of Scribe, so `wally install` pulls it into `ServerPackages/` automatically. You don't declare it yourself.

:::tip New Luau type solver
The typed accessor tree (calls like `data.Coins.Increment(50)`, `data.Settings.Music.Set(false)`, or `data.Inventory.Sword.Get()`) needs the **new Luau type solver**. In Studio, select **Workspace** in the Explorer and set its `UseNewLuauTypeSolver` property (under _Scripting_) to `Enabled`. In an external editor, enable the new solver in your Luau LSP settings. Scribe runs correctly without it; `Data.Raw` is the untyped escape hatch.
:::

## One shared module

Declare the template and options in a single ModuleScript that both the server and client require. It returns `{ Server, Client }`.

```lua
-- ReplicatedStorage/Shared/Data.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)

type ItemData = { Health: number, Dmg: number }

local template = {
    Coins = Scribe.Int(0, { Min = 0 }),
    Gems = 0,
    Equipped = nil :: string?,
    Inventory = {} :: { [string]: ItemData },
    Settings = { Music = true, Sfx = true },
}

return Scribe({
    Template = template,
    Transport = "Default",
    ProfileStoreIndex = "PlayerData", -- required: your DataStore name
    ProfileKeyPrefix = "PLAYER_",      -- required: per-player key prefix
})
```

`ProfileStoreIndex` and `ProfileKeyPrefix` are **required**. Naming your store is deliberate so two datastores can never share the same storage by accident.

## Server

Profiles load asynchronously, so wait for the data before touching it:

```lua
local Players = game:GetService("Players")
local Data = require(ReplicatedStorage.Shared.Data).Server

Players.PlayerAdded:Connect(function(player)
    local data = Data.WaitForData(player)
    if not data then return end -- load failed / timed out; player is being kicked

    data.Coins.Increment(50)
    data.Settings.Music.Set(false)
    print(data.Inventory.Sword_001.Dmg.Get())
end)
```

`Data[player]` / `Data.Get(player)` error while a profile is still loading. Use them only after [`WaitForData`](/api/Server#WaitForData).

## Client

Read the local player's data with the same accessor API. `Observe` fires immediately and on every change:

```lua
local Data = require(ReplicatedStorage.Shared.Data).Client

Data.Coins.Observe(function(coins)
    coinsLabel.Text = tostring(coins)
end)
```

Unlike the server, the client never makes you wait. Reads return your template defaults until the first sync arrives, and `Observe` (and `Changed`) fire the moment real data lands, so reactive UI updates itself without any gating. For a one-off imperative read at startup, where the default would be wrong, check `Data.IsReady()` or yield on `Data.WaitForData(timeout)` first.

Client writes are **local-only** (optimistic UI). Server ops always win. To change data authoritatively, call a server command:

```lua
-- server
Data.Command("EquipItem", { Args = { "string" } }, function(player, itemId)
    if not Data[player].Inventory[itemId].Get() then return false, "not owned" end
    Data[player].Equipped.Set(itemId)
    return true
end)

-- client
local ok, reason = Data.Request("EquipItem", "Sword_001")
```

## Configuration

The options table is fully typed as `ScribeOptions<T>`, so your editor autocompletes field names and flags a wrong type or a misspelled key. Beyond the three required fields shown above, the ones you reach for first:

- `SaveInterval` (`number?`): seconds between autosaves (default 300).
- `Migrations` (`{ [number]: (data) -> () }?`): evolve your data shape across versions.
- `UseMock` / `DontSave` (`boolean?`): play-test without touching live data.
- `Leaderboards`, `Products`, `Passes`, `Perks`: opt into monetization and boards.

Every option, with its type and default, is in the **[Configuration reference](./configuration)**.

:::note Already handle Robux purchases yourself?
If you register `Products`, Scribe takes over `MarketplaceService.ProcessReceipt` to grant them (it leaves it alone for data-only games). If your game already runs its own receipt handler, set `OwnReceipts = false` and route Scribe's products through `Data.HandleReceipt`. See [Monetization](./monetization) for details.
:::

## Where to next

- **[Configuration](./configuration)**: every `Scribe({})` option, typed, with defaults.
- **[Templates & Declarators](./templates)**: how to shape your data template and pick field types.
- **[Replication & Visibility](./visibility)**: who sees what (`ServerOnly`, `Shared`, `Session`).
- **[Session Lifecycle](./lifecycle)**: loading, saving, and session end.
- **[Monetization & Gifting](./monetization)**, **[Leaderboards](./leaderboards)**, **[Diagnostics](./diagnostics)**, **[Testing](./testing)**.
- The **[API reference](/api/Scribe)** for every method.
