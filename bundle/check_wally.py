"""Verify a Wally archive contains exactly the staged release package."""

from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import stat
import zipfile


ROOT = Path(__file__).resolve().parent.parent
REQUIRED = {
    "default.project.json",
    "wally.toml",
    "LICENSE",
    "NOTICE",
    "README.md",
    "Scribe-source-map.json",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_archive(archive_path, staging=ROOT / "dist" / "wally", root=ROOT):
    staging = Path(staging)
    root = Path(root)
    require(staging.is_dir(), f"Missing staging directory: {staging}")
    expected = {}
    for path in staging.rglob("*"):
        require(not path.is_symlink(), f"Linked staged path: {path}")
        if path.is_file():
            name = path.relative_to(staging).as_posix()
            require(
                name in REQUIRED or name.startswith(("src/", "licenses/")),
                f"Unexpected staged file: {name}",
            )
            expected[name] = path.read_bytes()
    require(REQUIRED <= expected.keys(), f"Missing required package files: {sorted(REQUIRED - expected.keys())}")
    require(any(name.startswith("licenses/") for name in expected), "Missing dependency licenses")

    core = {path.relative_to(root).as_posix() for path in (root / "src").rglob("*.luau")}
    require(bool(core), "No core Luau modules found")
    staged_core = {name for name in expected if name.endswith(".luau")}
    require(staged_core == core, "Staged core modules differ from repository sources")
    mapping = json.loads(expected["Scribe-source-map.json"])
    require(mapping.get("format") == 1, "Unsupported source map format")
    require(set(mapping["files"]) == core, "Source map does not cover exactly the core modules")
    for name in core:
        entry = mapping["files"][name]
        require(
            hashlib.sha256((root / name).read_bytes()).hexdigest() == entry["sourceSha256"],
            f"Source changed after staging: {name}",
        )
        require(
            hashlib.sha256(expected[name]).hexdigest() == entry["packedSha256"],
            f"Staged source changed: {name}",
        )

    directories = {str(parent) for name in expected for parent in PurePosixPath(name).parents if str(parent) != "."}
    seen = set()
    files = set()
    with zipfile.ZipFile(archive_path) as archive:
        for entry in archive.infolist():
            name = entry.orig_filename.rstrip("/")
            path = PurePosixPath(name)
            require(
                name and "\\" not in name and not path.is_absolute() and ".." not in path.parts and str(path) == name,
                f"Unsafe archive path: {entry.filename}",
            )
            require(name not in seen, f"Duplicate archive path: {name}")
            seen.add(name)
            require(not stat.S_ISLNK(entry.external_attr >> 16), f"Linked archive path: {name}")
            if entry.is_dir():
                require(name in directories, f"Unexpected archive directory: {name}")
            else:
                require(name in expected, f"Unexpected archive file: {name}")
                require(archive.read(entry) == expected[name], f"Archive source differs from staging: {name}")
                files.add(name)
    require(files == expected.keys(), f"Missing archive files: {sorted(expected.keys() - files)}")
    print(f"Verified {len(files)} Wally files, including {len(core)} core modules and their source map.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--staging", type=Path, default=ROOT / "dist" / "wally")
    args = parser.parse_args()
    check_archive(args.archive, args.staging)
