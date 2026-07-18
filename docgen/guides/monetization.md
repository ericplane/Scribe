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

- **Let Scribe take over (recommended).** Move your developer products into `Products`, passes into `Passes`, and gifting into [`PromptGift`](/api/Server#PromptGift). Scribe's receipt path is idempotent by `PurchaseId`, fail-closed (it never returns `PurchaseGranted` until the grant is durably saved, so it can't eat Robux), and it survives cross-server hops and offline recipients. That is genuinely hard to get right by hand, so for most games this is an upgrade over a hand-rolled handler.
- **Keep your own handler.** Set `OwnReceipts = false`, then call [`Data.HandleReceipt(receiptInfo)`](/api/Server#HandleReceipt) from your `ProcessReceipt` for every Scribe-registered product and return its `Enum.ProductPurchaseDecision`. Route only Scribe's product IDs to it: it returns `NotProcessedYet` for a product it doesn't know, which would stall one of your own purchases in a retry loop.

If you set `OwnReceipts = false` and **don't** wire up `HandleReceipt`, everything on the receipt path goes dark: **developer-product grants, `PromptGift` delivery, and the Robux purchase log never fire.** Perk ownership and soft-currency [`Purchase`](/api/Server#Purchase) keep working, since those never touch receipts.
:::

Receipts are **idempotent by `PurchaseId`** and **fail-closed**: `PurchaseGranted` is returned only after the grant is durably committed; otherwise `NotProcessedYet`, so Roblox retries.

## Perks

A **perk** is a saved boolean flag on a player, and it's usually what a developer product or game pass unlocks. A product's `Grants = "VIP"` sets it, as do [`Data.GrantPerk`](/api/Server#GrantPerk) / [`RevokePerk`](/api/Server#RevokePerk) and [gifting](#gifting). Perks persist with the profile and are read through [`Owns`](/api/Server#Owns).

Declaring `Perks` is **optional**, a typo-guard rather than a requirement: granting or checking any perk name works without it. If you do list your perk names, Scribe logs a dev-mode warning whenever you reference one that isn't in the list, which catches typos early:

```lua
Perks = { "VIP", "DoubleXP", "StarterPack" },
```

## Ownership

[`Owns`](/api/Server#Owns) is the unified check. It passes for a granted perk **or** a real game pass (cached) **or** RobloxPlus:

```lua
if Data.Owns(player, "VIP") then ... end        -- server
if Data.Owns("VIP") then storeButton.Visible = false end  -- client
```

`Owns` is **non-yielding**: perks and gifts resolve the instant a player is Ready, but real game-pass ownership is filled by an asynchronous `UserOwnsGamePassAsync` refresh kicked off at load, so a genuinely-owned pass can briefly read `false` in the window right after join. For a gate that must be correct _at that instant_ (e.g. deciding a spawn loadout), use the yielding [`OwnsAsync`](/api/Server#OwnsAsync), which waits for that refresh:

```lua
if Data.OwnsAsync(player, "VIP") then ... end  -- server, waits for sync
if Data.OwnsAsync("VIP") then ... end          -- client, waits for the flag
```

The client version awaits a replicated "ownership synced" flag, so it never reports a pass un-owned before the server's ownership data has arrived. In DevMode, calling either with a key that isn't a registered pass, declared perk, or product grant logs `UNKNOWN_OWNS_KEY` (it would otherwise silently return `false` forever).

## Soft-currency purchases

[`Purchase`](/api/Server#Purchase) is atomic: debit, grant, and log succeed or roll back together. Insufficient funds or a throwing `Grant` leaves everything untouched:

```lua
Data.Purchase(player, {
    Cost = { Path = "Coins", Amount = 45000 },
    Category = "Vehicle", ItemId = "Police01",
    Grant = function(data) data.Vehicles.Insert("Police01") end,
})
```

## Gifting

There's no native "gift a game pass" API, so gifting sells a developer product and grants the recipient a saved **perk**. [`PromptGift`](/api/Server#PromptGift) records a durable intent _before_ money moves, and delivery survives cross-server hops and offline recipients.

```lua
Data.PromptGift(buyer, "GiftVIP", recipientUserId)
```

Recipient ownership is checked twice: at prompt time (refused with `"recipient already owns this"`) **and again at receipt time**. If the recipient acquired the perk while the buyer sat on the purchase dialog, the payment converts to a re-aimable **gift credit** for the buyer instead of a no-op delivery. A pending credit is consumed by a future `PromptGift` with **no charge**.

## Purchase logs

Two capped logs live per player: `Robux` (written only by the receipt path; game code can't forge entries) and `InGame` (yours, via [`RecordPurchase`](/api/Server#RecordPurchase)). Query with [`GetPurchases`](/api/Server#GetPurchases). Both are **server-only by default**; opt into replicating them with `PurchaseLog = { ReplicateRobux = true }` if you want a client purchase-history UI.
