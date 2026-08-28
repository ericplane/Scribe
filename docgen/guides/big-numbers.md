# Big Numbers

A Luau number stops being exact past `2^53` and stops existing past `1.8e308`. If your game's whole point is a counter that keeps climbing, you will hit both ceilings. `Scribe.Big` is a field that does not.

Reach for one when the *magnitude* is the gameplay. Keep [`Scribe.Int`](/api/Scribe#Int) for anything where every digit has to be exact.

## A currency that outgrows a number

Emberfall's `Coins` and `Gems` are both `Scribe.Int`, and that stays right: the biggest coin total in the game is a few million, and a gem is bought with Robux so every unit has to be exact. Emberfall's prestige mode is where the ceiling shows up. It pays **Essence**, which doubles every reset and passes `2^53` within an evening of play. That field is a [`Scribe.Big`](/api/Scribe#Big):

```lua
Essence = Scribe.Big(0, { Min = 0 }),
Banked  = Scribe.Big(0, { Min = 0 }),   -- Essence carried across a prestige reset
```

Neither field is in the base Emberfall template on [Getting Started](./getting-started). They are the prestige slice, and they are the only two big fields in the game.

```lua
local data = Data.WaitForData(player)

data.Essence.Set("1.5e100")          -- a numeric string, because 1.5e100 is fine but 1e400 is not
data.Essence.Increment("2e99")       --> 1.7e100
data.Essence.Multiply(1.15)          --> 1.955e100, the VIP bonus
data.Essence.Divide(2)               --> 9.775e99, the prestige reset
print(data.Essence.Get():Short())    --> "9.775e99"
```

`Set`, `Increment`, `Decrement`, `Multiply` and `Divide` all accept a plain number, a numeric string like `"1.5e100"`, or another big value. That is one operand rule for the whole surface, so you never have to remember which call takes which.

!!! warning "This trades precision for range on purpose"
    A big carries about 15 significant digits at any magnitude, so `1e20 + 1 == 1e20`. That is the right trade for a currency whose magnitude is the point, and the wrong one for anything audited. Emberfall's `Gems` stay a `Scribe.Int` for exactly that reason: they are bought with Robux, and a lost unit is a support ticket.

## The arithmetic methods

| Method | Second argument | Returns |
| --- | --- | --- |
| `Set(value, replicate?)` | replicate flag | the new value |
| `Increment(delta, tags?)` | [economy tags](./economy) | the new value |
| `Decrement(delta, tags?)` | [economy tags](./economy) | the new value |
| `Multiply(factor, replicate?)` | replicate flag | the new value |
| `Divide(factor, replicate?)` | replicate flag | the new value |
| `Update(fn, replicate?)` | replicate flag | the new value |

Watch the second argument. `Increment` and `Decrement` take economy tags, because they move currency and the [economy log](./economy) wants to know why. `Multiply` and `Divide` take the plain replicate flag every other write takes, because scaling a balance is not a source or a sink.

`Divide` by zero **errors** naming the field, rather than handing back a nil you would then write somewhere. Guard the divisor if it can be player-supplied.

??? note "`Multiply` and `Divide` live on a big field only"
    Both are generated onto `Scribe.Big` fields and nowhere else, and each has its own entry on the [`Value`](/api/Value) reference.

    Calling either on a field that is not a `Scribe.Big` errors with a message naming the field, so `data.Xp.Multiply(2)` tells you `Xp` is not a big field rather than doing something surprising. The same is true of `Add` on a non-set and `Enable` on a non-flags field, covered in [Containers](./containers).

## Working with the value

`Get()` returns a [`BigValue`](/api/BigValue), not a number. It supports `+`, `-`, `*`, `/`, `tostring`, and a handful of methods, and it exposes its mantissa and exponent as `.M` and `.E`:

```lua
local essence = data.Essence.Get()

essence + 5           -- fine, and 5 + essence works too
essence * 2           -- fine
tostring(essence)     --> "1.5e100"
essence:ToNumber()    -- lossy, and saturates to inf past 1.8e308
essence.M, essence.E  --> 1.5, 100
essence:Pow(3)        -- another big: 3.375e300
essence:Log10()       --> 100.17609125905568
```

`:Pow(n)` raises a big to a non-negative integer power and `:Log10()` returns its base-10 logarithm as a plain number. Both are reads, so writing the result goes back through the field like any other value:

```lua
data.Essence.Set(data.Essence.Get():Pow(2))                -- square the balance
local tier = math.floor(data.Essence.Get():Log10() / 3)    -- a prestige tier from the magnitude
```

!!! warning "Comparisons need a big on both sides"
    Luau picks `<` and `<=` by metatable identity, so mixing a big with a plain number throws *"attempt to compare table < number"*. `==` is worse: Luau only consults it when both sides are tables, so `Get() == 5` is silently `false` rather than an error.

    Two big fields compare directly. To test against a constant, convert first:

    ```lua
    if data.Essence.Get() < data.Banked.Get() then end -- OK, both are bigs
    if data.Essence.Get() < 2000 then end              -- THROWS
    if data.Essence.Get():ToNumber() < 2000 then end   -- OK
    if data.Essence.Get() == 5 then end                -- always false, never fires
    if data.Essence.Get():ToNumber() == 5 then end     -- OK
    ```

    There is no public constructor for a standalone big, so a threshold comparison goes through `:ToNumber()`. That is exact while the threshold sits inside the double range, which covers any constant you can write as a literal.

## Showing it to a player

`Scribe.Short(value, decimals?)` is the same renderer as a free function, and it takes a plain number as well as a Big. A balance label should not have to know which numeric type the field was declared as:

```lua
local label = Scribe.Short(data.Coins.Get()) -- "1.50M", Int or Big alike
```

`Scribe.SetShortSuffixes({ "", "K", "M", "B", "T", "aa", "ab" })` replaces the suffix table, because the conventions past `T` diverge. Index 1 is the units tier and must stay empty.
`:Short()` formats for UI, with an optional decimal count that defaults to 2. It uses letter suffixes while it can and falls back to scientific notation once it runs out:

| Value | `:Short()` | `:Short(0)` | `:Short(3)` |
| --- | --- | --- | --- |
| `70` | `"70"` | `"70"` | `"70"` |
| `1500` | `"1.50K"` | `"2K"` | `"1.500K"` |
| `1e9` | `"1.00B"` | `"1B"` | `"1.000B"` |
| `1e40` | `"10.00DDc"` | `"10DDc"` | `"10.000DDc"` |
| `1.5e100` | `"1.5e100"` | `"1.5e100"` | `"1.5e100"` |

`Short(0)` rounds rather than truncates, so `1500` shows as `"2K"`.

```lua
data.Essence.Observe(function(essence)
    essenceLabel.Text = essence:Short()
end)
```

## Bounds

`Min` and `Max` behave as they do on `Scribe.Int`, which means they follow [`BoundsPolicy`](./configuration). The default `"Clamp"` pins the value into range and fires an anomaly, while `"Reject"` throws at the write site. A bound past `1.8e308` has to be a string, because a larger literal is already `math.huge`:

```lua
Essence = Scribe.Big(0, { Min = 0, Max = "1e600" }),
```

Under the default policy, `Decrement`ing a `{ Min = 0 }` field below zero leaves it at `0` instead of erroring, so a "can they afford it?" check is still your job:

```lua
if data.Essence.Get():ToNumber() >= price then
    data.Essence.Decrement(price, {
        TransactionType = Enum.AnalyticsEconomyTransactionType.Shop,
        ItemSku = itemId,
    })
end
```

??? note "Why `Pow` beats a chain of `Multiply` calls"
    `Pow` is exact to the module's 15 digits. A chain of `Multiply` calls is not, because each one rounds. At the default leaderboard `SigFigs`, a repeated-multiply square can produce a different ranking key from the true value from about the fourth power onward. If a result has to rank, raise it in one call.

    Three rules on `Pow`, each because the alternative would be a plausible wrong answer rather than an error:

    - **Non-negative integers only.** `Pow(2.5)`, `Pow(-3)` and `Pow(math.huge)` raise. For a negative power, divide: `Divide(x:Pow(3))`.
    - **`x:Pow(0)` is always `1`**, including `0:Pow(0)`. That is the empty-product convention, and it is what makes `x^0` unconditional.
    - **Overflow saturates**, exactly as `Multiply` already does. A result past the exponent ceiling clamps rather than raising, so there is one rule for the event rather than two.

??? note "`Log10` loses precision as the value grows"
    The integer part of the logarithm *is* the exponent, and it shares one double with the fraction. So `:Log10()` carries about 17 significant digits at `1e0`, 14 at `1e100`, 10 at `1e1000000`, and none at all near the exponent ceiling. For the exact integer part read `.E` directly. The fraction is what `:Log10()` adds.

    It is also total: the logarithm of zero is `-inf` and of a negative value is `nan`, matching what the equivalent plain number does, so a fresh `0` balance needs no special case at the call site.

??? note "Ranking a big field on a leaderboard"
    A `Scribe.Big` field can be a leaderboard stat, ranked exactly rather than through a lossy `number`. That comes with its own rules: values must be non-negative, `SigFigs` decides how many digits the ranking key keeps, and `Scale` is refused. [Leaderboards](./leaderboards) has the details.

## A Big inside a container element

A `Scribe.Big` declared as a field of a container's element shape puts the template past the Luau
type solver's budget. The module reports `Code is too complex to typecheck` at the `Scribe(...)`
call and stops type-checking, which costs you autocomplete and every other diagnostic in that file.

```lua
-- Over budget: a Big inside a record element.
Bees = Scribe.DictOf({ Id = Scribe.String(""), Amount = Scribe.Big(0, { Min = 0 }) }),

-- Fine: the element IS the big.
Bees = Scribe.DictOf(Scribe.Big(0, { Min = 0 })),

-- Fine: a big at a root, or in a plain record.
Essence = Scribe.Big(0, { Min = 0 }),
Wallet = { Essence = Scribe.Big(0, { Min = 0 }) },
```

This is a type-checking limit only. The code runs correctly either way, and nothing about storage
or replication changes.

If you need other fields beside the amount, either use `Scribe.Int` when the values fit under
`2^53`, or keep the amounts in their own `DictOf(Scribe.Big(...))` under the same keys.

## Where to next

- [Declaring Your Template](./templates) covers `Scribe.Int` and `Scribe.Number`, which are the right choice for everything that is not a runaway counter.
- [Containers](./containers) documents `Add`, `Enable` and `Disable`, the other three methods that live on one field kind only.
- [`BigValue`](/api/BigValue) is the reference page for the object `Get()` hands back.
- [Economy Analytics](./economy) explains the tags `Increment` and `Decrement` take.
- [Leaderboards](./leaderboards) ranks a big field without losing digits.
