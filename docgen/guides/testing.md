---
sidebar_position: 9
---

# Testing & Edit Mode

## Testing in Studio safely

A handful of options let you play-test without touching (or corrupting) live data:

| Option | Effect |
| --- | --- |
| `UseMock = true` | Leaderboards use an in-memory store instead of OrderedDataStore. |
| `DontSave = true` | Load real data but never persist changes. |
| `ResetData = true` | **Destructive**: every profile loads as template defaults. Development only. |
| `ViewedUserId = <id>` | Load another user's profile read-only (never saves). |
| `Banner = false` | Silence the one-line load banner. |

## Edit mode & storybooks

When `RunService:IsRunning()` is false (a UI Labs / Hoarcekat storybook, or the command bar), the client module skips the transport and handshake entirely and initializes **instantly** to template defaults. `Observe` and `Changed` work normally, so Scribe-backed components render and live-update without a running server.

Seed realistic state with the mock helpers (edit mode only):

```lua
Data.Mock({
    Coins = 1250,
    Inventory = { Sword = { Health = 100, Dmg = 5 } },
}, {
    Perks = { "VIP" },
    Leaderboards = { TopCoins = { { Rank = 1, UserId = 1, Name = "You", Score = 1250 } } },
})

Data.MockCommand("EquipItem", function(itemId) return true end)
```

Both [`Mock`](/api/Client#Mock) and [`MockCommand`](/api/Client#MockCommand) error outside edit mode, so they can't leak into a real session.

## Scribe Studio

For interactive testing, the **[Scribe Studio companion plugin](./studio-plugin)** renders the whole diagnostics layer as a live dock: inspect sessions, replay the change feed, simulate outages, invoke commands, and even edit production profiles. It's the fastest way to exercise everything without writing throwaway scripts.

## Headless tests

Scribe's own suite runs both in Studio (TestEZ) and headless via [Lune](https://lune-org.github.io/docs), against a deterministic fake ProfileStore and a stub transport. The same `Server.build(options, compiled)` entry point that the harness uses lets you construct isolated instances and drive the player lifecycle manually. That is useful if you want to unit-test your own game logic against Scribe without a live DataStore.
