# Changelog

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
