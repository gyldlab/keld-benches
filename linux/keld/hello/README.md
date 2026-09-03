# Keld hello — Linux

This is the first committed Linux Keld fixture. It builds the shipping
`keld-host` in Release mode from an immutable public Keld commit and
applies one benchmark-only adapter: `KELD_BENCH_URL` may replace the built-in
inline hello document with the harness's IPv4-loopback URL.

The adapter changes navigation only. Timing stays outside the process: the
Linux harness arms one monotonic clock before spawn and accepts only the
nonce-bound double-`requestAnimationFrame` image beacon emitted by
`index.html`. The normal binary behavior is unchanged when
`KELD_BENCH_URL` is absent.

This fixture measures the Linux `keld-host --hello` diagnostic window. It is
not the full no-flag app session: Linux `keld dev` still fails closed pending
KEL-96/T4. Results must keep that limitation in their session notes and must
not claim Bun readiness, app-link lifecycle, or application first paint.

## Build

Use a clean checkout of this repository and a local clone of canonical Keld.
The selected Keld SHA must be a full 40-character commit reachable from
`gyldlab/keld`; the recipe fetches that exact object from the sanitized
canonical HTTPS origin and verifies `FETCH_HEAD` before checkout. The commit
does not need to remain a moving branch head, so historical result recipes stay
rebuildable after `main` advances.

```bash
linux/keld/hello/build.sh \
  /path/to/keld \
  "$(git -C /path/to/keld rev-parse origin/main)" \
  "$PWD/linux/keld/hello/dist"
```

The output directory contains `keld-host-product` (unmodified Release host),
`keld-host-bench` (loopback-navigation adapter), and `provenance.json`. The
recipe refuses to overwrite it. Build products are ignored and binaries are
never committed.

## Measure

```bash
python3 linux/bench/run.py list-metrics
python3 linux/bench/run.py run \
  --metric PAINT-OPPORTUNITY \
  --fixture linux/keld/hello \
  --artifact-dir linux/keld/hello/dist \
  --samples 5 \
  --cache-state fresh-process \
  --out linux/bench/results/paint-opportunity/DATE.linux-keld.fresh-process.json
```

Five samples are diagnostic. Publication policy requires 30 valid samples,
a clean remotely advertised benchmark commit, verified power/thermal facts,
and every other policy condition recorded in the emitted document.
