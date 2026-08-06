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

local template = {
    Coins = Scribe.Int(0, { Min = 0 }),
    Gems = 0,
    Equipped = Scribe.Optional(Scribe.String("", { MaxLength = 32 })),
    Inventory = Scribe.DictOf({
        Health = Scribe.Int(100, { Min = 0 }),
        Dmg = Scribe.Int(1, { Min = 0 }),
    }, { MaxKeys = 200 }),
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

:::caution Turn on Studio access to API services first
Studio cannot reach DataStores until you publish the place and enable **File → Experience Settings → Security → "Enable Studio Access to API Services"**. This is the most common first-run surprise, and it does not look like an error: ProfileStore quietly falls back to an in-memory store, so a play-test appears to work while every session starts from template defaults and nothing survives a restart. The tell is one line in the Output, `[ProfileStore]: Roblox API services unavailable - data will not be saved`. When you *want* that isolation, ask for it explicitly with `Mode = "Mock"` (see [Testing](./testing)) rather than leaving it to a Studio setting.
:::

## Server

Profiles load asynchronously, so wait for the data before touching it:

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.Data).Server

Players.PlayerAdded:Connect(function(player)
    local data = Data.WaitForData(player)
    if not data then return end -- load failed / timed out; player is being kicked

    data.Coins.Increment(50)
    data.Settings.Music.Set(false)
    data.Inventory.Sword_001.Dmg.Set(7) -- creates the entry, filling Health from its default
    print(data.Inventory.Sword_001.Health.Get()) --> 100
end)
```

`Data[player]` / `Data.Get(player)` error while a profile is still loading. Use them only after [`WaitForData`](/api/Server#WaitForData).

## Client

Read the local player's data with the same accessor API. `Observe` fires immediately and on every change:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.Data).Client

Data.Coins.Observe(function(coins)
    coinsLabel.Text = tostring(coins)
end)
```

:::caution The client must require the module too
Replication only starts when the bundle is required from a **client-side script** (a `LocalScript`). That `require` runs the client's handshake with the server. If you set Scribe up on the server but never require it on the client, the client never syncs: `Observe`/`Changed` never fire with real data (reads stay at your template defaults), `GetShared` is empty, and the server logs a `CLIENT_HANDSHAKE_TIMEOUT` warning (`"client never sent Hello"`). Requiring the same shared module on both realms is the whole setup.
:::

Unlike the server, the client's **accessor tree** never makes you wait. Reads return your template defaults until the first sync arrives, and `Observe` (and `Changed`) fire the moment real data lands, so reactive UI updates itself without any gating. For a one-off imperative read at startup, where the default would be wrong, check `Data.IsReady()` or yield on `Data.WaitForData(timeout)` first.

That is a property of the tree, not of the whole client. Seven client methods **do** yield until the first snapshot arrives:

[`Request`](/api/Client#Request), [`Owns`](/api/Client#Owns), [`OwnsAsync`](/api/Client#OwnsAsync), [`ObserveOwned`](/api/Client#ObserveOwned), [`GetSaveInfo`](/api/Client#GetSaveInfo), [`GetGiftCredits`](/api/Client#GetGiftCredits), and [`GetPurchases`](/api/Client#GetPurchases).

None of them takes a **load** timeout, so that wait is unbounded: called before the first sync, they block for as long as loading takes. The two timeouts in play cover something later, not the load. The `RequestTimeout` option bounds the server's reply to `Request`, and `OwnsAsync`'s `timeout` argument bounds the ownership refresh that follows loading. So gate a UI script that calls any of them on `Data.IsReady()` or `Data.WaitForData(timeout)`, which is bounded (default 30s) and returns `false` rather than hanging. In edit mode (storybooks, the command bar) none of the seven yields at all.

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

One catch worth knowing before you build on this: `Data.Request` returns its own failure sentinels (`"timeout"`, `"rate-limited"`, and others), so the `false, "not owned"` above is indistinguishable from the request never reaching the server. [Commands & Requests](./commands) covers the full contract and the return shape that avoids it.

## Configuration

The options table is fully typed as `ScribeOptions<T>`, so your editor autocompletes field names and flags a wrong type or a misspelled key. Beyond the three required fields shown above, the ones you reach for first:

- `SaveInterval` (`number?`): seconds between autosaves (default 300).
- `Migrations` (`{ [number]: (data) -> () }?`): evolve your data shape across versions.
- `Mode` (`"Live" | "Mock" | "NoSave"`): play-test without touching live data. `"Mock"` runs profiles and leaderboards off in-memory stores; `"NoSave"` reads the real profile, never writes it back, and keeps leaderboards mocked too. One option covers every store Scribe touches, so a test session never needs the older `UseMock` / `DontSave` flags.
- `Leaderboards`, `Products`, `Passes`, `Perks`: opt into monetization and boards.

Every option, with its type and default, is in the **[Configuration reference](./configuration)**.

:::note Already handle Robux purchases yourself?
If you register `Products`, Scribe takes over `MarketplaceService.ProcessReceipt` to grant them (it leaves it alone for data-only games). If your game already runs its own receipt handler, set `OwnReceipts = false` and route Scribe's products through `Data.HandleReceipt`. See [Monetization](./monetization) for details.
:::

## Where to next

- **[Templates & Declarators](./templates)**: how to shape your data template and pick field types. Start here: it defines the vocabulary the rest of the guides use.
- **[Configuration](./configuration)**: every `Scribe({})` option, typed, with defaults. A reference page, best read once you have a template.
- **[Replication & Visibility](./visibility)**: who sees what (`ServerOnly`, `Shared`, `Session`).
- **[Session Lifecycle](./lifecycle)**: loading, saving, and session end.
- **[Monetization & Gifting](./monetization)**, **[Leaderboards](./leaderboards)**, **[Diagnostics](./diagnostics)**, **[Testing](./testing)**.
- The **[API reference](/api/Scribe)** for every method.
