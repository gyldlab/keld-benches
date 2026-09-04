# Linux metric runner

`run.py` is the Linux implementation of the repository-wide metric-runner
contract. It reads `schema/metrics.v1.json`, emits
`schema/result.v2.schema.json`, and currently implements:

- `PAINT-OPPORTUNITY`: external monotonic spawn-to-double-rAF image beacon for
  the `linux/keld/hello` WebKitGTK diagnostic window, either alone or paired
  round-by-round with the `linux/gtk4/hello` native floor;
- `MEM-IDLE`: Keld main RSS after the same paint beacon and a stable,
  generation-identical process census, with helpers/tree/private dirty kept as
  separate diagnostics;
- `DISK`: exact bytes of the unpatched Release `keld-host` raw-binary lane.

The Keld paint arm is intentionally `role: diagnostic`. Linux's KEL-96/T4
no-flag application boot has landed, but this harness still measures the
declared `keld-host --hello` benchmark adapter—not app first paint, Bun
readiness, or app-link lifecycle. The result always records
`DIAGNOSTIC_HELLO_ONLY` and cannot become a published scoreboard verdict by
collecting more samples. A paired native arm adds a within-session ratio but
does not promote that diagnostic into a product claim.

`MEM-IDLE` also uses the loopback-navigation adapter so the harness can prove
content readiness before sampling. It is diagnostic rather than an unmodified
product score; `DISK` alone reads the separate unpatched Release artifact.

## Build and run

Build the two provenance-bound artifacts first (unmodified product host and
loopback-navigation benchmark adapter):

```bash
linux/keld/hello/build.sh \
  /path/to/keld \
  "$(git -C /path/to/keld rev-parse origin/main)" \
  "$PWD/linux/keld/hello/dist"
```

Build the landed GTK4/WebKitGTK 6.0 native fixture separately:

```bash
linux/gtk4/hello/build.sh "$PWD/linux/gtk4/hello/dist"
```

List the metrics this OS harness implements:

```bash
python3 linux/bench/run.py list-metrics
```

Run a diagnostic paint session:

```bash
python3 linux/bench/run.py run \
  --metric PAINT-OPPORTUNITY \
  --fixture linux/keld/hello \
  --artifact-dir linux/keld/hello/dist \
  --samples 5 \
  --cache-state fresh-process \
  --out linux/bench/results/paint-opportunity/DATE.linux-keld.fresh-process.json
```

Run the Keld adapter and GTK4 native floor in balanced randomized paired
rounds. Each `--artifact-dir` maps positionally to the preceding fixture list;
the harness rejects count mismatches, duplicates, unknown fixtures, and
provenance swaps before measurement:

```bash
python3 linux/bench/run.py run \
  --metric PAINT-OPPORTUNITY \
  --fixture linux/keld/hello \
  --artifact-dir linux/keld/hello/dist \
  --fixture linux/gtk4/hello \
  --artifact-dir linux/gtk4/hello/dist \
  --samples 30 \
  --cache-state fresh-process \
  --label linux-keld-vs-gtk4 \
  --out linux/bench/results/paint-opportunity/DATE.linux-keld-vs-gtk4.fresh-process.json
```

Measure idle memory after paint and stability:

```bash
python3 linux/bench/run.py run \
  --metric MEM-IDLE \
  --fixture linux/keld/hello \
  --artifact-dir linux/keld/hello/dist \
  --samples 5 \
  --cache-state fresh-process \
  --label linux-keld-memory \
  --out linux/bench/results/mem-idle/DATE.linux-keld-memory.fresh-process.json
```

Measure the raw production host binary:

```bash
python3 linux/bench/run.py run \
  --metric DISK \
  --fixture linux/keld/hello \
  --artifact-dir linux/keld/hello/dist \
  --samples 1 \
  --cache-state fresh-process \
  --label linux-keld-host \
  --out linux/bench/results/disk/DATE.linux-keld-host.fresh-process.json
```

Output paths are immutable and must live directly under the metric's results
directory. A diagnostic run may use a local commit, but `--publish` exits 3
unless every publication condition passes. Result provenance never records an
absolute source or artifact path.

## Observable contracts

- One IPv4-loopback listener binds port `0`; the external monotonic clock is
  armed before process spawn.
- Paired paint runs execute each arm exactly once per round. Within every
  complete two-round block, each arm runs first once; the first order is
  randomized. Samples retain their round and position, and the comparison
  bootstraps matched per-round Keld/native ratios rather than pooling arms. If
  either arm rejects a requested round, the result retains every sample, exits
  `2`, and omits the comparison instead of deleting the failed pair.
- The page and beacon are bound to one random nonce. A stale nonce, malformed
  query, wrong phase, hidden/unfocused document, or duplicate beacon is
  rejected rather than converted into a plausible number.
- Each launch owns a fresh process group. `/proc/<pid>/stat` start ticks and a
  Linux pidfd bind cleanup to the spawned generation before the group is
  signalled.
- Memory succeeds only after four identical PID/start-time/class censuses with
  at least one WebKit process and at most 1% drift in both main and total-tree
  RSS. Main RSS is the metric value; helper RSS, total RSS, and main/helper/total
  private dirty are diagnostics.
- The environment block records distro/kernel, CPU/RAM, WebKitGTK version,
  power profile, and X11/Wayland/desktop facts. Thermal state remains
  `unverified` unless an independent Linux probe is added later.

Run the negative controls and shared schema checks:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 linux/bench/test_harness.py
python3 schema/check.py
```

The negative controls cover template port/nonce substitution, stale nonce,
single-rAF, malformed query, hidden/unfocused document, duplicate beacon,
silent-arm timeout, PID-generation mismatch, descendant process cleanup,
missing WebKit membership, generation churn, and excessive RSS drift.
