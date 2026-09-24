# Exchange

Use Exchange when two players trade items or currency. This guide trades Alice's Emberblade and 250 coins for Bob's Frostbrand.

You need a server-side `Data` bundle using the [Emberfall template](./emberfall), and both players must be loaded on the same server. Add the configuration below where you create that bundle; run the trade from your server trade handler.

Exchange temporarily holds the offered items outside each player's inventory. This is called **escrow**. If a trade is interrupted, the items stay recorded while Scribe resolves it. Your UI must show pending trades; do not refund or re-grant their contents yourself.

!!! warning "Same server, both online"
    For one-sided gifts or rewards across servers, use the [durable outbox](./transactions). That pattern does not make a two-sided cross-server trade atomic.

## Declaring what may be exchanged

Add `Exchangeable` to your existing bundle configuration. It lists the paths and transfer kinds your game allows. Nothing is exchangeable by default.

```lua
Scribe({
    Template = template,
    Exchangeable = {
        Item  = { Path = { "Inventory" }, Kind = "Key" },
        Money = { Path = { "Coins" },     Kind = "Qty" },
    },
    --[[ ...required fields... ]]
})
```

Here, `Key` moves a whole inventory entry and `Qty` moves some coins. Scribe checks this configuration at startup and refuses unsafe declarations.

## Making an exchange

Only call `Attempt` after both players accept the same offer. Build both baskets on the server: each basket lists what that player **gives**.

Check ownership and game rules first, including locked or soulbound items. The [allowlist](#the-allowlist-is-per-path-not-per-item) checks supported paths; it cannot supply those rules.

```lua
local outcome, why = Data.Exchange.Attempt(alice, {
    { Path = { "Inventory" }, Kind = "Key", Key = "Emberblade" },
    { Path = { "Coins" },     Kind = "Qty", Amount = 250 },
}, bob, {
    { Path = { "Inventory" }, Kind = "Key", Key = "Frostbrand" },
})

if outcome == "Committed" then
    print("Trade committed")
elseif outcome == "Aborted" then
    print("Trade aborted")
else
    warn(`Trade was refused or remains unresolved: {why}`)
    -- Inspect Exchange.Open below; do not refund or start a replacement trade.
end
```

| Outcome | Meaning | What your game should do |
| --- | --- | --- |
| `"Committed"` | The decision is to exchange the baskets. | Show the result, and use `Open` to show any delivery still waiting. |
| `"Aborted"` | The decision is to return the baskets to their original owners. | Show the cancelled trade. Scribe handles returns, including any that must wait. |
| `nil`, with a refusal reason | The attempt was refused before value moved. | Explain the reason, such as an undeclared path or a player already exchanging. |
| `nil`, with an unresolved reason | Scribe could not establish the decision. | Show the pending exchange. Let Scribe resolve it; do not refund or start a replacement. |

**A decision and a delivery are separate.** Even after `"Committed"` or `"Aborted"`, a full inventory or conflicting key can leave a delivery waiting.

`Data.Exchange.Open(player)` returns each pending exchange and the value it holds:

```lua
for _, open in Data.Exchange.Open(player) do
    print(open.Id, open.State)   -- "Staked" | "Claimed" | "Delivering"
    for _, leg in open.Staked do print("gave", leg.Kind, leg.Key or leg.Amount) end
    for _, leg in open.Owed do print("owed", leg.Kind, leg.Key or leg.Amount) end
end
```

Use this server-side result to build your pending-trade UI. The internal ledger is server-only and cannot be read through ordinary reserved-root accessors. Without this UI, held items can look as though they disappeared.

## What you get, stated exactly

- **One shared decision.** A single stored verdict decides the trade. Both players and every retry use that verdict.
- **Players keep playing.** The trade does not freeze either profile. Offered value has left the inventory, so it cannot be spent; other fields remain writable. This means the two profiles are not isolated from other game activity.
- **Value stays recorded.** Interrupted or blocked deliveries wait in escrow or an inbox instead of being duplicated or dropped.
- **Resolution can take time.** Scribe retries on later loads and periodic sweeps. There is no maximum time by which every item must arrive or return.

`Attempt` yields while saving and deciding the trade. It checks a 20-second deadline before proposing a commit, but storage calls and resolution work can take longer. Treat that deadline as a reason to attempt an abort, not a 20-second return guarantee or permission to refund.

## Choosing a leg kind

Each entry in a basket is called a **leg**. Choose its kind by what you want to move:

| Kind | Moves | Declared on |
| --- | --- | --- |
| `Key` | One whole container entry | A `DictOf`, `MapOf` (string or integer keyed), `SetOf`, or `ArrayOf` |
| `Qty` | An amount of a balance | A bounded `Scribe.Int` field |
| `Stack` | Part of one stacked entry | A `DictOf` or `MapOf` |

Name the balance field or container itself. A path cannot reach through a container to one of its entries, such as `{ "Inventory", "Potion", "Qty" }`.

## Trading part of a stack

Use `Stack` to move two Emberblades from an entry holding five. The giver keeps three, and the receiver gets two.

For this example, extend Emberfall's inventory with a `Locked` flag and add a `Reagents` bag of numeric counts:

```lua
Inventory = Scribe.DictOf({
    Qty    = Scribe.Int(1, { Min = 1, Max = 999 }),
    Rarity = Scribe.Enum("Common", RARITIES),
    Locked = false,                       -- the owner marked it untradeable
}, { MaxKeys = 200 }),
Reagents = Scribe.DictOf(Scribe.Int(0, { Min = 0, Max = 999 }), { MaxKeys = 64 }),
```

Replace the corresponding exchange declarations with:

```lua
Exchangeable = {
    Item = {
        Path = { "Inventory" }, Kind = "Stack",
        Count = "Qty", Identity = { "Rarity" }, Ignore = { "Locked" },
    },
    -- A DictOf whose element is a bare number needs nothing declared: the
    -- stored value IS the count, and nothing rides alongside it.
    Reagent = { Path = { "Reagents" }, Kind = "Stack" },
}
```

Then use this leg in a basket:

```lua
{ Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 2 }
```

To move the whole stack, set `Amount` to the held count. Scribe removes the original key rather than leaving a zero-count entry, so you do not also need a `Key` declaration.

At the destination:

- A missing key becomes a new entry with the moved count.
- An existing compatible entry receives the extra count.
- A conflicting entry or a count above `Max` leaves the delivery waiting in the inbox. Scribe calls this a **parked** delivery.

### Both halves of a split have to be a legal stack

Both the moved count and any remainder must meet the count field's minimum. If `Qty` has `Min = 3` and the player holds ten:

| Move | Leaves | Result |
| --- | --- | --- |
| 2 | 8 | Refused: the moved stack is below 3. |
| 8 | 2 | Refused: the remainder is below 3. |
| 7 | 3 | Allowed: both stacks meet the minimum. |
| 10 | nothing | Allowed: the whole entry moves. |

These checks reject an illegal split before debiting that stack. They prevent a split that could be removed from the giver but never legally delivered to the receiver.

### Every field has to be classified, and Scribe will not boot until it is

For a record stack, identify the count with `Count`, then classify every other field:

| Option | When the stack splits | Example |
| --- | --- | --- |
| `Identity` | Both halves keep the value. It must match when stacks merge. | `Rarity` describes the item. |
| `Ignore` | The giver keeps their value; a new receiver entry uses the declared default. The field does not travel. | `Locked` belongs to the owner. |

Do not put another resource counter in `Identity`: splitting would copy it into both halves. Scribe cannot infer which fields represent resources. It refuses to start if a field is unclassified, including when you later add a new one.

### Ignore works on a whole-entry `Key` leg too

You can also reset owner-specific fields when moving a whole entry:

```lua
Item = { Path = { "Inventory" }, Kind = "Key", Ignore = { "Locked" } },
```

Scribe removes `Locked` when the item is staked. The receiving entry uses its declared default. On a `Key` leg, fields not listed in `Ignore` travel with the item.

!!! warning "Ignored fields are not returned on abort"
    `Ignore` removes a field from the transferred payload. Its value is not held in escrow or returned if the trade aborts. Never ignore a field that represents value.

??? note "Unsupported declarations and why startup rejects them"
    Scribe checks declarations at startup, then checks every basket against the approved paths and kinds before claiming a slot. These configurations are rejected:

    | Declaration | Why it is unsafe |
    | --- | --- |
    | A misspelled path | It does not identify a declared field. |
    | A `Qty` field or stack count with no `Min` | A debit needs a floor; a stack split needs a minimum size. |
    | A path through a container, such as `{ "Inventory", "Potion", "Qty" }` | Creating the receiver's entry could also create unrelated default values. Name the container itself. |
    | A `Scribe.Number` quantity | Floating-point rounding can make a debit and credit differ. Use `Scribe.Int` minor units. |
    | A `Scribe.Optional` quantity | An absent balance cannot receive a credit. |
    | A `Scribe.Big` quantity | A small change to a large balance can be rounded away. A `Big` can still travel inside an item. |
    | A `Scribe.Flags` or derived field | It is not a movable quantity. |
    | A `Stack` on `SetOf` or `ArrayOf` | It has no stable keyed stack to split. |
    | A `Stack` count that is not a bounded `Scribe.Int` | It cannot safely represent the split quantity. |
    | A stack field in neither `Identity` nor `Ignore` | Scribe needs to know whether that field is copied or dropped. |
    | An undeclared field name in `Ignore`, `Identity`, or `Count` | A typo could leave a field travelling when you meant to remove it. |
    | A `Scribe.Timed` field anywhere in the moved subtree | Timed state is tied to its original path. |
    | An `ArrayOf` containing a datatype | An array leg identifies its entry by value, which cannot record that datatype safely. |
    | An `ArrayOf` with `Evict` | A full destination could silently evict another entry. |
    | A non-persisted field, such as a session field | Reloading would reset the transferred value. |
    | Anything under `_Scribe` | This is Scribe's own ledger. |

## The allowlist is per path, not per item

`Exchangeable` allows a kind of transfer, such as moving an inventory entry. It does not decide whether a particular item is locked, soulbound, or still in a trade-hold period. **Your server must enforce those rules.**

For example, using the extended inventory above:

```lua
local function legFor(player, itemId)
    local item = Data.Get(player).Inventory[itemId].Get()
    if item == nil then return nil, "you do not have that item" end
    if item.Locked then return nil, "that item is locked" end
    return { Path = { "Inventory" }, Kind = "Key", Key = itemId }
end
```

This helper builds a `Key` leg, so use it with a `Key` declaration. For a stack trade, also validate the requested amount and build a `Stack` leg.

!!! warning "Never pass client input straight into Attempt"
    Build and validate the offer on the server. Scribe's allowlist rejects undeclared paths, but it does not enforce your item restrictions or prove that both players accepted the offer.

### Ownership is the same check, from the right tree

Read the item from the **giver's data**, as `legFor` does:

```lua
-- RIGHT. Reads the giver's own tree, so an item they do not hold reads nil.
local item = Data.Get(player).Inventory[itemId].Get()
if item == nil then return nil, "you do not have that item" end
```

A catalogue only proves that the item exists in your game:

```lua
-- WRONG. A global catalogue knows the Emberblade exists. It does not know whose
-- it is, so any player can name any item id and pass this check.
local item = ItemCatalogue[itemId]
if item == nil then return nil, "no such item" end
```

Scribe also refuses to stake an item the giver does not hold. Checking ownership yourself catches it before claiming a trade slot and lets you give a clearer message.

## What a player sees

Offered items leave the inventory while the exchange holds them. Show them in a pending-trade view using `Open`, including what the player gave and what they are owed.

A delivery waits if the inventory is full, its key is occupied, or a stack would exceed `Max` or merge incompatible fields. Scribe retries on later loads and periodic sweeps. It does not clamp the amount, evict another item, or drop the delivery. Compatible `Stack` entries can merge normally.

## When something goes wrong

Most interruptions need no manual action: Scribe retries resolution on profile load and on periodic sweeps. Persistent storage failures, conflicting records, or blocked deliveries may need an operator to investigate.

### Recovering trades affected by the v2.4.0 key-length bug

Older builds combined both user IDs and a GUID into a verdict key. For larger user IDs, this exceeded Roblox's 50-character limit and left items held in escrow.

The fixed build uses a GUID for new exchanges and a compatible shorter storage key for affected historical IDs. Existing escrow IDs and valid verdict keys stay intact. Deploy the update across all servers; intact affected records can then resolve through the normal load/sweep recovery. Do not delete escrow records or manually replace the held items, because later recovery could deliver them again. Conflicting or damaged records still require investigation.

These server-side recovery tools consult the stored verdict before changing anything. They return `boolean, string?`; check both the success flag and refusal reason.

| Tool | Use it for | Important limit |
| --- | --- | --- |
| `Data.Exchange.Discard(exchangeId)` | An abandoned claim that never took value. | Refuses a claim with a verdict or staked value. |
| `Data.Exchange.Settle(exchangeId, verdict)` | An exchange that cannot resolve itself. Pass `"Commit"` or `"Abort"`. | Requires an explicit verdict and refuses a commit it cannot prove safe. An existing verdict wins. |
| `Data.Exchange.Redirect(exchangeId, userId, newKey)` | A parked item whose original destination key is blocked. | Stays in the same container; refuses sets and entries holding more than one item destination. |

!!! warning "`Settle` has no default"
    `Data.Exchange.Settle(exchangeId)` refuses. Investigate the exchange before choosing `"Commit"` or `"Abort"`; do not guess a decision because the original verdict cannot be reached. Never refund by directly editing the players' balances.

### `Commit` is not the peer of `Abort`

Committing releases each player's escrow because the other player already has a saved copy of what they are owed. `Settle` refuses `"Commit"` when:

- Either loaded record holds escrow without a recorded incoming basket, called a **take**.
- Only one side is loaded, so this server cannot check the other side.

These checks run before proposing the permanent verdict. `"Abort"` returns held value to its original owner and does not need those two checks. It still cannot replace an existing commit.

### `Redirect` moves one item, never two

One new key can identify only one destination. `Redirect` therefore refuses an inbox entry containing multiple `Key` or `Stack` legs, including one of each.

A single `Stack` leg can be redirected. An empty key receives a new stack; an occupied key uses the usual matching-field and count-limit checks.

Sets cannot be redirected: changing a set's key changes the item itself rather than its destination.

### One storage cost worth knowing

Verdict keys are permanent. Budget for a key for each exchange that reaches the verdict store. Do not delete old verdicts as housekeeping: a profile may need the original decision again after restoring older state, even if it previously settled.

## Rules for your own code

- **Do not yield inside listeners on exchangeable paths.** They run inside the transaction that triggered them; yielding rolls it back. See [Containers](./containers).
- **Reset owner-specific fields with `Ignore`.** Clearing them after delivery leaves a window where the receiver sees the previous owner's value. Remember that ignored values are also lost on abort.
- **Do not mutate tables returned by `Get()`.** They are live tables. Direct edits bypass Scribe's write tracking and can recreate an item that was already staked. Scribe can detect this but cannot prevent it. Build a new table and write through `Set` instead.

## Where to next

- [Cross-Key Transactions](./transactions) for one-sided gifts, mail, rewards, and payouts.
- [Containers](./containers) for listener rules.
- [Diagnostics](./diagnostics) for the `EXCHANGE_` log codes.
