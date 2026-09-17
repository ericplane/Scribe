# Cross-Key Transactions

A transaction applies related changes together. If one change fails, it undoes them all. Use one when a shop must take payment and grant an item together.

A transaction covers **one player's data**. Start with the forge example below. The later sections explain gifts and trades between players.

The examples run in a server script with the [Emberfall template](./emberfall). Only call the player functions after `WaitForData` succeeds.

## Quick reference

| Your task | Use |
| --- | --- |
| Take payment and grant something to one player | `Transaction`, then `Flush` to confirm the save; or [`Data.Purchase`](./monetization) |
| Combine several updates into fewer network messages | `Batch` |
| Give something to another player without receiving anything back | A saved transfer record and a message handler that ignores duplicates; see the outbox example below |
| Trade items between two players on this server | [Exchange](./exchange) |
| Trade items between players on different servers | A separate trade protocol; Scribe has no built-in API for this |

## One player, one transaction

Put related writes inside [`Data.Transaction`](/api/Server#Transaction). Call [`Data.Flush`](/api/Server#Flush) afterward to confirm that they were saved.

**The transaction callback must not yield.** Do not call `Flush`, wait for an event, or make a network request inside it.

Emberfall's forge takes 250 `Coins` and hands back an Ember Blade plus a little `Xp`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.EmberfallData).Server

local function forge(player: Player): ("Saved" | "Pending" | "Refused", string?)
    local data = Data[player]

    local ok, err = Data.Transaction(player, function()
        if data.Coins.Get() < 250 then
            error("not enough coins")
        end
        data.Coins.Decrement(250)
        data.Xp.Increment(200)
        data.Inventory["Emberblade"].Update(function(entry)
            local quantity = if entry then entry.Qty else 0
            if quantity >= 999 then
                error("Emberblade stack is full")
            end
            return { Qty = quantity + 1, Rarity = "Rare" }
        end)
    end)

    if not ok then
        return "Refused", err -- nothing changed, the coins are untouched
    end
    if not Data.Flush(player) then
        return "Pending", "The forge applied, but saving is not confirmed yet"
    end
    return "Saved"
end
```

If any write fails, the coins, XP, and inventory all return to their previous values. This includes a full stack or a new inventory entry that exceeds `MaxKeys`.

The `999` check matches the template's stack limit. Update both if that limit changes. Without the check, the quantity could stay at its maximum while the player still pays.

| Result from `forge` | What your game should do |
| --- | --- |
| `Saved` | Show success. The save was confirmed. |
| `Pending` | Show a pending state and retry `Flush`. The purchase already applied. |
| `Refused` | Show the reason. The transaction changed nothing. |

**Do not call `forge` again to retry a pending save.** That starts another purchase.

??? note "Why one player never needs a protocol"

    A session lock gives one server permission to write the profile. ProfileStore checks that permission inside the save operation.

    Each save also writes the whole data tree in one `UpdateAsync`. The coin debit, inventory entry, and XP change therefore share one saved version.

## Commit is not durability

`Transaction` returning `true` means the changes applied in memory. They still need a save. A server crash before that save can lose them.

`Flush` waits for save confirmation. A `true` return confirms the save; a `false` return needs careful handling.

!!! warning "A false Flush means unresolved, not failed"
    `Timeout` limits how long you wait. The save may still complete after `Flush` returns `false`.

    Never undo or repeat the purchase because its flush timed out. Retry `Flush` while the session is still Ready, or inspect the data on the next load.

    To let a client retry the purchase request itself safely, give the operation a stable ID. See [purchase idempotency keys](./monetization#making-a-purchase-idempotent).

    Do not add `Force = true` as a routine retry: it always requests a save and bypasses a blocked [wipe guard](./diagnostics#integrity-guards).

??? tip "Flush is free when there is nothing to save"

    `Flush` returns `true` without a DataStore request when the last save succeeded, nothing has changed since, and no save is in flight. A new grant changes the data, so it still needs a save.

    `Flush(player, { Timeout = 30 })` raises the confirmation wait from its 15-second default.

## Batch, when you only want fewer frames

Use [`Data.Batch`](/api/Server#Batch) to send several changes in one replication flush and notify container listeners once. If a write fails, earlier writes stay applied.

```lua
-- Emberfall's respawn: two stats move, the client redraws once.
Data.Batch(player, function()
    local data = Data[player]
    data.Stats.Deaths.Increment(1)
    data.Stats.Playtime.Increment(60)
end)
```

Use `Transaction` when all changes must succeed together. It already batches its writes, so wrapping it in `Batch` is unnecessary.

| | `Batch` | `Transaction` |
| --- | --- | --- |
| Coalesces replication | yes | yes |
| Rolls back on error | no | yes |
| Return value | none | `(boolean, string?)` |
| May yield inside | yes | no |

??? note "What one Changed pass actually means"

    Changing two fields in `Stats` fires `Stats.Changed` and the root `Changed` once each, with the final state. This applies on the server and client. Each individual field still fires its own `Changed`.

    Container `Changed` passes `(new, old)`. To receive every child write, use [`Value.OnChildChanged`](/api/Value#OnChildChanged), which passes `(key, new, old)` and is never combined.

## When the rule mentions two players

For a gift, the sender gives and the recipient only receives. Save a record of what is owed before sending the message. This saved list of pending transfers is a **durable outbox**.

The sequence is:

1. Remove the coins from the sender and record the transfer in one transaction.
2. Confirm that save with `Flush`.
3. Send the transfer ID and amount to the recipient.
4. Credit the recipient and remember the ID in one transaction. Ignore the same ID on later deliveries.

Step 4 makes delivery **idempotent**: retrying the message does not grant twice.

Use this pattern when order does not matter, such as adding currency, setting a permanent flag, or keeping the highest score. The recipient must be able to accept the full grant. Check any balance or inventory limits before applying it; silently clamping a grant loses value.

!!! warning "This example needs a delivery worker and a retention policy"
    The snippets show how a transfer is recorded and applied. They do not include the worker that resumes pending transfers after a load, or a safe way to prune old transfer IDs. Both need a design before using this in production. Read the retry and retention rules below.

    Register the message handler during server startup, before profiles load. Keep the sender functions on the server and validate who may send, to whom, and how much.

Emberfall needs two extra root fields for it, both [`Scribe.ServerOnly`](/api/Scribe#ServerOnly) because the client does not need this bookkeeping:

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

`Outbox` records transfers removed from Ava's balance whose message send is not yet confirmed. A message may already be queued even if its send returned `false`.

`Credited` records the transfer IDs Ben has applied, along with their application time.

### Ava's side: debit and promise in one write

```lua
local HttpService = game:GetService("HttpService")

local function deliverPending(ava: Player, transferId: string): boolean
    local record = Data[ava].Outbox[transferId].Get()
    if record == nil then
        return true -- already handed off and removed from the outbox
    end
    if not Data.Flush(ava) then
        return false -- keep the same record and ID; its save may still complete
    end
    if not Data.SendMessage(record.ToUserId, {
        Kind = "CoinGift", Id = transferId, Coins = record.Coins,
    }) then
        return false -- a retry sends the same ID, never another debit
    end
    Data[ava].Outbox.Remove(transferId)
    return true
end

local function sendCoins(ava: Player, benUserId: number, amount: number): ("Sent" | "Pending" | "Refused", string?)
    if benUserId <= 0 or benUserId == math.huge or benUserId % 1 ~= 0 then
        return "Refused", "recipient must be a positive finite user ID"
    end
    if amount <= 0 or amount == math.huge or amount % 1 ~= 0 then
        return "Refused", "amount must be a positive finite integer"
    end
    local transferId = HttpService:GenerateGUID(false)

    -- The debit and transfer record will be saved together by deliverPending.
    local ok, reason = Data.Transaction(ava, function()
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

    if not ok then
        return "Refused", reason -- the debit and record both rolled back
    end
    if not deliverPending(ava, transferId) then
        return "Pending", transferId
    end
    return "Sent", transferId
end
```

After the confirmed flush, Ava's saved data records the coins as owed. She can no longer spend them.

| Result from `sendCoins` | Meaning |
| --- | --- |
| `Sent` | The message was saved on the recipient's key. The recipient may not have applied it yet. |
| `Pending` | The outbox record remains. The second return value is its transfer ID. |
| `Refused` | No new transfer was created. The second return value explains why. |

Retry a pending transfer with `deliverPending(ava, transferId)`. **Do not call `sendCoins` again for the same transfer**; it creates a new ID and takes another payment.

Your delivery worker must resume saved outbox records after a load and retry with the same IDs. Use one worker per sender and block overlapping UI submissions for the same request. If the sender leaves, their pending transfers wait until your code can resume them.

Use a bounded retry policy so unresolved transfers become visible to operators. Reaching the limit does not prove delivery failed: keep the record for resolution rather than refunding or deleting it.

### Ben's side: credit and marker in one write

```lua
Data.OnMessage:Connect(function(ben, message)
    if message.Kind ~= "CoinGift" then
        return
    end
    local ok, reason = Data.Transaction(ben, function()
        local data = Data[ben]
        if data.Credited[message.Id].Get() ~= nil then
            return -- already applied, so a redelivery does nothing
        end
        data.Coins.Increment(message.Coins)
        data.Credited[message.Id].Set(os.time())
    end)
    if not ok then
        error(reason or "Coin gift could not be applied") -- retain the message for retry
    end
end)
```

[`Data.SendMessage`](/api/Server#SendMessage) reaches Ben's active server, or queues the message until he next loads. The same transfer can arrive more than once, so the handler saves the credit and its ID together.

Keep these rules:

- **Confirm Ava's save before sending.** Otherwise Ben could keep a credit while Ava's debit is lost in a crash.
- **Save Ben's credit and marker together.** If the marker were saved separately, a crash between the two saves could allow a second credit.
- **Retry an uncertain send with the same ID.** `SendMessage` returning `false` does not always mean nothing was queued. Never use that result alone to refund Ava.
- **Handle a full inbox.** Each recipient can hold 1,000 undelivered messages. Further sends return `false` and log `MESSAGE_QUEUE_FULL`. Keep the transfer pending and retry later.

!!! warning "Do not yield inside an OnMessage handler"
    Do not call `Flush` here. Scribe removes the message only after the handler returns successfully, in the same save that persists its changes. A failed save keeps the message for redelivery.

    If the handler raises, Scribe logs `MESSAGE_HANDLER_ERROR`. If no handler is connected, it logs `MESSAGE_NO_LISTENER`. Both keep the message for the next load. Unacknowledged messages are offered once per session, not once per save.

    A handler waiting on a yield remains unsettled until it returns. Keep the handler short and do its data changes without waiting.

!!! warning "Stopping retries does not make old IDs safe to delete"
    A duplicate may already be in the recipient's queue and arrive much later. Scribe does not expire these messages by age. Deleting its `Credited` entry would let it grant again, even after the sender has stopped retrying.

    This example keeps all markers. At `MaxKeys = 256`, a new marker cannot be inserted, so the transaction rolls back the credit and the handler raises to retain the message. That is a capacity limit to handle before shipping, not a reason to delete arbitrary markers.

    Safe pruning needs a protocol that guarantees an old transfer can no longer be applied. For example, a receiver-enforced expiry would also need a durable way to resolve transfers that expire unpaid. A sender retry window plus a time margin is insufficient. Keep unresolved debt visible, and never refund solely because it is old.

## When both sides give

A trade has a stronger rule than a gift: "I give my Ember Blade only if I receive your Frost Shield." Two independent gifts cannot enforce that rule.

[Exchange](./exchange) handles trades between two players loaded on the same server. It sets aside both offers and uses one recorded outcome to decide where each goes. Start with that guide for a normal trade window.

Scribe has no cross-server trade API. Building one requires more than sending a pair of messages:

- **Each server can check only the data it owns.** Appending a message cannot also require that the recipient still owns an offered item. Both sides need saved commitments and a shared decision.
- **A timeout cannot authorize a refund.** The other side may have received the item despite an error. Reading its data once is also insufficient: it could apply the message just after that read.
- **Intermediate changes remain visible.** Clients can see changes to [`Shared`](./visibility) fields. [Leaderboards](./leaderboards) use a separate store, so rolling back a profile does not roll back an already-written score.
- **Delivery can be delayed.** It depends on the message queue and save round trips. Design a pending state instead of assuming both sides finish within a trade-window countdown.
- **Game rules still need protection.** Validate requests on the server, prevent overlapping spends, and consider what restoring an old profile would do to items already traded away.

!!! warning "A Transaction refuses to leave one player's tree"
    Writing to another player's accessor inside `Data.Transaction` fails the outer transaction. This includes nesting a transaction for the other player. The outer writes roll back and the call returns `(false, error)`; neither player keeps a change from it.

    Nesting or batching cannot make one transaction cover two profiles. Use the outbox pattern for one-sided transfers, or [Exchange](./exchange) for supported trades.

### What you can do today

- **Choose the smallest operation.** A shop affects one player's profile. A gift has one giver. Use a trade protocol only when both sides must give together.
- **Keep ownership in one place where practical.** Some games can record who owns a unique item in one authoritative record. This is a different data design, not something two messages provide automatically.
- **Show pending transfers.** Tell the player which value is waiting, such as "500 coins to Ben: pending". Expose unresolved records to operators too.
- **Resolve the original transfer before returning value.** A return needs a saved decision that prevents the original delivery from applying later, then its own duplicate-safe delivery. Neither a timeout nor a failed send provides that decision. The example above does not implement returns.
- **Limit outstanding transfers.** Cap their count and total value before taking payment. Also limit how many records one sender can aim at a recipient.

## Where to next

- [Exchange](./exchange): trades between two players on one server.
- [Session Lifecycle](./lifecycle): loading, saving, shutdown, and `Flush`.
- [Monetization](./monetization): purchases within one player's data.
- [Gifting](./gifting): Scribe's built-in developer-product gifting flow.
- [Replication & Visibility](./visibility): what clients see during changes.
- [Log Code Reference](./log-codes): messaging errors and warnings.
- [Diagnostics](./diagnostics): save latency and failed flushes.
