---
sidebar_position: 3
---

# Replication & Visibility

By default, a field persists and replicates to its **owner**, the player it belongs to. Wrap a root field to change that.

| Wrapper | Persists? | Replicates to | Use for |
| --- | --- | --- | --- |
| *(default)* | ✅ | the owner | most player data |
| [`Scribe.ServerOnly(v)`](/api/Scribe#ServerOnly) | ✅ | nobody | secrets, anti-cheat state |
| [`Scribe.Shared(v)`](/api/Scribe#Shared) | ✅ | **every** client | public info (name, team) |
| [`Scribe.Session(v)`](/api/Scribe#Session) | ❌ | the owner | runtime-only state |

```lua
local template = {
    Coins   = 0,                                 -- persists, owner sees it
    Secret  = Scribe.ServerOnly({ Flagged = false }), -- never leaves the server
    Public  = Scribe.Shared({ DisplayName = "" }),    -- everyone sees it
    Runtime = Scribe.Session({ InCombat = false }),   -- resets on rejoin
}
```

`Shared` and `Session` are **root-only** wrappers. `ServerOnly` may also wrap a nested field to keep just that subtree server-side while its siblings replicate.

## Reading another player's shared data

`Scribe.Shared` roots stream to everyone. Read them on the client with [`GetShared`](/api/Client#GetShared), which accepts a `Player` or a `userId`:

```lua
local pub = Data.GetShared(otherPlayer)
if pub then nameLabel.Text = pub.DisplayName end

-- Fires (userId, shared) when anyone's shared data changes; `shared` is nil once they leave.
Data.OnSharedChanged:Connect(function(userId, shared)
    if shared then
        updateNameTag(userId, shared.DisplayName)
    end
end)
```

`OnSharedChanged` hands you a `userId` rather than a `Player` on purpose: the owner may have already left (a departed player has no `Player` object, and that's exactly when a `nil` update fires). It's the stable key, and `GetShared` accepts it directly, so the two compose.

## How replication works

Scribe derives an identical schema on the server and client from the shared template, then streams **schema-compressed batched diffs** over a pluggable transport. Writes coalesce per frame (a `PostSimulation` flush) and only send when something actually changes. There is no idle traffic. The client applies diffs to a local mirror, so reads are instant and `Observe`/`Changed` fire locally.

You never wire up RemoteEvents. The `"Default"` transport uses two RemoteEvents under a folder in `ReplicatedStorage` and is all most games ever need. If you already run your own networking layer, you can route Scribe's traffic through it. See [Custom Transports](./transports).

:::caution Client writes are optimistic
`data.Coins.Set(5)` on the client updates the local mirror only. It's fine for snappy UI, but the server's value always wins on the next diff. Authoritative changes go through [`Data.Request`](/api/Client#Request) → a server [`Command`](/api/Server#Command).
:::
