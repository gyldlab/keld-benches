# Real-application performance and diagnostics — proposed KEL-90 extension

**Status:** proposal for review; no new runner, metric ID, debug privilege, publication authority, or performance result is implemented by this document.

**Ownership:** [KEL-90](https://linear.app/gyldlab-keld/issue/KEL-90/bench-cross-os-metric-runner-standard-native-baselines-winuigtk4-keld) owns the single cross-OS benchmark runner, registry, and matched application measurements; [KEL-129](https://linear.app/gyldlab-keld/issue/KEL-129/perfmacos-decide-which-product-budgets-are-physically-achievable) owns budget semantics; [KEL-64](https://linear.app/gyldlab-keld/issue/KEL-64/perfmacos-reproducible-first-paint-and-process-tree-rss-oracle) owns the macOS paint/memory runner. The [macOS reproducibility tracker](https://github.com/gyldlab/keld/issues/180) already requires provenance and process census. KELD product-corpus correctness has its own owners (including [GH-587](https://github.com/gyldlab/keld/issues/587)); this proposal does not replace those oracles.

## Decision and boundaries

Extend the existing OS-qualified harness defined in [HARNESS-CONTRACT.md](../../HARNESS-CONTRACT.md), not a second benchmark program or an always-running in-app dashboard. A new application is an OS-qualified, immutable **fixture** plus its correctly reproduced workflow. A new measurement is a registry-owned metric plus an OS harness hook, not an unregistered score. Keep developer diagnostics separate from externally timed, publication-eligible runs.

A normal KELD application must not acquire new OS observation, process-enumeration, IPC, or privileged filesystem authority. Product-side instrumentation, if later approved in the KELD repository, is **off by default, developer-only, local, redacted, bounded, read-only**, and unavailable to the renderer or release application. No persistent background agent or HTTP listener is required.

### Ownership of answers

| Question | Owner and source of truth | Can it determine a published score? |
|---|---|---|
| When was the window painted? | External OS harness, one pre-spawn monotonic clock, nonce-bound paint oracle | Only under its registered metric |
| How much memory was resident? | OS-owned process census + named RSS counter | Only the registered denominator; coalition diagnostic stays separate |
| How much memory is charged on macOS? | OS footprint tool and independently attributed process/service coalition | Not until a separately approved metric and macOS admission rule exist |
| How much CPU time elapsed? | OS monotonic per-process counters and matched sampling window | Not until its metric is registered and qualified |
| What was KELD doing then? | Optional structured KELD lifecycle/IPC events | **No.** Attribution hints only; never a competing clock, score, or process authority |
| Did the app do equivalent work? | App-specific independent correctness oracle with immutable payload | Required gate before any comparative score |

## Reusable application fixture

A real-application fixture MUST identify, at minimum:

1. **Application and mode:** exact draw.io/other app version, Electron release mode or KELD Bun-primary + system webview, OS/architecture, security configuration, and build class (developer-staged versus installed/release).
2. **Provenance:** immutable source commit or licensed artifact version, executable SHA-256, worktree cleanliness and build recipe. A reference to a local installed app alone does not make the run reproducible.
3. **Workload:** input document bytes and SHA-256; same semantic operations, viewport, zoom/display scaling, open windows, saved state, and expected output across arms. If the app requires a proprietary or private input, use an appropriately licensed synthetic document with independently verified equivalence.
4. **Operations and independently observed completion:** launch, ready-to-interact, open, edit, save, fresh-process reopen, dirty-close Cancel, dirty-quit Cancel, Discard, clean Quit and teardown, **only** if the app actually supports those behaviors. Record passed, failed, unsupported, and unrun separately.
5. **Timing phases:** startup, stabilized idle, active workload and post-close. Each metric uses the stage, cache class, clock and condition-based stability policy that its registry entry defines. Do not pool idle and active or boot-cold and fresh-process data.
6. **Lifecycle:** exact launch-session identity; expected first-party and engine-helper process/service set; stable association proof; teardown receipt and absence of residual session-owned processes.
7. **Comparator admission:** correctness and security pass *before* a performance pair is admitted. Crashes, wrong zoom/geometry affecting workload, unsupported APIs, missing resources, mismatched payloads, unqualified helpers or incomplete teardown invalidate comparison.

The implementation of a new fixture belongs under the existing {os}/{framework}/{fixture}/ convention. Documentation alone does not constitute a runnable fixture; an arm is unavailable until its complete sources/artifact recipe, oracle and negative controls exist.

## A single measurement path, two observation modes

**Scored mode (external):** the harness launches one arm, proves workload and process identity, samples the registered OS counters, validates completion and cleanup, and writes the existing version-selected result document. Detailed KELD tracing is disabled. The harness never trusts self-reported application timings as an external score.

**Diagnostic mode (unscored):** repeat a comparable scenario with explicitly enabled local, bounded structured KELD events. Collect independent OS samples at the same time. Join timelines only using a proved clock-domain mapping with uncertainty bounds; reject missing/stale mappings instead of pretending two timestamps match. Event labels contain only role, process *instance*, window/document generation, phase, monotonic time and sanitized error class. No document content, URLs, auth tokens, user paths or IPC payloads.

Diagnostic data may suggest which phase coincided with memory growth; temporal correlation is not a demonstrated root cause. A native allocations profile or controlled intervention is needed before attributing a leak, cache or GPU allocation.

### Process attribution on macOS

The draw.io pilot found WebKit GPU/Networking/WebContent services associated with the KELD session but outside a simple Host/Bun child tree. The production measurement contract therefore requires **independent OS association evidence for every included service** and a stable launch-generation identity. PID or process name by itself cannot grant inclusion; PID reuse, shared services, foreign processes, missing expected services and duplicate attribution invalidate full-coalition claims. Never use a global process-name scan as an attribution oracle.

For each qualified process record retain a non-sensitive process-instance identity, role, observation timestamp, association method, RSS counter and any available private/dirty/footprint counter. Mark counters missing when an OS API cannot provide them. Avoid adding summed RSS to footprint or describing RSS totals as unique physical RAM; macOS footprint is a different ledger and any additive per-service aggregation must be separately validated. Process-count observations must state which roles/helpers are included and whether the census is complete.

### Reports and admissibility

Reuse the **one** metric registry (schema/metrics.v1.json) and existing result.vN schema. Do not change the meaning or budget of MEM-IDLE, whose scored denominator is currently the named KELD-host RSS lane. Until independently specified and implemented, physical footprint, CPU idle, full-coalition memory and process count are **diagnostics, not scored metric IDs**. A future new metric is admitted by a separate registry-owner review with oracle, units, OS counter semantics, sample policy, negative controls and per-OS hook; do not invent a competing result format.

Store original samples and checksums with session provenance. A report must distinguish OBSERVED, INFERRED, INVALID, and NOT MEASURED, and display n, median, distribution, confidence interval and publication eligibility. For GUI/memory publication, honor the existing minimum of 30 balanced independent paired launches per cache class; one 30-second time series within one session is **one** independent session, not 30 launches. Publish no advantage based on a developer build versus an installed release, differently zoomed content, unqualified process coalition, failed correctness, tracer-enabled score or missing thermal/power qualification.

## Draw.io 32.6.1 motivating diagnostic (NOT a benchmark result)

Prior **single-session** macOS M4 pilot, as described in the working-session report, observed:

| Counter / census | Electron | KELD | Status |
|---|---:|---:|---|
| Sum of sampled process RSS | 341.0 MiB | 283.1 MiB | Exploratory; shared pages may be counted repeatedly |
| macOS reported footprint | 234.5 MiB | 406.2 MiB | Exploratory; full attribution and additive semantics not qualified |
| Counted core/helper processes | 4 core | 3 core + 6 associated WebKit | Different census categories; do not compare as an equivalent total |

Historical workflow receipts describe successful 32.6.1 native Open/Edit/Save/Reopen/Cancel/Discard/Quit, but they were not newly re-qualified for this proposal. The KELD arm was developer-staged; the Electron arm was an installed app; diagram effective zoom did not match. **No RAM saving, CPU win, startup win, release qualification or public performance verdict follows.** Earlier 31.7.0 evidence remains a separate version/cohort.

## Ordered implementation slices (not authorized as completed by this document)

**A. App correctness fixture, KEL-90 + existing draw.io corpus owners.** Land a pinned, licensed synthetic draw.io workload, exact-input SHA, Electron/KELD build recipes, native UI/admission oracle and teardown. Do not copy or modify someone else's app-corpus acceptance code. Negative controls: corrupt payload hash; wrong zoom; failed save/reopen; Cancel closes; residual process; missing role.

**B. macOS process and OS counter census, KEL-64 owner.** Extend the existing macOS harness only after its owning runner is available on the target branch. Qualify first-party Host/Guardian/Bun and external WebKit helpers with identity and lifecycle proofs. Separately record RSS, private/dirty/footprint where supported, CPU counters, counter availability and process counts by role. Negative controls: reused PID, foreign shared helper, unlinked WebKit process, duplicate included role, disappearing helper, unsupported footprint aggregation, counter regression and incomplete cleanup.

**C. KELD internal diagnostic events, new approved KELD-side spec/owner.** Capture bounded, read-only lifecycle/role/IPC phase metadata. Prove no renderer privilege, no new socket, no credential/path/content logging, no work on ordinary release starts, no deadline inflation and no hot-path blocking. Negative controls: malformed event, secret-like payload, stale document generation, queue flood, disabled-release probe.

**D. Existing result contract and analysis, KEL-90.** Add any *demonstrated* new metric to the registry with its oracle and tests. Extend the owning harness's run/list-metrics verbs; generate one metric/session/cache-state result under the existing schema. Use trace-enabled runs for diagnosis only. Negative controls: incorrect denominator, missing source SHA, mixed cache classes, below-minimum sample count, invalid work pair, wrong stage and tracing-enabled publication.

**E. Repeated draw.io pilot then next app.** Re-run equivalent draw.io 32.6.1 release-grade arms with matched zoom, 30+ independently qualified pairs, and secure teardown before considering public comparisons. Reuse the same registry, harness and report contract for a second app by adding only its fixture and workload oracle—not a second collector.

## Stop conditions

Do not call the system implemented because this specification exists. Do not start additional GUI runs on the reported Mac while free space is critically low or while another native owner has exclusive custody; check actual current disk and process state first. Do not add the unmerged macOS runner again: macos/bench/README.md reserves that owner. Do not merge draft work, alter KELD security policy, invent an inspector privilege, publish metrics, or convert exploratory draw.io numbers into product claims without independent approval and OS evidence.

**Acceptance for this proposal:** owner review agrees on one reusable fixture boundary, one macOS harness owner, independent KELD diagnostic ownership, exact counter semantics and falsifiable controls. Subsequent code PRs, CI checks and real-Mac receipts close the slices separately.
