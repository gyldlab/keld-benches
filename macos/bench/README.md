# macOS harness (contract slot)

This directory is the macOS implementation slot for the metric-runner
contract ([`../../HARNESS-CONTRACT.md`](../../HARNESS-CONTRACT.md)): the
`list-metrics` / `run` verbs, result documents conforming to
`schema/result.v1.schema.json`, and immutable result files under
`results/<metric-id>/`.

**The implementation already exists** — the KEL-64 Swift/AppKit runner
(`macos/harness/HarnessCore.swift` + `Runner.swift` on the
`agent/kel-64-startup-trace-*` branch line). It is a fresh-process double-rAF
paint-opportunity oracle with negative controls (`--self-test`),
coalition-based RSS, generation-bound cleanup, provenance-bound publication
policy, and exit codes 0/2/3 — this contract adopted its semantics rather than
the other way around.

When that branch merges, the runner belongs here (`macos/bench/`), and needs
only interface alignment, no logic change:

- expose `list-metrics` (it implements `PAINT-OPPORTUNITY` and the RSS
  observation feeding `MEM-IDLE`);
- accept `--metric` / `--cache-state` / `--samples` spellings alongside its
  current flags;
- emit `schema/result.v1.schema.json` documents (its `BenchmarkDocument` is a
  superset: schema version, samples, summaries, publication block already
  exist — the mapping is field renames plus the registry-owned metric id).

Until the merge, do not reimplement a macOS harness here; measure nothing on
macOS except through that runner.
