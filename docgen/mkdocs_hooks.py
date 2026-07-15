"""MkDocs hooks that fold the Scribe generator into the build.

- on_pre_build: regenerate docs_gen/ from src/ + docs/ before every build, so a
  plain `mkdocs build` / `mkdocs serve` is always up to date.
- on_serve: also watch the Luau source and guide sources, so editing them during
  `mkdocs serve` triggers a rebuild (mkdocs only watches docs_dir by default).
"""
import sys
import pathlib

_HERE = pathlib.Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import gen  # noqa: E402  (path set up above)


def on_pre_build(config, **kwargs):
    gen.main()


def on_serve(server, config, builder, **kwargs):
    # watch the Luau source (API) and the docgen tree (guides + theme + generator)
    root = _HERE.parent
    for d in ("src", "docgen"):
        server.watch(str(root / d))
    return server
