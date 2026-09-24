"""Regression checks for release-only documentation stripping."""

from pathlib import Path
import json
import tempfile
import unittest

from stage import stage, strip_api_docs


DOC = "--[=[\n @within Example\n Explains the API.\n]=]"


class StripTests(unittest.TestCase):
    def test_standalone_docs_shrink_and_map_lines(self):
        source = "--!strict\n" + DOC + "\n-- Short summary.\nreturn 1\n"
        packed, segments, count = strip_api_docs(source)
        self.assertEqual(packed, "--!strict\n-- Short summary.\nreturn 1\n")
        self.assertEqual(segments, [[1, 1], [2, 6]])
        self.assertEqual(count, 1)

    def test_strings_and_ordinary_comments_are_untouched(self):
        values = [
            '"--[=[ @within Fake ]=]"',
            "'escaped \\' --[=[ @within Fake ]=]'",
            "[==[" + DOC + "]==]",
            "`" + DOC + "`",
            '`outer {`nested {"--[=[ @type Fake ]=]"}`} tail`',
            '`braces {({value = "}"}).value} \\` escaped`',
        ]
        source = "--!native\n--!optimize 2\n--!nolint\n-- Short note.\n--[=[Internal note.]=]\n"
        source += "--[==[\n @within UnrelatedBracketStyle\n]==]\n"
        source += "\n".join("local value = " + value for value in values)
        self.assertEqual(strip_api_docs(source), (source, [[1, 1]], 0))

    def test_inline_doc_keeps_a_token_separator(self):
        packed, segments, count = strip_api_docs("return" + DOC + "1")
        self.assertEqual(packed, "return \n\n\n1")
        self.assertEqual(segments, [[1, 1]])
        self.assertEqual(count, 1)

    def test_adjacent_blocks_and_crlf(self):
        source = (DOC + "\n" + DOC + "\nreturn 1\n").replace("\n", "\r\n")
        packed, segments, count = strip_api_docs(source)
        self.assertEqual(packed, "return 1\r\n")
        self.assertEqual(segments, [[1, 9]])
        self.assertEqual(count, 2)
        self.assertEqual(strip_api_docs(packed), (packed, [[1, 1]], 0))

    def test_doc_only_sections_do_not_leave_empty_gaps(self):
        source = "local a = 1\n\n" + DOC + "\n\n" + DOC + "\n\nreturn a\n"
        packed, segments, count = strip_api_docs(source)
        self.assertEqual(packed, "local a = 1\n\nreturn a\n")
        self.assertEqual(segments, [[1, 1], [3, 13]])
        self.assertEqual(count, 2)

    def test_incomplete_input_fails(self):
        for source in ('"unfinished', "[=[unfinished", "--[=[\n @class Example", "`unfinished {value"):
            with self.subTest(source=source), self.assertRaises(ValueError):
                strip_api_docs(source)

    def test_staging_keeps_originals_and_replaces_stale_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("src", "addons", "bundle"):
                (root / name).mkdir()
            source = (DOC + "\n-- Short summary.\nreturn 1\n").encode()
            (root / "src/init.luau").write_bytes(source)
            (root / "bundle/README.luau").write_text('return "__VERSION__"', encoding="utf-8")
            for name in ("rbxm", "telemetry", "ui-adapters", "leaderstats"):
                (root / "bundle" / f"{name}.project.json").write_text('{"name":"Scribe"}', encoding="utf-8")
            output = stage("2.5.0", root)
            self.assertEqual((root / "src/init.luau").read_bytes(), source)
            self.assertEqual((output / "src/init.luau").read_text(), "-- Short summary.\nreturn 1\n")
            self.assertEqual((root / "bundle/README.luau").read_text(), 'return "__VERSION__"')
            self.assertEqual((output / "bundle/README.luau").read_text(), 'return "2.5.0"')
            mapping = json.loads((output / "Scribe-source-map.json").read_text())
            self.assertEqual(mapping["files"]["src/init.luau"]["segments"], [[1, 5]])
            (output / "stale.luau").write_text("return 0")
            stage("2.5.0", root)
            self.assertFalse((output / "stale.luau").exists())

    def test_all_packages_share_core_source_and_line_mapping(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("src", "addons", "bundle", "licenses"):
                (root / name).mkdir()
            (root / "src/init.luau").write_bytes((DOC + "\n-- Short summary.\nreturn 1\n").replace("\n", "\r\n").encode())
            (root / "addons/Example.luau").write_text("return 2\n", encoding="utf-8")
            (root / "bundle/README.luau").write_text('return "__VERSION__"', encoding="utf-8")
            for name in ("rbxm", "telemetry", "ui-adapters", "leaderstats"):
                (root / "bundle" / f"{name}.project.json").write_text('{"name":"Scribe"}', encoding="utf-8")
            for name in ("wally.toml", "LICENSE", "NOTICE", "README.md", "licenses/Store.txt"):
                (root / name).write_text("unchanged", encoding="utf-8")
            (root / "default.project.json").write_text('{"tree":{"$path":"src"}}', encoding="utf-8")
            destinations = [stage("2.5.0", root, target) for target in ("rbxm", "wally", "npm")]
            for output in destinations:
                self.assertEqual((output / "src/init.luau").read_bytes(), b"-- Short summary.\nreturn 1\n")
                mapping = json.loads((output / "Scribe-source-map.json").read_text())
                self.assertEqual(mapping["files"]["src/init.luau"]["segments"], [[1, 5]])
            self.assertFalse((destinations[1] / "addons").exists())
            self.assertFalse((destinations[2] / "bundle").exists())


if __name__ == "__main__":
    unittest.main()
