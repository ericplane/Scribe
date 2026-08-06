# Commands & Requests

Client writes are local-only (see [Replication & Visibility](./visibility)). A **command** is the one way a client changes data authoritatively: you register a named handler on the server with [`Data.Command`](/api/Server#Command), and the client calls it by name with [`Data.Request`](/api/Client#Request), which yields until the reply arrives and hands back whatever the handler returned.

```lua
-- server
Data.Command("EquipItem", { Args = { "string" } }, function(player, itemId)
    Data[player].Equipped.Set(itemId)
    return true
end)

-- client
local equipped = Data.Request("EquipItem", "Sword_001")
```

The `player` a handler receives comes from the transport, never from the payload, so a client cannot claim to be someone else. Never accept a `userId` as an argument and act on it.

## Registering

There are two forms. The spec is optional; everything else is the same.

```lua
Data.Command("Ping", function(player)                  -- no spec: args are unvalidated
    return os.time()
end)

Data.Command("Buy", { Args = { "string", "number?" } }, function(player, sku, qty)
    ...
end)
```

`Data.Command` is a plain runtime call, so register everything at startup, before clients begin calling. A name with no registration is answered `unknown-command`. Registering the **same name twice errors**, as does an empty name or a handler that is not a function. Those are startup mistakes, so they throw at the call site rather than failing quietly later.

## The `Args` spec

`Args` is a list of type strings, one per positional argument. The leading `player` is not counted, so `{ "string" }` describes `function(player, itemId)`. Only the `Args` key of the spec table is read.

The check runs before the handler does, and it is a **shape** check only. Semantic validation ("does this player actually own that item") stays the handler's job.

| Spec entry | Accepts |
| --- | --- |
| `"string"`, `"number"`, `"boolean"`, `"table"`, `"buffer"` | a value whose `typeof()` is exactly that |
| `"any"` | any value except `nil` |
| a trailing `?`, as in `"string?"` | that type, or `nil` (including an omitted trailing argument) |
| `"any?"` | anything at all, `nil` included |

Passing **fewer** arguments than the spec declares is fine only where the entries are optional: the missing positions read as `nil`, and a non-optional entry rejects them. Passing **more** arguments than the spec declares is rejected outright, before any per-position check, and unlike a type mismatch it is not logged at all. Both rejections reply `bad-args`.

With no spec, nothing is validated: the handler receives whatever the client sent, in whatever types it sent, and must check them itself.

:::note Only wire-encodable values cross the boundary
Command arguments and return values are carried by Scribe's generic codec, which handles `nil`, booleans, numbers, strings, buffers, and tables of those (nested at most 24 deep). Roblox datatypes are **not** included: `Vector3` and `CFrame` are legal `typeof()` strings to write in an `Args` spec, but they can never match, because `Data.Request` raises while encoding one before the frame is ever sent. Pass the components, or pack them into a table.
:::

### Argument count

A command takes at most **16** arguments. `Data.Request` raises on the caller's thread if you pass more, rather than clamping, so a handler never runs with silently dropped trailing arguments. A hand-crafted frame carrying more is dropped server-side as a malformed frame with no reply at all, and the caller waits out its timeout.

## Return values

On success the handler's return values **are** the `Data.Request` results, passed through verbatim and in order. A handler that returns nothing leaves the caller with nothing, so return at least one value if the caller needs to branch.

A reply frame carries at most **8** values. Beyond that only the first 8 are sent, the caller sees trailing `nil`s, and the server warns `COMMAND_REPLY_TRUNCATED`. Pack the extras into a table instead. Return values are subject to the same encodable-type rule as arguments; a value the wire cannot carry turns the whole reply into a `reply-encode-failed` failure, **after** the handler's writes have already committed.

## What the caller gets back on failure

Every failure resolves `Data.Request` as exactly two values: `false` and one sentinel string.

| Sentinel | Raised by | Means |
| --- | --- | --- |
| `"rate-limited"` | server | the player is over `CommandRateLimit`. The handler never ran. |
| `"unknown-command"` | server | nothing is registered under that name. Usually a client running an older build. |
| `"not-ready"` | server | the caller's profile is not `Ready` (still loading, or the session already ended). |
| `"bad-args"` | server | the call did not match the `Args` spec: a wrong type at some position, or more arguments than declared. |
| `"error"` | server | the handler threw. The traceback goes to the `COMMAND_ERROR` log and is never sent to the client. |
| `"reply-encode-failed"` | server | the handler succeeded but returned something the wire cannot carry. Its writes stand. |
| `"timeout"` | client | no reply within `RequestTimeout`. See [below](#yielding-and-requesttimeout): the handler may still be running. |
| `"send-failed"` | client | the transport raised while sending the request frame. |
| `"edit-mode"` | client | `RunService:IsRunning()` is false and no [`MockCommand`](/api/Client#MockCommand) is registered under that name. |
| `"mock-error"` | client | edit mode, and the registered `MockCommand` handler threw. |

Two failures do **not** produce a sentinel and instead raise on the calling thread, because they are caller bugs rather than runtime conditions: passing more than 16 arguments, and passing a value the wire cannot encode.

:::caution Scribe cannot tell your `false, reason` apart from its own
There is no `ok` flag on the reply the caller can inspect. A handler that returns `false, "not owned"` hands the client the same two values as a rate-limited, unknown, not-ready, bad-args, thrown, or unencodable request. A naive `showToast(reason)` will eventually show a player the word `rate-limited`.

Return a shape that cannot collide instead. A table works, since Scribe's sentinels are always a plain string in the second slot and `false` in the first:

```lua
-- server
Data.Command("EquipItem", { Args = { "string" } }, function(player, itemId)
    if not Data[player].Inventory[itemId].Get() then
        return { Ok = false, Reason = "not owned" }
    end
    Data[player].Equipped.Set(itemId)
    return { Ok = true }
end)

-- client
local result, reason = Data.Request("EquipItem", "Sword_001")
if type(result) ~= "table" then
    warn(`EquipItem never ran: {reason}`) -- `reason` is one of the sentinels above
    return
end
if not result.Ok then
    showToast(result.Reason) -- your reason, safe to show a player
end
```
:::

## How a request is dispatched

Each inbound command frame runs the same gauntlet on the server, in this order. The first gate that rejects sends its sentinel and stops.

1. **Rate limit.** A token is taken before anything else, so even an unknown command name costs one.
2. **Registry lookup.** No registration under that name gives `unknown-command`.
3. **Ready gate.** The caller's profile must be in the `Ready` state, which is why [`Data[player]`](./lifecycle) is safe inside a handler without a `WaitForData` first. A profile still loading, or one whose session already ended, gives `not-ready`.
4. **`Args` check**, if the command declared one.
5. **The handler**, inside an `xpcall`. A throw is logged as `COMMAND_ERROR` and answered `error`.
6. **The reply**, encoded and sent.

## Yielding and `RequestTimeout`

A handler runs on the inbound frame thread inside an `xpcall`, so it **may yield**: `task.wait`, a DataStore call, `MarketplaceService`, [`Data.OwnsAsync`](./monetization#ownership). Nothing on the server bounds how long it takes, and the reply is only sent once the handler returns.

The client is the side with a clock. `Data.Request` arms a timer for `RequestTimeout` (default 10 seconds) and, when it expires, drops its own waiter and resolves the caller with `false, "timeout"`. When the handler eventually finishes, its reply arrives to a waiter that no longer exists and is discarded. No log code fires on either side.

:::caution A timeout is not a rollback
The handler kept running. Its `Set`, `Increment`, and `Insert` calls committed and will save normally. The client was told the command failed while the server durably succeeded, and nothing reconciles the two.

Keep handlers inside `RequestTimeout`. When a handler has to make a yielding Roblox web call whose worst case you do not control, either raise `RequestTimeout` to cover it, or return immediately and deliver the outcome through the replicated data itself (an `Observe` on the field the handler eventually writes) rather than through the RPC reply.
:::

A handler may yield, but the [`Batch` and `Transaction`](./lifecycle#batching-and-transactions) blocks inside it still must not.

`Data.Request` also yields until the client's **first snapshot** has arrived before it sends anything, and that wait has no timeout of its own: `RequestTimeout` only starts once the frame is on the wire. For a request fired at startup, gate on [`Data.WaitForData(timeout)`](/api/Client#WaitForData) first if you need the whole call to be bounded.

## Rate limiting

Each player gets a token bucket, sized and refilled at [`CommandRateLimit`](./configuration#behaviour-limits) per second (default 20). It starts full, so a burst of up to the full allowance passes at once and then drains to the sustained rate.

| Situation | What happens |
| --- | --- |
| Under the limit | the request proceeds normally |
| Over the limit | reply `false, "rate-limited"`, the `CommandsRateLimited` counter moves, and `COMMAND_RATE_LIMITED` is logged at most once per second per player |
| 256 rate-limited frames with no 10-second quiet gap | the rejection **reply is dropped too**, so the caller sits until `RequestTimeout` |
| 10 seconds without a single rate-limited frame | the sustained-flood counter resets to zero |

The log throttle and the reply cutoff exist for the same reason: this is the one command path an exploiter can drive without bound, and an unthrottled log would evict the diagnostic ring and erase the evidence of the flood itself. The metric counters still count every occurrence.

## In edit mode

With `RunService:IsRunning()` false (a storybook, the command bar), there is no server to answer. `Data.Request` looks for a handler registered with [`Data.MockCommand`](/api/Client#MockCommand): if there is none it returns `false, "edit-mode"`, and if the mock throws it returns `false, "mock-error"`.

```lua
Data.MockCommand("EquipItem", function(itemId)
    return { Ok = true }
end)
```

A mock handler takes **only the arguments**, with no leading `player`, since there is no session to attribute it to. `MockCommand` errors outside edit mode, so it cannot leak into a real one. See [Testing & Edit Mode](./testing#edit-mode-storybooks).

## Diagnostics

[`Scribe.GetMetrics()`](/api/Scribe#GetMetrics) counts the whole pipeline: `CommandsReceived` (every decoded frame), `CommandsRateLimited`, `CommandsRejected` (unknown name or bad args), `CommandsHandled`, and `CommandErrors`.

The `COMMAND_*` log codes, including which ones are throttled and which never log at all, are in the [Log Code Reference](./log-codes). The [Scribe Studio plugin](./studio-plugin) has a **Commands** panel that lists every registration with a form generated from its `Args` spec, and invokes it as any session player so you can see returns, errors, and duration without writing a test client.
