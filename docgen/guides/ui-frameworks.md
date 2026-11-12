# UI Frameworks

Scribe's client accessors already have the shape a reactive UI framework wants: a value you can read, and a subscription that tells you when it moved. Bridging one takes about five lines, and the repo ships those five lines for [Vide](https://github.com/centau/vide), [React](https://github.com/jsdotlua/react-lua) and [Fusion](https://github.com/dphfox/Fusion) so you do not have to write them.

They live in [`addons/ui/`](https://github.com/ericplane/Scribe/tree/main/addons/ui). **Wally installs `src` only**, so copy the file you want into your game and name it whatever suits your project, or insert `ScribeUIAdapters-Addon.rbxm` from the [release page](https://github.com/ericplane/Scribe/releases), a folder holding all three. The snippets below call the modules `ScribeVide`, `ScribeReact` and `ScribeFusion` to keep them distinct from the framework itself. Each one takes your framework as an argument, because the framework sits at a path in your project that Scribe cannot know:

```lua
local useScribe = require(ReplicatedStorage.Shared.ScribeVide)(vide)
local coins = useScribe(Data.Coins)
```

## roblox-ts

The adapters are separate optional packages: `@rbxts/scribe-react`,
`@rbxts/scribe-vide`, and `@rbxts/scribe-fusion`. Install only the adapter and
framework your game uses. The core package includes none of these dependencies.
See [roblox-ts](roblox-ts.md) for all three installation examples.

```ts
import React from "@rbxts/react";
import ScribeReact from "@rbxts/scribe-react";
import { Data } from "shared/data";

const { useScribeBinding } = ScribeReact(React);

function CoinLabel() {
    const coins = useScribeBinding(Data.Client.Coins); // React.Binding<number>
    return React.createElement("TextLabel", {
        Text: coins.map((value) => `${value} coins`),
    });
}
```

React hooks retain the accessor's value type, including `undefined` for an absent
entry. Vide returns a typed source and disconnect through a `LuaTuple`, so use
`const [value, disconnect] = useScribe(accessor)`. Fusion returns a Value and
disconnect in the same way. Its scoped 0.3 overload accepts your typed framework
implementation and preserves its additional Value members; it does not require
installing the 0.2 framework. Cleanup behavior is the same as in the Luau examples.

## Types in Luau

All three accept typed accessors in strict Luau. Vide and React preserve the field's type; Fusion needs an annotation:

| Adapter | Result for `Data.Coins` |
| --- | --- |
| Vide | `Source<number>` and a `Disconnect` |
| React | `number` from `useScribe`, `Binding<number>` from `useScribeBinding` |
| Fusion | a Fusion `Value`, typed `any`, and a `Disconnect` |

Each module exports `Readable<T>` and `Disconnect` for helpers. Annotate Fusion's result with the type from your installed version:

```lua
local coins: Fusion.Value<number>, disconnect = useScribe(Data.Coins)
```

Copy older adapters again to get the updated types.

## Vide

```lua
local useScribe = require(path.to.ScribeVide)(vide)

local function CoinLabel()
    local coins, disconnect = useScribe(Data.Coins)
    vide.cleanup(disconnect)
    return vide.create("TextLabel")({
        Text = function()
            return `{coins()} coins`
        end,
    })
end
```

Vide sources have getter and setter overloads. For optional or `any`-typed values, Luau may find a call with no arguments ambiguous. Cast to a getter when reading one:

```lua
local score = useScribe(Data.Score) -- a Scribe.Optional field
local text = function()
    return `{(score :: () -> number?)() or 0} points`
end
```

## React

```lua
local ScribeReact = require(path.to.ScribeReact)(React)

local function CoinLabel()
    local coins = ScribeReact.useScribe(Data.Coins)
    return React.createElement("TextLabel", { Text = `{coins} coins` })
end
```

Use `useScribe` when the value decides what the component renders. The hook gives React a shallow copy of a table so an `Insert`, `Remove` or child write that changes the mirror in place can trigger a render. If you copied the React adapter from 2.6.1 or earlier, replace it with the current file. For a value that only feeds a property, `useScribeBinding` updates the property without re-rendering the component.

```lua
local coins = ScribeReact.useScribeBinding(Data.Coins)
return React.createElement("TextLabel", {
    Text = coins:map(function(c)
        return `{c} coins`
    end),
})
```

It is built on `useState`, `useEffect` and `useBinding`, the three hooks jsdotlua React 17.2.1 exports. It deliberately avoids `useSyncExternalStore`, which is the React 18 hook for this job and does not exist in the Roblox port.

## Fusion

```lua
local useScribe = require(path.to.ScribeFusion)(Fusion, scope)  -- 0.3
local useScribe = require(path.to.ScribeFusion)(Fusion)         -- 0.2

local coins: Fusion.Value<number>, disconnect = useScribe(Data.Coins)
```

On 0.3 the disconnect is registered in the scope as well as returned, so `doCleanup(scope)` stops the Scribe listener with everything else, and calling the returned one early is safe. On 0.2 there is no scope, so call it yourself when the UI goes away.

## Why they are this short

**Reading a field.** Repeated `Get()` calls on an ordinary array, dictionary or record return the same table until the mirror replaces it. A `Scribe.Big` value is rebuilt on read, as is a container whose schema includes a `Big` or a packed Roblox datatype. Reading the whole data root also builds a fresh table. Treat the returned values as read-only.

**Receiving a resync.** The client rebuilds its containers from the snapshot and each observed container fires `Changed` once. An unchanged number, string or boolean stays quiet.

**Receiving repeated scalar writes.** Three `Increment` calls on the same field inside a [`Data.Batch`](./values) reach the client as one `Changed` with the final value.

??? note "Observe rather than Changed, and why it matters here"
    The Vide and Fusion adapters subscribe with `Observe`, not `Changed`. `Observe` delivers the current value before it returns, which closes the gap between reading the initial value and subscribing to later ones. With `Changed` a write landing in that gap is lost and the UI sits on a stale first value.

    The React adapter cannot use it, because a hook must return a value during render and the subscription only happens later in an effect. It re-reads with `Get()` at the top of the effect instead, which closes the same gap.

## What they cannot do

Another player's [`Scribe.Shared`](./visibility) roots have **no accessor**, so they cannot go through these adapters at all. [`Data.GetShared`](/api/Client#GetShared) returns a plain table and [`Data.OnSharedChanged`](/api/Client#OnSharedChanged) is the notification:

```lua
Data.OnSharedChanged:Connect(function(userId, sharedData)
    local pets = sharedData and sharedData.EquippedPets
    -- sharedData is nil when that player leaves
end)
```

`Data.GetShared(localPlayer)` is always `nil`, and permanently so rather than pending: the server broadcasts a player's Shared data to everyone except that player. Read your own through the ordinary accessor, which the adapters handle.

## Where to next

- [Reading & Writing Values](./values) covers `Get`, `Changed`, `Observe` and `Batch`.
- [Replication & Visibility](./visibility) decides which fields reach the client at all.
- [Commands & Requests](./commands) is how a button asks the server to change something.
