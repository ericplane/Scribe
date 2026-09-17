# Contributing to Scribe

## Naming the strings a public API returns

Every string a public API returns is one of two things: a stable identifier a caller branches
on, or text a game shows and may reword. That distinction decides the design; the casing only
follows from it.

| Kind | Casing | Used for | Examples |
| --- | --- | --- | --- |
| State or category | `PascalCase` | a stable value a caller switches on, naming a thing or a condition | `Status`, `LogLevel`, `LogCategory`, `SessionState`, `OpKind`, `Visibility` |
| Status or reason code | `kebab-case` | a stable value a caller switches on, naming what happened to a call or a session; a normal outcome as often as a refusal | `LifecycleReason`, `RequestReason`, `ProductState` |
| Sentence | lower case, spaces, no trailing period | the answer a call gives when it did not proceed, readable as it is: most members are text a game can show a player, the rest are diagnostics for the developer who wrote the call | `PurchaseReason`, `GiftReason` |

Four rules follow from that table.

**Never mix kinds inside one union.** A union whose members are sentences promises that every
member is a sentence, and callers rely on it. If a new refusal has no sensible sentence, that is
a sign it belongs in a different union rather than a sign to add a code to this one.

**For PascalCase unions the member name and the value are the same word.** `Scribe.Status.Healthy`
is `"Healthy"`. They differ only for the code and sentence kinds, where the value is a code or
display text and the member name is the identifier.

**Every union gets a frozen table on `Scribe`**, named after the type it holds, so a caller can
branch on a constant instead of pasting a string. The constant is what makes the value stable: a
game that branches on `Scribe.PurchaseReason.InsufficientFunds` is untouched if the wording ever
moves. `Scribe.Reason` predates this rule and holds `LifecycleReason`; `Scribe.LifecycleReason`
is the same table under the matching name, and both stay.

**A sentence union says which members a player may see.** `"insufficient funds"` is for the
player. `"invalid Cost spec"` is for the developer who wrote the call, and no wording makes it
otherwise. The guide for the call marks each member, and a game shows the player-facing ones and
logs the rest.

The same condition can appear in two unions with two spellings, and that is on purpose.
`Data.PromptPurchase` answers with a `ProductState` code because a shop branches on it, while
`Data.Purchase` and `Data.PromptGift` answer with a sentence because a game shows it; both branch
on the frozen constants either way. What matters is that each union stays internally consistent.

Published strings are not renamed to unify casing. A game that matches them is broken by a rename
and gains nothing from it. A call that needs both a code and a message grows a second return
value beside the sentence rather than changing it.

## Before you open a pull request

Run what CI runs:

```bash
lune run lune/run-tests
stylua --check src test lune addons
selene src test lune addons
```

Specs live in `test/Specs/<topic>/`, one folder per subsystem (`persistence`, `replication`,
`monetization`, `addons` and so on). A new spec goes in the folder of the code it covers; the
runner walks the folders and names the test by the file, so the folder is for the reader. A spec
starts with `local Root = script.Parent.Parent.Parent.Parent`, which is the test place root from
one folder down.

Specs are expected to survive mutation. A spec that passes when the code it covers is broken is
not evidence, so when you add one, break the line it guards and confirm the spec fails.
