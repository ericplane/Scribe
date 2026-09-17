"""Scribe docs generator.

Parses the `--[=[ ]=]` Luau doc-comments straight from ../src/, converts the
hand-written guides in ./guides/, and emits Starlight-compatible Markdown into
../docs-site/src/content/docs/. The website build invokes this before Astro.
"""
import re
import sys
import pathlib
import textwrap
import shutil
import tempfile

from playground.build import build_playground
import subprocess
from starlight import convert_page

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
SRC = ROOT / "src"            # Luau source (API doc-comments live here)
DOCS = HERE / "guides"        # hand-written guide sources
SITE = ROOT / "docs-site"
OUT = SITE / "src" / "content" / "docs"  # generated, git-ignored
PUBLIC = SITE / "public"
THEME = HERE / "theme"        # canonical logos and standalone playground assets

BLOCK = re.compile(r"--\[=\[(.*?)\]=\]", re.S)

DATATYPES = []                # datatype-declarator family; filled by main()
VERSION = "0.0.0"             # wally.toml package version; filled by main()
TYPES = {}                    # exported type name -> its anchor on api/types.md


_GIT_DATES = {}


def git_date(path):
    """The last commit date of a source file, for the page footer; None outside git."""
    if path not in _GIT_DATES:
        try:
            result = subprocess.run(["git", "log", "-1", "--format=%cI", "--", path], cwd=ROOT,
                                    capture_output=True, text=True, timeout=20)
            _GIT_DATES[path] = result.stdout.strip() or None
        except (OSError, subprocess.SubprocessError):
            _GIT_DATES[path] = None
    return _GIT_DATES[path]


def read_version():
    # single source of truth for the version shown in the docs: wally.toml.
    # guides use a {{version}} placeholder that gets substituted at build time,
    # so the deployed site always matches the current package version.
    text = (ROOT / "wally.toml").read_text(encoding="utf-8")
    m = re.search(r'^\s*version\s*=\s*"([^"]+)"', text, re.M)
    return m.group(1) if m else "0.0.0"


def parse_block(body, next_code):
    e = dict(cls=None, within=None, kind=None, name=None, key=None, ptype=None,
             interface=False, params=[], returns=[], tags=[], flags=[], fields=[],
             desc=[])
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
        # @interface/@type declare an exported shape rather than a member of a class,
        # so they get an entry on the Types page and legitimately resolve to no member
        # name. @within is IGNORED on these blocks: a type is reached from every
        # signature that names it, not from the one class that happens to declare it.
        # `key` is the name with its generic parameters stripped, because that is the
        # bare token a rendered signature actually contains.
        elif s.startswith("@interface ") or s.startswith("@type "):
            head, _, rest = s[1:].partition(" ")
            p = rest.strip().split(None, 1)
            e["interface"] = True
            e["kind"] = "interface" if head == "interface" else "type"
            e["name"] = p[0] if p else None
            e["key"] = re.sub(r"<.*", "", e["name"]) if e["name"] else None
            if head == "type" and len(p) > 1:
                e["ptype"] = p[1]
        elif s.startswith("@param "): e["params"].append(s[7:].strip())
        elif s.startswith("@return "): e["returns"].append(s[8:].strip())
        elif s.startswith("@tag "): e["tags"].append(s[5:].strip())
        elif s in ("@server", "@client", "@yields"): e["flags"].append(s[1:])
        elif s.startswith("@"): pass
        # `.Field Type -- what it is`, the Moonwave field line. Recognised only
        # inside an @interface block, so prose that happens to open with a dot is
        # still prose everywhere else.
        elif e["kind"] == "interface" and re.match(r"\.\w+\s", s):
            fname, _, rest = s[1:].partition(" ")
            ftype, _, fdesc = rest.strip().partition(" -- ")
            e["fields"].append((fname, ftype.strip(), fdesc.strip()))
        else: e["desc"].append(line)
    # infer name from the code line for members with no explicit @function/@method/@prop
    if e["within"] and not e["name"] and next_code:
        m = re.search(r"function\s+[\w.]+[.:](\w+)", next_code) or re.search(r"[\w.]+\.(\w+)\s*=", next_code)
        if m: e["kind"], e["name"] = "function", m.group(1)
    e["desc"] = textwrap.dedent("\n".join(e["desc"])).strip()
    return e


def collect():
    classes = {}  # name -> {desc, members:[]}
    types = {}    # key (the name without generics) -> parsed @interface/@type block
    seen = {}     # (within, name) -> "path:line" of the doc block that defined it first
    dups = []     # (within, name, first_src, dup_src) for every redefinition
    orphans = []  # (within, src, next_code) for a @within block whose member is unresolvable
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
            src = f"{path.relative_to(ROOT)}:{text.count(chr(10), 0, m.start()) + 1}"
            if e["interface"]:
                # Until this branch existed, parse_block set a flag here and collect()
                # dropped the block with no diagnostic, so every authored @interface
                # produced nothing at all and no build ever said so.
                if not e["key"]:
                    raise SystemExit(f"[docgen] {src}: @interface/@type with no name.")
                if e["key"] in types:
                    raise SystemExit(
                        f'[docgen] {src}: the type {e["key"]} is documented twice (first '
                        f'at {types[e["key"]]["src"]}). Give each exported type one block.'
                    )
                e["src"] = src
                types[e["key"]] = e
                continue
            if e["cls"]:
                classes.setdefault(e["cls"], {"desc": "", "members": []})["desc"] = e["desc"]
            elif e["within"] and e["name"]:
                # Two moonwave blocks resolving to the same Class.member emit a
                # duplicate API entry (and a duplicate TOC line). Almost always a
                # public doc-comment accidentally left on BOTH the internal self.<name>
                # and the Data.<name> wrapper. Flag every collision and fail the build.
                key = (e["within"], e["name"])
                if key in seen:
                    dups.append((key[0], key[1], seen[key], src))
                else:
                    seen[key] = src
                classes.setdefault(e["within"], {"desc": "", "members": []})["members"].append(e)
            elif e["within"]:
                # A @within block whose member name cannot be resolved (no explicit
                # @function/@method/@prop, and the next code line is not a definition)
                # is silently DROPPED from the API page, which dangles every
                # [Class.member] link pointing at it. In practice this means code was
                # inserted between the doc block and the thing it documents.
                orphans.append((
                    e["within"],
                    f"{path.relative_to(ROOT)}:{text.count(chr(10), 0, m.start()) + 1}",
                    nxt[:70],
                ))
    if orphans:
        lines = [
            "",
            "[docgen] ERROR: orphaned API doc-comment(s) -- a @within block whose member",
            "name could not be resolved, so it would be dropped from the API page and any",
            "[Class.member] link to it would dangle:",
            "",
        ]
        for within, src, nxt_code in orphans:
            lines += [f"  * @within {within} at {src}",
                      f"        next code line: {nxt_code or '(none)'}"]
        lines += [
            "",
            "Put the doc block directly above the function/property it documents (no code",
            "in between), or name it explicitly with @function/@method/@prop.",
            "",
        ]
        print("\n".join(lines), file=sys.stderr)
        raise SystemExit(1)
    if dups:
        lines = [
            "",
            "[docgen] ERROR: duplicate API doc-comment(s) -- the same member is documented",
            "by more than one moonwave block, which emits a duplicate entry in the API page",
            "and its table of contents:",
            "",
        ]
        for within, name, first, dup in dups:
            lines += [f"  * {within}.{name}",
                      f"        first defined at: {first}",
                      f"        duplicated at:    {dup}"]
        lines += [
            "",
            "Give each API member exactly ONE moonwave (--[=[ ]=]) doc block. Convention:",
            "keep the public block on the Data.<name> wrapper (Server/Client init.luau) and",
            "use a plain -- comment on the internal self.<name>. See docgen/README.md.",
            "",
        ]
        # Print explicitly (not just via SystemExit's arg) so the message is visible
        # even when the website build wraps this command, then fail non-zero.
        print("\n".join(lines), file=sys.stderr)
        raise SystemExit(1)
    return classes, types


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
    # Doc-comments cross-reference with the Moonwave autolink form, [Class] or
    # [Class.member]. The guide-style `](/api/Server#WaitForData)` is NOT rewritten
    # here (that is convert_guide's job), so it would ship as a site-absolute path
    # that resolves nowhere, and with the wrong anchor case besides. Catch the
    # source convention here before the final website link check.
    bad = re.search(r"\]\((/api/[^)]*)\)", text)
    if bad:
        raise SystemExit(
            f"[docgen] doc-comment contains the guide-style link {bad.group(1)}, which is not rewritten in "
            f"doc-comments and would ship as a dead absolute path.\n"
            f"          Use the Moonwave autolink form instead, e.g. [Server.WaitForData]."
        )

    # [ExportedType] resolves to that type's entry on the Types page. Only names
    # the generator actually rendered are rewritten, so an ordinary bracketed word
    # in prose is left exactly as written.
    def repl_type(m):
        n = m.group(1)
        return f"[`{n}`](types.md#{TYPES[n]})" if n in TYPES else m.group(0)
    text = re.sub(r"\[([A-Z]\w*)\](?!\()", repl_type, text)

    # [Class.member] / [Class] Moonwave autolinks -> intermediate Markdown links
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
    # Kept although nothing uses `:::` any more. Without it a `:::caution` block renders
    # as literal text, with no build error to notice.
    #
    # Write `!!!`. `???` is the COLLAPSIBLE variant, not a style choice, so do not fold
    # one into the other. Unknown types fall back to `note`.
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
    # Normalize legacy pipe escaping inside inline code. The Starlight conversion
    # adds GFM's required escapes back inside table rows, while ordinary inline
    # code should display the pipe alone. Runnable fenced code stays untouched.
    fences = []
    def stash(m):
        fences.append(m.group(0)); return f"\x00F{len(fences) - 1}\x00"
    text = re.sub(r"```.*?```", stash, text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", lambda m: m.group(0).replace("\\|", "|"), text)
    return re.sub(r"\x00F(\d+)\x00", lambda m: fences[int(m.group(1))], text)


def md(text):
    return unescape_code_pipes(convert_xref(convert_admonitions(text)))


def member_sep(e):
    # `@method` members are called with a colon. Props are fields, so they stay dotted.
    return ":" if e["kind"] == "method" else "."


def signature(e, cls):
    if e["kind"] == "prop":
        return f'{cls}.{e["name"]}: {e["ptype"]}'
    # A @param may carry a trailing `-- note` for the reader. It must not reach the
    # signature: inside a ```lua fence `--` comments out the REST of the line, so
    # every parameter after it renders as a grey comment and the signature reads as
    # something that would not even parse. Strip it here; the prose belongs in the
    # description, not in the signature line.
    def strip_note(param):
        return re.split(r"\s+--\s", param, maxsplit=1)[0].rstrip()

    ps = ", ".join(strip_note(p).replace(" ", ": ", 1) for p in e["params"])
    # Keep parameter signatures compact and linkable by naming exported types
    # instead of inlining shapes with string literals, e.g. PurchaseFilter?.
    if '"' in ps:
        raise SystemExit(
            f'[docgen] {cls}.{e["name"]}: a @param type contains a string literal. '
            f"Reference the exported type by name to keep the signature compact and linkable.\n          {ps}"
        )
    sig = f'{cls}{member_sep(e)}{e["name"]}({ps})'
    if e["returns"]:
        sig += " → " + " ".join(" ".join(strip_note(r).split()) for r in e["returns"])
    if "--" in sig:
        raise SystemExit(
            f'[docgen] {cls}.{e["name"]}: signature still contains "--", which comments out the rest '
            f"of the line in the rendered lua block.\n          {sig}"
        )
    return sig


def type_links(sig, cls, name, sep="."):
    # A signature renders inside a ```lua fence, and Markdown will not make a link
    # inside one, so an exported type named in a signature is a dead word on the
    # page. Emit the links directly beneath the fence instead, in the order the
    # signature mentions them. The `Class.member` prefix is stripped first so a
    # declarator does not list the type it is named after (Scribe.Flags -> Flags).
    head = f'{cls}{sep}{name}'
    body = sig[len(head):] if sig.startswith(head) else sig
    found = []
    for tok in re.findall(r"\b[A-Za-z_]\w*\b", body):
        # Skip the class being rendered. BigValue is both a class page and an
        # exported type, so BigValue.Pow would otherwise send the reader to a stub
        # whose entire content points back at the page they are already on.
        if tok in TYPES and tok != cls and tok not in found:
            found.append(tok)
    if not found:
        return None
    links = ", ".join(f"[`{n}`](types.md#{TYPES[n]})" for n in found)
    return f"Types: {links}\n{{ .api-typerefs }}"


def render_member(e, cls):
    out = [f'### {member_sep(e)}{e["name"]} {{ #{slug(e["name"])} }}', ""]
    raw = list(e["flags"])
    if e["kind"] == "prop":
        raw.insert(0, "signal" if e["ptype"] == "Signal" else "property")
    if raw:
        pills = " ".join(f'<span class="badge badge--{b}">{b}</span>' for b in raw)
        out.append(f'<div class="badges">{pills}</div>')
        out.append("")
    # The final Starlight conversion turns this intermediate marker into an
    # Expressive Code block with wrapping. Runnable guide examples keep scrolling.
    sig = signature(e, cls)
    out.append("``` { .lua .api-signature }")
    out.append(sig)
    out.append("```")
    out.append("")
    refs = type_links(sig, cls, e["name"], member_sep(e))
    if refs:
        out.append(refs)
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
    # An index lets readers choose a task before scanning full signatures. Keep
    # member anchors unchanged so existing links into the reference still work.
    if len(data["members"]) >= 8:
        out += ["## Find a member", "", "Choose a group, then follow a member link for its signature and behavior.", ""]
        for tag in order:
            out += [f"**{tag}**", ""]
            links = [f'[`{e["name"]}`](#{slug(e["name"])})' for e in groups[tag]]
            # Datatype siblings are generated below even without their own block.
            if any(e["name"] in DATATYPES for e in groups[tag]):
                links = [f'[`{e["name"]}`](#{slug(e["name"])})' for e in groups[tag] if e["name"] not in DATATYPES]
                links += [f'[`{v}`](#{slug(v)})' for v in DATATYPES]
            out += [" · ".join(links), ""]
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


TYPES_INTRO = """The exported shapes that the signatures on the other API pages name.
Every one of them is reachable through the module you required, so you can annotate
your own locals with `Scribe.LeaderboardEntry` and get the same checking Scribe uses
internally. Nothing here is something you construct by hand unless the entry says so.
"""


CLASS_PAGES = ("Server", "Client", "Value", "Scribe")


def type_cell(ftype):
    # A Type column that names a page the site already has should be a link, so a
    # reader chasing `.Server Server` or `.Level LogLevel` lands on the definition
    # rather than reading the word again. Exact matches only: a compound like
    # `("Default" | ScribeTransport)?` has no single destination, so it stays code.
    base = ftype[:-1] if ftype.endswith("?") else ftype
    if base in TYPES:
        return f"[`{ftype}`](types.md#{TYPES[base]})"
    if base in CLASS_PAGES:
        return f"[`{ftype}`]({slug(base)}.md)"
    return f"`{ftype}`"


def render_type(e):
    # `<` opens a raw HTML tag in a Markdown heading, so an unescaped `Timed<T>`
    # renders as a bare `Timed` and the generic silently disappears.
    title = e["name"].replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    out = [f'### {title} {{ #{TYPES[e["key"]]} }}', ""]
    if e["kind"] == "type" and e["ptype"]:
        out += ["``` { .lua .api-signature }", f'type {e["name"]} = {e["ptype"]}', "```", ""]
    if e["fields"]:
        out += ["| Field | Type | What it is |", "| --- | --- | --- |"]
        for fname, ftype, fdesc in e["fields"]:
            # The final conversion escapes pipes inside inline type code for GFM.
            # Escape plain prose here so it cannot create additional table cells.
            out.append(f'| `{fname}` | {type_cell(ftype)} | {md(fdesc).replace("|", chr(92) + "|")} |')
        out.append("")
    if e["desc"]:
        out += [md(e["desc"]), ""]
    return "\n".join(out)


def render_types(types):
    out = ["# Types", "", TYPES_INTRO, ""]
    order, groups = [], {}
    for e in types.values():
        tag = (e["tags"] or ["General"])[0]
        if tag not in groups:
            order.append(tag)
            groups[tag] = []
        groups[tag].append(e)
    for tag in order:
        out += [f"## {tag}", ""]
        for e in groups[tag]:
            out.append(render_type(e))
    return "\n".join(out)


SCRIBE_MEMBER = re.compile(r"\bScribe\.(\w+)\s*(?=[(.])")


def public_scribe_names():
    src = (ROOT / "src" / "init.luau").read_text(encoding="utf-8")
    return set(re.findall(r"^function Scribe\.(\w+)", src, re.M)) | set(
        re.findall(r"^Scribe\.(\w+) = ", src, re.M)
    )


def check_scribe_members(text, source, public):
    # The exchange guide shipped `Scribe.Server.new({...})` for a while and nothing
    # caught it: GuideExamplesRun transcribes examples by hand rather than reading the
    # Markdown, so a call to a non-existent member never reaches it.
    #
    # The lookahead limits this to names CALLED or used as a namespace.
    # `Scribe.PlayerData<T>` is a type and `Scribe.Flush` in prose is a profiler label;
    # both would be false positives otherwise.
    for n, line in enumerate(text.split("\n"), 1):
        for ref in SCRIBE_MEMBER.findall(line):
            if ref not in public:
                raise SystemExit(
                    f"[docgen] {source}:{n}: `Scribe.{ref}` is not exported by src/init.luau.\n"
                    f"          The entry point is `Scribe(options)`; see intro.md for the "
                    f"canonical call.\n          {line.strip()[:90]}"
                )


def check_grid_cards(text, source):
    # A Material "grid cards" card is a list item, so every line of its body must
    # stay indented under it. Lose the indent on one line and that card ends
    # early: the rest of its body renders as page text outside the grid, and the
    # following indented link becomes a code block. It still builds, so nothing
    # catches it but a human looking at the page.
    ingrid = False
    for n, line in enumerate(text.split("\n"), 1):
        if "grid cards" in line:
            ingrid = True
            continue
        if not ingrid or not line.strip():
            continue
        if line.startswith("-   ") or line.startswith("    "):
            continue
        if line.startswith("</div>"):
            ingrid = False
            continue
        raise SystemExit(
            f"[docgen] {source}:{n}: line is inside a `grid cards` list but is not indented, so it "
            f"breaks out of its card.\n          Indent it 4 spaces:\n          {line[:90]}"
        )


_PUBLIC_SCRIBE = None


def convert_guide(text, source="guide"):
    global _PUBLIC_SCRIBE
    if _PUBLIC_SCRIBE is None:
        _PUBLIC_SCRIBE = public_scribe_names()
    check_grid_cards(text, source)
    check_scribe_members(text, source, _PUBLIC_SCRIBE)
    text = re.sub(r"^---\n.*?\n---\n", "", text, flags=re.S)  # strip frontmatter
    text = convert_admonitions(text)
    text = re.sub(r"\]\(\./([\w-]+)(#[\w-]+)?\)", lambda m: f"]({m.group(1)}.md{m.group(2) or ''})", text)
    text = re.sub(r"\]\(/api/(\w+)(#[\w-]+)?\)",
                  lambda m: f"](api/{m.group(1).lower()}.md{(m.group(2) or '').lower()})", text)
    text = text.replace("](intro.md", "](getting-started.md")  # the intro page is published as getting-started
    text = text.replace("{{version}}", VERSION)       # stamp the wally.toml version
    text = unescape_code_pipes(text)                  # `\|` in table cells -> `|`
    return text


def scoped_path(path):
    """Refuse generated writes or cleanup outside this website project."""
    resolved, site = path.resolve(), SITE.resolve()
    if resolved == site or not resolved.is_relative_to(site):
        raise ValueError(f"Generated path escapes the documentation project: {path}")
    return path


def publish_generated(trees, stage):
    """Publish changed files only, rolling back filesystem errors during writes."""
    changes = []
    for source, destination in trees:
        scoped_path(source)
        scoped_path(destination)
        incoming = {path.relative_to(source): path for path in source.rglob("*") if path.is_file()}
        existing = {path.relative_to(destination): path for path in destination.rglob("*") if path.is_file()}
        for relative, path in incoming.items():
            target = scoped_path(destination / relative)
            if relative not in existing or path.read_bytes() != target.read_bytes():
                changes.append((path, target))
        for relative in existing.keys() - incoming.keys():
            changes.append((None, scoped_path(destination / relative)))

    # Back up only files that will change, before touching published output. This
    # also preserves old timestamps if a filesystem error interrupts publishing.
    backup = scoped_path(stage / "rollback")
    backup.mkdir()
    backups = []
    for index, (_, target) in enumerate(changes):
        old = backup / str(index) if target.is_file() else None
        if old:
            shutil.copy2(target, old)
        backups.append(old)
    attempted = []
    try:
        for index, (source, target) in enumerate(changes):
            attempted.append(index)
            if source is None:
                target.unlink()
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                source.replace(target)
    except OSError:
        for index in reversed(attempted):
            target, old = changes[index][1], backups[index]
            if old:
                old.replace(target)
            else:
                target.unlink(missing_ok=True)
        raise

    # Only generated empty directories can be removed. Never recurse over the
    # project or remove a directory containing unrelated public/source files.
    for _, destination in trees:
        for path in sorted(destination.rglob("*"), key=lambda path: len(path.parts), reverse=True):
            if path.is_dir():
                scoped_path(path)
                try:
                    path.rmdir()
                except OSError:
                    pass
    return len(changes)


def summary(desc):
    """The first paragraph of a doc block as plain text, for editor tooltips."""
    first = desc.split("\n\n", 1)[0]
    if first.lstrip().startswith("```"):
        return ""
    text = " ".join(line.strip() for line in first.splitlines())
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([A-Za-z_.:]+)\]", r"\1", text)
    return re.sub(r"\*\*([^*]+)\*\*", r"\1", text).strip()


def playground_api(classes):
    """Members the browser playground can complete: declarators, helpers and field methods."""
    entries = []
    for cls, member_filter in (("Scribe", lambda e: bool({"Field Types", "Visibility"} & set(e["tags"]))
                                          or e["name"] in ("Short", "SetShortSuffixes")),
                               ("Value", lambda e: True), ("BigValue", lambda e: True)):
        for e in classes.get(cls, {"members": []})["members"]:
            if not member_filter(e):
                continue
            entries.append({
                "class": cls, "name": e["name"], "kind": e["kind"], "tags": e["tags"],
                "signature": signature(e, cls), "summary": summary(e["desc"]),
            })
    return entries


def stage_site(output, assets):
    global TYPES

    (output / "api").mkdir(parents=True, exist_ok=True)

    classes, types = collect()
    # The registry has to exist before ANY page renders: render_member consults it
    # for the type links under each signature, and convert_xref for [ExportedType].
    TYPES = {key: slug(key) for key in types}
    class_sources = {
        "Server": "src/Server/init.luau", "Client": "src/Client/init.luau",
        "Scribe": "src/init.luau", "Value": "src/Internal/Node.luau",
        "BigValue": "src/Internal/Big.luau", "Signal": "src/Internal/Signal.luau",
        "Connection": "src/Internal/Signal.luau",
    }
    for cls, data in classes.items():
        name = f"api/{slug(cls)}.md"
        source = class_sources.get(cls, "src/init.luau")
        (output / name).write_text(convert_page(render_class(cls, data), name, source, git_date(source)), encoding="utf-8")
    print("[docgen] API:", ", ".join(f"{k}({len(v['members'])})" for k, v in classes.items()))
    if types:
        (output / "api" / "types.md").write_text(convert_page(render_types(types), "api/types.md", "src/init.luau",
                                                              git_date("src/init.luau")), encoding="utf-8")
    print(f"[docgen] types: {len(types)} exported shapes")

    guides = sorted(DOCS.glob("*.md"))
    for path in guides:
        name = "getting-started.md" if path.stem == "intro" else path.name
        (output / name).write_text(
            convert_page(convert_guide(path.read_text(encoding="utf-8"), f"guides/{path.name}"),
                         name, f"docgen/guides/{path.name}", git_date(f"docgen/guides/{path.name}")), encoding="utf-8"
        )
    print(f"[docgen] guides: {len(guides)} converted")

    # The changelog is plain Markdown already, so it skips the guide conventions.
    (output / "changelog.md").write_text(
        convert_page((ROOT / "CHANGELOG.md").read_text(encoding="utf-8"), "changelog.md", "CHANGELOG.md",
                     git_date("CHANGELOG.md")), encoding="utf-8")

    shutil.copytree(THEME / "assets", assets)
    build_playground(ROOT, assets / "playground", VERSION, playground_api(classes))


def main():
    global DATATYPES, VERSION, _PUBLIC_SCRIBE
    DATATYPES = find_datatypes()
    VERSION = read_version()
    _PUBLIC_SCRIBE = None
    SITE.mkdir(parents=True, exist_ok=True)
    # Invalid source saves never erase the last working preview. Validate and
    # generate everything in a scoped temporary directory before publishing.
    with tempfile.TemporaryDirectory(prefix=".docgen-", dir=SITE) as directory:
        stage = scoped_path(pathlib.Path(directory))
        output, assets = stage / "docs", stage / "assets"
        stage_site(output, assets)
        changed = publish_generated(((output, OUT), (assets, PUBLIC / "assets")), stage)
    print(f"[docgen] published {changed} changed files to {SITE.name}")


if __name__ == "__main__":
    main()
