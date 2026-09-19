#!/usr/bin/env python3
"""Fast policy and result-v3 emission tests for Linux KIPC campaigns."""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import campaign  # noqa: E402
import paired_campaign  # noqa: E402


class CampaignThermalPolicyTests(unittest.TestCase):
    def test_nominal_removes_schema_and_thermal_blockers(self) -> None:
        reasons = campaign.publication_reasons_for_thermal("nominal", paired=False)
        self.assertEqual(reasons, ["NO_SAME_SESSION_PAIRED_RUST_ARM"])

    def test_unverified_and_throttled_are_distinct(self) -> None:
        unverified = campaign.publication_reasons_for_thermal(
            "unverified", paired=False
        )
        throttled = campaign.publication_reasons_for_thermal(
            "throttled", paired=False
        )
        self.assertIn("THERMAL_STATE_UNVERIFIED", unverified)
        self.assertNotIn("THERMAL_THROTTLED", unverified)
        self.assertNotIn("RESULT_V2_SESSION_BLOCK_SCHEMA_GAP", unverified)
        self.assertIn("THERMAL_THROTTLED", throttled)
        self.assertNotIn("THERMAL_STATE_UNVERIFIED", throttled)
        self.assertNotIn("RESULT_V2_SESSION_BLOCK_SCHEMA_GAP", throttled)

    def test_paired_keeps_only_product_vs_floor_scope_blocker(self) -> None:
        reasons = campaign.publication_reasons_for_thermal("nominal", paired=True)
        self.assertEqual(reasons, ["PRODUCT_CLIENT_VS_LIBRARY_FLOOR_DIAGNOSTIC"])


class V3EmissionTests(unittest.TestCase):
    @staticmethod
    def environment() -> dict:
        return {
            "os": "Ubuntu 26.04.1 LTS",
            "kernel": "7.0.0-30-generic",
            "arch": "x86_64",
            "cpu": "Example CPU",
            "cpu_logical": 16,
            "ram_kib": 32 * 1024 * 1024,
            "ac_power": True,
            "power_profile": "performance",
            "thermal_state": "nominal",
            "thermal_evidence": "thermal-boundary-v1;state=nominal",
            "rustc": "rustc 1.97.1",
            "cargo": "cargo 1.97.1",
            "bun_version": "1.4.2",
            "bun_revision": "744846f844374847c902b5e7fd59b4342a51ef99",
        }

    @staticmethod
    def raw_receipts(*, paired: bool) -> list[dict]:
        receipts: list[dict] = []
        arms = ("rust", "bun") if paired else (None,)
        for tier in ("small", "representative"):
            for block in range(1, 21):
                for arm in arms:
                    tag = f"{tier}-{block}-{arm or 'bun'}"
                    sha = hashlib.sha256(tag.encode()).hexdigest()
                    receipt = {
                        "path": (
                            "linux/bench/results/ipc-rtt/"
                            f"2026-09-19.synthetic-{tag}.raw.json"
                        ),
                        "sha256": sha,
                        "bytes": 500000 + block,
                        "block": block,
                        "tier": tier,
                    }
                    if arm is not None:
                        receipt["arm"] = arm
                    receipts.append(receipt)
        return receipts

    @staticmethod
    def arm_stats(p99_ns: int) -> dict:
        return {
            "sessions": 20,
            "calls_timed_per_session": 100000,
            "pooled_timed_calls": 2_000_000,
            "p50_ns": 14000,
            "p90_ns": 19000,
            "p99_ns": p99_ns,
            "max_ns": 100000,
            "bootstrap_ci95_p50_ns": [13800, 14200],
            "bootstrap_ci95_p99_ns": [p99_ns - 500, p99_ns + 500],
            "bootstrap_resamples": 2000,
            "handshake_ns": {"min": 1000, "median": 2000, "max": 3000},
        }

    @classmethod
    def bun_tiers(cls) -> dict:
        return {
            tier: {**cls.arm_stats(27500), "payload_bytes": 6 if tier == "small" else 1024}
            for tier in ("small", "representative")
        }

    @classmethod
    def paired_tiers(cls) -> dict:
        output = {}
        for tier in ("small", "representative"):
            rust = cls.arm_stats(12000)
            bun = cls.arm_stats(30000)
            output[tier] = {
                "payload_bytes": 6 if tier == "small" else 1024,
                "rust_library_floor": rust,
                "bun_product_client": bun,
                "paired_comparison": {
                    "central_p50_ratio": 2.0,
                    "central_p99_ratio": 2.5,
                    "central_p50_delta_ns": 14000,
                    "central_p99_delta_ns": 18000,
                    "p50": {
                        "ratio_ci95": [1.9, 2.1],
                        "delta_ns_ci95": [13000, 15000],
                    },
                    "p99": {
                        "ratio_ci95": [2.4, 2.6],
                        "delta_ns_ci95": [17000, 19000],
                    },
                },
            }
        return output

    def test_bun_campaign_emits_two_v3_tier_documents(self) -> None:
        fake_artifacts = [
            {
                "role": "host-runner",
                "sha256": "a" * 64,
                "basename": "kel90-linux-bun-kipc-runner",
                "version": campaign.KELD_SHA[:12],
            },
            {
                "role": "bun-runtime",
                "sha256": "b" * 64,
                "basename": "bun",
                "version": "1.4.2+744846f84",
            },
        ]
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            campaign, "measured_bun_artifacts", return_value=fake_artifacts
        ):
            paths = campaign.write_v3_results(
                out_dir=pathlib.Path(temporary),
                date="2026-09-19",
                cache_state="fresh-process",
                bench_sha="c" * 40,
                started_utc="2026-09-19T12:00:00Z",
                finished_utc="2026-09-19T12:01:00Z",
                environment_metadata_value=self.environment(),
                thermal_evidence="thermal-boundary-v1;state=nominal",
                raw_files=self.raw_receipts(paired=False),
                tiers=self.bun_tiers(),
            )
            self.assertEqual(len(paths), 2)
            for path in paths:
                doc = json.loads(path.read_text())
                self.assertEqual(doc["schema_version"], 3)
                self.assertEqual(doc["publication"]["reasons"], [
                    {"code": "NO_SAME_SESSION_PAIRED_RUST_ARM"}
                ])
                self.assertEqual(doc["arms"][0]["statistics"]["valid_samples"], 20)
                self.assertEqual(doc["arms"][0]["statistics"]["observations"], 2_000_000)
                self.assertEqual(len(doc["arms"][0]["corpus"]["blocks"]), 20)
                self.assertFalse(doc["metric"]["parameters"]["handshake_included"])

    def test_paired_campaign_emits_diagnostic_comparisons_without_verdict(self) -> None:
        fake_bun_artifacts = [
            {"role": "host-runner", "sha256": "a" * 64, "basename": "runner", "version": "x"},
            {"role": "bun-runtime", "sha256": "b" * 64, "basename": "bun", "version": "1.4.2"},
        ]
        fake_rust_artifacts = [
            {"role": "rust-client", "sha256": "d" * 64, "basename": "client", "version": "x"},
            {"role": "rust-server", "sha256": "e" * 64, "basename": "server", "version": "x"},
        ]
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            campaign, "measured_bun_artifacts", return_value=fake_bun_artifacts
        ), mock.patch.object(
            paired_campaign, "measured_rust_artifacts", return_value=fake_rust_artifacts
        ):
            paths = paired_campaign.write_v3_results(
                out_dir=pathlib.Path(temporary),
                date="2026-09-19",
                cache_state="fresh-process",
                bench_sha="c" * 40,
                started_utc="2026-09-19T12:00:00Z",
                finished_utc="2026-09-19T12:01:00Z",
                environment_metadata_value=self.environment(),
                thermal_evidence="thermal-boundary-v1;state=nominal",
                raw_files=self.raw_receipts(paired=True),
                tiers=self.paired_tiers(),
            )
            self.assertEqual(len(paths), 2)
            doc = json.loads(paths[0].read_text())
            self.assertNotIn("comparison", doc)
            self.assertEqual(len(doc["diagnostic_comparisons"]), 2)
            self.assertEqual(doc["diagnostic_comparisons"][1]["statistic"], "p99")
            self.assertEqual(doc["diagnostic_comparisons"][1]["central_ratio"], 2.5)
            self.assertEqual(doc["diagnostic_comparisons"][1]["central_delta"], 18.0)
            self.assertEqual(
                doc["publication"]["reasons"],
                [{"code": "PRODUCT_CLIENT_VS_LIBRARY_FLOOR_DIAGNOSTIC"}],
            )
            self.assertTrue(all(
                arm["corpus"]["block_unit"] == "paired-session-round"
                for arm in doc["arms"]
            ))


if __name__ == "__main__":
    unittest.main(verbosity=2)
