# Scribe

**Persistent, fully-typed, automatically-replicated player data for Roblox Luau, built on [ProfileStore](https://madstudioroblox.github.io/ProfileStore/).**

📖 **[Full documentation → ericplane.github.io/Scribe](https://ericplane.github.io/Scribe/)**
🔌 **[Studio plugin → Scribe Studio](https://create.roblox.com/store/asset/113609038046646/Scribe-Studio)**

```toml
# wally.toml
[dependencies]
Scribe = "ericplane/scribe@1.0.8"
```

- **Fully typed.** A type-solver-generated accessor tree types your data end to end (`data.Coins.Increment(50)`, nested containers, arrays, and datatype fields), checked at compile time.
- **Replication for free.** Schema-compressed batched diffs stream to clients over a pluggable transport, and you read the same data on the client with the same API, with no RemoteEvents to wire up.
- **Production-grade.** Migrations, a wipe guard, version history, GDPR export and erase, leaderboards, gifting and perks, and fail-closed monetization all sit on top of ProfileStore's session locking.

> [!IMPORTANT]
> The typed API needs the **new Luau type solver** (Studio: select **Workspace** and set `UseNewLuauTypeSolver` to `Enabled`; or enable it in your Luau LSP settings). Scribe runs correctly without it. `Data.Raw` is the untyped escape hatch.

## Quick start

One shared module declares the template and options and returns `{ Server, Client }`:

```lua
-- ReplicatedStorage/Shared/Data.luau
local Scribe = require(game:GetService("ReplicatedStorage").Packages.Scribe)

return Scribe({
    Template = { Coins = 0, Settings = { Music = true } },
    ProfileStoreIndex = "PlayerData", -- required: your DataStore name
    ProfileKeyPrefix = "PLAYER_",     -- required: per-player key prefix
})
```

```lua
-- Server: wait for the profile to load, then use the typed accessor
local Data = require(game:GetService("ReplicatedStorage").Shared.Data).Server

game:GetService("Players").PlayerAdded:Connect(function(player)
    local data = Data.WaitForData(player) -- yields until Ready (or ~60s timeout)
    if data then
        data.Coins.Increment(50)
    end
end)
```

```lua
-- Client: read the same data reactively (writes are local-only; server wins)
local Data = require(game:GetService("ReplicatedStorage").Shared.Data).Client

Data.Coins.Observe(function(coins)
    coinsLabel.Text = tostring(coins)
end)
```

For declarators, replication + visibility, monetization, leaderboards, migrations, diagnostics, and the full API, see the **[documentation](https://ericplane.github.io/Scribe/)**.

## Development

```bash
rokit install              # wally + rojo + selene + luau-lsp + lune + stylua toolchain
wally install              # dependencies
selene src test lune       # lint
stylua --check src test lune  # formatting (drop --check to apply)
lune run lune/run-tests    # run the test suite (headless, ~1s)
```

The same lint, format, test, and type-check (luau-lsp) checks run in CI on every
pull request (`.github/workflows/ci.yml`), and releases are gated on a green run.
Mark the `test`, `lint`, `format`, `analyze`, and `version-check` checks as
required in the repository's branch-protection settings to enforce them on merge.

Docs are built with Material for MkDocs from the doc-comments in `src/` and the guides in `docgen/guides/`. See [docgen/README.md](docgen/README.md) for details.

## License

MIT
