# Metric-runner contract (v1)

Every OS harness in this repo implements **one interface** and emits **one
versioned result document**. The contract exists so that adding a framework is
one fixture folder plus one arm-registry line, adding a metric is one registry
entry plus one harness hook, and adding an OS is one `<os>/bench/` harness —
never a parallel result format.

This contract encodes the named metric contracts, cache-state classes, paired
bootstrap statistics, and >5% regression rule of Keld's research note
`docs/research/library/quality-evidence/49-falsifiable-bench-and-test-ladder.md`. It does not reinvent
them; when that note and this file disagree, fixing the disagreement is the
task.

## Top-priority gap, stated before any restructure

**Windows still has no committed `keld/` fixture.** macOS has
[`macos/keld/hello/`](./macos/keld/hello/), merged in PR #7, and Linux now has
[`linux/keld/hello/`](./linux/keld/hello/) plus the first contract-shaped Linux
harness. The remaining Windows gap is:

- The Windows harness measures Keld by splicing a beacon into
  `keld-wv` sources inside the private Keld repo at `-Prepare` time and
  building `keld-host.exe` there. No committed SHA in *this* repo reproduces
  the Keld arm.

First fixture work on Windows MUST be `windows/keld/hello/` (a committed build
recipe producing a Release artifact with bound provenance, following the KEL-64
`macos/keld/hello/build.sh` pattern), before any new Windows competitor arm or
metric lands. Correcting a historical table from an already-committed raw file
is not new fixture or metric work and does not make that pre-contract result
publication eligible.

## 1. Layout convention

```
schema/                          # OS-agnostic: result schema, metric registry, check
  result.v1.schema.json          #   frozen historical document shape
  result.v2.schema.json          #   current shape with module provenance
  metrics.v1.json                #   the one metric registry (versioned)
  check.py                       #   falsifiable contract check (run: python3 schema/check.py)
  examples/                      #   documents that MUST validate
{macos|windows|linux}/           # OS first, always
  bench/                         #   the ONE harness per OS (entry points + results)
    results/<metric-id>/         #   result documents, named per §4
  <framework>/<fixture>/         #   fixture sources (hello, notes, ...)
  keld/<fixture>/                #   Keld's own fixture — required, see gap above
  swift|winui|gtk4/              #   the OS's native floor (see §6)
```

Rules:

- OS-agnostic content at the root is limited to `schema/`, this file, and repo
  docs. Apps never live at the root (`README.md` rule, unchanged).
- One harness directory per OS, named `bench/`. The macOS KEL-64 harness
  currently lives at `macos/harness/` on its feature branch; on merge it is
  the macOS `bench/` implementation and SHOULD be moved or aliased to
  `macos/bench/` in that PR (path-only change, no logic change).
- Committed files never contain absolute paths, home directories, hostnames,
  or serials. Repo-relative paths only. (The pre-contract Windows result
  JSONs violate this with `D:\WORK\...` paths; see §5 migration.)

## 2. Harness interface

Each `{os}/bench/` harness exposes two verbs. The executable form is
OS-idiomatic (PowerShell on Windows, compiled Swift on macOS, shell/binary on
Linux) — the verbs, semantics, and output shape are not.

```
<harness> list-metrics
```

Prints a JSON array of the metric ids from `schema/metrics.v1.json` this
harness implements, with the registry version it read. A metric absent from
the registry MUST NOT be listed or run.

```
<harness> run --metric <ID> --fixture <path> --samples <N> \
              --cache-state <class> --out <file> [--publish]
```

- `--metric` — a registered id (e.g. `PAINT-OPPORTUNITY`, `MEM-IDLE`).
- `--fixture` — OS-qualified repo-relative fixture path per arm; repeatable.
- `--samples` — requested valid samples per arm. The registry's
  `sample_policy` states the publication minimum; fewer samples are allowed
  but force `publication.eligible = false` with reason `SAMPLES_BELOW_POLICY`.
- `--cache-state` — one of `boot-cold | fresh-process | warm-cache |
  renderer-warm`. One invocation = one class; harnesses MUST NOT pool classes.
- `--out` — result document path, outside the measured source tree.
- `--publish` — request publication assessment (see §3).

Exit codes (aligned with the macOS KEL-64 runner):

| Exit | Meaning |
|---|---|
| 0 | Measurement completed; document written |
| 2 | Measurement failure (missing artifact, oracle failure, cleanup failure) |
| 3 | `--publish` requested and the completed measurement fails publication policy |

Fail-closed invariants every implementation MUST keep (all exist today in at
least one OS harness; none may regress):

- One external monotonic clock armed **before** spawn; never in-process
  self-timing as the score.
- Beacons/oracles carry a nonce; missing, wrong, stale, duplicate, and
  wrong-phase signals reject the run with a recorded `reject_reason` — never
  a plausible number, never silent `0`/`null`-as-success.
- A timeout can only fail a run, never make one successful.
- Process cleanup is generation-bound (the harness proves the tree it kills is
  the tree it launched); memory is sampled only from the harness-owned
  tree/coalition, never a global process-name scan.
- Negative controls are committed next to the harness and runnable
  (`windows/bench/Test-Harness.ps1`, macOS `--self-test`). A harness change
  that cannot fail its own controls does not land.
- Condition-based waiting; a fixed sleep is accepted only where the
  pre-contract Windows harness already has one, and is a named migration item.

## 3. Result document

Every `run` emits one JSON document conforming to the file selected by its
integer `schema_version`. Current interpreted harnesses emit v2; immutable v1
documents continue to validate against frozen `schema/result.v1.schema.json`:

- **UTF-8 without BOM.** (Two of four committed pre-contract result files
  carry a PowerShell BOM and are rejected by strict JSON parsers.)
- One document = one metric × one OS × one machine × one cache-state class ×
  one session. Cross-session absolutes are not comparable — the KEL-65 tables
  in `MEASUREMENTS.md` demonstrate ~110 ms of cross-session drift on identical
  binaries.
- `arms[].samples[]` carries every raw run including rejected ones;
  `statistics` carries median / p90 / p99 (where sample count supports them)
  and a bootstrap 95% CI of the median — no normal-distribution assumption.
- `comparison` (optional) carries the paired candidate/baseline ratio CI and
  the `PASS | FAIL | INCONCLUSIVE` verdict against threshold 1.05 — the
  falsifiable form of Keld's >5% regression rule.
- `publication` is mandatory. `eligible: false` documents are valid
  diagnostics; they MUST NOT feed scoreboard `vs` cells. Publication requires,
  at minimum: registry sample policy met, balanced randomized interleaving by
  round, clean tree at an immutable `bench_sha`, Release artifacts with
  SHA-256, complete environment block, AC power / Low Power Mode off / nominal
  thermal state, and byte-identical canonical payload across arms
  (`provenance.payload_sha256`).
- `provenance.harness` names and hashes the entry point; interpreted harnesses
  also list and hash every imported measurement module in `modules`.
- Publication policy v2 makes that interpreted-module list mandatory before
  `eligible: true`. Immutable policy-v1 documents remain schema-valid; new or
  re-emitted interpreted-harness results use v2 and fail closed when module
  provenance is incomplete.

Validate any document with:

```bash
python3 schema/check.py          # schema + registry + examples + negative controls
python3 windows/bench/test_validate_result_v1.py  # version dispatch failure controls
```

Validate the historical medians published from the pre-contract Windows raw
files with the same percentile helper used by the harness:

```powershell
pwsh -NoProfile -File windows/bench/Test-Statistics.ps1
pwsh -NoProfile -File windows/bench/Test-Harness.ps1
pwsh -NoProfile -File windows/bench/Check-PublishedMeasurements.ps1
pwsh -NoProfile -File windows/bench/Test-PublishedMeasurements.ps1
```

The last command is the publication negative control: it mutates one temporary
Markdown cell and one temporary raw copy, and must observe the checker rejecting
both mismatches. The checker binds historical raw paths to their immutable Git
commit, blob, and SHA-256 before deriving any value. These are the repository's
documented check targets; this repository has no CI workflow.

## 4. Result naming

```
{os}/bench/results/<metric-id-lower>/<YYYY-MM-DD>.<label>.<cache-state>.json
```

Example:
`windows/bench/results/paint-opportunity/2026-08-15.kel65-direct-com.fresh-process.json`

- `<label>` is the kebab-case session label, also recorded at
  `session.label` inside the document.
- Result files are **immutable once committed**: a rerun is a new dated file,
  never an overwrite. This rule exists because the generic name
  `windows/bench/windows-first-paint.json` was silently overwritten by a later
  session (committed file: 2026-08-15, 7 runs, keld @ `f28d696…`) while
  `MEASUREMENTS.md` still cites it as the 2026-08-14 median-of-5 evidence.
  That published evidence is unrecoverable from `main`'s tip.
- Everything else (SHAs, OS build, hardware, engine, sample count) lives
  inside the document, not the filename.

## 5. Migration of pre-contract Windows results

`windows/bench/Measure-FirstPaint.ps1` measurement logic is correct
prior art and is **not rewritten** by this contract. The migration is
wrap-and-annotate, tracked in `windows/bench/CONTRACT.md`:

| Pre-contract | Contract |
|---|---|
| `-Arms keld,tauri,electron` | `--fixture` per arm from committed fixtures |
| `-Runs 5` | `--samples N` + registry publication minimum |
| implicit fresh-process | explicit `--cache-state` |
| `meta` + flat `samples[]`, BOM UTF-8 | versioned result document, UTF-8 no BOM |
| `windows-first-paint*.json`, overwritable | `results/paint-opportunity/<date>.<label>.<state>.json`, immutable |
| absolute `D:\WORK\...` exe paths in samples | `artifact.basename` + SHA-256 only |
| arm-by-arm execution | round-robin randomized interleaving for publication |

The four existing `windows/bench/windows-first-paint*.json` files stay where
they are as historical evidence (moving them would break `MEASUREMENTS.md`
links); they are superseded, not rewritten.
`schema/examples/paint-opportunity.fresh-process.example.json` is the KEL-65
direct-COM session converted to the v1 shape — with real sample values, real
computed bootstrap CIs, and `publication.eligible: false` carrying the exact
reasons the old harness cannot publish.

## 6. Native floor per OS

The native baseline answers "what does this OS charge for one window + one
system webview with no framework at all". It is a **fixture contract**, not an
implementation mandate — the apps land in their own PRs.

| OS | Path | Stack | Status |
|---|---|---|---|
| macOS | `macos/swift/appkit-wk/`, `macos/swift/swiftui-wk/` | AppKit / SwiftUI + WKWebView | sources committed, measured |
| Windows | `windows/winui/hello/` | Win32 (or WinUI 3) + WebView2 | contract committed, app absent |
| Linux | `linux/gtk4/hello/` | GTK4 + WebKitGTK | contract committed, app absent |

Each native fixture MUST: create one window, load the canonical hello payload
in the OS system webview, emit the standard double-rAF beacon with no
privileged instrumentation, build Release from a committed script, and stay in
the same webview lane as the OS's system-webview arms (WK on macOS, WebView2
on Windows, WebKitGTK on Linux). Native floors do not exist cross-OS: there is
deliberately no Swift under `windows/` or `linux/`.

## 7. Scaling walkthroughs

**Framework #7** (say Flutter, as a labeled diagnostic): create
`{os}/flutter/hello/` from the fixture template (sources + build recipe +
README), then add one arm entry to the OS harness's arm registry (for Windows
today: one hashtable entry in `Measure-FirstPaint.ps1`'s `$registry`; for the
contract wrapper: one `--fixture {os}/flutter/hello` argument). No schema
change, no harness logic change, no new result format. The new arm appears as
one more `arms[]` element in the same document.

**Metric #2** (say `MEM-IDLE` as a first-class scored run): add nothing to the
schema — the document shape is metric-agnostic. The registry entry already
exists (`schema/metrics.v1.json`); implement the metric hook behind the same
`run` verb in each OS harness that can support it, and let `list-metrics`
advertise it per OS. A brand-new metric is one registry entry + per-OS hooks;
no parallel harness, no `Measure-SecondThing.ps1`.

**OS #4** (say `freebsd/`): one new OS directory with `bench/` implementing
the two verbs against the same schema, fixture folders per framework, and a
native floor contract. `schema/` is untouched; existing OSes are untouched.

## 8. Keld-core hook (flagged, not implemented)

`IPC-RTT`, `IPC-BULK`, `BUN-READY`, and `CRASH-RECOVERY` cannot be measured
from launched fixtures alone: they need a Keld-side measurement surface (a
bench role or `keld-host` flag exposing spawn/HELLO/call timestamps on the
parent clock). That is a Keld-repo decision (KEL-86 territory, blocked on
KEL-30) and is deliberately **not** designed here. The registry entries exist
so the ids, units, and oracles are already agreed when that surface lands;
their `status` is `unmeasured`/`future` until then.
