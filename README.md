# Scribe

**Persistent, fully-typed, automatically-replicated player data for Roblox Luau, built on [ProfileStore](https://madstudioroblox.github.io/ProfileStore/).**

📖 **[Full documentation → ericplane.github.io/Scribe](https://ericplane.github.io/Scribe/)**
🔌 **[Studio plugin → Scribe Studio](https://create.roblox.com/store/asset/113609038046646/Scribe-Studio)**

```toml
# wally.toml
[dependencies]
Scribe = "ericplane/scribe@2.4.0"
```

- **Fully typed.** A type-solver-generated accessor tree types your data end to end (`data.Coins.Increment(50)`, nested containers, arrays, and datatype fields), checked at compile time.
- **Schemas all the way down.** `Scribe.ArrayOf` and `Scribe.DictOf` give array and dictionary *entries* a schema, so `data.Plots[1].Origin` is a typed `CFrame` that packs to 13 bytes, with per-element bounds and size caps.
- **Replication for free.** Schema-compressed batched diffs stream to clients over a pluggable transport, and you read the same data on the client with the same API, with no RemoteEvents to wire up.
- **Production-grade.** Migrations, a wipe guard, version history, GDPR export and erase, leaderboards, gifting and perks, and fail-closed monetization all sit on top of ProfileStore's session locking.

> [!IMPORTANT]
> The typed API needs the **new Luau type solver** (Studio: select **Workspace** and set `UseNewLuauTypeSolver` to `Enabled`; or enable it in your Luau LSP settings). Scribe runs correctly without it. `Data.Raw` is the untyped escape hatch.

## Quick start

One shared ModuleScript declares the template and returns `{ Server, Client }`.
This example uses Mock mode, so it starts fresh and does not touch saved player
data. The [step-by-step tutorial](https://ericplane.github.io/Scribe/getting-started/)
includes installation, the Studio folder structure, and how to test real saving.

```lua
-- ReplicatedStorage/Shared/Data.luau
local Scribe = require(game:GetService("ReplicatedStorage").Packages.Scribe)

return Scribe({
    Template = { Coins = 0, Settings = { Music = true } },
    ProfileStoreIndex = "PlayerData", -- required: your DataStore name
    ProfileKeyPrefix = "PLAYER_",     -- required: per-player key prefix
    Mode = "Mock",                   -- learning mode; resets between server runs
})
```

```lua
-- Script in ServerScriptService: wait for data, then change a field
local Data = require(game:GetService("ReplicatedStorage").Shared.Data).Server

game:GetService("Players").PlayerAdded:Connect(function(player)
    local data = Data.WaitForData(player) -- yields until Ready (default 60s timeout)
    if data then
        data.Coins.Increment(50)
    end
end)
```

```lua
-- LocalScript in StarterPlayer/StarterPlayerScripts
local Data = require(game:GetService("ReplicatedStorage").Shared.Data).Client

Data.Coins.Observe(function(coins)
    print("Coins:", coins) -- replace with your UI update once this works
end)
```

For declarators, replication + visibility, monetization, leaderboards, migrations, diagnostics, and the full API, see the **[documentation](https://ericplane.github.io/Scribe/)**.

Optional add-ons live in [`addons/`](addons/README.md): copy-in UI bridges for Vide, React and Fusion, and `ScribeTelemetry`, which posts Scribe's health, failures and summaries to Discord webhooks from the server.

## Development

```bash
rokit install              # wally + rojo + selene + luau-lsp + lune + stylua toolchain
wally install              # dependencies
selene src test lune addons       # lint
stylua --check src test lune addons  # formatting (drop --check to apply)
lune run lune/run-tests    # run the test suite (headless, ~2s)
```

The same lint, format, test, and type-check (luau-lsp) checks run in CI on every
pull request (`.github/workflows/ci.yml`), and releases are gated on a green run.
Mark the `test`, `lint`, `format`, `analyze`, and `version-check` checks as
required in the repository's branch-protection settings to enforce them on merge.

Docs are built with [Astro Starlight](https://starlight.astro.build/) from the doc-comments in `src/` and the guides in `docgen/guides/`. The site lives in `docs-site/`; see [docgen/README.md](docgen/README.md) for preview and check commands.

## License

MIT
