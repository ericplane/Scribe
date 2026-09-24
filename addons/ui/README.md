# UI framework adapters

Copy-in modules bridging a Scribe client accessor to Vide, React or Fusion.

**Wally users:** `wally.toml` publishes `src` only. Copy the file you want into your game, or insert `ScribeUIAdapters-Addon.rbxm`
from the [release page](https://github.com/ericplane/Scribe/releases) and keep the one you need.

**roblox-ts users:** install the separate `@rbxts/scribe-react`, `@rbxts/scribe-vide`,
or `@rbxts/scribe-fusion` package alongside the framework you use. Each wraps these
same Luau files with declarations that preserve the accessor value type. The
[roblox-ts guide](../../docgen/guides/roblox-ts.md) has publication status, installation,
and examples. Fusion 0.2 uses the native Value shape; the scoped overload accepts a
separately supplied typed Fusion 0.3 implementation without installing Fusion 0.2.

Each takes your framework as an argument, because it lives at a path in _your_ project:

```lua
local useScribe = require(ReplicatedStorage.Shared.ScribeVide)(vide)
local coins = useScribe(Data.Coins)
```

| File                | Entry point                                                                      |
| ------------------- | -------------------------------------------------------------------------------- |
| `ScribeVide.luau`   | `require(...)(vide)` then `useScribe(accessor) -> (source, disconnect)`          |
| `ScribeReact.luau`  | `require(...)(React)` then `.useScribe` / `.useScribeBinding`                    |
| `ScribeFusion.luau` | `require(...)(Fusion, scope?)` then `useScribe(accessor) -> (Value, disconnect)` |

React targets jsdotlua **17.2.1**: `useState`, `useEffect` and `useBinding` only, never
`useSyncExternalStore` (React 18, absent from the port). Fusion takes a `scope` on 0.3 and
omits it on 0.2.

Full documentation, including the three client-mirror properties these rely on and why
another player's `Scribe.Shared` roots cannot use them:
**[UI Frameworks](https://ericplane.github.io/Scribe/ui-frameworks/)**.

`test/Specs/addons/Adapters.spec.luau` drives all three against minimal fakes and pins those
properties, so a drift in Scribe's client API fails CI rather than silently breaking every
copy already pasted into a game.
