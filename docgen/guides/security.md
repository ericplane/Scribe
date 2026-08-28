# Security

Scribe draws a hard line between what a player's client may say and what your server decides. This guide shows you where that line sits, what Scribe checks for you before your code runs, and which decisions stay yours. Read it before you ship anything a player can spend money on.

## The one shape a safe feature takes

A client asks. The server decides. In Emberfall, the potion shop is a [command](./commands) whose arguments are shape-checked before your handler runs, and whose grant is atomic:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)
local Data = require(ReplicatedStorage.Shared.EmberfallData).Server

Data.Command("BuyPotion", {
    Args = { Scribe.Int(1, { Min = 1, Max = 10 }) },
}, function(player, count)
    return Data.Purchase(player, {
        Cost = { Path = "Coins", Amount = 50 * count },
        Category = "Consumable",
        ItemId = "HealthPotion",
        Grant = function(data)
            data.Inventory["HealthPotion"].Update(function(entry)
                return { Qty = if entry then entry.Qty + count else count, Rarity = "Common" }
            end)
        end,
    })
end)
```

Two different checks are happening here, and it is worth naming them separately. The `Scribe.Int(1, { Min = 1, Max = 10 })` declarator proves the **shape** of what arrived: an integer, between 1 and 10, before your handler runs. Your handler proves the **entitlement**: `Data.Purchase` refuses if the player cannot afford it, and rolls the whole thing back if the grant throws. Scribe will never do the second one for you.

## What a client physically cannot do

**A client cannot write player data.** This is not "writes are validated". There is no frame for it. A client emits exactly two frame types, `Hello` and `Command`, and the server's inbound dispatcher errors on anything else. No amount of crafted traffic expresses "set my Coins to 999", because the wire has no way to say it.

Client-side `Set` does exist, but it touches only the local mirror for optimistic UI, and the next server diff overwrites it. Reads work the same way, which leads to the one mistake worth calling out:

!!! warning "Gate grants on the server, never on the client mirror"
    [`Owns`](/api/Client#Owns) on the client reads a replicated mirror that an exploiter can make return `true` locally. Use the server's [`OwnsAsync`](/api/Server#OwnsAsync), which verifies live, before you hand anyone the `VIP` reward.

    ```lua
    -- Server. This is the one that decides.
    if Data.OwnsAsync(player, "VIP") then
        Data[player].Gems.Increment(100)
    end
    ```

## The inbound gauntlet

Every frame from a client passes the same gates before Scribe looks at its contents. They are ordered so the cheap ones run first.

| Guard | Default | What it stops |
| --- | --- | --- |
| Session check | n/a | Frames from a player with no active profile are dropped |
| Malformed budget | 32 per session | Past it, all inbound from that player is dropped unparsed for the session |
| Oversize budget | 32 per session | Its own counter and block, because an oversize frame was never read while a malformed one was decoded and failed |
| `MaxInboundFrameRate` | `max(60, CommandRateLimit * 4)` | Raw frames per second per player, the only ceiling that sees every frame whatever its type, size or validity |
| `MaxInboundBytes` | 8192 | Frame size, checked before decode |
| `MaxInboundRetainedBytes` | `MaxInboundBytes * 16` | How many bytes one frame may retain, which size alone is a poor proxy for |
| Command-name length | longest registered name, minimum 64 | An over-long name, read from its length prefix rather than the string |
| Wire recursion cap | 24 | A crafted deeply nested payload |
| Varint length cap | 10 groups | A malicious length prefix |
| Protocol version | n/a | Fails closed on mismatch: no handshake, no replication |
| Schema hash | n/a | Fails closed on template drift, because field ids would map to different paths on each side |
| Re-`Hello` cooldown | 5s | Repeated handshakes forcing full snapshot encodes |

Buffers, strings and every length prefix are bounds-checked against the frame, and the whole decode runs inside a `pcall` that feeds the malformed budget. Roblox datatypes and `Instance` values are not in the generic codec at all, so a client physically cannot send one.

??? note "Why the retained-bytes ceiling is separate from frame size"

    Size is a poor proxy for cost. One byte can buy an array slot holding a boolean, while eight kilobytes of one string buys one header plus its payload, so the same frame budget retains either roughly 256 KB or roughly 8 KB. `MaxInboundRetainedBytes` is the ceiling that sees the difference.

    Read the 16 multiplier as a ceiling and only a ceiling. It dates from when the tagged encoding was the only one, where a hash pair cost four bytes and 64/4 was exactly 16:1. The two encodings added since do not hold that ratio. Worst case by path, pinned in the test suite: 16.0:1 for a generic or dense array of scalars, 16.6:1 for tagged dynamic keys, 30.2:1 for a static struct of scalars, 48.0:1 for a dense array of table elements, and 59.4:1 for a static struct of table children.

    None of those is reachable from untrusted input today. The server accepts only `Hello` and `Command`, and `Command` arguments take the generic codec, so those figures bound the client's decoder rather than the server's.

??? note "Why an over-budget frame does not cost a player their session"

    An object-budget refusal is counted separately from the malformed budget and never blocks the session. Unlike a malformed frame, an over-budget one may simply be a legitimate payload with more elements than the default allows, and 32 of those should not strand a real player.

    A frame-rate trip is different again: it sends no reply, because replying is the amplification it exists to avoid. That is why it defaults well above `CommandRateLimit`. A chatty but legitimate client should hit `COMMAND_RATE_LIMITED`, which does reply, long before this one. A client that trips this is stranded until its `RequestTimeout`.

??? note "Why these logs are throttled to once per second"

    Every guard above logs at most once per second per player, on its own clock. An unthrottled log on a path a client can drive is the cheapest way to evict the diagnostic ring and erase the evidence of everything else. The counters in [`Scribe.GetMetrics`](/api/Scribe#GetMetrics) still count every occurrence, so you lose no measurement, only log lines.

## Where your code is the boundary

Three places let your own decisions reach a client. Get these right and the rest of the surface is closed.

### Commands

The [Commands guide](./commands) has the full dispatch order. The security-relevant parts:

- **Sender identity comes from the transport, never the payload.** A client cannot claim to be another player. Never accept a user id as an argument and act on it.
- **Rate limited** per player, `CommandRateLimit`, 20 per second by default, as a token bucket. Past a sustained flood of 256 rejections without a ten second quiet gap, even the rejection reply stops.
- **Arguments are decoded last.** Every rejection is answered from the fixed-size header alone, so a rejected frame never pays to decode a payload whose size an attacker chose.
- **`not-ready` is uniform.** A session that has not reached Ready answers the same for every name, registered or not, so nobody can enumerate your command list by diffing replies.
- **Handlers run inside `xpcall`.** A throw answers `error` and never leaks a traceback to the client.

Semantic authority stays yours. `Args` proves the payload's shape. Whether *this* player may buy *that* item is your handler's job.

### Replication

Visibility is a compile-time property of each root, and [`ServerOnly`](./visibility) data never enters a client queue at all.

- Diff operations are stripped before queueing, including `ServerOnly` descendants nested inside a whole-container `Set`.
- Snapshots go through the same filter, so a joining client's Init carries only what it may see.
- The library-owned `_Scribe` root is `ServerOnly` by default. Only `Perks` and `GiftCredits` replicate, purchase logs are opt-in per kind, and the receipt de-duplication ring never leaves the server.
- `ServerOnly` fields are absent from the client type, so reading one there is a build error rather than a `nil` at runtime.

??? note "What a derived field can leak"

    A [derived field](./derived) is the one sanctioned way `ServerOnly` data can influence what a client receives. When all of its inputs are already visible to its audience the value is computed locally and nothing is sent. A replicated field reading a `ServerOnly` input **is** transmitted, deliberately, because that is the only way the client could have it.

    That makes your compute function part of the trust boundary. Suppose Emberfall keeps a server-only `Suspicion` score. `Watchlisted = suspicion >= 80` leaks one bit, which is usually the intent. `math.floor(suspicion / 10)` leaks most of the value, and an exploiter reading the client mirror gets it for free. Bucket deliberately, and keep the projection as coarse as the UI actually needs.

### Monetization

- Receipts fail closed. `PurchaseGranted` is returned only after a durable commit. Anything else answers `NotProcessedYet` so Roblox retries, and Robux are never eaten.
- Idempotency runs off a persisted receipt ring. Entries age out after `PurchaseIdTTL`, seven days, well past any retry window. If a player buys faster than that drains, the count backstop evicts the oldest and logs [`PURCHASE_ID_EVICTED`](./log-codes#monetization), which is the one eviction that could let a retry grant twice.
- Soft-currency claims are separate, keyed by the `IdempotencyKey` you pass to `Data.Purchase`, capped by `MaxPurchaseClaims` and expiring after `PurchaseClaimTTL`. An eviction there logs `PURCHASE_CLAIM_EVICTED`.
- Grants are atomic. A `Grant` that throws rolls back completely rather than leaving partial writes that compound on the next retry.
- Gift intents carry a TTL and are keyed by product, so a second gift cannot overwrite a live intent and misdeliver the first purchase.

## Write validation catches your bugs, not exploiters

Scribe validates every write against the declared template and fires [`OnAnomaly`](/api/Server#OnAnomaly) with the path, the value and a reason: `OutOfBounds`, `OverMaxLength`, `InvalidUtf8`, `NotAMember`, or `NonFiniteComponent`. Strings are UTF-8 checked and truncated on character boundaries, numbers are bounds-checked according to `BoundsPolicy`, and unserializable values are refused at the write boundary rather than failing a whole profile's save opaquely later.

!!! warning "OnAnomaly is a correctness signal, not an abuse signal"
    Every one of those reasons fires on a server-side write, which means your game code writing a value the template refuses. A client cannot cause them, because a client cannot write. Do not build player-facing enforcement on `OnAnomaly`: you would be kicking players for your own logic errors.

    The abuse-shaped signals are the transport ones, malformed frames, oversize frames and frame rate, because a real Scribe client cannot produce any of them.

The wipe guard is the same idea at profile scale. Every save is compared against the last good one, and a collapse in size or a vanished top-level key fires `WIPE_GUARD_TRIPPED`. Under `WipeGuardPolicy = "Block"` the last good snapshot persists instead.

## What Scribe deliberately does not do

- **No enforcement.** Nothing kicks, throttles or bans a player for suspicious traffic. Crossing the malformed or oversize limit stops Scribe parsing their frames. They stay connected, and every response beyond that is yours.
- **No anti-cheat.** Scribe sees the data layer. Speed hacks, teleports, aimbots and exploit GUIs are invisible to it. Treat it as one high-quality signal feeding your anti-cheat, never as the anti-cheat.
- **No per-viewer visibility.** `Shared` is all or nothing to every client. Anything conditional, such as party-only or team-only, has to go through a Command.
- **No ban list.** Banning is irreversible and needs an appeals process. That decision belongs to you.
- **No sandbox against your own server code.** The `_Scribe` root refuses every write from game code and hands back a detached copy on read, which makes the receipt ring, perks and gift credits safe from being cleared *by accident* through a `Get()`. That is what the guard is for. It is not a boundary against deliberate reflection: server code can `require` Scribe's internals directly, and `pairs()` over an accessor ignores metatables and reaches the same state. Closing that would not be a security win, because nothing stops the `require`. The accidental route is closed, and it is the one that bites: iterating an accessor now raises with the fix in the message, because the old fallback silently deleted the container.

### Knobs

| Option | Default | Tighten when |
| --- | --- | --- |
| `CommandRateLimit` | 20 per second | Your commands are infrequent and you want spam caught sooner |
| `MaxInboundBytes` | 8192 | You know your largest legitimate command payload |
| `MaxInboundFrameRate` | `max(60, CommandRateLimit * 4)` | You have measured your busiest legitimate client |
| `BoundsPolicy` | `"Clamp"` | You would rather a bad write throw than silently clamp |
| `WipeGuardPolicy` | `"Warn"` | A suspected wipe should not reach the DataStore at all |
| `PurchaseIdTTL` | 7 days | Never lengthen it past the retry window without raising the cap too |
| `MaxProcessedPurchaseIds` | 200 | Raise it if you see `PURCHASE_ID_EVICTED` |

Every one of these is set in the [configuration table](./configuration) you pass to `Scribe({ ... })`.

### What to alert on

Route these to your backend with [`AddLogSink`](/api/Scribe#AddLogSink). The full list is in the [Log Code Reference](./log-codes).

| Code | Reading |
| --- | --- |
| `MALFORMED_FRAME_LIMIT`, `INBOUND_OVERSIZE_LIMIT` | Scribe has concluded this is not a Scribe client and stopped parsing it |
| `INBOUND_RATE_LIMITED` | Traffic volume no real client produces |
| `COMMAND_UNKNOWN` in volume | Someone probing for command names |
| `PURCHASE_ID_EVICTED` | A retried receipt could now double-grant |
| `WIPE_GUARD_TRIPPED` | Data loss, whatever the cause |
| `ANOMALY` | A bug in your write path, per the caution above |

For a security issue in Scribe itself, open an issue on the [repository](https://github.com/ericplane/Scribe).

## Where to next

- [Commands & Requests](./commands) for the full `Args` vocabulary and the dispatch order behind the gauntlet.
- [Replication & Visibility](./visibility) for choosing `ServerOnly`, `Shared` and `Session` per root field.
- [Monetization](./monetization) for receipts and idempotency keys, and [Gifting](./gifting) for the gift intent flow.
- [Diagnostics](./diagnostics) for the counters and log sinks that turn these codes into alerts.
- [Configuration](./configuration) for every knob in the table above, with its full description.
