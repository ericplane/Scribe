# Contributing to Scribe

## Naming the strings a public API returns

Every string a public API returns is one of two things: a stable identifier a caller branches
on, or text a game shows and may reword. That distinction decides the design; the casing only
follows from it.

| Kind | Casing | Used for | Examples |
| --- | --- | --- | --- |
| State or category | `PascalCase` | a stable value a caller switches on, naming a thing or a condition | `Status`, `LogLevel`, `LogCategory`, `SessionState`, `OpKind`, `Visibility` |
| Status or reason code | `kebab-case` | a stable value a caller switches on, naming what happened to a call or a session; a normal outcome as often as a refusal | `LifecycleReason`, `RequestReason`, `ProductState` |
| Sentence | lower case, spaces, no trailing period | the answer a call gives when it did not proceed, readable as it is: most members are text a game can show a player, the rest are diagnostics for the developer who wrote the call | `PurchaseReason`, `GiftReason` |

Four rules follow from that table.

**Never mix kinds inside one union.** A union whose members are sentences promises that every
member is a sentence, and callers rely on it. If a new refusal has no sensible sentence, that is
a sign it belongs in a different union rather than a sign to add a code to this one.

**For PascalCase unions the member name and the value are the same word.** `Scribe.Status.Healthy`
is `"Healthy"`. They differ only for the code and sentence kinds, where the value is a code or
display text and the member name is the identifier.

**Every union gets a frozen table on `Scribe`**, named after the type it holds, so a caller can
branch on a constant instead of pasting a string. The constant is what makes the value stable: a
game that branches on `Scribe.PurchaseReason.InsufficientFunds` is untouched if the wording ever
moves. `Scribe.Reason` predates this rule and holds `LifecycleReason`; `Scribe.LifecycleReason`
is the same table under the matching name, and both stay.

**A sentence union says which members a player may see.** `"insufficient funds"` is for the
player. `"invalid Cost spec"` is for the developer who wrote the call, and no wording makes it
otherwise. The guide for the call marks each member, and a game shows the player-facing ones and
logs the rest.

The same condition can appear in two unions with two spellings, and that is on purpose.
`Data.PromptPurchase` answers with a `ProductState` code because a shop branches on it, while
`Data.Purchase` and `Data.PromptGift` answer with a sentence because a game shows it; both branch
on the frozen constants either way. What matters is that each union stays internally consistent.

Published strings are not renamed to unify casing. A game that matches them is broken by a rename
and gains nothing from it. A call that needs both a code and a message grows a second return
value beside the sentence rather than changing it.

## Before you open a pull request

Run what CI runs:

Package builds and `npm test` need Python 3.10+ alongside the Rokit and Node.js tools.
The npm scripts use `python`; set `SCRIBE_PYTHON` if yours has a different path.

```bash
rokit install
wally install
lune run lune/run-tests
SCRIBE_FRAGMENT_ALL=1 SCRIBE_TEST_REPORT_DIR=test-results/fragment lune run lune/run-tests
node scripts/verify-test-runner.mjs
stylua --check src test lune addons
selene src test lune addons
npm ci
npm test
```

Specs live in `test/Specs/<topic>/`, one folder per subsystem (`persistence`, `replication`,
`monetization`, `addons` and so on). A new spec goes in the folder of the code it covers; the
runner discovers `*.spec.luau` modules recursively. The suite uses the official Jest Roblox
packages pinned by `wally.toml` and `wally.lock`, with the same `test/jest.config.luau` in Lune
and Studio. Import test APIs from `JestGlobals` explicitly and register tests at module scope:

```lua
local Root = script.Parent.Parent.Parent.Parent
local JestGlobals = require(Root.DevPackages.JestGlobals)
local describe, it, expect = JestGlobals.describe, JestGlobals.it, JestGlobals.expect

describe("example", function()
    it("adds", function()
        expect(1 + 1).toBe(2)
    end)
end)
```

`Root` is the test place root for a spec one topic folder below `Specs`. Test callbacks use
Jest matchers, such as `toBe`, `toEqual`, and `toThrow`. Use `afterEach` for cleanup that must
run after a failed assertion. Scribe's deterministic simulations retain their own clocks,
schedulers, and isolated server modules; Jest runs those scenarios without replacing them
with Jest fake timers.

Specs that call the public server constructor use `test/Helpers/ConstructorScope.luau`:
install the scope in `beforeEach`, then clean it in `afterEach` and `afterAll`. It drains
the fixtures' private fake stores, stops their bundles, and releases their shutdown
registrations before the test finishes. `Data.Stop()` alone deliberately leaves final
session saving to shutdown, so it is not sufficient cleanup for these fixtures.

For binary payloads, use `expect(actualBuffer).toEqualBuffer(expectedBuffer)`. It checks every
byte and reports the first difference in hex, so invalid UTF-8 cannot break Jest's error
formatter. `toBeWithin(expected, tolerance)` checks absolute numerical error, including the
boundary; its default tolerance is `1e-7`.

The headless runner accepts `SCRIBE_SPECS` as comma-separated spec-path substrings,
`SCRIBE_TEST_NAME` as a Jest test-name pattern, `SCRIBE_TEST_TIMEOUT` for the per-test timeout
in seconds (default 10), and `SCRIBE_TEST_REPORT_DIR` for its report directory
(default `test-results`). It writes `results.json` and `junit.xml`, and exits unsuccessfully
for failed tests, load errors, timeouts, focused tests, or an empty selection. For example,
in a POSIX shell:

```bash
SCRIBE_SPECS=Signal SCRIBE_TEST_TIMEOUT=20 lune run lune/run-tests
```

In PowerShell, set `$env:SCRIBE_SPECS = "Signal"` before running the command, then remove it
with `Remove-Item Env:SCRIBE_SPECS`. `npm run test:unit` runs the headless suite;
`npm run test:runner` verifies that the runner detects intentional failures and emits reports.
`npm test` continues to check declarations, package builds, and compiled roblox-ts consumers.
Set `SCRIBE_TEST_VERBOSE=1` to print individual test names.
Jest's per-test timeout requires the scheduler to run: a tight loop that never yields can
still block a direct local Lune invocation. Stop that process with Ctrl+C. CI bounds the
normal and fragment runs with separate process deadlines, and the runner verifier checks
that an external deadline terminates the intentionally non-yielding fixture.

Snapshots live beside their specs in `__snapshots__/<name>.spec.snap.lua`. Rojo maps these
files as ModuleScripts for the same comparison in Studio. Normal runs compare snapshots
without writing. To create or intentionally update one locally, set `SCRIBE_UPDATE_SNAPSHOTS=1`,
run the relevant specs, and review the snapshot diff. Updates are rejected when `CI` is set.
For example, in a POSIX shell:

```bash
SCRIBE_SPECS=wire/WireGolden SCRIBE_UPDATE_SNAPSHOTS=1 lune run lune/run-tests
```

To run the engine-compatible specs in Studio, install Wally dependencies, build
`rojo build test.project.json -o ScribeTest.rbxlx`, open the place, and press Run (F8).
`ServerScriptService.RunScribeTests` prints a startup banner and the number of spec modules.
Ordinary server Scripts cannot read the source that Jest needs, so Output explains that the
tests are waiting and prints the next command. While Run is active, execute it in the
**server command bar**:

```lua
require(game:GetService("ReplicatedStorage").ScribeDev.Test.RunTests)()
```

Jest needs the command bar's script-source permissions; an ordinary server Script cannot
provide them. The isolated test place enables `ServerScriptService.LoadStringEnabled` for
Jest's fallback loader. `RunTests` checks the running server context and loading permissions,
reports to Output, and raises on failure or no tests. It accepts Jest CLI options such as
`{ verbose = true, testNamePattern = "Signal" }`. Simulation specs that need the Lune host
remain headless-only. A normal Studio run has been confirmed: 2,813 tests passed, 360 skipped,
none failed, and both snapshots passed.

The default suite does not write to cloud DataStores. To opt into the real backend checks,
use a disposable published test universe with Studio API access enabled. Before starting Run,
edit `test/Helpers/ConformanceStore.luau` so its source sets `ConformanceStore.UseReal = true`,
then rebuild or sync the place. Changing the table returned by an external `require` does not
enable these checks because Jest loads its own isolated module instances. Restore the source
to `false` when finished.

Real backend tests and their setup have a 600-second ceiling; cleanup has 60 seconds.
Ordinary tests retain the 10-second default. Live tests include deliberate write pacing,
session loading, and save confirmation. The shared exchange round trip runs once, and cleanup
hooks release owned harnesses after failures or timeouts. After an earlier failed cloud run,
stop Studio's Run session and start a fresh one before retrying, so leftover sessions and
subscriptions from that run cannot affect the result.

Specs are expected to survive mutation. A spec that passes when the code it covers is broken is
not evidence, so when you add one, break the line it guards and confirm the spec fails.

## Maintaining roblox-ts support

`src/` is the shared implementation for Wally, the Studio model, and npm. Keep runtime
fixes there; do not create a TypeScript port or a second implementation in the declaration
files. Published RBXM, Wally, and npm packages omit long API doc blocks but keep concise
comments, types, and directives. The repository retains the full documentation.
Declarations in `types/` are copied unchanged into npm packages. See
[release packaging](bundle/README.md) for staging and source-line maps.

Public API changes need corresponding declarations and examples. Preserve the distinction
between closure properties (Scribe accessors and most server/client APIs, called with a dot)
and methods (signals, connections, telemetry handles, and Big values, called with a colon).
Use `LuaTuple` for multiple returns. A declaration that makes TypeScript happy but causes
roblox-ts to emit the wrong calling convention is a runtime bug.

Add meaningful compile-pass and compile-fail cases for schema inference, restricted APIs,
and optional values. Include representative calls in the roblox-ts compiler fixture so the
emitted Luau and module paths are checked as well. Addons are separate optional npm
packages: `@rbxts/scribe-react`, `@rbxts/scribe-vide`, `@rbxts/scribe-fusion`,
`@rbxts/scribe-telemetry`, and `@rbxts/scribe-leaderstats`. The core package must not include their runtime files,
declarations, or framework dependencies. Each addon depends on the core package's types
and uses the caller's framework installation.

Container accessor positions remain one-based; plain TypeScript array snapshots remain
zero-based in source code. `Child(key)` passes its key unchanged, including numeric map
keys and field names that overlap with accessor methods. Do not silently convert indices
in the shared runtime.

All distributions use the same Scribe version. Update `package.json`, `package-lock.json`,
`wally.toml`, and `src/Internal/Version.luau` together when preparing a release.
`npm version <version> --no-git-tag-version` updates both npm files. Building and testing
the npm package does not publish it. Run `wally install` after updating the Wally manifest
and commit its regenerated `wally.lock` too.

### npm release setup

The core and five optional addons are built from the same repository, version, and tag.
Before enabling automated publication, establish ownership of all six npm names. Initial
package creation requires a manual authenticated publish. In each package's npm
settings, configure a trusted publisher for the `ericplane/Scribe` GitHub repository and
workflow `publish-npm.yml`, with direct publishing permitted.

Only after every package and trusted publisher is configured, set the repository variable
`SCRIBE_NPM_PUBLISH` to `true`. The workflow can then publish all six packages from the
same release. Keep that variable unset until setup is complete; building release artifacts
does not mean a package has been published to npm.

#### First publication, step by step

1. Sign in to npm and enable two-factor authentication for your account. For the default
   package names, [join the `@rbxts` organization](https://roblox-ts.com/join-org/) using
   your **npm username**. Your account needs permission to create packages in that scope.
2. Use Node.js 24 with npm 11.5.1 or newer and Python 3.10+. Commit and push the release changes, including
   `.github/workflows/publish-npm.yml`, to the repository. Keep `SCRIBE_NPM_PUBLISH` unset
   throughout the first manual publication and its initial GitHub release.
3. Open a terminal in the Scribe repository and run the following commands. The tests
   require the repository's Rokit tools, including Lune; run `rokit install` first if needed.
   Stop and resolve any failed command before continuing.

```sh
npm ci
wally install
npm test
npm run build
npm login
npm whoami
```

`npm login` opens an authentication flow in your browser. Check that `npm whoami` reports
the npm account you added to `@rbxts`. The build uses the version already in `package.json`
and checks that it matches `wally.toml` and `src/Internal/Version.luau`.

4. Publish the generated core package first, then each addon. Complete any browser/2FA
   prompts from npm. These commands make the packages public; run each one only once for
   this version. Do not run a bare `npm publish` from the repository root, which is private.

```sh
npm publish ./dist/npm --access public
npm publish ./dist/npm-addons/react --access public
npm publish ./dist/npm-addons/vide --access public
npm publish ./dist/npm-addons/fusion --access public
npm publish ./dist/npm-addons/telemetry --access public
npm publish ./dist/npm-addons/leaderstats --access public
```

These commands assume a stable version, such as the initial `2.5.0`. If bootstrapping a
prerelease instead (for example, `2.6.0-beta.1`), add `--tag next` to each publish command.

5. On npm, verify that all six package pages exist under your account:
   `@rbxts/scribe`, `@rbxts/scribe-react`, `@rbxts/scribe-vide`, `@rbxts/scribe-fusion`,
   `@rbxts/scribe-telemetry`, and `@rbxts/scribe-leaderstats`. If a later publish failed, resume with that package after
   correcting the failure; do not republish the packages that succeeded.
6. If the initial version still needs a GitHub release, publish it now with the matching
   version tag while `SCRIBE_NPM_PUBLISH` is still unset. The npm workflow checks package
   contents but does not publish. Do not recreate an existing release/tag or rerun this
   manually published version with npm automation enabled; start automation with the next
   version. Published npm versions are immutable, and locally packed files can differ from
   GitHub's checkout (for example, Windows line endings).

#### Connect npm to GitHub Actions

For **each of the six packages**, open its npm page, choose **Settings**, then find
**Trusted publishing** and add a **GitHub Actions** publisher with these exact values:

| Field | Value |
| --- | --- |
| Organization or user | `ericplane` |
| Repository | `Scribe` |
| Workflow filename | `publish-npm.yml` (filename only) |
| Environment name | Leave blank |
| Allowed actions | Enable direct publishing with `npm publish` |

Save the configuration for each package. Stage-only permission is insufficient for
unattended releases. There is no `NPM_TOKEN` secret to create; this workflow uses GitHub's
short-lived identity. See [npm's trusted publishing guide](https://docs.npmjs.com/trusted-publishers/).

After all six publishers are configured and the initial release's npm workflow has
finished (including its CI gate and preview), open
`ericplane/Scribe` on GitHub and go to **Settings > Secrets and variables > Actions >
Variables > New repository variable**. Enter the name `SCRIBE_NPM_PUBLISH`, the value
`true`, and save. This is a repository **variable**, not a secret or environment variable.

#### Future releases

1. Choose a new shared version. For example, if the initial version was `2.5.0`, use
   `2.6.0` for the next minor release. Run `npm version 2.6.0 --no-git-tag-version` to update
   `package.json` and `package-lock.json`, then set the same version in `wally.toml` and
   `src/Internal/Version.luau`. Update the README's Wally install version and changelog too.
   Run `wally install` to refresh `wally.lock` for that version.
2. Run `npm test`, commit and push all release changes, and wait for CI to pass.
3. On GitHub, open **Releases > Draft a new release**. Create the matching tag (for example,
   `v2.6.0`) at the release commit, add the release notes, and click **Publish release**.
   Saving a draft or pushing a tag alone does not trigger this npm workflow.
4. Open **Actions > Publish to npm**. After the shared CI gate passes, the workflow builds
   and publishes the core and all five addons. Verify the new version on each npm page.

The workflow uses `latest` for ordinary version numbers and `next` for versions containing
a prerelease suffix such as `2.6.0-beta.1`. Choosing GitHub's prerelease checkbox alone does
not determine the npm distribution tag. Each new addon package needs its own first manual
publication and trusted publisher before joining subsequent automated releases.
