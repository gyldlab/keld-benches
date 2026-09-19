#!/usr/bin/env python3
"""Fast deterministic tests for result.v3 block-corpus helpers."""

from __future__ import annotations

import hashlib
import unittest

from block_result import (
    block_bootstrap_metadata,
    block_corpus,
    ipc_statistics_us,
    linux_ipc_environment,
)


class BlockResultTests(unittest.TestCase):
    def test_corpus_orders_blocks_and_binds_digest_chain(self) -> None:
        receipts = []
        for block in (2, 1):
            sha = hashlib.sha256(f"b{block}".encode()).hexdigest()
            receipts.append(
                {
                    "tier": "small",
                    "block": block,
                    "path": f"linux/bench/results/ipc-rtt/b{block}.raw.json",
                    "sha256": sha,
                    "bytes": 100 + block,
                }
            )
        bootstrap = block_bootstrap_metadata(
            resamples=2000, method="session block bootstrap", seed=1, rng="MT19937"
        )
        corpus = block_corpus(
            receipts,
            tier="small",
            block_unit="independent-session",
            observations_per_block=100000,
            bootstrap=bootstrap,
        )
        self.assertEqual([b["block"] for b in corpus["blocks"]], [1, 2])
        hashes = [b["raw_file"]["sha256"] for b in corpus["blocks"]]
        expected = hashlib.sha256(
            b"".join(bytes.fromhex(value) for value in hashes)
        ).hexdigest()
        self.assertEqual(corpus["digest_chain_sha256"], expected)

    def test_corpus_rejects_gap_and_duplicate_path(self) -> None:
        sha = "1" * 64
        with self.assertRaisesRegex(ValueError, "not contiguous"):
            block_corpus(
                [
                    {
                        "tier": "small",
                        "block": 2,
                        "path": "linux/bench/results/ipc-rtt/a.raw.json",
                        "sha256": sha,
                        "bytes": 1,
                    }
                ],
                tier="small",
                block_unit="independent-session",
                observations_per_block=1,
                bootstrap={"unit": "block", "resamples": 1000, "method": "x"},
            )

    def test_statistics_convert_nanoseconds_to_microseconds(self) -> None:
        stats = ipc_statistics_us(
            {
                "sessions": 20,
                "pooled_timed_calls": 2_000_000,
                "p50_ns": 14204,
                "p90_ns": 19032,
                "p99_ns": 27506,
                "max_ns": 100000,
                "bootstrap_ci95_p50_ns": [14000, 14500],
                "bootstrap_ci95_p99_ns": [26723, 28376],
                "bootstrap_resamples": 2000,
            },
            bootstrap_method="whole-session block bootstrap",
        )
        self.assertEqual(stats["median"], 14.204)
        self.assertEqual(stats["p99"], 27.506)
        self.assertEqual(stats["confidence_intervals"]["p99"]["lower"], 26.723)

    def test_environment_requires_verified_power_inputs(self) -> None:
        metadata = {
            "os": "Ubuntu",
            "kernel": "7.0",
            "arch": "x86_64",
            "cpu": "CPU",
            "ram_kib": 1024,
            "ac_power": True,
            "power_profile": "performance",
            "thermal_state": "nominal",
            "rustc": "rustc 1",
            "cargo": "cargo 1",
            "bun_version": "1.4.2",
            "bun_revision": "abc",
        }
        environment = linux_ipc_environment(metadata)
        self.assertEqual(environment["hardware"]["ram_bytes"], 1024 * 1024)
        self.assertFalse(environment["power"]["low_power_mode"])
        bad = dict(metadata)
        bad["ac_power"] = None
        with self.assertRaisesRegex(ValueError, "ac_power"):
            linux_ipc_environment(bad)


if __name__ == "__main__":
    unittest.main(verbosity=2)
