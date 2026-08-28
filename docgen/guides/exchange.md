# Exchange

Two players, two baskets, one exchange. Alice gives a blade and 250 coins, Bob gives a shield, and afterwards each item has exactly one owner.

Roblox has no multi-key transaction. Two players are two DataStore keys, and nothing in the platform can commit both together. Scribe does not pretend otherwise, so before any code, here is exactly what this feature promises and what it does not.

## What you get, stated exactly

**Atomic commit at a single verdict key.** One key decides the exchange. Every participant, on every server, on every retry, reads the same answer.

**Zero isolation across the two profiles.** Both players carry on playing throughout. There is no lock, no frozen inventory, no refused write. What they staked has left their inventory, exactly as if handed to a clerk, so they cannot spend it. Everything else is untouched.

**Conservation without a bounded resolution time.** Nothing is ever duplicated or destroyed. An exchange interrupted at the wrong moment can take until the next load to finish, and in the meantime the value sits where the player can see it.

**A bounded attempt.** The attempt itself is time bounded, around twenty seconds, and cancels rather than hanging. A player is never left staring at a frozen exchange window.

That last pair is the honest exchange. The attempt is bounded; the resolution is not. If you need "this exchange completes within N seconds or the money is back", this feature does not give you that and nothing on this platform does.

!!! warning "Same server, both online"
    Both players must be loaded on the same server. Offline and cross-server exchanges still belong to the [durable outbox](./transactions), which is the right shape for one-sided value: a gift, mail, a reward, a bounty payout.

## Declaring what may be exchanged

Nothing is exchangeable until you say so, and Scribe refuses to start if you name something it cannot move safely.

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

There are three kinds of leg.

| Kind | Moves | Declared on |
| --- | --- | --- |
| `Key` | One whole entry of a container | A `DictOf`, `MapOf` (string or integer keyed), `SetOf`, or `ArrayOf` |
| `Qty` | An amount of a balance | A bounded `Scribe.Int` field |
| `Stack` | Part of one stacked entry | A `DictOf` or `MapOf` |

A path names a **top-level field or a container**, never a path inside one.

## Trading part of a stack

Plenty of games store five of an item as one entry with a count on it, and a player trading two of those five is the ordinary case rather than the exotic one. That is a `Stack` leg.

Emberfall's inventory gains two fields for this guide: a `Locked` flag the owner sets, and a
`Reagents` bag whose entries are bare counts.

```lua
Inventory = Scribe.DictOf({
    Qty    = Scribe.Int(1, { Min = 1, Max = 999 }),
    Rarity = Scribe.Enum("Common", RARITIES),
    Locked = false,                       -- the owner marked it untradeable
}, { MaxKeys = 200 }),
Reagents = Scribe.DictOf(Scribe.Int(0, { Min = 0, Max = 999 }), { MaxKeys = 64 }),
```

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

```lua
{ Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 2 }
```

Moving the **whole** stack is the same leg with `Amount` equal to what is held. It removes the key outright rather than leaving a zero behind, so `Stack` replaces `Key` for these containers and you do not need to declare both.

On the receiving side, a key the player does not hold is written fresh at the amount moved. A key they already hold is **merged**: the counts add, and the rest of the entry has to match. Where it does not, the delivery **parks** rather than picking a winner, and the value stays in the player's inbox until it lands or an operator redirects it.

### Both halves of a split have to be a legal stack

If the count field declares a `Min` above one, some splits are illegal even when the player holds plenty. Suppose Emberfall declared `Qty = Scribe.Int(3, { Min = 3, Max = 999 })`, so a stack never drops below three, and a player holds ten Emberblades:

| Move | Leaves | Result |
| --- | --- | --- |
| 2 | 8 | **Refused.** The moved stack would be 2, under the minimum of 3. |
| 8 | 2 | **Refused.** The remainder would be 2. |
| 7 | 3 | Fine. Both halves sit exactly on the floor. |
| 10 | nothing | Fine. The whole entry travels as it stands, so there is no half that can be too small. |

Both refusals happen **before anything moves**, alongside every other basket check, so a refused split costs the players nothing.

It is worth knowing why the **moved** half is checked and not only the remainder, because the answer is not symmetry. Without that check the stake succeeds and the giver is debited, and the delivery then fails for ever: the credit writes a count below `Min`, the default `Clamp` policy rounds it up, and the content check refuses the mismatch it sees. Nothing is lost, because that check holds. But the value parks in the inbox and every retry fails identically, which is a stall with no way out rather than a conservation problem.

### Every field has to be classified, and Scribe will not boot until it is

A split **duplicates** whatever it does not drop. `{ Qty = 5, Rarity = "Rare" }` split by two becomes `{ Qty = 3, Rarity = "Rare" }` and `{ Qty = 2, Rarity = "Rare" }`, and for `Rarity` that is right: it describes the blade, not a resource. Duplicate a field that counts something and it is a mint, and no check inside the exchange can tell the two apart, because the count itself is exactly conserved either way.

Only you know which is which, so `Stack` makes you say:

- **`Identity`** travels with the split. Both halves keep it.
- **`Ignore`** does not travel. The receiver's copy starts at the field's declared default; the giver keeps theirs untouched.

Every declared element field must appear in one of them, or the game **refuses to start** and names the field. That is deliberate: the day you add a field to the element is exactly the day you want to be asked whether it duplicates.

### Ignore works on a whole-entry `Key` leg too

The same problem shows up without stacking. `Locked` is the owner's marker, not a property of the blade, so a traded Emberblade that arrives still locked is wrong.

```lua
Item = { Path = { "Inventory" }, Kind = "Key", Ignore = { "Locked" } },
```

The field is dropped when the item is staked, at the one point where the giver's copy is still readable, and the receiver's copy materialises from the element default. `Ignore` on a `Key` leg is optional: a field you do not list simply travels, which is always conserving.

!!! warning "`Ignore` destroys the field in transit"
    An ignored field does not go anywhere. It is not held, not escrowed, not returned by an abort. Never ignore anything that represents value.

**The allowlist is checked twice, and the second check is the one that protects players.** At startup, every path you declared is proved safe to move, and the game refuses to boot otherwise. On every call, every leg in both baskets is checked against that same list, by path *and* by kind, before a slot is claimed or any value moves. So a client can never name a path you did not declare: the worst it can do is earn a refusal that costs nothing. What that check cannot answer is whether this particular item may move, which is the next section.

**The refusals are startup errors, by name, on purpose.** An exchangeable path that cannot be moved safely is a configuration mistake, and discovering it mid-exchange means discovering it with value already in escrow. Scribe refuses:

| Shape | Why |
| --- | --- |
| A misspelled path | It would otherwise resolve to a parent and exchange a field you never named. |
| A `Qty` field with no declared `Min` | Without a floor a debit stores a negative, and every check passes while currency is minted. |
| A path that reaches THROUGH a container, like `{ "Inventory", "Potion", "Qty" }` | Crediting a key the receiver does not hold seeds the whole element from its declared defaults, so the exchange would mint everything that element declares alongside the thing being moved. Name the container itself. |
| A `Scribe.Number` quantity | Two doubles do not conserve: the debit and the credit differ by a sub-ULP remainder that grows with the balance. Hold a quantity in `Scribe.Int` minor units. |
| A `Scribe.Optional` quantity | There is no balance to credit until something writes the field, so the receiving half would park for ever. |
| An `ArrayOf` whose element carries a datatype | An array leg is staked from the value you name rather than from the store, and a datatype cannot be recorded that way. |
| A `Scribe.Big` quantity | Its arithmetic absorbs a small debit off a large balance, so the leg silently does nothing and reports success. A `Big` may still ride *inside* a exchanged item. |
| `Scribe.Flags`, a derived field | Neither is a movable quantity. |
| A `Stack` element field in neither `Identity` nor `Ignore` | A split duplicates whatever it does not drop, and no per-leg check can see it, because the count is exactly conserved either way. Classify it. |
| A `Stack` on a `SetOf` or `ArrayOf` | A set member is its own value and an array entry has no stable key, so neither has a keyed stack to split. |
| A `Stack` `Count` that is not a bounded `Scribe.Int` | A count is a quantity, and every way a quantity fails to conserve fails identically inside an element. That includes declaring no `Min`: without a floor the split has nothing to check either half against. |
| A name in `Ignore`, `Identity` or `Count` the element does not declare | An `Ignore` that silently ignores nothing is worse than none: the field would look stripped and travel anyway. |
| A `Scribe.Timed` field, anywhere in the subtree | Timed state is keyed by path, so it would resolve to the wrong owner after a move. |
| An `ArrayOf` with `Evict` | `Insert` at the cap destroys an entry with no return value and no error. |
| Anything under `_Scribe` | That is Scribe's own ledger. |

## The allowlist is per path, not per item

The startup check answers "may this *kind of thing* move". It cannot answer "may *this one* move", because Scribe does not know what your flags mean.

An Emberblade with `Locked = true`, a soulbound reward, an item still inside a trade-hold window: each is a path you declared exchangeable, holding an entry your game considers untradeable. **Scribe will move it, and report success.**

Check it on the server, before the basket is built:

```lua
local function legFor(player, itemId)
    local item = Data.Get(player).Inventory[itemId].Get()
    if item == nil then return nil, "you do not have that item" end
    if item.Locked then return nil, "that item is locked" end
    return { Path = { "Inventory" }, Kind = "Key", Key = itemId }
end
```

!!! warning "Never pass client input straight into Attempt"
    The allowlist stops a client naming `Coins` when you only declared `Inventory`. It does not stop a client naming an Emberblade they locked, and it cannot: `Locked` is your field with your meaning.

### Ownership is the same check, from the right tree

The allowlist does not check ownership either, and the fix is not an extra lookup. It is reading the item from **the tree of the player who is giving it**, which is what `legFor` above does:

```lua
-- RIGHT. Reads the giver's own tree, so an item they do not hold reads nil.
local item = Data.Get(player).Inventory[itemId].Get()
if item == nil then return nil, "you do not have that item" end
```

```lua
-- WRONG. A global catalogue knows the Emberblade exists. It does not know whose
-- it is, so any player can name any item id and pass this check.
local item = ItemCatalogue[itemId]
if item == nil then return nil, "no such item" end
```

Both look like validation. Only the first answers the question that matters, and it costs nothing extra, because you have to read the item anyway to check `Locked`.

A leg naming an item the giver does not hold is caught even if you skip this: the escrow refuses rather than staking an empty record. But it is caught *after* a slot is claimed and the counterparty has been told an exchange is starting, so catching it yourself is both cheaper and a better message.

## Making an exchange

```lua
local outcome, why = Data.Exchange.Attempt(alice, {
    { Path = { "Inventory" }, Kind = "Key", Key = "Emberblade" },
    { Path = { "Coins" },     Kind = "Qty", Amount = 250 },
}, bob, {
    { Path = { "Inventory" }, Kind = "Key", Key = "Frostbrand" },
})

if outcome ~= "Committed" then
    return false, why
end
```

`outcome` is `"Committed"`, `"Aborted"`, or `nil` with a reason. **An `Aborted` exchange is a completed operation, not a failure to clean up after**: every basket has been returned to its owner.

A `nil` is one of two things, and the reason tells you which. Either the exchange was **refused before anything moved**, which costs the players nothing: a basket naming a path you never declared exchangeable, a player already in an exchange, an inbox at its cap. Or the attempt **could not establish a verdict**, in which case value is in escrow and the exchange resolves itself on a later load or sweep. Refusals are by far the common case, and every one of them names what it refused.

`Data.Exchange.Open(player)` tells you what a player still has in flight **and what it is holding**, which is what you show them:

```lua
for _, open in Data.Exchange.Open(player) do
    print(open.Id, open.State)   -- "Staked" | "Claimed" | "Delivering"
    for _, leg in open.Staked do print("gave", leg.Kind, leg.Key or leg.Amount) end
    for _, leg in open.Owed do print("owed", leg.Kind, leg.Key or leg.Amount) end
end
```

Use it. Staked value leaves the balance on purpose, the resolution time is not bounded, and this is the only way a game can read the ledger: it is server-only and the accessor refuses reserved-root reads. Without it a stalled exchange looks to the player like their coins vanished.

## What a player sees

While an exchange is in flight, staked items are **gone from the inventory**. That is the design, not a side effect: they are with the clerk, and a player cannot spend what they have handed over. It is also what every trading system in every game does, so it is what players already expect.

If a delivery cannot be applied, the item waits in an inbox and is retried on every load and on a cadence. It is never clamped, evicted, merged or dropped. That covers a container at its cap, a destination key already taken, and for a `Stack` leg a merge that would pass the count's `Max` or land on an entry whose other fields do not match.

## When something goes wrong

Almost always: nothing. An interrupted exchange resolves itself the next time either profile loads, or on the periodic sweep, and both outcomes conserve.

The exception is an exchange whose verdict key cannot be reached at all, or whose records disagree. Then a person decides, with three verbs, and every one of them consults the verdict first:

| Verb | What it does | What it refuses |
| --- | --- | --- |
| `Data.Exchange.Discard(exchangeId)` | Drops an abandoned claim that never took value. | Anything with a verdict, and anything holding staked value. |
| `Data.Exchange.Settle(exchangeId, verdict)` | Forces `"Commit"` or `"Abort"` on an exchange that cannot resolve itself. | A missing verdict argument, and any `Commit` it cannot prove is safe. |
| `Data.Exchange.Redirect(exchangeId, userId, newKey)` | Lands a parked delivery on a different key of the same container. | A different container, a parked entry holding more than one item, and a set. |

!!! warning "`Settle` has no default"
    `Data.Exchange.Settle(exchangeId)` refuses. Guessing `Abort` here would, in exactly the situation the verb exists for, land a fresh Abort against a Commit the other side has already acted on, and leave the two profiles settled in opposite directions. Name the verdict.

### `Commit` is not the peer of `Abort`

A `Commit` tells each profile to drop its escrow, and that is only safe because the counterparty already took a durable copy of it. `Settle` refuses `Commit` in the two cases where it cannot see that copy:

- **When either loaded record holds escrow with no take recorded.** There is nothing to drop it in favour of, so committing would destroy it.
- **When only one side is loaded.** The verdict binds the absent profile too, and this server cannot read it.

Both checks run **before** the verdict is proposed, because the key is permanent: proposing `Commit` and only then discovering it cannot be applied would mark the exchange committed for ever with neither side able to act on it.

`Abort` needs neither check. Returning an escrow to its owner conserves from one side and needs no counterparty at all, which is why it stays available in every state.

### `Redirect` moves one item, never two

A parked entry can hold several items. One new key cannot name several destinations, so pointing them all at it would put every item on the same key: the first lands, the rest can only ever find it occupied, and the original keys are gone. `Redirect` refuses a parked entry holding more than one key leg rather than collapsing it.

**`Stack` legs count here too.** A parked entry holding one `Key` leg and one `Stack` leg is still two destinations, so it is refused for the same reason. A `Stack` leg on its own redirects normally, and the new key gets the ordinary delivery decision: vacant means a fresh entry at the amount moved, occupied means a merge on the same terms as any other delivery.

It also refuses a **set**, where the key *is* the value. Re-keying there does not move a delivery, it substitutes a different item, destroying the one that was staked and creating one nobody staked.

### One storage cost worth knowing

**Verdict keys are permanent.** One key per exchange attempt, never deleted. Deleting one can only be justified by knowing both sides settled, and a settled side can revert with no crash at all; deleting in that window is how you manufacture a mixed verdict out of a housekeeping job. Budget for it.

## Rules for your own code

**Do not yield inside a listener on an exchangeable path.** Container listeners fire inside the transaction that triggered them, and a yield rolls that transaction back. See [Containers](./containers).

**Reset owner-relative fields with `Ignore`, not afterwards.** A field like `Locked` describes the owner's relationship to an item rather than the item, so it should not travel. `Ignore` drops it where the item is staked and the receiver's copy starts at the declared default. Clearing it after delivery leaves a window where the receiver holds an item still marked by its previous owner.

**Do not write to a container you captured from `Get()`.** A table handed back by `Get()` is the live one, so putting an item back after it was staked reaches the key with no funnel and no op. Scribe detects it but cannot prevent it. Build a new table and `Set` it.

## Where to next

- [Cross-Key Transactions](./transactions) for one-sided value: gifts, mail, rewards, payouts.
- [Containers](./containers) for the listener rules that matter most here.
- [Diagnostics](./diagnostics) for the `EXCHANGE_` log codes.
