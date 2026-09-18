#!/usr/bin/env python3
"""Contract and optional real-display tests for the Linux Tauri comparator."""

from __future__ import annotations

import os
import pathlib
import selectors
import subprocess
import sys
import threading
import time
import unittest
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "linux" / "tauri" / "hello"
SOURCE = FIXTURE / "src-tauri" / "src" / "main.rs"
CARGO = FIXTURE / "src-tauri" / "Cargo.toml"
LOCK = FIXTURE / "src-tauri" / "Cargo.lock"
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

    def do_GET(self) -> None:  # noqa: N802
        self.server.observed.set()
        if self.server.redirect_to is None:
            body = b"escaped\n"
            self.send_response(200)
        else:
            body = b"redirect\n"
            self.send_response(302)
            self.send_header("Location", self.server.redirect_to)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


def _serve(server: _RedirectServer) -> threading.Thread:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


def _stop(server: _RedirectServer, thread: threading.Thread) -> None:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)
    if thread.is_alive():
        raise AssertionError("redirect server did not stop")


def _wait_signal(
    wait_for_signal: Callable[[float], bool],
    process: subprocess.Popen[bytes],
    timeout: float,
    message: str,
) -> None:
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(f"{message}; fixture remained running")
        if wait_for_signal(min(remaining, 0.1)):
            return
        rc = process.poll()
        if rc is not None:
            stderr = process.stderr.read(4096) if process.stderr else b""
            detail = stderr.decode("utf-8", errors="replace").strip()
            raise AssertionError(f"{message}; fixture exited {rc}: {detail}")


def _wait_stderr_line(process: subprocess.Popen[bytes], expected: bytes, timeout: float) -> None:
    if process.stderr is None:
        raise AssertionError("fixture stderr unavailable")
    deadline = time.monotonic() + timeout
    pending = bytearray()
    observed = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stderr, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(max(remaining, 0)):
                raise AssertionError(
                    f"missing {expected!r}; stderr tail={observed[-4096:]!r}"
                )
            chunk = os.read(process.stderr.fileno(), 4096)
            if not chunk:
                raise AssertionError(
                    f"stderr closed before {expected!r}; tail={observed[-4096:]!r}"
                )
            pending.extend(chunk)
            observed.extend(chunk)
            while b"\n" in pending:
                line, _, rest = pending.partition(b"\n")
                pending = bytearray(rest)
                if line + b"\n" == expected:
                    return


class TauriFixtureTests(unittest.TestCase):
    def test_source_uses_locked_tauri_external_url_and_navigation_guard(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        cargo = CARGO.read_text(encoding="utf-8")
        lock = LOCK.read_text(encoding="utf-8")
        self.assertIn('tauri = { version = "=2.11.5"', cargo)
        self.assertIn('tauri-build = { version = "=2.6.3"', cargo)
        self.assertIn('name = "tauri"\nversion = "2.11.5"', lock)
        self.assertIn("KELD_BENCH_URL", source)
        self.assertIn('Some("127.0.0.1")', source)
        self.assertIn("WebviewUrl::External", source)
        self.assertIn(".on_navigation(", source)
        self.assertIn("KELD-BENCH-URL-BLOCKED", source)

    def test_build_recipe_is_commit_bound_and_locked(self) -> None:
        build = BUILD.read_text(encoding="utf-8")
        for required in (
            "diff --quiet HEAD",
            "cargo build --release --locked",
            "recipe_commit",
            "refusing to overwrite",
            "tauri_version",
            "webkit2gtk-4.1",
            "gtk+-3.0",
        ):
            self.assertIn(required, build)

    def test_binary_rejects_missing_and_non_loopback_url_before_gui(self) -> None:
        artifact = os.environ.get("TAURI_FIXTURE_ARTIFACT")
        if not artifact:
            self.skipTest("set TAURI_FIXTURE_ARTIFACT")
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
                timeout=5,
            )
            self.assertEqual(completed.returncode, 64, completed.stderr.decode())
            self.assertIn(b"KELD_BENCH_URL", completed.stderr)

    def test_off_origin_redirect_is_blocked(self) -> None:
        artifact = os.environ.get("TAURI_FIXTURE_ARTIFACT")
        if not artifact or os.environ.get("TAURI_FIXTURE_REAL") != "1":
            self.skipTest("set TAURI_FIXTURE_ARTIFACT and TAURI_FIXTURE_REAL=1")
        target = _RedirectServer(None)
        target_thread = _serve(target)
        target_port = int(target.server_address[1])
        origin = _RedirectServer(f"http://127.0.0.1:{target_port}/escaped")
        origin_thread = _serve(origin)
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
            _wait_signal(origin.observed.wait, process, 10, "Tauri did not request approved URL")
            _wait_stderr_line(process, b"KELD-BENCH-URL-BLOCKED\n", 10)
            self.assertFalse(target.observed.is_set(), "Tauri followed rejected redirect")
            self.assertIsNone(process.poll(), "Tauri exited after rejecting redirect")
        finally:
            owner.cleanup()
            if process.stderr:
                process.stderr.close()
            _stop(origin, origin_thread)
            _stop(target, target_thread)

    def test_real_display_emits_exact_beacon_and_reaps(self) -> None:
        artifact = os.environ.get("TAURI_FIXTURE_ARTIFACT")
        if not artifact or os.environ.get("TAURI_FIXTURE_REAL") != "1":
            self.skipTest("set TAURI_FIXTURE_ARTIFACT and TAURI_FIXTURE_REAL=1")
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
            _wait_signal(server.wait_for_beacon, process, 20, "Tauri paint beacon timed out")
            snapshot = server.snapshot()
            self.assertEqual(snapshot.page_requests, 1)
            self.assertEqual(snapshot.beacon_requests, 1)
            self.assertEqual(snapshot.rejections, ())
            self.assertIsNone(snapshot.protocol_error)
            self.assertIsNone(process.poll(), "Tauri window exited before cleanup")
        finally:
            owner.cleanup()
            server.close()
            if process.stderr:
                process.stderr.close()
        self.assertIsNotNone(process.returncode)


if __name__ == "__main__":
    unittest.main(verbosity=2)
