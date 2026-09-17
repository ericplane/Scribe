# Troubleshooting

Start with the symptom you can see. Keep Studio's **Output** window open; Scribe's log code usually points to the next step.

| Symptom | First check |
| --- | --- |
| My script cannot find Scribe or the data module | Compare the names and locations with the [Getting Started file tree](./intro). |
| Every test starts with fresh data | Check `Mode` and the [real-saving checklist](./testing). Mock data is not kept between server runs. |
| Server data changes but my UI does not | Require the shared module from a LocalScript and use `Observe`; see [client syncing](#the-client-never-receives-data). |
| A value changes on the client, then changes back | Client writes are local. Use a [server command](./commands) for a lasting change. |
| A write changes the value differently than I expected | Check the field's bounds and [clamping rules](./templates). |
| An offline edit or erase is refused | Check whether the player is online, then read the returned reason; see [offline operations](./profiles). |
| Scribe reports an outage or repeated save errors | Inspect [diagnostics](./diagnostics) and the specific [log code](./log-codes). |

## Data does not load

1. Require the shared data module from a server Script at startup.
2. Call `Data.WaitForData(player)` before reading the player's fields.
3. Handle both results. If the data is `nil`, inspect the reason instead of indexing into it.

```lua
local data, reason = Data.WaitForData(player)
if not data then
    warn("Could not load data:", reason)
    return
end
print(data.Coins.Get())
```

This example assumes `Data` is your shared module's `.Server` and `player` is the joining Player. [Getting Started](./intro) has the complete script. The [session lifecycle guide](./lifecycle) explains each failure reason, including a player leaving during loading and an erase preventing a join.

## Changes disappear when I test again

- `Mode = "Mock"` starts fresh on the next server run. This is expected.
- `Mode = "NoSave"` reads a real profile but never saves changes.
- For `Mode = "Live"`, use a separate test experience and enable Studio access to API services. If Output says `[ProfileStore]: Roblox API services unavailable - data will not be saved`, the store has fallen back to memory.
- Check whether a wipe guard, migration error, or store failure is logged. Do not bypass a guard just to silence the warning.

Follow the [save-and-reload checklist](./testing#test-saving-across-sessions) to verify persistence. After a manual save, inspect `Flush`'s result: `false` is not permission to repeat a purchase or reward. See [saving](./lifecycle#saving).

## The client never receives data

The shared module must be required on **both** the server and client. The client require starts the connection to the server. A `CLIENT_HANDSHAKE_TIMEOUT` log can indicate that this step is missing.

Use `Observe` for UI: it runs immediately with the current value and again when synced data arrives. An initial template default is normal. For a one-time read that needs loaded data, check the boolean returned by `Data.WaitForData()` on the client before continuing.

Also check [visibility rules](./visibility). A server-only field is deliberately unavailable to the client.

## My data changed but listeners did not run

Treat tables returned by `Get()` as read-only. A returned table can be the stored table itself; editing it directly bypasses Scribe's validation, change events, and replication. Some values are rebuilt as copies, so direct edits to those do not update the profile at all. Use the field methods to write, or `Clone()` to make a separate copy. See [reading and writing values](./values).

## An example uses a field my template does not have

The first tutorial uses a small `GameData` module. Feature guides use the larger [Emberfall example](./emberfall). Add the fields that the feature needs, or adapt the example's paths to your template. Do not run two independent data modules against the same player profile key.

## Getting help

Include the Scribe version, the exact log code or returned reason, a minimal template and script that reproduce the problem, and whether it happens in Mock or Live mode. Remove private player data and credentials. [Diagnostics](./diagnostics) explains how to inspect recent logs and save state.
