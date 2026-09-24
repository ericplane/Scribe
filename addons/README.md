# Official add-ons

Optional modules maintained with Scribe, built only on its public API. **Wally publishes
`src` alone**: copy the folder you want into your game.

For roblox-ts, each addon is a separate optional npm package: `@rbxts/scribe-react`,
`@rbxts/scribe-vide`, `@rbxts/scribe-fusion`, `@rbxts/scribe-telemetry`, and
`@rbxts/scribe-leaderstats`. The core package includes none of their runtime files,
declarations, or framework dependencies. See the [roblox-ts guide](../docgen/guides/roblox-ts.md)
for installation and publication status. All packages use the same Scribe version.

| Folder | What it is | Runs on |
| --- | --- | --- |
| [`ui/`](ui/README.md) | Copy-in bridges from a client accessor to Vide, React or Fusion. One file each. | Client |
| [`telemetry/`](telemetry/README.md) | `ScribeTelemetry`: Scribe's health, failures, selected warnings, performance rules and periodic summaries posted to Discord webhooks. | Server |
| [`leaderstats/`](leaderstats/README.md) | `ScribeLeaderstats`: selected data fields mirrored into Roblox's player list, updated on change. | Server |

Each GitHub release also attaches them as models beside `Scribe.rbxm`: `ScribeTelemetry-Addon.rbxm`
and `ScribeUIAdapters-Addon.rbxm`, plus `ScribeLeaderstats-Addon.rbxm`, labelled as add-ons on the release page. Inserting one into Studio
is the same as copying the folder.

Each folder's README is the installation guide. The docs site has the longer treatment:
[UI Frameworks](https://ericplane.github.io/Scribe/ui-frameworks/) and
[Discord Telemetry](https://ericplane.github.io/Scribe/telemetry/), and
[Leaderstats](../docgen/guides/leaderstats.md).

Add-ons are versioned with Scribe and tested in its suite (`test/Specs/addons/Adapters.spec.luau`,
`test/Specs/addons/Telemetry*.spec.luau`, `test/Specs/addons/Leaderstats.spec.luau`), so a change to the API they rely on fails CI here rather
than in your game. They are linted, formatted and type-checked under the same gate as `src`.
