#!/usr/bin/env python3
"""Cross-platform failure controls for the version-dispatching result validator."""

from __future__ import annotations

import contextlib
import importlib.util
import hashlib
import io
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "windows" / "bench" / "validate_result_v1.py"
SPEC = importlib.util.spec_from_file_location("validate_result", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class ValidatorFailureTests(unittest.TestCase):
    def validate(self, document: object) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "candidate.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = VALIDATOR.main(["validate_result_v1.py", str(ROOT), str(path)])
        return code, output.getvalue()

    def test_unknown_schema_with_non_mapping_metric_fails_without_crashing(self) -> None:
        code, output = self.validate({"schema_version": 4, "metric": []})
        self.assertEqual(code, 2)
        self.assertIn("has no result.v4.schema.json", output)
        self.assertNotIn("Traceback", output)

    def test_policy_v2_valid_sample_without_value_fails_schema(self) -> None:
        example = json.loads(
            (ROOT / "schema" / "examples" / "paint-opportunity.fresh-process.example.json")
            .read_text(encoding="utf-8")
        )
        example["schema_version"] = 2
        example["publication"].update(policy_version=2, eligible=False)
        example["provenance"]["harness"].update(
            sha256="0" * 64,
            modules=[{
                "path": example["provenance"]["harness"]["path"],
                "sha256": "0" * 64,
            }],
        )
        example["arms"][0]["samples"][0].pop("value")
        code, output = self.validate(example)
        self.assertEqual(code, 2)
        self.assertIn("'value' is a required property", output)

    def v3_corpus_document(self) -> dict:
        example = json.loads(
            (ROOT / "schema" / "examples" / "ipc-rtt.block-corpus.v3.example.json")
            .read_text(encoding="utf-8")
        )
        relative = (
            "linux/bench/results/ipc-rtt/"
            "2026-09-18.kel90-linux-bun-100k-small.fresh-process.s01.raw.json"
        )
        raw_path = ROOT / relative
        raw = raw_path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        example["session"]["requested_samples"] = 1
        example["session"]["label"] = "ipc-block-validator-test"
        block = {
            "block": 1,
            "valid": True,
            "observations": 100000,
            "raw_file": {
                "path": relative,
                "sha256": digest,
                "bytes": len(raw),
            },
            "reject_reason": None,
        }
        corpus = example["arms"][0]["corpus"]
        corpus["blocks"] = [block]
        corpus["digest_chain_sha256"] = hashlib.sha256(
            bytes.fromhex(digest)
        ).hexdigest()
        stats = example["arms"][0]["statistics"]
        stats["valid_samples"] = 1
        stats["observations"] = 100000
        example["publication"].update(
            eligible=False,
            reasons=[{"code": "SAMPLES_BELOW_POLICY"}],
        )
        return example

    def test_v3_block_corpus_validates_bound_raw_sidecar(self) -> None:
        code, output = self.validate(self.v3_corpus_document())
        self.assertEqual(code, 0, output)
        self.assertIn("all 1 document(s) valid", output)

    def test_v3_block_corpus_raw_hash_mismatch_fails(self) -> None:
        document = self.v3_corpus_document()
        document["arms"][0]["corpus"]["blocks"][0]["raw_file"]["sha256"] = "f" * 64
        document["arms"][0]["corpus"]["digest_chain_sha256"] = hashlib.sha256(
            bytes.fromhex("f" * 64)
        ).hexdigest()
        code, output = self.validate(document)
        self.assertEqual(code, 2)
        self.assertIn("raw sidecar sha256 mismatch", output)

    def test_v3_block_corpus_raw_size_mismatch_fails(self) -> None:
        document = self.v3_corpus_document()
        document["arms"][0]["corpus"]["blocks"][0]["raw_file"]["bytes"] += 1
        code, output = self.validate(document)
        self.assertEqual(code, 2)
        self.assertIn("raw sidecar bytes mismatch", output)

    def test_non_numeric_median_fails_without_float_conversion_crash(self) -> None:
        example = json.loads(
            (ROOT / "schema" / "examples" / "paint-opportunity.fresh-process.example.json")
            .read_text(encoding="utf-8")
        )
        example["arms"][0]["statistics"]["median"] = "not-a-number"
        code, output = self.validate(example)
        self.assertEqual(code, 2)
        self.assertIn("is not valid under any of the given schemas", output)
        self.assertNotIn("Traceback", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
