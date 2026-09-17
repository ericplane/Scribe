"""Translate the canonical Scribe Markdown into Starlight's Markdown dialect.

The guides and Luau doc-comments remain the source of truth. Conversion happens
at build time so framework formatting does not leak into the public API comments.
"""
import html
import json
import posixpath
import re
import unicodedata
from urllib.parse import urlsplit, urlunsplit


ASIDES = {"note": "note", "info": "note", "important": "note", "example": "note",
          "tip": "tip", "success": "tip", "warning": "caution", "caution": "caution",
          "danger": "danger", "failure": "danger"}


def legacy_slug(text):
    """Match the ASCII Python-Markdown heading slugs on the previous site."""
    text = re.sub(r"!?\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = html.unescape(re.sub(r"<[^>]+>", "", text))
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = re.sub(r"[^\w\s-]", "", text).strip().lower()
    return re.sub(r"[-\s]+", "-", text)


def inline_title(text):
    text = html.escape(text.replace('\\"', '"'))
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", text)


def material_blocks(text):
    """Keep warnings visible and preserve optional notes as native details."""
    lines, output, index, fence = text.splitlines(), [], 0, None
    while index < len(lines):
        line = lines[index]
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            if fence is None:
                fence = marker.group(1)
            elif marker.group(1).startswith(fence):
                fence = None
            output.append(line)
            index += 1
            continue
        match = None if fence else re.match(r'^(!!!|\?\?\?\+?)\s+(\w+)(?:\s+"(.*)")?\s*$', line)
        if not match:
            output.append(line)
            index += 1
            continue
        kind, style, title = match.groups()
        title = title or style.capitalize()
        body = []
        index += 1
        while index < len(lines):
            if lines[index].startswith("    "):
                body.append(lines[index][4:])
            elif not lines[index].strip():
                body.append("")
            else:
                break
            index += 1
        content = material_blocks("\n".join(body).strip("\n"))
        if kind.startswith("???"):
            opened = " open" if kind.endswith("+") else ""
            output += [f'<details class="scribe-details scribe-details--{style}"{opened}>',
                       f"<summary>{inline_title(title)}</summary>", "", content, "", "</details>", ""]
        else:
            # Starlight supports Markdown in aside titles. Escape square brackets
            # because they delimit the custom-title syntax.
            title = title.replace('\\"', '"').replace("[", "\\[").replace("]", "\\]")
            output += [f":::{ASIDES.get(style, 'note')}[{title}]", content, ":::" , ""]
    return "\n".join(output)


def page_link(target, page):
    """Resolve a source-file link from the final trailing-slash page URL."""
    url = urlsplit(target)
    if url.scheme or url.netloc or not url.path or url.path.startswith("/"):
        return target
    original = posixpath.normpath(posixpath.join(posixpath.dirname(page), url.path))
    if original.endswith(".md"):
        original = original[:-3]
        if original == "intro":
            original = "getting-started"
        original = original.removesuffix("/index")
        destination = original + "/"
    else:
        destination = original
    # page is a source name such as api/server.md, whose URL is api/server/.
    relative = posixpath.relpath(destination, page.removesuffix(".md"))
    if destination.endswith("/") and not relative.endswith("/"):
        relative += "/"
    return urlunsplit(("", "", relative, url.query, url.fragment))


def convert_page(text, page, edit_source, last_updated=None):
    text = re.sub(r"^---\n.*?\n---\n", "", text, count=1, flags=re.S)
    text = material_blocks(text)
    # API signatures wrap independently of runnable code examples.
    text = re.sub(r"```\s*\{\s*\.lua\s+\.api-signature\s*\}\n(.*?)\n```",
                  r'<div class="api-signature">\n\n```lua wrap\n\1\n```\n\n</div>', text, flags=re.S)
    text = text.replace("\n{ .api-typerefs }", "")
    text = text.replace("var(--md-default-fg-color--lightest)", "var(--sl-color-gray-5)")

    fences = []
    def stash(match):
        fences.append(match.group(0))
        return f"\x00F{len(fences) - 1}\x00"
    text = re.sub(r"^([ \t]*)(`{3,}|~{3,})[^\n]*\n.*?^\1\2[ \t]*$", stash, text, flags=re.M | re.S)

    heading = re.search(r"^# (.+)$", text, re.M)
    if not heading:
        raise ValueError(f"{page}: missing page title")
    title = re.sub(r"\s*\{\s*#[^}]+\}\s*$", "", heading.group(1)).strip()
    top_id = legacy_slug(title)
    # Starlight supplies the visible h1. Keep old title links working as well.
    text = text[:heading.start()] + f'<span id="{top_id}"></span>' + text[heading.end():]
    used_ids = {top_id}
    def headings(match):
        hashes, label, explicit = match.groups()
        anchor = explicit or legacy_slug(label)
        candidate, suffix = anchor, 1
        while candidate in used_ids:
            candidate = f"{anchor}_{suffix}"
            suffix += 1
        used_ids.add(candidate)
        return f"{hashes} {label.rstrip()} {{#{candidate}}}"
    text = re.sub(r"^(#{2,6}) (.*?)(?:\s*\{\s*#([\w-]+)\s*\})?\s*$", headings, text, flags=re.M)
    text = re.sub(r"\]\(([^\s)]+)\)", lambda m: f"]({page_link(m.group(1), page)})", text)

    # One playground link uses the previous theme's button attributes. Preserve
    # its new-tab behavior with ordinary accessible HTML.
    text = re.sub(
        r'\[([^\]]+)\]\(([^)]+)\)\{\s*\.md-button\s+target="_blank"\s+rel="noopener"\s*\}',
        lambda m: f'<a class="scribe-button" href="{html.escape(m.group(2), quote=True)}" target="_blank" rel="noopener">{html.escape(m.group(1))}</a>', text)

    # GFM tables split on pipes even inside inline code, unlike Python-Markdown.
    rows = []
    for line in text.splitlines():
        if line.lstrip().startswith("|"):
            line = re.sub(r"`[^`\n]*`", lambda m: re.sub(r"(?<!\\)\|", r"\|", m.group(0)), line)
        rows.append(line)
    text = "\n".join(rows)
    text = re.sub(r"\x00F(\d+)\x00", lambda m: fences[int(m.group(1))], text)
    lines = ["---", f"title: {json.dumps(html.unescape(title), ensure_ascii=False)}",
             f"editUrl: {json.dumps('https://github.com/ericplane/Scribe/edit/main/' + edit_source)}"]
    # API pages list every member as an h3 and the changelog every section; the h2s are enough.
    if page.startswith("api/") or page == "changelog.md":
        lines.append("tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 2 }")
    if last_updated:
        lines.append(f"lastUpdated: {last_updated}")
    frontmatter = "\n".join(lines + ["---", ""])
    return frontmatter + text.strip() + "\n"
