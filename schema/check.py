#!/usr/bin/env python3
"""Falsifiable contract check for the keld-benches result schema.

Run from the repo root:  python3 schema/check.py

Checks, in order:
1. `schema/result.v1.schema.json` is itself a valid JSON Schema (draft 2020-12).
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

try:
    from jsonschema import Draft202012Validator
except ImportError:
    sys.exit("jsonschema not installed: pip install jsonschema")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "schema" / "result.v1.schema.json"
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


# 1. Schema is valid draft 2020-12.
schema = json.loads(SCHEMA_PATH.read_text())
try:
    Draft202012Validator.check_schema(schema)
    check(True, "result.v1 schema is valid draft 2020-12")
except Exception as exc:  # noqa: BLE001 - report, do not crash the gate
    check(False, "result.v1 schema is valid draft 2020-12", str(exc))
validator = Draft202012Validator(schema)

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
    errors = sorted(validator.iter_errors(doc), key=lambda e: e.json_path)
    check(not errors, f"example validates: {path.name}",
          errors[0].message[:120] if errors else "")
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
        ("absolute interpreted-module path is rejected",
         mutated(lambda d: d["provenance"]["harness"].update(modules=[{
             "path": "/tmp/harness.py",
             "sha256": "0" * 64,
         }]))),
        ("interpreted-module traversal path is rejected",
         mutated(lambda d: d["provenance"]["harness"].update(modules=[{
             "path": "linux/bench/../private.py",
             "sha256": "0" * 64,
         }]))),
        ("unknown per-sample field is rejected",
         mutated(lambda d: d["arms"][0]["samples"][0].update(surprise=1))),
        ("sample without validity flag is rejected",
         mutated(lambda d: d["arms"][0]["samples"][0].pop("valid"))),
        ("arm without statistics is rejected",
         mutated(lambda d: d["arms"][0].pop("statistics"))),
    ]
    for name, bad in controls:
        check(not validator.is_valid(bad), name, "(schema accepted a bad document)")

print()
if failures:
    sys.exit(f"{failures} check(s) FAILED")
print("all schema contract checks passed")
