# Getting Started

Every game needs somewhere to keep a player's coins, level, and inventory between visits. Scribe is that place. You write down the shape of your data once, in a plain Luau table, and Scribe handles saving it, locking it so two servers cannot fight over it, and streaming a copy to the client.

Everything in these guides is built around one example game called **Emberfall**, a small adventure RPG. You will meet its data template on this page and see slices of it everywhere else.

## Install

With [Wally](https://wally.run):

```toml
[dependencies]
Scribe = "ericplane/scribe@{{version}}"
```

That is the only line you add. Scribe vendors its own patched copy of [ProfileStore](https://github.com/lm-loleris/ProfileStore) inside the package, so there is no second dependency to declare and nothing appears in `ServerPackages/`.

??? note "If your game already uses ProfileStore"
    Keep it. Scribe never binds to a copy it finds in `ServerPackages` or `Packages`, so yours is left completely alone and the two run side by side. The reason Scribe brings its own is that an unpatched build cannot report whether a save succeeded, and Scribe will not adopt a store that cannot tell it that.

## The Emberfall template

Declare your template and your options in a single ModuleScript that both realms require. It returns the **bundle**, a table of `{ Server, Client }`. This is the whole Emberfall data model, and every other guide shows a slice of it.

```lua
-- ReplicatedStorage/Shared/EmberfallData.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)

local RARITIES = { "Common", "Rare", "Epic", "Legendary" }

-- Pure: no yields, no randomness, no os.time. Scribe runs it on both realms.
local function levelForXp(xp: number): number
    return math.min(100, math.floor(xp / 1000) + 1)
end

local template = {
    -- Currencies.
    Coins = Scribe.Int(0, { Min = 0 }),
    Gems  = Scribe.Int(0, { Min = 0 }),

    -- Progression. Level is computed from Xp and refuses every write.
    Xp    = Scribe.Int(0, { Min = 0 }),
    Level = Scribe.Derived(Scribe.Int(1, { Min = 1, Max = 100 }), { "Xp" }, levelForXp),

    -- Items, keyed by item id.
    Inventory = Scribe.DictOf({
        Qty    = Scribe.Int(1, { Min = 1, Max = 999 }),
        Rarity = Scribe.Enum("Common", RARITIES),
    }, { MaxKeys = 200 }),

    -- Three named booleans in one field, one write and one Changed for all of them.
    Settings = Scribe.Flags({ "Music", "Sfx", "TutorialDone" }),

    -- True while the daily reward is spent. Clears itself back to false after a day.
    LastDaily = Scribe.Timed(false),

    Stats = {
        Deaths   = Scribe.Int(0, { Min = 0 }),
        Playtime = Scribe.Int(0, { Min = 0 }),
    },
}

return Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",
})
```

`ProfileStoreIndex` and `ProfileKeyPrefix` are the only required options besides the template. Naming your own store is deliberate, so two games can never share storage by accident.

Read that template top to bottom and you have already met most of Scribe's vocabulary. `Scribe.Int` and `Scribe.Enum` are **declarators**: they give a field a default, a Luau type, and runtime rules such as a minimum. `Stats` is a plain nested table, which is fine when the fields inside it need nothing special. [Templates](./templates) covers all of them.

!!! warning "Turn on Studio access to API services first"
    Studio cannot reach DataStores until you publish the place and enable **File, Experience Settings, Security, "Enable Studio Access to API Services"**. This is the most common first-run surprise, and it does not look like an error. ProfileStore quietly falls back to an in-memory store, so a play-test appears to work while every session starts from template defaults and nothing survives a restart. The tell is one line in the Output: `[ProfileStore]: Roblox API services unavailable - data will not be saved`. When you *want* that isolation, ask for it with `Mode = "Mock"` (see [Testing](./testing)) rather than leaving it to a Studio setting.

## Writing data on the server

Profiles load asynchronously, so wait for the data before you touch it. `WaitForData` returns the player's **accessor tree**, and you index into it exactly the way you wrote the template.

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.EmberfallData).Server

Players.PlayerAdded:Connect(function(player)
    local data = Data.WaitForData(player)
    if not data then
        return -- the load failed or the player left; Scribe is already handling it
    end

    data.Coins.Increment(50)
    data.Xp.Increment(1200)
    print(data.Level.Get()) --> 2, recomputed from Xp for you

    data.Settings.Enable("Music")
    data.Inventory.Emberblade.Qty.Set(1) -- creates the entry
    print(data.Inventory.Emberblade.Rarity.Get()) --> "Common", from the element default
end)
```

Three things happened there. `Increment` wrote through the declarator, so the `Min = 0` on `Coins` is enforced and the change replicates to the player. `Level` was never written, because it is derived: bumping `Xp` is what moves it. Writing `Inventory.Emberblade.Qty` created that dictionary entry and filled `Rarity` in from its declared default.

Always handle the `nil` branch of `WaitForData`. [`Data.Get(player)`](/api/Server#Get), and its `Data[player]` shorthand, read the tree without yielding, and both error while a profile is still loading. Use them only after the wait has succeeded.

??? note "The seven reasons a wait can fail"
    `WaitForData` returns `(nil, reason)` on failure, and the reason is one of seven strings, also available as the `Scribe.Reason` table. The two you will actually branch on are `player-left`, which is by far the most common and needs no handling, and `still-loading`, which means the load is still in flight and calling again is worth doing. [Session Lifecycle](./lifecycle) has the full table.

## Reading data on the client

The client reads the same accessor tree with the same API. `Observe` fires once immediately with the current value and again on every change, which is all a piece of UI usually needs.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.EmberfallData).Client

Data.Coins.Observe(function(coins)
    coinsLabel.Text = tostring(coins)
end)

Data.Level.Observe(function(level)
    levelLabel.Text = `Level {level}`
end)
```

`Level` is derived from `Xp`, and `Xp` is visible to its owner, so the client computes `Level` itself rather than receiving it over the wire. You do not have to know that to use it, which is the point.

!!! warning "The client must require the module too"
    Replication only starts when the bundle is required from a **client-side script**. That `require` runs the client's half of the handshake. Set Scribe up on the server and never require it on the client, and the client never syncs: `Observe` and `Changed` never fire with real data, reads stay at your template defaults, and the server logs a `CLIENT_HANDSHAKE_TIMEOUT` warning saying the client never sent Hello. Requiring the same shared module on both realms is the whole setup.

The accessor tree never makes you wait. Reads return your template defaults until the first sync lands, and `Observe` fires again the moment real data arrives, so reactive UI needs no gating at all. For a one-off imperative read at startup, where a default would be the wrong answer, check `Data.IsReady()` or yield on `Data.WaitForData(timeout)` first.

??? warning "Seven client methods do yield until data arrives"
    That no-waiting property belongs to the accessor tree, not to the whole client object. These seven block until the first snapshot lands:

    [`Request`](/api/Client#Request), [`Owns`](/api/Client#Owns), [`OwnsAsync`](/api/Client#OwnsAsync), [`ObserveOwned`](/api/Client#ObserveOwned), [`GetSaveInfo`](/api/Client#GetSaveInfo), [`GetGiftCredits`](/api/Client#GetGiftCredits), and [`GetPurchases`](/api/Client#GetPurchases).

    None of them takes a load timeout, so that wait is unbounded: called before the first sync, they block for as long as loading takes. The two timeouts that do exist cover something later. `RequestTimeout` bounds the server's reply to `Request`, and the `timeout` argument on `OwnsAsync` bounds the ownership refresh that follows loading.

    So gate any UI script that calls one of them on `Data.IsReady()`, or on [`Data.WaitForData(timeout)`](/api/Client#WaitForData), which is bounded at 30 seconds by default and returns `false` rather than hanging. In edit mode, such as a storybook or the command bar, none of the seven yields at all.

## Changing data from the client

Client writes are local only. They are there for optimistic UI, and a server write always overwrites them. To change data authoritatively you register a **command** on the server and call it from the client.

```lua
-- server
Data.Command("BuyPotion", { Args = { "number" } }, function(player, count)
    if count < 1 or count > 10 or count % 1 ~= 0 then
        return false, "bad amount"
    end

    local data = Data[player]
    local price = 25 * count

    if data.Coins.Get() < price then
        return false, "not enough coins"
    end

    data.Coins.Decrement(price)
    data.Inventory.HealthPotion.Qty.Set(count)
    return true
end)
```

```lua
-- client
local ok, reason = Data.Request("BuyPotion", 3)
if not ok then
    showToast(reason)
end
```

One catch is worth knowing before you build on this. `Data.Request` returns its own failure values such as `"timeout"` and `"rate-limited"`, so the `false, "not enough coins"` above looks the same as a request that never reached the server. [Commands and Requests](./commands) covers the return shape that tells them apart.

## Configuration

The options table is typed as `ScribeOptions<T>`, so your editor autocompletes field names and flags a misspelled key. Beyond the two required ones, these are the options you reach for first:

| Option | What it does |
| --- | --- |
| `SaveInterval` | Seconds between autosaves. Default 300. |
| `Mode` | `"Live"`, `"Mock"`, or `"NoSave"`. Play-test without touching live data. |
| `Migrations` | Evolve your data shape across versions. |
| `Products`, `Passes`, `Perks` | Robux purchases and ownership. |
| `Leaderboards` | Declared boards, refreshed and replicated for you. |

Every option, with its type and default, is in the [Configuration reference](./configuration).

??? tip "Already handle Robux purchases yourself?"
    If you register `Products`, Scribe takes over `MarketplaceService.ProcessReceipt` to grant them. It leaves that callback alone for a game with no products declared. If your game already runs its own receipt handler, set `OwnReceipts = false` and route Scribe's products through [`Data.HandleReceipt`](/api/Server#HandleReceipt). See [Monetization](./monetization).

??? tip "Turning on the new Luau type solver"
    The typed accessor tree, calls like `data.Coins.Increment(50)` and `data.Inventory.Emberblade.Rarity.Get()`, needs the **new Luau type solver** to autocomplete and type-check. In Studio, select **Workspace** in the Explorer and set its `UseNewLuauTypeSolver` property, under Scripting, to `Enabled`. In an external editor, enable the new solver in your Luau LSP settings. Scribe runs correctly without it; you just lose the typing, and `Data.Raw` is the untyped escape hatch.

## Where to next

- [Templates](./templates) declares fields: every declarator, bounds, and the naming rules. Read this next, because it sets the vocabulary the other guides use.
- [Reading and Writing Values](./values) is the other half: what you can call on `data.Coins` once the field exists.
- [Derived Fields](./derived) explains `Level` properly, including what a compute function may and may not do.
- [Replication and Visibility](./visibility) decides who sees which field.
- [Testing](./testing) shows how to play-test Emberfall without touching live data.
