---
sidebar_position: 2
---

# Templates & Declarators

Your **template** is a plain table describing the shape and default values of a player's data. Scribe compiles it once into a schema that drives typing, validation, wire compression, and persistence.

```lua
local template = {
    Coins = Scribe.Int(0, { Min = 0 }),
    Wins = 0,                              -- a plain number field
    Equipped = nil :: string?,             -- optional field
    Inventory = {} :: { [string]: ItemData }, -- dynamic dictionary
    QuestProgress = {} :: { number },      -- array
    Settings = { Music = true, Sfx = true }, -- nested container
}
```

:::note Empty tables need a type
An empty array or dictionary in the template **must** carry a type ascription (`{} :: { string }`) so the type function knows the element type.
:::

## Plain values vs declarators

A plain value (`Wins = 0`, `Settings = { ... }`) is the simplest way to declare a field: its Luau type and default are inferred directly. **Declarators** (`Scribe.Int`, `Scribe.Enum`, …) add runtime metadata: bounds, validation, or compact wire packing.

| Declarator | Use it for |
| --- | --- |
| [`Scribe.Int(default, { Min, Max })`](/api/Scribe#Int) | Integers; bounded ints pack smaller |
| [`Scribe.Number(default, { Min, Max })`](/api/Scribe#Number) | Floating-point values |
| [`Scribe.String(default, { MaxLength })`](/api/Scribe#String) | Strings, optionally length-capped |
| [`Scribe.Enum(default, members)`](/api/Scribe#Enum) | A fixed set of string values (packs to one byte) |
| [`Scribe.Timed(default)`](/api/Scribe#Timed) | Fields that expire (boosters, buffs) |

Don't conflate the three things a declarator carries: the **default value**, the **Luau type** (what your code sees), and the **runtime metadata** (validation/packing). A plain `0` gives you a number field with no bounds; `Scribe.Int(0, { Min = 0 })` gives you a non-negative integer field that clamps.

## Reading and writing

Every field is a [`Value`](/api/Value). Index into the template shape and call methods on the leaf:

```lua
data.Coins.Get()               --> 0
data.Coins.Set(100)
data.Coins.Increment(50)       -- number fields
data.Settings.Music.Toggle()   -- boolean fields
data.QuestProgress.Insert(3)   -- array fields
data.Inventory.Sword.Set({ Health = 100, Dmg = 5 })
data.Coins.Observe(function(v) print("coins:", v) end)
```

Writes are validated against the declarator: out-of-range numbers clamp (or reject, under `BoundsPolicy = "Reject"`), enum values outside the set are refused, and unsupported types (functions, threads) throw.

## Timed fields

A `Scribe.Timed` field auto-clears back to its default when its timer lapses, firing `Changed`. A client `Observe` already covers "the booster ended":

```lua
XPBooster = Scribe.Timed(false),

-- server
data.XPBooster.SetTimed(true, 3600)  -- true for one hour
data.XPBooster.ExtendTimed(1800)     -- add 30 minutes
local active, remaining = data.XPBooster.Active()
```

## Cooldowns

Cooldowns are the *other* time-based feature, and the one most easily confused with `Timed`: there is **no `Cooldown` declarator and no template field**. A cooldown is a server-side timer keyed by any string you choose, driven entirely through the API. Reach for it for daily rewards, claim gates, or ability recharges.

```lua
-- OnCooldown checks AND arms in one call, so call it only at the claim moment:
if not Data.OnCooldown(player, "DailyReward", 86400) then
    grantDailyReward(player) -- it was off; a fresh 24h cooldown is now running
end

-- PeekCooldown is read-only and never arms, so it is safe for UI:
local onCooldown, remaining = Data.PeekCooldown(player, "DailyReward")

Data.ClearCooldown(player, "DailyReward") -- support / testing reset
```

Cooldowns are stored server-side in the profile, so they survive rejoins and cross-server hops and never replicate to the client. The rule of thumb: `Timed` is for a **field that expires** (a booster you read and display), while a cooldown answers **"can this happen again yet"** and holds no value of its own.

## Roblox datatype fields

For positions, colours, CFrames, and the like, use the datatype declarators. The value is stored and replicated as a **compact packed buffer**; your code only ever sees the real datatype.

```lua
SpawnPoint = Scribe.Vector3(Vector3.zero),
HomeDoor   = Scribe.CFrame(CFrame.identity),  -- axis-aligned rotations pack to 13 bytes
Tint       = Scribe.Color3(Color3.fromRGB(255, 120, 0)),
```

All 17 are supported: `Vector3`, `Vector2`, `Vector3int16`, `Vector2int16`, `CFrame`, `Color3`, `BrickColor`, `UDim`, `UDim2`, `Rect`, `NumberRange`, `NumberSequence`, `ColorSequence`, `DateTime`, `EnumItem`, `Font`, `PhysicalProperties`.

`buffer` values are also first-class template fields, ideal for games that save large placed-structure or inventory blobs.
