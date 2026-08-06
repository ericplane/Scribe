# Custom Transports

The **transport** is the network channel Scribe streams over. It moves opaque `buffer`s. Scribe owns everything above it (schema compression, batching, RPC correlation), so a transport only has to move bytes and refuse anything that isn't a `buffer`.

The `"Default"` transport (two RemoteEvents under a folder in `ReplicatedStorage`) is production-ready. **Most games never need anything else.** You'd only supply a custom transport if you already run your own networking layer and want Scribe's traffic to flow through that same channel.

## The interface

A transport is a table matching `Scribe.ScribeTransport`:

```lua
export type ScribeTransport = {
    Name: string,
    -- Server
    SendToClient: (self: any, player: Player, bytes: buffer) -> (),
    SendToAllClients: ((self: any, bytes: buffer) -> ())?, -- optional broadcast fast-path
    ListenServer: (self: any, callback: (player: Player, bytes: buffer) -> ()) -> (),
    -- Client
    SendToServer: (self: any, bytes: buffer) -> (),
    ListenClient: (self: any, callback: (bytes: buffer) -> ()) -> (),
}
```

Scribe validates the members it needs for the current context at startup (server methods on the server, client methods on the client), so a missing method fails loudly rather than silently. The signatures are the whole contract: `ListenServer` and `ListenClient` must invoke the callback **only** for payloads that really are a `buffer`, and drop everything else.

`SendToAllClients` is optional: a fast path for frames that go to *every* connected client, which today means the service-status broadcast. `Scribe.Shared` frames are **not** among them, because [they deliberately skip the owner's own client](./visibility#reading-another-players-shared-data), so those always go out through `SendToClient`. Omit the method and Scribe loops `SendToClient` for everything.

## Example

A full adapter is a dozen lines. This one wraps a buffer-typed remote from a Packet-style library:

```lua
local DataPacket = Packet("ScribeData", Packet.Buffer)

return {
    Name = "Packet",
    SendToClient = function(_, player, bytes) DataPacket:FireClient(player, bytes) end,
    SendToServer = function(_, bytes) DataPacket:Fire(bytes) end,
    ListenServer = function(_, cb)
        DataPacket.OnServerEvent:Connect(function(player, bytes)
            if typeof(bytes) == "buffer" then cb(player, bytes) end
        end)
    end,
    ListenClient = function(_, cb)
        DataPacket.OnClientEvent:Connect(function(bytes)
            if typeof(bytes) == "buffer" then cb(bytes) end
        end)
    end,
} :: Scribe.ScribeTransport
```

Forwarding the engine callback straight through (`:Connect(cb)`) is the one shortcut to avoid, for the reason in the next section.

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

- **Deliver `buffer` payloads only.** Your listeners are the type gate: check `typeof(bytes) == "buffer"` and drop anything else, on both the server and the client. A RemoteEvent lets a client fire any type it likes, and Scribe's inbound server handler measures the frame with `buffer.len` *before* the `pcall` that guards decoding, so a non-buffer payload throws inside your own connection instead of being counted and throttled as a [`MALFORMED_FRAME`](./log-codes#transport). The built-in `"Default"` transport does this check for you, which is why the requirement is easy to miss when writing an adapter.
- **The channel must be reliable and ordered.** Scribe sends diffs that build on each other; a dropped or reordered packet corrupts the client mirror. Use a reliable RemoteEvent (or your library's reliable channel), never an unreliable one.
- **Sender identity comes from the engine callback, never the payload.** In `ListenServer`, the `player` your callback receives is authoritative; do not read a user id out of the bytes. This is what keeps commands spoof-proof.
- **A custom transport won't make the payload smaller.** Scribe already schema-packs everything into a tight buffer before it reaches the transport, so there is no performance reason to move off the default.

## Multiple bundles on one channel

If you run more than one Scribe bundle, give each its own channel with `TransportChannel = "SomeName"` (or a distinct custom transport) so their traffic doesn't collide.
