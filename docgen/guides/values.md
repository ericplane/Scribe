# Reading & Writing Values

Once a field is declared, you reach it by indexing into the player's accessor tree exactly the way you wrote the template. `data.Coins` is an **accessor**, and every read and write goes through a method on it. This page is the tour of those methods: which ones exist, which fields they apply to, and what they do that a plain table assignment would not.

## Get and Set

Two methods cover most of what you will ever write.

```lua
local data = Data.WaitForData(player)
if not data then return end

data.Coins.Get()              --> 0
data.Coins.Set(100)           --> 100, the stored value
data.Coins.Increment(50)      --> 150
data.Coins.Decrement(25)      --> 125

data.Inventory.Emberblade.Rarity.Set("Epic")
data.Stats.Deaths.Increment(1)
```

Every write is validated against the declarator before it lands, clamped if it is out of bounds, replicated to the owning client, and announced to any listener. `Set` returns the value that was actually stored, which is not always the value you passed: `data.Coins.Set(-10)` on a `{ Min = 0 }` field returns `0`.

That is the whole common case. Everything below is a method for a particular kind of field.

??? note "Keeping one write off the wire"
    Most mutators take a trailing `replicate` boolean. Pass `false` and the write happens on the server, persists as normal, and is simply not sent to the client:

    ```lua
    data.Stats.Playtime.Increment(60, false)
    ```

    Reach for it on a field that changes very often and that no UI reads. If the client should *never* see a field, declare it [`Scribe.ServerOnly`](./visibility) instead, which is a statement about the field rather than about one write.

    On [`Increment`](/api/Value#Increment) and [`Decrement`](/api/Value#Decrement) the second argument is normally an economy tag table, so `false` in that slot is the way to say "server-only" there.

## Reacting to a change

`Observe` calls you immediately with the current value and again on every change. `Changed` skips that first call. Both return a function that disconnects the listener.

```lua
-- client
local stop = Data.Coins.Observe(function(coins)
    coinsLabel.Text = tostring(coins)
end)

Data.Level.Changed(function(new, old)
    if new > old then
        playLevelUpEffect(new)
    end
end)
```

`Observe` is what you want for UI, because it removes the "what do I show before the first value arrives" question. `Changed` is what you want when only the transition matters.

## Read, modify, write

`Update` reads the current value, hands it to your function, and stores whatever you return. It saves you the read and keeps the two halves next to each other.

```lua
-- Round Emberfall's coin balance down to the nearest ten.
data.Coins.Update(function(current)
    return current - (current % 10)
end)
```

`Clone` gives you a deep copy you may freely mutate, and `Default` gives you the field's declared default without touching the stored value at all.

```lua
local snapshot = data.Inventory.Clone()   -- yours to edit; nothing is written back
table.clear(snapshot)

data.Settings.Set(data.Settings.Default())  -- reset settings to the template default
```

`Default` is read-only schema metadata, so it works on the client, on the server, and before any data has loaded. That makes it the right way to build a "reset to defaults" button, and the right way to tell whether a player has ever changed something.

!!! warning "`Get` on a table hands you the stored table"
    For a **table** field, `Get` returns the stored table itself, not a copy. Mutating it writes straight into authoritative state behind Scribe's back: no validation, no replication, and no `Changed`. The value changes on the server and even saves, and the client never hears about it.

    ```lua
    -- WRONG: edits real state silently, and never replicates
    for itemId, entry in data.Inventory.Get() do
        entry.Rarity = "Legendary"
    end

    -- RIGHT: write through the accessor at that key
    for itemId in data.Inventory.Get() do
        data.Inventory[itemId].Rarity.Set("Legendary")
    end
    ```

    `data.Inventory[itemId]` is a real accessor, so `.Set` validates, replicates, and fires listeners like any other write. The entry `Get` handed you is a plain Lua table with no `.Set` of its own.

    The same trap sits inside `Update`, which passes your function exactly what `Get` returns. Mutating that table in place is a silent write, and worse, a transform that throws partway leaves the mutation in the profile with nothing reporting it. Build a new table and return that:

    ```lua
    data.Inventory.Update(function(current)
        local updated = table.clone(current)
        updated.Emberblade = { Qty = 1, Rarity = "Legendary" }
        return updated
    end)
    ```

    Use `Clone` whenever you want a table you can edit freely.

??? note "Why the rule is blanket rather than conditional"
    A subtree that contains packed datatypes **is** rebuilt on the way out, so mutating that one is silently discarded rather than silently applied. Two different silent failures depending on the shape of your template is worse than one rule, so treat everything `Get` returns as read-only.

    One container is not yours and does not hand back the stored table. Scribe's own `_Scribe` root, holding the receipt-dedupe ring, perks, gift credits, pending gifts, purchase logs, timers and the schema version, refuses every write from game code, and a read of it returns a detached deep copy so that refusal cannot be walked around. `Get` is not a write, so `data._Scribe.ProcessedPurchaseIds.Get()` followed by `table.clear` would otherwise empty the dedupe ring and make the next receipt Roblox retries grant a second time on one payment. Read that state with [`Data.Owns`](/api/Server#Owns), [`Data.GetGiftCredits`](/api/Server#GetGiftCredits) and [`Data.GetPurchases`](/api/Server#GetPurchases). Your own containers are unaffected.

    The refusal is by **caller**, not by object. Scribe writes those same paths through its own privileged handle, so the library is never blocked by its own guard, and there is no object you can hold that lets game code past it. Change that state through the APIs that own it: [`Data.GrantPerk`](/api/Server#GrantPerk), [`Data.RevokePerk`](/api/Server#RevokePerk), [`Data.Purchase`](/api/Server#Purchase) and [`Data.PromptGift`](/api/Server#PromptGift).

### The whole-tree read is frozen

`Data.Get(player).Get()`, with no field in front of the final call, is the one read that does not hand back the store. It returns a **frozen** table of exactly the roots your template declares, so the mistake above fails loudly there:

```lua
local whole = Data.Get(player).Get()
whole.Coins = 999             --> error: attempt to modify a readonly table
Data.Get(player).Coins.Set(999) -- the spelling that validates and replicates
```

Scribe's internal `_Scribe` root is not in that table, and neither is `_ScribeSession` on the client, which is what the accessor type has always promised. [`Scribe.Session`](./visibility) roots are present on the server, where the type promised them and the runtime used to leave them out.

The freeze is shallow. Nested containers reached through it are still the live tables described above. `Clone` returns the same shape unfrozen, and [`Data.Export`](/api/Server#Export) is the full profile dump including Scribe's internals.

## Numbers

| Method | What it does |
| --- | --- |
| [`Increment(amount, meta?)`](/api/Value#Increment) | Adds and returns the new value. |
| [`Decrement(amount, meta?)`](/api/Value#Decrement) | Subtracts and returns the new value. |
| [`Min()`](/api/Value#Min) | The declared minimum, or `nil` if unbounded. |
| [`Max()`](/api/Value#Max) | The declared maximum, or `nil` if unbounded. |

`Min` and `Max` are read-only schema metadata, so they work on the client and before data loads. Drive a slider or a progress bar off them and the bound lives in exactly one place:

```lua
levelBar.Size = UDim2.fromScale(Data.Level.Get() / Data.Level.Max(), 1)
```

The optional second argument to `Increment` and `Decrement` is an economy tag table. Pass one and Scribe emits a Roblox economy event for the write, with this field's name as the currency:

```lua
data.Coins.Increment(500, {
    TransactionType = Enum.AnalyticsEconomyTransactionType.IAP,
    ItemSku = "CoinPack500",
})
```

[Economy Analytics](./economy) covers the tag table in full.

## Booleans

A plain boolean field has [`Toggle()`](/api/Value#Toggle), which flips it and returns the new value.

Emberfall keeps its three settings in a `Scribe.Flags` field instead, because they belong together. A flags field is addressed **by member name**, and the whole set is one write and one `Changed`:

```lua
Settings = Scribe.Flags({ "Music", "Sfx", "TutorialDone" }),
```

```lua
data.Settings.Enable("Music")
data.Settings.Has("Music")          --> true
data.Settings.Toggle("Sfx")         --> true, the new state
data.Settings.Disable("Music")
data.Settings.Get()                 --> { "Sfx" }
data.Settings.Clear()               -- every flag off
```

`Enable` and `Disable` return nothing. Enabling a name that is not a declared member is an error rather than a silent no-op, and setting a flag to the state it already holds writes nothing at all: no replication, no `Changed`.

??? note "Flags start off, and there is no way to declare otherwise"
    A `Scribe.Flags` field's default is the empty set, so every member of Emberfall's `Settings` starts disabled, including `Music` and `Sfx`. There is no per-member default.

    If your game should start with some of them on, enable them in [`OnPlayerInit`](./lifecycle), which runs before the player can read anything. That hook receives the raw profile table rather than the accessor tree, and a flags field is stored as the list of enabled member names, so the assignment is `rawData.Settings = { "Music", "Sfx" }`.

??? note "Flags against three sibling booleans"
    Three separate boolean fields would be three writes, three `Changed` fires, and three chances to write a field name the template never declared. A flags field is one write, one `Changed`, and a compile-time list of the legal names, and it packs to a bitmask on the wire.

    The value is stored as the enabled member **names**, in declaration order, so reordering or removing members in a later release is safe. Only the wire packing is positional, and both ends of a replication frame always come from the same build. The cap is 32 members, refused at compile time rather than by silently dropping the 33rd.

## Sets

A `Scribe.SetOf` field holds unique scalars and answers "is this in here". Say Emberfall tracks which regions a player has unlocked:

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

`Add` on a value already present, and `Remove` on one that is absent, both return `false` and do nothing at all: no write, no replication, no `Changed`. That return value is the cheap way to answer "was this the first time", which is exactly what a discovery reward needs:

```lua
if data.Unlocked.Add(regionId) then
    data.Xp.Increment(250)
end
```

There is no `Insert` and no index-based `Remove`, because a set has no positions. [Containers](./containers) covers the declarator side, including why the element has to be a scalar.

## Big numbers

A `Scribe.Big` field carries a value far past the point a Luau number stops being exact. Suppose Emberfall's prestige mode adds one:

```lua
Essence = Scribe.Big(0, { Min = 0 }),
```

On top of `Set`, `Increment` and `Decrement`, a big field gets two methods no other field has. Both take a plain number, a numeric string, or another big value, and both return the new stored value:

```lua
data.Essence.Set("1.5e100")
data.Essence.Multiply(1.15)   -- 1.725e100, a prestige bonus
data.Essence.Divide(2)        -- 8.625e99, halved on a prestige reset
```

`Multiply` and `Divide` go through the ordinary write path, so bounds, replication and economy events all apply exactly as they do to `Increment`. Dividing by zero is an error naming the field rather than a value nothing can interpret.

Reading a big field back gives you an object rather than a number. [`BigValue`](/api/BigValue) is the reference page for it, covering `Short`, `ToNumber`, `Pow` and `Log10`, and why `Get() < 2000` throws.

??? note "Why these two exist at all"
    A big value is an object, not a number, so `data.Essence.Set(data.Essence.Get() * 1.15)` is a read, an arithmetic operation, and a write, and the arithmetic is the only part you actually meant. `Multiply` collapses the three, and more importantly it keeps the operation on the same write path as everything else, so a `Min` or `Max` clamp reports one anomaly rather than none.

    [Big Numbers](./big-numbers) covers the value object itself: `Short`, `ToNumber`, `Pow`, `Log10`, and why a comparison needs a big on both sides.

## Containers

Three listeners answer three different questions about a container.

| Listener | Question it answers | Callback |
| --- | --- | --- |
| [`Changed`](/api/Value#Changed) | Something under here changed. What does it look like now? | `(new, old)` |
| [`OnChildChanged`](/api/Value#OnChildChanged) | Which direct child moved, and from what to what? | `(key, new, old)` |
| [`OnKeyAdded`](/api/Value#OnKeyAdded) and [`OnKeyRemoved`](/api/Value#OnKeyRemoved) | Did a key appear or disappear? | `(key, value)` |

```lua
data.Inventory.Changed(function(inventory)
    redrawTotalWeight(inventory)      -- once per batch, however many slots moved
end)

data.Inventory.OnChildChanged(function(itemId, new)
    refreshSlot(itemId, new)          -- once per write
end)

data.Inventory.OnKeyRemoved(function(itemId, lastValue)
    destroySlot(itemId)
    print(`{itemId} left the bag holding {lastValue.Qty}`)
end)
```

`Changed` on a container is **coalesced**: a [`Data.Batch`](/api/Server#Batch) writing four fields fires it once, and on the client one replication frame fires it once however many children it carried. `OnChildChanged` is never coalesced, so three writes fire it three times. All of a container's `OnChildChanged` fires arrive before its `Changed`, so you can accumulate keys and act once.

`OnKeyAdded` and `OnKeyRemoved` report a key appearing or disappearing, never one changing. To learn that an existing key's value moved, use `OnChildChanged`.

??? note "Why `old` is sometimes the same table as `new`"
    On a container, `Changed` reports state rather than a transition, and `old` is the same reference as `new`, because the fire happens after the write and Scribe does not snapshot a container's contents. The same caveat applies to `OnChildChanged` when the child is itself a container. When the child is a leaf, `old` is a real prior value.

    A write that **replaces** the container's own table is different: a whole-container `Set` or `Update`, and the set and flags mutators, which rewrite the whole value. Those carry a real prior table as `old` and are not coalesced, because collapsing them would throw that prior value away.

!!! warning "The container `key` argument was removed in 1.3.0"
    A container `Changed` listener used to take a third `key` argument. One fire can now cover several children, so naming one of them would imply the others did not change. Scribe errors at connect time on a container listener that declares a third parameter, rather than passing `nil` forever. Move that logic to `OnChildChanged`. Leaf listeners are unchanged.

## The whole surface at a glance

| Method | Applies to |
| --- | --- |
| `Get`, `Set`, `Update`, `Clone`, `Default`, `Observe`, `Changed` | every field |
| `Increment`, `Decrement`, `Min`, `Max` | numbers, including `Scribe.Big` |
| `Multiply`, `Divide` | `Scribe.Big` only |
| `Toggle` | booleans, and `Scribe.Flags` with a member name |
| `Enable`, `Disable`, `Has`, `Clear` | `Scribe.Flags` |
| `Add`, `Remove`, `Has`, `Count`, `Clear` | `Scribe.SetOf` |
| `Insert`, `Remove`, `RemoveValue`, `Find`, `Has`, `Count`, `Clear` | arrays and dictionaries |
| `OnInsert`, `OnRemove`, `OnKeyAdded`, `OnKeyRemoved`, `OnChildChanged` | containers |
| `SetTimed`, `ExtendTimed`, `Active` | `Scribe.Timed` |

Calling one on the wrong kind of field is an error naming the field and the method, not a silent no-op. A [derived field](./derived) has no mutators at all: they are absent from its type and they throw if you reach them anyway.

## Where to next

- [Declaring Your Template](./templates) is the other half: how a field comes to exist in the first place.
- [Containers](./containers) covers arrays, dictionaries, maps and sets as declarators.
- [Big Numbers](./big-numbers) covers the big value object and its arithmetic, and [`BigValue`](/api/BigValue) is its reference page.
- [Replication and Visibility](./visibility) explains who receives a write and when.
- [Economy Analytics](./economy) covers the tag table on `Increment` and `Decrement`.
