#!/usr/bin/env python3
"""Contract and negative tests for the routed CI planner."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

import plan  # noqa: E402


ALL = {
    "contract": True,
    "linux_unit": True,
    "linux_gtk": True,
    "windows": True,
    "macos": True,
}
NONE = {route: False for route in plan.ROUTES}


class RouteTests(unittest.TestCase):
    def assert_routes(self, paths: list[str], *expected: str) -> None:
        changes = [plan.Change("M", path) for path in paths]
        actual = plan.plan_changes(changes)
        wanted = {route: route in expected for route in plan.ROUTES}
        self.assertEqual(actual, wanted)

    def test_contract_exact_routes(self) -> None:
        for path in (
            "schema/result.v2.schema.json",
            "windows/bench/validate_result_v1.py",
            "windows/bench/test_validate_result_v1.py",
        ):
            with self.subTest(path=path):
                self.assert_routes([path], "contract")

    def test_linux_unit_exact_routes(self) -> None:
        for path in (
            "linux/bench/run.py",
            "linux/bench/test_harness.py",
            "linux/keld/hello/build.sh",
            "linux/keld/hello/keld-bench-url.patch",
        ):
            with self.subTest(path=path):
                self.assert_routes([path], "linux_unit")

    def test_linux_shared_files_route_both_leaves(self) -> None:
        for path in ("linux/bench/harness.py", "linux/keld/hello/index.html"):
            with self.subTest(path=path):
                self.assert_routes([path], "linux_unit", "linux_gtk")

    def test_metrics_schema_routes_contract_and_linux_unit(self) -> None:
        self.assert_routes(
            ["schema/metrics.v1.json"], "contract", "linux_unit"
        )

    def test_linux_gtk_exact_routes(self) -> None:
        for path in (
            "linux/gtk4/hello/build.sh",
            "linux/gtk4/hello/main.c",
            "linux/gtk4/hello/test_fixture.py",
        ):
            with self.subTest(path=path):
                self.assert_routes([path], "linux_gtk")

    def test_windows_exact_routes(self) -> None:
        for path in (
            "windows/bench/Test-Harness.ps1",
            "windows/bench/extract_tauri_payload.py",
            "windows/bench/hello.template.html",
            "MEASUREMENTS.md",
        ):
            with self.subTest(path=path):
                self.assert_routes([path], "windows")

    def test_macos_only_swift_fixture_trees(self) -> None:
        for path in (
            "macos/swift/appkit-wk/HelloAppKit.swift",
            "macos/swift/swiftui-wk/Info.plist",
        ):
            with self.subTest(path=path):
                self.assert_routes([path], "macos")
        self.assertEqual(
            plan.plan_changes([plan.Change("M", "macos/keld/hello/index.html")]),
            ALL,
        )

    def test_multiple_known_paths_union_routes(self) -> None:
        self.assert_routes(
            [
                "windows/bench/Statistics.ps1",
                "macos/swift/appkit-wk/Info.plist",
            ],
            "windows",
            "macos",
        )

    def test_prose_docs_only_routes_none(self) -> None:
        self.assertEqual(
            plan.plan_changes(
                [
                    plan.Change("M", "README.md"),
                    plan.Change("A", "docs/design notes\nwith newline.md"),
                ]
            ),
            NONE,
        )

    def test_unknown_non_doc_path_forces_all(self) -> None:
        self.assertEqual(
            plan.plan_changes([plan.Change("M", "linux/new-runner.py")]), ALL
        )

    def test_infrastructure_paths_force_all(self) -> None:
        for path in (
            "AGENTS.md",
            "HARNESS-CONTRACT.md",
            "linux/AGENTS.md",
            ".github/dependabot.yml",
            ".github/workflows/ci.yml",
            "ci/plan.py",
            "ci/requirements-contract.txt",
            "ci/requirements-plan.txt",
            ".gitignore",
            ".gitattributes",
            ".gitleaksignore",
        ):
            with self.subTest(path=path):
                self.assertEqual(plan.plan_changes([plan.Change("M", path)]), ALL)

    def test_new_result_addition_routes_contract(self) -> None:
        self.assertEqual(
            plan.plan_changes(
                [plan.Change("A", "linux/bench/results/run\n01.json")]
            ),
            {**NONE, "contract": True},
        )

    def test_existing_result_modification_deletion_and_type_change_are_rejected(self) -> None:
        for path in (
            "windows/bench/results/run.json",
            "windows/bench/windows-first-paint.json",
        ):
            for status in ("M", "D", "T"):
                with self.subTest(path=path, status=status):
                    with self.assertRaises(plan.PlanError):
                        plan.plan_changes([plan.Change(status, path)])

    def test_every_legacy_windows_evidence_source_is_immutable(self) -> None:
        for path in plan.LEGACY_WINDOWS_EVIDENCE:
            with self.subTest(path=path):
                with self.assertRaises(plan.PlanError):
                    plan.plan_changes([plan.Change("M", path)])

    def test_zero_or_unresolvable_comparison_fails_safe_all(self) -> None:
        self.assertEqual(plan.plan_changes(None), ALL)


class ParserTests(unittest.TestCase):
    def test_nul_parser_preserves_adversarial_filenames(self) -> None:
        raw = b"M\0docs/line\nbreak.md\0A\0schema/tab\tname.json\0"
        self.assertEqual(
            plan.parse_name_status_z(raw),
            [
                plan.Change("M", "docs/line\nbreak.md"),
                plan.Change("A", "schema/tab\tname.json"),
            ],
        )

    def test_malformed_records_are_rejected(self) -> None:
        for raw in (b"M\0path", b"M\0", b"\0path\0"):
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError):
                    plan.parse_name_status_z(raw)


class CliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary_directory.name)
        self._git("init", "-q")
        self._git("config", "user.name", "CI Planner Test")
        self._git("config", "user.email", "ci-planner@example.invalid")
        self._write("README.md", b"base\n")
        self._git("add", "--", "README.md")
        self._git("commit", "-qm", "base")
        self.base = self._git("rev-parse", "HEAD").stdout.strip()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args],
            cwd=self.repo,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def _write(self, relative: str, contents: bytes) -> None:
        destination = self.repo / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(contents)

    def _commit(self, relative: str, contents: bytes) -> str:
        self._write(relative, contents)
        self._git("add", "--", relative)
        self._git("commit", "-qm", "change")
        return self._git("rev-parse", "HEAD").stdout.strip()

    def _run(self, base: str, head: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(Path(plan.__file__).resolve()),
                "--base",
                base,
                "--head",
                head,
                "--repo",
                str(self.repo),
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={key: value for key, value in os.environ.items() if key != "GITHUB_OUTPUT"},
        )

    def test_cli_output_contract_and_nul_safe_diff(self) -> None:
        adversarial = "linux/keld/hello/line\nname.md"
        head = self._commit(adversarial, b"docs\n")
        result = self._run(self.base, head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "planner_tests=true\n"
            "contract=false\n"
            "linux_unit=false\n"
            "linux_gtk=false\n"
            "windows=false\n"
            "macos=false\n",
        )

    def test_cli_appends_the_same_contract_to_github_output(self) -> None:
        output = self.repo / "github-output"
        output.write_text("existing=value\n", encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(Path(plan.__file__).resolve()),
                "--base",
                self.base,
                "--head",
                "HEAD",
                "--repo",
                str(self.repo),
                "--output",
                str(output),
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            output.read_text(encoding="utf-8"),
            "existing=value\n" + plan.output_values(NONE),
        )

    def test_unresolvable_and_zero_base_emit_all_routes(self) -> None:
        head = self._git("rev-parse", "HEAD").stdout.strip()
        for base in ("not-a-revision", "0" * 40):
            with self.subTest(base=base):
                result = self._run(base, head)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.stdout,
                    plan.output_values(ALL),
                )

    def test_existing_result_change_exits_nonzero_without_outputs(self) -> None:
        result_path = "windows/bench/results/published.json"
        first = self._commit(result_path, b"{}\n")
        second = self._commit(result_path, b'{"changed": true}\n')
        result = self._run(first, second)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("must not be modified or deleted", result.stderr)


if __name__ == "__main__":
    unittest.main()
