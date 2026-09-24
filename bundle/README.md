# Release packaging

RBXM, Wally, and npm releases keep concise comments, Luau types, directives, and internal notes.
The long `--[=[ ... ]=]` API documentation blocks are removed from a staging copy.
Original sources stay intact in GitHub for the website and playground.

From the repository root, with Python 3.10+ and the Rokit tools installed:

```sh
python bundle/stage.py --version 2.5.0
rojo build dist/rbxm/bundle/rbxm.project.json -o Scribe.rbxm
rojo build dist/rbxm/bundle/telemetry.project.json -o ScribeTelemetry-Addon.rbxm
rojo build dist/rbxm/bundle/ui-adapters.project.json -o ScribeUIAdapters-Addon.rbxm
rojo build dist/rbxm/bundle/leaderstats.project.json -o ScribeLeaderstats-Addon.rbxm
lune run bundle/verify
```

The shared release action also checks the stripper's regression cases and verifies
that each module compiles to identical bytecode with debug information disabled
and original line positions restored in memory for the comparison.
It reads the built models back and checks that they contain the staged source.

For Wally, stage with `python bundle/stage.py --version 2.5.0 --target wally`, then
pack or publish from `dist/wally/`. Do not publish the repository root directly.
`npm run build` stages sources with `--target npm` before building the core and
addon packages. It uses `python` by default; set `SCRIBE_PYTHON` to another Python
3.10+ executable if needed. Installing the published packages does not need Python.

Each staging run replaces its target: `dist/rbxm/`, `dist/wally/`, or `dist/npm-sources/`.

## Error line numbers

Removing documentation lines changes error locations relative to GitHub. Each
release includes `Scribe-source-map.json` beside the models and inside each Wally
or npm package; it is not loaded into the game. Its `files` keys are repository
paths, with source and packed SHA-256 hashes to identify the exact files. npm maps
also include `packagePath` for files renamed or moved inside the package.

Each file's `segments` contains `[packedLine, sourceLine]` pairs. For an error at
packed line `L`, take the last pair whose first value is at most `L`. The original
line is `sourceLine + L - packedLine`. For example, `[20, 70]` maps packed line 24
to source line 74. Use the matching release tag when opening the source.

Ordinary comments and strings are preserved, including comment-like text inside
quoted, long, and interpolated strings. Only tagged API blocks are removed.
