"""Scribe docs generator.

Parses the `--[=[ ]=]` Luau doc-comments straight from ../src/, converts the
hand-written guides in ./guides/, and emits Material-for-MkDocs Markdown into
../docs_gen/ (the mkdocs `docs_dir`). No Moonwave, no Docusaurus.

Run directly (`python docgen/gen.py`) or let mkdocs_hooks.py invoke main() on
every build/serve.
"""
import re
import pathlib
import textwrap
import shutil

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
SRC = ROOT / "src"            # Luau source (API doc-comments live here)
DOCS = HERE / "guides"        # hand-written guide sources
OUT = ROOT / "docs_gen"       # generated mkdocs docs_dir (git-ignored)
THEME = HERE / "theme"        # static css + assets copied into OUT

BLOCK = re.compile(r"--\[=\[(.*?)\]=\]", re.S)

DATATYPES = []                # datatype-declarator family; filled by main()
VERSION = "0.0.0"             # wally.toml package version; filled by main()


def read_version():
    # single source of truth for the version shown in the docs: wally.toml.
    # guides use a {{version}} placeholder that gets substituted at build time,
    # so the deployed site always matches the current package version.
    text = (ROOT / "wally.toml").read_text(encoding="utf-8")
    m = re.search(r'^\s*version\s*=\s*"([^"]+)"', text, re.M)
    return m.group(1) if m else "0.0.0"


def parse_block(body, next_code):
    e = dict(cls=None, within=None, kind=None, name=None, ptype=None,
             params=[], returns=[], tags=[], flags=[], desc=[])
    for line in body.split("\n"):
        s = line.strip()
        if s.startswith("@class "): e["cls"] = s[7:].strip()
        elif s.startswith("@within "): e["within"] = s[8:].strip()
        elif s.startswith("@function "): e["kind"], e["name"] = "function", s[10:].strip()
        elif s.startswith("@method "): e["kind"], e["name"] = "method", s[8:].strip()
        elif s.startswith("@prop "):
            p = s[6:].strip().split(None, 1)
            e["kind"], e["name"] = "prop", p[0]
            e["ptype"] = p[1] if len(p) > 1 else "any"
        elif s.startswith("@param "): e["params"].append(s[7:].strip())
        elif s.startswith("@return "): e["returns"].append(s[8:].strip())
        elif s.startswith("@tag "): e["tags"].append(s[5:].strip())
        elif s in ("@server", "@client", "@yields"): e["flags"].append(s[1:])
        elif s.startswith("@"): pass
        else: e["desc"].append(line)
    # infer name from the code line for members with no explicit @function/@method/@prop
    if e["within"] and not e["name"] and next_code:
        m = re.search(r"function\s+[\w.]+[.:](\w+)", next_code) or re.search(r"[\w.]+\.(\w+)\s*=", next_code)
        if m: e["kind"], e["name"] = "function", m.group(1)
    e["desc"] = textwrap.dedent("\n".join(e["desc"])).strip()
    return e


def collect():
    classes = {}  # name -> {desc, members:[]}
    for path in SRC.rglob("*.luau"):
        text = path.read_text(encoding="utf-8")
        for m in BLOCK.finditer(text):
            after = text[m.end():]
            nxt = ""
            for ln in after.split("\n"):
                t = ln.strip()
                if t and not t.startswith("--"):
                    nxt = t; break
            e = parse_block(m.group(1), nxt)
            if e["cls"]:
                classes.setdefault(e["cls"], {"desc": "", "members": []})["desc"] = e["desc"]
            elif e["within"] and e["name"]:
                classes.setdefault(e["within"], {"desc": "", "members": []})["members"].append(e)
    return classes


def find_datatypes():
    # The datatype declarators (Scribe.Vector3, .CFrame, .Color3, ...) are 17
    # sibling functions that all forward to datatypeMarker and share ONE doc
    # block. Discover the whole family, in source order, so we can give each its
    # own API entry instead of documenting only the one that carries the block.
    text = (SRC / "init.luau").read_text(encoding="utf-8")
    names = []
    for m in re.finditer(r"function Scribe\.(\w+)\(default:[^\n]*\n\s*return datatypeMarker\(", text):
        if m.group(1) not in names:
            names.append(m.group(1))
    return names


def slug(s): return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def convert_xref(text):
    # [Class.member] / [Class] Moonwave autolinks -> Material links
    def repl(m):
        cls, _, mem = m.group(1).partition(".")
        page = slug(cls)
        if mem:
            return f"[`{cls}.{mem}`]({page}.md#{slug(mem)})"
        return f"[`{cls}`]({page}.md)"
    return re.sub(r"\[((?:Server|Client|Value|Scribe)(?:\.[A-Za-z]\w*)?)\]", repl, text)


ADM = {"note": "note", "tip": "tip", "info": "info", "caution": "warning",
       "warning": "warning", "danger": "danger"}


def convert_admonitions(text):
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        m = re.match(r"^:::(\w+)\s*(.*)$", lines[i])
        if m:
            typ, title = ADM.get(m.group(1), "note"), m.group(2).strip()
            out.append(f'!!! {typ}' + (f' "{title}"' if title else ""))
            i += 1
            while i < len(lines) and lines[i].strip() != ":::":
                out.append(("    " + lines[i]).rstrip()); i += 1
            i += 1
            out.append("")
        else:
            out.append(lines[i]); i += 1
    return "\n".join(out)


def unescape_code_pipes(text):
    # Moonwave's Markdown tables required a literal pipe inside a cell to be
    # written as backslash-pipe. Python-Markdown instead prints the backslash
    # verbatim AND already refuses to split a table row on a pipe that lives
    # inside an inline-code span -- so the escape is both unnecessary and ugly.
    # Drop the backslash inside inline code only; leave fenced blocks and any
    # plain-text pipes (which genuinely still need escaping) untouched.
    fences = []
    def stash(m):
        fences.append(m.group(0)); return f"\x00F{len(fences) - 1}\x00"
    text = re.sub(r"```.*?```", stash, text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", lambda m: m.group(0).replace("\\|", "|"), text)
    return re.sub(r"\x00F(\d+)\x00", lambda m: fences[int(m.group(1))], text)


def md(text):
    return unescape_code_pipes(convert_xref(convert_admonitions(text)))


def signature(e, cls):
    if e["kind"] == "prop":
        return f'{cls}.{e["name"]}: {e["ptype"]}'
    ps = ", ".join(p.replace(" ", ": ", 1) for p in e["params"])
    sig = f'{cls}.{e["name"]}({ps})'
    if e["returns"]:
        sig += " → " + " ".join(e["returns"])
    return sig


def render_member(e, cls):
    out = [f'### .{e["name"]} {{ #{slug(e["name"])} }}', ""]
    raw = list(e["flags"])
    if e["kind"] == "prop":
        raw.insert(0, "signal" if e["ptype"] == "Signal" else "property")
    if raw:
        pills = "".join(f'<span class="badge badge--{b}">{b}</span>' for b in raw)
        out.append(f'<div class="badges">{pills}</div>')
        out.append("")
    out.append("```lua")
    out.append(signature(e, cls))
    out.append("```")
    out.append("")
    if e["desc"]:
        out.append(md(e["desc"]))
        out.append("")
    return "\n".join(out)


def datatype_template(desc):
    # the shared datatype blurb: the primary (Vector3) block with the redundant
    # "All 17 ... share this shape" list paragraph dropped. The `Vector3` token
    # gets swapped per declarator so every entry reads identically bar its name.
    paras = [p for p in desc.split("\n\n") if "share this shape" not in p]
    return "\n\n".join(paras).strip()


def datatype_member(base, v, template):
    return {
        "kind": "function", "name": v, "ptype": None,
        "params": [f"default {v}"], "returns": [v],
        "tags": base["tags"], "flags": list(base["flags"]),
        "desc": template.replace("`Vector3`", f"`{v}`"),
    }


def render_class(name, data):
    out = [f"# {name}", ""]
    if data["desc"]:
        out.append(md(data["desc"])); out.append("")
    # group by tag, preserving first-appearance order
    order, groups = [], {}
    for e in data["members"]:
        tag = (e["tags"] or ["General"])[0]
        if tag not in groups: order.append(tag); groups[tag] = []
        groups[tag].append(e)
    # The datatype declarators are one family sharing a doc block; some members
    # (Vector3, CFrame) carry their own richer block, the rest none. Emit the
    # whole family ONCE, in source order, using each type's own block if it has
    # one and a compact sibling entry otherwise.
    documented_dt = {e["name"]: e for m in groups.values() for e in m if e["name"] in DATATYPES}
    primary = next((v for v in DATATYPES if v in documented_dt), None)
    dt_done = False
    for tag in order:
        out.append(f"## {tag}"); out.append("")
        for e in groups[tag]:
            if e["name"] in DATATYPES:
                if dt_done:
                    continue                                 # already emitted with the family
                dt_done = True
                base = documented_dt[primary]
                template = datatype_template(base["desc"])
                for v in DATATYPES:
                    out.append(render_member(datatype_member(base, v, template), name))
            else:
                out.append(render_member(e, name))
    return "\n".join(out)


def convert_guide(text):
    text = re.sub(r"^---\n.*?\n---\n", "", text, flags=re.S)  # strip frontmatter
    text = convert_admonitions(text)
    text = re.sub(r"\]\(\./([\w-]+)(#[\w-]+)?\)", lambda m: f"]({m.group(1)}.md{m.group(2) or ''})", text)
    text = re.sub(r"\]\(/api/(\w+)(#[\w-]+)?\)",
                  lambda m: f"](api/{m.group(1).lower()}.md{(m.group(2) or '').lower()})", text)
    text = text.replace("](intro.md", "](index.md")  # intro is the home page
    text = text.replace("{{version}}", VERSION)       # stamp the wally.toml version
    text = unescape_code_pipes(text)                  # `\|` in table cells -> `|`
    return text


def copy_theme():
    # the stylesheet + logo/favicon live in docgen/theme/ and are referenced by
    # mkdocs.yml relative to docs_dir, so copy them into OUT on every build
    for sub in ("stylesheets", "assets"):
        src = THEME / sub
        if src.is_dir():
            shutil.copytree(src, OUT / sub, dirs_exist_ok=True)


def main():
    global DATATYPES, VERSION
    DATATYPES = find_datatypes()
    VERSION = read_version()

    # OUT is fully generated; wipe it clean so deleted sources don't leave stragglers
    shutil.rmtree(OUT, ignore_errors=True)
    (OUT / "api").mkdir(parents=True, exist_ok=True)
    (OUT / ".gitkeep").write_text("", encoding="utf-8")

    classes = collect()
    for cls, data in classes.items():
        (OUT / "api" / f"{slug(cls)}.md").write_text(render_class(cls, data), encoding="utf-8")
    print("[docgen] API:", ", ".join(f"{k}({len(v['members'])})" for k, v in classes.items()))

    guides = sorted(DOCS.glob("*.md"))
    for path in guides:
        name = "index.md" if path.stem == "intro" else path.name
        (OUT / name).write_text(convert_guide(path.read_text(encoding="utf-8")), encoding="utf-8")
    print(f"[docgen] guides: {len(guides)} converted")

    copy_theme()
    print(f"[docgen] wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
