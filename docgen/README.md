# Scribe documentation

The docs site uses [Astro Starlight](https://starlight.astro.build/).
API pages are generated from the `--[=[ ]=]` Luau doc-comments in `../src/`; the
guides are the hand-written Markdown in `guides/`.

```
docgen/
  gen.py                      # parses src/ doc-comments and converts guides/
  guides/                     # hand-written guide sources (edit these)
  theme/assets/               # logo, favicon, social card, and playground runtime assets
  theme/social-card.html      # source of assets/social-card.png (see below)
  playground/                 # source adapter and browser runtime checks
docs-site/
  astro.config.mjs            # site settings and navigation
  src/pages/index.astro       # custom Scribe home page
  src/pages/playground.astro  # the playground page
  src/playground/             # the playground editor (CodeMirror, completions, checks)
  src/styles/                 # navy-and-mint theme
  src/code-theme.mjs          # code block colours and frames, matching the playground
  src/content/docs/           # GENERATED guide and API pages (do not edit)
  public/assets/              # GENERATED copied assets and runtime (do not edit)
  dist/                       # built HTML output (git-ignored)
```

## Local preview

Install **Node.js 22.19 or newer** (CI uses Node 24), **Python 3.10 or newer**, and
the project's [Rokit](https://github.com/rojo-rbx/rokit) toolchain for Lune checks.
The Python generator uses only the standard library; no pip packages are needed.

From the **repo root**:

```bash
npm ci --prefix docs-site
npm run dev --prefix docs-site
```

Open the local URL printed by Astro, normally `http://localhost:4321/`.
The development command generates
the pages, then watches `src/` and `docgen/` for source changes. Astro also reloads
when you edit the site's styles and components.

Generation validates a temporary copy before updating the preview. Invalid edits
leave the last working pages in place, and unchanged files are not rewritten.
Check the terminal for errors if a saved edit does not appear.

To choose another port, use `npm run dev --prefix docs-site -- --port 8767`.
The development wrapper accepts only `--port`; put other site settings in
`docs-site/astro.config.mjs`.

To generate once without serving: `python docgen/gen.py`. To view a production
build, run `npm run build --prefix docs-site`, then `npm run preview --prefix docs-site`.
Search uses the index created by the production build; use preview to test it.

## Checks

Run these from the repository root:

```sh
npm run build --prefix docs-site
npm run check --prefix docs-site
lune run docgen/check_examples
```

The build generates the pages, renders the site, and checks internal page and
section links in the resulting HTML. The docs check covers Markdown conversion,
heading anchors, and the playground's real WebAssembly runtime and generated
Scribe source. The Lune check reads the actual Getting Started, Commands, and
Emberfall examples from Markdown, then runs them against real Scribe modules with
fake storage and loopback networking. These checks also run in the docs
pull-request workflow and before a docs deployment.

No live Roblox services are contacted. Browser layout and a real Studio
save-and-reload test remain separate checks.

## Social card and page dates

`theme/assets/social-card.png` is the 1200 by 630 preview that link unfurls show.
Regenerate it from `theme/social-card.html` with a headless Chromium after the
site's npm dependencies are installed, which is where its fonts come from:

```sh
msedge --headless=new --window-size=1200,630 --hide-scrollbars --screenshot=docgen/theme/assets/social-card.png docgen/theme/social-card.html
```

The repository's `CHANGELOG.md` is published as the Changelog page without the
guide conventions applied. The version pill in the site header links to the
section for the version in `wally.toml`, and the site check fails if that section
is missing, so add the changelog entry before bumping the version.

Each page's "Last updated" date is the last commit that touched its source: the
guide file, or the Luau file an API page is generated from. `gen.py` reads it with
`git log`, so the workflows check out full history and a file that has never been
committed shows no date.

## Playground

The playground is a page of the site, `docs-site/src/pages/playground.astro`,
with its editor in `docs-site/src/playground/`. The runtime assets live under
`theme/assets/playground/`; `playground/build.py` generates the Scribe runtime
bundle from `src/` during the normal documentation build, and `gen.py` writes the
API entries the editor completes from the same doc comments as the API pages.
Runtime dependencies are pinned, vendored, and checksum-checked. After installing
the site's npm dependencies, the build does not download a playground runtime.
The browser loads the execution runtime in a worker when it checks or runs code.

See [playground/README.md](playground/README.md) for supported behavior, limits,
dependency provenance, and update instructions. This code is documentation tooling;
it is not added to the Roblox package.

## Doc-comment convention (one block per member)

Each API member must have **exactly one** moonwave (`--[=[ ]=]`) doc block. Most
public server/client functions exist twice in the source: a public `Data.<name>`
wrapper in `Server/init.luau` or `Client/init.luau`, and an internal
`self.<name>` implementation in a subsystem module (e.g. `Monetization.luau`).
Put the `@within` doc block on the **`Data.<name>` wrapper only**, and use a plain
`-- ...` comment on the internal `self.<name>`. Two blocks that resolve to the
same `Class.member` would emit a duplicate API entry and a duplicate table-of-
contents line.

`gen.py` enforces this: it **fails the build** (and thus the `docs-check` CI) if any
`Class.member` is documented by more than one block, naming both source locations.

## Links

Keep guide links in their existing source form, such as
`[Visibility](./visibility#wipe-guard)` or `[ArrayOf](/api/Scribe#ArrayOf)`. The
generator converts them into published Starlight routes at the site root. It also
maps the source `intro.md` guide to the existing `getting-started/` URL.

In doc-comments, use Moonwave autolinks such as `[Scribe.ArrayOf]`. The generator
links them to the API member's lowercase anchor (`/api/scribe/#arrayof`).
Do not hand-write `#ArrayOf`: fragment names are case-sensitive.

Existing guide URLs and explicit heading IDs remain stable through the migration.
The site keeps the previous heading rules for section links. If a heading must be
renamed, retain the old anchor with `<span id="old-heading"></span>` next to it.

## Writing a guide

The short **Start here** path teaches one working example. Other guides are
organized by task, with separate conceptual explanations and reference pages.
Keep existing page names and heading anchors when possible; other projects may
link directly to them.

For each guide:

1. Say what the reader will build and what they need first.
2. Show the smallest working example, including its script location or explicit
   assumptions. Use the full Emberfall template only when the feature needs it.
3. State the expected result and the failures the caller must handle.
4. Put internal algorithms and uncommon alternatives after the working path.

Use short paragraphs with one idea each. Introduce terms after their plain-language
meaning. Existing `!!!` notes and `???` collapsible notes are supported by the
generator, so guide authors do not need to write framework components. Keep
safety-critical behavior visible; collapsible notes are for optional detail, not
a prerequisite for using the first example correctly. Retain precise return
values in the API reference.

For larger API calls, document prerequisites, a small example, return outcomes,
and retry behavior. The generator adds member indexes without changing API anchors.
Prefer executable examples with meaningful outcome checks over snippets that only
show which methods exist. A docs build checks structure and links; it does not
prove that an example's game logic is correct.

Before calling a tutorial beginner-friendly, ask a developer new to Scribe to
complete it without coaching. Record where they stop, the questions they ask, and
whether their observed result matches the guide. This remains a human usability
check, separate from automated validation.

## Deployment

Everything (this generator, `docs-site/`, the guides, and the library) lives on
**`main`**. The API pages are generated from `../src/`, so the docs source has to
sit with the code.

`.github/workflows/docs.yml` deploys published releases from their tag. On a push
to `main`, it deploys only when the package version matches the latest published
release; this also permits docs fixes for that release. A manual run can explicitly
override the version gate. Builds deploy to GitHub Pages **as an artifact** (no
branch, nothing committed to git).
Enable it once in **Settings → Pages → Build and deployment → Source: GitHub
Actions**. The site is published at `https://scribe.ericplane.dev/`, with the custom
domain configured in GitHub Pages. `docs-site/astro.config.mjs` sets that `site`
and leaves `base` at `/`; `docs-site/public/CNAME` records the domain. Do not add
the repository prefix `/Scribe`: on the custom domain, that makes asset and page
URLs point to paths that do not exist.

If the hosting location changes, update the Astro settings, `public/CNAME`, and
the default origin/base in `docgen/check_site.py` together. The build checks local
links against this deployment location, including absolute links on the custom
domain.
