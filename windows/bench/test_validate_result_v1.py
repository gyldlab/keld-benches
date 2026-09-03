#!/usr/bin/env python3
"""Cross-platform failure controls for the version-dispatching result validator."""

from __future__ import annotations

import contextlib
import importlib.util
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
        code, output = self.validate({"schema_version": 3, "metric": []})
        self.assertEqual(code, 2)
        self.assertIn("has no result.v3.schema.json", output)
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
