#!/usr/bin/env python3
"""Negative controls for the Linux paint-opportunity oracle."""

from __future__ import annotations

import signal
import subprocess
import sys
import unittest
import urllib.parse
from unittest import mock

from harness import (
    BeaconServer,
    HarnessError,
    OwnedProcess,
    ProcessIdentity,
    ROOT,
    _proc_identity,
    render_payload,
    request,
    summarize,
)


TEMPLATE = (ROOT / "linux" / "keld" / "hello" / "index.html").read_bytes()
NONCE = "0123456789abcdef0123456789abcdef"


class PayloadTests(unittest.TestCase):
    def test_template_parameterizes_port_and_nonce(self) -> None:
        rendered = render_payload(TEMPLATE, 43123, NONCE)
        self.assertNotIn(b"__KELD_BENCH_", rendered)
        self.assertIn(b"http://127.0.0.1:43123", rendered)
        self.assertGreaterEqual(rendered.count(NONCE.encode("ascii")), 2)
        self.assertIn(b'requestAnimationFrame(() => {\n        requestAnimationFrame(', rendered)


class BeaconTests(unittest.TestCase):
    def setUp(self) -> None:
        self.server = BeaconServer(TEMPLATE, NONCE)
        self.server.start()

    def tearDown(self) -> None:
        self.server.close()

    def beacon_path(self, **changes: str) -> str:
        query = {
            "nonce": NONCE,
            "phase": "double-raf",
            "visibility": "visible",
            "focus": "1",
        }
        query.update(changes)
        return f"/run/{NONCE}/paint.gif?{urllib.parse.urlencode(query)}"

    def test_valid_page_and_beacon_are_accepted_once(self) -> None:
        self.assertEqual(request(self.server, f"/run/{NONCE}/index.html"), 200)
        self.assertEqual(request(self.server, self.beacon_path()), 200)
        self.assertTrue(self.server.wait_for_beacon(0.1))
        snapshot = self.server.snapshot()
        self.assertEqual(snapshot.page_requests, 1)
        self.assertEqual(snapshot.beacon_requests, 1)
        self.assertIsNotNone(snapshot.accepted_ns)

    def test_stale_nonce_is_rejected(self) -> None:
        stale = "f" * 32
        path = f"/run/{stale}/paint.gif?" + urllib.parse.urlencode(
            {
                "nonce": stale,
                "phase": "double-raf",
                "visibility": "visible",
                "focus": "1",
            }
        )
        self.assertEqual(request(self.server, path), 404)
        self.assertFalse(self.server.wait_for_beacon(0.01))
        self.assertIn("path_nonce_mismatch", self.server.snapshot().rejections)

    def test_single_raf_claim_is_rejected(self) -> None:
        self.assertEqual(request(self.server, self.beacon_path(phase="single-raf")), 422)
        self.assertFalse(self.server.wait_for_beacon(0.01))
        self.assertIn("wrong_phase", self.server.snapshot().rejections)

    def test_malformed_query_is_rejected(self) -> None:
        self.assertEqual(request(self.server, f"/run/{NONCE}/paint.gif?not-a-pair"), 400)
        self.assertFalse(self.server.wait_for_beacon(0.01))
        self.assertIn("malformed_query", self.server.snapshot().rejections)

    def test_hidden_or_unfocused_document_is_rejected(self) -> None:
        self.assertEqual(request(self.server, self.beacon_path(visibility="hidden")), 422)
        self.assertEqual(request(self.server, self.beacon_path(focus="0")), 422)
        self.assertFalse(self.server.wait_for_beacon(0.01))
        self.assertEqual(
            self.server.snapshot().rejections,
            ("document_not_visible", "document_not_focused"),
        )

    def test_duplicate_beacon_marks_protocol_error(self) -> None:
        self.assertEqual(request(self.server, self.beacon_path()), 200)
        self.assertEqual(request(self.server, self.beacon_path()), 409)
        self.assertEqual(self.server.snapshot().protocol_error, "duplicate_beacon")

    def test_silent_arm_times_out_without_a_value(self) -> None:
        self.assertFalse(self.server.wait_for_beacon(0.01))
        self.assertIsNone(self.server.snapshot().accepted_ns)


class ProcessOwnershipTests(unittest.TestCase):
    def test_transient_truncated_proc_stat_is_unavailable(self) -> None:
        with mock.patch("pathlib.Path.read_text", return_value="123 (exiting) Z"):
            self.assertIsNone(_proc_identity(123))

    def test_generation_mismatch_blocks_group_signal(self) -> None:
        process = subprocess.Popen(
            [sys.executable, "-c", "import signal; signal.pause()"],
            start_new_session=True,
        )
        owner = OwnedProcess(process)
        original = owner.identity
        try:
            owner.identity = ProcessIdentity(
                pid=original.pid,
                process_group=original.process_group,
                start_ticks=original.start_ticks + 1,
            )
            with self.assertRaisesRegex(HarnessError, "PID was reused"):
                owner._signal_group(signal.SIGTERM)
        finally:
            owner.identity = original
            owner.cleanup()
        self.assertIsNotNone(process.returncode)

    def test_cleanup_terminates_owned_descendant_group(self) -> None:
        program = (
            "import signal,subprocess,sys; "
            "child_program=\"import signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
            "print('ready',flush=True); signal.pause()\"; "
            "child=subprocess.Popen([sys.executable,'-c',child_program],"
            "stdout=subprocess.PIPE,text=True); "
            "child.stdout.readline(); "
            "print(child.pid,flush=True); signal.pause()"
        )
        process = subprocess.Popen(
            [sys.executable, "-c", program],
            start_new_session=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        owner = OwnedProcess(process)
        assert process.stdout is not None
        try:
            child_pid = int(process.stdout.readline().strip())
            self.assertIsNotNone(_proc_identity(child_pid))
            owner.cleanup()
        finally:
            process.stdout.close()
        self.assertIsNotNone(process.returncode)
        self.assertIsNone(_proc_identity(child_pid))


class StatisticsTests(unittest.TestCase):
    @staticmethod
    def samples(*values: float) -> list[dict[str, object]]:
        return [
            {"run": index, "value": value, "valid": True, "reject_reason": None}
            for index, value in enumerate(values, start=1)
        ]

    def test_single_deterministic_value_is_not_padded_with_a_bootstrap_ci(self) -> None:
        summary = summarize(self.samples(478_208))
        self.assertEqual(summary["valid_samples"], 1)
        self.assertEqual(summary["median"], 478_208)
        self.assertIsInstance(summary["median"], int)
        self.assertNotIn("bootstrap_ci95", summary)

    def test_observations_use_nearest_rank_and_bootstrap_median(self) -> None:
        summary = summarize(self.samples(4, 1, 3, 2))
        self.assertEqual(summary["median"], 2.5)
        self.assertEqual(summary["p90"], 4)
        self.assertEqual(summary["bootstrap_ci95"]["resamples"], 10_000)
        self.assertLessEqual(summary["bootstrap_ci95"]["lower"], 2.5)
        self.assertGreaterEqual(summary["bootstrap_ci95"]["upper"], 2.5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
