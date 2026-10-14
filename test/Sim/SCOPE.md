# What the simulation covers

`test/Sim` runs simulated Scribe servers over one key space and virtual clock. It tests
behaviour under controlled timing and faults, not Roblox's production performance.
Keep this scope up to date when the harness changes.

## Modelled

- **Servers.** Each uses a real Scribe bundle with separate module instances, built by
  `Bundle.luau`. `Universe:Run(seconds)` advances Heartbeat at `TickPeriod`, one virtual
  second by default. Servers share `os.time`; each has its own, optionally skewed `os.clock`.
- **ProfileStore.** Each server loads the bundled fork, including its session locks,
  autosaves and message queue. `TestCtx` specs instead use `FakeProfileStore`.
- **Storage.** `Disk/` models latency, request budgets, numeric error codes, per-key
  throughput, contention, size limits, version history and OrderedDataStores.
- **Replication.** Each server gets its own `Link` by default. The bundle drives replication
  through `PostSimulation`, and `Bundle:ClientRealm()` separates client modules from server
  modules. This ensures client health updates must cross the transport.

## Limits

- Clients on the **same simulated server share one client module cache**, including health
  state. They cannot model independent client health; they are separate from the server's
  cache, not from each other.
- `IsStudio()` defaults to `false`, so Studio-only paths are excluded unless a spec overrides
  it. [DebugHookTeardown](../Specs/diagnostics/DebugHookTeardown.spec.luau) does this explicitly.
- Sorted queries expose only their first page. That is all Scribe's leaderboards read.
- Version history is bounded by count; real retention expiry is not modelled.
- `Disk:Arm` injects numeric errors, not named DataStore throttles. Direct classifier tests
  cover those in [FailureTaxonomy](../Specs/diagnostics/FailureTaxonomy.spec.luau).

## Writing a scenario

- Omit `Transport` for client scenarios so each server gets its own `Link`. A supplied
  transport is shared across servers; a single-listener `StubTransport` keeps only the last
  listener. It cannot host two clients either.
- Deliver frames through the frame signal. Scheduling a separate `Sched:Delay` for each
  frame changes the scheduler's seeded ordering.
- Assert ordering only within one player's frames. Broadcast order between players follows
  table iteration and is not stable across processes.
- Assert `#server.Bundle.FrameErrors == 0` after a run. Frame handlers run synchronously
  under `pcall`; otherwise an error could stop the tick driver or go unnoticed.
- Keep the bundle's private `PostSimulation` signal separate from `Heartbeat`. Sharing it
  can drive an unintended second ProfileStore instance.
- For `ServerStore` scenarios, set
  `server.Bundle:ClientRealm().Compiled = server.Bundle.Compiled` before creating clients.
  The default client compile omits the store, which would cause a schema mismatch.
- `Universe:Quiesce()` is permanent for that universe. A later `Run` does not restart ticks.