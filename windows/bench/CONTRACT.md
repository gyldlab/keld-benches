# Windows harness — contract annotation

`Measure-FirstPaint.ps1` predates the metric-runner contract
([`../../HARNESS-CONTRACT.md`](../../HARNESS-CONTRACT.md)). Its measurement
logic — external clock armed before spawn, image-beacon oracle, fail-closed
nonce, descendant-tree RSS, negative controls in `Test-Harness.ps1` — is
correct prior art and MUST NOT be rewritten to satisfy the contract. The
migration is a thin wrapper plus these annotations.

## Interface mapping

| Contract | Today (`Measure-FirstPaint.ps1`) | Wrapper obligation |
|---|---|---|
| `list-metrics` | none | emit `["PAINT-OPPORTUNITY"]` + registry version |
| `run --metric PAINT-OPPORTUNITY` | implicit (only metric) | reject other ids until implemented |
| `--fixture <os>/<framework>/<fixture>` | `-Arms keld,tauri,electron` + hardcoded `$registry` paths | map fixtures to arms; fail on unknown |
| `--samples N` | `-Runs N` | pass through; mark `SAMPLES_BELOW_POLICY` under 30 |
| `--cache-state <class>` | implicit fresh-process (previous tree killed, OS caches uncontrolled) | only `fresh-process` is truthful today; reject others |
| `--out <file>` | `-OutFile` | convert to `schema/result.v1.schema.json`, **UTF-8 no BOM**, write under `results/paint-opportunity/` per contract §4 |
| `--publish` | none | always `eligible: false` until the blockers below fall |
| exit 0/2/3 | `throw` on failure | map |

## Known contract violations to annotate, not hide

These are properties of the current script; the wrapper records them as
publication reason codes instead of papering over them:

1. **`PRE_CONTRACT_HARNESS`** — output is `meta` + flat `samples[]`, written
   with `Set-Content -Encoding utf8` (PowerShell 5.1 = **BOM**, which strict
   JSON parsers reject; the script's own comments call out the same BOM trap
   for source files). Samples embed absolute `D:\WORK\...` paths, and
   `-KeldRepo`/`-BenchRepo` default to machine-specific `D:\` paths.
2. **`ARMS_NOT_INTERLEAVED`** — arms run sequentially; the contract requires
   balanced randomized interleaving by round for publication.
3. **`SOURCE_TREE_PATCHED`** — `-Prepare` splices the beacon into Keld's
   `keld-wv` sources and fixture HTML, so no committed SHA reproduces the
   measured binaries. The root fix is a committed `windows/keld/hello/` fixture
   with a build recipe (contract top-priority gap), mirroring
   `macos/keld/hello/build.sh` on the KEL-64 branch.
4. **Fixed sleeps** — 4 s RSS settle and 2 s between runs are sleeps, not
   awaited conditions. Replacing them with condition-based stability (as the
   macOS runner's 500 ms bounded-drift rule does) is a harness change with its
   own negative control, out of scope for the wrapper.
5. **Session-scoped nonce** — already documented honestly in the script
   header; a per-launch nonce needs runtime-loaded content (the committed
   fixture, again).

## Result files in this directory

Pre-contract, immutable history — do not extend this set:

| File | Session | Note |
|---|---|---|
| `windows-first-paint.json` | 2026-08-15, 7 runs, keld @ `f28d696` | **Overwritten evidence**: `MEASUREMENTS.md` cites this filename as the 2026-08-14 median-of-5 session, whose raw data is no longer at `main`'s tip. This is the incident that made contract §4 result names immutable. |
| `windows-first-paint-kel65-baseline.json` | 2026-08-15 A/B baseline (wry) | BOM |
| `windows-first-paint-kel65-direct-com.json` | 2026-08-15 A/B candidate | BOM; converted to the v1 example at `schema/examples/` |
| `windows-first-paint-kel66-smartscreen-off.json` | 2026-08-15 isolation run | keld arm only |

New sessions write contract-named documents under
`results/paint-opportunity/` and never reuse a filename.
