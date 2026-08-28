# Scribe Studio

Scribe Studio is a Roblox Studio plugin that renders Scribe's diagnostics layer as a live, interactive dock. It turns "what is my data actually doing" into something you can watch and drive. Inspect every player's session, replay the change feed, simulate outages, profile bandwidth, invoke commands, lint your template, and, with an explicit opt-in, edit live production profiles.

It is the fastest way to exercise everything Scribe does without writing throwaway scripts.

## Getting started

1. Open a place that initializes Scribe on the server.
2. Press **Play** or Run. The plugin discovers Scribe's Studio hook, handshakes, and attaches, **read-only by default**.
3. To edit values, run mutating simulations, or inject receipts, flip **Enable writes** in Settings. It resets to off every session.
4. For the `script:line` column in the Changes panel, flip **Capture source attribution**. It is off by default because it costs a stack capture per write.

Nothing extra is installed on the game side. Scribe ships the Studio debug hook in the box, and the plugin negotiates the protocol version with whatever hook the game speaks.

In a multi-client test the full toolset lives in the **server** view. Switching to the **client** view attaches to Scribe's read-only client hook, so you can confirm exactly what one client received.

## Panels

| Panel | What it does | Mode |
| --- | --- | --- |
| **Sessions** | Live player list with load state, profile size against the 4 MB ceiling, dirty flag, and save results, plus a virtualized data tree with visibility and declarator badges, search, and flash-on-change. One click turns a session into a `Data.Mock(...)` snapshot, and Compare diffs player against player or against defaults. | Play |
| **Changes** | Filterable feed of every replication op, old value to new, with `script:line` attribution, open-at-line, export, and watch expressions. Time travel scrubs a slider to reconstruct any player's state at any past op, diffed against now. | Play |
| **Diagnostics** | Health machine with transition history, per-second metric graphs, the log ring buffer with filters, simulation buttons for Degraded, Outage, load failure and session steal, and a flight recorder that saves whole sessions for replay in edit mode. | Play |
| **Bandwidth** | Real per-flush byte counts over time, the chattiest paths by field with their wire widths, and advisories. | Play |
| **Commands** | Every `Data.Command` registration with an argument form generated from its spec. Invoke as any session player and see the return values, errors, and duration. | Play |
| **Boards** | Leaderboard cached entries, per-player ranks, write-queue depth, refresh from store, and a gated queue flush. | Play |
| **Schema** | Runtime-derived schema browser with field ids, types, wire widths and visibility, plus an edit-mode template lint with open-at-line. | Play and Edit |
| **Monetization** | Grant and revoke perks, gift state with TTL countdowns, gift credits, purchase logs, and receipt injection with edge-case presets. | Play |
| **Production** | Live profile tooling over Studio's DataStore access: lookup, version history with diff and restore, in-place profile editing, GDPR export, and erase. | Edit |
| **Settings** | Per-session write and attribution toggles, stream buffer caps, and the template module path. | Any |

Watching Emberfall in the Sessions panel is the quickest way to confirm that `Level` really does move when you grant `Xp`, and the Changes feed will show you the derived recompute arriving as its own op.

!!! warning "Restore, erase, and profile edits mutate real data"
    The Production panel operates on real player profiles using Studio's own DataStore access. Reads are side-effect free, but restore, erase, and profile edits are not. Those three are blocked while a session lock is held, meaning a player is actively online, require a typed confirmation, and are recorded in a local audit log.

    Enable **File, Experience Settings, Security, "Enable Studio Access to API Services"** and publish the place before any of it works. It operates against the opened game's universe.

??? note "Why editing real data here is safe to allow"
    Editing production data is a serious capability, so the plugin is built so that you do not have to take its word for anything.

    Nothing leaves your machine. There is no telemetry.

    There are no privileged writes. Every plugin-initiated change goes through Scribe's normal server accessor API, so validation, bounds, logging, and replication all apply, exactly as they would for a write from your own game code. Writes require an explicit per-session opt-in and are attributed as `Source = "ScribeStudio"` in the change feed, so you can always tell them apart later.

    It is Studio-only by construction. The debug hook Scribe exposes for the plugin only exists when `RunService:IsStudio()` is true, so the code path is never taken on a live server.

??? note "Receipt injection needs mock persistence"
    Injecting a fake receipt spends zero Robux, and it is still gated twice. Beyond **Enable writes**, injection checks the bundle's resolved [persistence mode](./configuration#persistence-mode) and runs only under `Mode = "Mock"`. On a `Live` or `NoSave` bundle every injection is refused, with an error naming `Mode = "Mock"` as the requirement. That is what keeps a real store out of reach.

    The legacy `UseMock = true` and `DontSave = true` flags resolve to that same mode, unless `ViewedUserId` is set alongside them, which resolves to `NoSave`, so an older config still works.

    The Boards panel is gated the same way. Under `Mode = "Mock"` or `"NoSave"` the boards are backed by mock OrderedDataStores, so a flush reaches nothing real.

## Install

Get Scribe Studio from the Creator Store. Install it once and it appears in Studio's **Plugins** tab.

**[Install Scribe Studio](https://create.roblox.com/store/asset/113609038046646/Scribe-Studio)**

## Where to next

- [Testing](./testing) covers the `Mode` option the plugin's gates read, and edit-mode storybooks.
- [Diagnostics](./diagnostics) is the API behind the Diagnostics panel: logs, health, and metrics.
- [Session Lifecycle](./lifecycle) explains the load states the Sessions panel displays.
