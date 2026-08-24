---
hide:
  - navigation
  - toc
---

# Scribe

Persistent, typed, auto-replicated player data for Roblox, built on ProfileStore. You write down the shape of your data once. Scribe saves it, locks it so two servers cannot fight over it, streams a copy to the client, and gives you a typed accessor for every field.

[Get started](getting-started.md){ .md-button .md-button--primary }
[Wally](https://wally.run/package/ericplane/scribe){ .md-button }
[Roblox model](https://create.roblox.com/store/asset/80989304733349/Scribe){ .md-button }
[Studio plugin](https://create.roblox.com/store/asset/113609038046646/Scribe-Studio){ .md-button }
[GitHub](https://github.com/ericplane/Scribe){ .md-button }

## Where to start

<div class="grid cards" markdown>

- :material-numeric-1-circle:{ .lg .middle } **New to Scribe**

  ***

  Install it, meet the full Emberfall template, and get a player's data saving in about ten minutes. Then learn what you can call on a field, and how a session begins and ends.

  [:octicons-arrow-right-24: Getting Started](getting-started.md)

  [:octicons-arrow-right-24: Declaring Your Template](templates.md)

  [:octicons-arrow-right-24: Reading & Writing Values](values.md)

- :material-numeric-2-circle:{ .lg .middle } **Building a real game**

  ***

  Inventories and sets, numbers past `2^53`, cooldowns, fields computed from other fields, who is allowed to see what, and client-to-server commands.

  [:octicons-arrow-right-24: Containers](containers.md)

  [:octicons-arrow-right-24: Derived Fields](derived.md)

  [:octicons-arrow-right-24: Replication & Visibility](visibility.md)

- :material-numeric-3-circle:{ .lg .middle } **Shipping it**

  ***

  Sell products and passes without ever eating a Robux payment, rank players globally, and watch the whole thing from a live Studio plugin.

  [:octicons-arrow-right-24: Monetization](monetization.md)

  [:octicons-arrow-right-24: Leaderboards](leaderboards.md)

  [:octicons-arrow-right-24: Diagnostics](diagnostics.md)

- :material-numeric-4-circle:{ .lg .middle } **Already have saved data**

  ***

  Adopt an existing ProfileStore, DataStore2 or hand-rolled database in place, without a wipe and without a migration window.

  [:octicons-arrow-right-24: Migrating to Scribe](migrating.md)

  [:octicons-arrow-right-24: Offline Profiles](profiles.md)

  [:octicons-arrow-right-24: Configuration](configuration.md)

</div>

## What you get

<div class="grid cards" markdown>

- :material-check-decagram:{ .lg .middle } **Typed end to end**

  ***

  A type-solver-generated accessor tree types every read and write, including nested containers, arrays, and Roblox datatype fields, all checked at compile time.

  [:octicons-arrow-right-24: Declaring your template](templates.md)

- :material-sync:{ .lg .middle } **Replication for free**

  ***

  Schema-compressed batched diffs stream to clients over a pluggable transport. Read player data on the client with the same accessor API, with no RemoteEvents to write.

  [:octicons-arrow-right-24: Replication and visibility](visibility.md)

- :material-package-variant-closed:{ .lg .middle } **Serialization built in**

  ***

  Vector3, CFrame, Color3, and raw buffer fields pack into compact binary while your code keeps the real datatype. A Vector3 is 12 bytes and an axis-aligned CFrame is 13. Containers pack too, and 32 named booleans fold into one field.

  [:octicons-arrow-right-24: Roblox datatypes](datatypes.md)

- :material-infinity:{ .lg .middle } **Numbers past 2^53**

  ***

  A big field carries an idle or prestige currency far past the point a Luau number stops being exact, and past 1.8e308 where it stops existing. It ranks on a leaderboard exactly, with no separate rank field.

  [:octicons-arrow-right-24: Big numbers](big-numbers.md)

- :material-database-lock:{ .lg .middle } **Production persistence**

  ***

  Migrations, a wipe guard, version history, and GDPR export and erase all sit on ProfileStore session locking, and they all fail closed.

  [:octicons-arrow-right-24: Offline profiles](profiles.md)

- :material-gift-outline:{ .lg .middle } **Monetization and gifting**

  ***

  Products, gamepasses, gifting, and perks live in the config table. Receipts are idempotent and fail closed, so Robux are never eaten.

  [:octicons-arrow-right-24: Monetization](monetization.md)

- :material-flask-outline:{ .lg .middle } **Testable without a live store**

  ***

  One `Mode` option swaps the whole stack onto an in-memory store, so a play-test or a CI run never touches real player data and leaderboards never write a real score.

  [:octicons-arrow-right-24: Testing and edit mode](testing.md)

- :material-chart-line:{ .lg .middle } **Observable**

  ***

  Structured logs with stable codes, a health status machine, per-player save state, and a companion Studio plugin that renders it all live.

  [:octicons-arrow-right-24: Diagnostics](diagnostics.md)

</div>
