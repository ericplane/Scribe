# Declaring Your Template

Your **template** describes one player's data: its fields, their types, and their starting values. Start with plain values. Add rules only where your game needs them.

This guide builds on the shared module in [Getting Started](./intro). The larger [Emberfall example](./emberfall) shows how the same ideas fit together in an RPG.

## Declaring a field

The tutorial starts with `Coins = 0`. To make coins a whole number that stays above or equal to zero, replace that field with `Scribe.Int`:

```lua
local template = {
    Coins = Scribe.Int(0, { Min = 0 }),
    Settings = {
        Music = true,
    },
}
```

`Scribe.Int(0, { Min = 0 })` gives the field a starting value and rules. Scribe calls this a **declarator**. The starting value is `0`; the rules require a whole number with a minimum of `0`.

By default, an out-of-range write is **clamped** to the nearest allowed value. It does not throw an error:

```lua
-- On the server, after Data.WaitForData(player) succeeds:
data.Coins.Set(-10)
print(data.Coins.Get()) -- 0

data.Coins.Set(2.7)
print(data.Coins.Get()) -- 3
```

Set `BoundsPolicy = "Reject"` alongside `Template` in your Scribe options if you want these writes to throw instead. Wrong types, such as writing a string to `Coins`, are always rejected.

[Try clamping and rejection in the playground](playground.md?example=clamp). Change the bounds or the written value and inspect the result before adding the field to your game.

Nested tables work the same way: `Settings.Music = true` becomes `data.Settings.Music.Get()`. You do not need a special declaration for a group of fixed fields.

## Plain values and declarators

A plain value works too. `Playtime = 0` would give you a number field defaulting to zero, with its type inferred and no rules attached. Use one when the field genuinely needs nothing else.

A declarator adds rules such as bounds, allowed strings, or a length limit. It also gives your editor the field's type, so autocomplete matches the value you declared.

Use this table to find the kind of field you need. You do not need to learn every declaration before using Scribe.

| Declarator | Use it for |
| --- | --- |
| [`Scribe.Int(default, { Min, Max })`](/api/Scribe#Int) | Whole numbers, such as coins or levels. |
| [`Scribe.Number(default, { Min, Max, Precision })`](/api/Scribe#Number) | Numbers that can have a fractional part. Optional `Precision` [reduces network size](#narrowing-a-float). |
| [`Scribe.String(default, { MaxLength })`](/api/Scribe#String) | Strings, optionally capped by byte length. |
| [`Scribe.Enum(default, members)`](/api/Scribe#Enum) | One of a fixed set of strings, such as an item's rarity. |
| [`Scribe.Optional(inner)`](/api/Scribe#Optional) | A field that may legitimately be absent. |
| [`Scribe.Dynamic(factory)`](/api/Scribe#Dynamic) | A default computed once per profile, such as a creation timestamp. |
| [`Scribe.Big(default, { Min, Max })`](/api/Scribe#Big) | Numbers past `2^53`, for idle and simulator currencies. |
| [`Scribe.Derived(output, inputs, compute)`](/api/Scribe#Derived) | A read-only field computed from other fields. |
| [`Scribe.Timed(default)`](/api/Scribe#Timed) | A value that clears itself when its timer lapses. |
| [`Scribe.Flags(members)`](/api/Scribe#Flags) | Up to 32 named booleans held in one field. |
| [`Scribe.ArrayOf(shape, opts)`](/api/Scribe#ArrayOf) | A list whose entries have a declared shape. |
| [`Scribe.DictOf(shape, opts)`](/api/Scribe#DictOf) | A string-keyed map whose values have a declared shape. |
| [`Scribe.MapOf(keyType, value, opts)`](/api/Scribe#MapOf) | A map whose **key** type is declared, `"integer"` or `"string"`. |
| [`Scribe.SetOf(element, opts)`](/api/Scribe#SetOf) | A collection of unique scalars, for membership rather than order. |
| [`Scribe.Vector3(default)`](/api/Scribe#Vector3) and related declarations | Roblox values such as positions, colors, and transforms. |

The container declarators, the datatype family, `Scribe.Flags`, `Scribe.Big`, `Scribe.Timed` and `Scribe.Derived` each have a guide of their own, linked at the foot of this page. Everything else in that table is covered here.

## Numbers, strings, and enums

`Scribe.Int` rounds a non-integer write and clamps an out-of-range one. Both `Min` and `Max` must themselves be integers, and both must be finite, or the template refuses to compile.

`Scribe.String` takes a `MaxLength`, and **that budget counts bytes, not characters**. A three-character CJK name is nine bytes and trips a `MaxLength` of eight, so size the cap for the alphabets your players actually type. An over-long write is truncated on a character boundary rather than mid-character, which would produce invalid UTF-8 and fail the profile's next save.

`Scribe.Enum` restricts a string field to a fixed set of members, and **its default must be one of them**. Emberfall uses one for item rarity:

```lua
local RARITIES = { "Common", "Rare", "Epic", "Legendary" }

Rarity = Scribe.Enum("Common", RARITIES),   -- OK
Rarity = Scribe.Enum("", RARITIES),         -- error naming the field
```

An empty string standing in for "no value yet" is a template error. If a field should genuinely read `nil` until something writes it, that is what `Scribe.Optional` is for, and the enum default inside it is still required to be a member.

??? note "What clamping actually does, and how to turn it off"
    Out-of-range numbers clamp by default and report an anomaly for diagnostics. Set [`BoundsPolicy = "Reject"`](./configuration) and the write throws at the call site instead. The same switch governs over-long strings. An enum value outside its declared members is always rejected, under either policy.

    Some values are always rejected, under either policy, because nothing could store them: functions, threads, Instances and other userdata, non-finite numbers, strings or table keys that are not valid UTF-8, and tables that mix array indices with string keys, which the DataStore's JSON encoder cannot write at all.

## Fields that may be absent

Declaring an absent field as `nil :: string?` looks like it works, and it does not. A `nil` value puts no key in the table literal at all, so the compiler never sees the field: no type metadata, no bounds, no packing. Use [`Scribe.Optional`](/api/Scribe#Optional) instead, wrapping the declarator that supplies the type:

```lua
Inventory = Scribe.DictOf({
    Qty      = Scribe.Int(1, { Min = 1, Max = 999 }),
    Rarity   = Scribe.Enum("Common", RARITIES),
    Nickname = Scribe.Optional(Scribe.String("", { MaxLength = 20 })),
}, { MaxKeys = 200 }),
```

The inner default is dropped. An optional field has **no** default at all, so it is never seeded into a new profile and never filled in when a write omits it. It reads `nil` until something writes it, and `Set(nil)` takes it back to absent.

`Scribe.Optional` wraps leaves only. It refuses `Scribe.Timed`, because a lapsed timer restores a default that an optional field does not have, and it refuses `Scribe.Dynamic`, because a factory exists precisely to seed a value. It also refuses a container declarator, since an empty container is already the absent case.

## Defaults computed per profile

A template default is evaluated **once**, when the module loads. So `os.time()` written directly captures the server's start time and hands that same frozen number to every new profile:

```lua
-- WRONG: every player's CreatedUnix is the server-start time, not their own.
CreatedUnix = os.time(),
```

`Scribe.Dynamic` fixes it. Pass the function itself, and Scribe runs it once per new profile:

```lua
CreatedUnix = Scribe.Dynamic(os.time),
JoinedAt    = Scribe.Dynamic(function() return DateTime.now() end),
```

The field takes the factory's return type, so `CreatedUnix` is a `number` and `JoinedAt` a `DateTime`, with autocomplete on both. Datatype results are packed for you.

Scribe evaluates the factory whenever a profile has no stored value for that field: on a brand-new profile, and on an existing profile that gains the field after you add it. A stored value is **never** overwritten, so a returning player keeps what they had. The flip side is worth planning for. Add a creation-timestamp field long after launch and existing players get it computed on their next load, not their true creation date.

??? note "Factory restrictions"
    Scribe calls the factory once at module load to sample its return type, so a factory that yields, errors, or has a side effect does that at startup as well as per profile. Keep it to a clock read, a random seed, or an id.

    A no-argument factory also cannot see the player, so defaults that depend on `player.Name` or a `UserId` lookup do not fit here. Use [`OnPlayerInit`](./lifecycle) for those. `Scribe.Dynamic` cannot be combined with [`Scribe.Session`](./visibility) either, for the same reason: a session field is rebuilt every session, and `OnPlayerInit` is the hook that runs then.

## Narrowing a float

This section is an optional network optimization. You can leave `Precision` unset and move on to [reading and writing values](./values).

A `Scribe.Number` uses an eight-byte double in numeric replication. `Precision` can reduce that size when a slightly rounded client value is acceptable.

It is opt-in and it stays opt-in. Omit `Precision` and nothing changes. Declaring `Min` and `Max` alone narrows nothing, because bounds have meant "validate and clamp" since long before this option existed.

Emberfall's template has no float in it today. Say you add an accuracy stat, a fraction between zero and one:

```lua
Stats = {
    Deaths   = Scribe.Int(0, { Min = 0 }),
    Playtime = Scribe.Int(0, { Min = 0 }),
    Accuracy = Scribe.Number(0, { Min = 0, Max = 1, Precision = 0.001 }), -- 2 bytes
},
```

| `Precision` | Wire bytes | Error |
| --- | --- | --- |
| omitted | 8 | none, every double round-trips bit for bit |
| `"f32"` | 4 | relative, up to `2^-24`, about 7 significant decimal digits |
| a number | 1, 2 or 4 | absolute, up to `Precision / 2` |

A numeric `Precision` is a **fixed-point step**. The field travels as the index of the nearest point on a grid of that step across `[Min, Max]`, so both bounds are required, and the width is the narrowest of 1, 2 or 4 bytes that indexes the grid. `Accuracy` above is 1001 grid points, so two bytes, and every value arrives within `0.0005` of what was sent.

??? note "What you trade away, and what is never mangled"
    Narrowing changes the value the **client** sees. The server keeps the full double it was given and persists it unchanged. Only the replicated copy is quantized, so do not compare a client-side narrowed field to the server's value for equality.

    Nothing is silently mangled. A value the narrowed form cannot carry within the error above is not rounded, capped or flushed. It is sent as an exact `f64` on the generic path instead, costing four bytes more than the narrowing saves and losing nothing. That covers `NaN`, both infinities, anything outside `[Min, Max]` on a fixed-point field, and anything past the binary32 range or below its smallest normal magnitude on an `"f32"` one. Subnormals never flush to zero, and a large value never rounds to infinity.

    On a float-heavy diff this is most of the frame. The corpus measured in `WireFloat.spec`, 64 three-component transforms as `f32` plus 136 fractions on one-byte grids, goes from 3176 bytes to 1452. That is a 54% saving: four bytes off every `f32` field and seven off every one-byte one.

??? note "Declarations that fail at compile time"
    A declaration that cannot be represented in the width it asks for fails when the template compiles, not when a value first fails to fit:

    ```lua
    Scribe.Number(0, { Min = 0, Max = 100, Precision = 1e-9 })  -- 1e11 grid steps, past what an index holds
    Scribe.Number(0, { Max = 1e39, Precision = "f32" })         -- a bound past the binary32 range
    Scribe.Number(0, { Min = 1e17, Max = 1e17 + 10, Precision = 0.1 }) -- finer than a double's own spacing there
    Scribe.Number(0, { Precision = 0.5 })                       -- a numeric Precision needs both Min and Max
    Scribe.Int(0, { Min = 0, Max = 9, Precision = 1 })          -- Precision is a Scribe.Number option
    ```

    That last one is refused rather than ignored. A bounded `Scribe.Int` already packs from its `Min` and `Max` alone, so `Precision` there would be a belief about the field that nothing would ever correct.

    `Precision` also appears on [`Scribe.CFrame`](./datatypes), where it names the same thing and points the other way: a `CFrame`'s default is the lossy form, so there it buys precision with bytes rather than the reverse. Those are the only two declarators that take it.

!!! warning "Narrowing is a wire change"
    `Precision` is folded into the schema hash and the wire protocol version, so a client and a server that disagree about it refuse the handshake rather than mis-decoding. Adding or changing `Precision` needs both realms deployed together, like any other template change.

## Names Scribe will not let you use

Two sets of names are off limits, and both are reported at startup rather than discovered later.

**Method names.** A field called `Count`, `Get`, `Set`, `Insert`, or any other accessor method name is shadowed by the method and unreachable through the typed API, at any depth. Scribe logs `API_NAME_COLLISION` naming the field.

**Root fields that collide with a client API name.** On the client you read a root field as `Data.Coins`, so a root named after a client method or property becomes unreachable by that name. Examples include `Owns`, `Request`, `Mock`, `Raw`, `IsReady`, and `Stop`; check the [client API](/api/Client) when choosing a name. This rule applies to root fields, since nested fields are reached through their parent. Accessor method names remain reserved at every depth.

The `_Scribe` root is reserved outright, along with any root name beginning with it, and the template refuses to compile if you declare one.

## Naming the accessor type

This section is for adding type annotations to your own modules. Ordinary reads and writes do not need these annotations.

Scribe calls the object returned by `WaitForData` an **accessor tree**: each field provides methods such as `Get` and `Set`. Its type is `Scribe.PlayerData<T>`, also returned by `Data.Get(player)` on the server and `Data.Get()` on the client:

```lua
export type Template = typeof(template) -- from the module that calls Scribe()

type EmberfallData = Scribe.PlayerData<Template>

local function newSession(player: Player, data: EmberfallData)
    return { player = player, joinedAt = os.time(), data = data }
end
```

Use `Scribe.ServerData<T>` and `Scribe.ClientData<T>` when you need to name the whole `Data` object rather than one player's tree.

### If Luau says the code is too complex

On a large template the `Scribe({ ... })` call can report "Code is too complex to typecheck", and Luau then silently stops checking the whole file. The accessor trees are not the cost. What the solver cannot afford is instantiating both halves of the bundle inside one call, so name the options, cast the call, and annotate the half you use:

```lua
local options: Scribe.ScribeOptions<typeof(template)> = {
    Template = template,
    ProfileStoreIndex = "MyGameData",
    ProfileKeyPrefix = "PLAYER_",
}
local Data = (Scribe :: any)(options).Server :: Scribe.ServerData<typeof(template)>
```

The options literal is still checked against your template, `Data` is the same type the bundle would have given you, and every diagnostic inside is unchanged. Measured with the analyzer CI runs, a template of distinct five-field records checks to 32 roots through the plain call and past 256 this way; one of `DictOf` containers moves from 16 to past 256.

## Where to next

- [Reading and Writing Values](./values) covers what you can call on a field once you have declared it.
- [Containers](./containers) is the rest of the declarator list: arrays, dictionaries, maps, sets, and flags.
- [Derived Fields](./derived) explains Emberfall's `Level`, which is computed rather than stored.
- [Roblox Datatypes](./datatypes) covers `Vector3`, `CFrame`, and the fifteen others.
- [Big Numbers](./big-numbers) is for a currency that runs past `2^53`.
- [Timers & Cooldowns](./time) covers `Scribe.Timed` and the cooldown API beside it.
- [Replication and Visibility](./visibility) decides which of these fields the client ever sees.
- [The Server Store](./server-store) declares the round state that belongs to nobody.
