#!/usr/bin/env python3
"""Validate result.v1 documents against the schema AND the metric registry.

Exists because schema/check.py validates the schema and schema/examples/ but
never reads {os}/bench/results/ — a forged document with metric.id "not a real
metric", unit "unicorns", cache_state "lukewarm", bench_sha "main" and
publication.eligible=true with reasons:[] passes `python schema/check.py`
cleanly. A harness that writes a document must be able to prove the document
it just wrote is well-formed; Run-KipcEcho.ps1 already calls a checker,
Emit-Kel25Documents.ps1 previously did not.

Checks per document:
  1. JSON Schema Draft 2020-12 against schema/result.v1.schema.json
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
    schema = json.load(open(os.path.join(root, 'schema', 'result.v1.schema.json'), encoding='utf-8'))
    registry = json.load(open(os.path.join(root, 'schema', 'metrics.v1.json'), encoding='utf-8'))
    known = {m['id']: m for m in registry['metrics']}
    validator = Draft202012Validator(schema)

    failures = 0
    for path in argv[2:]:
        name = os.path.basename(path)
        problems = []
        raw = open(path, 'rb').read()
        if raw[:3] == b'\xef\xbb\xbf':
            problems.append("file starts with a UTF-8 BOM")
        try:
            doc = json.loads(raw.decode('utf-8'))
        except Exception as exc:
            print(f"FAIL {name}: not valid UTF-8 JSON: {exc}")
            failures += 1
            continue

        for err in sorted(validator.iter_errors(doc), key=lambda e: list(e.path)):
            problems.append(f"schema: {list(err.path)}: {err.message}")

        metric = doc.get('metric', {})
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

        for arm in doc.get('arms', []):
            aid = arm.get('arm_id', '?')
            samples = arm.get('samples', [])
            stats = arm.get('statistics', {})
            valid = [s for s in samples if s.get('valid')]
            if stats.get('valid_samples') != len(valid):
                problems.append(
                    f"arm {aid}: statistics.valid_samples={stats.get('valid_samples')} "
                    f"but {len(valid)} samples have valid=true")
            nums = [s['value'] for s in valid
                    if isinstance(s.get('value'), (int, float)) and not isinstance(s.get('value'), bool)]
            if nums and stats.get('median') is not None:
                recomputed = median(nums)
                if abs(recomputed - float(stats['median'])) > 1e-6:
                    problems.append(
                        f"arm {aid}: statistics.median={stats['median']} does not recompute "
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
