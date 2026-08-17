# Templates & Declarators

Your **template** is a plain table describing the shape and default values of a player's data. Scribe compiles it once into a schema that drives typing, validation, wire compression, and persistence.

```lua
local template = {
    Coins = Scribe.Int(0, { Min = 0 }),
    Wins = 0,                              -- a plain number field
    Equipped = Scribe.Optional(Scribe.String("", { MaxLength = 32 })), -- may be absent
    Settings = { Music = true, Sfx = true }, -- nested container
    QuestProgress = {} :: { number },      -- untyped array
    Inventory = Scribe.DictOf({            -- typed dictionary: entries get a schema
        Amount = Scribe.Int(1, { Min = 1 }),
        Level = Scribe.Int(1, { Min = 1, Max = 100 }),
    }),
}
```

:::note Empty tables need a type
An untyped array or dictionary in the template **must** carry a type ascription (`{} :: { string }`) so the type function knows the element type. [`Scribe.ArrayOf`](#typed-containers) and `Scribe.DictOf` need no ascription, since the element shape already states the type.
:::

## Plain values vs declarators

A plain value (`Wins = 0`, `Settings = { ... }`) is the simplest way to declare a field: its Luau type and default are inferred directly. **Declarators** (`Scribe.Int`, `Scribe.Enum`, …) add runtime metadata: bounds, validation, or compact wire packing.

| Declarator | Use it for |
| --- | --- |
| [`Scribe.Int(default, { Min, Max })`](/api/Scribe#Int) | Integers; bounded ints pack smaller |
| [`Scribe.Number(default, { Min, Max })`](/api/Scribe#Number) | Floating-point values |
| [`Scribe.Big(default, { Min, Max })`](/api/Scribe#Big) | Numbers past `2^53`, for idle and simulator currencies ([big numbers](#big-numbers)) |
| [`Scribe.String(default, { MaxLength })`](/api/Scribe#String) | Strings, optionally length-capped |
| [`Scribe.Enum(default, members)`](/api/Scribe#Enum) | A fixed set of string values (packs to one byte) |
| [`Scribe.Timed(default)`](/api/Scribe#Timed) | Fields that expire (boosters, buffs) |
| [`Scribe.Flags(members)`](/api/Scribe#Flags) | A fixed set of named booleans, up to 32, in one field |
| [`Scribe.Dynamic(factory)`](/api/Scribe#Dynamic) | A default computed per profile (creation timestamps, seeds) |
| [`Scribe.Derived(output, inputs, compute)`](/api/Scribe#Derived) | A read-only field computed from other fields ([derived fields](./derived)) |
| [`Scribe.ArrayOf(shape, { MaxItems, Evict })`](/api/Scribe#ArrayOf) | A list whose entries have a schema ([typed containers](#typed-containers)), optionally a [rolling window](#rolling-windows) |
| [`Scribe.SetOf(element, { MaxItems })`](/api/Scribe#SetOf) | A collection of unique entries: membership, not order |
| [`Scribe.DictOf(shape, { MaxKeys, MaxKeyLength })`](/api/Scribe#DictOf) | A string-keyed map whose values have a schema |
| [`Scribe.MapOf(keyType, value, opts)`](/api/Scribe#MapOf) | A map whose **key** type is declared (`"integer"` or `"string"`) |
| [`Scribe.Optional(inner)`](/api/Scribe#Optional) | A field that may legitimately be absent |

Don't conflate the three things a declarator carries: the **default value**, the **Luau type** (what your code sees), and the **runtime metadata** (validation/packing). A plain `0` gives you a number field with no bounds; `Scribe.Int(0, { Min = 0 })` gives you a non-negative integer field that clamps.

:::note Root field names the client reserves
On the client you read data as `Data.Coins`, so a **root** field sharing a name with a client method is unreachable that way (the method wins). The names to avoid are `Owns`, `Request`, `Mock`, and `Raw`; the rest of the client surface is `Verb...` or `On...` shaped (`GetPurchases`, `WaitForData`, `OnSharedChanged`), which no data field is likely to collide with. Scribe logs `API_NAME_COLLISION` at startup if it happens, on live servers as well as in Studio. This applies to root fields only: nested fields are reached through their parent and never collide.
:::

Declaring an absent field as `nil :: string?` looks like it works, but a `nil` value puts no key in the table literal at all, so the compiler never sees the field: it gets no type metadata, no bounds, and no packing. Use [`Scribe.Optional`](/api/Scribe#optional) instead.

`Scribe.Enum` restricts a string field to a fixed set of members, and its **default must be one of them**. An empty string standing in for "no value yet" is a template error naming the field:

```lua
Status = Scribe.Enum("Idle", { "Idle", "Running", "Done" }),  -- OK
Status = Scribe.Enum("", { "Idle", "Running", "Done" }),      -- error: enum default must be one of its members
```

That holds under `Scribe.Optional` too. The default there is only a type-and-validation sample, never seeded, so an enum field that should read `nil` until it is written is still spelled `Scribe.Optional(Scribe.Enum("Idle", { "Idle", "Running", "Done" }))`.

## Dynamic (per-profile) defaults

A template default is evaluated **once**, when the module loads. So `os.time()`, `os.date()`, or `DateTime.now()` written directly capture the *server's start time* and hand that same frozen value to every new profile:

```lua
-- WRONG: every player's CreatedUnix is the server-start time, not their own.
CreatedUnix = os.time(),
```

`Scribe.Dynamic` fixes this: pass the **function**, and Scribe runs it per new profile. It also runs the factory once at module load to sample the return type, so the factory must be pure: no yields, no errors, no side effects. `Scribe.Dynamic` cannot be combined with `Scribe.Session`; use [`OnPlayerInit`](./lifecycle) for per-session values.

```lua
CreatedUnix = Scribe.Dynamic(os.time),                             -- number; pass the function itself
JoinedAt    = Scribe.Dynamic(function() return DateTime.now() end), -- DateTime, packed for you
```

The field types as the factory's return type, so `CreatedUnix` is a `number` and `JoinedAt` a `DateTime`, with full autocomplete. Datatype results are packed correctly. It's just as handy for per-profile seeds or ids.

**When the factory runs.** Scribe evaluates it whenever a profile has no stored value for the field: on a brand-new profile, and on an existing profile that gains the field after you add it to the template. A stored value is **never overwritten**, so a returning player keeps what they had. The flip side: add a creation-timestamp field long after launch and existing players get it computed on their next load, not their true creation date.

Player-specific defaults (based on `player.Name`, a `UserId` lookup, and so on) don't fit a no-argument factory, so use [`OnPlayerInit`](./lifecycle) for those.

## Reading and writing

Every field is a [`Value`](/api/Value). Index into the template shape and call methods on the leaf:

```lua
data.Coins.Get()               --> 0
data.Coins.Set(100)
data.Coins.Increment(50)       -- number fields
data.Settings.Music.Toggle()   -- boolean fields
data.QuestProgress.Insert(3)   -- array fields
data.Inventory.Sword.Level.Set(4)  -- a fresh key starts from the element defaults
data.Coins.Observe(function(v) print("coins:", v) end)
```

:::caution `Get()` on a table is read-only
For a **table** field, `Get()` hands you the stored table itself, not a copy. Mutating it writes straight into authoritative state behind Scribe's back: no validation, no replication op, and no `Changed`. The value changes on the server and even persists, but the client never hears about it.

```lua
-- WRONG: edits real state silently, and never replicates
for _, entry in data.Gifts.Daily.Get() do
    if entry.GiftId == day then
        entry.Claimed = true
    end
end

-- RIGHT: find the index, then write through the accessor
local daily = data.Gifts.Daily
for i, entry in daily.Get() do
    if entry.GiftId == day then
        daily[i].Claimed.Set(true)
        break
    end
end
```

`daily[i]` is a real [`Value`](/api/Value), so `.Set` validates, replicates, and fires listeners like any other write. This works for a plain array and for a [`Scribe.ArrayOf`](#typed-containers) alike. The entry you got from `Get()` is a plain Lua table, so it has no `.Set` of its own.

The inconsistency is the reason for the blanket rule: a subtree containing packed datatypes **is** rebuilt on the way out, so mutating that one is silently discarded instead of silently applied. Two different silent failures depending on the shape of your template. Treat everything `Get()` returns as read-only, and use [`Clone()`](/api/Value#Clone) when you want a detached table you can edit freely.
:::

### Maps with typed keys

`Scribe.DictOf` is string-keyed. When the keys are user ids, item ids, or anything else numeric, `Scribe.MapOf` declares the key type so you stop coercing at every boundary:

```lua
Friends = Scribe.MapOf("integer", {
    Name = Scribe.String(""),
    LastSeen = Scribe.Int(0),
}),

data.Friends[player.UserId].Name.Set("Ada")   -- no tostring, no tonumber
```

The declaration is not sugar. A DataStore serializes every object key to a JSON string, so an integer-keyed map comes back holding `"123"` where it stored `123`, and only the declared key type makes converting it back unambiguous: without it, `"123"` on disk could equally have been the number `123` or the string `"123"`. Scribe restores the keys on load, before anything reads them.

Keys that could not have survived that round trip are refused at the write: fractional, infinite, and `NaN`. A key that is not a canonical integer spelling (`"07"`) is left exactly as it is on load rather than relocated, since this map never wrote it.

`MaxKeys` caps the entry count. `MaxKeyLength` applies to string keys only and is refused on an integer map, where it would read as a cap that does nothing.

### Sets of unique values

`Scribe.SetOf` is for membership rather than order: owned items, unlocked levels, completed quests, claimed rewards. It is the shape people otherwise express as a dictionary of `true` values, storing a value nobody ever reads.

```lua
Unlocked = Scribe.SetOf(Scribe.String("", { MaxLength = 32 })),

data.Unlocked.Add("Desert")      --> true  (false if already a member)
data.Unlocked.Has("Desert")      --> true
data.Unlocked.Remove("Desert")   --> true  (false if it was not a member)
data.Unlocked.Count()
```

`Add` on a value already present and `Remove` on one that is absent both return `false` and do nothing: no write, no replication op, no `Changed`. Entries are kept deduplicated and in sorted order, so two profiles holding the same members hold the same table.

The element has to be a **scalar**: `Scribe.Int`, `Scribe.Number`, `Scribe.String`, or `Scribe.Enum`. Members are compared by value and stored in a sorted canonical order, and neither is meaningful for a record, so a record shape is refused by the declarator itself and anything else (a `Scribe.Big`, a datatype, a nested container) at compile time. When entries need structure, use [`Scribe.ArrayOf`](#typed-containers), or keep a scalar id in the set and the rest in a sibling `Scribe.DictOf` keyed by that id.

Unlike [`Scribe.ArrayOf`](#typed-containers) there is no `Insert` and no index-based `Remove`, since a set has no positions. `MaxItems` caps membership; [`Evict`](#rolling-windows) does not apply, because there is no oldest entry to drop. `Clear` empties the set.

### Sets of named booleans

When a fixed set of booleans belongs together, `Scribe.Flags` holds them in one field addressed by name:

```lua
Tutorial = Scribe.Flags({ "Movement", "Combat", "Trading" }),

data.Tutorial.Enable("Combat")
data.Tutorial.Has("Combat")     --> true
data.Tutorial.Toggle("Trading") --> true  (the new state)
data.Tutorial.Get()             --> { "Combat", "Trading" }
data.Tutorial.Disable("Combat") -- now { "Trading" }
data.Tutorial.Clear()           -- all off
```

`Enable`, `Disable`, `Toggle`, and `Has` each take a **member name**; `Clear` takes none and turns every flag off. Note that the [`Value`](/api/Value) page documents `Toggle` in its plain-boolean form, which flips a boolean field and takes no argument.

Compared with three sibling booleans it is one write and one `Changed` instead of one per flag, the valid names are declared rather than implied by whatever strings the code passes, and it packs to a bitmask on the wire. Enabling a name that is not a member is an error, not a silent no-op, and setting a flag to what it already is writes nothing at all.

The value is stored as the enabled member **names**, in declaration order, so **reordering or removing members in a later release is safe**. Only the wire packing is positional, and both ends of a replication frame always come from the same build. The cap is 32 members, refused at compile time rather than silently dropping the 33rd.

### Reacting to a container

Two events cover a table field, and they answer different questions.

`Changed` on a container reports **state**: something beneath this changed, here is the current value. It is coalesced, so a [`Data.Batch`](/api/Server#Batch) writing four fields fires it once, and on the client one replication frame fires it once however many children it carried. It takes `(new, old)`, where `old` is the same reference as `new` because Scribe does not snapshot a container.

The `old == new` part holds for writes **beneath** the container. A write that REPLACES the container's own table (a whole-container `Set` or `Update`, and `Scribe.SetOf` `Add`/`Remove` or `Scribe.Flags` `Enable`/`Disable`/`Toggle`, which rewrite the whole value) carries a real prior table as `old`, and is not coalesced, because collapsing it would throw that prior value away.

`OnChildChanged` reports a **transition**: this direct child moved, here is its key and both sides of the move. It takes `(key, new, old)`, matching `Changed`'s new-first order. It is never coalesced, so three writes fire it three times, and every ancestor receives its own immediate child. `old` is a real prior value when the child is a leaf; when the child is itself a container it is the same reference as `new`, for the same reason `Changed` carries that caveat.

```lua
data.Inventory.Changed(function(inv)
    redrawTotals(inv)              -- once per batch, however many slots moved
end)

data.Inventory.OnChildChanged(function(key, new, old)
    refreshSlot(key, new)          -- once per write
end)
```

All of a container's `OnChildChanged` fires arrive before its `Changed`, so you can accumulate keys and act once. For a [`Scribe.DictOf`](#typed-containers), `OnChildChanged` is the only way to learn that an existing key's **value** changed: `OnKeyAdded` and `OnKeyRemoved` report a key appearing or disappearing, never one changing.

:::caution The container `key` argument was removed in 1.3.0
A container `Changed` listener used to take a third `key` argument. One fire can now cover several children, so naming one of them would imply the others did not change. Scribe errors at connect time on a container listener declaring a third parameter rather than passing `nil` forever. Move that logic to `OnChildChanged`. Leaf listeners are unchanged. A node under an untyped `{}` subtree has no schema to judge, so it is classified by what is stored there at connect time: connect after the container exists and the check covers it too.
:::

### The root read is frozen

`Data[player].Get()` with no field in front of it is the one read that does not hand back the store. It returns a **frozen** table of exactly the roots your template declares, so the mistake above fails loudly there:

```lua
local whole = Data[player].Get()
whole.Coins = 999          --> error: attempt to modify a readonly table
Data[player].Coins.Set(999) -- the spelling that validates and replicates
```

Two things are no longer in that table that used to be. Scribe's internal `_Scribe` root (and `_ScribeSession` on the client) is gone, which is what `Scribe.PlayerData<T>` has always declared, so typed code never saw it anyway. In exchange, [`Scribe.Session`](/api/Scribe#Session) roots are now present on the server, where the type promised them but the runtime left them out.

The freeze is shallow. Nested containers reached through it are still the live tables described above, so the blanket read-only rule still applies to everything below the first level. `Clone()` returns the same shape unfrozen when you want a copy you can edit, and [`Data.Export`](/api/Server#Export) is the full profile dump including Scribe's internals.

Writes are validated against the declarator: out-of-range numbers clamp (or reject, under `BoundsPolicy = "Reject"`), enum values outside the set are refused, and a string past a field's `MaxLength` is truncated on a character boundary (so a multi-byte character is never split), or rejected under `BoundsPolicy = "Reject"`. Note `MaxLength` counts **bytes**, not characters, so budget for multi-byte text.

Separately, values that simply cannot be stored are always rejected outright:

- unsupported types: functions, threads, Instances and other userdata
- non-finite numbers (NaN or infinity)
- strings or table keys that are not valid UTF-8
- tables that mix array indices with string keys, which JSON cannot encode, so the whole profile save would fail later

Data written through raw paths that bypass the accessor, such as migrations or `OnPlayerInit`, is scanned for the same problems at load and reported as `PROFILE_UNPERSISTABLE`.

### Naming the accessor type

To store a profile in your own class or table you need a name for the accessor's type. That is `Scribe.PlayerData<T>`, the type of `Data[player]`, `Data.Get(player)`, and the client's `Data.Get()`:

```lua
export type Template = typeof(template) -- from the module that calls Scribe()

type PlayerData = Scribe.PlayerData<Template>

local function new(player: Player, data: PlayerData)
    return { player = player, joinedAt = os.time(), data = data }
end
```

Use `Scribe.ServerData<T>` and `Scribe.ClientData<T>` for the whole `Data` object, and `Scribe.PlayerData<T>` for one player's tree.

## Big numbers

A plain Luau number stops being exact past `2^53` and stops existing past `1.8e308`. For an idle or simulator currency that runs off that scale, use [`Scribe.Big`](/api/Scribe#Big):

```lua
Coins = Scribe.Big(0, { Min = 0 }),

data.Coins.Set("1.5e100")             -- a numeric string, since 1.5e100 is fine but 1e400 is not
data.Coins.Increment("2e99")          -- 1.7e100
data.Coins.Multiply(1.15)             -- 1.955e100
data.Coins.Get():Short()              --> "1.955e100"
```

This trades precision for range **on purpose**. A big carries about 15 significant digits at any magnitude, so `1e20 + 1 == 1e20`. That is the right trade for a currency whose magnitude is the whole point, and the wrong one for anything audited: use [`Scribe.Int`](/api/Scribe#Int) when every digit has to be exact.

`Set`, `Increment`, `Decrement`, `Multiply`, and `Divide` all accept a plain number, a numeric string like `"1.5e100"`, or another big value. A bound past `1.8e308` has to be a string too, because a larger literal is already `math.huge`:

```lua
Prestige = Scribe.Big(0, { Min = 0, Max = "1e600" }),
```

### Working with the value

`Get()` returns an object, not a number. It supports `+`, `-`, `*`, `/`, `tostring`, `:Short()`, and `:ToNumber()`, and exposes its mantissa and exponent as `.M` and `.E`.

```lua
local coins = data.Coins.Get()
coins + 5          -- fine, and 5 + coins works too
coins * 2          -- fine
tostring(coins)    --> "1.5e100"
coins:ToNumber()   -- lossy, and saturates to inf past 1.8e308
coins.M, coins.E   --> 1.5, 100
```

:::caution Comparisons need a big on **both** sides
Luau picks `<` and `<=` by metatable identity, so mixing a big with a plain number throws *"attempt to compare table < number"*. `==` is worse: Luau only consults it when both sides are tables, so `Get() == 5` is silently `false` rather than an error.

Two big fields compare directly. To test against a constant, convert first:

```lua
if data.Coins.Get() < data.Bank.Get() then end   -- OK, both are bigs
if data.Coins.Get() < 2000 then end              -- THROWS
if data.Coins.Get():ToNumber() < 2000 then end   -- OK
if data.Coins.Get() == 5 then end                -- always false, never fires
if data.Coins.Get():ToNumber() == 5 then end     -- OK
```

There is no public constructor for a standalone big, so a threshold comparison goes through `:ToNumber()`. That is exact while the threshold is inside the double range, which covers any constant you can write as a literal.
:::

### Displaying it

`:Short()` formats for UI, with an optional decimal count (default 2). It uses letter suffixes while it can and falls back to scientific notation once it runs out:

| Value | `:Short()` | `:Short(0)` | `:Short(3)` |
| --- | --- | --- | --- |
| `70` | `"70"` | `"70"` | `"70"` |
| `1500` | `"1.50K"` | `"2K"` | `"1.500K"` |
| `1e9` | `"1.00B"` | `"1B"` | `"1.000B"` |
| `1e40` | `"10.00DDc"` | `"10DDc"` | `"10.000DDc"` |
| `1.5e100` | `"1.5e100"` | `"1.5e100"` | `"1.5e100"` |

Note `Short(0)` rounds rather than truncates, so `1500` shows as `"2K"`.

### Bounds

`Min` and `Max` behave like they do on `Scribe.Int`, which means they follow [`BoundsPolicy`](./configuration): the default `"Clamp"` pins the value into range and fires an anomaly, while `"Reject"` throws at the write site. Under the default, `Decrement`ing a `{ Min = 0 }` field below zero leaves it at `0` instead of erroring, so a "can they afford it?" check is still your job:

```lua
if data.Coins.Get():ToNumber() >= price then
    data.Coins.Decrement(price, { Source = "Shop" })
end
```

A big field can also be a leaderboard stat, ranked exactly rather than by a lossy `number`. That has its own rules (non-negative values, `SigFigs`, no `Scale`), covered in [Leaderboards](./leaderboards#ranking-a-scribebig).

## Timed fields

A `Scribe.Timed` field auto-clears back to its default when its timer lapses, firing `Changed`. A client `Observe` already covers "the booster ended":

```lua
XPBooster = Scribe.Timed(false),

-- server
data.XPBooster.SetTimed(true, 3600)  -- true for one hour
data.XPBooster.ExtendTimed(1800)     -- add 30 minutes
local active, remaining = data.XPBooster.Active()
```

`Scribe.Timed` wraps a **single leaf value**: a number, string, boolean, or a datatype declarator. A table is refused at startup with "Scribe.Timed only wraps leaf values", and a container declarator with "Scribe.Timed cannot wrap Scribe.ArrayOf". So a bundle of buff values that expire together (`Scribe.Timed({ Damage = 2, Speed = 1.5 })`) is not a template you can write: declare the fields normally and time a single flag beside them, or keep an expiry timestamp on the record and read it yourself.

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

Cooldowns count wall-clock time by default, so one armed before logging off keeps running while the player is away. Pass `{ IncludeOfflineTime = false }` for one that only ticks down while they are playing:

```lua
Data.OnCooldown(player, "Boost", 3600, { IncludeOfflineTime = false })
```

Scribe stores the remaining seconds rather than a deadline for those, converting on every save, so a server crash costs at most the countdown since the last save and can only make the cooldown end slightly late, never early. A key holds one cooldown either way, and `PeekCooldown`/`ClearCooldown` cover both modes.

To react the moment one lapses, connect [`OnCooldownEnded`](/api/Server#OnCooldownEnded). A cooldown holds no value, so unlike a lapsing `Timed` field it fires no `Changed`, and this signal is its only expiry notification:

```lua
Data.OnCooldownEnded:Connect(function(player, key)
    if key ~= "DailyReward" then
        return
    end
    -- the daily reward is claimable again
end)
```

One signal covers every cooldown, because keys are arbitrary strings rather than declared fields, so there is no set to subscribe to. It fires within about a second of expiry, and **not** for cooldowns that lapsed while the player was offline; read those with `PeekCooldown` at join.

## Roblox datatype fields

For positions, colours, CFrames, and the like, use the datatype declarators. The value is stored and replicated as a **compact packed buffer**; your code only ever sees the real datatype.

```lua
SpawnPoint = Scribe.Vector3(Vector3.zero),
HomeDoor   = Scribe.CFrame(CFrame.identity),  -- axis-aligned rotations pack to 13 bytes
Tint       = Scribe.Color3(Color3.fromRGB(255, 120, 0)),
```

All 17 are supported: `Vector3`, `Vector2`, `Vector3int16`, `Vector2int16`, `CFrame`, `Color3`, `BrickColor`, `UDim`, `UDim2`, `Rect`, `NumberRange`, `NumberSequence`, `ColorSequence`, `DateTime`, `EnumItem`, `Font`, `PhysicalProperties`.

`buffer` values are also first-class template fields, ideal for games that save large placed-structure or inventory blobs.

## Typed containers

A plain `{}` field stores whatever you put in it, but its entries have no schema, so they get no type checking, no bounds, and no datatype packing. Give the entries a shape instead:

```lua
PlacedFurniture = Scribe.ArrayOf({
    Cf     = Scribe.CFrame(CFrame.new()),
    ItemId = Scribe.String("", { MaxLength = 64 }),
}, { MaxItems = 200 }),

Resources = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 64 }),
```

Now every entry is validated like a declared field, and `data.PlacedFurniture[1].Cf` is a typed accessor returning a real `CFrame`:

```lua
data.PlacedFurniture.Insert({ Cf = CFrame.new(0, 5, 0), ItemId = "OakChair" })
local cf = data.PlacedFurniture[1].Cf.Get()  -- a CFrame, unpacked for you

data.Resources.Wood.Increment(5)  -- a fresh key starts from the declared default
```

Packing is schema-driven, so an element schema is what lets a datatype live in a container at all. Without one, Scribe could not tell a packed CFrame from a buffer you stored yourself. (You can still pack an untyped container by hand with `Scribe.Datatypes.Pack("CFrame", cf)` and `Unpack("CFrame", stored)`.)

Putting a declarator inside a plain array literal is a template error for the same reason, and the error names the fix.

**`ArrayOf`** is for lists: contiguous integer indices, entries created with `Insert`.

**`DictOf`** is for string-keyed maps. A key exists only once something writes it, so `Get()` on an unwritten key is `nil` and `Count()` excludes it, and the element default is what that first write starts from. Any string is a valid key, so there is no typo protection on the key itself: when the key set is fixed and known, declare ordinary fields instead.

They nest freely, in any combination, up to Scribe's 24-level write depth. That budget is counted from the template root, so the levels above a container come out of it too, and an element shape that pushes past it is refused at startup with an error naming the field:

```lua
Plots = Scribe.ArrayOf({
    Name      = Scribe.String("", { MaxLength = 32 }),
    Furniture = Scribe.DictOf({ Cf = Scribe.CFrame(CFrame.new()) }, { MaxKeys = 200 }),
}, { MaxItems = 4 }),
```

The element shape can also be a single declarator rather than a record: `Scribe.ArrayOf(Scribe.CFrame(CFrame.new()))` is an array of CFrames.

### Rolling windows

By default an `Insert` at `MaxItems` is an error. `Evict` turns the cap into a rolling window instead: the insert drops an entry to make room. That is what you want for a bounded history like recent matches or a kill feed. It takes `"Front"` or `"Back"`, and it requires `MaxItems`, since a bare `Evict` has nothing to drop from.

```lua
RecentMatches = Scribe.ArrayOf({
    MapId = Scribe.String("", { MaxLength = 32 }),
    Score = Scribe.Int(0),
}, { MaxItems = 10, Evict = "Front" }),
```

`Evict` names the **end to drop from**, not an age, because which end holds the oldest entry depends on how you insert. Append with `Insert(item)` and the oldest sits at the front, so you want `"Front"`; prepend with `Insert(item, 1)` and the oldest sits at the back, so you want `"Back"`. Picking the end your inserts do not target churns that end while the other freezes.

The drop is a real removal, not a quiet truncation: it fires `OnRemove` and replicates, so a listener sees what was dropped and client mirrors stay the right length. An array that is already over cap (a lowered `MaxItems`, or entries written before the cap existed) is trimmed all the way down on the next `Insert` rather than one entry per write.

`Evict` is an `ArrayOf` option only. `DictOf`, `MapOf`, and `SetOf` refuse it as an unknown option, since none of them has a positional end to drop from.

### Element rules

**Records are closed.** A field the shape does not declare is a write error, so a typo like `data.PlacedFurniture[1].Colour.Set("red")` fails loudly instead of persisting forever.

**Omitted fields fill from their defaults.** `Insert({ ItemId = "chair" })` stores the declared `Cf` default too. The *typed* surface still asks for every field though, so in strict Luau either pass the whole element, or mark the ones that may be absent:

```lua
Note = Scribe.Optional(Scribe.String("", { MaxLength = 64 })),
```

An optional field has no default at all: it is never seeded or filled, and reads `nil` until written.

**Caps reject by default.** `MaxItems`, `MaxKeys`, and `MaxKeyLength` turn unbounded growth into an error naming the field, rather than a profile that quietly grows until it can no longer save. The one opt-in is [`Evict`](#rolling-windows) on an `ArrayOf`, which makes `MaxItems` a rolling window instead.

**Searching compares by value.** `Has`, `Find`, and `RemoveValue` match declared elements structurally, so the value `Get()` handed you finds the stored one:

```lua
local item = data.PlacedFurniture.Get()[2]
data.PlacedFurniture.RemoveValue(item)  -- removes index 2
```

**Array indices are positional.** `data.Plots[2]` means whatever sits at index 2 right now, so a per-element `Observe` follows the index, not the element. Watch the container with `OnInsert` / `OnRemove` instead. This is also why `Scribe.Timed` is rejected inside an element shape (a running timer would follow the index too), as is `Scribe.Dynamic` (its factory seeds once per new profile, and elements do not exist then).

**Remove entries with `Remove`.** `data.Plots[2].Set(nil)` is refused except on the last entry, since a hole would split `#arr` from `Count()`.

**Method names are reserved.** A field named `Count`, `Get`, `Set`, `Insert`, and so on is shadowed by the accessor method and unreachable through the typed API. Scribe logs `API_NAME_COLLISION` naming it.

### Untyped containers

Keep a plain `{}` field when you genuinely want a free-form blob:

```lua
Loose = {} :: { [string]: any },  -- free-form map, written by key
Blobs = {} :: { any },            -- free-form list, written with Insert
```

Two write rules tightened in v1.0.10, on any array, typed or not:

- **`Insert(nil)` is an error**, as is a non-integer position. Inserting `nil` at a middle position used to shift the entries above it and leave a hole.
- **A table mixing array indices with string keys is rejected at the write site.** One could never have been saved (the DataStore's JSON encoder fails on it), so this used to surface as a lost profile save long after the write that caused it.
