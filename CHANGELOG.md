# Changelog

## 2.1.0

Released 2026-08-28.

This release adds exchanges: two players who are both loaded on the same server hand over two baskets
of value, and one verdict decides both sides, so nothing is duplicated or destroyed. It also adds
`Data.PromptPurchase`, confirms a finished game pass purchase before crediting it, and adds the
measurements a game needs to tell what Scribe costs it in a running server. Scribe's reserved root
gained two subkeys for the exchange ledger, which changes the schema hash the two realms compare
during the handshake, so the server and the client must be deployed together, even by a game that
declares nothing exchangeable. The largest fix is that a generalized `for` loop over an accessor used
to empty the container it was reading.

### Behaviour changes

- Scribe's reserved `_Scribe` root gained two subkeys, `Exchange` for a trade while it is in flight
  and `ExchangeInbox` for value that has settled to a player but has not been delivered onto a game
  path yet. Both realms fold that root into the schema hash they compare during the handshake, so a
  client built from 2.0.0 and a server built from 2.1.0 derive different hashes, the server logs
  `SCHEMA_MISMATCH` and refuses to replicate to that client. Deploy the server and the client
  together. The wire protocol version itself is unchanged, so on a mixed deploy the server loads and
  saves normally while the player's client copy of the data never arrives and stays at template
  defaults.

- The `ResetData` option now refuses to wipe a profile that holds an in-flight or undelivered
  exchange. The load reports `EXCHANGE_RESET_REFUSED` at Error, naming how many of each the profile
  holds, and leaves the stored data as it was. Resolve or discard the exchange first, because the
  wipe would take the reserved root with it, and with it the only record that the staked value ever
  existed.

- `Data.RestoreVersion` now returns false with a reason, and logs `PROFILE_RESTORE_FAIL`, while the
  profile holds an in-flight or undelivered exchange, whatever `RollBackReserved` is set to. A
  restore rolls game data back and deliberately keeps the live reserved root, which for an exchange
  is wrong in both directions: it can leave a stake sitting in the inventory and in escrow at once,
  or take an item back out from under a delivery that has already been cleared. The exchange has to
  reach a terminal state first.

- A finished game pass purchase is now confirmed with an ownership check before anything is credited.
  `PromptGamePassPurchaseFinished` reports that the purchase dialog closed rather than that a
  transaction completed, and a game pass has no `ProcessReceipt` to be authoritative, so an
  unconfirmed close used to write a permanent Robux purchase-log entry for money that may never have
  been spent. A check that does not confirm the purchase now credits nothing, writes no purchase-log
  entry and logs `PASS_PURCHASE_UNCONFIRMED`, and a genuine purchase the ownership API has not caught
  up with has the player's ownership restored on their next load, because the join scan re-resolves
  every declared pass. The check yields, so ownership is credited once it returns rather than in the
  same frame the purchase signal fires.

- A name declared in both `Products` and `Passes` now fails to boot. A prompt resolves by name, so
  the same name in two tables would leave table order deciding what the player is charged for. Rename
  one of them.

- An `OnPlayerInit` hook is handed the profile data directly, before the accessor tree that refuses
  reserved writes exists, so that hook and a `Scribe.Dynamic` factory are the one place Scribe's
  in-flight exchange ledger is reachable. A change either one makes to that ledger is now put back
  and reported as `EXCHANGE_INIT_TAMPER` at Error, which is what a starter kit clearing `_Scribe` to
  start clean looks like. Only the exchange ledger is put back: receipts, perks and the rest of that
  root are not.

### Added

- `Data.Exchange.Attempt` moves value between two players who are both loaded on the same server.
  Each side hands over a basket of legs naming what that player gives, both baskets are staked out of
  the two profiles, and one verdict key decides the whole exchange, so every participant, on every
  server and on every retry, reads the same answer. Nothing is duplicated or destroyed, but the
  resolution is deliberately not time bounded: an exchange interrupted at the wrong moment finishes
  on a later load or on the periodic sweep, and until then the staked value sits where the game can
  still show it to the player. A profile may hold only one exchange at a time.

- The new `Exchangeable` option is the allowlist of what a game may exchange, and nothing outside it
  can be traded. Each entry names a `Path` and a `Kind`, and a path may name a field or a container
  but may never reach through a container into one of its entries. The list says which kinds of thing
  may move, never whether one particular item may, so ownership and any untradeable marker of your
  own are still yours to check.

- An exchange basket is a list of legs, and a leg is one of three kinds. A `Key` leg moves one whole
  entry of a `DictOf`, `MapOf`, `SetOf` or `ArrayOf`. A `Qty` leg moves an `Amount` off a balance,
  which must be a `Scribe.Int` field declaring a `Min`. A `Stack` leg moves part of one entry of a
  `DictOf` or `MapOf`, splitting the count held on that entry and leaving the rest of it behind.

- A `Stack` declaration names `Count`, the element field holding how many, and must then classify
  every other field the element declares: `Identity` for a field that travels with both halves of a
  split, `Ignore` for one that does not travel at all. A field in neither fails the game at boot and
  is named. A split duplicates whatever it does not drop, and nothing at runtime can tell a
  duplicated tag from a minted resource, because the count itself is exactly conserved either way. An
  element that is a bare number is the one shape with nothing to declare, because the stored value is
  the count.

- A declaration Scribe cannot move safely fails the game at boot, naming the entry, and is logged as
  `EXCHANGE_REGISTRATION_REFUSED`. Refused at startup: a misspelled path, which would otherwise
  resolve to a parent and exchange a field nobody named; a path that reaches through a container,
  because crediting a key the receiver does not hold would seed the whole element from its defaults;
  a quantity on a container, on a `Scribe.Number`, on a `Scribe.Big`, on a `Scribe.Optional` or on a
  field declaring no `Min`; a `Scribe.Flags` or a derived field; a non-persisted root; a
  `Scribe.Timed` field or an `Evict` container anywhere in the subtree; and anything under Scribe's
  reserved `_Scribe` root.

- Every leg of both baskets is checked against the `Exchangeable` declarations, by path and by kind,
  before a slot is claimed or any value moves. A basket may therefore be built straight from what a
  client asked for: an undeclared path, an undeclared kind or a malformed leg produces a refusal that
  costs the players nothing and leaves nothing behind.

- `Data.Exchange.Open` reports what one player still has in flight: an entry per exchange carrying
  `Id`, a `State` of `Claimed`, `Staked` or `Delivering`, the `Partner` UserId, `Staked` for what
  they handed over, `Owed` for what they are owed, and `Since`. Staked value leaves the balance on
  purpose and resolution is not time bounded, so this is what a game shows a player whose exchange
  has stalled: without it their items simply look to them like they vanished. Every table it hands
  back is freshly built and aliases nothing Scribe holds, so it is safe to keep or mutate.

- `Data.Exchange.Discard`, `Data.Exchange.Settle` and `Data.Exchange.Redirect` are operator verbs for
  an exchange the automatic machinery cannot finish, and all three act on profiles loaded on the
  server they are called from. `Discard` drops an abandoned claim that never took value, and refuses
  an exchange that already has a verdict or that holds escrowed value. `Settle` forces `Commit` or
  `Abort` on one that cannot resolve itself, has no default verdict, and refuses a `Commit` when only
  one side is loaded or when a side holds escrow with no take recorded. `Redirect` lands a parked
  delivery on a different key of the same container, and refuses a set, where the key is the value,
  and a parked delivery holding more than one key leg.

- `Data.PromptPurchase` prompts a player to buy a declared product or pass for themselves, by the
  name you gave it rather than its numeric Id. The name resolves against `Products` and `Passes`, and
  Scribe makes the matching engine call, so a shop button does not have to know which table an item
  lives in. It refuses something the player already owns, so a caller does not have to pair every
  prompt with its own `Data.Owns` check; a product with no `Grants` is a consumable, has nothing to
  own, and always prompts. An unknown name, a player whose data is not loaded, something the player
  already owns and a prompt the engine refused all come back as `(false, reason)` rather than
  raising. Prompting is all it does, and for a product the grant still happens on the receipt, so a
  player who buys and then leaves is granted on their next load.

- The new `LoadDuration` metric records how long a profile took to become ready, in seconds, and
  reads through `Scribe.GetMetrics` and `Scribe.GetPercentiles` like any other distribution. It is
  measured from the moment the player joined rather than from the DataStore call, so it covers the
  queue, the retries and the migration chain, which is what the player actually waited through. A
  load taking ten seconds or longer also warns as `SLOW_LOAD`, naming the player and how long it
  took. That threshold is fixed and sits well below `LoadTimeout`, so it reports joins that are
  merely slow rather than only the ones that end in a kick.

- An attempt answers `Committed`, `Aborted`, or nil with a reason. An `Aborted` exchange is a
  finished operation rather than a failure left to clean up: every basket has been returned to its
  owner. A nil is one of two things, and the reason says which. Either the exchange was refused
  before anything moved, which is by far the common case and costs the players nothing, or no verdict
  could be established, in which case the value is in escrow and the exchange resolves itself on a
  later load or on the sweep.

- The refusals that cost nothing are a player exchanging with themselves, two empty baskets, a player
  who already has an exchange in flight, a player who is not loaded on this server, and a player
  already holding eight undelivered exchanges, which is the cap. An attempt also carries a deadline
  of about twenty seconds: one that reaches it aborts rather than going on to commit, and every
  basket comes back to its owner.

- An exchange interrupted part way resolves itself the next time either profile loads, and a
  background sweep does the same for sessions that never end. `EXCHANGE_RESOLVED` records each
  exchange that reaches a terminal state, `EXCHANGE_UNRESOLVED` reports one that cannot, and
  `EXCHANGE_PARKED` reports a settled exchange whose delivery has nowhere to land, which is the
  condition `Data.Exchange.Redirect` exists for. The last two are announced once per exchange per
  server rather than on every sweep.

- A delivery that cannot be applied parks in the receiving player's inbox and is retried on every
  load and on the sweep, rather than being clamped, evicted or dropped. That covers a container at
  its cap, a destination key already occupied, and for a `Stack` leg a merge that would pass the
  count's `Max` or land on an entry whose other fields do not match the one being delivered.

- `Ignore` works on a `Key` leg as well, for a field that describes the owner's relationship to an
  item rather than the item, such as a locked marker. The field is dropped where the item is staked,
  the one point at which the giver's copy is still readable, and the receiver's copy starts from the
  element's declared default. An ignored field is destroyed in transit rather than held, escrowed or
  returned by an abort, so nothing that represents value belongs in it. Listing fields is optional on
  a `Key` leg: one left unlisted simply travels, which is always conserving.

- Moving a whole stack is the same `Stack` leg with `Amount` equal to what is held, and it removes
  the key outright rather than leaving a zero count entry the player still appears to own, so a
  container that stacks does not need a `Key` declaration as well. Where the count declares a `Min`,
  a partial move that would leave either half below that floor is refused before anything moves, and
  that includes the half being moved, not only the remainder.

- `Scribe.ExchangeLeg`, `Scribe.OpenExchange` and `Scribe.OpenLeg` are exported types, so a basket
  you build and the entries `Data.Exchange.Open` hands back both type-check. The `LogCode` union
  gained eight exchange codes alongside `SLOW_LOAD` and `PASS_PURCHASE_UNCONFIRMED`, and
  `LogCategory` gained `Exchanges`.

- A bundle whose `Mode` is `Mock` or `NoSave` serves the exchange verdict from memory under the same
  first writer wins contract, so an exchange resolves the same way in Studio as it does in
  production. A server that cannot reach the verdict store logs `EXCHANGE_STORE_UNAVAILABLE` and
  refuses attempts rather than falling back to a store no other server can see.

- The new `FlushDuration` metric records what one frame of replication cost, in seconds, and reads
  through `Scribe.GetMetrics` and `Scribe.GetPercentiles`. Nothing is recorded for a frame that
  flushed nothing, so the distribution describes busy frames rather than the average frame, and the
  existing `FlushEntriesPerFrame` and `FlushQueuedPerFrame` counts still say how much work there was.

- A frame of replication now appears in the MicroProfiler under a single label, `Scribe.Flush`,
  covering the flush across every player in that frame. It is the only label Scribe adds, because a
  profiler annotation does not survive a yield: work that waits, such as a profile load or a
  migration you wrote, is reported through a metric instead.

- Scribe's own long-lived threads now report their allocations under a `Scribe` memory category in
  the Developer Console, covering the profile load, the leaderboard refresh and write pacer loops,
  the timed sweep and the exchange sweep. Roblox charges an allocation to the thread that is running,
  so a write your own code makes stays under your own category: the tag shows what Scribe does on its
  own rather than the total cost of the data layer.

- The stack declarations are refused at boot on the same terms: a `Stack` on a `SetOf` or `ArrayOf`,
  neither of which has a keyed stack to split; a `Count` naming a field that is not a `Scribe.Int`
  declaring a `Min`; a `Count` that is also ignored; a name in `Count`, `Identity` or `Ignore` that
  the element does not declare; a field listed in both `Identity` and `Ignore`; a container field
  listed in `Identity`, where a split would duplicate the whole collection; `Ignore` on a quantity
  leg; and `Count` or `Identity` on a leg that is not a `Stack`.

- Each exchange writes one key to a DataStore named `ClaimExchangeVerdicts`. The first writer wins
  and every later proposal reads that answer back rather than overwriting it, and Scribe never
  deletes one, because deleting a verdict can only be justified by knowing both sides settled and a
  settled side can still revert. Budget for one key per exchange.

- An exchange in flight locks nothing. Neither profile is frozen and no write is refused, so both
  players carry on playing throughout, and the only thing either of them can observe is that what
  they staked has left their data until the exchange settles.

- The new `PassPurchasesUnconfirmed` metric counts finished game pass purchases that the ownership
  check would not confirm, and the new `PurchasePrompts` metric counts the prompts
  `Data.PromptPurchase` opened. Both are reported by `Scribe.GetMetrics`.

- `Scribe.Short` renders a quantity the way a player reads it, as `1.5K` or `100M`, and takes either
  a plain number or a `Scribe.Big` value, so a balance label no longer has to branch on which numeric
  type the field happens to be declared as. `Scribe.SetShortSuffixes` replaces the suffix table it
  and a big value's `Short` method render with, for a game whose convention past `T` is not Scribe's
  `Qa`, `Qi`, `Sx`. The list must be non-empty, every entry must be a string, and the first entry
  must be the empty string, because that is the tier a plain number renders in. It applies to every
  later render in the realm that calls it, so call it once at startup, and on the client too if the
  client formats its own labels.

### Fixed

- A generalized `for` loop over an accessor, as in `for key, entry in data.Inventory do`, emptied the
  container it was meant to read. An accessor carried no iterator, so Luau fell back to calling it,
  and that call reached `Set` with a nil value and deleted the node. The loop body never ran, so the
  whole statement read as a harmless no-op while the deletion replicated and saved. Iterating an
  accessor now raises, and the error names `Get` for a read-only walk and `Clone` for a table you may
  edit. Calling a node with two nil arguments is refused for the same reason, while a deliberate
  `Set(nil)` with one argument still clears the value.

- A save that handed its session to another server part way through was reported as having failed,
  even though its bytes had already reached the key. When another server starts a session for a
  profile this one still holds, which is what a teleport or a quick rejoin produces, it requests a
  force load, and the save that noticed the request released the session without recording that its
  own write had landed. `Data.Flush` returned false for data that was on disk, and the receipt path
  reads that same answer before it decides whether to report `PurchaseGranted`.

- In `DevMode`, `UNDECLARED_PERK` warned about a product whose `Grants` names a declared pass, and
  about that same name passed to `Data.GrantPerk`. A game pass cannot be transferred, so granting a
  perk of the pass's own name is how a gift confers it, and `Data.Owns` already answers across both
  namespaces. A declared pass name is now accepted in both places without a warning.

### Changed

- The `PROFILE_LOADED` log entry now carries `LoadSeconds`, the time between the player joining and
  their data being ready, so a sink added with `Scribe.AddLogSink` can attribute one slow join
  without reading the metric.

### Documentation

- A new guide, Exchange, covers moving value between two players who are both loaded on the same
  server: what an exchange promises and what it deliberately does not, the three leg kinds, declaring
  `Count`, `Identity` and `Ignore` on a stack, why the allowlist answers whether a kind of thing may
  move and never whether this particular item may, what a player sees while an exchange is in flight,
  and the three operator verbs, including why `Settle` refuses to guess a verdict. It also gives the
  rule that a listener on an exchangeable path must not yield, because container listeners fire
  inside the transaction the exchange runs in and a yield rolls it back.

- A new guide, What It Costs, covers measuring Scribe in a running game rather than guessing: the
  `LoadDuration`, `SaveDuration`, `FlushDuration` and `ProfileSize` distributions and why the p99 is
  the number to read, the `SLOW_LOAD` and `PROFILE_SIZE` warnings, `Scribe.GetStatus` and
  `Scribe.GetBudgetSnapshot`, what the single `Scribe.Flush` MicroProfiler label and the `Scribe`
  memory category do and do not cover, and what Scribe deliberately does not measure.

- The configuration guide gained an Exchanging section covering the new `Exchangeable` option and
  every field of a leg spec: `Path`, `Kind`, `Count`, `Identity` and `Ignore`. It states that an
  ignored field is destroyed in transit rather than escrowed, and that a `Stack` element field named
  in neither `Identity` nor `Ignore` refuses to start and names the field. It points at the Exchange
  guide for the full list of shapes Scribe will not let you declare exchangeable, each with the
  reason it cannot be moved safely.

- The monetization guide no longer teaches prompting a sale with a numeric product id. It now teaches
  `Data.PromptPurchase`, which takes the name you declared, resolves it across both `Products` and
  `Passes`, refuses something the player already owns, and answers `(false, reason)` rather than
  raising. A new section explains that a finished game pass purchase is confirmed with an ownership
  check before anything is credited, that a genuine purchase the ownership API has not caught up with
  is credited on the player's next load, and that a name declared in both tables fails at startup.
  `PASS_PURCHASE_UNCONFIRMED` is written up alongside the other monetization log codes.

- The cross key transactions guide no longer says Scribe has no API for a two sided trade. The section that
  frames the problem, the decision table and the closing links all send two players on one server to the
  Exchange guide, and the costs listed below that section are now scoped to the cross server case, which is
  still uncovered.

- The log code reference gained an Exchange section for the eight `EXCHANGE_` codes, which record where an
  in flight exchange currently is rather than any loss of value, and gained rows for `SLOW_LOAD` and
  `PASS_PURCHASE_UNCONFIRMED`.

- The containers guide now warns that a container listener which yields closes the thread of any open
  transaction and rolls that whole transaction back, including the write that fired the listener, and
  that the error names the transaction body rather than the listener, so the file you go looking in
  is the wrong one. A listener that raises instead is logged while the transaction still commits.

- The documentation build now fails when a guide calls a `Scribe.` member the package does not
  export, so a guide can no longer teach an entry point that does not exist.

## 2.0.0

Released 2026-08-24.

This release closes a long list of defects in the money, persistence and replication paths, and adds
derived fields, idempotent commands, narrowed float replication and a schema check for stored data.
It also changes a number of behaviours that existing games depend on, including the replication wire
format, so read the behaviour changes below before upgrading. A game that uses neither monetization
nor offline writes will find most of its risk in the wire format change and the template compile
rules.

### Behaviour changes

- The replication protocol version moved from 1 to 6, so a server and a client built from different
  Scribe versions now refuse each other and log `PROTOCOL_MISMATCH` instead of mis-decoding frames.
  Deploy the server and the client together, because a mixed deploy leaves players unable to load.

- Scribe now ships its own patched copy of ProfileStore inside the package, so the ProfileStore
  Wally dependency is no longer required. Remove it from your `wally.toml` when you upgrade.

- Game code can no longer write anywhere inside Scribe's reserved `_Scribe` root, and every mutator
  on such a path now raises an error naming the path and the API that owns that state. Reading a
  table inside that root also hands back a detached copy rather than the live stored table.

- A transaction can no longer touch a second player's data. Opening a transaction on another player,
  or writing to one from inside an open transaction, now raises and rolls the transaction back, and
  the error points at the durable outbox as the way to move value between players.

- A cross-server message is no longer acknowledged when nothing is connected to `Data.OnMessage` or
  when a handler raises. It stays on the key and is offered again on the player's next load, so a
  handler must now tolerate seeing the same message twice.

- `Data.RestoreVersion` no longer rolls the reserved `_Scribe` root back with the game data. Granted
  receipts, paid gifts, perks, the purchase log and running cooldowns are carried across from the
  live profile, and the new `RollBackReserved` option restores the old behaviour when that root is
  itself what needs repairing.

- A migration step that changes the reserved `_Scribe` root now has that change discarded and the
  stored root kept, reported as `MIGRATION_RESERVED_DISCARDED`. A migration that rebuilt the profile
  from its own key list used to destroy receipt idempotency and paid gifts in silence.

- `Data.SendMessage` now returns false and logs `MESSAGE_QUEUE_FULL` when the recipient's offline
  inbox is at its cap. It used to report success after throwing a message away.

- A template that declares a non-finite `Min` or `Max` on `Scribe.Number`, or a `MaxLength` that is
  not a non-negative integer, now fails to compile. This fails at startup rather than in production,
  and a negative `MaxLength` previously deleted the end of every value it was applied to.

- `Data.UpdateOffline` now commits as a compare-and-set, so the session check and the write are a
  single DataStore call. It gained one refusal reason, that the profile changed while the update was
  being prepared, and a refusal now writes nothing at all.

- `Data.WaitForData` can now answer `still-loading` where it used to answer `timeout`. A load that
  is merely slow is worth retrying, so code branching on `timeout` should handle both.

- Cooldown and claim keys passed to the public timed API are now refused if they contain invalid
  UTF-8 or begin with `@`, which is reserved for Scribe's own idempotency claims. Rename any key of
  yours that starts with that character.

- A write that would leave a container holding both array indices and string keys is now refused,
  whether it arrives as a keyed write or as an `Insert`. That shape loses half its contents on save.

- A product grant that yields and then fails part way is now settled as granted, logged as
  `GRANT_PARTIAL` and counted in `ReceiptsPartial`. It used to be retried, which compounded the
  writes it had already made.

- Two pass names sharing one gamepass `Id` now fail to boot, matching the refusal products have
  always had for a duplicate `Id`. Give each pass its own gamepass or register it once, because an
  in-experience purchase reports only the Id and used to credit whichever of the two names Scribe
  registered last.

- `tostring` on a `Scribe.Big` now keeps the fractional part instead of rounding to a whole number,
  so a third of ten prints as `3.33333333333333`. The numbers inside bounds error messages change
  with it.

- Dividing a `Scribe.Big` by zero now raises instead of returning nil.

- A `Set` that writes the value a field already holds no longer fires `Changed` or queues a
  replication op on a `Scribe.Big`, a flags field or a datatype field. Those three used to fire
  where the identical no-op on an integer cost nothing.

- `SchemaPolicy` now defaults to `Warn` under `DevMode` and stays off on live servers, so a Studio
  session reports stored data that no longer matches the template. An explicit setting still wins in
  both directions.

- `Data.Request` now returns `Scribe.RequestFailed` as a third value whenever the refusal is
  Scribe's rather than your handler's. Only a caller that forwards the results of `Data.Request`
  straight into another call needs to change.

- In edit mode, meaning a storybook or the command bar, a bundle now builds the client half instead
  of the server half. Building the server half used to create the transport folder and RemoteEvents
  in ReplicatedStorage and leave the client stub raising.

### Added

- `Scribe.Derived` declares a field that Scribe computes from other declared fields instead of
  accepting writes. It is never persisted or migrated, it recomputes when an input changes, and
  every mutator is absent from its type and raises at runtime.

- `Client.RequestOnce` sends a command tagged with a caller-supplied idempotency key, so the server
  runs the handler at most once per key and answers repeats with the original reply. Keys must be
  non-empty, valid UTF-8 and at most 64 bytes.

- A command spec now accepts `Idempotent = true`, which makes the command require a key sent through
  `RequestOnce`. The requirement is symmetric, so a key sent to a plain command and a keyless call
  to an idempotent one are both refused.

- `PurchaseSpec` gained an optional `IdempotencyKey`, and a repeat under the same key returns
  exactly what the first call returned and spends nothing. The new `PurchaseClaimTTL` and
  `MaxPurchaseClaims` options govern how long a claim is kept and how many may be live on one
  profile.

- `Data.Stop` releases everything a bundle holds on the process, including the background loops, the
  Players and MarketplaceService listeners and the transport channel claim. A game never needs it,
  but a test suite or a simulation that builds many bundles does.

- `Scribe.Number` gained a `Precision` option that narrows a replicated field to four, two or one
  bytes. The server keeps the full double it was given and only the client copy is quantized, so do
  not compare the two for equality.

- `Scribe.CFrame` gained `Precision = "exact"`, which packs every component bit for bit at 49 bytes
  instead of the default 13 or 29. `Scribe.Datatypes.Pack` takes the same value as an optional third
  argument.

- A `Scribe.Big` value now supports `Pow` for a non-negative integer exponent and `Log10`. Both are
  reads that return a new value, and `Pow` refuses a fractional, negative or non-finite exponent.

- The new `SchemaPolicy` option checks stored data against the template when a profile loads. Only a
  table mixing array indices with string keys ends the session under `Reject`, and under that
  setting a bounded `Scribe.Big` outside its bounds also refuses the load.

- An outbound frame larger than the outbound budget is now split into fragments and reassembled by
  the client, where it previously could not be sent at all. A frame needing more than sixteen
  fragments logs `OUTBOUND_OVERSIZE` once per server.

- A custom transport may now declare `MaxFrameBytes`, and Scribe keeps every frame under it. An
  adapter whose own framing inflates the buffer can carry its ceiling with it instead of having to
  be paired with a matching `MaxOutboundBytes` setting.

- `Scribe.GetPercentiles` returns the P50, P90 and P99 of each recorded metric, which `GetMetrics`
  could not report. It is computed over the most recent 256 samples per name, so it does not agree
  with the all-time count.

- `Scribe.GetBudgetSnapshot` reports the DataStore request allowance the engine currently gives, by
  request type. Its `Available` field is false when the engine could not be asked at all.

- `Scribe.AddLogSink` now returns a function that removes the sink again, so a sink with a lifetime
  no longer stays registered for the life of the server.

- `Scribe.RequestReason`, `Scribe.PurchaseReason` and `Scribe.GiftReason` name the fixed refusals of
  `Data.Request`, `Data.Purchase` and `Data.PromptGift`, each with a matching exported type.

- The new `ImportLegacyData` option adopts data from another library once, before Scribe has ever
  saved for that player. The adopted profile then runs the full migration chain.

- The new `LoadTimeout` option bounds how long a profile load is given, defaulting to 120 seconds
  with a floor of 60.

- The new `LogRingSize` option sets how many recent entries `GetRecentLogs` retains, which used to
  be fixed at 512.

- The new `MaxOutboundBytes` option caps the bytes in one outbound frame before fragmentation,
  defaulting to 65536 with a floor of 256.

- The new `MaxInboundRetainedBytes` option caps how much memory one inbound client frame may cause
  the server to retain, defaulting to sixteen times `MaxInboundBytes`.

- The new `BudgetPolicy` option, whose only value is `Defer`, paces the two leaderboard background
  loops against the DataStore request allowance. It deliberately touches no save path.

- The new `IsRunning` option overrides the `RunService:IsRunning()` default, and is the seam a
  storybook or a test harness uses to pick which half of the bundle gets built.

- A leaderboard `Stat` may now name a derived field, provided that field reads only persisted
  inputs. One that reads session-only state is refused at startup.

- A new `MIRROR_RESYNC` log entry and a `MirrorResyncs` metric record every time Scribe rebuilds a
  client's copy of the data after a send failed.

- In `DevMode`, Scribe now warns with `GRANT_SEEDED_ELEMENT` when a purchase grant creates a
  container element merely by writing through its key, which is what a stale or mistyped id looks
  like.

- The `LogCode` union gained thirty nine new codes across persistence, integrity, replication,
  transport, commands, monetization, gifting and leaderboards, and `LogCategory` gained `Derived`.
  No existing code was removed.

### Fixed

**Purchases and gifts.**

- A gift receipt that Roblox retried more than an hour after the purchase was granted to the buyer
  instead of the recipient, so one payment could produce two grants. The recipient is now recorded
  durably for as long as the receipt can still be retried.

- A second gift prompt for the same product could delete the first gift's record while it was still
  being delivered, so that receipt landed with nothing to aim it at and the perk went to the buyer.
  Gift records are now cleared by their own identity rather than by their slot.

- The gift prompt cap counted only archived records, so a buyer could arm a full set of pending
  gifts against a handful of free slots and lose the recipients at the next sweep. The cap now
  counts pending intents alongside the records they will become.

- A Robux gift to a player whose inbox was full is now held for Roblox to retry, instead of being
  destroyed with the buyer's escrow already cleared.

- A gift spent from a paid gift credit could grant twice when the delivery write committed and then
  lost its answer: the credit was handed back, the buyer was told to try again, and the retry queued
  a second gift under a fresh id the recipient could not deduplicate. Only a delivery that provably
  wrote nothing is refunded now; one that cannot be confirmed keeps the credit spent, answers
  `GiftReason.DeliveryUnconfirmed` and logs `GIFT_CREDIT_UNCONFIRMED`.

- A gift spent from a paid gift credit could still grant twice when the recipient's inbox was
  reported full after the delivery had already been queued, and could instead swallow the credit
  when the send was refused at a closing server's door without ever being attempted. Both came of
  the store answering the same thing in every case, so `MessageAsync` now also reports whether
  anything could have been written, and the credit comes back only where nothing can have been.

- A gift spent from a paid gift credit was swallowed when the recipient's inbox was full and the
  send had been throttled first. Whether anything could have been written was inferred from how many
  attempts the store had made rather than from what those attempts did, and a throttled request is
  dropped before it reaches storage, so a single one turned a delivery that provably never happened
  into one that could not be confirmed. Each failed attempt is now classified by its error, and only
  a request rejected outright or dropped at the throttle queue counts as having written nothing.

- A gift delivery that raised, rather than returning a failure, unwound past the refund decision
  entirely: the credit stayed spent with nothing logged, counted or reported, and the caller saw a
  script error instead of a refusal. It now settles as unconfirmed, keeps the credit spent because a
  raise cannot prove the gift did not go out, and logs `GIFT_CREDIT_UNCONFIRMED` with the error.

- `MESSAGE_QUEUE_FULL` and `MESSAGE_SEND_FAIL` claimed the message had not been delivered whatever
  had happened, including for a refusal reported after an earlier attempt in the same call had
  already queued it. Both lines now say which of the two occurred and carry `Context.ProvablyClean`,
  and the new `MessageQueueFullAmbiguous` counter isolates the refusals that may be hiding a
  delivery.

- Two copies of the same receipt arriving at once could each run the grant, so a player who paid
  once received the product twice. The second copy is now refused while the first is still running
  and logs `RECEIPT_IN_FLIGHT`.

- A receipt for an offline player could be granted twice when two servers decided from the same
  stored snapshot, because the duplicate marker was only checked before the write. It is now checked
  again inside the write itself.

- With `WipeGuardPolicy` set to `Block`, `Data.Flush` could return true for a save that had swapped
  the payload and left the old value on the key. Monetization answers `PurchaseGranted` off that
  boolean, so a paid grant could be acknowledged without ever being stored.

- A run of `AwaitSave` calls, or of `Client.Request` round trips, against a store or transport that
  answered immediately could walk the calling thread into the engine's `task.defer` re-entrancy
  ceiling. Past that point the engine accepts the call, reports success and never runs the callback,
  so the waiting thread was never woken and hung for the rest of the server's life. On the save path
  that took a receipt's `PurchaseGranted` answer with it. Neither path wakes its caller through the
  defer queue any more.

- Duplicate receipts are logged again at Info as `RECEIPT_DUPLICATE`, alongside the
  `ReceiptsDuplicate` counter they had lost touch with.

**Saving and offline writes.**

- When two saves for one player overlapped, a write made during the first could be reported as
  already on disk after that save failed. The dirty flag is now accumulated across every save in
  flight and cleared only once they all drain.

- A load that failed closed used to rewrite the stored profile on its way out, backfilling template
  defaults and advancing the key version, so the evidence a developer needed was gone. Those paths
  now release the lock without writing.

- Erasing a player's data while they were still playing left that session permanently stuck,
  accepting writes it silently discarded and never releasing. The session now ends cleanly and the
  erased key stays erased.

- `Data.RestoreVersion` could take a live session's data away from it when the player joined between
  the last check and the write. The check and the write are now a single operation.

- `Data.UpdateOffline` refused forever when a player's session had been left behind by a crashed
  server, while `Erase` and `RestoreVersion` already recovered from the same state. It now proceeds
  once the abandoned session is older than the dead session threshold.

- Two servers writing to the same offline player within the same second could both report success
  while one of the writes was silently discarded. Offline writes now carry a write counter that
  catches this.

- An offline write made from a snapshot taken before an operator restored an older version could
  silently undo that restore.

- An offline write that your callback declined used to still mint a new key version and spend part
  of the write budget. A decline now writes nothing at all.

- A refused offline write or a full inbox used to be reported as a DataStore error, which counted
  toward service health and could push a server into Outage, where it refuses Robux grants.

- A `Data.OnMessage` handler that yields and never returns silently withheld the acknowledgement, so
  the message came back on every load with nothing ever logged. The session end now reports
  `MESSAGE_HANDLER_STALLED` naming how many were outstanding.

- A second cross-server request arriving within six seconds of the first was discarded rather than
  queued, so its effect waited for the next autosave instead of landing within about a second. Those
  requests are now collapsed into a single save.

**Replication.**

- A replication frame that the transport refused was lost from the server queue and never reached
  the player, leaving that client's copy of the data permanently wrong. Scribe now notices the
  failed send and rebuilds the client from a fresh snapshot.

**Everything else.**

- An array `Insert` that Scribe refused, for a nil item, a fractional position or a value the
  element schema rejects, still evicted an entry first. An array already past its `MaxItems` lost
  every surplus entry to a single refused `Insert`.

- `Insert` with a non-number position raised a raw Luau error rather than the Scribe message written
  for it.

- A whole-table `Set` on a container did not fire `OnKeyAdded` or `OnKeyRemoved` for the keys it
  added or dropped, and now does. `Clear`, `Insert` and `Remove` still do not, which is a known gap.

- A template root field named `Raw` or `Stop` collided with Scribe's own API and was shadowed in
  silence. Both are now reported as `API_NAME_COLLISION`, and the log entry names the field.

- A bundle that failed to build, for example on a mistyped option, left the Default transport
  channel claimed. Fixing the option and pressing Play again reported that another Scribe instance
  already held the channel.

- A profile holding a key that was neither a string nor a number got no size estimate at all, so the
  `PROFILE_SIZE` warning that exists to fire before the DataStore ceiling was silently skipped for
  exactly that profile. The size walk asserted every non-string key was a number and raised on a
  boolean, table or function key; it now charges such a key a fixed cost and keeps measuring, and
  `PROFILE_UNPERSISTABLE` is still what reports that the data cannot be saved.

### Changed

- `Data.Flush` now returns true immediately and spends no DataStore request when the profile is
  already on disk with nothing written since. `Force = true` still always goes to the store.

- A leaderboard's first refresh is now staggered across servers, so a fleet does not read one board
  in unison. The interval between later refreshes is unchanged and exact.

- Leaderboard store failures no longer log once per attempt. `LB_READ_FAIL`, `LB_WRITE_FAIL` and
  `LB_WRITE_DROPPED` are throttled to one entry per code every 30 seconds, and that entry carries how
  many it suppressed. The counters still record every attempt. Studio with API access switched off
  refuses every call for the whole session, so that case is reported once and names the setting to
  change, rather than repeating for as long as the place is open.

- `ProfileStoreIndex` and `ProfileKeyPrefix` are now validated only on the server, so a shared
  bundle module can set them behind a server check and keep the live DataStore name out of client
  bytecode.

- A `WipeGuardShrinkRatio` outside the accepted range is now clamped and logged as
  `WIPE_GUARD_RATIO_CLAMPED` instead of being used as given.

- The `Args` entry of a command spec is typed as an array of any instead of an array of string. Most
  of the declarators were type errors under the previous typing even though the runtime validator
  accepted them.

- `Changed` and `Observe` on the root accessor now emit a dev warning when the subscription is
  expensive.

### Documentation

- The guides were rebuilt so that every example describes one small adventure game with a single
  shared template. Nine guides are new: values, containers, datatypes, big numbers, time, profiles,
  gifting, derived and transactions.

- The getting started guide taught a `Set` call on a flags member that does not exist, so anyone
  following it hit a runtime error on their first attempt. Every guide now uses the `Disable`
  spelling.

- The migrating guide taught importing from another library inside `OnPlayerInit`, guarded by a
  boolean in your own template. That hook runs after reconcile, after the migration chain and after
  the stored shape check, so imported data met none of them. It now teaches `ImportLegacyData`,
  which adopts the record before all three and needs no guard field.

- Site search never split on underscores, so searching for a log code such as
  `PROFILE_SCHEMA_VIOLATION` returned nothing. The search separator now splits them.

- `Value.Add`, `Value.Enable`, `Value.Disable`, `Value.Multiply` and `Value.Divide` are documented
  for the first time. They are not new, only newly written up.

- `Value.Update` now carries a warning that the transform receives the live stored table on a table
  field, so a transform that mutates it and then raises leaves the change in the profile with
  nothing reported.

- A new guide covers cross key transactions and gives a decision procedure for whether a feature
  needs one, with the shipped purchase path as a worked example.

- The configuration guide now states the trade-off in publishing a value through a `Shared` root,
  because the number moving is itself information every client in the server can read.

## 1.3.2

Released 2026-08-09.

- Receipt idempotency ids are now held with a TTL and evicted once the log is full, reported as
  `PURCHASE_ID_EVICTED`, so a long-lived profile stops growing its purchase log without bound.
- The untrusted inbound path gained rate limiting and an oversize cap, reported as
  `INBOUND_RATE_LIMITED` and `INBOUND_OVERSIZE_LIMIT`.

## 1.3.1

Released 2026-08-07.

- `Scribe.Session` stopped being a visibility of its own and became a modifier that composes with
  one. `Scribe.ServerOnly(Scribe.Session(v))` is runtime state only the server sees, and
  `Scribe.Shared(Scribe.Session(v))` is runtime state everyone sees and nothing saves. Combining
  `ServerOnly` and `Shared` on the same field is a startup error.
- Command handling was reworked alongside it.

## 1.3.0

Released 2026-08-04.

The largest release of the 1.x line.

- `Scribe.Big` stores a value past the exact double range as a mantissa and exponent pair, with
  arithmetic, comparison and display that keep working past it.
- `Scribe.Flags` stores a named set as a packed bitmask.
- `Scribe.SetOf` and `Scribe.MapOf` joined `ArrayOf` and `DictOf` as typed containers.
- `OnChildChanged` reports every child transition of a container individually, where the
  container's own `Changed` coalesces them.

## 1.2.1

Released 2026-08-01.

- Client accessors no longer materialize a `ServerOnly` field from its declared default.

## 1.2.0

Released 2026-07-31.

- Leaderboard `RefreshInterval` is clamped to a floor rather than accepted as written, and the
  clamp is reported as `LB_INTERVAL_CLAMPED`. Reading a board name that is not declared is
  reported as `LB_UNKNOWN_BOARD`.
- The guides were corrected on `Get()` and write-through accessors, including a caution that a
  table handed back by `Get()` is not a live handle to stored data.

## 1.1.0

Released 2026-07-29.

- The new `OnCooldownEnded` signal fires when a cooldown lapses while the player is online. A
  cooldown that lapsed while they were away does not fire it, because "ended" would misdescribe
  time the player was not there to spend.
- `Data.UpdateOffline` reported success for a write that never landed, and the offline receipt
  path turned that into `PurchaseGranted`. It now reports the store failure, and a failed offline
  write is counted against health.

## 1.0.12

Released 2026-07-28.

- `Data.WaitForData` and `Data.Flush` gained timeout arguments.
- `ProfileKeyPrefix` handling in the options table was corrected.

## 1.0.11

Released 2026-07-23.

- `Scribe.Configure` sets process-wide options that belong to the process rather than to a bundle.
- Monetization receipt handling was reworked and a strict mode added.
- A `Mode` that overrides the older individual flags is reported as `MODE_OVERRIDES_LEGACY`, and
  two bundles asking for different save intervals as `SAVE_INTERVAL_CONFLICT`.

## 1.0.10

Released 2026-07-21.

- `Scribe.ArrayOf` and `Scribe.DictOf` declare typed containers whose entries have a shape, and
  `Scribe.Optional` marks a field that has no default and may simply be absent.

## 1.0.9

Released 2026-07-20.

- The new `OnOwnershipChanged` signal reports a gamepass or a granted perk changing hands.

## 1.0.8

Released 2026-07-19.

- Replication and error handling were reworked. A profile over the size ceiling is reported as
  `PROFILE_TOO_LARGE`, a command reply that had to be cut short as `COMMAND_REPLY_TRUNCATED`, a
  leaderboard score outside the storable range as `LB_SCORE_OUT_OF_RANGE`, and a sustained run of
  malformed frames as `MALFORMED_FRAME_LIMIT`.

## 1.0.7

Released 2026-07-18.

- `OwnsAsync` checks gamepass ownership against Roblox on every call, where `Owns` answers from the
  warm cache.
- Publishing to Wally moved to a workflow that refuses to publish unless the version declarations
  agree.

## 1.0.6

Released 2026-07-17.

- Hello handshake failures are logged with the reason they failed, and a Scribe running without
  access to the transport is detected and reported as `SANDBOXED`.

## 1.0.5

Released 2026-07-16.

- Default value validation was fixed for datatype fields nested inside a record.

## 1.0.4

Released 2026-07-15.

- `Scribe.Dynamic` seeds a per-profile default from a factory that runs once, when the profile is
  created, rather than from a value shared by every profile.

## 1.0.2

Released 2026-07-15.

- Economy analytics emit automatically on a tagged currency mutation, so a `Source` or `Sink` event
  reaches Roblox without a separate call.
- The wipe guard reports `WIPE_GUARD_TRIPPED`, `WIPE_GUARD_BLOCKED`, `WIPE_GUARD_CLEARED` and
  `WIPE_GUARD_FORCED`.

## 1.0.1

Released 2026-07-15.

First published release.
