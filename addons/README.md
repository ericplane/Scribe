# Official add-ons

Optional modules maintained with Scribe, built only on its public API, and **not part of the
package**. `wally.toml` publishes `src` alone, so nothing here is installed with Scribe: copy
the folder you want into your game.

| Folder | What it is | Runs on |
| --- | --- | --- |
| [`ui/`](ui/README.md) | Copy-in bridges from a client accessor to Vide, React or Fusion. One file each. | Client |
| [`telemetry/`](telemetry/README.md) | `ScribeTelemetry`: Scribe's health, failures, selected warnings, performance rules and periodic summaries posted to Discord webhooks. | Server |

Each GitHub release also attaches them as models beside `Scribe.rbxm`: `ScribeTelemetry-Addon.rbxm`
and `ScribeUIAdapters-Addon.rbxm`, labelled as add-ons on the release page. Inserting one into Studio
is the same as copying the folder.

Each folder's README is the installation guide. The docs site has the longer treatment:
[UI Frameworks](https://ericplane.github.io/Scribe/ui-frameworks/) and
[Discord Telemetry](https://ericplane.github.io/Scribe/telemetry/).

Add-ons are versioned with Scribe and tested in its suite (`test/Specs/addons/Adapters.spec.luau`,
`test/Specs/addons/Telemetry*.spec.luau`), so a change to the API they rely on fails CI here rather
than in your game. They are linted, formatted and type-checked under the same gate as `src`.
