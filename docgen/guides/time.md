# Timers & Cooldowns

Two different questions come up constantly in a game with progression. "Is this buff still running?" and "can this happen again yet?" Scribe answers them with two separate features, and picking the wrong one is the most common mistake on this page.

A [`Scribe.Timed`](/api/Scribe#Timed) field is a **value that expires**. A cooldown is a **gate with no value**.

## The daily reward

Emberfall's `LastDaily` is a timed field. It is `true` while today's reward has been claimed, and it clears itself back to `false` a day later:

```lua
LastDaily = Scribe.Timed(false),
```

```lua
local function claimDaily(player: Player): boolean
    local data = Data.WaitForData(player)
    if not data then
        return false
    end

    local spent = data.LastDaily.Active()
    if spent then
        return false          -- already claimed today
    end

    data.Coins.Increment(250, {
        TransactionType = Enum.AnalyticsEconomyTransactionType.TimedReward,
        ItemSku = "DailyReward",
    })
    data.LastDaily.SetTimed(true, 86400)
    return true
end
```

`SetTimed(value, seconds)` sets the value and arms the timer. When the timer lapses Scribe writes the declared default back and fires `Changed`, so a client `Observe` is all the UI needs:

```lua
Data.LastDaily.Observe(function(spent)
    claimButton.Visible = not spent
end)
```

`Active()` returns two things, so the countdown comes for free:

```lua
local spent, remaining = data.LastDaily.Active()
```

## What a timed field can hold

`Scribe.Timed` wraps a **single leaf value**: a number, a string, a boolean, or a [datatype](./datatypes) declarator. A table is refused at startup with "Scribe.Timed only wraps leaf values", and a container declarator with "Scribe.Timed cannot wrap Scribe.ArrayOf".

So a bundle of buff values that expire together is not a template you can write:

```lua
Boost = Scribe.Timed({ Damage = 2, Speed = 1.5 }),  -- startup error
```

Declare the fields normally and time a single flag beside them, or keep an expiry timestamp on the record and read it yourself.

Two more behaviours to know:

- **Durations floor to 1 second.** Expiries are checked by a once-per-second sweep, so sub-second timers are not possible.
- **Durations cap at a finite value of roughly 126 years**, so `SetTimed(value, math.huge)` means "effectively permanent".

:::caution A plain `Set` does not cancel a running timer
If you `Set` a permanent value while an earlier `SetTimed` is still armed, the old timer still lapses and resets the field to its template default, throwing your value away. To convert a timed value into a permanent one, re-issue `SetTimed(value, math.huge)`, or wait until `Active()` reports false before the plain `Set`.
:::

## Extending a running timer

Emberfall sells an XP boost, and buying a second one while the first is still running should add time rather than restart it:

```lua
XpBoost = Scribe.Timed(false),
```

```lua
if data.XpBoost.Active() then
    data.XpBoost.ExtendTimed(1800)     -- add 30 minutes to what is left
else
    data.XpBoost.SetTimed(true, 1800)  -- arm a fresh 30 minutes
end
```

The `Active()` check matters. `ExtendTimed` with no timer running **arms a fresh one** from now, so a field that was never `SetTimed` starts counting down and reverts to its declared default. `ExtendTimed` never writes the value itself, so unlike `SetTimed` it has nothing to replicate.

## Cooldowns

A cooldown answers "can this happen again yet". There is **no `Cooldown` declarator and no template field**. It is a server-side timer keyed by any string you choose, driven entirely through the API. Reach for it for ability recharges, claim gates, and anything else where you never need to read a value.

```lua
-- OnCooldown CHECKS and ARMS in one call, so call it only at the moment of use.
if not Data.OnCooldown(player, "Dash", 12) then
    performDash(player)   -- it was off; a fresh 12s cooldown is now running
end

-- PeekCooldown is read-only and never arms, so it is safe for UI.
local onCooldown, remaining = Data.PeekCooldown(player, "Dash")

Data.ClearCooldown(player, "Dash")   -- support and testing reset
```

Cooldowns live in the profile server-side, so they survive rejoins and cross-server hops, and they never replicate to the client.

To react the moment one lapses, connect [`OnCooldownEnded`](/api/Server#OnCooldownEnded). A cooldown holds no value, so unlike a lapsing timed field it fires no `Changed`, and this signal is its only expiry notification:

```lua
Data.OnCooldownEnded:Connect(function(player, key)
    if key == "Dash" then
        tellClientDashIsReady(player)
    end
end)
```

One signal covers every cooldown, because keys are arbitrary strings rather than declared fields, so there is no set to subscribe to. It fires within about a second of expiry, and it does **not** fire for cooldowns that lapsed while the player was offline. Read those with `PeekCooldown` at join.

## Which one do I want?

| | `Scribe.Timed` field | Cooldown |
| --- | --- | --- |
| Holds a value | yes | no |
| Declared in the template | yes | no, keyed by a string |
| Replicates to the owner | yes, like any field | never |
| Expiry notification | `Changed` fires with the default | `OnCooldownEnded` |
| Read without side effects | `Get()`, `Active()` | `PeekCooldown` |
| Good for | boosters, buffs, a claimed flag | ability recharges, rate limits |

Emberfall's daily reward is a timed field because the UI shows a claimed state and a countdown. Emberfall's dash is a cooldown because nothing ever needs to read it.

??? note "Counting only the time a player is actually playing"
    Cooldowns count wall-clock time by default, so one armed before logging off keeps running while the player is away. That is what you want for a daily reward. For a cooldown that should only tick down during a session, pass `IncludeOfflineTime = false`:

    ```lua
    Data.OnCooldown(player, "Boost", 3600, { IncludeOfflineTime = false })
    ```

    Scribe stores the remaining seconds rather than a deadline for those, converting on every save. So a server crash costs at most the countdown since the last save, and it can only make the cooldown end slightly late, never early. A key holds one cooldown either way, and `PeekCooldown` and `ClearCooldown` cover both modes.

??? note "Cooldown keys starting with `@` are reserved"
    Scribe stores its own once-guards in the same place cooldowns live, including the [`Data.Purchase` idempotency key](./monetization). A key in the `@` namespace is refused by `OnCooldown`, `PeekCooldown` and `ClearCooldown`, and the reserved ones never reach `OnCooldownEnded`. Any other prefix is yours.

??? note "Why a timed field cannot feed a derived field"
    A timed field lapses on the wall clock rather than on a write, so an expired-but-uncleared timer reads one way in a live session and another way in a stored profile. The same bytes would derive two different values. [`Scribe.Derived`](./derived) therefore refuses a timed input. Store an expiry timestamp in a `Scribe.Int` and derive from that.

    The same reasoning is why `Scribe.Timed` is refused inside a [container](./containers) element shape: a running timer would follow the index rather than the element.

## Where to next

- [Declaring Your Template](./templates) covers the leaf declarators a timed field can wrap.
- [Derived Fields](./derived) explains why a timed value cannot be a derived input.
- [Monetization](./monetization) uses the same cooldown storage for purchase idempotency.
- [Session Lifecycle](./lifecycle) is where a running timer survives a rejoin, and where it does not.
