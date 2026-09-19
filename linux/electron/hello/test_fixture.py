#!/usr/bin/env python3
"""Contract and optional real-display tests for the Linux Electron comparator."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "linux" / "electron" / "hello"
SOURCE = FIXTURE / "src" / "main.js"
HTML = FIXTURE / "src" / "index.html"
PACKAGE = FIXTURE / "package.json"
LOCK = FIXTURE / "package-lock.json"
BUILD = FIXTURE / "build.sh"
PAYLOAD = ROOT / "linux" / "keld" / "hello" / "index.html"
sys.path.insert(0, str(ROOT / "linux" / "bench"))

from harness import BeaconServer, OwnedProcess  # noqa: E402


def _artifact() -> str | None:
    return os.environ.get("ELECTRON_FIXTURE_ARTIFACT")


def _wait_for_beacon(server: BeaconServer, process: subprocess.Popen[bytes], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError("Electron paint beacon timed out")
        if server.wait_for_beacon(min(remaining, 0.1)):
            return
        rc = process.poll()
        if rc is not None:
            stderr = process.stderr.read(4096) if process.stderr else b""
            raise AssertionError(
                f"Electron exited before beacon: {rc}: "
                f"{stderr.decode('utf-8', errors='replace')}"
            )


class ElectronFixtureTests(unittest.TestCase):
    def test_source_pins_secure_black_window_and_loopback_contract(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        package = json.loads(PACKAGE.read_text(encoding="utf-8"))
        lock = LOCK.read_text(encoding="utf-8")
        html = HTML.read_text(encoding="utf-8")

        self.assertEqual(package["devDependencies"]["electron"], "43.4.0")
        self.assertIn('"node_modules/electron"', lock)
        self.assertIn('"version": "43.4.0"', lock)
        for required in (
            "KELD_BENCH_URL",
            'parsed.hostname !== "127.0.0.1"',
            "setWindowOpenHandler",
            '"deny"',
            '"will-navigate"',
            "contextIsolation: true",
            "nodeIntegration: false",
            "sandbox: true",
            "app.enableSandbox()",
            'backgroundColor: "#000000"',
        ):
            self.assertIn(required, source)
        self.assertNotIn("--no-sandbox", source)
        self.assertIn("background: #000", html)

    def test_build_recipe_is_commit_bound_locked_and_uses_official_runtime(self) -> None:
        build = BUILD.read_text(encoding="utf-8")
        for required in (
            "diff --quiet HEAD",
            "package-lock.json",
            "npm ci --ignore-scripts",
            "node node_modules/electron/install.js",
            "node_modules/electron/dist",
            "ELECTRON_RUN_AS_NODE",
            "tree_sha256",
            "refusing to overwrite",
        ):
            self.assertIn(required, build)

    def test_binary_rejects_missing_and_non_loopback_url_before_gui(self) -> None:
        artifact = _artifact()
        if not artifact:
            self.skipTest("set ELECTRON_FIXTURE_ARTIFACT")
        for value in (
            None,
            "https://example.com/",
            "http://localhost:1/run/abababababababababababababababab/index.html",
            "http://127.0.0.1:1/not-a-run",
        ):
            env = os.environ.copy()
            env.pop("KELD_BENCH_URL", None)
            if value is not None:
                env["KELD_BENCH_URL"] = value
            completed = subprocess.run(
                [artifact],
                env=env,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 64, completed.stderr.decode())
            self.assertIn(b"KELD_BENCH_URL", completed.stderr)

    def test_real_display_emits_exact_beacon_and_reaps(self) -> None:
        artifact = _artifact()
        if not artifact or os.environ.get("ELECTRON_FIXTURE_REAL") != "1":
            self.skipTest("set ELECTRON_FIXTURE_ARTIFACT and ELECTRON_FIXTURE_REAL=1")
        server = BeaconServer(PAYLOAD.read_bytes())
        server.start()
        process = subprocess.Popen(
            [artifact],
            env={**os.environ, "KELD_BENCH_URL": server.page_url},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        owner = OwnedProcess(process)
        try:
            _wait_for_beacon(server, process, 25)
            snapshot = server.snapshot()
            self.assertEqual(snapshot.page_requests, 1)
            self.assertEqual(snapshot.beacon_requests, 1)
            self.assertEqual(snapshot.rejections, ())
            self.assertIsNone(snapshot.protocol_error)
            self.assertIsNone(process.poll(), "Electron exited before cleanup")
        finally:
            owner.cleanup()
            server.close()
            if process.stderr:
                process.stderr.close()
        self.assertIsNotNone(process.returncode)


if __name__ == "__main__":
    unittest.main(verbosity=2)
