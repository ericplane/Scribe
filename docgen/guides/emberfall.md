# Emberfall Example

**Emberfall** is the small adventure RPG used in Scribe's feature guides. This page keeps its full template in one place. You do not need all these features to start using Scribe; [Getting Started](./intro) uses only coins and a setting.

## What the example includes

| Data | What it demonstrates | Guide |
| --- | --- | --- |
| Coins, gems, XP, and statistics | Whole numbers with a minimum | [Templates](./templates) |
| Level | A value computed from XP | [Derived fields](./derived) |
| Inventory | Items with a quantity and rarity | [Containers](./containers) |
| Settings | Several named on/off switches | [Flags](./containers) |
| LastDaily | A value that expires | [Timers and cooldowns](./time) |

## Shared module

Install Scribe as described in [Getting Started](./intro#1-install-scribe), then create **ReplicatedStorage.Shared.EmberfallData** as a ModuleScript. The feature guides require this path.

Use this module instead of the tutorial's `GameData` module. Running both examples at once would create two Scribe instances on the same default transport channel.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)

local RARITIES = { "Common", "Rare", "Epic", "Legendary" }

-- A derived calculation must give the same result on server and client.
local function levelForXp(xp: number): number
    return math.min(100, math.floor(xp / 1000) + 1)
end

local template = {
    Coins = Scribe.Int(0, { Min = 0 }),
    Gems = Scribe.Int(0, { Min = 0 }),

    Xp = Scribe.Int(0, { Min = 0 }),
    Level = Scribe.Derived(Scribe.Int(1, { Min = 1, Max = 100 }), { "Xp" }, levelForXp),

    Inventory = Scribe.DictOf({
        Qty = Scribe.Int(1, { Min = 1, Max = 999 }),
        Rarity = Scribe.Enum("Common", RARITIES),
    }, { MaxKeys = 200 }),

    Settings = Scribe.Flags({ "Music", "Sfx", "TutorialDone" }),
    LastDaily = Scribe.Timed(false),

    Stats = {
        Deaths = Scribe.Int(0, { Min = 0 }),
        Playtime = Scribe.Int(0, { Min = 0 }),
    },
}

return Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",
    Mode = "Mock",
})
```

`Mode = "Mock"` keeps this example in memory. Read [Testing](./testing#test-saving-across-sessions) before switching to real saved data.

## Try a few changes

In the server script from Getting Started, change the require to `ReplicatedStorage.Shared.EmberfallData`. Replace the code after the successful `WaitForData` check with:

```lua
data.Coins.Increment(50)
data.Xp.Increment(1200)
print(data.Level.Get()) -- 2: computed from XP

data.Settings.Enable("Music")
data.Inventory.Emberblade.Qty.Set(1)
print(data.Inventory.Emberblade.Rarity.Get()) -- Common: the item default
```

Writing `Inventory.Emberblade.Qty` creates that item and fills in its other defaults. Writing `Xp` recalculates `Level`; you cannot write `Level` directly.

Change the client script's require to the same `EmberfallData` module. Its existing `Data.Coins.Observe(...)` example still works. Add this to watch the derived level:

```lua
Data.Level.Observe(function(level)
    print("Level:", level)
end)
```

Feature guides build on this template. Shops, passes, leaderboards, and other optional systems introduce their configuration in their own guides; they are not enabled by this example alone.
