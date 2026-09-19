#!/usr/bin/env python3
"""Fast policy tests for Linux KIPC campaign thermal publication blockers."""

from __future__ import annotations

import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import campaign  # noqa: E402


class CampaignThermalPolicyTests(unittest.TestCase):
    def test_nominal_removes_only_thermal_blocker(self) -> None:
        reasons = campaign.publication_reasons_for_thermal("nominal", paired=False)
        self.assertEqual(
            reasons,
            [
                "RESULT_V2_SESSION_BLOCK_SCHEMA_GAP",
                "NO_SAME_SESSION_PAIRED_RUST_ARM",
            ],
        )

    def test_unverified_and_throttled_are_distinct(self) -> None:
        unverified = campaign.publication_reasons_for_thermal(
            "unverified", paired=False
        )
        throttled = campaign.publication_reasons_for_thermal(
            "throttled", paired=False
        )
        self.assertIn("THERMAL_STATE_UNVERIFIED", unverified)
        self.assertNotIn("THERMAL_THROTTLED", unverified)
        self.assertIn("THERMAL_THROTTLED", throttled)
        self.assertNotIn("THERMAL_STATE_UNVERIFIED", throttled)

    def test_paired_keeps_product_vs_floor_scope_blocker(self) -> None:
        reasons = campaign.publication_reasons_for_thermal("nominal", paired=True)
        self.assertEqual(
            reasons,
            [
                "RESULT_V2_SESSION_BLOCK_SCHEMA_GAP",
                "PRODUCT_CLIENT_VS_LIBRARY_FLOOR_DIAGNOSTIC",
            ],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
