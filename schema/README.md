# Result schema and metric registry

The shared, OS-agnostic half of the metric-runner contract
([`../HARNESS-CONTRACT.md`](../HARNESS-CONTRACT.md)):

| File | Owns |
|---|---|
| [`result.v1.schema.json`](./result.v1.schema.json) | The one shape every result document has (JSON Schema draft 2020-12) |
| [`metrics.v1.json`](./metrics.v1.json) | Which metrics exist: id, unit, oracle, budget, cache states, sample policy, per-OS status |
| [`check.py`](./check.py) | Falsifiable contract check — schema validity, registry invariants, examples, negative controls |
| [`examples/`](./examples/) | Documents that MUST validate (currently: the real KEL-65 Windows session converted to v1) |

```bash
python3 schema/check.py   # from the repo root; requires jsonschema
```

## Versioning

- The **schema version** changes only by adding a new
  `result.vN.schema.json` file; existing documents keep validating against
  their own version. Never edit a shipped version's shape.
- The **registry version** (`registry_version`) bumps when an existing
  metric's id, unit, oracle, or budget changes. *Adding* a metric entry is
  backward-compatible and does not bump the version.
- Adding a metric or a framework never touches `result.vN.schema.json` —
  that is the design, and the scaling walkthroughs in `HARNESS-CONTRACT.md`
  §7 depend on it.

Metric ids, units, oracles, budgets, cache-state classes, sample policy, and
the 1.05 ratio regression rule are taken from Keld's research note
`docs/research/49-falsifiable-bench-and-test-ladder.md` (private repo). This
registry is the machine-readable encoding, not a second source of truth.
