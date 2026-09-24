"""Stage release sources without the website's API doc blocks."""

from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil


ROOT = Path(__file__).resolve().parent.parent
PROJECTS = ("rbxm", "telemetry", "ui-adapters", "leaderstats")
API_TAG = re.compile(r"(?m)^\s*@(class|within|interface|type)\s+\S")
LONG_OPEN = re.compile(r"\[(=*)\[")


def long_end(source, start):
    opening = LONG_OPEN.match(source, start)
    if not opening:
        return None
    closing = "]" + opening[1] + "]"
    end = source.find(closing, opening.end())
    if end < 0:
        raise ValueError("Unterminated long string or comment")
    return end + len(closing)


def quoted_end(source, start):
    quote = source[start]
    i = start + 1
    while i < len(source):
        if source[i] == "\\":
            i += 2
        elif source[i] == quote:
            return i + 1
        elif quote == "`" and source[i] == "{":
            i = interpolation_end(source, i + 1)
        else:
            i += 1
    raise ValueError("Unterminated quoted string")


def comment_end(source, start):
    end = long_end(source, start + 2)
    if end is not None:
        return end
    end = source.find("\n", start)
    return len(source) if end < 0 else end


def interpolation_end(source, start):
    depth = 1
    i = start
    while i < len(source):
        if source.startswith("--", i):
            i = comment_end(source, i)
        elif source[i] in "\"'`":
            i = quoted_end(source, i)
        elif source[i] == "[" and (end := long_end(source, i)) is not None:
            i = end
        else:
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
    raise ValueError("Unterminated string interpolation")


def api_blocks(source):
    """Find actual comments, never marker-like text inside strings."""
    i = 0
    while i < len(source):
        if source.startswith("--", i):
            end = comment_end(source, i)
            if source.startswith("--[=[", i) and API_TAG.search(source[i + 5:end - 3]):
                yield i, end
            i = end
        elif source[i] in "\"'`":
            i = quoted_end(source, i)
        elif source[i] == "[" and (end := long_end(source, i)) is not None:
            i = end
        else:
            i += 1


def strip_api_docs(source):
    pieces = []
    segments = [[1, 1]]
    cursor = 0
    removed_lines = 0
    count = 0
    for start, end in api_blocks(source):
        line_start = source.rfind("\n", 0, start) + 1
        line_end = source.find("\n", end)
        line_end = len(source) if line_end < 0 else line_end + 1
        standalone = not source[line_start:start].strip() and not source[end:line_end].strip()
        if standalone:
            start, end = line_start, line_end
            # Avoid empty gaps where several documentation-only blocks stood.
            while end < len(source):
                next_end = source.find("\n", end)
                next_end = len(source) if next_end < 0 else next_end + 1
                if source[end:next_end].strip():
                    break
                end = next_end
            replacement = ""
            output_line = source.count("\n", 0, start) + 1 - removed_lines
            removed_lines += source.count("\n", start, end)
            segment = [output_line, output_line + removed_lines]
            if segments[-1][0] == output_line:
                segments[-1] = segment
            else:
                segments.append(segment)
        else:
            # Inline blocks keep separators and line positions.
            replacement = " " + "".join(re.findall(r"\r\n|\n|\r", source[start:end]))
        pieces.extend((source[cursor:start], replacement))
        cursor = end
        count += 1
    pieces.append(source[cursor:])
    return "".join(pieces), segments, count


def stage(version, root=ROOT, target="rbxm"):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError("Expected a release version such as 2.5.0")
    folders = {"rbxm": "rbxm", "npm": "npm-sources", "wally": "wally"}
    if target not in folders:
        raise ValueError(f"Unknown package target: {target}")
    root = root.resolve()
    destination = root / "dist" / folders[target]
    for path in (destination.parent, destination):
        if path.is_symlink() or path.resolve() != path:
            raise ValueError(f"Refusing redirected staging path: {path}")
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    files = {}
    removed_bytes = 0
    removed_blocks = 0
    for directory in (("src",) if target == "wally" else ("src", "addons")):
        for path in sorted((root / directory).rglob("*")):
            if path.is_symlink():
                raise ValueError(f"Refusing linked source: {path}")
            if not path.is_file():
                continue
            relative = path.relative_to(root)
            output = destination / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            raw = path.read_bytes()
            if path.suffix == ".luau":
                source = raw.decode("utf-8").replace("\r\n", "\n")
                text, segments, count = strip_api_docs(source)
                packed = text.encode("utf-8")
                files[relative.as_posix()] = {
                    "sourceSha256": hashlib.sha256(raw).hexdigest(),
                    "packedSha256": hashlib.sha256(packed).hexdigest(),
                    "segments": segments,
                }
                removed_bytes += len(source.encode("utf-8")) - len(packed)
                removed_blocks += count
            else:
                packed = raw
            output.write_bytes(packed)
    if target == "rbxm":
        bundle = destination / "bundle"
        bundle.mkdir()
        for name in PROJECTS:
            project = json.loads((root / "bundle" / f"{name}.project.json").read_text(encoding="utf-8"))
            if name == "rbxm":
                project["name"] = f"Scribe v{version}"
            (bundle / f"{name}.project.json").write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")
        readme = (root / "bundle" / "README.luau").read_bytes().replace(b"\r\n", b"\n")
        readme = readme.replace(b"__VERSION__", version.encode())
        (bundle / "README.luau").write_bytes(readme)
    elif target == "wally":
        for name in ("default.project.json", "wally.toml", "LICENSE", "NOTICE", "README.md"):
            shutil.copyfile(root / name, destination / name)
        # Match Wally's serialization of the project file.
        project = json.loads((root / "default.project.json").read_text(encoding="utf-8"))
        (destination / "default.project.json").write_text(json.dumps(project, indent=2), encoding="utf-8", newline="\n")
        shutil.copytree(root / "licenses", destination / "licenses")
    mapping = {
        "version": version,
        "format": 1,
        "description": "Segments are [packedLine, sourceLine]. Use the last segment at or before the packed line, then add its line offset.",
        "files": files,
    }
    (destination / "Scribe-source-map.json").write_text(json.dumps(mapping, indent=2) + "\n", encoding="utf-8")
    print(f"Staged {len(files)} modules; removed {removed_blocks} API blocks and {removed_bytes:,} source bytes.")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--target", choices=("rbxm", "wally", "npm"), default="rbxm")
    args = parser.parse_args()
    stage(args.version, target=args.target)
