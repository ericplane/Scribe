# Roblox Datatypes

A `Vector3` or a `CFrame` cannot be handed to a DataStore as it is. The usual workaround is to split it into three or twelve numbers and reassemble it on the way back. Scribe does that for you, and does it in far fewer bytes than a table of numbers would take.

Declare the field with the datatype's own declarator and your code only ever sees the real datatype.

## A checkpoint in Emberfall

Emberfall remembers where you last rested. Add two fields to the template:

```lua
Checkpoint = Scribe.Vector3(Vector3.zero),
HomePortal = Scribe.CFrame(CFrame.identity),
```

They read and write like any other field:

```lua
local data = Data.WaitForData(player)

data.Checkpoint.Set(character.PrimaryPart.Position)

local spot = data.Checkpoint.Get()   -- a real Vector3, unpacked for you
character:PivotTo(CFrame.new(spot))

data.Checkpoint.Observe(function(position)
    respawnMarker.Position = position
end)
```

Under the hood the value is stored and replicated as a compact packed buffer. You never see the buffer, and you never write the packing code.

## The seventeen declarators

`Vector3`, `Vector2`, `Vector3int16`, `Vector2int16`, `CFrame`, `Color3`, `BrickColor`, `UDim`, `UDim2`, `Rect`, `NumberRange`, `NumberSequence`, `ColorSequence`, `DateTime`, `EnumItem`, `Font`, `PhysicalProperties`.

Each takes a default of its own type, so `Scribe.Color3(Color3.fromRGB(255, 120, 0))` is a colour field starting at Emberfall orange. `Scribe.CFrame` is the only one that takes a second argument, covered below.

A `buffer` is also a first-class template field, which is what you want for a large placed-structure or inventory blob you serialize yourself.

## Full-precision CFrames

A `CFrame` field packs its rotation cheaply, and cheap means lossy. If the orientation is decoration, such as a piece of furniture or a door, that is the right trade and you should keep it. If the orientation is *data* you compare, accumulate or replay, opt into the exact form:

```lua
HomePortal = Scribe.CFrame(CFrame.identity),                          -- 13 or 29 bytes
AimVector  = Scribe.CFrame(CFrame.identity, { Precision = "exact" }), -- 49 bytes, lossless
```

| Declaration | Bytes | Rotation fidelity |
| --- | --- | --- |
| omitted, axis-aligned | 13 | exact if the axes are square, **snapped** if within `1e-4` of square |
| omitted, any other rotation | 29 | quaternion, components return off by roughly `1e-7` |
| `Precision = "exact"` | 49, always | every component bit for bit |

??? note "What the extra 20 bytes buy"
    The default stores an arbitrary rotation as a quaternion, four numbers standing in for the rotation matrix's nine, and rebuilds the nine when you read it. That re-derivation is lossy, so a `CFrame` written and read back comes out slightly turned, and the error compounds if you keep feeding the result back in. Roblox stores `CFrame` components as `f32`, so writing all twelve as `f32` is the identity: the exact form does not merely reduce the error, it removes it.

    It also removes a sharper loss. The 13-byte path treats an axis within `1e-4` of a unit axis *as* that axis and rebuilds it exactly, so a rotation a twentieth of a degree off square silently becomes square. That is three orders of magnitude worse than the quaternion error, on the path that looks cheapest. An `"exact"` field never takes it.

    The cost is flat on purpose. An `"exact"` field is 49 bytes for every value, including the axis-aligned ones the default would have packed into 13. The cheap path is exactly the path that snaps, and a width that moved with the runtime rotation would not be a cost you could budget.

`Precision` is the same knob [`Scribe.Number`](./templates#narrowing-a-float) uses and it means the same thing: the precision the field is stored and sent at. It points the other way here only because a `CFrame`'s default is the lossy form while a `Number`'s default is the exact one. `"exact"` is its only value on a `CFrame`, and declaring it on any other datatype is refused when the template compiles.

Adding it to a live field is safe. Every buffer already written keeps decoding, because the exact form uses a tag and a length no older buffer can have.

## Datatypes inside a container

Packing is schema-driven, so an element shape is what lets a datatype live in a [container](./containers) at all. Declare the shape and every entry packs:

```lua
Placed = Scribe.ArrayOf({
    Cf     = Scribe.CFrame(CFrame.identity),
    ItemId = Scribe.String("", { MaxLength = 64 }),
}, { MaxItems = 200 }),

data.Placed.Insert({ Cf = CFrame.new(0, 5, 0), ItemId = "EmberLantern" })
local cf = data.Placed[1].Cf.Get()   -- a real CFrame
```

Without an element schema Scribe could not tell a packed `CFrame` from a buffer you stored yourself, so an untyped `{}` container cannot pack for you.

## Packing by hand

Three paths bypass the accessor and therefore bypass packing: [`OnPlayerInit`](./lifecycle#onplayerinit), a [migration step](./profiles#migrations), and [`Data.UpdateOffline`](/api/Server#UpdateOffline). All three hand you the **raw** profile table, and a raw assignment stores the userdata itself, which no DataStore can serialize.

`Scribe.Datatypes` is the escape hatch for those three:

```lua
OnPlayerInit = function(player, data, isNewProfile)
    data.Checkpoint = Vector3.new(0, 12, 0)                            -- PROFILE_UNPERSISTABLE
    data.Checkpoint = Scribe.Datatypes.Pack("Vector3", Vector3.new(0, 12, 0))  -- correct
end,
```

`Scribe.Datatypes.Unpack("Vector3", stored)` goes the other way, for reading one out of a raw table. Reads through the accessor are unaffected either way: `data.Checkpoint.Get()` still hands back a real `Vector3`.

!!! warning "An unpacked datatype in a raw write is silent until the save fails"
    Scribe scans raw-written data at load and reports anything unstorable as `PROFILE_UNPERSISTABLE`, so the problem does surface. It surfaces as a log line rather than an error at the line that caused it. Often the simpler fix is to store the plain numbers in ordinary fields and build the datatype where you use it.

??? note "Why a packed buffer instead of a table of numbers"
    A `Vector3` written as `{ X = 0, Y = 12, Z = 0 }` costs the three numbers plus three key strings, in JSON, every save and every replication frame. The packed form is a fixed-width buffer with no keys at all. On a template with a few hundred placed objects that is the difference between a profile that saves comfortably and one that creeps toward the roughly 4 MB ceiling.

    `Scribe.EnumItem` and `Scribe.Font` are the two worth calling out: both would otherwise be stored as strings you would have to look back up, and both come back as the real `EnumItem` or `Font` object.

## Where to next

- [Declaring Your Template](./templates) covers the scalar declarators and the `Precision` knob on `Scribe.Number`.
- [Containers](./containers) explains element shapes, which is what lets a datatype live in a list or a map.
- [Session Lifecycle](./lifecycle#onplayerinit) is the first place you will meet a raw profile table.
- [Offline Profiles](./profiles) is the other one, and it has the same packing rule.
