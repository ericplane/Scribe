# roblox-ts

Scribe's npm package runs the same Luau implementation as the Wally package and the
Studio model. TypeScript declarations describe its schema, accessors, server/client
APIs. Five optional addons have their own npm packages and declarations: React,
Vide, Fusion, telemetry, and leaderstats. All six packages share one Scribe version
and tag; there is no TypeScript runtime fork.

Published packages keep concise Luau comments and types; full API documentation stays
in the repository and on this site. Each package includes `Scribe-source-map.json`
to map runtime error lines back to the matching release source.

## Install

The npm packages are prepared for initial publication. Repository owners must complete
the release setup in `CONTRIBUTING.md` before these registry installs are available.
After publication, install the core in an existing roblox-ts project:

```sh
npm install @rbxts/scribe
```

Use roblox-ts 3 with TypeScript 5.5 and the matching `@rbxts/compiler-types`. Keep the
normal roblox-ts `strict`, `noLib`, and `typeRoots` settings. Scribe does not need a
compiler transformer. Your usual Rojo mapping for `node_modules/@rbxts` includes it.
For project setup, follow the [roblox-ts quick start](https://roblox-ts.com/docs/quick-start/).

## A shared template

```ts
// shared/data.ts
import Scribe from "@rbxts/scribe";

export const template = {
    Coins: Scribe.Int(0, { Min: 0 }),
    Essence: Scribe.Big(0),
    Settings: { Music: true },
    Inventory: Scribe.DictOf({
        Count: Scribe.Int(1, { Min: 1 }),
        Rarity: Scribe.Enum("Common", ["Common", "Rare", "Legendary"]),
    }),
    RecentRuns: Scribe.ArrayOf({ Score: 0 }, { MaxItems: 10, Evict: "Front" }),
    Secret: Scribe.ServerOnly(0),
};

export const Data = Scribe({
    Template: template,
    ProfileStoreIndex: "PlayerData",
    ProfileKeyPrefix: "PLAYER_",
    Mode: "Mock",
});
```

`Mock` starts with fresh data and does not save it. See [test modes](./testing) before
switching to real persistence. Primitive defaults widen to their value type: `Coins`
holds numbers and `Settings.Music` holds booleans. Enum and flag members retain their
declared names. Containers infer both their entry shape and permitted operations.

```ts
// server/data.server.ts
import { Data } from "shared/data";

game.GetService("Players").PlayerAdded.Connect((player) => {
    const [data, reason] = Data.Server.WaitForData(player);
    if (data === undefined) {
        warn(reason);
        return;
    }

    data.Coins.Increment(50);
    data.Settings.Music.Toggle();
    data.Inventory.Child("Sword").Set({ Count: 1, Rarity: "Rare" });
});
```

```ts
// client/data.client.ts
import { Data } from "shared/data";

const disconnect = Data.Client.Coins.Observe((coins) => print(coins));
// Call disconnect() when the consumer is destroyed.
```

`WaitForData` returns a `LuaTuple`; use destructuring to receive both results.
`Data.Server.Get(player)` is the non-yielding player lookup. The Luau shortcut
`Data[player]` is not a TypeScript object index.

Accessors are closure properties. Write `data.Coins.Increment(50)` as shown;
roblox-ts emits the appropriate dot call. Ordinary object methods, such as
`Data.Server.OnSave.Connect(...)`, compile to colon calls automatically.

## Containers and indices

Use `Child(key)` to address a container entry. It passes the key unchanged and also
works for record fields whose names overlap with accessor methods, such as `Get`,
`Set`, `Count`, or `Child`.

```ts
data.RecentRuns.Insert({ Score: 4200 });
const score = data.RecentRuns.Child(1).Score.Get();
data.RecentRuns.Remove(1);

const sword = data.Inventory.Child("Sword").Get();
if (sword !== undefined) {
    print(sword.Count);
}
```

**Accessor positions are one-based.** `Child(1)`, `Remove(1)`, an explicit `Insert`
position, and indices reported by collection events refer to the first Luau array
slot. An integer `MapOf` key is an exact key, with no positional conversion.

**Array snapshots use ordinary TypeScript indexing.** If `runs` is the array
returned by `data.RecentRuns.Get()`, `runs[0]` addresses the first element, because
roblox-ts compiles normal array indexing to Luau's first slot. Accessors are not
ordinary arrays. Keeping access through `Child` makes the distinction explicit.

An unwritten dictionary or map entry can be absent. Its `Get()` result includes
`undefined`; check it before using the snapshot. Reading a child does not insert
the entry. Use accessor methods to change stored data; snapshots are not a mutable
storage interface.

The [container guide](./containers) describes caps, eviction, map keys, sets, and
the distinction between following an array index and following an element.

## Typed boundaries

The client accessor tree omits `ServerOnly` fields. Derived fields expose reads
and subscriptions without mutation methods. A root accessor has no whole-profile
`Set` or `Update`. `ServerStore`, when supplied, is inferred from its own template.

These types describe the public API and do not replace server-side validation.
Network input, arbitrary migration data, raw profile metadata, and addon-specific
payloads remain `unknown` where Scribe cannot establish their shape. Narrow them
before use. The explicit `Raw` interface is an escape hatch and cannot provide the
same schema guarantees.

### Server-wide data

Both `Scribe(options)` and `Scribe.new(options)` infer `ServerStore` independently
from the player template. In the preceding shared module, add a server template
and replace the `Data` construction with:

```ts
const serverTemplate = {
    Wave: Scribe.Int(0),
    Round: { Running: false },
    ServerSecret: Scribe.ServerOnly({ Seed: Scribe.Int(0) }),
};

export const Data = Scribe.new({
    Template: template,
    ServerStore: serverTemplate,
    ProfileStoreIndex: "PlayerData",
    ProfileKeyPrefix: "PLAYER_",
    Mode: "Mock",
});

// Server script:
Data.Server.ServerStore.Wave.Increment(1);
Data.Server.ServerStore.Round.Set({ Running: true });

// Client script:
const disconnect = Data.Client.ServerStore.Wave.Observe((wave) => print(wave));
```

Player and server templates must use different root names; overlapping roots are
rejected at startup. Client store accessors are read-only, and `ServerSecret` is
absent from their type.
The store itself is a plain map of root accessors, with no whole-store `Get`, `Set`,
or `Observe`. A root named `Get` is therefore accessible as
`Data.Server.ServerStore.Get.Get()`. Nested accessor name collisions still use
`Child(name)`. Explicit annotations can use
`Scribe.Bundle<typeof template, typeof serverTemplate>`; no separate schema format
is needed. See [server store](./server-store) for its lifetime and replication.

### Shared command contracts

Command names, argument tuples, and handler returns can be described once in your
shared data module. A contract connects independently compiled client requests and
server registrations; declarations cannot discover registrations in another file.

```ts
import Scribe from "@rbxts/scribe";

const template = { Equipped: "" };
const serverStore = { Season: 1 };

interface Commands {
    Equip: (this: void, itemId: string) => LuaTuple<[boolean, string]>;
}

export const Data = Scribe<typeof template, typeof serverStore, Commands>({
    Template: template,
    ServerStore: serverStore,
    ProfileStoreIndex: "PlayerData",
    ProfileKeyPrefix: "PLAYER_",
    Mode: "Mock",
});
```

```ts
// Server
Data.Server.Command("Equip", { Args: ["string"] }, (player, itemId) => {
    const data = Data.Server.Get(player);
    if (data === undefined) return $tuple(false, "data unavailable");
    data.Equipped.Set(itemId);
    return $tuple(true, itemId);
});

// Client
const [success, message, requestFailed] = Data.Client.Request("Equip", "Sword");
if (requestFailed === Scribe.RequestFailed) {
    warn(message); // Scribe rejected or could not complete the request.
} else if (success) {
    print(message); // The command's own result.
}
```

The runtime `Args` specification still validates incoming packets. Validate game
rules such as ownership and permissions inside the handler. Without a contract,
dynamic command names remain usable, and their arguments/results cannot receive
the same per-command checking. See [commands](./commands) for the failure marker,
rate limiting, and request lifecycle.

## Purchase prompts from a client

Declare `Products` and `Passes` in your shared Scribe options, then prompt by name
from your shop UI:

```ts
import Scribe from "@rbxts/scribe";
import { Data } from "shared/data";

const [prompted, reason, requestFailed] = Data.Client.PromptPurchase("CoinPack500");
if (requestFailed === Scribe.RequestFailed) {
    warn("Purchase prompt request failed", reason);
} else if (!prompted) {
    warn("Purchase prompt refused", reason);
}
```

The result is a `LuaTuple`. The optional third value identifies request failures,
such as a timeout, separately from eligibility refusals. The server validates the
name, ownership, and paid-random policy, then calls Roblox to open the dialog.
No custom command contract is needed. The call only targets the local player;
server code keeps using `Data.Server.PromptPurchase(player, name)`.

`prompted === true` means Roblox's prompt call succeeded. Scribe still grants purchases
through its server receipt/pass flow. A timeout or lost reply leaves the outcome unknown:
the server may already have opened the dialog. Scribe does not retry automatically,
and client `Stop()` cannot cancel a request already sent. See
[monetization](./monetization#prompting-the-sale) for repeated-click handling, refusal
codes, and receipt setup.

## Big numbers

TypeScript does not support custom operator overloads. Big values provide named
methods shared with Luau:

```ts
const essence = data.Essence.Get();
const next = essence.Multiply(2).Add("1e399");
if (next.Compare("1e400") >= 0) {
    print(next.Short());
}
```

`Add`, `Subtract`, `Multiply`, `Divide`, and `Negate` return new Big values;
`Compare` returns `-1`, `0`, or `1`; `Equals` compares numerical values. Operands can
be another Big value, a number, or a decimal string. Use these
instead of `+`, `-`, `*`, `/`, `<`, or `===` for Big arithmetic/comparisons. Stored
Big accessors keep their existing methods such as `Increment` and `Decrement`.
Numeric strings are validated at runtime and limited to 256 bytes before whitespace
removal. TypeScript checks operand types; numeric validity and bounds remain runtime
checks.
See [Big numbers](./big-numbers) for precision, formatting, and persistence.

## Diagnostics

Load phases, leaderboard health, log codes, and sink options are typed. Server code
can inspect them without making DataStore requests:

```ts
import Scribe from "@rbxts/scribe";
import { Data } from "shared/data";

function reportLoad(player: Player) {
    const [state, phase] = Data.Server.GetState(player);
    if (state === Scribe.SessionState.Loading) {
        print(phase); // Scribe.LoadPhase | undefined
    }
}

const disconnect = Scribe.AddLogSink((entry) => {
    print(entry.Code, entry.Message);
}, { Level: Scribe.LogLevel.Warn, MaxQueued: 64 });

for (const board of Scribe.GetLeaderboardSnapshot()) {
    if (board.Status === Scribe.LeaderboardStatus.Degraded) {
        warn(board.Name, board.PendingWrites, board.LastWriteError);
    }
}
```

`Data.Server.GetLeaderboardStatus(name)` returns one board's health or `undefined`
for an unknown name. `Scribe.GetLeaderboardSnapshot()` includes each running
bundle's board name and `BundleId`. Disconnect a log sink when its consumer is
destroyed. See [diagnostics](./diagnostics) and [leaderboards](./leaderboards).

## UI adapters

Each adapter is a separate optional npm package containing the same small Luau
module as its Studio counterpart. Installing `@rbxts/scribe` includes no addon
files, addon declarations, or UI framework dependencies. Install just the adapter
and framework you use:

```sh
npm install @rbxts/scribe-react @rbxts/react
# Or:
npm install @rbxts/scribe-vide @rbxts/vide
# Or, for Fusion 0.2:
npm install @rbxts/scribe-fusion @rbxts/fusion
```

```ts
import React from "@rbxts/react";
import ScribeReact from "@rbxts/scribe-react";
import { Data } from "shared/data";

const { useScribe, useScribeBinding } = ScribeReact(React);

function CoinLabel() {
    const coins = useScribe(Data.Client.Coins); // number
    return React.createElement("TextLabel", { Text: `${coins} coins` });
}
```

`useScribeBinding` returns `React.Binding<T>` for property updates without a
component re-render. Both React helpers follow React's hook rules.

```ts
import Vide from "@rbxts/vide";
import ScribeVide from "@rbxts/scribe-vide";

const useScribe = ScribeVide(Vide);
// Inside your Vide scope:
const [coins, disconnect] = useScribe(Data.Client.Coins);
Vide.cleanup(disconnect);
print(coins());
```

```ts
import Fusion from "@rbxts/fusion";
import ScribeFusion from "@rbxts/scribe-fusion";

const useScribe = ScribeFusion(Fusion); // @rbxts/fusion 0.2
const [coins, disconnect] = useScribe(Data.Client.Coins);
print(coins.get());
// Call disconnect() when the UI is destroyed.
```

The scoped Fusion overload accepts a typed Fusion 0.3 `Value(scope, initial)`
implementation plus its scope. It registers cleanup automatically and preserves
the supplied framework's additional Value members. Read a 0.3 value through that
framework's `peek`/`use`; it does not have the 0.2 `.get()` method.
`@rbxts/fusion` 0.2 is an optional peer of the Fusion adapter, so a project supplying
a compatible 0.3 implementation does not need to install the 0.2 package.

## Telemetry

Install the separate optional package after publication:

```sh
npm install @rbxts/scribe-telemetry
```

Import `ScribeTelemetry` from `@rbxts/scribe-telemetry` in a server script.
`Start`, options, routes, previews, statistics, and handle methods are typed.
Destination names are inferred from `Webhooks`, so a typo in a route or a
`handle.Test(...)` call is a type error.

Keep webhook URLs and configuration on the server. Importing the module does not
start reporting; call `Start(Scribe, options)` explicitly. See [telemetry](./telemetry)
for setup and delivery behavior.

## Leaderstats

The optional `@rbxts/scribe-leaderstats` package mirrors selected data into Roblox's
player list. Install it separately after publication:

```sh
npm install @rbxts/scribe-leaderstats
```

Start it once in a server script:

```ts
import ScribeLeaderstats from "@rbxts/scribe-leaderstats";
import { Data } from "shared/data";

const leaderstats = ScribeLeaderstats.Start(Data.Server, {
    Coins: "Coins",
});
// During teardown:
// leaderstats.Stop();
```

Names on the left are display labels; paths on the right are checked against your
template. Values update when Scribe changes them. See [Leaderstats](./leaderstats)
for supported fields, visibility, and cleanup.

## Maintaining one implementation

Runtime changes belong in `src/`; addon runtime changes belong in `addons/`.
`types/` contains the TypeScript description of those APIs. The package checks
cover valid and invalid TypeScript usage, actual roblox-ts compilation, module
resolution, and the emitted calling conventions. Luau tests continue to exercise
the shared runtime. Addon packages take the core as a peer dependency and use its
public types; the core has no dependency on them.

The shared additions for TypeScript are `Child(key)` and named Big operations.
Luau callers can use them too. No separate release branch or schema definition is
needed. Maintainers do need to update both the Luau types and TypeScript declarations
when a public API changes.
