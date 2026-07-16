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

:::note The client converges to the current value, not an event log
When a client finishes its handshake it receives a **snapshot** of the current data, then live diffs from that point on. It never replays writes that happened before it synced, so it is not a log of every value the server ever set.

- A value the server sets and then overwrites before the client syncs is not delivered on its own. Set a field to `5` then `10` while the client is still handshaking, and the client's first value is `10`, never `5`. `Observe` fires once with the synced value, then again on each later change.
- `Data.WaitForData(player)` on the **server** waits for that player's profile to load server-side, not for the client's handshake to finish. Writes made right after it returns can reach the client only as their final value. To act on a client being ready to receive, drive it from the client (a first `Observe` fire, or a [`Data.Request`](/api/Client#Request) the client sends once loaded).

The client always ends at the correct current value. To have it observe a *sequence* of values, produce those changes after the client is synced and space them across frames, since same-frame writes to one field coalesce to the latest. For UI, read the value passed to `Observe` rather than counting individual fires.
:::

You never wire up RemoteEvents. The `"Default"` transport uses two RemoteEvents under a folder in `ReplicatedStorage` and is all most games ever need. If you already run your own networking layer, you can route Scribe's traffic through it. See [Custom Transports](./transports).

:::caution Client writes are optimistic
`data.Coins.Set(5)` on the client updates the local mirror only. It's fine for snappy UI, but the server's value always wins on the next diff. Authoritative changes go through [`Data.Request`](/api/Client#Request) → a server [`Command`](/api/Server#Command).
:::
