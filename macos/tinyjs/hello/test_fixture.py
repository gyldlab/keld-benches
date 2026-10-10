#!/usr/bin/env python3
"""Offline build-contract tests. No metric samples, GUI claim, or publication."""
from __future__ import annotations

import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

import build


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)

    def archive(self, names=("tinyjs/bin/tjs",), kind=tarfile.REGTYPE):
        path = self.root / "sdk.tar.gz"
        with tarfile.open(path, "w:gz") as bundle:
            for name in names:
                item = tarfile.TarInfo(name)
                item.type = kind
                item.mode = 0o755
                item.size = 4 if kind == tarfile.REGTYPE else 0
                if kind == tarfile.SYMTYPE:
                    item.linkname = "../../escape"
                bundle.addfile(item, io.BytesIO(b"test") if item.size else None)
        return path, {"bytes": path.stat().st_size, "sha256": build.sha256(path)}

    def test_verified_regular_archive_extracts_executable(self):
        path, pin = self.archive()
        sdk = build.extract_sdk(path, self.root / "unpack", pin)
        self.assertEqual((sdk / "bin/tjs").read_bytes(), b"test")
        self.assertEqual((sdk / "bin/tjs").stat().st_mode & 0o777, 0o755)

    def test_digest_mismatch_rejects_before_extraction(self):
        path, pin = self.archive()
        pin["sha256"] = "0" * 64
        dest = self.root / "unpack"
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            build.extract_sdk(path, dest, pin)
        self.assertFalse(dest.exists())

    def test_size_mismatch_rejects(self):
        path, pin = self.archive()
        pin["bytes"] += 1
        with self.assertRaisesRegex(ValueError, "size"):
            build.extract_sdk(path, self.root / "unpack", pin)

    def test_unsafe_archive_paths_reject(self):
        for name in ("/absolute", "tinyjs/../../escape", "other/bin/tjs"):
            with self.subTest(name=name):
                path, pin = self.archive((name,))
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    build.extract_sdk(path, self.root / "unpack", pin)
                self.assertFalse((self.root / "unpack").exists())

    def test_links_and_devices_reject(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE):
            with self.subTest(kind=kind):
                path, pin = self.archive(kind=kind)
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    build.extract_sdk(path, self.root / "unpack", pin)

    def test_duplicate_members_reject(self):
        path, pin = self.archive(("tinyjs/bin/tjs", "tinyjs/bin/tjs"))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            build.extract_sdk(path, self.root / "unpack", pin)

    def test_existing_output_is_not_overwritten(self):
        sentinel = self.root / "keep"
        sentinel.write_text("keep")
        with self.assertRaises(FileExistsError):
            build.reserve_output(self.root)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_output_inside_source_rejects(self):
        source = self.root / "source"
        source.mkdir()
        with self.assertRaisesRegex(ValueError, "outside"):
            build.reserve_output(source / "out", source)
        self.assertFalse((source / "out").exists())

    def test_symlink_output_rejects(self):
        link = self.root / "link"
        link.symlink_to(self.root / "missing", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            build.reserve_output(link)
        self.assertFalse((self.root / "missing").exists())

    def test_new_output_is_private(self):
        out = build.reserve_output(self.root / "out")
        self.assertEqual(out.stat().st_mode & 0o777, 0o700)

    def test_staging_uses_canonical_and_normal_backend(self):
        project = build.stage_project(self.root)
        self.assertEqual((project / "src/frontend/index.html").read_bytes(),
                         build.CANONICAL.read_bytes())
        self.assertEqual((project / "src/main.js").read_bytes(),
                         (build.HERE / "src/main.js").read_bytes())
        config = json.loads((project / "tinyjs.json").read_text())
        self.assertEqual(config["size"], "960x640")
        self.assertIs(config["debug"], False)
        self.assertNotIn("update", config)
        self.assertNotIn("url", config)

    def fake_app(self):
        app = self.root / "test.app"
        data = app / "Contents/Resources/app"
        (data / "frontend").mkdir(parents=True)
        (data / "src").mkdir()
        (data / "frontend/index.html").write_bytes(build.CANONICAL.read_bytes())
        (data / "src/main.js").write_bytes((build.HERE / "src/main.js").read_bytes())
        return app, data

    def test_packaged_renderer_tamper_rejects(self):
        app, data = self.fake_app()
        build.verify_payload(app)
        (data / "frontend/index.html").write_text("different")
        with self.assertRaisesRegex(ValueError, "renderer"):
            build.verify_payload(app)

    def test_packaged_backend_tamper_rejects(self):
        app, data = self.fake_app()
        (data / "src/main.js").write_text("different")
        with self.assertRaisesRegex(ValueError, "backend"):
            build.verify_payload(app)

    def test_upstream_is_release_and_architecture_pinned(self):
        upstream = json.loads((build.HERE / "upstream.json").read_text())
        self.assertRegex(upstream["source_commit"], r"^[0-9a-f]{40}$")
        self.assertEqual(upstream["version"], "v0.50.1")
        self.assertEqual(set(upstream["assets"]), {"arm64", "x86_64"})
        for arch, pin in upstream["assets"].items():
            self.assertEqual(pin["name"], "tinyjs-macos-" + arch + ".tar.gz")
            self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(pin["bytes"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
