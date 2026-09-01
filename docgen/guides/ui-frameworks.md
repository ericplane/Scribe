# UI Frameworks

Scribe's client accessors already have the shape a reactive UI framework wants: a value you can read, and a subscription that tells you when it moved. Bridging one takes about five lines, and the repo ships those five lines for [Vide](https://github.com/centau/vide), [React](https://github.com/jsdotlua/react-lua) and [Fusion](https://github.com/dphfox/Fusion) so you do not have to write them.

They live in [`adapters/`](https://github.com/ericplane/Scribe/tree/main/adapters) and are **not part of the package**. Wally installs `src` only, so copy the file you want into your game. Each one takes your framework as an argument, because the framework sits at a path in your project that Scribe cannot know:

```lua
local useScribe = require(ReplicatedStorage.Shared.ScribeVide)(vide)
local coins = useScribe(Data.Coins)
```

## Vide

```lua
local useScribe = require(path.to.Vide)(vide)

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

## React

```lua
local ScribeReact = require(path.to.React)(React)

local function CoinLabel()
    local coins = ScribeReact.useScribe(Data.Coins)
    return React.createElement("TextLabel", { Text = `{coins} coins` })
end
```

`useScribe` re-renders the component on every change, which is what you want when the value decides *what* is rendered. When it only feeds a property, `useScribeBinding` updates that property without re-rendering at all:

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
local useScribe = require(path.to.Fusion)(Fusion, scope)  -- 0.3, which takes a scope
local useScribe = require(path.to.Fusion)(Fusion)         -- 0.2, which does not

local coins, disconnect = useScribe(Data.Coins)
```

On 0.3 the scope destroys the `Value` but never the Scribe listener, so still call the disconnect when the UI goes away.

## Why they are this short

Three properties of the client mirror do the work. Each is measured and pinned by a spec, so an adapter already pasted into your game keeps working.

**`Get()` is referentially stable.** Two calls with nothing changing in between return the same table, for scalars, containers and records alike. A fresh table per call would make a React memo or a Vide derived recompute forever, and it stays invisible until a UI is built on it.

**That survives a resync.** A dropped frame makes the client re-handshake and rebuild its mirror from defaults. The reference is unchanged across that when the value is, so a hiccup costs no spurious re-render and fires no spurious listener.

**One frame of writes is one notification.** Three `Increment` calls inside a [`Data.Batch`](./values) reach the client as a single `Changed`. No adapter needs to debounce.

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
