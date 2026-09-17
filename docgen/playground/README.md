# Scribe documentation playground

The playground page runs Scribe's real template compiler and field accessors in
the visitor's browser. It uses the actual Scribe source, not a JavaScript
implementation of its rules. It is documentation tooling only and adds nothing to
the shipped Roblox module.

## Pieces

- `docs-site/src/pages/playground.astro` is the page. It renders inside the
  Starlight shell and loads the editor from `docs-site/src/playground/`.
- `docs-site/src/playground/` is the editor: CodeMirror with a Luau mode, hover tooltips,
  completions, and diagnostics. Astro bundles it with the site.
- `theme/assets/playground/` holds the runtime assets the page fetches:
  `worker.mjs`, `presets.json`, and the vendored `runtime/`. `gen.py` copies them
  into `docs-site/public/assets/playground/` and then writes `runtime.luau`,
  `metadata.json`, and `api.json` beside them.
- `build.py` generates the runtime bundle and `bootstrap.luau` is appended to it.

## Build and check

From the repository root, generate the docs and run:

```sh
python docgen/gen.py
node docgen/playground/check.mjs
```

The check executes the same generated source, presets, and vendored WebAssembly
runtime the browser uses. Every preset has assertions on its output and final
data. The check also covers protected calls, unsupported services, the absence of
any JavaScript constructor through the print binding, output formatting, snapshot
limits, the execution deadline, the schema `describe()` returns for the editor,
and the `api.json` entries the completions rely on. Browser layout, the Stop
button, worker deadlines, and the editor itself are checked in the rendered page.

## Source adapter

`build.py` wraps these source files in module closures, changing only their
`require(script.Parent.X)` expressions to local module references:

`Datatypes`, `Util`, `Marker`, `Big`, `Derived`, `Clock`, `Metrics`, `Template`, `Node`.

It then lifts the public declarators and helpers verbatim from `src/init.luau`:
the `ServerOnly`, `Shared` and `Session` wrappers; `Int`, `Number`, `Big`,
`String`, `Enum`, `Flags`, `Dynamic`, `Derived`, `Optional`, `ArrayOf`, `SetOf`,
`MapOf` and `DictOf`; and `Short` with `SetShortSuffixes`. A body that references
anything beyond `Marker`, `BigMath` and Luau globals fails generation so the
adapter gets reviewed. `Scribe.Timed` is a stub that explains it needs the server
scheduler. The Roblox datatype declarators are absent because they need the
engine's datatypes. The bundle deliberately avoids the full public entry point,
which loads Roblox server services and type functions beyond this scope.

`bootstrap.luau` creates an in-memory template and accessor tree. The only service
shim returns an inert HttpService handle so Util can load. Calling GUID generation
or scheduling work throws an explicit unsupported-feature error. No fake saving,
purchase, player, or networking success is reported. `print` and `warn` format
their arguments in Luau so nil, tables and floats read as they do in Studio.

The runtime chunk returns two functions. `run(template, actions, policy)` builds
the tree, runs the actions with `data` and `Scribe`, and returns the before and
after snapshots. `describe(template)` compiles the template alone and returns its
field schema as JSON; the editor uses it for field completions, the Fields panel,
and its own checks. Template and action functions are compiled separately from
the bundle; internal tree and store objects are not exposed.

`api.json` is written by `gen.py` from the same doc comments as the API pages:
the declarators, `Scribe.Short`, and every `Value` and `BigValue` member with its
signature and first paragraph. The editor shows these as completion details.

The generated metadata records the Scribe version and SHA-256 of the complete
runtime source. This runtime compiles and executes Luau. The editor reports
syntax errors from the real compiler and template errors from the real compiler
of templates, plus its own checks against the compiled schema: unknown fields,
methods that do not fit a field, writes to derived fields, literal values of the
wrong type, and field names an accessor method would shadow. It does not run
Luau's static type checker; that needs a separate Luau analysis runtime and
Roblox definitions, and it cannot be inferred from successful execution.

## Browser isolation and limits

Each Run and each check creates a fresh module worker. Only bounded print/warn
output is bridged to JavaScript. Luau receives no DOM, fetch, filesystem,
JavaScript evaluation, or Roblox service bindings. All dependency assets are
served locally by the docs site.

The page stops a run's worker after 15 seconds of loading or 2 seconds of
execution, and a check's worker after 4 seconds. Each editor is limited to
12,000 characters, output to 12,000 characters, and displayed snapshots to
bounded depth and entry counts. These are responsiveness limits, not a guarantee
against every browser out-of-memory condition; the playground should not be
advertised as a hardened arbitrary-code hosting service. Nothing runs until the
visitor selects Run, checks only compile, and navigation terminates active workers.

The Copy link button stores the template, actions and bounds policy in the URL
fragment. A fragment never reaches the server, and loading one only fills the
editors; it does not run anything.

## Runtime dependency

`theme/assets/playground/runtime/` vendors **luau-web 1.4.0**, by xNasuni,
whose npm package declares MIT licensing. Its source uses the Luau Interop fork.
The selected Asyncify artifact includes its WebAssembly payload, so it does not
download a separate runtime or use an execution service.

The loader always selects Asyncify, including in browsers with JSPI. This avoids
the [reported JSPI protected-call inconsistency](https://github.com/PytechNo/Weblua/blob/main/README.md).
The regression checks specifically exercise `pcall` and `xpcall`.

The generated host script also has one worker-environment refusal assertion
removed. The upstream artifact already contains a shared `WEB || WORKER` branch
using `fetch`, with no DOM dependency; its other worker references only detect
the environment. The embedded WebAssembly payload is unchanged. This small host
adaptation must be retested in an actual browser worker on runtime updates:
Node's worker_threads do not expose WorkerGlobalScope and missed the upstream
refusal. Execution must never fall back to the page's UI thread.

`PROVENANCE.json` records the npm version, package source commit, upstream URLs,
original checksums, and local checksums. The docs build verifies those checksums.
`NOTICE.txt` identifies the licenses; the original Luau, Lua, and Emscripten license
texts are retained alongside it. Upstream does not include a separate license text
for the binding package, so its original package manifest is retained as the
source of its MIT declaration.

To update, review the upstream release and licenses, replace the pinned artifacts,
apply the documented host changes, update provenance, and run both the checks and
the browser smoke test. Do not replace the version pin with a floating CDN URL.

## Next useful increments

Add a feature only when its real source dependencies and unsupported-service
boundaries are understood. Timed fields need the server scheduler and transaction
rollback needs the server tree, so both belong to a later increment with their
own checks. Static type checking needs a Luau analysis runtime compiled for the
browser plus the Scribe and Roblox definitions; it cannot be inferred from
successful execution of this runtime.
