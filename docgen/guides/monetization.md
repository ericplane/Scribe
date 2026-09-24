# Monetization

Scribe can sell developer products, check game-pass ownership, and spend in-game currency. For developer products, it handles the receipt and confirms the purchase to Roblox only after the grant is saved.

Choose the task you need; you do not need every feature to build a shop:

| Task | Start here |
| --- | --- |
| Sell coins or another repeatable Robux product | [Selling a coin pack](#selling-a-coin-pack) |
| Deliver a product bought outside the game | [External purchases](#external-purchases) |
| Show a purchase dialog | [Prompting the sale](#prompting-the-sale) |
| Spend coins earned in your game | [Soft-currency purchases](#soft-currency-purchases) |
| Check a pass or saved perk | [Checking what a player owns](#checking-what-a-player-owns) |
| Display the player's price | [Showing the price](#showing-the-price) |
| Send a purchase to another player | [Gifting](./gifting) |

Examples use the [Emberfall template](./emberfall). Keep grants on the server, and wait for the player's data before using their accessors.

## Selling a coin pack

Declare your products and passes in the shared module, next to the template. A product's `Grant` receives the buyer's accessor tree.

```lua
Products = {
    CoinPack500 = {
        Id = 1234567890,
        Category = "Currency",
        Grant = function(data)
            data.Coins.Increment(500, {
                TransactionType = Enum.AnalyticsEconomyTransactionType.IAP,
                ItemSku = "CoinPack500",
            })
        end,
    },
},

Passes = { VIP = { Id = 987654321 } },
```

That is the entire setup. When a server script first requires the shared module, Scribe takes over `MarketplaceService.ProcessReceipt`: it grants the coins, writes a Robux purchase-log entry, and waits for the save to confirm before answering `PurchaseGranted`. If it cannot finish, it answers `NotProcessedYet` and leaves the receipt pending. Roblox can retry when the buyer rejoins or starts another developer-product purchase; there is no timed retry loop. See [Roblox's receipt documentation](https://create.roblox.com/docs/reference/engine/classes/MarketplaceService#ProcessReceipt).

### External purchases

Products bought outside your game arrive through the same receipt handler. Register the product in `Products`, keep old handlers in `RetiredProducts`, and start Scribe in every place the buyer can join. If you [keep your own receipt handler](#if-your-game-already-handles-receipts), route these receipts to Scribe too.

If a receipt arrives while the buyer is joining or loading, Scribe waits for their data, then grants and saves normally. The wait uses `LoadTimeout` (120 seconds by default, with a 60-second minimum). Leaving, a failed load, stopping the bundle, or reaching the timeout leaves the receipt pending. A receipt timeout does not cancel the profile load.

**External sales bypass `PromptPurchase` and its eligibility checks.** Only list products that can be delivered without an in-game selection or situation, such as a fixed coin pack. Do not list paid random items or products restricted by a round, location, quantity, or player role. Enable and test external sales through [Roblox's external purchase settings](https://create.roblox.com/docs/production/monetization/developer-products#outside-your-game).

A receipt marked as coming from outside the experience does not consume an unrelated pending gift for the same product. A gift destination already saved for that exact purchase ID still applies. See [gifting](./gifting#external-purchases-and-pending-gifts).

## Prompting the sale

Ask by the name you declared, not the numeric Id. From a client shop button, use the
client API without a player argument:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scribe = require(ReplicatedStorage.Packages.Scribe)
local Data = require(ReplicatedStorage.GameData).Client

buyButton.Activated:Connect(function()
    local prompted, reason, requestFailed = Data.PromptPurchase("CoinPack500")
    if requestFailed == Scribe.RequestFailed then
        warn(`Purchase prompt request failed: {reason}`)
    elseif not prompted then
        warn(`Purchase prompt refused: {reason}`)
    end
end)
```

The client asks the server to prompt a purchase for the local player. The server checks
the registered name, loaded data, ownership, and paid-random policy, then calls Roblox
to open the dialog. The client yields for the result; you do not need to register a
command or write a RemoteEvent handler.

Server scripts can still prompt a chosen player with the existing form, using
`require(ReplicatedStorage.GameData).Server`:

```lua
Data.PromptPurchase(player, "CoinPack500")   -- a product
Data.PromptPurchase(player, "VIP")           -- a pass
```

Both forms resolve the name against `Products` and `Passes`, so a shop button does not
need to know which table an item lives in. The Id stays in one place.

A name declared in **both** tables is a startup error. Resolution is by name, so otherwise the order of two tables would decide what the player is charged for.

**It refuses something the player already owns.** A pass is its own ownership key. A product is checked against its `Grants` perk, and one with no `Grants` is a consumable that can be bought repeatedly. So you do not have to pair every prompt with its own [`Owns`](/api/Server#Owns) check.

An eligibility refusal returns a `Scribe.ProductState` string: `"not-loaded"`, `"owned"`,
`"paid-random-restricted"`, or `"policy-pending"`. Unknown names and engine prompt errors
return diagnostic text. Repeated clicks while the client request is pending return
`"purchase prompt already open"`. The server uses the same refusal while this bundle
has a purchase or gift dialog open for that player, or an unresolved paid gift for the
requested product. This also applies to calls from server code. These refusals do not
raise. See [unresolved gifts](./gifting#one-unresolved-gift-per-product) for cancellation
and receipt-ordering limits.

On the client, a third result equal to `Scribe.RequestFailed` means the request itself
failed, for example with `"timeout"`, `"rate-limited"`, or `"edit-mode"`. Handle that
separately from a shop refusal. See [commands](./commands) for the request failure
codes and [paid random items](#paid-random-items) for checking eligibility before a click.

If the reply times out or is lost, the server may already have opened the prompt.
Scribe does not retry automatically. Calling client `Data.Stop()` cannot cancel a
request already sent to the server.

**`true` means Roblox's prompt call succeeded, not that a purchase succeeded.** Grants,
receipt handling, and the `PurchasePrompts` metric remain on the server. Never grant
an item from this return value or from a client prompt-finished event.

!!! note "You can still prompt it yourself"
    `MarketplaceService:PromptProductPurchase` and `PromptGamePassPurchase` keep working, and Scribe still handles what follows. `Data.PromptPurchase` is the shorter route with name resolution and the ownership check attached.

### A finished pass purchase is confirmed, not trusted

A game pass has no `ProcessReceipt`. The only signal is `PromptGamePassPurchaseFinished`, which reports that the purchase **dialog closed**, not that a transaction completed.

Scribe re-checks ownership before crediting anything. If the check does not confirm it, nothing is credited, no purchase-history entry is written, and `PASS_PURCHASE_UNCONFIRMED` is logged. A genuine purchase the ownership API has not caught up with is credited on the player's next load, because the join scan re-resolves every declared pass.

The reason this matters is not the session cache, which heals itself. It is the purchase history: that is persisted, and an unconfirmed event would have written a permanent record of Robux that may never have been spent.

The meta table on `Increment` is optional. It makes the grant show up in Roblox's economy dashboard, which is worth having for your largest source of currency. See [Economy Analytics](./economy).

???+ warning "A `Grant` must never yield"
    No `task.wait`, no DataStore call, no `MarketplaceService` call inside a `Grant`. Scribe runs the callback inside a transaction so that a `Grant` which throws part-way is rolled back completely, and a transaction cannot survive a yield.

    A product `Grant` that yields is logged as `GRANT_FAIL` and then run anyway, without rollback, because refusing it forever would mean taking the player's Robux and never delivering. If it throws after yielding you get `GRANT_PARTIAL` instead: the writes it already made stand, the receipt settles once, and an operator has to compensate by hand.

    A soft-currency [`Purchase`](/api/Server#Purchase) `Grant` that yields is refused outright. Nothing is debited and nothing is granted.

    Do the async work before you show the prompt, or afterwards from a signal.

## Paid random items

Roblox restricts paid random items for some players and leaves the check to the game. The engine reports the answer per player as `PolicyService:GetPolicyInfoForPlayerAsync(player).ArePaidRandomItemsRestricted`, and the rule covers an item bought with Robux **or with an in-experience currency that Robux can buy**. Declare the entry so Scribe can check eligibility before its purchase and gift prompts:

```lua
Products = {
    LootBox = {
        Id = 1234567890,
        PaidRandom = true,
        Grant = function(data)
            data.Boxes.Increment(1)
        end,
    },
},
```

A pass cannot carry the flag: it grants a fixed perk, so declaring `PaidRandom` on one is a startup error.

`Data.PromptPurchase` refuses a flagged entry for a restricted player, and while the player's policy is not yet known. `Data.Purchase` does the same for a spec carrying `PaidRandom = true`, which is the in-experience currency half of the rule. `Data.PromptGift` refuses a restricted buyer, and a recipient who is not on this server, because a policy can only be read for a Player who is here; an unflagged gift needs nobody present, as before.

A receipt for a flagged product from a restricted player is still granted and logged `PAID_RANDOM_RECEIPT`: the player has already paid, and deferring it does not refund them. Prompts outside Scribe and external sales bypass its pre-purchase checks. Keep paid random products off external listings.

**The policy is read once per player**, off the join path, and only when the bundle declares a flagged entry. Until it lands the entry reads `policy-pending` and the prompt refuses: selling a loot box to a player whose restriction could not be read is the failure the rule exists to prevent. A read that fails is retried three times with backoff, logged `POLICY_READ_FAIL` once, and re-armed at most every 30 seconds by the next check. Unflagged entries never consult it, so an outage cannot refuse an ordinary coin pack.

### Asking before you prompt

`Data.GetProductState(player, name)` answers with one of five strings from `Scribe.ProductState`. Use it to update your shop buttons. `PromptPurchase` checks the state again when called, so still handle its result: ownership or policy may have changed, and opening a prompt can fail.

| `Scribe.ProductState` member | The string | When |
| --- | --- | --- |
| `Purchasable` | `"purchasable"` | none of the below |
| `Owned` | `"owned"` | a pass the player holds, or a product whose `Grants` perk they hold; a consumable is never owned |
| `PaidRandomRestricted` | `"paid-random-restricted"` | flagged, and the player's policy restricts it |
| `PolicyPending` | `"policy-pending"` | flagged, and the policy is not known yet |
| `NotLoaded` | `"not-loaded"` | the player's data is not loaded |

The client has the same call, `Data.GetProductState(name)`, computed from the mirror and the local player's own policy read, and `Data.ObserveProductState(name, callback)` for a button that should repaint when the policy lands or ownership changes:

```lua
Data.ObserveProductState("LootBox", function(state)
    buyButton.Active = state == Scribe.ProductState.Purchasable
    buyButton.Text = if state == "paid-random-restricted" then "Not available" else "Buy"
end)
```

The client state helps you draw the button; the server checks eligibility again when
the client calls `PromptPurchase`. If the client's policy read fails it shows
`policy-pending`. An unknown name raises from `GetProductState` and is refused without
raising by `PromptPurchase`. Request failures, an already-open dialog, and an engine
prompt error are separate from eligibility, so `GetProductState` does not predict them.

??? note "Testing it"
    `GetPolicyInfoAsync` in the options is a seam for the policy read on both realms, in the shape of `GetProductInfoAsync`. Hand it a function returning `{ ArePaidRandomItemsRestricted = true }` to render the restricted button in a storybook or a headless test.

## Showing the price

A shop button with `100 R$` baked into it is wrong for a large share of your players, and wrong in the direction that confuses them: they are charged less than the number on the button and cannot tell why. Two discounts move it, independently of each other.

- **Roblox Plus** takes 10% off for a subscriber's first two months and 20% from the third. Roblox covers it, so your earnings per sale do not change.
- **Regional pricing** puts a player anywhere between 30% and 100% of your listed price, based on their economic location.

Ask on the client, by the name you declared:

```lua
-- In a LocalScript
local price = Data.GetPrice("VIP")
```

The first call starts the read and returns `nil`; the value lands a moment later. [`Data.GetPriceAsync`](/api/Client#GetPriceAsync) is the yielding form when you would rather wait than poll. For UI, observe it rather than polling:

```lua
local disconnect = Data.ObserveProductInfo("VIP", function(info)
    if info == nil then
        label.Text = "..."
        return
    end
    label.Text = `{info.PriceInRobux} R$`
    was.Visible = info.PriceInRobux < info.UserBasePriceInRobux
    was.Text = `{info.UserBasePriceInRobux} R$`
end)
```

`PriceInRobux` is what this player pays. `UserBasePriceInRobux` is the undiscounted price, and `PriceDiscountDetails` lists each discount as `{ Type, Percent, AmountInRobux }`, which is enough to say **why** an item is cheaper instead of just showing a smaller number.

None of this waits for the profile to load, so a shop can price itself during your loading screen.

!!! danger "The server cannot answer this"
    `MarketplaceService:GetProductInfoAsync` takes no player. On a live server it returns the **base catalog price**, which is the one number a discounted player never pays.

    In Studio a server script does get the personalized price, and Roblox has confirmed that as a divergence between Studio and live. So a server-side price cache looks right in Play Solo and is wrong for every discounted player in production. That is why these calls are client-only.

### Warming a shop

Every read fetches on demand, so nothing here is required. If you are about to open a shop with many items, warm them together:

```lua
Data.PrefetchProductInfo()                     -- every declared pass and product
Data.PrefetchProductInfo({ "VIP", "Coins100" })
```

Reads asked for in the same frame are deferred and leave as one burst. The engine's transparent batching only coalesces calls that are in flight together, so twelve buttons mounting at once cost one request rather than twelve. Roblox rate-limits this API without publishing the limit, which is what makes the batching worth having.

### When a read fails

A refused read retries with backoff and then leaves the price `nil`, logging `PRODUCT_INFO_FAIL`. It never falls back to the catalog price: `nil` means "show a placeholder", a number means "this is what they pay". Guessing would reintroduce the mismatch this whole API exists to prevent.

Scribe re-reads on its own the first time the local player's `HasRobloxSubscription` flips, since that moves a Plus discount. It watches once, and the 10% to 20% step at month three does not flip that flag at all, so [`Data.RefreshProductInfo`](/api/Client#RefreshProductInfo) is there for every later move.

## Checking what a player owns

Perks, passes and Roblox Premium all answer to the same key. In Emberfall, `"VIP"` is the pass name, so `Owns(player, "VIP")` is true whether the player bought the pass or was handed the perk by staff.

```lua
-- server
if Data.OwnsAsync(player, "VIP") then
    giveVipKit(player)
end
```

[`OwnsAsync`](/api/Server#OwnsAsync) is the one to reach for by default. If the cache does not already say owned, it re-checks live with `UserOwnsGamePassAsync`, so a pass bought thirty seconds ago is reflected immediately. [`Owns`](/api/Server#Owns) is the non-yielding version for a hot path where the data is already warm, such as a button click mid-session.

Gate a grant on the **server's** check, never the client's. The client's `Owns` and `OwnsAsync` read a replicated mirror, and an exploiter can make a mirror say anything.

`"RobloxPlus"` is built in. You never declare it, and it resolves from the player's Roblox subscription:

```lua
if Data.OwnsAsync(player, "RobloxPlus") then
    Data[player].Coins.Increment(100)
end
```

### Reacting to a purchase

Do not poll. `OnOwnershipChanged` fires for every key, which is what you want when a purchase should change something in the world:

```lua
Data.OnOwnershipChanged:Connect(function(player, key, owned)
    if key == "VIP" and owned then
        openVipDoor(player)
    end
end)
```

For a single key with the current value delivered up front, use [`ObserveOwned`](/api/Server#ObserveOwned). It needs a Ready profile on the server, so put it behind [`WaitForData`](/api/Server#WaitForData). Both signals exist on the client too, and the client versions are the easy way to hide a "buy VIP" button the instant the sale completes.

??? note "The key is the NAME you registered, and it has to be a string"
    `Owns`, `OwnsAsync` and `ObserveOwned` take the name a pass, perk or product grant was
    registered under, not a game-pass id. `Owns(player, 12345)` is a mistake, and so is
    `Owns(player, config.PassName)` when that field is missing.

    Both raise now, naming the API and the type they got. They used to be silent in the
    worst way: a non-string key answered `false`, so an ownership gate denied a player who
    had paid and nothing was logged anywhere.

    Only owned keys are stored. The ownership cache holds a key when the player owns it and
    holds nothing when they do not, rather than writing `false` for every declared pass, so
    what crosses the wire is proportional to what a player actually owns. Every reader tests
    for `true`, so an absent key and a `false` one are the same answer.

??? note "Why `Owns` can say false right after a player joins"
    Perks and gift deliveries resolve the moment a profile is Ready, but real game-pass ownership is filled in by an asynchronous refresh that starts at load. `Owns` reads that cache, so a genuinely-owned pass can read `false` for a moment right after join. `OwnsAsync` closes that gap by verifying live.

    Once the cache says owned it is trusted without re-checking, because pass ownership only ever gains during a session. A refund is picked up on the player's next join, not mid-session.

    `"RobloxPlus"` is the exception that moves both ways. Scribe keeps it current from `Players.PlayerMembershipChanged`, so a player who subscribes or lapses mid-session fires `OnOwnershipChanged` in the matching direction.

??? note "Which monetization calls need a Ready player"
    Four of them error if the profile is not Ready: [`GrantPerk`](/api/Server#GrantPerk), [`RevokePerk`](/api/Server#RevokePerk), [`ObserveOwned`](/api/Server#ObserveOwned), and [`RecordPurchase`](/api/Server#RecordPurchase). Wire those behind [`WaitForData`](/api/Server#WaitForData) rather than calling them straight out of `PlayerAdded`.

    The reading calls are tolerant instead. `Owns`, `OwnsAsync`, `GetPurchases` and `GetGiftCredits` answer `false` or an empty table, and `Purchase` and `PromptGift` refuse with a reason. Tolerant is not the same as correct: a VIP owner reads as a non-owner until their profile lands, so gate ownership logic on readiness too.

## Granting a perk yourself

A perk is a saved boolean on the player. Products set one with `Grants`, and you can set one directly for a contest prize, a support refund, or an admin command:

```lua
Data.GrantPerk(player, "VIP")     -- Owns(player, "VIP") is now true
Data.RevokePerk(player, "VIP")
```

Declaring your perk names is optional and buys you a typo guard:

```lua
Perks = { "VIP" },
```

With the list present, Scribe logs `UNDECLARED_PERK` for a perk name outside it, both at startup (for a product whose `Grants` key is misspelled, which would otherwise surface only after a player has spent Robux) and at grant time. `RevokePerk` is exempt, since revoking a name you never granted is harmless. Ownership checks warn under their own code, `UNKNOWN_OWNS_KEY`.

## Soft-currency purchases

[`Purchase`](/api/Server#Purchase) is the shop-side twin of a product: it debits a currency, runs a grant, and writes a log entry, all or nothing.

```lua
local ok, reason = Data.Purchase(player, {
    Cost = { Path = "Coins", Amount = 250 },
    Category = "Item",
    ItemId = "EmberLantern",
    Grant = function(data)
        data.Inventory.EmberLantern.Update(function(entry)
            local quantity = if entry then entry.Qty else 0
            if quantity >= 999 then
                error("Lantern stack is full")
            end
            return { Qty = quantity + 1, Rarity = "Rare" }
        end)
    end,
})

if not ok then
    if reason == Scribe.PurchaseReason.InsufficientFunds then
        showToast(player, "You need 250 coins to buy a lantern.")
    elseif reason == Scribe.PurchaseReason.DataNotLoaded then
        showToast(player, "Your data is still loading. Try again shortly.")
    else
        warn(`Lantern purchase refused: {reason}`)
        showToast(player, "The purchase could not be completed. Please try again later.")
    end
    return
end

if not Data.Flush(player) then
    showToast(player, "Your lantern was added. Saving is still pending.")
    return -- retry Flush later; do not purchase or grant the lantern again
end
showToast(player, "Lantern purchased and saved!")
```

If the player has 200 coins, nothing happens at all: no debit, no lantern, and `reason` is `"insufficient funds"`. If the `Grant` throws, the debit rolls back with it. There is no window in which the coins are gone and the item is missing.

`Cost.Path` names any numeric field in your template, and that field's declarator does the work. `Coins` is a `Scribe.Int` with `Min = 0`, so a fractional `Amount` is refused and the balance can never go below zero. A path that names no declared field returns `(false, "invalid cost path")` rather than debiting somewhere unexpected. A path that names a field which exists but is not a spendable number -- a `Scribe.Big`, a string, an enum, a container -- is refused too, with `(false, "cost path is not a spendable number")`, so the two mistakes do not read the same. `Scribe.Big` is the one worth calling out: it holds a balance, but `Cost` does plain arithmetic on a plain number, so a Big field cannot be spent from directly.

`Cost.Path` may also point into a typed container, such as a `Scribe.DictOf` key like `"Wallet.Gold"`, and the element's own `Min` floor and int rule apply to the debit exactly as a plain currency field's would. A dictionary accepts any key, though, so a typo there does **not** report an invalid cost path: `"Wallet.Glod"` resolves, spends the element default as a balance nobody granted, and leaves the phantom key behind. Point costs at declared fields unless the currency set is genuinely open-ended.

The grant uses a whole-element `Update` so a repeat purchase adds to the existing quantity. An unwritten entry is `nil`, so the same callback also creates the first lantern. The stack-full check matches the template's maximum of `999`; it prevents charging for a write that would clamp at that limit.

`showToast` represents your game's UI function; keep internal error details in server logs. A successful `Purchase` changes the live profile; the explicit `Flush` above asks for save confirmation before showing a saved result.

!!! danger "A grant that writes through an unresolved key takes the Robux and delivers nothing"

    A container key that names no element is **created** by a write rather than refused. So the obvious way to write an upgrade grant succeeds end to end, even when `itemId` names nothing the player owns:

    ```lua
    -- itemId came from the shop UI, so the player chose it
    Grant = function(data)
        data.Inventory[itemId].Qty.Increment(1) -- no error, ever
    end,
    ```

    The element materialises from its declared defaults, the transaction commits, the profile saves, and the purchase reports success. The player paid, and the item sits on a key no UI will ever show.

    Resolve the id before you spend it. A `Grant` that throws is rolled back in full, so the coins stay in the player's pocket:

    ```lua
    Grant = function(data)
        local quantity = data.Inventory[itemId].Qty.Get()
        if quantity == nil then
            error(`Emberfall: no inventory entry "{itemId}" to upgrade`)
        end
        if quantity >= 999 then
            error("Item stack is full")
        end
        data.Inventory[itemId].Qty.Increment(1)
    end,
    ```

    `Get()` on an unwritten key is `nil` and reading never creates the key, so the check costs nothing. The rule generalises: inside a `Grant`, treat any id that came from a client or from stored data as unresolved until you have checked it. On the receipt path the same mistake costs Robux instead of coins, and the receipt still settles as `PurchaseGranted`.

    In DevMode Scribe warns about the first shape with [`GRANT_SEEDED_ELEMENT`](./log-codes#monetization), naming the product and the path. It is a warning and not a refusal because Scribe cannot tell a dangling id from one you just minted.

### Making a purchase idempotent

A double-clicked button, a re-fired RemoteEvent, or a client that reconnected mid-request will debit twice. Pass an `IdempotencyKey` and the repeat is free:

```lua
local ok, reason = Data.Purchase(player, {
    Cost = { Path = "Coins", Amount = 250 },
    Category = "Item",
    ItemId = "EmberLantern",
    IdempotencyKey = `buy:{orderId}`,   -- your id for this one intent
    Grant = function(data)
        data.Inventory.EmberLantern.Update(function(entry)
            local quantity = if entry then entry.Qty else 0
            if quantity >= 999 then
                error("Lantern stack is full")
            end
            return { Qty = quantity + 1, Rarity = "Rare" }
        end)
    end,
})
if not ok then
    warn(`Purchase refused: {reason}`)
    return
end
if not Data.Flush(player) then
    warn("Purchase applied; save confirmation is pending")
end
```

A repeat under the same key returns exactly what the first call returned and spends nothing. The caller needs no special case: the "this was a duplicate" signal goes to the `PURCHASE_DUPLICATE` log code and the `PurchasesDuplicate` counter, not into the return value. The key is up to 64 bytes of valid UTF-8, and it is yours to choose. Anything stable for one intent and unique across intents will do.

The claim is persisted, so it survives a rejoin, and it is taken inside the transaction, so a `Grant` that throws rolls the claim back and a genuine retry still works.

??? note "What the claims cost, and the two knobs that bound it"
    Two options under [Configuration](./configuration) govern how long the bookkeeping lives.

    `PurchaseClaimTTL` is how long your game's claim is remembered. Its default is seven days (or the legacy `PurchaseIdTTL` setting). Choose a duration covering your own retry window. Completed Roblox receipt IDs are retained separately for a fixed 30 days.

    `MaxPurchaseClaims` caps live claims per profile at 1000. Claims expire on their own, so this only matters for a player buying faster than the TTL drains. Reaching it drops the claim nearest to expiring and logs `PURCHASE_CLAIM_EVICTED`, because a dropped claim means a retry can apply that purchase a second time. If you see it, shorten the TTL rather than raising the cap.

    Claims live in Scribe's own reserved namespace, so they never appear in [`OnCooldownEnded`](/api/Server#OnCooldownEnded) and cannot be cleared with `ClearCooldown`.

### Reading the refusal

`Purchase` returns `(false, reason)` for eight fixed refusals, and Scribe exports them as a frozen table so you can branch on them without pasting strings. Four are for the player; the other four say the call itself is wrong, and belong in a log rather than a toast:

| `Scribe.PurchaseReason` member | The string | For |
| --- | --- | --- |
| `DataNotLoaded` | `"player data not loaded"` | the player, as "try again" |
| `InvalidCostSpec` | `"invalid Cost spec"` | the developer |
| `InvalidCostAmount` | `"invalid Cost amount"` | the developer |
| `InvalidCostPath` | `"invalid cost path"` | the developer |
| `CostPathNotSpendable` | `"cost path is not a spendable number"` | the developer |
| `InsufficientFunds` | `"insufficient funds"` | the player |
| `PaidRandomRestricted` | `"paid random items are not available for this account"` | the player |
| `PolicyPending` | `"cannot check account settings right now; try again in a moment"` | the player |

```lua
local ok, reason = Data.Purchase(player, spec)
if not ok then
    if reason == Scribe.PurchaseReason.InsufficientFunds then
        openCoinShop(player)
    else
        warn(`Emberfall shop refused a purchase: {reason}`)
    end
end
```

Anything outside that table can be your `Grant`'s own error text. Log it for investigation and show a general failure message. The four `Cost` refusals describe mistakes in the purchase definition; the other four describe a player's current ability to buy. Map those to suitable UI text rather than displaying every returned string directly.

## Purchase history

Every player carries two capped logs. The `Robux` log is written only by Scribe, from the receipt path and from completed pass purchases, so game code cannot forge an entry. The `InGame` log is yours, and `Data.Purchase` writes into it automatically.

Add your own entries for anything Scribe did not process, such as a quest reward or a trade:

```lua
Data.RecordPurchase(player, {
    Category = "Quest",
    ItemId = "EmberLantern",
    Currency = "Coins",
    Amount = 0,
    Meta = { Quest = "TheFirstEmber" },
})
```

The entry table is yours to shape. Scribe stamps `Ts` for you if you leave it out, and in DevMode it warns with `UNDECLARED_CATEGORY` when `Category` is not in `PurchaseLog.PurchaseLogCategories`, if you declared that list.

Read both logs back with [`GetPurchases`](/api/Server#GetPurchases), newest first:

```lua
for _, record in Data.GetPurchases(player, { Kind = "Robux", Limit = 10 }) do
    print(record.Ts, record.Product, record.PriceInRobux)
end
```

The filter accepts `Kind`, `Category`, `ItemId`, `Since` and `Limit`, and it is exported as `Scribe.PurchaseFilter`. Every record carries a `Kind` field of `"Robux"` or `"InGame"` so you can render one mixed list.

??? note "Showing purchase history to the player"
    Both logs are server-only by default, and each opts in separately:

    ```lua
    PurchaseLog = { ReplicateRobux = true, ReplicateInGame = true },
    ```

    A client history UI usually wants both. `ReplicateRobux` on its own sends the Robux receipts and leaves out every entry written by `RecordPurchase` and by soft-currency `Purchase`, which is most of what an Emberfall player did.

    `RobuxCap` and `InGameCap` bound each ring at 100 entries by default, oldest dropped.

## If your game already handles receipts

!!! warning "Roblox allows exactly one `ProcessReceipt` callback"
    Scribe installs its own the moment a server script requires the shared module, whenever you have declared any `Products` or `RetiredProducts`. That **silently overrides a receipt handler your game already had**. A pass-only or data-only game is left alone, and a second Scribe bundle errors loudly at startup instead. Assignment order is not a safe fix either: a handler your game assigns afterwards silently wins, and every Scribe product goes dark with no warning.

You have two ways out, and the first is usually better.

**Let Scribe take over.** Move your developer products into `Products`, your passes into `Passes`, and your gifting into [`PromptGift`](/api/Server#PromptGift). Scribe's receipt path already survives cross-server hops and offline recipients, which is genuinely hard to get right by hand.

**Keep your own handler.** Set `OwnReceipts = false` and call [`TryHandleReceipt`](/api/Server#TryHandleReceipt) from your callback. It returns a decision for a Scribe product and `nil` for anything else, so you fall through to your own handling without maintaining a second list of product ids:

```lua
MarketplaceService.ProcessReceipt = function(receiptInfo)
    local decision = Data.TryHandleReceipt(receiptInfo)
    if decision then
        return decision
    end
    return myOwnHandler(receiptInfo)
end
```

If you set `OwnReceipts = false` and then never route receipts to Scribe, everything on the receipt path goes dark: developer-product grants, gift delivery, and receipt-driven Robux log entries. Perks, pass ownership and soft-currency `Purchase` keep working, because none of those touch receipts.

??? note "When to use `HandleReceipt` instead"
    [`HandleReceipt`](/api/Server#HandleReceipt) is the stricter variant. It answers `NotProcessedYet` for an unknown product rather than `nil`, which is right when Scribe owns the callback but would leave one of *your* purchases pending if you routed everything through it.

    Call it yourself only when Scribe is the **last** handler in your chain. That is exactly what the second-bundle startup error asks for: set `OwnReceipts = false` on the secondary bundle and route its receipts through `HandleReceipt`.

??? note "Why a receipt sometimes waits for the player's next session"
    Scribe checks `PurchaseId` against its [retained receipt history](#receipt-history-and-capacity). `PurchaseGranted` is returned only after the grant is durably committed, and `NotProcessedYet` otherwise. Roblox retries on another purchase or a rejoin, not on a timer.

    A buyer still loading on this server gets the bounded wait described under [external purchases](#external-purchases). If the buyer is already absent when handling starts, a perk-only product (`Grants` with no `Grant`) can commit against the offline profile. A `Grant` callback needs a live accessor tree, so for an offline buyer Scribe answers `NotProcessedYet` and waits for Roblox to retry, which may not be until that player's next session.

    Nothing is lost either way. Prefer a perk when delivery timing matters.

## Retiring a product safely

Move a discontinued product from `Products` to `RetiredProducts`, keeping its original name, ID and grant behavior:

```lua
RetiredProducts = {
    OldCoinPack = {
        Id = 1234567890, -- the original developer-product ID
        Grant = function(data)
            data.Coins.Increment(500)
        end,
    },
},
```

Scribe can still finish paid receipts and queued gifts for that product. It is omitted from the client catalog and cannot start a new purchase. Existing paid gift credits remain redeemable through `PromptGift`; without a credit, a retired product is refused. Active and retired products cannot share names or IDs.

Deleting every handler for a paid product leaves its gifts waiting for a later compatible deployment. One unknown gift does not stop other messages, but many retained messages can fill the player's shared inbox. Do not discard those messages just to clear the queue.

## Receipt history and capacity

Scribe keeps completed purchase and gift IDs as `{ Id, At }` records for **30 days**. If Roblox repeats an ID still in history, Scribe confirms the existing grant is saved and returns `PurchaseGranted` again without granting twice.

!!! warning "Protection ends when the record expires"
    Returning `PurchaseGranted` does not prove Roblox recorded the acknowledgement. An unresolved receipt can arrive again, and a retry after its completion record expires can grant twice. This also applies to gifts: a saved destination does not prevent redelivery after the recipient's completion record expires. The 30-day window is Scribe's retention policy, not a Roblox retry cutoff.

Expired records are removed during profile loads and receipt operations. There is no background timer or offline sweep. Existing timestamped records keep their original age; legacy string IDs receive a timestamp when safely migrated on a profile load/write. If the extra timestamp data would exceed Scribe's internal 3.8 MB profile guard, unknown-age strings stay protected until space allows migration. Expired dated records can still be removed.

Before delivering a paid gift, Scribe also saves that receipt's exact recipient on the buyer's profile. If delivery succeeds but the final buyer save fails, a retry still targets the same recipient even after the original gift intent expires or is replaced. These pending `ReceiptReservations` are not age-pruned. The first online delivery needs one additional buyer save; ordinary self-purchases use their existing save path.

The default `MaxReceiptHistoryBytes` is **1 MiB**, a ceiling rather than preallocated space. Admission includes concurrent and reserved grants and checks the current profile size. When full, new grants remain pending with `RECEIPT_HISTORY_FULL`; records within the 30-day window are not evicted to make room. Duplicates still in history remain safe to acknowledge. Raising the limit within available storage can restore admission.

There is no automatic external receipt archive. `PurchaseIdTTL` does not change the fixed 30-day window, and `MaxProcessedPurchaseIds` is ignored. Previously evicted IDs cannot be recovered by this update. Upgrade every place and server that handles these profiles; older servers can still prune history using their earlier policy.

## Where to next

- [Gifting](./gifting) for sending a product to another player, including one who is offline.
- [Economy Analytics](./economy) for getting these purchases onto Roblox's economy dashboard.
- [Cross-Key Transactions](./transactions) for a trade that has to move value between two players at once.
- [Configuration](./configuration) for the full list of monetization and gifting options.
- [Log Code Reference](./log-codes#monetization) for every code the receipt path can emit.
