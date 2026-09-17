"""Focused regression checks for documentation migration boundaries."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import gen
from check_site import check_site
from starlight import convert_page, legacy_slug, material_blocks, page_link


class ConversionChecks(unittest.TestCase):
    def test_links_resolve_from_trailing_slash_routes(self):
        self.assertEqual(page_link("api/server.md#flush", "profiles.md"), "../api/server/#flush")
        self.assertEqual(page_link("../profiles.md#editing", "api/server.md"), "../../profiles/#editing")
        self.assertEqual(page_link("server.md#flush", "api/server.md"), "./#flush")
        self.assertEqual(page_link("intro.md", "templates.md"), "../getting-started/")
        self.assertEqual(page_link("assets/playground/index.html", "playground.md"), "../assets/playground/index.html")
        self.assertEqual(page_link("https://example.com/foo.md", "profiles.md"), "https://example.com/foo.md")

    def test_details_remain_optional_and_expanded_details_stay_open(self):
        result = material_blocks('???+ note "A `type` detail"\n    A paragraph.\n\n    ```lua\n    ??? not_an_aside\n    ```\n\n## Next')
        self.assertIn('class="scribe-details scribe-details--note" open>', result)
        self.assertIn("<summary>A <code>type</code> detail</summary>", result)
        self.assertIn("```lua\n??? not_an_aside\n```", result)
        self.assertIn("</details>\n\n## Next", result)
        self.assertNotIn(" open>", material_blocks('??? note "Closed"\n    Body'))

    def test_visible_warnings_and_code_are_not_mixed(self):
        result = material_blocks('!!! warning "Keep data"\n    A **warning**.\n\n```text\n!!! warning "Literal"\n```')
        self.assertIn(":::caution[Keep data]\nA **warning**.\n:::", result)
        self.assertIn('```text\n!!! warning "Literal"\n```', result)

    def test_headings_keep_legacy_anchors_and_one_title(self):
        result = convert_page("# Reading & Writing\n\n## A `Scribe.Big` value\n\n### .Get { #get }\n\n## Again\n\n## Again\n", "values.md", "docgen/guides/values.md")
        self.assertIn('title: "Reading & Writing"', result)
        self.assertIn('<span id="reading-writing"></span>', result)
        self.assertIn("## A `Scribe.Big` value {#a-scribebig-value}", result)
        self.assertIn("### .Get {#get}", result)
        self.assertIn("## Again {#again_1}", result)
        self.assertNotIn("\n# Reading", result)
        self.assertEqual(legacy_slug("Full-precision CFrames"), "full-precision-cframes")

    def test_gfm_union_tables_and_runnable_code(self):
        result = convert_page('# API\n\n| Type |\n| --- |\n| `string | number` |\n\n```lua\nlocal text = "a | b"\n-- [keep](example.md)\n## Keep this heading\n```\n', "api/value.md", "src/Internal/Node.luau")
        self.assertIn('`string \\| number`', result)
        self.assertIn('local text = "a | b"', result)
        self.assertIn('-- [keep](example.md)', result)
        self.assertIn('## Keep this heading\n```', result)

    def test_site_checker_rejects_missing_assets_and_anchors(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            (site / "index.html").write_text('<a href="/Scribe/guide/#works">Read</a><img src="/Scribe/logo.svg">', encoding="utf-8")
            (site / "guide").mkdir()
            (site / "guide" / "index.html").write_text('<h1 id="works">Works</h1>', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing target"):
                check_site(site, base="/Scribe/")
            (site / "logo.svg").write_text('<svg/>', encoding="utf-8")
            self.assertEqual(check_site(site, base="/Scribe/"), (2, 2))
            (site / "guide" / "index.html").write_text('<h1 id="renamed">Renamed</h1>', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing anchor"):
                check_site(site, base="/Scribe/")

    def test_root_deployment_checks_custom_domain_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            (site / "index.html").write_text(
                '<link rel="stylesheet" href="https://scribe.ericplane.dev/_astro/site.css">'
                '<script src="/_astro/site.js"></script><img src="assets/logo.svg">'
                '<a href="https://example.com/elsewhere/">External</a>', encoding="utf-8")
            (site / "_astro").mkdir()
            (site / "assets").mkdir()
            (site / "_astro/site.js").write_text("", encoding="utf-8")
            (site / "assets/logo.svg").write_text("<svg/>", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing target: https://scribe.ericplane.dev/_astro/site.css"):
                check_site(site)
            (site / "_astro/site.css").write_text("", encoding="utf-8")
            self.assertEqual(check_site(site), (1, 3))

    def test_root_deployment_rejects_stale_repository_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            (site / "index.html").write_text('<link rel="stylesheet" href="/Scribe/site.css">', encoding="utf-8")
            (site / "site.css").write_text("", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing target: /Scribe/site.css"):
                check_site(site)
            self.assertEqual(check_site(site, base="/Scribe/", origin="https://ericplane.github.io"), (1, 1))

    def test_checker_supports_an_explicit_deployment_origin(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            (site / "index.html").write_text('<img src="https://docs.example.com/logo.svg">', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing target"):
                check_site(site, origin="https://docs.example.com")
            (site / "logo.svg").write_text("<svg/>", encoding="utf-8")
            self.assertEqual(check_site(site, origin="https://docs.example.com/"), (1, 1))
            with self.assertRaisesRegex(ValueError, "without a path"):
                check_site(site, origin="https://docs.example.com/Scribe/")


class PublishChecks(unittest.TestCase):
    def test_invalid_source_and_failed_asset_stage_preserve_working_output(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory) / "website"
            output, public = site / "src/content/docs", site / "public"
            source, theme = site / "authoring", site / "theme"
            for path in (output, public / "assets", source, theme / "assets"):
                path.mkdir(parents=True)
            (output / "working.md").write_text("last working page", encoding="utf-8")
            (public / "assets/logo.svg").write_text("last working asset", encoding="utf-8")
            def snapshot():
                return {str(path.relative_to(site)): (path.read_bytes(), path.stat().st_mtime_ns)
                        for folder in (output, public) for path in folder.rglob("*") if path.is_file()}
            original = snapshot()
            with patch.multiple(gen, SITE=site, OUT=output, PUBLIC=public, DOCS=source, THEME=theme), \
                 patch.object(gen, "collect", return_value=({}, {})):
                guide = source / "guide.md"
                guide.write_text("# Invalid\n\nScribe.NotAnExport()", encoding="utf-8")
                with self.assertRaises(SystemExit):
                    gen.main()
                self.assertEqual(snapshot(), original)
                self.assertEqual(list(site.glob(".docgen-*")), [])
                guide.write_text("# Fixed\n\nThis is valid.", encoding="utf-8")
                with patch.object(gen, "build_playground", side_effect=ValueError("asset staging failed")):
                    with self.assertRaisesRegex(ValueError, "asset staging failed"):
                        gen.main()
                self.assertEqual(snapshot(), original)
                self.assertEqual(list(site.glob(".docgen-*")), [])

    def test_publish_keeps_unchanged_mtimes_and_removes_only_obsolete_output(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            stage, destination = site / ".docgen-test", site / "generated"
            incoming = stage / "docs"
            incoming.mkdir(parents=True)
            destination.mkdir()
            (destination / "same.md").write_text("same", encoding="utf-8")
            (incoming / "same.md").write_text("same", encoding="utf-8")
            stamp = (destination / "same.md").stat().st_mtime_ns
            (destination / "old.md").write_text("obsolete", encoding="utf-8")
            (incoming / "new.md").write_text("new", encoding="utf-8")
            with patch.object(gen, "SITE", site):
                self.assertEqual(gen.publish_generated(((incoming, destination),), stage), 2)
            self.assertEqual((destination / "same.md").stat().st_mtime_ns, stamp)
            self.assertFalse((destination / "old.md").exists())
            self.assertEqual((destination / "new.md").read_text(encoding="utf-8"), "new")

    def test_publish_failure_restores_files_already_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            stage, destination = site / ".docgen-test", site / "generated"
            incoming = stage / "docs"
            incoming.mkdir(parents=True)
            destination.mkdir()
            for name in ("first.md", "second.md"):
                (incoming / name).write_text("new " + name, encoding="utf-8")
                (destination / name).write_text("old " + name, encoding="utf-8")
            original = {path.name: (path.read_bytes(), path.stat().st_mtime_ns) for path in destination.iterdir()}
            replace, attempted = Path.replace, []
            def fail_second_source(path, target):
                if path.parent == incoming:
                    attempted.append(path.name)
                    if len(attempted) == 2:
                        raise OSError("simulated file lock")
                return replace(path, target)
            with patch.object(gen, "SITE", site), patch.object(Path, "replace", fail_second_source):
                with self.assertRaisesRegex(OSError, "simulated file lock"):
                    gen.publish_generated(((incoming, destination),), stage)
            actual = {path.name: (path.read_bytes(), path.stat().st_mtime_ns) for path in destination.iterdir()}
            self.assertEqual(actual, original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
