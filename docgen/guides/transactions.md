# Cross-Key Transactions

Sooner or later Emberfall gets a feature that sounds like it needs a distributed transaction: a forge, a shop, a gift, a coin transfer between two players. Most of them do not need one. This guide gives you two questions that sort any feature into one of three answers, and the first answer is "you already have it and it already works".

Start by writing down the rule you are afraid of breaking, as one plain sentence. "Coins never go below zero." "The player gets the blade or keeps the coins, never neither and never both." Then count how many players' saved data that sentence mentions. That count is the whole decision.

## One player, one transaction

If the rule mentions only one player's saved data, you are finished before you start. Put the writes inside [`Data.Transaction`](/api/Server#Transaction) and make them durable with [`Data.Flush`](/api/Server#Flush).

Emberfall's forge takes 250 `Coins` and hands back an Ember Blade plus a little `Xp`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.EmberfallData).Server

local function forge(player: Player): (boolean, string?)
    local data = Data[player]

    local ok, err = Data.Transaction(player, function()
        if data.Coins.Get() < 250 then
            error("not enough coins")
        end
        data.Coins.Decrement(250)
        data.Xp.Increment(200)
        data.Inventory["Emberblade"].Update(function(entry)
            return { Qty = if entry then entry.Qty + 1 else 1, Rarity = "Rare" }
        end)
    end)

    if not ok then
        return false, err -- nothing changed, the coins are untouched
    end
    Data.Flush(player)
    return true
end
```

Three writes land together or none of them do. If the `Inventory` write throws because the player is already at `MaxKeys`, the 250 `Coins` come back and the `Xp` goes away with them. The transaction gives you the "or neither" half of the promise. `Flush` gives you the "it survived a server crash" half.

??? note "Why one player never needs a protocol"

    Two properties of the storage layer combine into this.

    The session lock means exactly one server may write a profile key at a time. Scribe's vendored ProfileStore checks session ownership inside the save transform rather than before it, so a second server cannot slip a write in between the check and the write. There is no second writer to race, so a profile never has two divergent versions to reconcile. Reconciling divergent versions is the problem every distributed commit protocol exists to solve, and it does not arise here.

    One save also writes the whole tree. A profile save assigns the entire data table into the key in a single `UpdateAsync`, so everything flushed together lands in one key version whatever part of the tree it touched. A debit at `Coins`, an insert into `Inventory` and an entry in Scribe's own reserved namespace are one atomic durable write, not three.

## Commit is not durability

`Transaction` returning `true` means the writes landed on the player's tree together. It does not mean they are saved. They queue for the next autosave like any other write, and a crash before that loses them. `Flush` is the call that makes them durable, and you want it before you tell the player the forge worked.

`Flush` returns a boolean, and a `false` return is the interesting case.

!!! warning "A false Flush means unresolved, not failed"
    `Timeout` bounds how long you wait for confirmation. It does not bound whether the write happens. A `false` return means the save may still land a moment later.

    Never compensate for a timed out flush by undoing the work. Re-credit the 250 coins, have that save land after all, and the player now owns the Ember Blade *and* the coins. You minted an item out of a network hiccup. Retry the same idempotent operation instead, or show the player a pending state and let the next load tell you the truth. "Unresolved" is a third state alongside committed and not committed, and every durable design on this platform has to carry it.

??? tip "Flush is free when there is nothing to save"

    When the profile is already on disk, meaning nothing was written since the last save, no save is in flight, and that save succeeded, `Flush` returns `true` immediately and spends no DataStore request. That matters for a game that flushes on a checkpoint or a timer. It never applies right after a grant, because a grant leaves the profile dirty by definition.

    `Flush(player, { Force = true })` always goes to the store, and also pushes a save through a blocked wipe guard. `Flush(player, { Timeout = 30 })` widens the confirmation wait from its 15 second default.

## Batch, when you only want fewer frames

[`Data.Batch`](/api/Server#Batch) looks similar and does something different. It coalesces the writes inside it into one replication flush and one container `Changed` pass. It does not roll anything back.

```lua
-- Emberfall's respawn: two stats move, the client redraws once.
Data.Batch(player, function()
    local data = Data[player]
    data.Stats.Deaths.Increment(1)
    data.Stats.Playtime.Increment(60)
end)
```

Reach for `Batch` when you care about network chatter and listener noise. Reach for `Transaction` when you care about all or nothing. A `Transaction` already batches, so you never need both.

| | `Batch` | `Transaction` |
| --- | --- | --- |
| Coalesces replication | yes | yes |
| Rolls back on error | no | yes |
| Return value | none | `(boolean, string?)` |
| May yield inside | yes | no |

??? note "What one Changed pass actually means"

    Coalescing applies to containers. Writing both fields of `Stats` fires the `Stats` and root `Changed` once each with the end state, on the server and on the client. Every individual leaf still fires its own `Changed`, because each leaf is a distinct transition with its own old and new value.

    A container `Changed` carries state rather than a transition, so it takes `(new, old)` and no key. To learn which children moved, use [`Value.OnChildChanged`](/api/Value#OnChildChanged), which takes `(key, new, old)`, is never coalesced, and reports every write.

## When the rule mentions two players

This set is smaller than it looks, because most cross-player features are one sided. A gift, mail, a quest reward, a bounty payout, "send Ben 500 coins". One side gives and the other only ever receives.

Ask the second question: is the effect on the other player's data **monotone**? Adding an item, adding currency, setting a flag that never unsets, taking the max of a score. If it is, arrival order cannot break anything. Two credits landing in either order give the same result, the receiving side never has to check anything, and the whole problem collapses into delivery. Get the message there at least once, and make applying it twice harmless.

That is a durable outbox. Emberfall needs two extra root fields for it, both [`Scribe.ServerOnly`](/api/Scribe#ServerOnly) because no client has any business reading them:

```lua
-- Added to the Emberfall template.
Outbox = Scribe.ServerOnly(Scribe.DictOf({
    ToUserId = Scribe.Int(0, { Min = 0 }),
    Coins    = Scribe.Int(0, { Min = 0 }),
    SentAt   = Scribe.Int(0, { Min = 0 }),
}, { MaxKeys = 16, MaxKeyLength = 40 })),

Credited = Scribe.ServerOnly(Scribe.DictOf(
    Scribe.Int(0, { Min = 0 }),
    { MaxKeys = 256, MaxKeyLength = 40 }
)),
```

`Outbox` holds coins that have left Ava's balance and not yet reached anybody. `Credited` records which transfer ids Ben has already applied, and when he applied them.

### Ava's side: debit and promise in one write

```lua
local HttpService = game:GetService("HttpService")

local function sendCoins(ava: Player, benUserId: number, amount: number): boolean
    local transferId = HttpService:GenerateGUID(false)

    -- The debit and the record of what is owed are ONE durable write.
    local ok = Data.Transaction(ava, function()
        local data = Data[ava]
        if data.Coins.Get() < amount then
            error("not enough coins")
        end
        data.Coins.Decrement(amount)
        data.Outbox[transferId].Set({
            ToUserId = benUserId,
            Coins = amount,
            SentAt = os.time(),
        })
    end)

    -- Flush is the commit point, and the only one.
    if not ok or not Data.Flush(ava) then
        return false -- nothing durable, so nothing is owed; retry from scratch
    end

    -- Deliver. A refused send leaves the record standing, so you retry later.
    if Data.SendMessage(benUserId, { Kind = "CoinGift", Id = transferId, Coins = amount }) then
        Data[ava].Outbox.Remove(transferId)
    end
    return true
end
```

After that flush the 500 coins are neither in Ava's balance nor anywhere else. They are in the record. Never in two places, and never in zero.

### Ben's side: credit and marker in one write

```lua
Data.OnMessage:Connect(function(ben, message)
    if message.Kind ~= "CoinGift" then
        return
    end
    Data.Transaction(ben, function()
        local data = Data[ben]
        if data.Credited[message.Id].Get() ~= nil then
            return -- already applied, so a redelivery does nothing
        end
        data.Coins.Increment(message.Coins)
        data.Credited[message.Id].Set(os.time())
    end)
end)
```

[`Data.SendMessage`](/api/Server#SendMessage) reaches whatever server Ben is on, and queues for him if he is offline. Delivery is at least once, which is exactly why the marker exists.

Three things that pair is doing on purpose.

- **The message points at value, it does not carry it.** The coins are already out of Ava's balance and recorded as owed. A message that is refused, dropped or never read costs nothing, because the record on Ava's key is what makes the debt real.
- **The marker is written by the same transaction as the credit.** Written separately, a crash between them credits again on the redelivery. Written together they are one key version, and there is no "between" to crash into.
- **A refused send is not an error to compensate for.** A recipient holds at most 1,000 undelivered messages. Past that `SendMessage` returns `false` and logs `MESSAGE_QUEUE_FULL`. The record stands, the value is conserved, and you try again later. A refusal does not always prove nothing was written -- the store retries internally, so a message can be queued by an earlier attempt whose answer was lost -- which is exactly why the marker above makes a second delivery a no-op.

Ordering is load bearing. Ava's flush must complete before Ben's tree is touched. Credit durable before debit durable is the canonical duplication bug, and doing it in that order hands the win to anyone who can choose when to disconnect.

??? note "Do not yield inside an OnMessage handler"

    Scribe retires a message from Ben's key only after the handler returns without raising, and only in the same save that persists what the handler wrote. So you do not call `Flush` inside the handler. The credit and the acknowledgement ride the next save together, and a failed save retires nothing, which is what makes redelivery safe.

    A handler that parks on a yield holds that fire open. Nothing is acknowledged, nothing is logged, and the session can end with the message still unsettled. If a handler raises you get `MESSAGE_HANDLER_ERROR`, and if nothing is connected you get `MESSAGE_NO_LISTENER`. Both keep the message for the next load. Redelivery is once per session, not once per save.

??? note "Give the ledger one horizon and derive both ends from it"

    `Credited` cannot grow forever, so it needs a pruning rule, and this is the easiest place in the whole pattern to write a real duplication bug. It happens when the retry window and the memory of having applied something are two independently chosen numbers. Ava is still retrying after Ben has forgotten, the marker is gone, and the second copy is credited.

    Pick one constant, which is how long a sender may keep retrying an `Outbox` record, and derive the recipient's pruning deadline from it as `appliedAt + horizon + margin`. Because a record is always applied at or after the moment it was created, the marker provably outlives the last possible retry of the message that created it. That is a proof rather than a hope, and it costs nothing but the discipline of not writing the second number by hand.

## When both sides give

A trade is the shape where both sides give. Its rule is not conservation, because two independent one sided transfers conserve value perfectly well. Its rule is fairness: "I do not hand over my Ember Blade unless I get the Frost Shield." Fairness is exactly the property two independent transfers lack, and it is the thing the player is actually afraid of.

Scribe has no API for this. What follows is the cost, so you can judge whether to build something above the library.

- **There is no cross key precondition.** The only write that reaches a key another server owns is an unconditional append to that key's message queue. It cannot say "commit only if Ben still has the shield". A precondition can only be checked where the data lives, so each side has to commit to giving before it can learn whether the other side did, and that commitment has to be durable.
- **There is no safe unilateral reclaim.** Once your side's give is durable, taking it back needs proof the other side never took it. A write that errors on this platform may still have committed, so "my delivery failed" is not proof. Reading the other key gives you a snapshot that races a concurrent apply on some other server. Every timer based "give it back after five minutes" is unsound for the same reason. A clock may authorise a refusal. It may never authorise a transfer of value.
- **There is no isolation.** Even a correct protocol buys atomic commit and durability and nothing else. The intermediate state is actively replicated: a client watching a [`Shared`](./visibility) value sees it leave and, on an abort, sees it come back. It also reaches a second store no rollback can touch, because a [leaderboard](./leaderboards) write is an `OrderedDataStore` write with no transaction over it, so `TopLevel` can show a `Level` the profile does not have.
- **It is asynchronous, not live.** Delivery to a player on another server rides the message queue, dispatched inside a save round trip and bounded by the autosave period. That is minutes by default, not a countdown in a trade window.
- **None of it is dupe prevention.** The largest duplication incidents on this platform were application logic bugs: client authoritative item movement, single server check then use races, and operational version restores that re-mint an item already traded away. No storage protocol touches any of them.

!!! warning "A Transaction refuses to leave one player's tree"
    While a `Data.Transaction` is open, a write to a different player's accessor is refused, whether it is a bare write to their data or a nested `Data.Transaction` on them. The refusal fails the enclosing transaction, so its own writes roll back and the call returns `(false, error)`. Nothing lands on either player.

    This is the same rule Scribe applies to a yield inside a transaction, and it exists for the same reason. A rollback cannot reach a different DataStore key, so a write it could never undo must not look as though it is covered. No arrangement of nesting, batching or ordering makes two keys commit together. Use the durable outbox above.

### What you can do today

- **Ask whether it is really symmetric.** A surprising number of trades are one sided in practice. Emberfall's shop is the game selling to the player. A gift, a bounty and a quest reward all have one giver. Split a symmetric trade into two one sided moves against a game owned intermediary and both halves become the outbox you already know how to build.
- **Trade the claim, not the item.** Move an id that names an entitlement and keep the authoritative record of who holds it in one place you control, rather than moving item data between two profiles.
- **Show "unresolved" rather than guessing it.** Render in flight value in the UI. A player who can see "pending: 500 coins to Ben" files a support ticket. A player whose coins silently vanished files a duping report.
- **Never write the compensating undo.** Roll forward instead. If a delivery cannot be applied because the destination is capped or the path no longer exists after a migration, send it back as a new forward delivery. A return is just another one sided transfer, and unlike an undo it cannot race the thing it is reversing.
- **Bound the blast radius.** Cap how much value one player can have in flight, and cap how many records one player can aim at another. Both are refusals you make before anything is written, which is the only place a refusal is free.

## Quick reference

| What you are building | Players the rule names | The answer |
| --- | --- | --- |
| Forge, shop, spend to unlock, ticket redemption | one | `Transaction` then `Flush` |
| `Coins >= 0`, an inventory cap, "afford it first", "grant and log together" | one | `Transaction` then `Flush`, or [`Data.Purchase`](./monetization) |
| Gift, mail, quest reward, bounty payout, "send Ben 500 coins" | two, add only at the far side | durable outbox: record, `Flush`, `SendMessage`, idempotent apply |
| An achievement someone else triggers, a max merge high score | two, monotone | the same outbox |
| Two sided trade, "exactly one owner of this blade", a conserved global supply | two, not monotone | [Exchange](./exchange), for two players on ONE server; otherwise the outbox above |

If you came here to find out whether you need a cross-key transaction, the most likely correct answer is the first row.

## Where to next

- [Session Lifecycle](./lifecycle) for when a profile loads, saves and shuts down, and where `Flush` fits in that timeline.
- [Monetization](./monetization) for `Data.Purchase`, the one player transaction that is already written for you.
- [Gifting](./gifting) for the outbox pattern as Scribe already ships it, escrowed on the buyer's profile.
- [Replication & Visibility](./visibility) for what a client sees while a write is in flight.
- [Log Code Reference](./log-codes) for `MESSAGE_QUEUE_FULL`, `MESSAGE_HANDLER_ERROR` and the rest of the messaging codes.
- [Diagnostics](./diagnostics) for watching save latency and failed flushes in production.
