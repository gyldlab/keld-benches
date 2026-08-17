# macOS external benchmark oracle

This dependency-free Swift/AppKit runner launches real `.app` bundles through
`NSWorkspace.openApplication`. It measures a **fresh-process double-rAF paint-
opportunity proxy** on one monotonic clock. It does not claim compositor
completion, display scanout, or cold-cache time.

The server binds `127.0.0.1:0`. Every run gets a random UUID in its URL and
minimal benchmark environment. The server accepts one canonical HTML load
and one `phase=double-raf` beacon; missing, wrong, stale, duplicate, and
single-rAF tokens are rejected. A deadline can only fail a run—it never makes
one successful. `NSWorkspace.openApplication` has no cancellation or ownership
handle before its callback. If that callback misses the deadline, the harness
quarantines instead of emitting output until LaunchServices returns an app to
clean up or an authoritative launch error; abandoning the callback could leak a
late-launched app.

Inputs are trusted benchmark fixtures, not hostile executables. A fixture MUST
keep its registered root process alive through the `openApplication` callback
and until harness cleanup. Public LaunchServices exposes no PID, ASN,
cancelation handle, or coalition before that boundary: a program that spawns a
raw child and exits before registration can leave an uncorrelatable process.
When callback ownership cannot be captured, the harness emits no JSON/output,
prints an operator-remediation error, and aborts every later arm. It cannot
truthfully claim containment for that pre-callback behavior.

RSS is a complete resource-coalition member sum from one bracketed `ps` RSS
observation:

1. retain the PID returned by `NSWorkspace` as the coalition root and record
   LaunchServices `originalPid` without replacing it; bind any returned launcher
   PID to its kernel process generation before comparing its resource coalition;
   an unavailable, dead, or different-coalition launcher handoff rejects the arm
   because its full memory cannot be proved by this contract;
2. at the launch callback, bind the returned PID's 64-bit kernel process unique
   ID to its resource-coalition ID without starting a subprocess; after the
   beacon, independently verify the same ID through `launchctl print pid/PID`;
3. enumerate that coalition directly with libSystem's exported
   `coalition_info_pid_list` symbol;
4. bracket one `ps ... rss` observation with kernel member lists, process unique
   IDs, and the coalition's monotonic tasks-started/tasks-exited counters,
   rejecting membership churn, even an ABA join-and-exit, and PID reuse; then
   classify and sum every member's RSS;
5. accept RSS only after unchanged membership and bounded RSS drift persist for
   at least 500 ms.

The coalition PID-list/resource-usage symbols and process-info flavors 17 and 20
are exported by the macOS runtime but have no public SDK contract. The harness
fails explicitly if the running OS cannot provide the required behavior; it
never falls back to descendant trees, process names, or partial same-UID scans.
Cleanup repeatedly enumerates the captured coalition and uses
`proc_signal_with_audittoken` with the kernel PID generation to prevent a
recycled PID from redirecting `SIGKILL`. It stops only after the original root
generation is gone and the coalition is empty.

`footprint` is deliberately not used: `footprint -t` follows descendants and
reports physical footprint, neither of which is the resource-coalition RSS
contract.

## Build and self-test

```bash
mkdir -p macos/harness/.build
xcrun swiftc -O -parse-as-library \
  -strict-concurrency=complete -warn-concurrency -warnings-as-errors \
  -o macos/harness/.build/keld-macos-bench \
  macos/harness/HarnessCore.swift macos/harness/Runner.swift
macos/harness/.build/keld-macos-bench --self-test
```

The self-test exercises the real port-zero server and proves missing, wrong,
stale, duplicate, and wrong-phase requests cannot complete a run. It mutates the
accepted Keld AC1 four-stage record and proves a wrong nonce, duplicate stage,
omitted stage, or non-monotonic timestamp is a typed startup-trace measurement
failure; accepting that defect fails the test, and the external beacon path
must not publish the trace. A missing, unreadable, or pre-existing reserved
path is a typed measurement failure and must not consume a previous arm's
record. It also tests
the missing-beacon timeout, parsers/statistics, fail-closed Git-status mapping,
raw-blob rejection of changes hidden by clean filters or `assume-unchanged`,
output-collision isolation, a byte-for-byte rebuild from a pinned immutable
`HEAD:path` source tree of the running kernel-mapped harness executable,
retained-descriptor path-replacement controls, public-evidence redaction, and the
machine-readable publication policy. The redaction control constructs evidence with known raw
tokens, paths, network coordinates, process generations, coalition values, and
monotonic timestamps; encoding must omit them while preserving consistent
within-sample pseudonyms and relative offsets. The self-test also builds and
launches a disposable app that refuses graceful termination and spawns a child,
then proves generation-bound hard cleanup drains the root, child, and WebKit
helpers without leaking a process.

## Startup attribution diagnostic

`--app-startup-trace LABEL=ENVIRONMENT_VARIABLE` opts one trusted fixture into
a non-scoring startup trace. The harness creates a unique private output path,
passes it only through the named environment variable, and accepts exactly one
nonce-bound v1 record with strictly ordered milestones. A missing, stale,
malformed, duplicate, or out-of-order trace fails the arm after the normal
double-rAF beacon is accepted. The emitted JSON adds only relative stage
durations; it contains no path, nonce, or process identity.

For Keld's committed adapter, use `KELD_BENCH_STARTUP_TRACE`. The fixture writes
the trace after `keld-wv` enters, tao creates the event loop, tao/AppKit builds
the native window, and wry/WebKit builds the webview. Trace-enabled arms are
for diagnosis only and the runner refuses `--publish` with them; compare their
results with separately built, trace-disabled score arms.

## Keld and Tauri

Build Keld with the committed adapter recipe first; do not add the URL seam to
the product. The recipe checkout must be clean and both the recipe commit and
Keld source commit must be exact heads advertised by their canonical remotes:

```bash
macos/keld/hello/build.sh \
  /absolute/path/to/keld \
  "$(git -C /absolute/path/to/keld rev-parse HEAD)" \
  "/absolute/artifacts/Keld Hello.app"

./macos/tauri/hello/build.sh
```

Run 11 interleaved samples per arm (the default) and atomically retain raw JSON.
For a publishable run, use `--publish` and place the initial result outside the
repository so creating it cannot dirty the measured source tree:

```bash
macos/harness/.build/keld-macos-bench \
  --app 'Keld=/absolute/artifacts/Keld Hello.app' \
  --app-arg 'Keld=--hello' \
  --app-arg 'Keld=--title=Hello' \
  --app 'Tauri=/absolute/path/to/Tauri Hello.app' \
  --publish \
  --output /tmp/keld-vs-tauri.json
```

An adapter-built Keld bundle carries its normalized source and recipe
repositories, immutable commits, patch/template/script SHA-256 values, build
recipe identifier, and build toolchain in `Info.plist`. The build script accepts
only canonical `gyldlab/keld` and `gyldlab/keld-benches` origins. Publication
compares those recipe hashes and commit with the clean harness checkout. The
canonical Tauri recipe likewise embeds its source/recipe commit, recipe
path, script hash, and actual build toolchain; publication binds all of them to
the clean fixture source and harness commit. Other arms must provide their exact
build command and a separately defined artifact-binding contract. This is a trusted-operator
provenance contract, not a cryptographic proof that arbitrary supplied bundle
bytes were produced from those sources; a signed build attestation would be a
separate artifact-distribution contract.

The JSON records hashes of build commands and launch-argument templates, never
their raw values. It also omits absolute app, executable, source, and HTML paths;
sample and cleanup failures use stable public codes while detailed local errors
are written only to stderr.
Raw nonce hashes, PIDs and process generations, coalition identifiers/names and
lifecycle counters, LaunchServices identifiers, peer addresses, and the chosen
loopback port are likewise omitted. Process and coalition relationships use a
fresh unrecorded salt for each sample, so one raw identity maps consistently
within that sample but cannot be correlated through a stable published value
across samples. Event, launch-callback, beacon, and coalition observation times
are milliseconds relative to that sample's launch `t0`; boot-relative monotonic
timestamps are never encoded.
Repository provenance uses a credential-free repository identifier, immutable
commit snapshot, clean/dirty/unavailable state, and repository-relative source
hashes. Required fixture and harness source hashes are checked against that
captured commit; the runner never substitutes a moving `HEAD` while a run is
being assembled.
Remote-head evidence is queried from the literal canonical HTTPS URL, from
`/var/empty`, with Git's global/system configuration, replacements, credential
prompts, and ambient working directory removed. Publish-required harness and
fixture source files and lockfiles are also checked against raw `commit:path`
Git blob object IDs from the captured commit. Clean/smudge filters and index
assume-state therefore cannot turn different required bytes into publishable
provenance.

The runner resolves its own loaded executable through the kernel rather than
caller-controlled `argv[0]`, retains a no-follow read-only descriptor, and
proves its device/inode matches the offset-zero executable mapping reported by
the kernel. It reads and hashes only through that descriptor, with metadata
snapshots before and after each read. It rebuilds `HarnessCore.swift` and
`Runner.swift` from exact raw blobs of the captured commit in a private external
tree, compiles the exact `keld-macos-bench` basename with the recorded strict
invocation, and requires byte-for-byte equality for publication. A negative
control compiles a transient substituted source path and must fail while the
immutable-source compile succeeds. Together with the pinned raw source checks,
this binds the running harness to the reviewed commit and the compiler observed
at benchmark time.
Tauri Bun/Tauri/Rust/Cargo/Xcode/SDK values and Keld Rust/Cargo/Xcode/SDK values
are metadata captured by their canonical build recipes, not benchmark-time
guesses about a pre-existing app. Tauri evidence is also bound to the clean
source commit and raw `HEAD` hashes of its required source files, `bun.lock`,
and `Cargo.lock`.

Every result contains `publication` with a policy version, `eligible` boolean,
and stable reason codes. Publication requires the committed canonical HTML, an
unchanged clean harness/source commit, complete artifact and toolchain
provenance, exactly 11 successful samples for every arm, complete metrics and
cleanup proof, unchanged app bundles, at least three coalition observations over
at least 500 ms with no more than 1,024 KiB total drift, a result path outside
the source tree, Low Power Mode off and nominal thermal state at both boundaries
of every sample as well as the full-run endpoints, complete host metadata, and
unchanged endpoint host state. Canonical commits must be reachable from
an exact branch head advertised by the canonical remote. The validated output
is exclusively and atomically installed before JSON is emitted to stdout; an
output failure emits no stdout eligibility claim. `--publish` exits 3 when a
completed measurement fails that policy; ordinary measurement failure exits 2.
Without `--publish`, the same assessment is recorded but the run remains
diagnostic.
