#!/usr/bin/env python3
"""Static and optional real-display controls for the KEL-171 fixture."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


FIXTURE = Path(__file__).resolve().parent
SOURCE = FIXTURE / "probe.c"
AUDIT = FIXTURE / "audit.c"
BUILD = FIXTURE / "build.sh"
RUNNER = FIXTURE / "run_matrix.py"
sys.path.insert(0, str(FIXTURE))

import run_matrix as matrix  # noqa: E402


class FixtureTests(unittest.TestCase):
    def test_source_uses_webkit_snapshot_and_double_raf_oracle(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        for required in (
            "webkit_web_view_get_snapshot(",
            "webkit_web_view_get_snapshot_finish(",
            "WEBKIT_SNAPSHOT_OPTIONS_TRANSPARENT_BACKGROUND",
            "requestAnimationFrame(()=>requestAnimationFrame(",
            "gdk_display_get_default()",
            "G_OBJECT_TYPE_NAME(display)",
            "WEBKIT_DISABLE_DMABUF_RENDERER",
        ):
            self.assertIn(required, source)
        self.assertNotIn("sleep(", source)

    def test_build_binds_committed_recipe_and_native_lane(self) -> None:
        build = BUILD.read_text(encoding="utf-8")
        self.assertIn("diff --quiet HEAD", build)
        self.assertIn("cat-file -e", build)
        self.assertIn("pkg-config --cflags-only-I gtk+-3.0 webkit2gtk-4.1", build)
        self.assertIn("-Wall -Wextra -Werror -Wpedantic", build)
        self.assertIn("refusing to overwrite", build)

    def test_runner_records_every_decision_bearing_atom(self) -> None:
        runner = RUNNER.read_text(encoding="utf-8")
        for required in (
            '"census"',
            '"rows"',
            '"negative_control"',
            '"signal"',
            '"png_sha256"',
            '"gdk_display_type"',
            '"disable_dmabuf_renderer"',
        ):
            self.assertIn(required, runner)

    def test_real_probe_and_compositor_fault_preserves_internal_alpha(self) -> None:
        artifact = os.environ.get("KEL171_FIXTURE_ARTIFACT")
        if not artifact:
            self.skipTest("set KEL171_FIXTURE_ARTIFACT to exercise the built probe")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            good = root / "good.png"
            environment = {
                **os.environ,
                "KEL171_NONCE": "ab" * 16,
                "GDK_BACKEND": "x11",
                "GTK_A11Y": "none",
            }
            completed = subprocess.run(
                [artifact, "--style", "opaque", "--output", str(good)],
                env=environment,
                check=False,
                input="R",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=20,
            )
            receipt = json.loads(completed.stdout)
            self.assertTrue(receipt["oracle_pass"])
            self.assertEqual(receipt["gdk_display_type"], "GdkX11Display")
            self.assertTrue(good.is_file())
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(matrix.decode_png_oracle(good, "opaque")["oracle_pass"])

            bad = root / "bad.png"
            faulted = subprocess.run(
                [artifact, "--style", "transparent", "--output", str(bad)],
                env={**environment, "KEL171_FAULT_BLACK_COMPOSITOR": "1"},
                check=False,
                input="R",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=20,
            )
            self.assertEqual(faulted.returncode, 0, faulted.stderr)
            faulted_receipt = json.loads(faulted.stdout)
            self.assertTrue(faulted_receipt["oracle_pass"])
            self.assertTrue(faulted_receipt["fault_black_compositor"])
            self.assertEqual(faulted_receipt["surface"]["background_argb"], "00000000")

    def test_real_probe_rejects_non_hex_nonce_before_gtk(self) -> None:
        artifact = os.environ.get("KEL171_FIXTURE_ARTIFACT")
        if not artifact:
            self.skipTest("set KEL171_FIXTURE_ARTIFACT to exercise the built probe")
        completed = subprocess.run(
            [artifact, "--style", "opaque", "--output", "/tmp/not-created.png"],
            env={**os.environ, "KEL171_NONCE": "z" * 32},
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
        self.assertEqual(completed.returncode, 64)
        self.assertIn("usage:", completed.stderr)

    def test_audit_library_records_live_webkit_process(self) -> None:
        artifact = os.environ.get("KEL171_FIXTURE_ARTIFACT")
        audit = os.environ.get("KEL171_AUDIT_LIBRARY")
        if not artifact or not audit:
            self.skipTest("set KEL171_FIXTURE_ARTIFACT and KEL171_AUDIT_LIBRARY")
        with tempfile.TemporaryDirectory() as temporary:
            receipt = Path(temporary) / "audit.receipt"
            completed = subprocess.run(
                [artifact, "--style", "opaque", "--output", str(Path(temporary) / "probe.png")],
                env={
                    **os.environ,
                    "GDK_BACKEND": "x11",
                    "KEL171_NONCE": "cd" * 16,
                    "KEL171_TEST_AUDIT": "1",
                    "KEL171_KELD_RECEIPT": str(receipt),
                    "LD_PRELOAD": audit,
                },
                check=False,
                input="R",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=20,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            audit_receipt, error = matrix.read_keld_audit(receipt)
            self.assertIsNone(error)
            self.assertIsNotNone(audit_receipt)
            assert audit_receipt is not None
            self.assertTrue(audit_receipt["pid"].isdigit())
            self.assertEqual(audit_receipt["uri"], "https://keld.invalid/audit")
            self.assertEqual(audit_receipt["gdk_display_type"], "GdkX11Display")

    def test_timeout_is_terminal(self) -> None:
        artifact = os.environ.get("KEL171_FIXTURE_ARTIFACT")
        if not artifact:
            self.skipTest("set KEL171_FIXTURE_ARTIFACT to exercise the built probe")
        with tempfile.TemporaryDirectory() as temporary:
            completed = subprocess.run(
                [
                    artifact,
                    "--style",
                    "opaque",
                    "--output",
                    str(Path(temporary) / "must-not-pass.png"),
                ],
                env={
                    **os.environ,
                    "GDK_BACKEND": "x11",
                    "KEL171_NONCE": "ef" * 16,
                    "KEL171_TEST_SUPPRESS_READY": "1",
                    "KEL171_TEST_SHORT_TIMEOUT": "1",
                },
                check=False,
                input="R",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
            )
            self.assertEqual(completed.returncode, 124, completed.stderr)
            self.assertEqual(completed.stdout, "")
            self.assertIn("KEL171-TIMEOUT", completed.stderr)


class RunnerContractTests(unittest.TestCase):
    def test_schedule_never_drops_paired_or_later_cells(self) -> None:
        schedule = matrix.matrix_schedule(matrix.BACKENDS, 2, 171)
        self.assertEqual(len(schedule), 16)
        self.assertEqual(
            {
                (backend, style, mitigation, repetition)
                for backend, style, mitigation, repetition in schedule
            },
            {
                (backend, style, mitigation, repetition)
                for backend in matrix.BACKENDS
                for style in matrix.STYLES
                for mitigation in matrix.MITIGATIONS
                for repetition in (1, 2)
            },
        )

    def test_completion_distinguishes_partial_diagnostic_and_invalid_row(self) -> None:
        rows = [
            {
                "backend": "x11",
                "style": style,
                "mitigation": mitigation,
                "repetition": 1,
                "valid": True,
            }
            for style in matrix.STYLES
            for mitigation in matrix.MITIGATIONS
        ]
        self.assertEqual(
            matrix.matrix_completion(rows, ("x11",), 1, True, []),
            (True, False, 4),
        )
        rows[2]["valid"] = False
        self.assertEqual(
            matrix.matrix_completion(rows, ("x11",), 1, True, []),
            (False, False, 4),
        )
        rows.append({**rows[2], "valid": True, "attempt": 2})
        self.assertEqual(
            matrix.matrix_completion(rows, ("x11",), 1, True, []),
            (True, False, 4),
        )

    def test_renderer_override_is_an_explicit_rejection(self) -> None:
        self.assertEqual(
            matrix.renderer_override_errors({"LIBGL_ALWAYS_SOFTWARE": "1"}),
            ["LIBGL_ALWAYS_SOFTWARE"],
        )
        self.assertEqual(matrix.renderer_override_errors({}), [])

    def test_only_acquisition_and_focus_failures_are_retryable(self) -> None:
        self.assertTrue(
            matrix.retryable_native_acquisition(
                {
                    "reject_reasons": ["compositor_oracle_failed"],
                    "compositor_oracle": {
                        "error": "unique magenta window marker not found"
                    },
                    "compositor_capture": {"valid": True},
                }
            )
        )
        self.assertFalse(
            matrix.retryable_native_acquisition(
                {
                    "reject_reasons": ["png_oracle_failed"],
                    "compositor_oracle": {"oracle_pass": True},
                    "compositor_capture": {"valid": True},
                }
            )
        )
        self.assertTrue(
            matrix.retryable_keld_focus(
                {
                    "reject_reasons": [
                        "beacon_not_accepted",
                        "document_not_focused",
                    ]
                }
            )
        )
        self.assertFalse(
            matrix.retryable_keld_focus(
                {"reject_reasons": ["keld_backend_mismatch"]}
            )
        )

    def test_census_failure_blocks_completion(self) -> None:
        census = {
            "environment": {"WAYLAND_DISPLAY": "wayland-0"},
            "commands": [],
        }
        errors = matrix.validate_census(census)
        self.assertIn("missing_nvidia-smi", errors)
        rows = [{"valid": True} for _ in range(4)]
        self.assertEqual(
            matrix.matrix_completion(rows, ("x11",), 1, True, errors)[0], False
        )

    def test_strict_artifact_provenance_rejects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "kel171-webkitgtk-probe"
            artifact.write_bytes(b"verified fixture")
            audit = Path(temporary) / "kel171-webkitgtk-audit.so"
            audit.write_bytes(b"verified audit")
            provenance = {
                "schema_version": 1,
                "fixture_repository": "github.com/gyldlab/keld-benches",
                "fixture_commit": "a" * 40,
                "fixture_files": {
                    "linux/webkitgtk/dmabuf-matrix/audit.c": matrix.sha256(AUDIT),
                    "linux/webkitgtk/dmabuf-matrix/build.sh": matrix.sha256(BUILD),
                    "linux/webkitgtk/dmabuf-matrix/probe.c": matrix.sha256(SOURCE),
                },
                "artifact": {
                    "basename": artifact.name,
                    "sha256": matrix.sha256(artifact),
                    "bytes": artifact.stat().st_size,
                },
                "audit": {
                    "basename": audit.name,
                    "sha256": matrix.sha256(audit),
                    "bytes": audit.stat().st_size,
                },
                "toolchains": {
                    "cc": "cc test",
                    "gtk+-3.0": "3.test",
                    "webkit2gtk-4.1": "2.test",
                },
            }
            self.assertEqual(
                matrix.validate_artifact_provenance(
                    provenance, artifact, matrix.sha256(artifact)
                ),
                "a" * 40,
            )
            provenance["artifact"]["bytes"] = artifact.stat().st_size + 1
            with self.assertRaisesRegex(ValueError, "does not match"):
                matrix.validate_artifact_provenance(
                    provenance, artifact, matrix.sha256(artifact)
                )

    def test_run_row_rejects_wrong_backend_and_cleans_timeout_group(self) -> None:
        fake_source = """#!/usr/bin/python3
import json, os, signal, subprocess, sys
from pathlib import Path
if os.environ.get('FAKE_TIMEOUT') == '1':
    child = subprocess.Popen([sys.executable, '-c', 'import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.pause()'])
    Path(os.environ['FAKE_CHILD_PID']).write_text(str(child.pid), encoding='ascii')
    signal.pause()
style = sys.argv[2]
Path(sys.argv[4]).write_bytes(b'fake-png')
backend = 'GdkWaylandDisplay' if os.environ.get('GDK_BACKEND') == 'wayland' else 'GdkX11Display'
if os.environ.get('FAKE_WRONG_BACKEND') == '1':
    backend = 'GdkWaylandDisplay' if backend == 'GdkX11Display' else 'GdkX11Display'
background = 'ff203040' if style == 'opaque' else '00000000'
print(json.dumps({'schema_version':1,'nonce':os.environ['KEL171_NONCE'],'style':style,'gdk_display_type':backend,'gdk_display_name':'test','gtk_runtime':'3.24.0','gtk_headers':'3.24.0','webkit_runtime':'2.52.0','webkit_headers':'2.52.0','disable_dmabuf_renderer':os.environ.get('WEBKIT_DISABLE_DMABUF_RENDERER'),'fault_black_compositor':os.environ.get('KEL171_FAULT_BLACK_COMPOSITOR') == '1','surface':{'type':0,'format':0,'width':320,'height':240,'marker_argb':'ffff00aa','background_argb':background},'oracle_pass':True,'png_status':0}), flush=True)
sys.stdin.buffer.read(1)
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake = root / "fake-probe"
            fake.write_text(fake_source, encoding="utf-8")
            fake.chmod(0o700)

            def capture(path: Path) -> dict[str, object]:
                path.write_bytes(b"frame")
                return {"valid": True}

            def compositor(_full: Path, crop: Path, style: str) -> dict[str, object]:
                crop.write_bytes(b"crop")
                return {"oracle_pass": True, "sample_rgba": (32, 48, 64, 255)}

            gpu = [{"graphics_devices": [{"nvidia": True}]}]
            with (
                mock.patch.object(matrix, "capture_mutter_compositor", side_effect=capture),
                mock.patch.object(matrix, "compositor_oracle", side_effect=compositor),
                mock.patch.object(matrix, "decode_png_oracle", return_value={"oracle_pass": True}),
                mock.patch.object(matrix, "process_gpu_receipts", return_value=gpu),
                mock.patch.dict(os.environ, {"FAKE_WRONG_BACKEND": "1"}),
            ):
                wrong = matrix.run_row(fake, root, "x11", "opaque", "off", 1)
            self.assertFalse(wrong["valid"])
            self.assertIn("backend_mismatch", wrong["reject_reasons"])
            self.assertIsNone(wrong["cleanup_error"])

            child_pid_file = root / "child.pid"
            with mock.patch.dict(
                os.environ,
                {"FAKE_TIMEOUT": "1", "FAKE_CHILD_PID": str(child_pid_file)},
            ):
                timed_out = matrix.run_row(
                    fake,
                    root,
                    "x11",
                    "opaque",
                    "on",
                    2,
                    receipt_timeout_seconds=0.2,
                    exit_timeout_seconds=0.1,
                )
            self.assertFalse(timed_out["valid"])
            self.assertIn("timeout", timed_out["reject_reasons"])
            self.assertGreaterEqual(len(timed_out["post_exit_process_group"]), 2)
            self.assertIsNone(timed_out["cleanup_error"])


if __name__ == "__main__":
    unittest.main()
