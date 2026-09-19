#!/usr/bin/env python3
"""Falsifiable contract check for the keld-benches result schemas and registry."""

from __future__ import annotations

import copy
import hashlib
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
BLOCK_UNITS = {"independent-session", "paired-session-round"}
STATISTICS = {"median", "p90", "p99"}

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
check(set(validators) >= {1, 2, 3}, "result schema versions 1, 2, and 3 are present")

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
block_policies = [
    policy
    for policy in registry.get("sample_policy", {}).values()
    if isinstance(policy, dict) and policy.get("mode") == "block-corpus"
]
check(bool(block_policies), "registry contains at least one block-corpus sample policy")
for index, policy in enumerate(block_policies, start=1):
    check(
        isinstance(policy.get("sessions_min"), int) and policy["sessions_min"] >= 1,
        f"block-corpus policy {index} has positive sessions_min",
    )
    check(
        isinstance(policy.get("calls_per_session"), int)
        and policy["calls_per_session"] >= 1,
        f"block-corpus policy {index} has positive calls_per_session",
    )
    check(
        set(policy.get("allowed_block_units", [])) <= BLOCK_UNITS
        and bool(policy.get("allowed_block_units")),
        f"block-corpus policy {index} uses defined block units",
    )
    check(
        policy.get("bootstrap_unit") == "block",
        f"block-corpus policy {index} bootstraps by block",
    )
    check(
        set(policy.get("required_statistics", [])) <= STATISTICS,
        f"block-corpus policy {index} names defined required statistics",
    )
    check(
        set(policy.get("required_confidence_intervals", [])) <= STATISTICS,
        f"block-corpus policy {index} names defined confidence intervals",
    )

# 3. Examples validate structurally and semantically.
examples = sorted(EXAMPLES_DIR.glob("*.json"))
check(bool(examples), "at least one example document exists")
valid_docs_by_version = {}
for path in examples:
    doc = json.loads(path.read_text())
    version = doc.get("schema_version")
    validator = validators.get(version)
    errors = [] if validator is None else sorted(
        validator.iter_errors(doc), key=lambda e: e.json_path
    )
    if validator is None:
        errors = [ValueError(f"unknown schema_version {version!r}")]
    semantic = [] if errors else semantic_problems(doc, registry)
    check(
        not errors and not semantic,
        f"example validates: {path.name}",
        (
            str(getattr(errors[0], "message", errors[0]))[:120]
            if errors
            else semantic[0][:120] if semantic else ""
        ),
    )
    if not errors and not semantic and isinstance(version, int):
        valid_docs_by_version.setdefault(version, doc)
    metric_id = doc.get("metric", {}).get("id")
    check(
        metric_id in ids,
        f"example metric id is registered: {path.name}",
        f"unknown id {metric_id!r}",
    )

# 4. Historical/v2 negative controls.
valid_v1 = valid_docs_by_version.get(1)
if valid_v1 is None:
    check(False, "v1 negative controls ran", "no valid v1 example to mutate")
else:
    validator_v1 = validators[1]

    def mutated_v1(fn):
        doc = copy.deepcopy(valid_v1)
        fn(doc)
        return doc

    controls = [
        ("undefined cache-state class is rejected", mutated_v1(lambda d: d.update(cache_state="lukewarm"))),
        ("branch name in place of an immutable sha is rejected", mutated_v1(lambda d: d["provenance"].update(bench_sha="main"))),
        ("missing publication block is rejected", mutated_v1(lambda d: d.pop("publication"))),
        ("free-text metric id is rejected", mutated_v1(lambda d: d["metric"].update(id="first paint"))),
        ("absolute harness path is rejected", mutated_v1(lambda d: d["provenance"]["harness"].update(path="/Users/nobody/bench.ps1"))),
        ("unknown per-sample field is rejected", mutated_v1(lambda d: d["arms"][0]["samples"][0].update(surprise=1))),
        ("sample without validity flag is rejected", mutated_v1(lambda d: d["arms"][0]["samples"][0].pop("valid"))),
        ("arm without statistics is rejected", mutated_v1(lambda d: d["arms"][0].pop("statistics"))),
    ]
    for name, bad in controls:
        check(not validator_v1.is_valid(bad), name, "(schema accepted a bad document)")

    policy_v2 = mutated_v1(lambda d: (
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
        validator_v2.is_valid(policy_v2) and not semantic_problems(policy_v2, registry),
        "policy-v2 eligible result with complete modules is accepted",
    )

    without_modules = copy.deepcopy(policy_v2)
    without_modules["provenance"]["harness"].pop("modules")
    check(not validator_v2.is_valid(without_modules), "policy-v2 eligible result without modules is rejected")

    absolute_module = copy.deepcopy(policy_v2)
    absolute_module["provenance"]["harness"]["modules"][0]["path"] = "/tmp/harness.py"
    check(not validator_v2.is_valid(absolute_module), "absolute interpreted-module path is rejected")

    traversal_module = copy.deepcopy(policy_v2)
    traversal_module["provenance"]["harness"]["modules"][0]["path"] = "linux/bench/../private.py"
    check(not validator_v2.is_valid(traversal_module), "interpreted-module traversal path is rejected")

    fixture_traversal = copy.deepcopy(policy_v2)
    fixture_traversal["provenance"]["fixtures"] = [{"path": "linux/keld/../../outside", "sha": "0" * 40}]
    fixture_traversal["arms"][0]["fixture_path"] = "linux/keld/../../outside"
    check(not validator_v2.is_valid(fixture_traversal), "policy-v2 fixture traversal paths are rejected")

    shallow_fixture = copy.deepcopy(policy_v2)
    shallow_fixture["provenance"]["fixtures"] = [{"path": "linux/keld", "sha": "0" * 40}]
    shallow_fixture["arms"][0]["fixture_path"] = "linux/keld"
    check(not validator_v2.is_valid(shallow_fixture), "policy-v2 fixture paths require OS, framework, and fixture segments")

    valid_without_value = copy.deepcopy(policy_v2)
    valid_without_value["arms"][0]["samples"][0].pop("value")
    check(not validator_v2.is_valid(valid_without_value), "policy-v2 valid sample without value is rejected")

    invalid_without_reason = copy.deepcopy(policy_v2)
    invalid_without_reason["arms"][0]["samples"][0].update(valid=False, value=None)
    invalid_without_reason["arms"][0]["samples"][0].pop("reject_reason", None)
    check(not validator_v2.is_valid(invalid_without_reason), "policy-v2 invalid sample without rejection reason is rejected")

    invalid_with_value = copy.deepcopy(policy_v2)
    invalid_with_value["arms"][0]["samples"][0].update(valid=False, value=1, reject_reason="expected failure")
    check(not validator_v2.is_valid(invalid_with_value), "policy-v2 invalid sample with numeric value is rejected")

    policy_v2_mismatch = copy.deepcopy(policy_v2)
    policy_v2_mismatch["provenance"]["harness"]["sha256"] = "1" * 64
    check(bool(semantic_problems(policy_v2_mismatch, registry)), "policy-v2 entrypoint/module hash mismatch is rejected")

    policy_v2_diagnostic = copy.deepcopy(policy_v2)
    policy_v2_diagnostic["publication"].update(eligible=False, reasons=[{"code": "HARNESS_MODULES_UNPROVEN"}])
    policy_v2_diagnostic["provenance"]["harness"].pop("sha256")
    policy_v2_diagnostic["provenance"]["harness"].pop("modules")
    check(
        validator_v2.is_valid(policy_v2_diagnostic)
        and not semantic_problems(policy_v2_diagnostic, registry),
        "policy-v2 diagnostic may record incomplete modules with blocking reason",
    )

# 5. Version-3 block-corpus positive and negative controls.
valid_v3 = valid_docs_by_version.get(3)
if valid_v3 is None:
    check(False, "v3 block-corpus controls ran", "no valid v3 example")
else:
    validator_v3 = validators[3]

    def semantic_rejects(doc, text):
        problems = semantic_problems(doc, registry)
        return bool(problems) and any(text in problem for problem in problems)

    missing_raw = copy.deepcopy(valid_v3)
    missing_raw["arms"][0]["corpus"]["blocks"][0]["raw_file"] = None
    check(not validator_v3.is_valid(missing_raw), "v3 valid block without raw sidecar is rejected")

    rejected_with_raw = copy.deepcopy(valid_v3)
    rejected_with_raw["arms"][0]["corpus"]["blocks"][0].update(
        valid=False, observations=0, reject_reason="expected rejection"
    )
    check(not validator_v3.is_valid(rejected_with_raw), "v3 rejected block cannot retain a raw sidecar")

    traversal_raw = copy.deepcopy(valid_v3)
    traversal_raw["arms"][0]["corpus"]["blocks"][0]["raw_file"]["path"] = (
        "linux/bench/results/ipc-rtt/../../secret.raw.json"
    )
    check(not validator_v3.is_valid(traversal_raw), "v3 raw sidecar traversal path is rejected")

    duplicate_block = copy.deepcopy(valid_v3)
    duplicate_block["arms"][0]["corpus"]["blocks"][1]["block"] = 1
    check(semantic_rejects(duplicate_block, "block ids"), "v3 duplicate block ids are rejected semantically")

    bad_valid_count = copy.deepcopy(valid_v3)
    bad_valid_count["arms"][0]["statistics"]["valid_samples"] = 1
    check(semantic_rejects(bad_valid_count, "valid_samples"), "v3 valid block count must match statistics")

    bad_observations = copy.deepcopy(valid_v3)
    bad_observations["arms"][0]["statistics"]["observations"] = 199999
    check(semantic_rejects(bad_observations, "statistics.observations"), "v3 pooled observation count must match blocks")

    bad_chain = copy.deepcopy(valid_v3)
    bad_chain["arms"][0]["corpus"]["digest_chain_sha256"] = "f" * 64
    check(semantic_rejects(bad_chain, "digest_chain_sha256"), "v3 digest chain must match ordered raw hashes")

    missing_payload = copy.deepcopy(valid_v3)
    missing_payload["metric"].pop("parameters", None)
    check(
        semantic_rejects(missing_payload, "payload_tier"),
        "v3 IPC block corpus without payload identity is rejected",
    )

    handshake_scored = copy.deepcopy(valid_v3)
    handshake_scored["metric"]["parameters"]["handshake_included"] = True
    check(
        semantic_rejects(handshake_scored, "handshake_included=false"),
        "v3 IPC block corpus cannot score the handshake",
    )

    duplicate_artifact_role = copy.deepcopy(valid_v3)
    duplicate_artifact_role["arms"][0]["artifacts"].append(
        copy.deepcopy(duplicate_artifact_role["arms"][0]["artifacts"][0])
    )
    check(
        semantic_rejects(duplicate_artifact_role, "artifact roles are not unique"),
        "v3 duplicate measured artifact roles are rejected",
    )

    # Build a complete synthetic 20x100k corpus that meets the registry policy.
    eligible_v3 = copy.deepcopy(valid_v3)
    eligible_v3["session"]["requested_samples"] = 20
    eligible_v3["publication"].update(policy_version=3, eligible=True, reasons=[])
    eligible_v3["arms"][0]["role"] = "score"
    blocks = []
    hashes = []
    for block in range(1, 21):
        digest = hashlib.sha256(f"eligible-block-{block}".encode()).hexdigest()
        hashes.append(digest)
        blocks.append({
            "block": block,
            "valid": True,
            "observations": 100000,
            "raw_file": {
                "path": f"linux/bench/results/ipc-rtt/2026-09-19.eligible.s{block:02d}.raw.json",
                "sha256": digest,
                "bytes": 500000 + block,
            },
            "reject_reason": None,
        })
    corpus = eligible_v3["arms"][0]["corpus"]
    corpus["blocks"] = blocks
    corpus["digest_chain_sha256"] = hashlib.sha256(
        b"".join(bytes.fromhex(digest) for digest in hashes)
    ).hexdigest()
    stats = eligible_v3["arms"][0]["statistics"]
    stats["valid_samples"] = 20
    stats["observations"] = 2_000_000
    stats["p99"] = 27.5
    stats["confidence_intervals"]["p99"] = {
        "lower": 26.7,
        "upper": 28.4,
        "resamples": 2000,
        "method": "whole-session block bootstrap",
    }
    check(
        validator_v3.is_valid(eligible_v3)
        and not semantic_problems(eligible_v3, registry),
        "policy-v3 eligible IPC block corpus meeting 20x100k policy is accepted",
    )

    too_few = copy.deepcopy(eligible_v3)
    too_few["session"]["requested_samples"] = 19
    too_few["arms"][0]["corpus"]["blocks"] = too_few["arms"][0]["corpus"]["blocks"][:19]
    too_few["arms"][0]["statistics"]["valid_samples"] = 19
    too_few["arms"][0]["statistics"]["observations"] = 1_900_000
    hashes = [block["raw_file"]["sha256"] for block in too_few["arms"][0]["corpus"]["blocks"]]
    too_few["arms"][0]["corpus"]["digest_chain_sha256"] = hashlib.sha256(
        b"".join(bytes.fromhex(digest) for digest in hashes)
    ).hexdigest()
    check(semantic_rejects(too_few, "registry requires at least 20"), "eligible IPC corpus below 20 blocks is rejected")

    too_short = copy.deepcopy(eligible_v3)
    too_short["arms"][0]["corpus"]["blocks"][0]["observations"] = 99999
    too_short["arms"][0]["statistics"]["observations"] = 1_999_999
    check(semantic_rejects(too_short, "registry requires at least 100000"), "eligible IPC block below 100k calls is rejected")

    no_p99_ci = copy.deepcopy(eligible_v3)
    no_p99_ci["arms"][0]["statistics"]["confidence_intervals"].pop("p99")
    check(semantic_rejects(no_p99_ci, "confidence_intervals.p99"), "eligible IPC corpus without p99 block-bootstrap CI is rejected")

check(
    not semantic_problems({"publication": []}, registry)
    and not semantic_problems({"publication": {"policy_version": "2"}}, registry),
    "semantic checker leaves malformed container rejection to JSON Schema",
)

print()
if failures:
    sys.exit(f"{failures} check(s) FAILED")
print("all schema contract checks passed")
