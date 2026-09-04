#!/usr/bin/env python3
"""Negative controls for the stable required-check aggregator."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from required import ROUTES, evidence_problems  # noqa: E402


def environment(*, requested: str = "true", result: str = "success") -> dict[str, str]:
    values = {"PLAN_RESULT": "success", "SECRETS_RESULT": "success"}
    for requested_name, result_name in ROUTES.values():
        values[requested_name] = requested
        values[result_name] = result
    return values


class RequiredEvidenceTests(unittest.TestCase):
    def test_every_selected_route_succeeds(self) -> None:
        self.assertEqual(evidence_problems(environment()), [])

    def test_every_unselected_route_is_skipped(self) -> None:
        self.assertEqual(
            evidence_problems(environment(requested="false", result="skipped")), []
        )

    def test_plan_and_unconditional_secret_scan_must_succeed(self) -> None:
        for name in ("PLAN_RESULT", "SECRETS_RESULT"):
            for result in ("", "failure", "cancelled", "skipped"):
                with self.subTest(name=name, result=result):
                    values = environment()
                    values[name] = result
                    self.assertTrue(evidence_problems(values))

    def test_selected_route_must_not_fail_cancel_or_skip(self) -> None:
        for result in ("failure", "cancelled", "skipped", ""):
            with self.subTest(result=result):
                values = environment()
                values["CONTRACT_RESULT"] = result
                self.assertTrue(evidence_problems(values))

    def test_unselected_route_must_not_run_or_disappear(self) -> None:
        for result in ("success", "failure", "cancelled", ""):
            with self.subTest(result=result):
                values = environment(requested="false", result="skipped")
                values["WINDOWS_RESULT"] = result
                self.assertTrue(evidence_problems(values))

    def test_missing_or_invalid_route_decision_fails_closed(self) -> None:
        for requested in (None, "", "yes", "TRUE"):
            with self.subTest(requested=requested):
                values = environment()
                if requested is None:
                    values.pop("MACOS_REQUESTED")
                else:
                    values["MACOS_REQUESTED"] = requested
                self.assertTrue(evidence_problems(values))


if __name__ == "__main__":
    unittest.main(verbosity=2)
