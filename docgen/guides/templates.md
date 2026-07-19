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
| [`Scribe.Dynamic(factory)`](/api/Scribe#Dynamic) | A default computed per profile (creation timestamps, seeds) |

Don't conflate the three things a declarator carries: the **default value**, the **Luau type** (what your code sees), and the **runtime metadata** (validation/packing). A plain `0` gives you a number field with no bounds; `Scribe.Int(0, { Min = 0 })` gives you a non-negative integer field that clamps.

## Dynamic (per-profile) defaults

A template default is evaluated **once**, when the module loads. So `os.time()`, `os.date()`, or `DateTime.now()` written directly capture the *server's start time* and hand that same frozen value to every new profile:

```lua
-- WRONG: every player's CreatedUnix is the server-start time, not their own.
CreatedUnix = os.time(),
```

`Scribe.Dynamic` fixes this: pass the **function**, and Scribe runs it per new profile. (It also runs the factory ONCE at module load, to sample the return type for typing and packing -- so the factory must be pure: no yields, no errors, no side effects. A `Scribe.Dynamic` field cannot be combined with `Scribe.Session`; use [`OnPlayerInit`](./lifecycle) for per-session values.)

```lua
CreatedUnix = Scribe.Dynamic(os.time),                             -- number; pass the function itself
JoinedAt    = Scribe.Dynamic(function() return DateTime.now() end), -- DateTime, packed for you
```

The field types as the factory's return type, so `CreatedUnix` is a `number` and `JoinedAt` a `DateTime`, with full autocomplete. Datatype results are packed correctly. It's just as handy for per-profile seeds or ids.

**When the factory runs.** Scribe evaluates it the first time a profile actually *has* the field:

- a **brand-new profile** (all of its `Dynamic` fields), and
- an **existing profile that gains the field** after you add it to the template (just that one field, on its next load).

It never runs when a value is already stored. The check is on the profile's actual saved value, decided before any defaults are backfilled, so a returning player's value is **always preserved and never overwritten**. Player-specific defaults (based on `player.Name`, a `UserId` lookup, and so on) don't fit a no-argument factory, so use [`OnPlayerInit`](./lifecycle) for those.

:::note Late-added timestamps
Add a creation-timestamp `Dynamic` field long after launch and existing players get it computed on their *next* load, not their true (unrecorded) creation date. That's a value choice, not data loss: everything they already had is untouched.
:::

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

Writes are validated against the declarator: out-of-range numbers clamp (or reject, under `BoundsPolicy = "Reject"`), enum values outside the set are refused, and a string past a field's `MaxLength` is truncated on a character boundary (so a multi-byte character is never split), or rejected under `BoundsPolicy = "Reject"`. Separately, values that simply cannot be stored are always rejected outright: unsupported types (functions, threads, Instances and other userdata), non-finite numbers (NaN or infinity), and strings or table keys that are not valid UTF-8. Note `MaxLength` counts **bytes**, not characters, so budget for multi-byte text. Data written through raw paths that bypass the accessor, such as migrations or `OnPlayerInit`, is scanned for the same problems at load and reported as `PROFILE_UNPERSISTABLE`.

## Timed fields

A `Scribe.Timed` field auto-clears back to its default when its timer lapses, firing `Changed`. A client `Observe` already covers "the booster ended":

```lua
XPBooster = Scribe.Timed(false),

-- server
data.XPBooster.SetTimed(true, 3600)  -- true for one hour
data.XPBooster.ExtendTimed(1800)     -- add 30 minutes
local active, remaining = data.XPBooster.Active()
```

Two behaviors to know:

- **Durations floor to 1 second**, and expiries are checked by a once-per-second sweep -- sub-second timers are not possible.
- **A plain `Set` does not cancel a running timer.** If you `Set` a "permanent" value while an earlier `SetTimed` is still armed, the old timer still lapses and resets the field to its template default, discarding your value. To convert a timed value to a permanent one, use `SetTimed(value, math.huge)` -- or wait for `Active()` to report false before the plain `Set`.

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
