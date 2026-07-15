---
sidebar_position: 12
---

# Custom Transports

The **transport** is the network channel Scribe streams over. It moves opaque `buffer`s. Scribe owns everything above it (schema compression, batching, RPC correlation), so a transport only has to send and receive bytes.

The `"Default"` transport (two RemoteEvents under a folder in `ReplicatedStorage`) is production-ready. **Most games never need anything else.** You'd only supply a custom transport if you already run your own networking layer and want Scribe's traffic to flow through that same channel.

## The interface

A transport is a table matching `Scribe.ScribeTransport`:

```lua
export type ScribeTransport = {
    Name: string,
    -- Server
    SendToClient: (self, player: Player, bytes: buffer) -> (),
    SendToAllClients: ((self, bytes: buffer) -> ())?, -- optional broadcast fast-path
    ListenServer: (self, callback: (player: Player, bytes: buffer) -> ()) -> (),
    -- Client
    SendToServer: (self, bytes: buffer) -> (),
    ListenClient: (self, callback: (bytes: buffer) -> ()) -> (),
}
```

Scribe validates the members it needs for the current context at startup (server methods on the server, client methods on the client), so a missing method fails loudly rather than silently.

`SendToAllClients` is optional. If you provide it, Scribe uses it to broadcast `Scribe.Shared` data to every client in one call; otherwise it falls back to looping `SendToClient`.

## Example

A full adapter is about six lines. This one wraps a buffer-typed remote from a Packet-style library:

```lua
local DataPacket = Packet("ScribeData", Packet.Buffer)

return {
    Name = "Packet",
    SendToClient = function(_, player, bytes) DataPacket:FireClient(player, bytes) end,
    ListenServer = function(_, cb) DataPacket.OnServerEvent:Connect(cb) end,
    SendToServer = function(_, bytes) DataPacket:Fire(bytes) end,
    ListenClient = function(_, cb) DataPacket.OnClientEvent:Connect(cb) end,
} :: Scribe.ScribeTransport
```

Pass it to `Scribe`:

```lua
return Scribe({
    Template = template,
    Transport = require(ReplicatedStorage.Shared.MyTransport),
    ProfileStoreIndex = "PlayerData",
    ProfileKeyPrefix = "PLAYER_",
})
```

## Rules

- **The channel must be reliable and ordered.** Scribe sends diffs that build on each other; a dropped or reordered packet corrupts the client mirror. Use a reliable RemoteEvent (or your library's reliable channel), never an unreliable one.
- **Sender identity comes from the engine callback, never the payload.** In `ListenServer`, the `player` your callback receives is authoritative; do not read a user id out of the bytes. This is what keeps commands spoof-proof.
- **A custom transport won't make the payload smaller.** Scribe already schema-packs everything into a tight buffer before it reaches the transport, so a networking library adds its own conveniences but no extra per-field compression. There's no performance reason to move off the default. Do that only to unify with an existing setup.

## Multiple bundles on one channel

If you run more than one Scribe bundle, give each its own channel with `TransportChannel = "SomeName"` (or a distinct custom transport) so their traffic doesn't collide.
