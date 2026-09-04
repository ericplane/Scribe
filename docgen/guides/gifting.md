# Gifting

Ava wants to buy Ben a gem pack. Roblox has no "gift this to someone else" API, so gifting is really a sale to Ava whose effects land on Ben's profile, and the hard part is making sure that still works when Ben is offline, on another server, or joins next week. Scribe records where a gift is aimed before any Robux moves, and delivers it whenever the recipient turns up.

You need [Monetization](./monetization) first. Gifting reuses the same `Products` you already declared.

## Sending a gift

Any product can be gifted. In Emberfall that is `GemPack100`, which is already in the shared module.

```lua
local ok, reason = Data.PromptGift(ava, "GemPack100", benUserId)
if not ok then
    showToast(ava, reason)
end
```

[`PromptGift`](/api/Server#PromptGift) yields while it writes a durable record of the intent, then shows Ava the Robux prompt. It returns `(boolean, string?)`, and you must handle the `false` branch: refusal here is routine, not exceptional. The default gift cooldown alone is five seconds per sender, so any button a player can double-click will produce one.

Ben receives the product's effects exactly as if he had bought it himself. `GemPack100` has a `Grant`, so his `Gems` go up by 100 the moment delivery lands, wherever he is.

??? note "What `true` does not tell you"
    A `true` return means one of two things: a Robux prompt was shown and nothing has been delivered yet, or a held gift credit was consumed and the gift went out immediately at no charge.

    It never means "Ben has his gems". Ava may close the prompt, and even a completed purchase is delivered asynchronously. To know a gift actually landed, listen for the signal below.

## Reacting to a delivery

Delivery can happen on another server, or out of the offline mailbox on Ben's next join, so a signal is the only correct way to react to one.

```lua
-- server, on the RECIPIENT
Data.OnGiftReceived:Connect(function(player, info)
    -- info = { FromUserId, Product, GiftId }
    announce(player, `A gift from {info.FromUserId}!`)
end)
```

`OnGiftReceived` is the only place the sender and the gift id are available, so use it for the "Ben, Ava sent you this" moment. For a plainer question like "does Ben own VIP now", use [`OnOwnershipChanged` or `ObserveOwned`](./monetization#reacting-to-a-purchase) instead. Those already cover gift deliveries alongside ordinary purchases, whatever route the value took.

## Gift credits

Sometimes Ava's money arrives and there is nobody sensible to give it to. Rather than burn the Robux, Scribe converts the purchase into a **gift credit**: a durable, re-aimable token the buyer keeps. A later `PromptGift` consumes it and charges nothing.

```lua
-- server, on the BUYER
Data.OnGiftCredit:Connect(function(player, productName)
    showToast(player, `Your {productName} gift is unclaimed. Pick someone else.`)
end)
```

Read the balance with [`Data.GetGiftCredits(player)`](/api/Server#GetGiftCredits) on the server or [`Data.GetGiftCredits()`](/api/Client#GetGiftCredits) on the client. Both return a `{ [productName]: count }` map, and credits replicate to their owner by default, so a client gift UI needs no opt-in.

```lua
-- client
for productName, count in Data.GetGiftCredits() do
    print(`{count} unclaimed {productName}`)
end
```

??? note "When a credit is issued instead of a delivery"
    Credits only arise for a **perk** product, meaning one declared with `Grants` and no `Grant`. A product with a `Grant` callback delivers real value to anyone, so there is no such thing as a wasted delivery.

    Two situations produce one. The recipient acquired the perk between the prompt and the receipt, so delivering it would be a no-op: Scribe writes a credit and logs `GIFT_RECIPIENT_ALREADY_OWNS`. Or a perk product was bought with no gift intent at all by a buyer who already owns it, which is `GIFT_CREDIT_ISSUED`.

    The second case is governed by `NoGiftIntentPolicy`. The default, `"GrantOrCredit"`, writes the credit. `"Hold"` declines the receipt instead, so Roblox eventually refunds and no credit is minted. If the buyer already holds an unused credit for that product, the purchase is declined outright rather than stacking a second one.

## Reading the refusal

Ownership is checked twice, at prompt time and again at receipt time, so a race between two gifters cannot double-deliver. That is one of twelve fixed refusals, exported as a frozen table:

| `Scribe.GiftReason` member | The string |
| --- | --- |
| `BuyerDataNotLoaded` | `"buyer data not loaded"` |
| `InvalidRecipient` | `"invalid recipient"` |
| `CannotGiftYourself` | `"cannot gift yourself"` |
| `GiftCooldown` | `"gift cooldown"` |
| `TooManyPending` | `"too many pending gifts"` |
| `DataServicesDown` | `"data services are experiencing issues; try again later"` |
| `RecipientAlreadyOwns` | `"recipient already owns this"` |
| `CreditReserveFailed` | `"could not reserve gift credit; try again later"` |
| `DeliveryFailed` | `"could not deliver gift; try again later"` |
| `DeliveryUnconfirmed` | `"gift delivery could not be confirmed; do not send it again"` |
| `AlreadyPending` | `"a gift of this item is already pending; try again shortly"` |
| `IntentRecordFailed` | `"could not record gift intent; try again later"` |
| `PaidRandomRestricted` | `"paid-random-restricted"` |
| `PolicyPending` | `"policy-pending"` |

The last two belong to a product declared `PaidRandom = true`: the buyer is restricted, or the buyer's or recipient's policy is not known, which for a recipient who is not on this server it never is. [Paid random items](./monetization.md#paid-random-items) has the rule.

```lua
local ok, reason = Data.PromptGift(ava, "GemPack100", benUserId)
if not ok then
    if reason == Scribe.GiftReason.GiftCooldown then
        return                                    -- a double-click, say nothing
    elseif reason == Scribe.GiftReason.RecipientAlreadyOwns then
        showToast(ava, "Ben already has that.")
    else
        showToast(ava, reason)
    end
end
```

??? note "Why one of them tells the player NOT to retry"
    `DeliveryFailed` and `DeliveryUnconfirmed` are both delivery refusals and they are opposites.

    A gift to someone offline or on another server is delivered by committing a message to their profile key. That write can **commit and then lose its answer** -- a timeout on the way back, or the retry loop ending at shutdown -- and Scribe cannot tell that apart from a write that never happened. So it splits the two outcomes. When the delivery provably did not go out you get `DeliveryFailed`, the spent gift credit is handed straight back, and retrying is exactly right.

    **A full inbox is not by itself proof.** The store retries internally, so a refusal can be reported for a message an earlier attempt of the same call already queued. Scribe asks the store whether *any* attempt could have written rather than assuming the refusal speaks for the call, and only the answer `no` earns a refund. Two things reach `DeliveryFailed`: a same-server `Grant` that threw and was rolled back, and an inbox refusal behind which nothing reached storage -- which includes one preceded by throttled requests, because a throttled request is dropped at the queue and never dispatched.

    When it is unconfirmed you get `DeliveryUnconfirmed`, and the credit **stays spent**. That is deliberate. A gift credit carries no id a retry could reuse -- each spend mints a fresh one -- so handing the credit back for a gift that was in fact queued lets the same payment deliver a second time, which the recipient's duplicate check cannot catch. Scribe would rather cost one credit than grant twice. It logs `GIFT_CREDIT_UNCONFIRMED` with the buyer, the product and the recipient so you can reconcile the rare case by hand, and counts `GiftCreditsUnconfirmed`.

    Do not fold the two into one "try again" toast. The retry is the part that double-grants.

Three more refusals exist that cannot be members of the table. Two carry an interpolated value: `unknown product "<name>"` and `purchase prompt failed: <err>`. The third, `"too many unsettled gift purchases; try again later"`, means the buyer's durable aim store is full of gifts whose receipts have not settled yet.

??? note "Why so many of them are about writing something down"
    Four refusals (`DataServicesDown`, `IntentRecordFailed`, `CreditReserveFailed`, and the full aim store) all say the same thing in different words: Scribe could not durably record where this gift was going, so it refused to let money move.

    That ordering is the whole design. The intent is saved **before** the purchase prompt appears, because a receipt from Roblox carries the product id and nothing else. If the record of Ben is lost, the receipt has no recipient and settles to Ava as an ordinary purchase. Refusing a prompt that has not been paid for is far cheaper than compensating a paid gift that went nowhere.

    The one thing Scribe cannot refuse is a receipt that arrives after its intent has aged out. It falls back to a durable **gift aim**, and if even that has expired you get `GIFT_AIM_EXPIRED`, which names the recipient and the product so you can compensate by hand.

## Throttles worth knowing

Gifting is a spam and abuse surface, so it ships throttled. All of these live under [Configuration](./configuration).

| Option | Default | What it bounds |
| --- | --- | --- |
| `GiftCooldown` | 5 seconds | Minimum gap between one sender's prompts. |
| `GiftMaxPending` | 20 | Unresolved intents one sender may hold at once. |
| `GiftIntentTTL` | 3600 seconds | How long an intent stays valid before the receipt falls through to `NoGiftIntentPolicy`. |
| `AllowDuplicateGifts` | `false` | Whether a perk the recipient already owns may be gifted anyway. |
| `NoGiftIntentPolicy` | `"GrantOrCredit"` | What an intentless perk purchase becomes. |

A second gift of the **same** product by the same sender is refused with `AlreadyPending` while a purchase could still be in flight, which is up to two minutes. Intents are keyed by product id, because that is all a receipt carries, so overwriting a live one would deliver Ava's first purchase to her second recipient.

??? note "Why gifting grants a perk rather than a pass"
    There is no API to transfer a game pass, so a "gift VIP" product is a developer product whose `Grants` names a perk. Scribe treats perks and passes as one ownership namespace, so `Owns(ben, "VIP")` is true either way and the rest of your game needs no special case. See [Checking what a player owns](./monetization#checking-what-a-player-owns).

    The consequence to plan for is that a renamed or deleted product strands any gift credits keyed to its old name. Scribe warns at load with `GIFT_CREDIT_UNKNOWN_PRODUCT` and never deletes them, because a credit is money the player already paid. Restore the product entry or rename the key in a migration.

## Where to next

- [Monetization](./monetization) for products, passes, perks and soft-currency purchases.
- [Configuration](./configuration#gifting) for every gifting option and its default.
- [Log Code Reference](./log-codes#gifting) for the fifteen codes the gift path can emit and what each one means.
- [Diagnostics](./diagnostics) for the `GiftPrompts` and `GiftsDelivered` counters.
