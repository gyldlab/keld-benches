#!/usr/bin/env python3
"""Contract and optional real-Wayland tests for the GTK4 native floor."""

from __future__ import annotations

import os
import pathlib
import selectors
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "linux" / "gtk4" / "hello"
SOURCE = FIXTURE / "main.c"
BUILD = FIXTURE / "build.sh"
PAYLOAD = ROOT / "linux" / "keld" / "hello" / "index.html"
sys.path.insert(0, str(ROOT / "linux" / "bench"))

from harness import BeaconServer, OwnedProcess  # noqa: E402


class _RedirectServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, redirect_to: str | None) -> None:
        self.redirect_to = redirect_to
        self.observed = threading.Event()
        super().__init__(("127.0.0.1", 0), _RedirectHandler)


class _RedirectHandler(BaseHTTPRequestHandler):
    server: _RedirectServer

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.server.observed.set()
        if self.server.redirect_to is not None:
            self.send_response(302)
            self.send_header("Location", self.server.redirect_to)
            body = b"redirect\n"
        else:
            self.send_response(200)
            body = b"escaped\n"
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


def _start_server(server: _RedirectServer) -> threading.Thread:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


def _stop_server(server: _RedirectServer, thread: threading.Thread) -> None:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)
    if thread.is_alive():
        raise AssertionError("redirect test server did not stop")


class Gtk4FixtureTests(unittest.TestCase):
    def test_committed_source_declares_one_gtk4_webkitgtk_window(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        for required in (
            "gtk_application_new",
            "gtk_application_window_new",
            "webkit_web_view_new",
            "gtk_window_set_child",
            "webkit_web_view_load_uri",
            "gtk_window_present",
        ):
            self.assertEqual(source.count(required), 1, required)
        self.assertIn("KELD_BENCH_URL", source)
        self.assertIn("127.0.0.1", source)
        self.assertIn('"decide-policy"', source)
        self.assertIn("webkit_policy_decision_ignore", source)
        self.assertNotIn("G_SOURCE_CONTINUE", source)

    def test_build_is_strict_and_uses_the_native_gtk4_lane(self) -> None:
        build = BUILD.read_text(encoding="utf-8")
        self.assertIn("pkg-config --cflags-only-I gtk4 webkitgtk-6.0", build)
        self.assertIn("pkg-config --cflags-only-other gtk4 webkitgtk-6.0", build)
        self.assertIn("pkg-config --libs gtk4 webkitgtk-6.0", build)
        self.assertIn("-isystem", build)
        self.assertIn("-Wall -Wextra -Werror -Wpedantic", build)
        self.assertIn("refusing to overwrite", build)
        self.assertIn("diff --quiet HEAD", build)
        self.assertIn('if [ -e "$staged" ] || [ -L "$staged" ]; then', build)
        self.assertEqual(build.count("refusing to overwrite output created during build"), 2)

    def test_binary_rejects_missing_or_non_loopback_url_before_gtk(self) -> None:
        artifact = os.environ.get("GTK4_FIXTURE_ARTIFACT")
        if not artifact:
            self.skipTest("set GTK4_FIXTURE_ARTIFACT to exercise the built binary")
        for value in (None, "https://example.com/", "http://localhost:1/not-a-run"):
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
                timeout=5,
            )
            self.assertEqual(completed.returncode, 64, completed.stderr.decode())
            self.assertIn(b"KELD_BENCH_URL", completed.stderr)

    def test_off_domain_redirect_is_rejected_before_target_request(self) -> None:
        artifact = os.environ.get("GTK4_FIXTURE_ARTIFACT")
        if not artifact or os.environ.get("GTK4_FIXTURE_REAL") != "1":
            self.skipTest("set GTK4_FIXTURE_ARTIFACT and GTK4_FIXTURE_REAL=1")
        target = _RedirectServer(None)
        target_thread = _start_server(target)
        target_port = int(target.server_address[1])
        origin = _RedirectServer(f"http://127.0.0.1:{target_port}/escaped")
        origin_thread = _start_server(origin)
        origin_port = int(origin.server_address[1])
        approved = f"http://127.0.0.1:{origin_port}/run/{'ab' * 16}/index.html"
        process = subprocess.Popen(
            [artifact],
            env={**os.environ, "KELD_BENCH_URL": approved},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        owner = OwnedProcess(process)
        try:
            self.assertTrue(origin.observed.wait(5), "fixture did not request the approved URL")
            self.assertIsNotNone(process.stderr)
            with selectors.DefaultSelector() as selector:
                selector.register(process.stderr, selectors.EVENT_READ)
                self.assertTrue(selector.select(5), "fixture did not report the blocked redirect")
            self.assertEqual(process.stderr.readline(), b"KELD-BENCH-URL-BLOCKED\n")
            self.assertFalse(target.observed.is_set(), "fixture followed the rejected redirect")
            self.assertIsNone(process.poll(), "fixture exited after rejecting the redirect")
        finally:
            owner.cleanup()
            if process.stderr is not None:
                process.stderr.close()
            _stop_server(origin, origin_thread)
            _stop_server(target, target_thread)
        self.assertFalse(target.observed.is_set(), "redirect target was requested during cleanup")

    def test_real_wayland_window_emits_exact_double_raf_beacon_and_reaps(self) -> None:
        artifact = os.environ.get("GTK4_FIXTURE_ARTIFACT")
        if not artifact or os.environ.get("GTK4_FIXTURE_REAL") != "1":
            self.skipTest("set GTK4_FIXTURE_ARTIFACT and GTK4_FIXTURE_REAL=1")
        server = BeaconServer(PAYLOAD.read_bytes())
        server.start()
        process = subprocess.Popen(
            [artifact],
            env={**os.environ, "KELD_BENCH_URL": server.page_url},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        owner = OwnedProcess(process)
        try:
            self.assertTrue(server.wait_for_beacon(15), "native GTK4 beacon timed out")
            snapshot = server.snapshot()
            self.assertEqual(snapshot.page_requests, 1)
            self.assertEqual(snapshot.beacon_requests, 1)
            self.assertEqual(snapshot.rejections, ())
            self.assertIsNone(snapshot.protocol_error)
            self.assertIsNone(process.poll(), "native window exited before cleanup")
        finally:
            owner.cleanup()
            server.close()
        self.assertIsNotNone(process.returncode)


if __name__ == "__main__":
    unittest.main(verbosity=2)
