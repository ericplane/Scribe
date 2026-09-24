"""Ensure archive checks catch missing, altered, and unexpected package files."""

from pathlib import Path
import hashlib
import json
import tempfile
import unittest
import warnings
import zipfile

from check_wally import REQUIRED, check_archive


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.staging = self.root / "dist/wally"
        self.archive = self.root / "package.zip"
        mapping = {"format": 1, "files": {}}
        for name in ("src/init.luau", "src/Internal/Helper.luau"):
            original = b"-- API docs\n-- Short summary.\nreturn 1\n"
            packed = b"-- Short summary.\nreturn 1\n"
            for directory, value in ((self.root, original), (self.staging, packed)):
                target = directory / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(value)
            mapping["files"][name] = {
                "sourceSha256": hashlib.sha256(original).hexdigest(),
                "packedSha256": hashlib.sha256(packed).hexdigest(),
                "segments": [[1, 2]],
            }
        for name in REQUIRED - {"Scribe-source-map.json"}:
            (self.staging / name).write_bytes(b"fixture\n")
        (self.staging / "licenses").mkdir()
        (self.staging / "licenses/dependency.txt").write_bytes(b"license\n")
        (self.staging / "Scribe-source-map.json").write_text(json.dumps(mapping), encoding="utf-8")
        self.contents = {
            path.relative_to(self.staging).as_posix(): path.read_bytes()
            for path in self.staging.rglob("*")
            if path.is_file()
        }

    def write_archive(self, contents=None, extra=None):
        with warnings.catch_warnings(), zipfile.ZipFile(self.archive, "w") as archive:
            warnings.simplefilter("ignore", UserWarning)
            for directory in ("src/", "src/Internal/", "licenses/"):
                archive.writestr(directory, b"")
            for name, value in (self.contents if contents is None else contents).items():
                archive.writestr(name, value)
            if extra:
                entry = zipfile.ZipInfo()
                entry.filename = extra[0]
                archive.writestr(entry, extra[1])

    def check(self):
        check_archive(self.archive, self.staging, self.root)

    def test_exact_package_with_directories_passes(self):
        self.write_archive()
        self.check()

    def test_missing_source_or_map_fails(self):
        for name in ("src/Internal/Helper.luau", "Scribe-source-map.json"):
            with self.subTest(name=name):
                self.write_archive({key: value for key, value in self.contents.items() if key != name})
                with self.assertRaisesRegex(ValueError, "Missing archive files"):
                    self.check()

    def test_changed_archive_source_fails(self):
        self.write_archive({**self.contents, "src/init.luau": b"return 2\n"})
        with self.assertRaisesRegex(ValueError, "Archive source differs"):
            self.check()

    def test_unexpected_files_and_directories_fail(self):
        for name in ("test/example.luau", "tools/helper.py", "docs/", "addons/extra.luau"):
            with self.subTest(name=name):
                self.write_archive(extra=(name, b""))
                with self.assertRaisesRegex(ValueError, "Unexpected archive"):
                    self.check()

    def test_unsafe_and_duplicate_paths_fail(self):
        for name in ("../secret", "src/../secret", "src\\secret", "/absolute", "src/init.luau"):
            with self.subTest(name=name):
                self.write_archive(extra=(name, b""))
                with self.assertRaisesRegex(ValueError, "Unsafe archive path|Duplicate archive path"):
                    self.check()

    def test_changed_original_or_staged_source_fails(self):
        self.write_archive()
        for directory, message in ((self.root, "Source changed"), (self.staging, "Staged source changed")):
            with self.subTest(directory=directory):
                target = directory / "src/init.luau"
                original = target.read_bytes()
                target.write_bytes(b"return 2\n")
                with self.assertRaisesRegex(ValueError, message):
                    self.check()
                target.write_bytes(original)

    def test_incomplete_map_fails(self):
        path = self.staging / "Scribe-source-map.json"
        mapping = json.loads(path.read_bytes())
        del mapping["files"]["src/Internal/Helper.luau"]
        path.write_text(json.dumps(mapping), encoding="utf-8")
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "Source map does not cover"):
            self.check()

    def test_repository_source_missing_from_staging_fails(self):
        (self.root / "src/Added.luau").write_bytes(b"return 1\n")
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "Staged core modules differ"):
            self.check()


if __name__ == "__main__":
    unittest.main()
