"""Fail a documentation build on broken local links, assets, or fragments.

Run after Astro builds to docs-site/dist/. An optional snapshot from the previous site can
also verify that published routes and anchors survive a framework migration.
External sites are deliberately not contacted during deterministic build checks.
"""
import argparse
from collections import Counter
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urljoin, urlsplit


ROOT = Path(__file__).resolve().parent.parent
ORIGIN = "https://scribe.ericplane.dev"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path, self.ids, self.links = path, [], []
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag == "a" and attrs.get("name"):
            self.ids.append(attrs["name"])
        attribute = "href" if tag in ("a", "link") else "src"
        if tag in ("a", "link", "img", "script", "iframe", "source", "video", "audio") and attrs.get(attribute):
            self.links.append((attrs[attribute], self.getpos()[0]))


def check_site(site, base="/", legacy_snapshot=None, *, origin=ORIGIN):
    if not site.is_dir():
        raise ValueError(f"Build output does not exist: {site}")
    deployment = urlsplit(origin)
    if (deployment.scheme not in ("http", "https") or not deployment.netloc
            or deployment.path not in ("", "/") or deployment.query or deployment.fragment):
        raise ValueError("The deployment origin must be an http(s) origin without a path; use --base for the path.")
    origin = origin.rstrip("/")
    base = "/" + base.strip("/") + "/" if base.strip("/") else "/"
    pages = {path.relative_to(site).as_posix(): Page(path) for path in site.rglob("*.html")}
    errors, checked = [], 0
    if "index.html" not in pages:
        errors.append("The built site has no homepage (index.html).")
    for relative, page in pages.items():
        duplicate = [anchor for anchor, count in Counter(page.ids).items() if count > 1]
        if duplicate:
            errors.append(f"{relative}: duplicate anchor IDs: {', '.join(duplicate)}")
        path_url = relative.removesuffix("index.html") if relative.endswith("/index.html") or relative == "index.html" else relative
        page_url = origin + base + path_url
        for href, line in page.links:
            absolute = urlsplit(urljoin(page_url, href))
            if absolute.scheme not in ("http", "https") or absolute.netloc != deployment.netloc:
                continue
            # Only this repository's published site is local to this build.
            if not absolute.path.startswith(base):
                errors.append(f"{relative}:{line}: link escapes the deployment base: {href}")
                continue
            target_name = unquote(absolute.path[len(base):])
            target = site / target_name
            if target.is_dir():
                target = target / "index.html"
            if not target.is_file():
                errors.append(f"{relative}:{line}: missing target: {href}")
                continue
            checked += 1
            fragment = unquote(absolute.fragment)
            if fragment and target.suffix == ".html":
                target_page = pages.get(target.relative_to(site).as_posix())
                if target_page is None or fragment not in target_page.ids:
                    errors.append(f"{relative}:{line}: missing anchor: {href}")
    if legacy_snapshot:
        snapshot = json.loads(legacy_snapshot.read_text(encoding="utf-8"))
        for relative, anchors in snapshot.items():
            if relative not in pages:
                errors.append(f"Previously published page disappeared: {relative}")
                continue
            missing = set(anchors) - set(pages[relative].ids)
            if missing:
                errors.append(f"{relative}: previously published anchors disappeared: {', '.join(sorted(missing))}")
    if errors:
        raise ValueError("\n".join(errors))
    return len(pages), checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", type=Path, default=ROOT / "docs-site" / "dist")
    parser.add_argument("--base", default="/", help="Published path prefix (default: /).")
    parser.add_argument("--origin", default=ORIGIN, help="Published origin used to resolve local links.")
    parser.add_argument("--legacy-snapshot", type=Path)
    args = parser.parse_args()
    try:
        pages, links = check_site(args.site, args.base, args.legacy_snapshot, origin=args.origin)
    except ValueError as error:
        print(f"[docs check] FAILED\n{error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"[docs check] {pages} HTML pages; {links} local links, assets, and anchors passed.")


if __name__ == "__main__":
    main()
