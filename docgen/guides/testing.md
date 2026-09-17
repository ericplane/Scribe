# Testing & Edit Mode

Choose a test mode based on what you want to check. For your first play-tests, use `Mode = "Mock"`: it exercises your game without reading or writing saved profiles.

| I want to… | Use |
| --- | --- |
| Try gameplay with fresh test data | `Mode = "Mock"` |
| Check loading and saving across sessions | `Mode = "Live"` in a separate test experience |
| Inspect an existing saved profile without saving changes | `Mode = "NoSave"` |
| Preview UI without pressing Play | [Edit mode](#edit-mode-and-storybooks) |
| Build an automated test harness | [Headless tests](#headless-tests) |

## Play-testing without touching live data

Set `Mode` in the shared module that calls `Scribe`:

```lua
return Scribe({
    Template = template,
    ProfileStoreIndex = "ScribeTutorial",
    ProfileKeyPrefix = "PLAYER_",
    Mode = "Mock",
})
```

Mock mode uses an in-memory store for profiles and leaderboards. It can save and reload within that running server, but its data disappears when the server stops. A new Studio play-test starts with an empty mock store.

Use this for gameplay, validation, and UI tests. It does not tell you whether your game's existing saved data matches a new template, or whether Roblox's live services are available.

## Test saving across sessions

Use a **separate test experience** for this check, so mistakes cannot affect your live players.

1. Set up [Getting Started](./intro) in that experience.
2. Publish the place, then enable **Enable Studio Access to API Services** in its security settings.
3. Change the shared module to `Mode = "Live"`. Keep the same store name and player-key prefix between test runs.
4. In the server's `onPlayerAdded` function, after the coin increment, add the save check below.
5. Play, wait for `Save confirmed`, then stop and play again with the same test player.

```lua
if Data.Flush(player) then
    print("Save confirmed")
else
    warn("Save not confirmed yet; check Output before continuing the test")
end
```

With the Getting Started script, a new test profile prints `50` coins on the first run and `100` on the next: the script adds another 50 each time it loads. The client can still briefly show its default before the loaded value arrives.

`Flush` waits for save confirmation. `false` means Scribe could not confirm the save within the wait; it does **not** prove that the save failed. Do not repeat the coin grant to fix this. Check [saving behavior](./lifecycle#saving) and retry the save if needed.

!!! warning "Check for an in-memory fallback"
    If Output says `[ProfileStore]: Roblox API services unavailable - data will not be saved`, your play-test cannot reach DataStores. Even `Mode = "Live"` is then using an in-memory fallback. Confirm that the place is published and Studio API access is enabled before treating this as a saving test.

Return to `Mode = "Mock"` when you finish testing persistence. `"Live"` is the default when no mode is specified.

## Inspect a real profile without saving it

Use `Mode = "NoSave"` to load a real profile as a snapshot. Add `TargetUserId` to inspect one specific player:

```lua
Mode = "NoSave",
TargetUserId = 123456, -- replace with the player to inspect
```

These are options in the same table as `Template`. The store name and key prefix must identify the data you intend to inspect. Your session can read and change its local copy, but Scribe does not save it. Leaderboards use mock storage in this mode too.

This is useful for checking a changed template against data that already exists. It still needs access to Roblox's DataStores.

!!! warning "ResetData is not a test mode"
    `ResetData = true` replaces loaded data with template defaults. In Live mode those resets can be saved. Use Mock mode for disposable test data instead.

??? note "Legacy mode options and startup output"
    `UseMock`, `DontSave`, and `ViewedUserId` remain supported. Prefer `Mode` for new configurations. If you specify both, `Mode` takes precedence and Scribe logs `MODE_OVERRIDES_LEGACY`. See [persistence configuration](./configuration#persistence-mode).

    `Banner = false` hides the startup banner; it does not change saving behavior.

## Edit mode and storybooks

When Studio is not running a play-test, the client API starts immediately with template defaults. You can use it in a UI Labs or Hoarcekat story, or the command bar, without a server.

With the shared module from Getting Started, this complete example seeds a coin balance and observes it:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage.Shared.GameData).Client

Data.Mock({ Coins = 1250 })
local disconnect = Data.Coins.Observe(function(coins)
    print("Preview coins:", coins) -- 1250
end)

-- Call when this preview closes:
disconnect()
```

In a real story, keep the observer connected while the component is mounted and call `disconnect()` when it unmounts. If the story **creates its own Scribe instance**, also call [`Data.Stop()`](/api/Client#Stop) when it closes. Do not stop a shared instance that other stories are still using.

[`Data.Mock`](/api/Client#Mock) and [`Data.MockCommand`](/api/Client#MockCommand) only work outside play mode. They throw if used in a running game. `Mode = "Mock"` is the separate option for play-tests; it does not enable these edit-mode methods.

??? example "Preview inventories, purchases, and leaderboards"
    This larger example uses the [Emberfall module](./emberfall), rather than the tutorial's smaller `GameData` template:

    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Data = require(ReplicatedStorage.Shared.EmberfallData).Client

    Data.Mock({
        Coins = 1250,
        Gems = 40,
        Xp = 4200,
        Inventory = {
            Emberblade = { Qty = 1, Rarity = "Epic" },
            HealthPotion = { Qty = 7, Rarity = "Common" },
        },
        Settings = { "Music", "Sfx" },
    }, {
        Perks = { "VIP" },
        GiftCredits = { GemPack100 = 2 },
        Leaderboards = {
            TopLevel = {
                { Rank = 1, UserId = 101, Name = "Ava", Score = 42 },
                { Rank = 2, UserId = 102, Name = "Ben", Score = 37 },
            },
        },
    })

    Data.MockCommand("BuyPotion", function(count)
        return true -- preview only; no real purchase is made
    end)
    ```

    `Level` is derived from XP, so seed `Xp` and let Scribe compute `Level`: this example produces level `5`. Flags such as `Settings` are seeded as a list of enabled names.

    The second `Mock` argument supplies Scribe's own state:

    | Key | Client APIs it feeds |
    | --- | --- |
    | `Perks` | `Owns`, `ObserveOwned` |
    | `GiftCredits` | `GetGiftCredits` |
    | `Leaderboards` | `GetLeaderboard` |
    | `PurchaseLogs` | `GetPurchases`; takes `Robux` and `InGame` arrays of log entries |

??? note "Mock values still follow your template"
    `Data.Mock` merges the supplied fields into current state, then writes through normal accessors. The same field types, bounds policy, and container limits apply. Supply real Roblox datatypes such as `CFrame`, not their packed buffer representation.

    Scribe validates dictionary keys, array layout, declared record fields, and container size. Numbers clamp by default; `BoundsPolicy = "Reject"` makes out-of-range numbers throw. Invalid enum members are always rejected. See [template validation](./templates#numbers-strings-and-enums).

??? note "How edit mode starts"
    Scribe checks `RunService:IsRunning()` because `IsServer()` can be true in edit mode. It builds only the client preview: no transport folder or handshake is created. Accessing the shared module's `.Server` API in edit mode throws.

## Scribe Studio

The [Scribe Studio plugin](./studio-plugin) gives you a live panel for inspecting sessions, watching changes, testing commands, and simulating failures. Its guide distinguishes safe previews from tools that edit saved profiles.

## Headless tests

For most game projects, start with the Studio tests above. An automated harness is useful when you need repeatable tests of your own game logic. Scribe's repository uses TestEZ and [Lune](https://lune-org.github.io/docs) with a fake ProfileStore and transport.

??? warning "Advanced: constructing an isolated server with internal APIs"
    `Server.build` and the template compiler are internal and can change between releases. They are not methods on the public bundle. With a Wally installation, the link module also does not expose their children, so this example uses the versioned `_Index` folder.

    The snippet assumes your test harness provides a compatible `player`. It is not a standalone command-bar example.

    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Scribe = require(ReplicatedStorage.Packages.Scribe)
    local ScribeRoot = ReplicatedStorage.Packages._Index["ericplane_scribe@{{version}}"].scribe
    local Template = require(ScribeRoot.Internal.Template)
    local Server = require(ScribeRoot.Server)

    local options = {
        Template = { Coins = Scribe.Int(0, { Min = 0 }) },
        ProfileStoreIndex = "EmberfallTest",
        ProfileKeyPrefix = "PLAYER_",
        Mode = "Mock",
        TransportChannel = "Test",
        OwnReceipts = false,
        KickOnSessionEnd = false,
        LogLevel = "Fatal",
    }

    local compiled = Template.Compile(options.Template)
    local Data, ctx = Server.build(options, compiled)

    ctx.Persistence.OnPlayerAdded(player)
    local data, reason = ctx.Persistence.WaitForData(player)
    assert(data, reason)
    data.Coins.Increment(50)
    assert(data.Coins.Get() == 50)

    ctx.Persistence.OnPlayerRemoving(player)
    Data.Stop()
    ```

    `build` returns the public API and its internal context. Unlike `Server.new`, it does not connect player events or register a shutdown callback; your harness drives that lifecycle. Removing a player destroys its accessors, so make assertions first.

    Always tear down instances, including when an assertion fails, using your test runner's cleanup hook. Call `Data.Stop()` on each server and client instance you create. This releases the transport channel, background work, and listeners so later tests can reuse the channel. `Stop` does not save; call `Flush` first if persistence is what the test checks.

    Optional seams for more advanced tests:

    - `ProfileStore = <your fake>` replaces the store.
    - A custom `Transport` captures frames instead of using `TransportChannel`.
    - `Template.Compile(options.Template, { ReplicateRobuxLog = true, ReplicateInGameLog = true })` includes purchase logs when your test needs them. Public `Scribe(options)` derives these flags from `PurchaseLog`.

??? tip "Running Scribe's own suite"
    In the repository, run `lune run lune/run-tests`. Its deterministic multi-server simulation models latency, request budgets, failures, and contention. Read `test/Sim/SCOPE.md` for what it covers and what still needs a real Roblox test. These simulations do not measure production service performance.

## Where to next

- [Scribe Studio](./studio-plugin) for interactive inspection.
- [Diagnostics](./diagnostics) for logs, health status, and metrics.
- [Session Lifecycle](./lifecycle#saving) for save confirmation and failure handling.
- [Configuration](./configuration#persistence-mode) for all persistence options.
