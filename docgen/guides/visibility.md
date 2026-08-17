# Replication & Visibility

By default, a field persists and replicates to its **owner**, the player it belongs to. Wrap a root field to change that.

| Wrapper | Persists? | Replicates to | Use for |
| --- | --- | --- | --- |
| *(default)* | ✅ | the owner | most player data |
| [`Scribe.ServerOnly(v)`](/api/Scribe#ServerOnly) | ✅ | nobody | secrets, anti-cheat state |
| [`Scribe.Shared(v)`](/api/Scribe#Shared) | ✅ | **every** client | public info (name, team) |
| [`Scribe.Session(v)`](/api/Scribe#Session) | ❌ | the owner | runtime-only state |

`Scribe.Session` cannot wrap a `Scribe.Dynamic` field (a startup error): Session data is rebuilt from its default every session, so a one-time seed has nowhere to live. Generate per-session values in [`OnPlayerInit`](./lifecycle) instead.

```lua
local template = {
    Coins   = 0,                                 -- persists, owner sees it
    Secret  = Scribe.ServerOnly({ Flagged = false }), -- never leaves the server
    Public  = Scribe.Shared({ DisplayName = "" }),    -- everyone sees it
    Runtime = Scribe.Session({ InCombat = false }),   -- resets on rejoin
}
```

`Shared` and `Session` are **root-only** wrappers. `ServerOnly` may also wrap a nested field to keep just that subtree server-side while its siblings replicate.

A [derived field](./derived) sits on the same axes and adds one rule of its own: since your template module runs on both realms, a value whose inputs are all visible to its audience is **computed** by each realm rather than sent, and only a field reading something its audience cannot see crosses the wire. Wrap it in `ServerOnly` or `Shared` exactly as you would any other field.

### Combining wrappers

Saving and replication are **independent**, so one wrapper from each axis combines:

| Axis | Wrappers |
| --- | --- |
| Does it save? | `Scribe.Session` (no), nothing (yes) |
| Who receives it? | `Scribe.ServerOnly` (nobody), `Scribe.Shared` (everyone), nothing (the owner) |

```lua
Strikes = Scribe.ServerOnly(Scribe.Session({ Count = 0 })),  -- runtime, server-side only
Status  = Scribe.Shared(Scribe.Session({ Stunned = false })), -- runtime, everyone sees it
```

Order does not matter, so `Scribe.Session(Scribe.ServerOnly(x))` is the same field.

Two wrappers from the **same** axis are a startup error naming both, since a field cannot have two answers to one question:

```lua
Bad = Scribe.Shared(Scribe.ServerOnly({ A = 1 })),  -- error: broadcast to everyone, and to nobody?
Bad = Scribe.Session(Scribe.Session({ A = 1 })),    -- error: already applied
```

### Wrapping a declarator

A wrapper goes **outside** the declarator, and every declarator is fair game, including the v1.3.0 ones: [`Scribe.Big`](./templates#big-numbers), [`Scribe.Flags`](./templates#sets-of-named-booleans), [`Scribe.SetOf`](./templates#sets-of-unique-values), [`Scribe.MapOf`](./templates#maps-with-typed-keys), and the [typed containers](./templates#typed-containers).

```lua
Wealth   = Scribe.ServerOnly(Scribe.Big(0, { Min = 0 })),
Unlocked = Scribe.Shared(Scribe.SetOf(Scribe.String("", { MaxLength = 32 }))),
Runtime  = Scribe.Session(Scribe.Flags({ "InCombat", "Afk" })),
Owned    = Scribe.ServerOnly(Scribe.MapOf("integer", Scribe.Int(0))),
```

Visibility is the only thing the wrapper changes. The field keeps its full accessor surface underneath: `Add`/`Has`/`Remove` on a set, `Enable`/`Toggle` on flags, big arithmetic on a `Scribe.Big`.

### Inside a typed container

A field of a [`Scribe.ArrayOf`, `Scribe.DictOf`, or `Scribe.MapOf`](./templates#typed-containers) element shape may be `ServerOnly`, and it is stripped from every entry exactly as a static field is: from a direct write, from a whole-container `Set` diff, from an `Insert` op, from the join snapshot, and from a `Shared` root's broadcast to other players.

```lua
Plots = Scribe.ArrayOf({
    Name = Scribe.String("", { MaxLength = 32 }),
    Seed = Scribe.ServerOnly(Scribe.Int(0)),  -- never leaves the server
}),

Friends = Scribe.MapOf("integer", {
    Name  = Scribe.String("", { MaxLength = 32 }),
    Score = Scribe.ServerOnly(Scribe.Int(0)),  -- same rule, typed keys
}),
```

`Shared` and `Session` stay root-only, so they are rejected inside an element shape at compile time: `ArrayOf`, `DictOf`, `MapOf`, and `SetOf` alike.

`Scribe.SetOf` is the exception to the `ServerOnly` rule, because its element is a single scalar declarator rather than a record, so there are no per-field wrappers to put inside it. `Scribe.SetOf(Scribe.ServerOnly(...))` does compile, but it then strips **every** member on the way out and clients see an empty set. Wrap the field itself instead:

```lua
Unlocked = Scribe.ServerOnly(Scribe.SetOf(Scribe.String(""))),  -- not SetOf(ServerOnly(...))
```

## Reading another player's shared data

`Scribe.Shared` roots stream to everyone. Read them on the client with [`GetShared`](/api/Client#GetShared), which accepts a `Player` or a `userId`:

```lua
local shared = Data.GetShared(otherPlayer)
if shared then nameLabel.Text = shared.Public.DisplayName end

-- Fires (userId, shared) when anyone's shared data changes; `shared` is nil once they leave.
Data.OnSharedChanged:Connect(function(userId, shared)
    if shared then
        updateNameTag(userId, shared.Public.DisplayName)
    end
end)
```

Both hand you every `Shared` root keyed by its template name, so index through the root (`shared.Public`), not straight to the field.

:::caution `GetShared` never returns your own data
The server broadcasts a player's `Shared` roots to every client **except** that player's own, at join and on every diff. So on the owner's client `Data.GetShared(Players.LocalPlayer)` is always `nil`, and `OnSharedChanged` never fires with the local `userId`. A name-tag loop over `Players:GetPlayers()` silently skips one player, with no error and no log.

The owner still sees their own `Shared` roots, through the **ordinary accessor** (`Data.Public.DisplayName`), which stays live like any other field. The two read paths are separate, so handle the local player on the accessor and everyone else on `GetShared`:

```lua
local function displayName(player: Player): string?
    if player == Players.LocalPlayer then
        return Data.Public.DisplayName.Get()  -- your own Shared root
    end
    local shared = Data.GetShared(player)
    return if shared then shared.Public.DisplayName else nil
end
```
:::

`OnSharedChanged` hands you a `userId` rather than a `Player` on purpose: the owner may have already left (a departed player has no `Player` object, and that's exactly when a `nil` update fires). It's the stable key, and `GetShared` accepts it directly, so the two compose.

## How replication works

Scribe derives an identical schema on the server and client from the shared template, then streams **schema-compressed batched diffs** over a pluggable transport. Writes coalesce per frame (a `PostSimulation` flush) and only send when something actually changes. There is no idle traffic. The client applies diffs to a local mirror, so reads are instant and `Observe`/`Changed` fire locally.

:::note The client converges to the current value, not an event log
When a client finishes its handshake it receives a **snapshot** of the current data, then live diffs from there. It never replays writes made before it synced: set a field to `5` then `10` while the client is still handshaking and the client's first value is `10`, never `5`.

`Data.WaitForData(player)` on the **server** waits for that player's profile to load server-side, not for the client's handshake, so writes made right after it returns can reach the client only as their final value. To act on a client being ready to receive, drive it from the client (a first `Observe` fire, or a [`Data.Request`](/api/Client#Request) the client sends once loaded).

The client always ends at the correct current value. To have it observe a *sequence* of values, produce those changes after the client is synced and space them across frames, since same-frame writes to one field coalesce to the latest. For UI, read the value passed to `Observe` rather than counting fires.
:::

You never wire up RemoteEvents. The `"Default"` transport uses two RemoteEvents under a folder in `ReplicatedStorage` and is all most games ever need. If you already run your own networking layer, you can route Scribe's traffic through it. See [Custom Transports](./transports).

:::caution Client writes are optimistic
`data.Coins.Set(5)` on the client updates the local mirror only. It's fine for snappy UI, but the server's value always wins on the next diff. Authoritative changes go through [`Data.Request`](/api/Client#Request) to a server [`Command`](/api/Server#Command). See [Commands & Requests](./commands).
:::
