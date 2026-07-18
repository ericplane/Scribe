# Scribe documentation

The docs site is [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/).
API pages are generated from the `--[=[ ]=]` Luau doc-comments in `../src/`; the
guides are the hand-written Markdown in `guides/`.

```
docgen/
  gen.py            # parses src/ doc-comments + converts guides/ -> docs_gen/
  mkdocs_hooks.py   # runs gen.py on every mkdocs build; watches sources during serve
  guides/           # hand-written guide sources (edit these)
  theme/            # extra.css + logo/favicon (copied into docs_gen/ at build time)
docs_gen/           # GENERATED mkdocs docs_dir (git-ignored, do not edit)
mkdocs.yml          # site config (at the repo root)
site/               # built HTML output (git-ignored)
```

## Local preview

From the **repo root**:

```bash
python -m venv .venv
. .venv/Scripts/activate          # Windows;  use  source .venv/bin/activate  on macOS/Linux
pip install -r requirements-docs.txt

mkdocs serve                       # http://127.0.0.1:8000/Scribe/
```

The mkdocs hook regenerates `docs_gen/` before every build, and `mkdocs serve`
watches `src/` and `docgen/`, so editing a doc-comment or a guide live-reloads
the page. To generate once without serving: `python docgen/gen.py`.

## Doc-comment convention (one block per member)

Each API member must have **exactly one** moonwave (`--[=[ ]=]`) doc block. Most
public server/client functions exist twice in the source: a public `Data.<name>`
wrapper in `Server/init.luau` or `Client/init.luau`, and an internal
`self.<name>` implementation in a subsystem module (e.g. `Monetization.luau`).
Put the `@within` doc block on the **`Data.<name>` wrapper only**, and use a plain
`-- ...` comment on the internal `self.<name>`. Two blocks that resolve to the
same `Class.member` would emit a duplicate API entry and a duplicate table-of-
contents line.

`gen.py` enforces this: it **fails the build** (and thus the `docs-check` CI, which
runs `mkdocs build --strict`) if any `Class.member` is documented by more than one
block, naming both source locations.

## Deployment

Everything — this generator, `mkdocs.yml`, the guides, and the library — lives on
**`main`**. The API pages are generated from `../src/`, so the docs source has to
sit with the code.

On every push to `main`, `.github/workflows/docs.yml` builds the site and deploys
it to GitHub Pages **as an artifact** (no branch, nothing committed to git).
Enable it once in **Settings → Pages → Build and deployment → Source: GitHub
Actions**. The site is served at the `site_url` in `mkdocs.yml`
(`https://ericplane.github.io/Scribe/`), which assumes the repo is named
`Scribe`.
