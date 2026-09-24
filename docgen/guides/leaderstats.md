# Player-list stats

Show coins, levels, or a title beside each player's name with the optional
**Scribe Leaderstats** addon. You select the fields; it handles profile loading,
updates, and cleanup.

This displays live values in Roblox's built-in player list. Use
[Leaderboards](leaderboards.md) when you also need persistent rankings.

## Add it to your game

Copy `addons/leaderstats/ScribeLeaderstats.luau` into `ServerScriptService`.
The core Scribe package does not load or include it automatically.

For roblox-ts, use the separate `@rbxts/scribe-leaderstats` package described below.
See [roblox-ts](roblox-ts.md) for package publication status and the shared data setup.

## Choose the columns

Suppose your existing `GameData` template includes:

```lua
Template = {
    Coins = 0,
    Progress = { Level = 1 },
    Title = "Newcomer",
}
```

Create a server Script:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.GameData).Server
local Leaderstats = require(ServerScriptService.ScribeLeaderstats)

local display = Leaderstats.Start(Data, {
    Coins = "Coins",
    Level = "Progress.Level",
    Title = "Title",
})
```

`Level` is the visible column name, and `"Progress.Level"` is its path in the
template. The addon creates the player's `leaderstats` folder after their profile
loads. Players already in the server are included.

Keep changing values through Scribe:

```lua
local data = Data.WaitForData(player)
if data then
    data.Coins.Increment(25)
end
```

The displayed number updates automatically. Editing `player.leaderstats` does
not change or save Scribe data.

## roblox-ts

After npm publication, install the addon alongside the core:

```sh
npm install @rbxts/scribe @rbxts/scribe-leaderstats
```

With the shared `Data` bundle from the [roblox-ts guide](roblox-ts.md), start it in
a server script:

```ts
import ScribeLeaderstats from "@rbxts/scribe-leaderstats";
import { Data } from "shared/data";

const display = ScribeLeaderstats.Start(Data.Server, {
    Coins: "Coins",
});

// Later, before stopping the Scribe bundle:
display.Stop();
```

Path types follow the actual server schema, including nested fields. Misspellings,
containers, optional values or ancestors, Roblox datatype properties, and Big values
are rejected. A field name containing a dot cannot be addressed by this path syntax.
An always-present derived string is suitable for formatting large numbers.

The same visibility rules below apply: selecting a `ServerOnly` or `Session` scalar
explicitly makes it public through the player list. Types cannot decide whether a
particular value is appropriate to publish.

## What can be displayed?

| Scribe value | Created instance |
| --- | --- |
| Finite number, including a decimal | `NumberValue` |
| String | `StringValue` |
| Boolean | `BoolValue` |

Choose fields that always exist and keep the same type. Nested fields and derived
scalar values work. Dot-separated paths address string keys; array indices and
field names containing dots are not supported. For large-number formatting,
define a derived string field and display that.

**All selected values become public to every client.** A `ServerOnly` or
`Session` wrapper does not hide a value you explicitly select here. Only select
information you intend everyone to see.

## Cleanup and conflicts

The addon listens for changes; it does not poll loaded profiles or make additional
DataStore requests. It removes its generated values when a player leaves or their
Scribe session ends.

If you stop a bundle manually, stop the display first:

```lua
display:Stop()
Data.Stop()
```

Repeating Stop is safe. Pending profile waits
finish within their current 10-second window, without creating any late instances.

The addon preserves existing `leaderstats` folders and unrelated children. If a
configured column already exists, a path is missing, or a value is unsupported,
it warns and skips that player's entire configured display. If a selected value
later disappears or changes type, it removes that player's generated stats and
warns. Correct the configuration/data and restart the addon to try again.

Run one addon handle per server Data API. Column instances are added in
alphabetical order; Roblox controls how many columns fit in its player list.
