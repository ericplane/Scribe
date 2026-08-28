# Commands & Requests

A player clicks a button in Emberfall and something has to actually change: coins are spent, a setting flips, a daily reward is claimed. The client cannot make that change itself, because anything a client writes stays on the client and never reaches the server. A **command** is how you close that gap. You register a named function on the server, the client calls it by name, and the server's answer comes back.

## Your first command

Register the handler on the server, once, at startup.

```lua
-- ServerScriptService/EmberfallServer.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)
local Data = require(ReplicatedStorage.Shared.EmberfallData).Server

Data.Command("ToggleMusic", { Args = { "boolean" } }, function(player, on)
    if on then
        Data[player].Settings.Enable("Music")
    else
        Data[player].Settings.Disable("Music")
    end
    return on
end)
```

Call it from a `LocalScript`.

```lua
-- StarterPlayerScripts/EmberfallUi.client.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)
local Data = require(ReplicatedStorage.Shared.EmberfallData).Client

local musicOn = Data.Request("ToggleMusic", false)
```

[`Data.Request`](/api/Client#Request) yields until the reply arrives and hands back whatever the handler returned, so `musicOn` is `false` here. The `player` your handler receives comes from the transport, so a client cannot claim to be someone else. Never accept a user id as an argument and act on it.

## Registering

There are two forms. The spec table is optional, and everything else is the same.

```lua
Data.Command("GetServerTime", function(player)          -- no spec: nothing is validated
    return os.time()
end)

Data.Command("BuyPotion", { Args = { "number" } }, function(player, count)
    ...
end)
```

Register every command at startup, before clients begin calling. A name with no registration is answered `unknown-command`. Registering the same name twice throws, as does an empty name or a handler that is not a function. Those are startup mistakes, so they surface at the call site instead of failing quietly in production.

The spec table reads exactly two keys: `Args`, covered next, and `Idempotent`, covered under [running a command at most once](#running-a-command-at-most-once).

## Validating what the client sent

`Args` is a list of specs, one per positional argument. The leading `player` is not counted, so `{ "string" }` describes `function(player, itemId)`. The check runs before your handler does, and it checks **shape** only. Semantic validation, such as whether this player really owns that item, stays your job.

| Spec entry | Accepts |
| --- | --- |
| `"string"`, `"number"`, `"boolean"`, `"table"`, `"buffer"` | a value whose `typeof()` is exactly that |
| `"any"` | any value except `nil` |
| a trailing `?`, as in `"string?"` | that type, or `nil`, including an omitted trailing argument |
| `"any?"` | anything at all, `nil` included |

### Ranges, not just types

A spec entry may be a **declarator**, the same vocabulary your template uses. Reach for one when the argument has a legal range and not just a legal type.

```lua
Data.Command("BuyPotion", {
    Args = {
        Scribe.Enum("Health", { "Health", "Mana" }),
        Scribe.Int(1, { Min = 1, Max = 10 }),
    },
}, function(player, flavour, count)
    ...
end)
```

The declarator's constraints come with it: `Min`, `Max`, `MaxLength`, enum members, `MaxItems`, `MaxKeys`, `MaxKeyLength`, and integrality for `Scribe.Int`. A bare `"number"` can only tell you a number arrived, which is the half of the check that never catches anything interesting. `count = 0`, `count = 2.5` and `count = 1e9` all pass `"number"`, and all three fail `Scribe.Int(1, { Min = 1, Max = 10 })`.

Accepted here: `Int`, `Number`, `String`, `Enum`, `Flags`, `Optional`, `ArrayOf`, `SetOf`, `DictOf`, `MapOf`. The rest describe how a field is stored or replicated (`Timed`, `ServerOnly`, `Shared`, `Session`, `Dynamic`) or carry a value the wire cannot represent (`Datatype`, `Big`). Passing one of those is refused at registration, and the error names the declarator.

### Table payloads

A spec entry may also be a **shape table** describing a table argument, nested as deep as eight levels. This is opt-in. A bare `"table"` stays exactly as permissive as it was, and most commands take scalars where a shape would be noise.

```lua
Data.Command("CraftItem", {
    Args = { { ItemId = "string", Count = "number?", Reagents = { "string" } } },
}, function(player, order)
    -- order.ItemId is a string, order.Count is a number or nil, and every
    -- order.Reagents element is a string. All of it, before this line runs.
end)
```

| Shape form | Means |
| --- | --- |
| `{ Field = spec, ... }` | a table with exactly these keys, each value matching its spec |
| a declarator | that declarator's type and its constraints |
| `{ spec }`, a single entry at index `1` | an array whose every element matches `spec` |

Two rules are worth knowing. A shape **rejects undeclared keys**, because a payload carrying a field the command never declared is either version skew or someone probing. And a shape is always **required**: for an optional table argument, declare `"table?"` and check the contents yourself.

A malformed spec is rejected at registration rather than on the first client call, so a shape that could never match fails at startup instead of turning every request into `bad-args` in production.

??? note "Why a bad argument is rejected and never clamped"
    A template write **clamps** an out-of-range number under the default `BoundsPolicy`, because the server chose that value and losing a little precision beats losing the write entirely.

    A command argument is the client's claim about what it wants, so it is rejected with `bad-args` instead. Silently clamping is how "buy 999999" quietly becomes "buy 10", and the player is then charged for something they did not ask for.

??? note "Argument and return-value limits"
    A command takes at most **16** arguments. `Data.Request` raises on the caller's thread if you pass more, rather than clamping, so a handler never runs with silently dropped trailing arguments. A hand-crafted frame carrying more is dropped server-side with no reply at all, and that caller waits out its timeout.

    A reply frame carries at most **8** values. Beyond that only the first eight are sent, the caller sees trailing `nil`s, and the server warns `COMMAND_REPLY_TRUNCATED`. Pack the extras into a table.

    Passing **fewer** arguments than the spec declares is fine only where those entries are optional. The missing positions read as `nil`, and a non-optional entry rejects them. Passing **more** arguments than the spec declares is rejected outright, before any per-position check, and unlike a type mismatch it is not logged at all. Both rejections answer `bad-args`.

??? note "Only wire-encodable values cross the boundary"
    Arguments and return values are carried by Scribe's generic codec, which handles `nil`, booleans, numbers, strings, buffers, and tables of those nested at most 24 deep.

    Roblox datatypes are not included. `Vector3` and `CFrame` are legal `typeof()` strings to write in an `Args` spec, but they can never match, because `Data.Request` raises while encoding one before the frame is ever sent. Pass the components, or pack them into a table.

## Running a command at most once

Some commands must not run twice however many times the client asks. Claiming the Emberfall daily reward is the obvious one: a retry after a slow network should hand out one hundred gems, not two hundred.

Mark the command `Idempotent = true` on the server, and call it with [`Data.RequestOnce`](/api/Client#RequestOnce) and a key from the client.

```lua
-- server
Data.Command("ClaimDaily", { Idempotent = true }, function(player)
    local data = Data[player]
    if data.LastDaily.Active() then
        return false, "already claimed today"
    end
    data.LastDaily.SetTimed(true, 86400) -- clears itself back to false after a day
    data.Gems.Increment(100)
    return true
end)
```

```lua
-- client
local HttpService = game:GetService("HttpService")

local claimId = HttpService:GenerateGUID(false)
local function claim()
    return Data.RequestOnce("ClaimDaily", claimId)
end

local ok, reason, failed = claim()
if failed == Scribe.RequestFailed and reason == Scribe.RequestReason.Timeout then
    ok, reason = claim() -- same key, so the server replays its first answer
end
```

The server runs the handler at most once per key and answers every repeat with the original reply, byte for byte, including a repeat that arrives while the first call is still yielding. Generate the key once per **intent**, not once per attempt, and reuse it for every retry of that intent.

The requirement is symmetric and enforced. A key sent to a command that is not registered `Idempotent`, or a plain `Data.Request` to one that is, is refused with `bad-idempotency-key` rather than silently downgraded. Keys must be non-empty, valid UTF-8 and at most 64 bytes. They live for the session and die with it, which is also the lifetime of any request that could still be retried. A key is also scoped to the command name, so the same key used on two different commands is two independent entries.

## What the caller gets back on failure

Every framework failure resolves `Data.Request` as three values: `false`, one sentinel string, and the marker table [`Scribe.RequestFailed`](/api/Scribe#RequestFailed).

| Sentinel | Raised by | Means |
| --- | --- | --- |
| `"rate-limited"` | server | the player is over `CommandRateLimit`. The handler never ran. |
| `"unknown-command"` | server | nothing is registered under that name, usually a client on an older build. |
| `"not-ready"` | server | the caller's profile is not `Ready`, so it is still loading or the session already ended. |
| `"bad-args"` | server | the call did not match the `Args` spec, or it carried more arguments than declared. |
| `"bad-idempotency-key"` | server | the key and the command disagree, or the key was empty, over 64 bytes, or not valid UTF-8. The handler never ran. |
| `"error"` | server | the handler threw. The traceback goes to the `COMMAND_ERROR` log and is never sent to the client. |
| `"reply-encode-failed"` | server | the handler succeeded but returned something the wire cannot carry. Its writes stand. |
| `"timeout"` | client | no reply within `RequestTimeout`. The handler may still be running. |
| `"send-failed"` | client | the transport raised while sending the request frame. |
| `"edit-mode"` | client | `RunService:IsRunning()` is false and no mock is registered under that name. |
| `"mock-error"` | client | edit mode, and the registered mock handler threw. |

Those eleven strings are also available as named constants on [`Scribe.RequestReason`](/api/Scribe#RequestReason), so you compare against `Scribe.RequestReason.Timeout` instead of retyping `"timeout"` and getting it subtly wrong. The table is frozen, and the field names are the sentinel strings in PascalCase: `RateLimited`, `UnknownCommand`, `NotReady`, `BadArgs`, `BadIdempotencyKey`, `Error`, `ReplyEncodeFailed`, `Timeout`, `SendFailed`, `EditMode`, `MockError`.

Three failures produce no sentinel and instead raise on the calling thread, because they are caller bugs rather than runtime conditions: passing more than 16 arguments, passing a value the wire cannot encode, and handing `Data.RequestOnce` a key that is empty, over 64 bytes, or not valid UTF-8. The client checks the key before it sends, so the `bad-idempotency-key` sentinel above reaches you only when the command and the key disagree.

!!! warning "The first two values cannot tell you who refused, but the third can"
    A handler's return values reach the caller verbatim. A handler that returns `false, "not owned"` hands the client the same two values as any of the eleven sentinels above, and a handler that returns `false, "timeout"` is byte-identical to Scribe's own timeout. A naive `showToast(reason)` will eventually show an Emberfall player the words `rate-limited`.

    **Read the third return value.** Every framework refusal appends `Scribe.RequestFailed`, a frozen table Scribe owns. Handler values never carry it, because they cross the wire and the wire has no representation for a reference, so a handler that returns a table gets a copy on the other side and can never produce this one.

    ```lua
    local ok, reason, failed = Data.Request("BuyPotion", "Health", 3)
    if failed == Scribe.RequestFailed then
        warn(`BuyPotion never ran: {reason}`) -- one of the sentinels above
    elseif not ok then
        showToast(reason)                     -- your handler's reason, safe to show a player
    end
    ```

    The third value is `nil` on success and `nil` whenever the values are the handler's, so a plain `if failed then` is enough unless your own handlers return a third value.

Returning a shape that cannot collide also works, and it is worth it when the handler has more to say than a string. A table is unambiguous on its own, since Scribe's own refusals are always `false` plus a plain string.

```lua
-- server
Data.Command("EquipItem", { Args = { "string" } }, function(player, itemId)
    if not Data[player].Inventory[itemId].Get() then
        return { Ok = false, Reason = "not owned" }
    end
    return { Ok = true }
end)

-- client
local result, reason = Data.Request("EquipItem", "Emberblade")
if type(result) ~= "table" then
    warn(`EquipItem never ran: {reason}`)
    return
end
if not result.Ok then
    showToast(result.Reason)
end
```

## Handlers that yield

A handler runs inside an `xpcall` on the inbound frame thread, so it **may yield**: `task.wait`, a DataStore call, `MarketplaceService`, an ownership check. Nothing on the server bounds how long it takes, and the reply is only sent once the handler returns.

The client is the side with a clock. `Data.Request` arms a timer for `RequestTimeout`, ten seconds by default, and resolves the caller with `false, "timeout"` when it expires. The reply that arrives afterwards finds no waiter and is discarded. No log code fires on either side.

!!! warning "A timeout is not a rollback"
    The handler kept running. Its `Set`, `Increment` and `Insert` calls committed and will save normally. The client was told the command failed while the server durably succeeded, and nothing reconciles the two. On a command that spends Emberfall gems, that is a player who paid and saw an error.

    Keep handlers inside `RequestTimeout`. When a handler has to make a yielding web call whose worst case you do not control, either raise `RequestTimeout` to cover it, or return immediately and deliver the outcome through the replicated data itself with an `Observe` on the field the handler eventually writes.

A handler may yield, but the `Batch` and `Transaction` blocks inside it still must not. See [Session Lifecycle](./lifecycle).

`Data.Request` also yields until the client's first snapshot has arrived before it sends anything, and that wait has no timeout of its own. `RequestTimeout` only starts once the frame is on the wire. For a request fired at startup, gate on [`Data.WaitForData(timeout)`](/api/Client#WaitForData) first if you need the whole call to be bounded.

## Rate limiting

Each player gets a token bucket, sized and refilled at `CommandRateLimit` per second, which defaults to 20. It starts full, so a burst of up to the full allowance passes at once and then drains to the sustained rate.

| Situation | What happens |
| --- | --- |
| Under the limit | the request proceeds normally |
| Over the limit | the reply is `false, "rate-limited"`, `CommandsRateLimited` moves, and `COMMAND_RATE_LIMITED` is logged at most once per second per player |
| 256 rate-limited frames with no 10-second quiet gap | the rejection reply is dropped too, so that caller sits until `RequestTimeout` |
| 10 seconds without a single rate-limited frame | the sustained-flood counter resets to zero |

??? note "Why the limiter goes quiet under a flood"
    The log throttle and the reply cutoff exist for the same reason. This is the one command path an exploiter can drive without bound, and an unthrottled log would evict the diagnostic ring and erase the evidence of the flood itself.

    The metric counters still count every occurrence, so the flood stays visible in [`Scribe.GetMetrics()`](/api/Scribe#GetMetrics) even while the log is quiet.

??? note "The order a request is checked in"
    Each inbound frame runs the same gauntlet on the server. The first gate that rejects sends its sentinel and stops.

    1. **Rate limit.** A token is taken before anything else, so even an unknown name costs one. The arguments are not decoded until every gate below has passed, so a rejected frame costs only its fixed-size header. Arguments are attacker-sized, and decoding one before deciding to reject it is work an exploiter chooses for you.
    2. **Ready gate.** The caller's profile must be `Ready`, which is why `Data[player]` is safe inside a handler with no `WaitForData` first. A profile still loading, or one whose session ended, gives `not-ready` for **every** name, registered or not, so nobody can enumerate your command surface by watching which names answer differently.
    3. **Registry lookup.** No registration under that name gives `unknown-command`.
    4. **`Args` arity**, if the command declared a spec. More arguments than declared is caught here, from the header alone.
    5. **`Args` types**, once the arguments have been decoded.
    6. **The handler**, inside an `xpcall`. A throw is logged as `COMMAND_ERROR` and answered `error`.
    7. **The reply**, encoded and sent.

## In edit mode

With `RunService:IsRunning()` false, in a storybook or the command bar, there is no server to answer. `Data.Request` looks for a handler registered with [`Data.MockCommand`](/api/Client#MockCommand). If there is none it returns `false, "edit-mode"`, and if the mock throws it returns `false, "mock-error"`.

```lua
Data.MockCommand("ToggleMusic", function(on)
    return on
end)
```

A mock handler takes only the arguments, with no leading `player`, since there is no session to attribute it to. `MockCommand` errors outside edit mode, so it cannot leak into a real one.

## Watching commands in production

[`Scribe.GetMetrics()`](/api/Scribe#GetMetrics) counts the whole pipeline: `CommandsReceived` for every decoded frame, then `CommandsRateLimited`, `CommandsRejected` for an unknown name or bad arguments, `CommandsHandled`, and `CommandErrors`. `CommandsDeduped` counts idempotent repeats answered from the cache instead of running the handler again.

The `COMMAND_*` log codes, including which are throttled and which never log at all, are in the [Log Code Reference](./log-codes).

## Where to next

- [Replication & Visibility](./visibility) explains why a client write never leaves the client, which is the reason commands exist.
- [Testing & Edit Mode](./testing) covers mock commands and storybooks in full.
- [Diagnostics](./diagnostics) shows you the counters and logs a misbehaving command produces.
- [Log Code Reference](./log-codes) lists every `COMMAND_*` code and what it means.
- [Scribe Studio](./studio-plugin) has a Commands panel that invokes any registration as any player, with a form built from its `Args` spec.
