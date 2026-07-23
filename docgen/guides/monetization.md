---
sidebar_position: 6
---

# Monetization & Gifting

Scribe's monetization layer lives inside the data service because correct receipt handling needs exactly what Scribe owns: durable saving, player lifecycle, and idempotency. The overriding rule is **never eat Robux**.

## Configuring products and passes

```lua
Products = {
    Coins1000 = { Id = 111, Category = "Currency",
        Grant = function(data) data.Coins.Increment(1000, { Source = "Purchase" }) end },
    GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
},
Passes = { VIP = { Id = 333 } },
```

Scribe binds `MarketplaceService.ProcessReceipt` automatically and runs everything Robux-driven off it: developer-product grants, gifting delivery, idempotency, and the Robux purchase log.

:::caution Already have a `ProcessReceipt`? Set `OwnReceipts = false`
Roblox allows exactly **one** `ProcessReceipt` callback. By default Scribe installs its own, which **silently overrides any receipt handler your game already has** (a second Scribe bundle instead errors loudly at startup). If your game already handles receipts, pick one of these:

- **Let Scribe take over (recommended).** Move your developer products into `Products`, passes into `Passes`, and gifting into [`PromptGift`](/api/Server#PromptGift). Scribe's receipt path survives cross-server hops and offline recipients, which is genuinely hard to get right by hand.
- **Keep your own handler.** Set `OwnReceipts = false`, then call [`Data.TryHandleReceipt(receiptInfo)`](/api/Server#TryHandleReceipt) from your `ProcessReceipt`. It returns a decision for a Scribe product and `nil` for anything else, so you can fall through to your own handling without maintaining a second list of product IDs:

    ```lua
    MarketplaceService.ProcessReceipt = function(receiptInfo)
        local decision = Data.TryHandleReceipt(receiptInfo)
        if decision then
            return decision
        end
        return myOwnHandler(receiptInfo)
    end
    ```

    [`HandleReceipt`](/api/Server#HandleReceipt) is the stricter variant: it answers `NotProcessedYet` for an unknown product, which is right when Scribe owns `ProcessReceipt` but would stall one of **your** purchases in a permanent retry loop if you routed everything through it.

If you set `OwnReceipts = false` and **don't** wire up `HandleReceipt`, everything on the receipt path goes dark: **developer-product grants, `PromptGift` delivery, and the Robux purchase log never fire.** Perk ownership and soft-currency [`Purchase`](/api/Server#Purchase) keep working, since those never touch receipts.
:::

Receipts are **idempotent by `PurchaseId`** and **fail-closed**: `PurchaseGranted` is returned only after the grant is durably committed; otherwise `NotProcessedYet`, so Roblox retries.

## Perks

A **perk** is a saved boolean flag on a player, and it's usually what a developer product or game pass unlocks. A product's `Grants = "VIP"` sets it, as do [`Data.GrantPerk`](/api/Server#GrantPerk) / [`RevokePerk`](/api/Server#RevokePerk) and [gifting](#gifting). Perks persist with the profile and are read through [`Owns`](/api/Server#Owns).

Declaring `Perks` is **optional**, a typo-guard rather than a requirement: granting or checking any perk name works without it. If you do list your perk names, Scribe logs a dev-mode warning (`UNDECLARED_PERK`) when `GrantPerk` or an ownership check names one that isn't in the list, which catches typos early. `RevokePerk` is exempt, since revoking a name you never granted is harmless:

```lua
Perks = { "VIP", "DoubleXP", "StarterPack" },
```

## Ownership

There are two ownership checks, and both pass for a granted perk, an owned game pass, or RobloxPlus. Prefer [`OwnsAsync`](/api/Server#OwnsAsync) by default: on the server it verifies live against `UserOwnsGamePassAsync` whenever the cache does not already say owned, so it is authoritative including for a pass bought moments ago. It still needs a loaded profile, so gate it behind `WaitForData` on join. [`Owns`](/api/Server#Owns) is the non-yielding version for hot paths where the data is already warm, such as a button click or a mid-session gate.

```lua
-- server
if Data.OwnsAsync(player, "VIP") then ... end   -- preferred, verifies live
if Data.Owns(player, "VIP") then ... end         -- fast, non-yielding

-- client
if Data.OwnsAsync("VIP") then ... end            -- preferred, waits for the replicated flag
if Data.Owns("VIP") then storeButton.Visible = false end
```

This matters because perks and gifts resolve the instant a player is Ready, while real game pass ownership is filled by an asynchronous refresh kicked off at load. `Owns` reads that cache, so a genuinely-owned pass can briefly read `false` right after join, and that is the gap `OwnsAsync` closes. Once the cache says owned it is trusted without a re-check, since pass ownership only ever gains within a session. The client version instead waits on a replicated ownership-synced flag.

Gate grants on the **server's** `Owns` or `OwnsAsync`, never the client's. The client versions are only reads of the replicated mirror, so an exploiter can make them return `true` locally; only the server's `OwnsAsync`, backed by `UserOwnsGamePassAsync`, is authoritative. In DevMode, calling either with a key that is not a registered pass, declared perk, or product grant logs `UNKNOWN_OWNS_KEY`, since it would otherwise silently return `false` forever.

### RobloxPlus

`"RobloxPlus"` is a **built-in ownership key**. You never declare it in `Passes` or `Perks`: it is always available and resolves from the player's Roblox subscription, so you can gate a subscriber perk without wiring anything up.

```lua
-- server
if Data.OwnsAsync(player, "RobloxPlus") then
    grantDailyBonus(player)
end

-- client
Data.ObserveOwned("RobloxPlus", function(subscribed)
    subscriberBadge.Visible = subscribed
end)
```

Because it is an ordinary ownership key, it works everywhere the others do (`Owns`, `OwnsAsync`, `ObserveOwned`, `OnOwnershipChanged`, on both realms) and it never triggers the `UNKNOWN_OWNS_KEY` warning. On the server it is read from the live player property, so it is correct even before the ownership cache is populated; the client reads the replicated value.

It is also the one ownership key that reliably changes in **both** directions during a session. Scribe seeds it at load and keeps it current from `Players.PlayerMembershipChanged`, so a player who subscribes or lapses mid-session fires `OnOwnershipChanged` in the matching direction. Game pass ownership, by contrast, only ever gains within a session.

### Reacting to ownership changes

To run something the moment a player gains a pass or perk, react instead of polling. `OnOwnershipChanged` covers every key at once, which is what you want for applying effects on purchase:

```lua
-- server
Data.OnOwnershipChanged:Connect(function(player, key, owned)
    if key == "VIP" and owned then giveVipKit(player) end
end)

-- one specific key, with the current value delivered immediately
local disconnect = Data.ObserveOwned(player, "VIP", function(owned)
    vipDoor:SetEnabled(owned)
end)
```

Both exist on the client too (`Data.OnOwnershipChanged` fires `(key, owned)` for the local player, and `Data.ObserveOwned(key, callback)`), which is the easy way to toggle a "buy" button the instant a purchase completes. Ownership already held when the player joined is the baseline and does not fire.

These cover purchases, grants, gift deliveries, and revokes. They do **not** fire for a game pass refund mid-session, because ownership only ever gains within a session: a cached `true` is never re-verified. A refund is picked up on the player's next join.

## Soft-currency purchases

[`Purchase`](/api/Server#Purchase) is atomic: debit, grant, and log succeed or roll back together. Insufficient funds or a throwing `Grant` leaves everything untouched:

```lua
Data.Purchase(player, {
    Cost = { Path = "Coins", Amount = 45000 },
    Category = "Vehicle", ItemId = "Police01",
    Grant = function(data) data.Vehicles.Insert("Police01") end,
})
```

`Cost.Path` names any numeric field, and the field's declarator does the work: a `Scribe.Int` currency refuses a fractional `Amount`, and its `Min` is the floor the debit may not cross.

For a **fixed** set of currencies, declare them as ordinary fields. A typo in `Cost.Path` then returns `(false, "invalid cost path")` instead of silently debiting somewhere else:

```lua
Wallet = { Gold = Scribe.Int(100, { Min = 0 }), Gems = Scribe.Int(0, { Min = 0 }) },
-- Cost = { Path = "Wallet.Gold", Amount = 30 }   -- 100 -> 70
```

`Cost.Path` may also descend into a [typed container](./templates#typed-containers), which is the right shape when the currency keys are **open-ended** (a data-driven resource catalog, say). Note the trade-off: a `DictOf` accepts *any* string key by design, so `Wallet.Glod` is a valid path rather than an error, and it spends from the element's declared default. That is fine for a catalog whose keys you cannot enumerate, and wrong for a wallet whose currencies you can.

The atomicity also covers a `Grant` that writes into a capped container: an `Insert` past `MaxItems` throws, so the debit rolls back with it and `Purchase` returns `false` plus the error naming the field and the cap. A full inventory is a clean refusal rather than currency taken for an item the player never received.

## Gifting

There's no native "gift a game pass" API, so gifting sells a developer product and grants the recipient a saved **perk**. [`PromptGift`](/api/Server#PromptGift) records a durable intent _before_ money moves, and delivery survives cross-server hops and offline recipients.

```lua
Data.PromptGift(buyer, "GiftVIP", recipientUserId)
```

Recipient ownership is checked twice: at prompt time (refused with `"recipient already owns this"`) **and again at receipt time**. If the recipient acquired the perk while the buyer sat on the purchase dialog, the payment converts to a re-aimable **gift credit** for the buyer instead of a no-op delivery. A pending credit is consumed by a future `PromptGift` with **no charge**.

## Purchase logs

Two capped logs live per player: `Robux` (written only by the receipt path; game code can't forge entries) and `InGame` (yours, via [`RecordPurchase`](/api/Server#RecordPurchase)). Query with [`GetPurchases`](/api/Server#GetPurchases). Both are **server-only by default**; opt into replicating them with `PurchaseLog = { ReplicateRobux = true }` if you want a client purchase-history UI.
