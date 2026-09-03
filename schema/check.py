#!/usr/bin/env python3
"""Falsifiable contract check for the keld-benches result schema.

Run from the repo root:  python3 schema/check.py

Checks, in order:
1. Every `schema/result.vN.schema.json` is a valid JSON Schema (draft 2020-12).
2. `schema/metrics.v1.json` parses, every metric id matches the id pattern the
   result schema enforces, ids are unique, and every referenced cache state is
   one of the four defined classes.
3. Every document under `schema/examples/` validates against the result schema.
4. Negative controls: known-bad mutations of a valid document MUST be rejected.
   A schema that accepts these is defective, even if every example passes.

Requires: python3 + jsonschema (`pip install jsonschema`). Exit 0 = all pass.
"""

import copy
import json
import pathlib
import re
import sys

from result_contract import semantic_problems

try:
    from jsonschema import Draft202012Validator
except ImportError:
    sys.exit("jsonschema not installed: pip install jsonschema")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_PATHS = sorted((ROOT / "schema").glob("result.v*.schema.json"))
REGISTRY_PATH = ROOT / "schema" / "metrics.v1.json"
EXAMPLES_DIR = ROOT / "schema" / "examples"

CACHE_STATES = {"boot-cold", "fresh-process", "warm-cache", "renderer-warm"}
METRIC_ID_PATTERN = re.compile(r"^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*$")

failures = 0


def check(condition, name, detail=""):
    global failures
    if condition:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name} {detail}")
        failures += 1


# 1. Every versioned schema is valid draft 2020-12 and self-identifies.
validators = {}
for schema_path in SCHEMA_PATHS:
    match = re.fullmatch(r"result\.v([0-9]+)\.schema\.json", schema_path.name)
    if match is None:
        continue
    version = int(match.group(1))
    schema = json.loads(schema_path.read_text())
    try:
        Draft202012Validator.check_schema(schema)
        check(True, f"result.v{version} schema is valid draft 2020-12")
    except Exception as exc:  # noqa: BLE001 - report, do not crash the gate
        check(False, f"result.v{version} schema is valid draft 2020-12", str(exc))
    check(
        schema.get("properties", {}).get("schema_version", {}).get("const") == version,
        f"result.v{version} schema const matches its filename",
    )
    validators[version] = Draft202012Validator(schema)
check(set(validators) >= {1, 2}, "result schema versions 1 and 2 are present")

# 2. Registry invariants.
registry = json.loads(REGISTRY_PATH.read_text())
ids = [m["id"] for m in registry["metrics"]]
check(len(set(ids)) == len(ids), "registry metric ids are unique")
check(
    all(METRIC_ID_PATTERN.match(i) for i in ids),
    "every registry id matches the result-schema id pattern",
)
check(
    all(set(m["cache_states"]) <= CACHE_STATES for m in registry["metrics"]),
    "every registry cache state is a defined class",
)
check(
    all("unit" in m and "oracle" in m and "status" in m for m in registry["metrics"]),
    "every registry entry names unit, oracle, and status",
)

# 3. Examples validate.
examples = sorted(EXAMPLES_DIR.glob("*.json"))
check(bool(examples), "at least one example document exists")
valid_doc = None
for path in examples:
    doc = json.loads(path.read_text())
    validator = validators.get(doc.get("schema_version"))
    errors = [] if validator is None else sorted(
        validator.iter_errors(doc), key=lambda e: e.json_path
    )
    if validator is None:
        errors = [ValueError(f"unknown schema_version {doc.get('schema_version')!r}")]
    check(not errors, f"example validates: {path.name}",
          str(getattr(errors[0], "message", errors[0]))[:120] if errors else "")
    if not errors and valid_doc is None:
        valid_doc = doc
    metric_id = doc.get("metric", {}).get("id")
    check(metric_id in ids, f"example metric id is registered: {path.name}",
          f"unknown id {metric_id!r}")

# 4. Negative controls. Each mutation reproduces a defect class that actually
#    occurred in this repo's pre-contract results (see HARNESS-CONTRACT.md).
if valid_doc is None:
    check(False, "negative controls ran", "no valid example to mutate")
else:
    validator = validators[1]

    def mutated(fn):
        doc = copy.deepcopy(valid_doc)
        fn(doc)
        return doc

    controls = [
        ("undefined cache-state class is rejected",
         mutated(lambda d: d.update(cache_state="lukewarm"))),
        ("branch name in place of an immutable sha is rejected",
         mutated(lambda d: d["provenance"].update(bench_sha="main"))),
        ("missing publication block is rejected",
         mutated(lambda d: d.pop("publication"))),
        ("free-text metric id is rejected",
         mutated(lambda d: d["metric"].update(id="first paint"))),
        ("absolute harness path is rejected",
         mutated(lambda d: d["provenance"]["harness"].update(
             path="/Users/nobody/bench.ps1"))),
        ("unknown per-sample field is rejected",
         mutated(lambda d: d["arms"][0]["samples"][0].update(surprise=1))),
        ("sample without validity flag is rejected",
         mutated(lambda d: d["arms"][0]["samples"][0].pop("valid"))),
        ("arm without statistics is rejected",
         mutated(lambda d: d["arms"][0].pop("statistics"))),
    ]
    for name, bad in controls:
        check(not validator.is_valid(bad), name, "(schema accepted a bad document)")

    policy_v2 = mutated(lambda d: (
        d.update(schema_version=2),
        d["publication"].update(policy_version=2, eligible=True, reasons=[]),
        d["provenance"]["harness"].update(
            sha256="0" * 64,
            modules=[{
                "path": "windows/bench/Measure-FirstPaint.ps1",
                "sha256": "0" * 64,
            }],
        ),
    ))
    validator_v2 = validators[2]
    check(
        validator_v2.is_valid(policy_v2) and not semantic_problems(policy_v2),
        "policy-v2 eligible result with complete modules is accepted",
    )

    without_modules = copy.deepcopy(policy_v2)
    without_modules["provenance"]["harness"].pop("modules")
    check(
        not validator_v2.is_valid(without_modules),
        "policy-v2 eligible result without modules is rejected",
    )

    absolute_module = copy.deepcopy(policy_v2)
    absolute_module["provenance"]["harness"]["modules"][0]["path"] = "/tmp/harness.py"
    check(
        not validator_v2.is_valid(absolute_module),
        "absolute interpreted-module path is rejected",
    )

    traversal_module = copy.deepcopy(policy_v2)
    traversal_module["provenance"]["harness"]["modules"][0]["path"] = (
        "linux/bench/../private.py"
    )
    check(
        not validator_v2.is_valid(traversal_module),
        "interpreted-module traversal path is rejected",
    )

    fixture_traversal = copy.deepcopy(policy_v2)
    fixture_traversal["provenance"]["fixtures"] = [
        {"path": "linux/keld/../../outside", "sha": "0" * 40}
    ]
    fixture_traversal["arms"][0]["fixture_path"] = "linux/keld/../../outside"
    check(
        not validator_v2.is_valid(fixture_traversal),
        "policy-v2 fixture traversal paths are rejected",
    )

    shallow_fixture = copy.deepcopy(policy_v2)
    shallow_fixture["provenance"]["fixtures"] = [
        {"path": "linux/keld", "sha": "0" * 40}
    ]
    shallow_fixture["arms"][0]["fixture_path"] = "linux/keld"
    check(
        not validator_v2.is_valid(shallow_fixture),
        "policy-v2 fixture paths require OS, framework, and fixture segments",
    )

    valid_without_value = copy.deepcopy(policy_v2)
    valid_without_value["arms"][0]["samples"][0].pop("value")
    check(
        not validator_v2.is_valid(valid_without_value),
        "policy-v2 valid sample without value is rejected",
    )

    invalid_without_reason = copy.deepcopy(policy_v2)
    invalid_without_reason["arms"][0]["samples"][0].update(valid=False, value=None)
    invalid_without_reason["arms"][0]["samples"][0].pop("reject_reason", None)
    check(
        not validator_v2.is_valid(invalid_without_reason),
        "policy-v2 invalid sample without rejection reason is rejected",
    )

    invalid_with_value = copy.deepcopy(policy_v2)
    invalid_with_value["arms"][0]["samples"][0].update(
        valid=False, value=1, reject_reason="expected failure"
    )
    check(
        not validator_v2.is_valid(invalid_with_value),
        "policy-v2 invalid sample with numeric value is rejected",
    )

    policy_v2_mismatch = copy.deepcopy(policy_v2)
    policy_v2_mismatch["provenance"]["harness"]["sha256"] = "1" * 64
    check(
        bool(semantic_problems(policy_v2_mismatch)),
        "policy-v2 entrypoint/module hash mismatch is rejected",
    )

    policy_v2_diagnostic = copy.deepcopy(policy_v2)
    policy_v2_diagnostic["publication"].update(
        eligible=False,
        reasons=[{"code": "HARNESS_MODULES_UNPROVEN"}],
    )
    policy_v2_diagnostic["provenance"]["harness"].pop("sha256")
    policy_v2_diagnostic["provenance"]["harness"].pop("modules")
    check(
        validator_v2.is_valid(policy_v2_diagnostic)
        and not semantic_problems(policy_v2_diagnostic),
        "policy-v2 diagnostic may record incomplete modules with blocking reason",
    )
    check(
        not semantic_problems({"publication": []})
        and not semantic_problems({"publication": {"policy_version": "2"}}),
        "semantic checker leaves malformed container rejection to JSON Schema",
    )

print()
if failures:
    sys.exit(f"{failures} check(s) FAILED")
print("all schema contract checks passed")
