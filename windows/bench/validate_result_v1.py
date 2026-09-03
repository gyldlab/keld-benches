#!/usr/bin/env python3
"""Validate versioned result documents against their schema and the registry.

Exists because schema/check.py validates the schema and schema/examples/ but
never reads {os}/bench/results/ — a forged document with metric.id "not a real
metric", unit "unicorns", cache_state "lukewarm", bench_sha "main" and
publication.eligible=true with reasons:[] passes `python schema/check.py`
cleanly. A harness that writes a document must be able to prove the document
it just wrote is well-formed; Run-KipcEcho.ps1 already calls a checker,
Emit-Kel25Documents.ps1 previously did not.

Checks per document:
  1. JSON Schema Draft 2020-12 against schema/result.vN.schema.json selected
     from the document's integer schema_version
  2. no UTF-8 BOM (strict parsers reject it; PS 5.1 Set-Content -Encoding utf8
     emits one, which is how the older windows-first-paint*.json got theirs)
  3. metric.id is registered in schema/metrics.v1.json
  4. metric.unit equals the registry unit for that id
  5. cache_state is one the registry allows for that metric
  6. statistics.valid_samples equals the number of samples with valid=true
  7. statistics.median recomputes from the valid samples (numeric metrics)

Exit 0 = all pass. Exit 2 = at least one failed. Exit 3 = usage/setup error.
"""
import json
import os
import sys

try:
    from jsonschema import Draft202012Validator
except ImportError:
    print("FATAL: python module 'jsonschema' is required", file=sys.stderr)
    sys.exit(3)


def median(values):
    s = sorted(values)
    n = len(s)
    if n == 0:
        return None
    if n % 2 == 1:
        return float(s[n // 2])
    return float((s[n // 2 - 1] + s[n // 2]) / 2)


def main(argv):
    if len(argv) < 3:
        print("usage: validate_result_v1.py <repo-root> <document.json> [more...]", file=sys.stderr)
        return 3
    root = argv[1]
    sys.path.insert(0, os.path.join(root, 'schema'))
    from result_contract import semantic_problems

    with open(os.path.join(root, 'schema', 'metrics.v1.json'), encoding='utf-8') as registry_file:
        registry = json.load(registry_file)
    known = {m['id']: m for m in registry['metrics']}
    validators = {}

    failures = 0
    for path in argv[2:]:
        name = os.path.basename(path)
        problems = []
        with open(path, 'rb') as document_file:
            raw = document_file.read()
        if raw[:3] == b'\xef\xbb\xbf':
            problems.append("file starts with a UTF-8 BOM")
        # `json.loads` accepts the bare literals NaN, Infinity and -Infinity as
        # an extension. They are not JSON (RFC 8259 has no non-finite numbers),
        # and once parsed they reach the schema as Python floats that satisfy
        # `"type": "number"`, while every numeric comparison against NaN returns
        # False -- so a document carrying `"median": NaN` would pass both the
        # schema and the range checks and be declared publishable. Refuse them
        # at the parse boundary, where the reason is still legible.
        def _reject_constant(literal: str) -> None:
            raise ValueError(
                f"{literal} is not JSON: RFC 8259 has no non-finite numbers, "
                "and it would satisfy the schema while defeating every "
                "numeric check"
            )

        try:
            doc = json.loads(raw.decode('utf-8'), parse_constant=_reject_constant)
        except Exception as exc:
            print(f"FAIL {name}: not valid UTF-8 JSON: {exc}")
            failures += 1
            continue

        # A result document is a JSON object. Raw sample sidecars (*.raw.json)
        # are arrays, and passing one used to raise AttributeError deep in the
        # metric checks instead of being rejected. A crash is not a verdict:
        # it tells the caller nothing about whether the file is publishable,
        # and a traceback in a validation gate reads as tooling breakage rather
        # than as the refusal it actually is. Reject it here, with the reason.
        if not isinstance(doc, dict):
            print(f"FAIL {name}: top level is {type(doc).__name__}, not a result "
                  f"object (raw sample sidecars are not result documents)")
            failures += 1
            continue

        schema_version = doc.get('schema_version')
        if not isinstance(schema_version, int) or isinstance(schema_version, bool):
            problems.append(f"schema_version {schema_version!r} is not an integer")
            validator = None
        else:
            schema_path = os.path.join(
                root, 'schema', f'result.v{schema_version}.schema.json')
            if not os.path.isfile(schema_path):
                problems.append(
                    f"schema_version {schema_version} has no {os.path.basename(schema_path)}")
                validator = None
            else:
                if schema_version not in validators:
                    with open(schema_path, encoding='utf-8') as schema_file:
                        versioned_schema = json.load(schema_file)
                    Draft202012Validator.check_schema(versioned_schema)
                    validators[schema_version] = Draft202012Validator(versioned_schema)
                validator = validators[schema_version]

        if validator is None:
            failures += 1
            print(f"FAIL {name}")
            for problem in problems:
                print(f"       - {problem}")
            continue

        for err in sorted(validator.iter_errors(doc), key=lambda e: list(e.path)):
            problems.append(f"schema: {list(err.path)}: {err.message}")
        problems.extend(f"semantic: {problem}" for problem in semantic_problems(doc))

        metric_value = doc.get('metric', {})
        metric = metric_value if isinstance(metric_value, dict) else {}
        mid = metric.get('id')
        if mid not in known:
            problems.append(f"metric.id {mid!r} is not in schema/metrics.v1.json")
        else:
            spec = known[mid]
            if metric.get('unit') != spec['unit']:
                problems.append(
                    f"metric.unit {metric.get('unit')!r} != registry unit {spec['unit']!r}")
            if doc.get('cache_state') not in spec['cache_states']:
                problems.append(
                    f"cache_state {doc.get('cache_state')!r} not allowed for {mid} "
                    f"(registry allows {spec['cache_states']})")

        arms_value = doc.get('arms', [])
        arms = arms_value if isinstance(arms_value, list) else []
        for arm in arms:
            if not isinstance(arm, dict):
                continue
            aid = arm.get('arm_id', '?')
            samples = arm.get('samples', [])
            stats = arm.get('statistics', {})
            samples = samples if isinstance(samples, list) else []
            stats = stats if isinstance(stats, dict) else {}
            samples = [sample for sample in samples if isinstance(sample, dict)]
            valid = [s for s in samples if s.get('valid')]
            if stats.get('valid_samples') != len(valid):
                problems.append(
                    f"arm {aid}: statistics.valid_samples={stats.get('valid_samples')} "
                    f"but {len(valid)} samples have valid=true")
            nums = [s['value'] for s in valid
                    if isinstance(s.get('value'), (int, float)) and not isinstance(s.get('value'), bool)]
            median_value = stats.get('median')
            numeric_median = (
                isinstance(median_value, (int, float))
                and not isinstance(median_value, bool)
            )
            if nums and numeric_median:
                recomputed = median(nums)
                if abs(recomputed - float(median_value)) > 1e-6:
                    problems.append(
                        f"arm {aid}: statistics.median={median_value} does not recompute "
                        f"from valid samples (got {recomputed})")

        if problems:
            failures += 1
            print(f"FAIL {name}")
            for p in problems:
                print(f"       - {p}")
        else:
            print(f"ok   {name}")

    if failures:
        print(f"\n{failures} document(s) failed validation")
        return 2
    print(f"\nall {len(argv) - 2} document(s) valid")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
