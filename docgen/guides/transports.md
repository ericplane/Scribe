# Custom Transports

The transport is the network channel Scribe streams over. It moves opaque `buffer` values and nothing else, because Scribe owns everything above it: schema compression, batching, and request correlation. The built-in `"Default"` transport is production-ready, and most games never replace it.

You would write your own only if Emberfall already runs its own networking layer and you want Scribe's traffic flowing through that same channel, so one place handles logging, ordering and instrumentation for every packet the game sends.

## A working adapter

An adapter is a table matching `Scribe.ScribeTransport`. This one wraps a buffer-typed remote from a Packet-style library and is the whole file:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)

local EmberfallPacket = Packet("EmberfallData", Packet.Buffer)

return {
    Name = "EmberfallPacket",
    SendToClient = function(_, player, bytes) EmberfallPacket:FireClient(player, bytes) end,
    SendToServer = function(_, bytes) EmberfallPacket:Fire(bytes) end,
    ListenServer = function(_, cb)
        EmberfallPacket.OnServerEvent:Connect(function(player, bytes)
            if typeof(bytes) == "buffer" then cb(player, bytes) end
        end)
    end,
    ListenClient = function(_, cb)
        EmberfallPacket.OnClientEvent:Connect(function(bytes)
            if typeof(bytes) == "buffer" then cb(bytes) end
        end)
    end,
} :: Scribe.ScribeTransport
```

Then hand it to Scribe in the shared Emberfall module:

```lua
return Scribe({
    Template = template,
    Transport = require(ReplicatedStorage.Shared.EmberfallTransport),
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",
})
```

That is a complete, correct adapter. The `typeof(bytes) == "buffer"` check in both listeners is not optional, and the next section says why.

## The interface

```lua
export type ScribeTransport = {
    Name: string,
    MaxFrameBytes: number?, -- optional: this channel's own ceiling, in bytes
    -- Server
    SendToClient: (self: any, player: Player, bytes: buffer) -> (),
    SendToAllClients: ((self: any, bytes: buffer) -> ())?, -- optional broadcast fast path
    ListenServer: (self: any, callback: (player: Player, bytes: buffer) -> ()) -> (),
    -- Client
    SendToServer: (self: any, bytes: buffer) -> (),
    ListenClient: (self: any, callback: (bytes: buffer) -> ()) -> (),
}
```

Scribe checks the members it needs for the current realm at startup, so a missing one fails loudly with `Scribe: custom transport is missing "..."` rather than going quiet. On the server that is `SendToClient` and `ListenServer`. On the client it is `SendToServer` and `ListenClient`.

`SendToAllClients` is an optional fast path for frames that go to every connected client, which today means the service-status broadcast. `Scribe.Shared` frames are not among them, because [they deliberately skip the owner's own client](./visibility), so those always go out through `SendToClient`. Omit the method and Scribe loops `SendToClient` for everything.

## The five rules

**Deliver `buffer` payloads only.** Your listeners are the type gate. Check `typeof(bytes) == "buffer"` and drop anything else, on both realms. A RemoteEvent lets a client fire any type it likes, and Scribe measures an inbound frame with `buffer.len` before the `pcall` that guards decoding, so a non-buffer payload throws inside your own connection instead of being counted and throttled as a [`MALFORMED_FRAME`](./log-codes#transport).

**The channel must be reliable and ordered.** Scribe sends diffs that build on each other, so a dropped or reordered packet corrupts the client mirror. Use a reliable RemoteEvent or your library's reliable channel, never an unreliable one.

**The send methods must not yield.** `FireClient` and its equivalents return immediately, so a thin adapter satisfies this without trying. One that awaits a delivery acknowledgement, rate limits by sleeping, or routes through a promise library does not. Scribe calls `SendToClient` from inside the handshake and from the per-frame flush, and a send that parks there stalls the rest of that frame's work for every player. Buffer internally and return instead.

**Sender identity comes from the engine callback, never the payload.** In `ListenServer`, the `player` your callback receives is authoritative. Do not read a user id out of the bytes. This is what keeps [commands](./security) spoof-proof.

**No single call exceeds [`MaxOutboundBytes`](./configuration), 65536 by default.** Anything larger is split by Scribe and rebuilt by the client, so an adapter never has to carry a multi-megabyte buffer. That matters because an Init snapshot is the player's whole Emberfall profile. Never add chunking inside the adapter: fragments arriving out of order are discarded, so an adapter that reorders breaks reassembly exactly as it breaks diffs.

??? note "Why forwarding the engine callback straight through is the shortcut to avoid"

    Writing `EmberfallPacket.OnServerEvent:Connect(cb)` instead of the wrapped form looks equivalent and is not. The built-in `"Default"` transport does the `typeof` check for you, which is precisely why the requirement is easy to miss when you write your first adapter.

    Without it, a client firing a string or a table reaches Scribe's inbound handler, which calls `buffer.len` on it before the guarded decode. That throws inside your own connection. It is not counted against the malformed budget, not throttled, and not logged as a `MALFORMED_FRAME`, so the one signal that would have told you an exploiter is probing never fires.

??? note "A custom transport will not make the payload smaller"

    Scribe schema-packs everything into a tight buffer before it reaches the transport, so there is no performance reason to move off the default. Field names never go on the wire, bounded integers pack to their smallest form, and diffs carry only what changed. An adapter sees the finished bytes.

    Pick a custom transport for operational reasons, such as one logging path or one ordering guarantee across your whole game, and not in the hope of shaving bytes.

## Declaring a smaller ceiling

If your channel cannot carry 64 KB, declare `MaxFrameBytes` on the transport itself rather than asking every game that uses your adapter to remember a matching `MaxOutboundBytes`:

```lua
return {
    Name = "Base64Bridge",
    MaxFrameBytes = 49152, -- 65536 wire bytes divided by the 4/3 base64 expansion
    -- the rest of the adapter
} :: Scribe.ScribeTransport
```

Scribe reads the field once at startup and takes the smaller of the two, so declaring one can only narrow the budget and never widen it. A game that asked for 4096 keeps 4096 even behind an adapter declaring 65536.

Set it to the largest buffer that survives your channel **after your own framing**. An adapter that base64s the payload inflates it by 4/3, so a 65536-byte wire limit is a `MaxFrameBytes` of 49152.

??? note "Why the ceiling belongs on the adapter and not in its README"

    "Remember to set `MaxOutboundBytes` when you use my adapter" is a coupling nothing enforces. The failure it produces is not a clear error either: the client never finishes loading and re-sends `Hello` forever, which looks like a DataStore problem long before it looks like a framing problem.

    Putting the number on the transport makes it travel with the code that knows it, and the one-way clamp means a game can still tighten the budget further without you doing anything.

## Running more than one bundle

If Emberfall runs a second Scribe bundle, give each one its own channel with `TransportChannel = "SomeName"`, or a distinct custom transport, so their traffic does not collide.

## Where to next

- [Configuration](./configuration) for `MaxOutboundBytes`, `TransportChannel` and the rest of the network options.
- [Security](./security) for what Scribe checks on every inbound frame once your adapter has handed it over.
- [Replication & Visibility](./visibility) for what actually travels down the channel and when.
- [Diagnostics](./diagnostics) for the counters that tell you whether frames are arriving.
- [Log Code Reference](./log-codes#transport) for the transport-category codes.
