# Linux metric runner

`run.py` is the Linux implementation of the repository-wide metric-runner
contract. It reads `schema/metrics.v1.json`, emits
`schema/result.v1.schema.json`, and currently implements:

- `PAINT-OPPORTUNITY`: external monotonic spawn-to-double-rAF image beacon for
  the `linux/keld/hello` WebKitGTK diagnostic window;
- `DISK`: exact bytes of the unpatched Release `keld-host` raw-binary lane.

The paint arm is intentionally `role: diagnostic`. Linux's KEL-96/T4 no-flag
application boot has not landed, so this measures `keld-host --hello`, not app
first paint, Bun readiness, or app-link lifecycle. The result always records
`DIAGNOSTIC_HELLO_ONLY` and cannot become a published scoreboard verdict by
collecting more samples.

## Build and run

Build the two provenance-bound artifacts first (unmodified product host and
loopback-navigation benchmark adapter):

```bash
linux/keld/hello/build.sh \
  /path/to/keld \
  "$(git -C /path/to/keld rev-parse origin/main)" \
  "$PWD/linux/keld/hello/dist"
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
- The page and beacon are bound to one random nonce. A stale nonce, malformed
  query, wrong phase, hidden/unfocused document, or duplicate beacon is
  rejected rather than converted into a plausible number.
- Each launch owns a fresh process group. `/proc/<pid>/stat` start ticks and a
  Linux pidfd bind cleanup to the spawned generation before the group is
  signalled.
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
silent-arm timeout, PID-generation mismatch, and descendant process cleanup.
