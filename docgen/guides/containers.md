# Containers

Most player data is a collection of something: items in a bag, regions you have unlocked, the last ten runs you played. A container field holds many entries under one name, and Scribe gives every entry the same validation, bounds and packing a top-level field gets.

Reach for one whenever the number of things is not known when you write the template.

## An inventory

Emberfall's `Inventory` is a dictionary keyed by item id, and every entry has the same shape:

```lua
local RARITIES = { "Common", "Rare", "Epic", "Legendary" }

Inventory = Scribe.DictOf({
    Qty    = Scribe.Int(1, { Min = 1, Max = 999 }),
    Rarity = Scribe.Enum("Common", RARITIES),
}, { MaxKeys = 200 }),
```

Writing a key creates it, and the entry is a typed accessor like anything else:

```lua
local data = Data.WaitForData(player)

data.Inventory.Emberblade.Set({ Qty = 1, Rarity = "Legendary" })
data.Inventory.Emberblade.Qty.Increment(1)   --> 2

print(data.Inventory.Emberblade.Rarity.Get())  --> "Legendary"
print(data.Inventory.Count())                  --> 1

data.Inventory.Remove("Emberblade")
```

A key exists only once something writes it, so `Get()` on an unwritten key is `nil` and `Count()` excludes it. `MaxKeys = 200` turns unbounded growth into a write error naming the field instead of a profile that quietly grows until it can no longer save.

## The five container declarators

| Declarator | Holds | Keyed by | Reach for it when |
| --- | --- | --- | --- |
| [`Scribe.DictOf(shape, opts)`](/api/Scribe#DictOf) | many entries of one shape | any string | the key is an id you already have |
| [`Scribe.MapOf(keyType, shape, opts)`](/api/Scribe#MapOf) | many entries of one shape | a declared key type | the keys are numbers, such as user ids |
| [`Scribe.ArrayOf(shape, opts)`](/api/Scribe#ArrayOf) | an ordered list | position | order matters, or entries have no id |
| [`Scribe.SetOf(element, opts)`](/api/Scribe#SetOf) | unique scalars | nothing | you only care about membership |
| [`Scribe.Flags(members)`](/api/Scribe#Flags) | a fixed set of booleans | a declared name | the names are known up front |

The element shape can be a record, as `Inventory` uses, or a single declarator: `Scribe.ArrayOf(Scribe.Int(0))` is an array of integers.

They nest freely in any combination, up to Scribe's 24-level write depth. That budget is counted from the template root, so the levels above a container come out of it too, and an element shape that pushes past it is refused at startup with an error naming the field.

## Lists

`Scribe.ArrayOf` is for contiguous integer indices, with entries created by `Insert`. Emberfall keeps the last ten runs:

```lua
RecentRuns = Scribe.ArrayOf({
    Zone  = Scribe.String("", { MaxLength = 32 }),
    Score = Scribe.Int(0, { Min = 0 }),
}, { MaxItems = 10, Evict = "Front" }),
```

```lua
data.RecentRuns.Insert({ Zone = "Ashfall Ridge", Score = 4200 })
data.RecentRuns[1].Score.Get()
data.RecentRuns.Remove(1)          -- by index, returns the removed entry
data.RecentRuns.Count()
```

By default an `Insert` at `MaxItems` is an error. `Evict` turns the cap into a rolling window instead, dropping an entry to make room. It takes `"Front"` or `"Back"`, and it requires `MaxItems`, since a bare `Evict` has nothing to drop from.

`Evict` names the **end to drop from**, not an age, because which end holds the oldest entry depends on how you insert. Append with `Insert(item)` and the oldest sits at the front, so you want `"Front"`. Prepend with `Insert(item, 1)` and the oldest sits at the back, so you want `"Back"`. Picking the end your inserts do not target churns that end while the other freezes.

The drop is a real removal rather than a quiet truncation. It fires `OnRemove` and it replicates, so a listener sees what was dropped and client mirrors stay the right length. An array that is already **over** cap, because you lowered `MaxItems` or because the entries predate it, trims all the way down on the next `Insert` rather than shedding one entry per write.

??? note "Watching an index is not watching an element"
    `data.RecentRuns[2]` means whatever sits at index 2 right now, so a per-element `Observe` follows the **index**, not the element. Insert or remove at or below index 2 and that listener fires with whatever moved into the slot, not with a change to the thing you were watching. Appending shifts nothing, so it wakes nobody.

    To follow the element instead, watch the container with `OnInsert` and `OnRemove` and key off the value.

    This is also why [`Scribe.Timed`](./time) is rejected inside an element shape, since a running timer would follow the index too, and why `Scribe.Dynamic` is rejected, since its factory seeds once per new profile and elements do not exist then.

`Evict` is an `ArrayOf` option only. `DictOf`, `MapOf` and `SetOf` refuse it as an unknown option, because none of them has a positional end to drop from.

## Maps with typed keys

`Scribe.DictOf` is string-keyed. When the keys are user ids, item ids, or anything else numeric, `Scribe.MapOf` declares the key type so you stop coercing at every boundary:

```lua
Friends = Scribe.MapOf("integer", {
    Name     = Scribe.String("", { MaxLength = 32 }),
    LastSeen = Scribe.Int(0, { Min = 0 }),
}),

data.Friends[ben.UserId].Name.Set("Ben")   -- no tostring, no tonumber
```

The declaration is not sugar. A DataStore serializes every object key to a JSON string, so an integer-keyed map comes back holding `"123"` where it stored `123`, and only the declared key type makes converting it back unambiguous. Scribe restores the keys on load, before anything reads them.

Keys that could not have survived that round trip are refused at the write: fractional, infinite, and NaN. A key that is not a canonical integer spelling, such as `"07"`, is left exactly as it is on load rather than relocated, since this map never wrote it.

`MaxKeys` caps the entry count. `MaxKeyLength` applies to string keys only and is refused on an integer map, where it would read as a cap that does nothing.

:::caution `MaxKeyLength` counts bytes, not characters
A three-character CJK key is nine bytes and trips a `MaxKeyLength` of eight. Size it for the alphabets your players actually type.
:::

## Sets of unique values

`Scribe.SetOf` is for membership rather than order: regions unlocked, quests completed, rewards claimed. It is the shape people otherwise express as a dictionary of `true` values, storing a value nobody ever reads.

```lua
Unlocked = Scribe.SetOf(Scribe.String("", { MaxLength = 32 }), { MaxItems = 64 }),
```

```lua
data.Unlocked.Add("AshfallRidge")      --> true
data.Unlocked.Add("AshfallRidge")      --> false, already a member
data.Unlocked.Has("AshfallRidge")      --> true
data.Unlocked.Remove("AshfallRidge")   --> true
data.Unlocked.Count()                  --> 0
data.Unlocked.Clear()
```

`Add` on a value already present, and `Remove` on one that is absent, both return `false` and do nothing: no write, no replication op, no `Changed`. That makes `Add` a safe idempotent grant, which is exactly what you want when the same quest-complete path can run twice.

Entries are kept deduplicated and in sorted order, so two profiles holding the same members hold the same table.

The element has to be a **scalar**: `Scribe.Int`, `Scribe.Number`, `Scribe.String` or `Scribe.Enum`. Members are compared by value and stored in a canonical order, and neither is meaningful for a record, so a record shape is refused by the declarator itself, and a `Scribe.Big`, a datatype or a nested container is refused when the template compiles. When entries need structure, use `Scribe.ArrayOf`, or keep a scalar id in the set and the rest in a sibling `Scribe.DictOf` keyed by that id.

There is no `Insert` and no index-based `Remove`, since a set has no positions. `MaxItems` caps membership, and `Evict` does not apply, because there is no oldest entry to drop.

## Named booleans

When a fixed set of booleans belongs together, `Scribe.Flags` holds them in one field addressed by name. Emberfall's `Settings` is one:

```lua
Settings = Scribe.Flags({ "Music", "Sfx", "TutorialDone" }),
```

```lua
data.Settings.Enable("Music")
data.Settings.Enable("Sfx")
data.Settings.Has("Music")          --> true
data.Settings.Toggle("Sfx")         --> false, the new state
data.Settings.Disable("Music")
data.Settings.Enable("TutorialDone")
data.Settings.Get()                 --> { "TutorialDone" }
data.Settings.Clear()               -- every flag off
```

`Enable`, `Disable`, `Toggle` and `Has` each take a **member name**. `Clear` takes none. Enabling a name that is not a member is an error rather than a silent no-op, and setting a flag to what it already is writes nothing at all.

Compared with three sibling booleans this is one write and one `Changed` instead of one per flag, the valid names are declared rather than implied by whatever strings the code happens to pass, and it packs to a bitmask on the wire.

??? note "Five methods that live on one field kind only"
    `Add`, `Enable`, `Disable`, `Multiply` and `Divide` are each generated onto one kind of field and nowhere else, so your editor suggests them only where they apply. Each has its own entry on the [`Value`](/api/Value) reference; here is the whole surface at a glance:

    | Method | Field kind | Signature |
    | --- | --- | --- |
    | `Add` | `Scribe.SetOf` | `Add(item, replicate?) -> boolean` |
    | `Enable` | `Scribe.Flags` | `Enable(name, replicate?)` |
    | `Disable` | `Scribe.Flags` | `Disable(name, replicate?)` |
    | `Multiply` | [`Scribe.Big`](./big-numbers) | `Multiply(factor, replicate?) -> BigValue` |
    | `Divide` | [`Scribe.Big`](./big-numbers) | `Divide(factor, replicate?) -> BigValue` |

    Each errors with a message naming the field when called on the wrong kind, so `data.Coins.Add("x")` tells you `Coins` is not a `Scribe.SetOf` field rather than doing something surprising.

??? note "Reordering flag members later is safe"
    The value is stored as the enabled member **names**, in declaration order, so reordering or removing members in a later release does not corrupt anyone's data. Only the wire packing is positional, and both ends of a replication frame always come from the same build.

    The cap is 32 members, refused when the template compiles rather than by silently dropping the 33rd.

## Reacting to a container

Four events cover a container, and they answer different questions.

| Event | Arguments | Answers |
| --- | --- | --- |
| `Changed` | `(new, old)` | something beneath this changed, here is the current state |
| `OnChildChanged` | `(key, new, old)` | this direct child moved, here are both sides |
| `OnKeyAdded` / `OnKeyRemoved` | `(key, element)` | a key appeared or disappeared |
| `OnInsert` / `OnRemove` | `(element, index)` | an array entry was added or dropped |

```lua
data.Inventory.Changed(function(inventory)
    redrawTotals(inventory)          -- once per batch, however many slots moved
end)

data.Inventory.OnChildChanged(function(itemId, new, old)
    refreshSlot(itemId, new)         -- once per write
end)

data.Inventory.OnKeyAdded(function(itemId, entry)
    playPickupSound(itemId, entry.Rarity)
end)

data.Inventory.OnKeyRemoved(function(itemId, entry)
    clearSlot(itemId)
end)
```

`Changed` is coalesced, so a [`Data.Batch`](/api/Server#Batch) writing four entries fires it once, and on the client one replication frame fires it once however many children it carried. `OnChildChanged` is never coalesced: three writes fire it three times, and every ancestor receives its own immediate child.

All of a container's `OnChildChanged` fires arrive before its `Changed`, so you can accumulate keys and act once at the end. `OnKeyAdded` and `OnKeyRemoved` report a key appearing or disappearing and never one changing, so `OnChildChanged` is the only way to learn that an existing entry's value moved.

??? note "Why `old` is often the same table as `new`"
    Scribe does not snapshot a container, so for writes **beneath** the container `Changed` hands you the same reference twice.

    A write that replaces the container's own table is different. A whole-container `Set` or `Update`, and `SetOf` `Add` and `Remove`, and `Flags` `Enable`, `Disable` and `Toggle`, all rewrite the whole value, so they carry a real prior table as `old` and are not coalesced. Collapsing those would throw the prior value away.

    The same rule applies to `OnChildChanged`: `old` is a real prior value when the child is a leaf, and the same reference as `new` when the child is itself a container.

:::caution The container `key` argument was removed in 1.3.0
A container `Changed` listener used to take a third `key` argument. One fire can now cover several children, so naming one of them would imply the others did not change. Scribe errors at connect time on a container listener that declares a third parameter, rather than passing `nil` forever. Move that logic to `OnChildChanged`. Leaf listeners are unchanged.
:::

## Element rules

**Records are closed.** A field the shape does not declare is a write error, so `data.Inventory.Emberblade.Colour.Set("red")` fails loudly instead of persisting forever.

**Omitted fields fill from their defaults.** `data.Inventory.Torch.Set({ Rarity = "Common" })` stores the declared `Qty` default too. The *typed* surface still asks for every field, though, so in strict Luau either pass the whole element or mark the ones that may be absent:

```lua
Inventory = Scribe.DictOf({
    Qty    = Scribe.Int(1, { Min = 1, Max = 999 }),
    Rarity = Scribe.Enum("Common", RARITIES),
    Note   = Scribe.Optional(Scribe.String("", { MaxLength = 64 })),
}, { MaxKeys = 200 }),
```

An optional field has no default at all. It is never seeded and never filled, and it reads `nil` until something writes it.

**Caps reject by default.** `MaxItems`, `MaxKeys` and `MaxKeyLength` turn unbounded growth into an error naming the field. The one opt-in is `Evict` on an `ArrayOf`.

Only **growth** past a cap is refused. A whole-container `Set` that leaves the count where it already was, or lowers it, is allowed even when that count is over cap, so a container a newer-template server stored above the limit stays writable on an older one through a rolling deploy. `opts` itself is closed too: `Scribe.ArrayOf` takes `MaxItems` and `Evict` and nothing else, and an unknown key errors at declaration rather than leaving the container silently uncapped.

**Searching compares by value.** `Has`, `Find` and `RemoveValue` match declared elements structurally, so the value `Get()` handed you finds the stored one:

```lua
local run = data.RecentRuns.Get()[2]
data.RecentRuns.RemoveValue(run)  -- removes index 2
```

**Remove entries with `Remove`.** `data.RecentRuns[2].Set(nil)` is refused except on the last entry, since a hole would split `#array` from `Count()`.

**Method names are reserved.** An element field named `Count`, `Get`, `Set`, `Insert` and so on is shadowed by the accessor method and unreachable through the typed API. Scribe logs `API_NAME_COLLISION` naming it.

## Untyped containers

Keep a plain `{}` field when you genuinely want a free-form blob:

```lua
Scratch = {} :: { [string]: any },  -- free-form map, written by key
Blobs   = {} :: { any },            -- free-form list, written with Insert
```

You give up type checking, bounds, and [datatype packing](./datatypes) on the entries. Packing is schema-driven, so an element schema is what lets a datatype live in a container at all. Without one, Scribe could not tell a packed `CFrame` from a buffer you stored yourself.

Putting a declarator inside a plain array literal is a template error for the same reason, and the error names the fix.

??? note "Two write rules that apply to every array"
    Both were tightened in v1.0.10 and hold for typed and untyped arrays alike.

    `Insert(nil)` is an error, as is a non-integer position. Inserting `nil` at a middle position used to shift the entries above it and leave a hole.

    A table that mixes array indices with string keys is rejected at the write site. One could never have been saved, because the DataStore's JSON encoder fails on it, so this used to surface as a lost profile save long after the write that caused it.

## Where to next

- [Declaring Your Template](./templates) covers the scalar declarators that go inside an element shape.
- [Replication & Visibility](./visibility) shows how to keep one element field server-side.
- [Big Numbers](./big-numbers) documents `Multiply` and `Divide`, and the value object they hand back.
- [Roblox Datatypes](./datatypes) explains why an element schema is what lets a `CFrame` live in a container.
- [Diagnostics](./diagnostics) is where a container growing past what a profile can save shows up first.
