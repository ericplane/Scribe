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
lune run lune/run-tests
stylua --check src test lune addons
selene src test lune addons
npm ci
npm test
```

Specs live in `test/Specs/<topic>/`, one folder per subsystem (`persistence`, `replication`,
`monetization`, `addons` and so on). A new spec goes in the folder of the code it covers; the
runner walks the folders and names the test by the file, so the folder is for the reader. A spec
starts with `local Root = script.Parent.Parent.Parent.Parent`, which is the test place root from
one folder down.

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
the npm package does not publish it.

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
