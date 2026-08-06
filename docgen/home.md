---
hide:
  - navigation
  - toc
---

# Scribe

Persistent, typed, auto-replicated player data for Roblox, built on ProfileStore. Declare your data shape once, and Scribe handles saving, session locking, replication, migrations, monetization, and diagnostics.

[Get started](getting-started.md){ .md-button .md-button--primary }
[Wally](https://wally.run/package/ericplane/scribe){ .md-button }
[Roblox model](https://create.roblox.com/store/asset/80989304733349/Scribe){ .md-button }
[Studio plugin](https://create.roblox.com/store/asset/113609038046646/Scribe-Studio){ .md-button }
[GitHub](https://github.com/ericplane/Scribe){ .md-button }

## Highlights

<div class="grid cards" markdown>

-   :material-check-decagram:{ .lg .middle } __Typed end to end__

    ---

    A type-solver-generated accessor tree types every read and write, including nested containers, arrays, and Roblox datatype fields, all checked at compile time.

    [:octicons-arrow-right-24: Getting started](getting-started.md)

-   :material-sync:{ .lg .middle } __Replication for free__

    ---

    Schema-compressed batched diffs stream to clients over a pluggable transport. Read player data on the client with the same accessor API, with no RemoteEvents.

    [:octicons-arrow-right-24: Replication and visibility](visibility.md)

-   :material-package-variant-closed:{ .lg .middle } __Serialization built in__

    ---

    Vector3, CFrame, Color3, and raw buffer fields pack into compact binary (a Vector3 is 12 bytes, an axis-aligned CFrame 13), while you keep the real datatype. Give entries a shape with `Scribe.ArrayOf`, `Scribe.DictOf`, `Scribe.SetOf`, or `Scribe.MapOf` and they pack too, and `Scribe.Flags` folds up to 32 named booleans into one field.

    [:octicons-arrow-right-24: Templates and declarators](templates.md)

-   :material-infinity:{ .lg .middle } __Numbers past 2^53__

    ---

    `Scribe.Big` carries an idle or simulator currency far past the point a Luau number stops being exact, and past 1.8e308 where it stops existing. It ranks on a leaderboard exactly, with no separate rank field.

    [:octicons-arrow-right-24: Big numbers](templates.md#big-numbers)

-   :material-database-lock:{ .lg .middle } __Production persistence__

    ---

    Migrations, a wipe guard, version history, and GDPR export and erase all sit on ProfileStore session locking, and they all fail closed.

    [:octicons-arrow-right-24: Offline profiles, versions, and erasure](lifecycle.md#offline-profiles-version-history-and-erasure)

-   :material-gift-outline:{ .lg .middle } __Monetization and gifting__

    ---

    Products, gamepasses, gifting, and perks live in the config table. Receipts are idempotent and fail closed, so Robux are never eaten.

    [:octicons-arrow-right-24: Monetization and gifting](monetization.md)

-   :material-chart-line:{ .lg .middle } __Observable__

    ---

    Structured logs with stable codes, a health status machine, per-player save state, and a companion Studio plugin that renders it all live.

    [:octicons-arrow-right-24: Diagnostics](diagnostics.md)

</div>
