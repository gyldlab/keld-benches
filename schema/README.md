# Result schema and metric registry

The shared, OS-agnostic half of the metric-runner contract
([`../HARNESS-CONTRACT.md`](../HARNESS-CONTRACT.md)):

| File | Owns |
|---|---|
| [`result.v1.schema.json`](./result.v1.schema.json) | Frozen historical result shape (JSON Schema draft 2020-12) |
| [`result.v2.schema.json`](./result.v2.schema.json) | Current shape: normalized harness paths and interpreted-module provenance |
| [`metrics.v1.json`](./metrics.v1.json) | Which metrics exist: id, unit, oracle, budget, cache states, sample policy, per-OS status |
| [`result_contract.py`](./result_contract.py) | Cross-field semantic policy that JSON Schema cannot express |
| [`check.py`](./check.py) | Falsifiable contract check — every schema version, registry invariants, examples, semantic checks, negative controls |
| [`examples/`](./examples/) | Documents that MUST validate (currently: the real KEL-65 Windows session converted to v1) |

```bash
python3 schema/check.py   # from the repo root; requires jsonschema
```

## Versioning

- The **schema version** changes only by adding a new
  `result.vN.schema.json` file; existing documents keep validating against
  their own version. Never edit a shipped version's shape.
- Version 2 adds complete interpreted-harness module provenance and requires an
  exact module entry matching the top-level harness path/hash before policy-v2
  results may set `publication.eligible: true`. Policy-v1/v1 documents remain
  unchanged.
- The **registry version** (`registry_version`) bumps when an existing
  metric's id, unit, oracle, or budget changes. *Adding* a metric entry is
  backward-compatible and does not bump the version.
- Adding a metric or a framework never touches `result.vN.schema.json` —
  that is the design, and the scaling walkthroughs in `HARNESS-CONTRACT.md`
  §7 depend on it.

Metric ids, units, oracles, budgets, cache-state classes, sample policy, and
the 1.05 ratio regression rule are taken from Keld's research note
`docs/research/library/quality-evidence/49-falsifiable-bench-and-test-ladder.md` (private repo). This
registry is the machine-readable encoding, not a second source of truth.
