# Replication & Visibility

Every field in your template answers two questions: does it get saved, and who gets to see it. By default the answer is "yes, and its owner". You change that by wrapping a root field.

This is the guide to reach for when a value must stay on the server, or when other players need to read it.

## The four kinds of root

Here is Emberfall with three roots added to the canonical template, one for each wrapper:

```lua
local template = {
    Coins = Scribe.Int(0, { Min = 0 }),                        -- saved, the owner sees it
    Gems  = Scribe.Int(0, { Min = 0 }),

    Nameplate = Scribe.Shared({                                -- saved, everyone sees it
        Title = Scribe.String("Wanderer", { MaxLength = 24 }),
    }),

    AntiCheat = Scribe.ServerOnly({                            -- saved, nobody sees it
        Strikes = Scribe.Int(0, { Min = 0 }),
    }),

    Combat = Scribe.Session({ InCombat = false }),             -- not saved, the owner sees it
}
```

| Wrapper | Persists? | Replicates to | Use for |
| --- | --- | --- | --- |
| *(none)* | yes | the owner | most player data |
| [`Scribe.ServerOnly(v)`](/api/Scribe#ServerOnly) | yes | nobody | secrets, anti-cheat state |
| [`Scribe.Shared(v)`](/api/Scribe#Shared) | yes | **every** client | public info such as a title |
| [`Scribe.Session(v)`](/api/Scribe#Session) | no | the owner | runtime-only state |

`AntiCheat` is absent from the client's accessor type, so reading it there is a type error rather than a `nil` at runtime. `Combat` resets to `false` on every rejoin, because nothing about it was ever written to storage.

## Combining wrappers

Saving and replication are independent questions, so one wrapper from each axis combines freely:

| Axis | Wrappers |
| --- | --- |
| Does it save? | `Scribe.Session` (no), nothing (yes) |
| Who receives it? | `Scribe.ServerOnly` (nobody), `Scribe.Shared` (everyone), nothing (the owner) |

```lua
Aggro   = Scribe.ServerOnly(Scribe.Session({ ThreatLevel = 0 })),   -- runtime, server-side only
Emote   = Scribe.Shared(Scribe.Session({ Playing = "" })),          -- runtime, everyone sees it
```

Order does not matter, so `Scribe.Session(Scribe.ServerOnly(x))` is the same field.

Two wrappers from the **same** axis are a startup error naming both, because a field cannot have two answers to one question:

```lua
Nameplate = Scribe.Shared(Scribe.ServerOnly({ Title = "" })),  -- error: to everyone, and to nobody?
Combat    = Scribe.Session(Scribe.Session({ InCombat = false })),  -- error: already applied
```

`Shared` and `Session` are **root-only**. `ServerOnly` may also wrap a nested field, keeping just that subtree on the server while its siblings replicate.

## Wrapping a declarator

A wrapper goes **outside** the declarator, and every declarator is fair game:

```lua
Suspicion = Scribe.ServerOnly(Scribe.Int(0, { Min = 0, Max = 100 })),           -- a bounded int
Badges    = Scribe.Shared(Scribe.SetOf(Scribe.String("", { MaxLength = 32 }))), -- a set
Loadout   = Scribe.Session(Scribe.Flags({ "Torch", "Sprinting" })),             -- named booleans
Stash     = Scribe.ServerOnly(Scribe.DictOf({                                   -- a whole container
    Qty    = Scribe.Int(1, { Min = 1, Max = 999 }),
    Rarity = Scribe.Enum("Common", RARITIES),
}, { MaxKeys = 200 })),
```

None of those four is in the base template. They are the visibility slice, and each one is wrapped the way its meaning demands: a suspicion score is nobody's business, a badge is everybody's, a loadout dies with the session, and a stash is the server's bookkeeping. Emberfall's own `Settings` and `Inventory` stay unwrapped, because a player's audio preference has to survive a rejoin and the client has to render the bag.

Visibility is the only thing the wrapper changes. The field keeps its whole accessor surface underneath: `Add` and `Has` on a [set](./containers#sets-of-unique-values), `Enable` and `Toggle` on [flags](./containers#named-booleans), `MaxKeys` and `OnKeyAdded` on a [dictionary](./containers).

## Server-only fields inside a container

A field of an [`ArrayOf`, `DictOf` or `MapOf`](./containers) element shape may be `ServerOnly`, and it is stripped from every entry the same way a static field is: from a direct write, from a whole-container `Set` diff, from an `Insert` op, from the join snapshot, and from a `Shared` root's broadcast to other players.

```lua
Inventory = Scribe.DictOf({
    Qty      = Scribe.Int(1, { Min = 1, Max = 999 }),
    Rarity   = Scribe.Enum("Common", RARITIES),
    RollSeed = Scribe.ServerOnly(Scribe.Int(0)),  -- never leaves the server
}, { MaxKeys = 200 }),
```

`Shared` and `Session` stay root-only, so they are rejected inside an element shape when the template compiles, for `ArrayOf`, `DictOf`, `MapOf` and `SetOf` alike.

??? warning "`SetOf` is the exception"
    A [`Scribe.SetOf`](./containers#sets-of-unique-values) element is a single scalar declarator rather than a record, so there are no per-field wrappers to put inside it. `Scribe.SetOf(Scribe.ServerOnly(...))` does compile, but it then strips **every** member on the way out and clients see an empty set.

    Wrap the field itself instead:

    ```lua
    Sanctions = Scribe.ServerOnly(Scribe.SetOf(Scribe.String(""))),  -- not SetOf(ServerOnly(...))
    ```

## Reading another player's shared data

`Scribe.Shared` roots stream to everyone. Read them on the client with [`GetShared`](/api/Client#GetShared), which accepts a `Player` or a `userId`:

```lua
local shared = Data.GetShared(ben)
if shared then
    nameLabel.Text = shared.Nameplate.Title
end

-- Fires (userId, shared) when anyone's shared data changes. `shared` is nil once they leave.
Data.OnSharedChanged:Connect(function(userId, shared)
    if shared then
        updateNameTag(userId, shared.Nameplate.Title)
    end
end)
```

Both hand you every `Shared` root keyed by its template name, so index through the root (`shared.Nameplate`) rather than straight at the field.

`OnSharedChanged` gives you a `userId` rather than a `Player` on purpose. The owner may have already left, and a departed player has no `Player` object, which is exactly when the `nil` update fires. The id is the stable key, and `GetShared` accepts it directly, so the two compose.

!!! warning "`GetShared` never returns your own data"
    The server broadcasts a player's `Shared` roots to every client **except** that player's own, at join and on every diff. So on Ava's client `Data.GetShared(Players.LocalPlayer)` is always `nil`, and `OnSharedChanged` never fires with Ava's own userId. A nameplate loop over `Players:GetPlayers()` silently skips one player, with no error and no log.

    Ava still sees her own `Shared` roots through the **ordinary accessor** (`Data.Nameplate.Title`), which stays live like any other field. The two read paths are separate, so handle the local player on the accessor and everyone else on `GetShared`:

    ```lua
    local function titleFor(player: Player): string?
        if player == Players.LocalPlayer then
            return Data.Nameplate.Title.Get()  -- your own Shared root
        end
        local shared = Data.GetShared(player)
        return if shared then shared.Nameplate.Title else nil
    end
    ```

## What a Session root costs

`Session` means "not saved". It does not mean "not sent". A `Session` root rides in the **join snapshot** and is replicated to its owner on every join, exactly like a persisted root. The only difference is which store it came from.

That has one consequence no number will otherwise tell you, so cap your session containers the same way you cap any other:

```lua
Threat = Scribe.Session(Scribe.DictOf(Scribe.Int(0), { MaxKeys = 200 })),
```

A wrapper goes outside a declarator, so this is legal, and it turns unbounded growth into a write error naming the field, in your own test session, at the line that caused it.

??? note "Why ProfileSize will not warn you"
    [`ProfileSize`](./diagnostics) and the roughly 4 MB DataStore ceiling both measure what gets **saved**, so `Session` data is absent from both by construction.

    Measured on a template of `{ Coins, Cache = Scribe.Session({}) }` holding 8,000 cache keys: the join snapshot was **286,946 bytes** while `ProfileSize` reported **158 bytes**. Nothing is broken there. The snapshot is fragmented and delivered correctly. But every join pays for it, and only `JoinBytes` counts it.

    The bare `Scribe.Session({})` spelling has no cap, which is true of any untyped dictionary and is not special to `Session`.

??? note "Session, Dynamic and derived fields"
    `Scribe.Session` cannot wrap a [`Scribe.Dynamic`](./templates) field, and that is a startup error. Session data is rebuilt from its default every session, so a one-time per-profile seed has nowhere to live. Generate per-session values in [`OnPlayerInit`](./lifecycle#onplayerinit) instead.

    A [derived field](./derived) sits on these same axes and adds one rule of its own. Because your shared module runs on both realms, a derived value whose inputs are all visible to its audience is **computed** by each realm rather than sent, and only a field reading something its audience cannot see crosses the wire. Wrap it in `ServerOnly` or `Shared` exactly as you would any other root.

## How replication works

Scribe derives an identical schema on the server and the client from your shared template, then streams schema-compressed batched diffs over a pluggable transport. Writes coalesce per frame on a `PostSimulation` flush and only send when something actually changed, so there is no idle traffic. The client applies each diff to a local mirror, which is why reads are instant and `Observe` and `Changed` fire locally.

You never wire up a RemoteEvent. The `"Default"` transport uses two RemoteEvents under a folder in `ReplicatedStorage` and is all most games ever need. If you already run your own networking layer, you can route Scribe's traffic through it. See [Custom Transports](./transports).

??? note "The client converges to the current value, not an event log"
    When a client finishes its handshake it receives a **snapshot** of the current data, then live diffs from there. It never replays writes made before it synced. Set `Coins` to 5 and then to 10 while the client is still handshaking, and the client's first value is 10, never 5.

    `Data.WaitForData(player)` on the **server** waits for that player's profile to load server-side, not for the client's handshake, so writes made right after it returns can reach the client only as their final value. To act on a client being ready to receive, drive it from the client: a first `Observe` fire, or a [`Data.Request`](/api/Client#Request) the client sends once it has loaded.

    The client always ends at the correct current value. To have it observe a *sequence* of values, produce those changes after the client is synced and space them across frames, since same-frame writes to one field coalesce to the latest. For UI, read the value passed to `Observe` rather than counting fires.

!!! warning "Client writes are optimistic"
    `data.Coins.Set(5)` on the client updates the local mirror only. That is fine for snappy UI, but the server's value always wins on the next diff. Authoritative changes go through [`Data.Request`](/api/Client#Request) to a server [`Command`](/api/Server#Command). See [Commands & Requests](./commands).

## Where to next

- [Commands & Requests](./commands) is how a client asks the server to change something it can only read.
- [The Server Store](./server-store) replicates state that belongs to the server rather than to a player.
- [Derived Fields](./derived) shows how visibility decides whether a computed value is sent or recomputed.
- [Containers](./containers) covers the caps that keep a `Session` root from growing without limit.
- [Security](./security) explains what a `ServerOnly` field does and does not protect.
- [Custom Transports](./transports) routes Scribe's diffs through your own networking layer.
