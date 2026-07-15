---
sidebar_position: 10
---

# Scribe Studio (Companion Plugin)

**Scribe Studio** is a Roblox Studio plugin that renders Scribe's diagnostics layer as a live, interactive dock. It turns "what is my data actually doing" into something you can watch and drive: inspect every player's session, replay the change feed, simulate outages, profile bandwidth, invoke commands, lint your template, and, with an explicit opt-in, edit live production profiles.

It's the fastest way to test everything Scribe does without writing throwaway scripts.

## Safety first

Editing real data is a serious capability, so the plugin is built to be trustworthy:

- **No telemetry.** Nothing leaves your machine.
- **No privileged writes.** Every plugin-initiated change goes through Scribe's normal server `Value` API. Validation, bounds, logging, and replication all apply. Writes require an explicit per-session opt-in and are attributed as `Source = "ScribeStudio"` in the change feed.
- **Studio-only by construction.** The debug hook Scribe exposes for the plugin only exists when `RunService:IsStudio()` is true. The code path is never taken on a live server.

## Panels

| Panel | What it does | Mode |
| --- | --- | --- |
| **Sessions** | Live player list (load state, profile size vs the 4 MB ceiling, dirty flag, save results) and a virtualized data tree with visibility/declarator badges, search, and flash-on-change. One-click **Snapshot → `Data.Mock(...)`** and **Compare** (player vs player, or vs defaults). | Play |
| **Changes** | Filterable feed of every replication op (old → new) with `script:line` attribution and open-at-line, export, and **watch expressions**. **Time travel**: scrub a slider to reconstruct any player's state at any past op, diffed against now. | Play |
| **Diagnostics** | Health machine with transition history, per-second metric graphs, the log ring buffer with filters, **simulation buttons** (Degraded / Outage / load failure / session steal), and a **flight recorder** to save whole sessions and replay them in edit mode. | Play |
| **Bandwidth** | Real per-flush byte counts over time, chattiest paths by field with wire widths, and advisories. | Play |
| **Commands** | Every `Data.Command` registration with an arg form generated from its spec. Invoke as any session player, see returns / errors / duration. | Play |
| **Boards** | Leaderboard cached entries, per-player ranks, write-queue depth, refresh-from-store, and a gated queue flush. | Play |
| **Schema** | Runtime-derived schema browser (field IDs, types, wire widths, visibility) plus edit-mode **template lint** with open-at-line. | Play / Edit |
| **Monetization** | Grant / revoke perks, gift state with TTL countdowns, gift credits, purchase logs, and **receipt injection** with edge-case presets. Mock mode only, zero Robux spent. | Play |
| **Production** | Live profile tooling over Studio's DataStore access: lookup, version history + diff + **restore**, in-place **profile editing**, GDPR export, and erase. | Edit |
| **Settings** | Per-session write & attribution toggles, stream buffer caps, template module path. | N/A |

## Getting started

1. Open a place that initializes Scribe on the server.
2. Press **Play** (or Run). The plugin discovers Scribe's Studio hook, handshakes, and attaches, **read-only by default**.
3. To edit values, run mutating simulations, or inject receipts, flip **Enable writes** in Settings (it resets off every session).
4. For the `script:line` column in Changes, flip **Capture source attribution** (off by default because it costs a stack capture per write).

In a multi-client test the full toolset lives in the **server** view; switching to the **client** view attaches to Scribe's read-only client hook, so you can confirm exactly what a client received.

## Editing production data

The **Production** panel operates on real player profiles using Studio's own DataStore access, with no keys or credentials needed. Enable *File → Experience Settings → Security → "Enable Studio Access to API Services"* (the place must be published), and it works against the opened game's universe.

Reads are side-effect free. **Restore, erase, and profile edits mutate real data**, so they are blocked while a session lock is held (a player is actively online), require a typed confirmation, and are recorded in a local audit log.

## Requirements

Scribe ships the Studio debug hook in-box (`src/Server/DebugHook.luau`), so any recent release works. The plugin negotiates the protocol version with whatever hook the game speaks. Nothing extra to install on the game side.

## Install

Get **Scribe Studio** from the Creator Store. Install it once and it appears in Studio's **Plugins** tab:

**[→ Install Scribe Studio](https://create.roblox.com/store/asset/113609038046646/Scribe-Studio)**
