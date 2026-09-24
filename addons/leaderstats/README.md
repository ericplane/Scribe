# Scribe Leaderstats

An optional server addon that displays selected Scribe values in Roblox's built-in
player list. Scribe remains the source of truth: the addon never saves data or writes
leaderstat changes back into your profile.

Copy `ScribeLeaderstats.luau` into `ServerScriptService`. It is not included in the core
Wally package.

**roblox-ts users:** `@rbxts/scribe-leaderstats` is a separate optional package using
the same Luau implementation. It infers valid display paths from your server schema,
including nested fields, and rejects misspelled paths, containers, optional fields,
and Big values. See [roblox-ts](../../docgen/guides/roblox-ts.md) for publication status
and [the leaderstats guide](../../docgen/guides/leaderstats.md#roblox-ts) for an example.
Use `display.Stop()` in TypeScript; the compiler supplies the method receiver.

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Leaderstats = require(ServerScriptService.ScribeLeaderstats)
local Data = require(ReplicatedStorage.GameData).Server

local display = Leaderstats.Start(Data, {
    Coins = "Coins",
    Level = "Progress.Level",
    Title = "Title",
})
```

The left side is the column name; the right side is a dot-separated stat path.
Choose always-present numbers, strings, or booleans. Numbers use `NumberValue`
so fractional values are preserved. Strings use `StringValue`, and booleans use
`BoolValue`. Nested paths work, including field names such as `Get` or `Set`.

**Every selected value becomes visible to every client.** Selecting a `ServerOnly`
or `Session` path explicitly publishes that value through the player list. Keep
private moderation, anti-cheat, and account data out of this configuration.

## Lifecycle

- Start once per server Data API. Current players and future joins are handled.
- Values appear after the profile loads, then update through Scribe observers.
  Ready players require no polling and the addon makes no DataStore requests.
- Player departure and `Data.SessionEnded` remove the player's generated values
  and disconnect their observers.
- Call `display:Stop()` to release the
  whole addon. Call this **before `Data.Stop()`** if shutting down a bundle;
  `Data.Stop()` deliberately does not end existing sessions.
- Stop disconnects listeners immediately. Any pending profile wait finishes
  within its current 10-second window; a late load cannot recreate the display.

An existing `leaderstats` folder is reused, but an existing stat with the same name
is never overwritten. A collision, missing path, or unsupported initial value
produces a warning and skips all configured stats for that player. If an observed
value disappears or changes type, their generated stats are removed and a warning
is emitted. Use stable scalar fields rather than optional/dynamic entries.

Stop removes only the addon's generated stat instances. It preserves existing
folders and unrelated children, including children another script added to a
folder the addon created. Names are created in alphabetical order.

For an isolated test, `Start` accepts a third dependency argument with `Players`,
`NewInstance`, `IsServer`, and `Warn` overrides. Normal game code omits it.

See the [leaderstats guide](../../docgen/guides/leaderstats.md) for a complete example.
