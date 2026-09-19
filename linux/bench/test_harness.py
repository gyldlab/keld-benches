#!/usr/bin/env python3
"""Negative controls for the Linux paint-opportunity oracle."""

from __future__ import annotations

import hashlib
import os
import pathlib
import random
import selectors
import signal
import subprocess
import sys
import tempfile
import shutil
import unittest
import urllib.parse
from unittest import mock

from harness import (
    BeaconServer,
    HarnessError,
    _canonical_tauri_artifact_sha256,
    _verify_tauri_trusted_build,
    KELD_DEV_BEACON_PATH,
    KELD_DEV_PROJECT_PATH,
    MemorySnapshot,
    MemoryStability,
    OwnedProcess,
    ProcessIdentity,
    ProductProcessRecord,
    ROOT,
    _prepare_product_workspace,
    _proc_identity,
    _product_atspi_bus_address,
    _product_backend_pair_preflight,
    _product_backend_scope,
    _product_dmabuf_scope,
    _product_memory_observation,
    _product_native_close,
    _product_process_class,
    _product_runtime_preflight,
    _product_wayland_close,
    _product_x11_dmabuf_pair_preflight,
    _publication_reasons,
    _paint_attempt,
    _verify_committed_file_digests,
    fixture_artifact_pairs,
    paired_ratio_comparison,
    paired_round_orders,
    render_payload,
    render_product_renderer,
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

    def test_fast_exit_is_reaped_and_retained_as_a_rejected_sample_reason(self) -> None:
        process = subprocess.Popen(
            [sys.executable, "-c", "raise SystemExit(7)"],
            start_new_session=True,
        )
        descriptor = os.pidfd_open(process.pid)
        selector = selectors.DefaultSelector()
        try:
            selector.register(descriptor, selectors.EVENT_READ)
            self.assertTrue(selector.select(2), "child must exit before ownership capture")
        finally:
            selector.close()
            os.close(descriptor)
        owner = OwnedProcess(process)
        self.assertEqual(owner.exit_code, 7)
        self.assertIsNone(owner.identity)
        self.assertEqual(process.returncode, 7)
        self.assertFalse(owner.cleanup())

    def test_fast_exit_becomes_an_invalid_sample_instead_of_aborting(self) -> None:
        sample = _paint_attempt(pathlib.Path("/usr/bin/false"), TEMPLATE, 1, 1)
        self.assertFalse(sample["valid"])
        self.assertEqual(sample["reject_reason"], "process_exited_1")
        self.assertIsNone(sample["value"])

    def test_fast_exit_cleanup_reaps_a_surviving_process_group_child(self) -> None:
        child_program = (
            "import signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
            "print('ready',flush=True); signal.pause()"
        )
        parent_program = (
            "import subprocess,sys; "
            f"child=subprocess.Popen([sys.executable,'-c',{child_program!r}],"
            "stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True); "
            "child.stdout.readline(); "
            "print(child.pid,flush=True); raise SystemExit(9)"
        )
        process = subprocess.Popen(
            [sys.executable, "-c", parent_program],
            start_new_session=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        assert process.stdout is not None
        child_pid = int(process.stdout.readline().strip())
        descriptor = os.pidfd_open(process.pid)
        selector = selectors.DefaultSelector()
        try:
            selector.register(descriptor, selectors.EVENT_READ)
            self.assertTrue(selector.select(2), "parent must exit before ownership capture")
        finally:
            selector.close()
            os.close(descriptor)
            process.stdout.close()
        owner = OwnedProcess(process)
        self.assertEqual(owner.exit_code, 9)
        self.assertTrue(owner.cleanup())
        self.assertIsNone(_proc_identity(child_pid))

    def test_generation_mismatch_blocks_group_signal(self) -> None:
        process = subprocess.Popen(
            [sys.executable, "-c", "import signal; signal.pause()"],
            start_new_session=True,
        )
        owner = OwnedProcess(process)
        self.assertIsNotNone(owner.identity)
        original = owner.identity
        assert original is not None
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

    def test_owned_process_exposes_generation_bound_members(self) -> None:
        process = subprocess.Popen(
            [sys.executable, "-c", "import signal; signal.pause()"],
            start_new_session=True,
        )
        owner = OwnedProcess(process)
        try:
            members = owner.members()
            self.assertEqual(len(members), 1)
            self.assertEqual(members[0].pid, process.pid)
            self.assertEqual(members[0].process_group, process.pid)
        finally:
            owner.cleanup()


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

    def test_paired_ratio_uses_registry_threshold(self) -> None:
        baseline = self.samples(100, 100, 100)
        candidate = self.samples(110, 110, 110)
        comparison = paired_ratio_comparison(baseline, candidate, threshold=1.15)
        self.assertEqual(comparison["baseline_arm"], "gtk4-native")
        self.assertEqual(comparison["candidate_arm"], "keld-linux-host")
        self.assertEqual(comparison["ratio_ci95"], {"lower": 1.1, "upper": 1.1})
        self.assertEqual(comparison["threshold"], 1.15)
        self.assertEqual(comparison["verdict"], "PASS")
        current = paired_ratio_comparison(baseline, candidate, threshold=1.05)
        self.assertEqual(current["verdict"], "FAIL")

    def test_paired_ratio_rejects_incomplete_or_duplicate_rounds(self) -> None:
        with self.assertRaisesRegex(HarnessError, "at least two valid matched rounds"):
            paired_ratio_comparison(self.samples(100), self.samples(90), threshold=1.05)
        duplicate = self.samples(100, 101)
        duplicate[1]["run"] = 1
        with self.assertRaisesRegex(HarnessError, "duplicate sample"):
            paired_ratio_comparison(duplicate, self.samples(90, 91), threshold=1.05)
        with self.assertRaisesRegex(HarnessError, "identical round membership"):
            paired_ratio_comparison(
                self.samples(100, 100), self.samples(90, 90, 90), threshold=1.05
            )
        invalid = self.samples(90, 90, 90)
        invalid[2]["valid"] = False
        invalid[2]["value"] = None
        invalid[2]["reject_reason"] = "timeout"
        with self.assertRaisesRegex(HarnessError, "every matched round to be valid"):
            paired_ratio_comparison(self.samples(100, 100, 100), invalid, threshold=1.05)
        with self.assertRaisesRegex(HarnessError, "greater than one"):
            paired_ratio_comparison(
                self.samples(100, 100), self.samples(90, 90), threshold="1.05"
            )


class PairingTests(unittest.TestCase):
    def test_artifact_file_provenance_is_bound_to_committed_bytes(self) -> None:
        path = "linux/keld/hello/index.html"
        digest = hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip()
        _verify_committed_file_digests(head, {path: digest}, {path}, "test")
        with self.assertRaisesRegex(HarnessError, "does not match committed bytes"):
            _verify_committed_file_digests(head, {path: "0" * 64}, {path}, "test")

    def test_artifact_ancestry_timeout_is_a_stable_harness_error(self) -> None:
        path = "linux/keld/hello/index.html"
        with mock.patch(
            "harness.subprocess.run",
            side_effect=subprocess.TimeoutExpired("git", 30),
        ):
            with self.assertRaisesRegex(HarnessError, "cannot verify commit ancestry"):
                _verify_committed_file_digests(
                    "0" * 40, {path: "0" * 64}, {path}, "test"
                )

    def test_artifact_provenance_rejects_non_mapping_file_set(self) -> None:
        path = "linux/keld/hello/index.html"
        with self.assertRaisesRegex(HarnessError, "incomplete committed file set"):
            _verify_committed_file_digests("0" * 40, None, {path}, "test")

    def test_fixture_artifact_mapping_rejects_mismatch_duplicate_and_unknown(self) -> None:
        with self.assertRaisesRegex(HarnessError, "one --artifact-dir per --fixture"):
            fixture_artifact_pairs(["linux/keld/hello"], ["a", "b"])
        with self.assertRaisesRegex(HarnessError, "duplicate Linux fixture"):
            fixture_artifact_pairs(
                ["linux/keld/hello", "linux/keld/hello"], ["a", "b"]
            )
        mapping = fixture_artifact_pairs(
            ["linux/keld/hello", "linux/tauri/hello"], ["a", "b"]
        )
        self.assertEqual(set(mapping), {"linux/keld/hello", "linux/tauri/hello"})
        self.assertEqual(
            fixture_artifact_pairs(["linux/keld/dev-hello"], ["product"]),
            {"linux/keld/dev-hello": (ROOT / "product").resolve()},
        )
        with self.assertRaisesRegex(HarnessError, "unsupported Linux fixture"):
            fixture_artifact_pairs(["linux/foreign/hello"], ["a"])

    def test_paired_round_schedule_is_balanced_inside_every_two_round_block(self) -> None:
        orders = paired_round_orders(
            ("keld-linux-host", "gtk4-native"), 6, random.Random(90)
        )
        self.assertEqual(len(orders), 6)
        self.assertTrue(all(set(order) == {"keld-linux-host", "gtk4-native"} for order in orders))
        for offset in range(0, 6, 2):
            self.assertNotEqual(orders[offset][0], orders[offset + 1][0])

    def test_paired_schedule_rejects_wrong_arm_or_sample_count(self) -> None:
        with self.assertRaisesRegex(HarnessError, "exactly two arms"):
            paired_round_orders(("keld-linux-host",), 2, random.Random(1))
        with self.assertRaisesRegex(HarnessError, "positive sample count"):
            paired_round_orders(("keld-linux-host", "gtk4-native"), 0, random.Random(1))


class TauriArtifactTrustTests(unittest.TestCase):
    def test_trusted_tauri_build_accepts_only_matching_canonical_digest(self) -> None:
        artifact = pathlib.Path("/tmp/fake-tauri-artifact")
        with mock.patch(
            "harness._canonical_tauri_artifact_sha256", return_value="a" * 64
        ), mock.patch(
            "harness._trusted_tauri_rebuild_sha256", return_value="a" * 64
        ):
            self.assertEqual(
                _verify_tauri_trusted_build("1" * 40, artifact),
                "a" * 64,
            )

        with mock.patch(
            "harness._canonical_tauri_artifact_sha256", return_value="a" * 64
        ), mock.patch(
            "harness._trusted_tauri_rebuild_sha256", return_value="b" * 64
        ):
            with self.assertRaisesRegex(
                HarnessError, "does not match an independent rebuild"
            ):
                _verify_tauri_trusted_build("1" * 40, artifact)

    def test_tauri_canonical_digest_rejects_non_elf_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact = pathlib.Path(temporary) / "tauri-linux-hello"
            artifact.write_bytes(b"not an ELF")
            with self.assertRaisesRegex(HarnessError, "could not inspect Tauri ELF"):
                _canonical_tauri_artifact_sha256(artifact)


class ProductRunnerTests(unittest.TestCase):
    @staticmethod
    def record(
        pid: int,
        parent_pid: int,
        command: str,
        *,
        comm: str = "process",
        process_group: int = 100,
        start_ticks: int | None = None,
    ) -> ProductProcessRecord:
        return ProductProcessRecord(
            identity=ProcessIdentity(
                pid=pid,
                process_group=process_group,
                start_ticks=start_ticks if start_ticks is not None else pid * 10,
            ),
            parent_pid=parent_pid,
            command=command,
            comm=comm,
        )

    def test_product_renderer_derivation_is_nonce_bound_and_non_mutating(self) -> None:
        stock = KELD_DEV_PROJECT_PATH.joinpath("index.html").read_bytes()
        beacon = KELD_DEV_BEACON_PATH.read_bytes()
        stock_before = bytes(stock)
        rendered = render_product_renderer(stock, beacon, 43123, NONCE)

        self.assertEqual(stock, stock_before)
        self.assertNotEqual(rendered, stock)
        self.assertNotIn(b"__KELD_BENCH_", rendered)
        self.assertIn(b"http://127.0.0.1:43123", rendered)
        self.assertGreaterEqual(rendered.count(NONCE.encode("ascii")), 2)
        self.assertIn(b"data-keld-bench-launch-theme", rendered)
        self.assertIn(b"background:#000!important", rendered)
        self.assertIn(b"color-scheme:dark", rendered)
        theme_at = rendered.index(b"data-keld-bench-launch-theme")
        head_close_at = rendered.index(b"</head>")
        body_open_at = rendered.index(b"<body>")
        visible_content_at = rendered.index(b"<h1>")
        self.assertLess(theme_at, head_close_at)
        self.assertLess(head_close_at, body_open_at)
        self.assertLess(theme_at, visible_content_at)
        self.assertEqual(rendered.count(b"</head>"), 1)
        self.assertEqual(rendered.count(b"</body>"), 1)

    def test_product_role_classification_keeps_cli_host_bun_and_engine_distinct(self) -> None:
        root = self.record(10, 1, "/bench/keld dev", comm="keld")
        host = self.record(20, 10, "/stage/keld-host", comm="keld-host")
        wrapper = self.record(30, 20, "/usr/bin/bwrap -- /runtime/launcher", comm="bwrap")
        bun = self.record(40, 30, "/runtime/program run /code/main.ts", comm="bun")
        web = self.record(
            50,
            20,
            "/usr/lib/webkit2gtk/WebKitWebProcess 4 50",
            comm="WebKitWebProcess",
        )

        self.assertEqual(_product_process_class(root, 10), "keld-cli")
        self.assertEqual(_product_process_class(host, 10), "keld-host")
        self.assertEqual(_product_process_class(wrapper, 10), "sandbox-wrapper")
        self.assertEqual(_product_process_class(bun, 10), "bun")
        self.assertEqual(_product_process_class(web, 10), "webkit-web")

    def test_product_memory_scores_host_not_cli_or_total_tree(self) -> None:
        records = (
            self.record(10, 1, "/bench/keld dev", comm="keld"),
            self.record(20, 10, "/stage/keld-host", comm="keld-host"),
            self.record(30, 20, "/runtime/program run /code/main.ts", comm="bun"),
            self.record(
                40,
                20,
                "/usr/lib/webkit2gtk/WebKitWebProcess",
                comm="WebKitWebProcess",
            ),
        )
        counters = {
            10: (100, 10),
            20: (200, 20),
            30: (300, 30),
            40: (400, 40),
        }

        with mock.patch("harness._product_process_records", return_value=records), mock.patch(
            "harness._product_memory_counters",
            side_effect=lambda identity: counters[identity.pid],
        ):
            observation = _product_memory_observation(records[0].identity)

        self.assertIsNotNone(observation)
        assert observation is not None
        self.assertEqual(observation.snapshot.main_rss_kib, 200)
        self.assertEqual(observation.cli_rss_kib, 100)
        self.assertEqual(observation.bun_rss_kib, 300)
        self.assertEqual(observation.keld_owned_rss_kib, 300)
        self.assertEqual(observation.snapshot.helper_rss_kib, 800)
        self.assertEqual(observation.snapshot.total_rss_kib, 1000)
        self.assertEqual(observation.snapshot.engine_processes, 1)
        self.assertEqual(
            observation.snapshot.process_classes,
            "bun:1,keld-cli:1,keld-host:1,webkit-web:1",
        )

    def test_product_workspace_is_owner_private_and_source_fixture_stays_immutable(self) -> None:
        stock_path = KELD_DEV_PROJECT_PATH / "index.html"
        stock_before = stock_path.read_bytes()
        renderer = render_product_renderer(
            stock_before,
            KELD_DEV_BEACON_PATH.read_bytes(),
            43123,
            NONCE,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            for name in ("keld", "keld-host", "keld-role-launcher"):
                path = artifacts / name
                path.write_bytes(name.encode("ascii"))
                path.chmod(0o755)
            home = root / "home"
            home.mkdir()
            workspace = _prepare_product_workspace(
                artifacts,
                renderer,
                home_root=home,
            )
            try:
                self.assertEqual(workspace.root.stat().st_mode & 0o777, 0o700)
                self.assertEqual(workspace.project.stat().st_mode & 0o777, 0o700)
                self.assertEqual((workspace.project / "index.html").read_bytes(), renderer)
                for name in ("keld", "keld-host", "keld-role-launcher"):
                    self.assertEqual(
                        (workspace.bin_dir / name).read_bytes(),
                        name.encode("ascii"),
                    )
                    self.assertTrue(os.access(workspace.bin_dir / name, os.X_OK))
            finally:
                shutil.rmtree(workspace.root, ignore_errors=True)
        self.assertEqual(stock_path.read_bytes(), stock_before)

    def test_product_backend_scope_isolates_and_restores_display_environment(self) -> None:
        original = {
            "GDK_BACKEND": "auto",
            "WAYLAND_DISPLAY": "wayland-9",
            "DISPLAY": ":77",
        }
        with mock.patch.dict(os.environ, original, clear=True):
            with _product_backend_scope(
                "wayland",
                wayland_display="wayland-9",
                x11_display=":77",
            ):
                self.assertEqual(os.environ["GDK_BACKEND"], "wayland")
                self.assertEqual(os.environ["WAYLAND_DISPLAY"], "wayland-9")
                self.assertNotIn("DISPLAY", os.environ)
            self.assertEqual({key: os.environ.get(key) for key in original}, original)

            with _product_backend_scope(
                "x11",
                wayland_display="wayland-9",
                x11_display=":77",
            ):
                self.assertEqual(os.environ["GDK_BACKEND"], "x11")
                self.assertEqual(os.environ["DISPLAY"], ":77")
                self.assertNotIn("WAYLAND_DISPLAY", os.environ)
            self.assertEqual({key: os.environ.get(key) for key in original}, original)

    def test_product_x11_dmabuf_scope_and_preflight_are_isolated(self) -> None:
        original = {
            "DISPLAY": ":99",
            "WAYLAND_DISPLAY": "wayland-9",
            "WEBKIT_DISABLE_DMABUF_RENDERER": "caller",
        }
        with mock.patch.dict(os.environ, original, clear=True):
            with _product_dmabuf_scope(False):
                self.assertNotIn("WEBKIT_DISABLE_DMABUF_RENDERER", os.environ)
            self.assertEqual(os.environ["WEBKIT_DISABLE_DMABUF_RENDERER"], "caller")
            with _product_dmabuf_scope(True):
                self.assertEqual(os.environ["WEBKIT_DISABLE_DMABUF_RENDERER"], "1")
            self.assertEqual(os.environ["WEBKIT_DISABLE_DMABUF_RENDERER"], "caller")

        seen: list[tuple[str | None, str | None, str | None, str | None]] = []

        def preflight() -> str:
            seen.append(
                (
                    os.environ.get("GDK_BACKEND"),
                    os.environ.get("WAYLAND_DISPLAY"),
                    os.environ.get("DISPLAY"),
                    os.environ.get("WEBKIT_DISABLE_DMABUF_RENDERER"),
                )
            )
            return "1.4.2+dmabuf"

        with mock.patch.dict(
            os.environ,
            {"DISPLAY": ":99", "WAYLAND_DISPLAY": "wayland-9"},
            clear=True,
        ), mock.patch(
            "harness.pathlib.Path.is_file", return_value=True
        ), mock.patch(
            "harness._product_runtime_preflight", side_effect=preflight
        ):
            self.assertEqual(
                _product_x11_dmabuf_pair_preflight(),
                ("1.4.2+dmabuf", ":99"),
            )
            self.assertEqual(
                seen,
                [
                    ("x11", None, ":99", None),
                    ("x11", None, ":99", "1"),
                ],
            )
            self.assertEqual(os.environ["DISPLAY"], ":99")
            self.assertEqual(os.environ["WAYLAND_DISPLAY"], "wayland-9")
            self.assertNotIn("GDK_BACKEND", os.environ)
            self.assertNotIn("WEBKIT_DISABLE_DMABUF_RENDERER", os.environ)

        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(HarnessError, "requires DISPLAY"):
                _product_x11_dmabuf_pair_preflight()

    def test_product_backend_pair_preflight_checks_both_isolated_arms(self) -> None:
        seen: list[tuple[str | None, str | None, str | None]] = []

        def preflight() -> str:
            seen.append(
                (
                    os.environ.get("GDK_BACKEND"),
                    os.environ.get("WAYLAND_DISPLAY"),
                    os.environ.get("DISPLAY"),
                )
            )
            return "1.4.2+paired"

        with mock.patch.dict(
            os.environ,
            {"WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":99"},
            clear=True,
        ), mock.patch("harness._product_runtime_preflight", side_effect=preflight):
            self.assertEqual(
                _product_backend_pair_preflight(),
                ("1.4.2+paired", "wayland-0", ":99"),
            )
            self.assertEqual(
                seen,
                [
                    ("wayland", "wayland-0", None),
                    ("x11", None, ":99"),
                ],
            )
            self.assertEqual(os.environ["WAYLAND_DISPLAY"], "wayland-0")
            self.assertEqual(os.environ["DISPLAY"], ":99")
            self.assertNotIn("GDK_BACKEND", os.environ)

        with mock.patch.dict(os.environ, {"DISPLAY": ":99"}, clear=True):
            with self.assertRaisesRegex(HarnessError, "requires both WAYLAND_DISPLAY and DISPLAY"):
                _product_backend_pair_preflight()

    def test_product_preflight_requires_explicit_backend_and_matching_display(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"GDK_BACKEND": "x11", "DISPLAY": ":99", "WAYLAND_DISPLAY": "wayland-0"},
            clear=True,
        ):
            with self.assertRaisesRegex(HarnessError, "WAYLAND_DISPLAY"):
                _product_runtime_preflight()

        with mock.patch.dict(
            os.environ,
            {
                "GDK_BACKEND": "wayland",
                "WAYLAND_DISPLAY": "wayland-0",
                "DISPLAY": ":99",
                "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
            },
            clear=True,
        ):
            with self.assertRaisesRegex(HarnessError, "DISPLAY to be unset"):
                _product_runtime_preflight()

        with mock.patch.dict(
            os.environ,
            {"GDK_BACKEND": "wayland", "WAYLAND_DISPLAY": "wayland-0"},
            clear=True,
        ):
            with self.assertRaisesRegex(HarnessError, "session D-Bus"):
                _product_runtime_preflight()

        with mock.patch.dict(os.environ, {"GDK_BACKEND": "broadway"}, clear=True):
            with self.assertRaisesRegex(HarnessError, "GDK_BACKEND=x11 or GDK_BACKEND=wayland"):
                _product_runtime_preflight()

        with mock.patch.dict(
            os.environ,
            {"GDK_BACKEND": "x11", "DISPLAY": ":99"},
            clear=True,
        ), mock.patch("harness.shutil.which", return_value="/usr/bin/tool"), mock.patch(
            "harness.run_text", return_value="1.4.2+test"
        ):
            self.assertEqual(_product_runtime_preflight(), "1.4.2+test")

        with mock.patch.dict(
            os.environ,
            {
                "GDK_BACKEND": "wayland",
                "WAYLAND_DISPLAY": "wayland-0",
                "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
            },
            clear=True,
        ), mock.patch("harness.shutil.which", return_value="/usr/bin/tool"), mock.patch(
            "harness._product_wayland_atspi_preflight"
        ) as atspi_preflight, mock.patch(
            "harness.run_text", return_value="1.4.2+test"
        ):
            self.assertEqual(_product_runtime_preflight(), "1.4.2+test")
            atspi_preflight.assert_called_once_with()

    def test_product_atspi_bus_address_is_fail_closed(self) -> None:
        good = subprocess.CompletedProcess(
            ["gdbus"],
            0,
            "('unix:path=/run/user/1000/at-spi/bus,guid=test',)\n",
            "",
        )
        with mock.patch("harness.subprocess.run", return_value=good):
            self.assertEqual(
                _product_atspi_bus_address(),
                "unix:path=/run/user/1000/at-spi/bus,guid=test",
            )

        bad = subprocess.CompletedProcess(
            ["gdbus"], 0, "('tcp:host=example',)\n", ""
        )
        with mock.patch("harness.subprocess.run", return_value=bad):
            self.assertIsNone(_product_atspi_bus_address())

        failed = subprocess.CompletedProcess(["gdbus"], 1, "", "no bus")
        with mock.patch("harness.subprocess.run", return_value=failed):
            self.assertIsNone(_product_atspi_bus_address())

    def test_product_wayland_close_binds_pid_title_and_bus(self) -> None:
        completed = subprocess.CompletedProcess(["python"], 0, b"", b"")
        with mock.patch(
            "harness._product_atspi_bus_address", return_value="unix:path=/tmp/atspi"
        ), mock.patch("harness.subprocess.run", return_value=completed) as run:
            self.assertEqual(
                _product_wayland_close(4242, "product-bench"),
                (True, None, None),
            )
        args, kwargs = run.call_args
        self.assertEqual(args[0][-2:], ["4242", "product-bench"])
        self.assertEqual(kwargs["env"]["AT_SPI_BUS_ADDRESS"], "unix:path=/tmp/atspi")
        self.assertEqual(kwargs["timeout"], 8)

        rejected = subprocess.CompletedProcess(["python"], 11, b"", b"")
        with mock.patch(
            "harness._product_atspi_bus_address", return_value="unix:path=/tmp/atspi"
        ), mock.patch("harness.subprocess.run", return_value=rejected):
            self.assertEqual(
                _product_wayland_close(4242, "product-bench"),
                (False, None, "wayland_atspi_close_rejected_11"),
            )

    def test_product_native_close_dispatches_exact_wayland_host(self) -> None:
        root = self.record(10, 1, "/bench/keld dev", comm="keld")
        host = self.record(20, 10, "/stage/keld-host", comm="keld-host")
        with mock.patch(
            "harness._product_process_records", return_value=(root, host)
        ), mock.patch.dict(os.environ, {"GDK_BACKEND": "wayland"}, clear=True), mock.patch(
            "harness._product_wayland_close", return_value=(True, None, None)
        ) as close:
            self.assertEqual(
                _product_native_close(root.identity, "product-bench"),
                (True, None, None),
            )
            close.assert_called_once_with(20, "product-bench")

    def test_product_publication_reasons_do_not_claim_hello_adapter(self) -> None:
        environment = {
            "power": {
                "ac_power": True,
                "low_power_mode": False,
                "thermal_state": "unverified",
            }
        }
        common = dict(
            metric_id="MEM-IDLE",
            requested_samples=30,
            valid_samples=30,
            tree_state="clean",
            advertised=True,
            environment=environment,
            recipe_commits=("a" * 40,),
            bench_sha="a" * 40,
            paired=False,
        )
        historical = {
            item["code"] for item in _publication_reasons(**common)
        }
        product = {
            item["code"]
            for item in _publication_reasons(**common, keld_mode="dev-product")
        }
        self.assertIn("DIAGNOSTIC_HELLO_ONLY", historical)
        self.assertIn("BENCHMARK_ADAPTER_ARTIFACT", historical)
        self.assertNotIn("DEVELOPER_FLOW_SCOPE", historical)
        self.assertIn("DEVELOPER_FLOW_SCOPE", product)
        self.assertNotIn("DIAGNOSTIC_HELLO_ONLY", product)
        self.assertNotIn("BENCHMARK_ADAPTER_ARTIFACT", product)



class MemoryStabilityTests(unittest.TestCase):
    @staticmethod
    def snapshot(
        *,
        generation: int = 20,
        engine_processes: int = 1,
        main_rss_kib: int = 10_000,
        total_rss_kib: int = 30_000,
    ) -> MemorySnapshot:
        return MemorySnapshot(
            membership=(
                (10, 10, "keld-host"),
                (20, generation, "webkit-web"),
            ),
            process_classes="keld-host:1,webkit-web:1",
            process_count=2,
            engine_processes=engine_processes,
            main_rss_kib=main_rss_kib,
            helper_rss_kib=total_rss_kib - main_rss_kib,
            total_rss_kib=total_rss_kib,
            main_private_dirty_kib=1_000,
            helper_private_dirty_kib=2_000,
            total_private_dirty_kib=3_000,
        )

    def test_four_identical_memberships_with_bounded_drift_are_stable(self) -> None:
        stability = MemoryStability()
        accepted = [
            stability.observe(
                self.snapshot(main_rss_kib=10_000 + offset, total_rss_kib=30_000 + offset)
            )
            for offset in (0, 10, 20, 30)
        ]
        self.assertEqual(accepted, [False, False, False, True])
        self.assertLessEqual(stability.drift_percent(), 1.0)

    def test_missing_engine_floor_never_stabilizes(self) -> None:
        stability = MemoryStability()
        for _ in range(6):
            self.assertFalse(stability.observe(self.snapshot(engine_processes=0)))
        self.assertEqual(stability.last_reject_reason, "engine_process_floor_missing")

    def test_generation_churn_resets_the_stability_window(self) -> None:
        stability = MemoryStability()
        for _ in range(3):
            self.assertFalse(stability.observe(self.snapshot()))
        self.assertFalse(stability.observe(self.snapshot(generation=21)))
        self.assertEqual(stability.last_reject_reason, "membership_churn")
        self.assertEqual(len(stability.history), 1)

    def test_rss_drift_resets_the_stability_window(self) -> None:
        stability = MemoryStability()
        for _ in range(3):
            self.assertFalse(stability.observe(self.snapshot()))
        self.assertFalse(
            stability.observe(self.snapshot(main_rss_kib=11_000, total_rss_kib=33_000))
        )
        self.assertEqual(stability.last_reject_reason, "rss_drift_exceeded")
        self.assertEqual(len(stability.history), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
