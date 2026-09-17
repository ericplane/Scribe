# Getting Started

Scribe keeps player data, such as coins and settings, and sends each player a copy for their UI. You describe the data once, then read and change it through Scribe.

This tutorial assumes you can create scripts in Roblox Studio. By the end, the server will give a player 50 coins and the client will print the updated balance. We will use **Mock mode**, so this first example never touches saved player data.

<span id="install"></span>

## 1. Install Scribe

**In Studio:** download `Scribe.rbxm` from the [release you want to use](https://github.com/ericplane/Scribe/releases). Insert the file into your place. Inside the imported `Scribe` folder, move `Packages` into `ReplicatedStorage`, then delete the outer folder. If you already have a `Packages` folder there, move only the imported `Packages.Scribe` into it.

**With Wally:** add this dependency to your project's `wally.toml`, run `wally install`, and use your Rojo project to place `Packages` in `ReplicatedStorage`:

```toml
[dependencies]
Scribe = "ericplane/scribe@{{version}}"
```

Scribe includes the ProfileStore version it needs. There is no second dependency to install.

## 2. Create the shared data module

Create the folders and scripts below in Studio. The names matter because the examples use these paths.

```text
ReplicatedStorage
├── Packages
│   └── Scribe          (installed package)
└── Shared
    └── GameData        (ModuleScript)
ServerScriptService
└── PlayerData          (Script)
StarterPlayer
└── StarterPlayerScripts
    └── PlayerData      (LocalScript)
```

Paste this into the **GameData ModuleScript**:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)

return Scribe({
    Template = {
        Coins = 0,
        Settings = {
            Music = true,
        },
    },
    ProfileStoreIndex = "ScribeTutorial",
    ProfileKeyPrefix = "PLAYER_",
    Mode = "Mock",
})
```

The **template** describes a new player's data: zero coins and music enabled. `ProfileStoreIndex` names the store; `ProfileKeyPrefix` is the prefix for player keys inside it. Keep these names stable once you start saving real data.

This module returns two APIs: `.Server` for server scripts and `.Client` for LocalScripts. Require this same module from both sides.

<span id="writing-data-on-the-server"></span>
<span id="getting-data-on-the-server"></span>

## 3. Give the player coins on the server

Paste this into **ServerScriptService.PlayerData**:

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.GameData).Server

local function onPlayerAdded(player: Player)
    local data, reason = Data.WaitForData(player)
    if not data then
        warn("Could not load player data:", reason)
        return
    end

    data.Coins.Increment(50)
    print("Server coins:", data.Coins.Get())
    print("Music enabled:", data.Settings.Music.Get())
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
    task.spawn(onPlayerAdded, player)
end
```

`WaitForData` waits for the player's profile. Always handle its `nil` result: a player can leave before loading finishes. Once it succeeds, `Get()` reads a field and `Increment(50)` adds 50 to it.

The last loop also handles players who arrived before this script started. Scribe handles profile loading and saving itself; your script waits for the result.

<span id="reading-data-on-the-client"></span>

## 4. Read changes on the client

Paste this into **StarterPlayerScripts.PlayerData**:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.GameData).Client

Data.Coins.Observe(function(coins)
    print("Client coins:", coins)
end)
```

`Observe` calls your function immediately, then again when the value changes. Before the server's first update arrives, that value can be the template default, `0`.

!!! important "Keep the LocalScript"
    The client must require `GameData` to start receiving updates. Requiring it only on the server is not enough.

## 5. Play and check the result

Press **Play** and open Studio's **Output** window. On a new play-test you should see:

```text
Server coins: 50
Music enabled: true
Client coins: 50
```

The client may print `Client coins: 0` first, and the message order can vary. Seeing `50` on both sides means your server write reached the client.

Stop and play again. The balance starts fresh because this tutorial uses an in-memory mock store. To test saving across sessions, follow [Testing: save and reload](./testing#test-saving-across-sessions).

<span id="where-to-next"></span>

## What to try next

You now have the basic setup. Choose the next task you need:

- [Add rules to your template](./templates), such as keeping coins above zero.
- [Read, write, and observe values](./values), including updating UI and cleaning up listeners.
- [Send a request from the client](./commands). Client writes are local only; lasting changes must happen on the server.
- [Test saving and preview UI](./testing).
- [Explore the Emberfall example](./emberfall), the larger RPG template used in feature guides.

<span id="the-emberfall-template"></span>

Looking for the full template previously shown here? It now lives on the [Emberfall example page](./emberfall), with its inventory, level, settings, and timer examples together.

<span id="changing-data-from-the-client"></span>

To change saved data from a client button, follow [Commands and Requests](./commands). The server checks and applies the requested change.

<span id="configuration"></span>

For options beyond this tutorial, use the [Configuration reference](./configuration). You can leave optional systems at their defaults until you need them.

??? tip "Autocomplete and types"
    Scribe's typed API uses Luau's new type solver. If your Studio version exposes `Workspace.UseNewLuauTypeSolver`, set it to `Enabled`; in an external editor, enable the new solver in your Luau LSP settings. Scribe can run without these generated types, but field-specific autocomplete needs them. See [template types](./templates#naming-the-accessor-type) when you need type annotations in your own modules.

??? note "A one-time client read after loading"
    `Observe` is convenient for UI because it updates when real data arrives. If startup code needs the loaded value just once, first check `Data.WaitForData()` and handle `false`. It waits up to 30 seconds by default. The [client API](/api/Client#WaitForData) and [Session Lifecycle](./lifecycle) explain the loading states.

??? note "If your game already uses ProfileStore"
    Keep your existing package. Scribe uses its own patched copy, which reports save results; it does not adopt a ProfileStore module from elsewhere in your game.
