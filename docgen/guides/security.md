# Security

What Scribe defends against, what it deliberately does not, and which knobs are yours.

## The trust boundary

**A client cannot write player data.** Not "writes are validated": there is no frame for it. A client emits exactly two frame types, `Hello` and `Command`, and the server's inbound dispatcher errors on anything else. No amount of crafted traffic expresses "set my Coins to 999", because the wire has no way to say it.

Client-side `Set` exists, but it only touches the local mirror for optimistic UI, and the next server diff overwrites it. The same holds for reads: [`Owns`](/api/Client#Owns) on the client reads a replicated mirror an exploiter can make return `true` locally, so gate grants on the **server's** [`OwnsAsync`](/api/Server#OwnsAsync), which verifies live.

That leaves two doors, and the rest of this page is what guards them.

## Inbound frames

Every frame from a client passes the same gauntlet before Scribe looks at its contents. Each gate is cheap and ordered so the cheap ones run first.

| Guard | Default | What it stops |
| --- | --- | --- |
| Session check | n/a | Frames from a player with no active profile are dropped |
| Malformed budget | 32 / session | Past it, **all** inbound from that player is dropped unparsed for the session |
| Oversize budget | 32 / session | Its own counter and block, because an oversize frame was never read while a malformed one was decoded and failed |
| `MaxInboundFrameRate` | `max(60, CommandRateLimit * 4)` | Raw frames per second, per player: the only ceiling that sees **every** frame whatever its type, size, or validity |
| `MaxInboundBytes` | 8192 | Frame size, checked before decode |
| Wire recursion cap | 24 | A crafted deeply-nested payload |
| Varint length cap | 10 groups | A malicious length prefix |
| Protocol version | n/a | Fails **closed** on mismatch: no handshake, no replication |
| Schema hash | n/a | Fails **closed** on template drift, because field ids would map to different paths on each side |
| Re-`Hello` cooldown | 5s | Repeated handshakes forcing full snapshot encodes |

Buffers, strings, and every length prefix are bounds-checked against the frame, and the whole decode runs inside a `pcall` that feeds the malformed budget. Roblox datatypes and `Instance`s are not in the generic codec at all, so a client physically cannot send one.

Every one of these logs is **throttled to once per second per player**, on its own clock. That is deliberate: an unthrottled log on a client-drivable path is the cheapest way to evict the diagnostic ring and erase the evidence of everything else. The counters in [`Scribe.GetMetrics`](/api/Scribe#GetMetrics) still count every occurrence.

:::note A frame-rate trip drops silently
Unlike the command limiter, `MaxInboundFrameRate` sends no reply, because replying is the amplification it exists to avoid. That is why it defaults well above `CommandRateLimit`: a chatty-but-legitimate client should hit `COMMAND_RATE_LIMITED`, which *does* reply, long before this. A client tripping this one is stranded until its `RequestTimeout`.
:::

## Commands

The one path where client input reaches your code. See the [Commands guide](./commands) for the full dispatch order.

- **Sender identity comes from the transport, never the payload.** A client cannot claim to be another player.
- **Rate limited** per player (`CommandRateLimit`, default 20/s), as a token bucket. Past a sustained flood (256 rejections without a 10s quiet gap) even the rejection reply stops.
- **Arguments are decoded last.** Every rejection above is answered from the fixed-size header alone, so a rejected frame never pays for decoding a payload an attacker chose the size of.
- **`not-ready` is uniform.** A pre-Ready session answers the same for every name, registered or not, so the command surface cannot be enumerated by diffing replies.
- **`Args` validation** is optional but recursive when declared: type strings, [Scribe declarators](./commands#declarators-optional) with their `Min`/`Max`/`MaxLength`/enum constraints, or nested shape tables that reject undeclared keys.
- **Handlers run inside `xpcall`.** A throw answers `error` and never leaks a traceback to the client.

Semantic authority stays yours. `Args` proves the payload's shape; whether *this* player may buy *that* item is your handler's job.

## Replication

Visibility is a compile-time property of each root, and `ServerOnly` data never enters a client queue:

- Diff ops are stripped before queueing, including `ServerOnly` descendants nested inside a whole-container `Set`.
- Snapshots go through the same filter, so a joining client's Init carries only what it may see.
- The library-owned `_Scribe` root is `ServerOnly` by default. Only `Perks` and `GiftCredits` replicate; purchase logs are opt-in per kind, and the receipt de-duplication ring never leaves the server.
- `ServerOnly` fields are absent from the **client type**, so reading one there is a build error rather than a `nil` at runtime.

## Monetization

- Receipts **fail closed**: `PurchaseGranted` only after a durable commit. Anything else answers `NotProcessedYet` so Roblox retries, and Robux are never eaten.
- Idempotency via a persisted `PurchaseId` ring. Entries age out after `PurchaseIdTTL` (7 days), well past any retry window. If a player buys faster than that drains, the count backstop evicts the oldest and logs [`PURCHASE_ID_EVICTED`](./log-codes#monetization), the one eviction that could let a retry grant twice.
- Grants are atomic. A `Grant` that throws rolls back completely rather than leaving partial writes that compound on the next retry.
- Gift intents carry a TTL and are keyed by product, so a second gift cannot overwrite a live intent and misdeliver the first purchase.

## Write validation

Scribe validates every write against the declared schema and fires [`OnAnomaly`](/api/Server#OnAnomaly) with the path, value, and reason: `OutOfBounds`, `OverMaxLength`, `InvalidUtf8`, `NotAMember`, `NonFiniteComponent`. Strings are UTF-8 checked and truncated on character boundaries, numbers are bounds-checked per `BoundsPolicy`, and unserializable values are refused at the write boundary rather than failing a whole profile's save opaquely later.

:::caution These are your bugs, not exploiters
Every one of those reasons fires on a **server-side write**: your game code writing a value the schema refuses. A client cannot cause them, because a client cannot write. Treat `OnAnomaly` as a correctness signal, not an abuse signal, and do not build player-facing enforcement on it: you would be kicking players for your own logic errors.

The abuse-shaped signals are the transport ones above (malformed, oversize, frame rate), because a real Scribe client cannot produce them.
:::

The wipe guard is the same idea at profile scale: every save is compared against the last good one, and a collapse in size or vanished top-level keys fires `WIPE_GUARD_TRIPPED`. Under `WipeGuardPolicy = "Block"` the last good snapshot persists instead.

## What Scribe deliberately does not do

- **No enforcement.** Nothing kicks, throttles, or bans a player for suspicious traffic. Crossing the malformed or oversize limit stops Scribe *parsing* their frames; they stay connected. Every response beyond that is yours.
- **No anti-cheat.** Scribe sees the data layer. Speed hacks, teleports, aimbots, and exploit GUIs are invisible to it. Treat it as one high-quality signal feeding your anti-cheat, never as the anti-cheat.
- **No per-viewer visibility.** `Shared` is all-or-nothing to every client. Anything conditional (party-only, team-only) has to go through a Command.
- **No ban list.** Banning is irreversible and needs an appeals process. That decision belongs to you.

## Knobs

| Option | Default | Tighten when |
| --- | --- | --- |
| `CommandRateLimit` | 20/s | Your commands are infrequent and you want spam caught sooner |
| `MaxInboundBytes` | 8192 | You know your largest legitimate command payload |
| `MaxInboundFrameRate` | `max(60, CommandRateLimit * 4)` | You have measured your busiest legitimate client |
| `BoundsPolicy` | `"Clamp"` | You would rather a bad write throw than silently clamp |
| `WipeGuardPolicy` | `"Warn"` | A suspected wipe should not reach the DataStore at all |
| `PurchaseIdTTL` | 7 days | Never lengthen past the retry window without raising the cap too |
| `MaxProcessedPurchaseIds` | 200 | Raise it if you see `PURCHASE_ID_EVICTED` |

## What to alert on

Route these to your backend with [`AddLogSink`](/api/Scribe#AddLogSink). Full list in the [Log Code Reference](./log-codes).

| Code | Reading |
| --- | --- |
| `MALFORMED_FRAME_LIMIT`, `INBOUND_OVERSIZE_LIMIT` | Scribe has concluded this is not a Scribe client and stopped parsing it |
| `INBOUND_RATE_LIMITED` | Traffic volume no real client produces |
| `COMMAND_UNKNOWN` in volume | Someone probing for command names |
| `PURCHASE_ID_EVICTED` | A retried receipt could now double-grant |
| `WIPE_GUARD_TRIPPED` | Data loss, whatever the cause |
| `ANOMALY` | A bug in your write path; see the caution above |

For a security issue in Scribe itself, open an issue on the [repository](https://github.com/ericplane/Scribe).
