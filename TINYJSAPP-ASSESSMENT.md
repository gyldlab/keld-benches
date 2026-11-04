# TinyJSApp: principal systems assessment

Assessed 2026-10-11. Recommendation: **include as a lightweight JavaScript-backend
system-webview comparator; do not replace Keld's runtime/security architecture**.

## Evidence boundary

TinyJSApp release [v0.50.1](https://github.com/tarwin/tinyjsapp/releases/tag/v0.50.1)
was published 2026-10-08 UTC. Its source revision is
`2ea9f0ef7e83a4962adaaa78d4590c412e9f87a9`. The source review also inspected main at
`8336e31d5d03329051b13284730d98f9ec2682ca` (later documentation). The benchmark pins
the release, not moving main. Keld was read at
`4dba1144e1a7de22c739df080b3a58ca7db4ecce`; the benchmark base was
`fcad69a0c6efc8068e5c9889c1d25e28dd92966a`.

This assessment distinguishes source observations from tests and architectural
recommendations. It is not a whole-project security certification, a demonstrated
exploit, or a measured performance ranking. Keld's generated
[product-status ledger](https://github.com/gyldlab/keld/blob/4dba1144e1a7de22c739df080b3a58ca7db4ecce/docs/engineering/product-status.md)
is the current/target/evidence owner; a linked test declaration is not proof that
it was run. No runtime or security change is proposed in the Keld repository.

## Architectural comparison

TinyJSApp combines C++/Objective-C++ native launchers, the txiki.js v26.6.0
QuickJS interpreter backend, and WKWebView/WebView2/WebKitGTK. Its packaged macOS
launcher is the bundle executable and spawns the JS backend; its development and
Windows/Linux layouts start from the backend and spawn the launcher. Keld uses a
Rust host and Bun application processes with authenticated host-owned admission.
Both reuse system engines rather than shipping Chromium on macOS/Linux.

A small SDK is not a small complete application measurement; two delivered
executables are not two total OS processes. Webview helper processes and any
runtime-spawned helpers matter. QuickJS versus Bun changes package weight,
CPU throughput, startup and library compatibility simultaneously. A CPU-heavy
QuickJS disadvantage is a hypothesis, not a measured Keld win. A pure browser
frontend says little about backend or native-addon compatibility.

TinyJSApp offers usable windows, menus/tray, dialogs, persistent storage, native
services, wrapping, reload and build/publish flows. Keld's current ledger marks
multiple native services, the general renderer bridge, privileged product
composition and packaging/updater orchestration incomplete. TinyJS is therefore
a useful usability baseline today, not just a performance foil. Conversely,
TinyJS is not a Node/Electron native-addon compatibility replacement for Bun:
FFI, WebAssembly and pure-JS packages do not make `.node` addons compatible.

Sources: [launcher and bridge layout](https://github.com/tarwin/tinyjsapp/blob/2ea9f0ef7e83a4962adaaa78d4590c412e9f87a9/runtime/bridge.js),
[packaging](https://github.com/tarwin/tinyjsapp/blob/2ea9f0ef7e83a4962adaaa78d4590c412e9f87a9/cli.js),
[Keld README](https://github.com/gyldlab/keld/blob/4dba1144e1a7de22c739df080b3a58ca7db4ecce/README.md).

## Security and reliability: transferable lessons, not a transplant

TinyJS centrally gates renderer calls in the backend and uses native-engine
origin information rather than trusting a page-supplied origin. That is useful
prior art. However, absent `api` policy allows top-level calls, the JS backend
has full system access, and a method allowlist is not OS containment of a
compromised backend dependency. Private Unix socket directories and Windows
pipe authentication protect particular transport threats; neither alone proves
Keld's desired same-user, per-role or native-addon isolation model.

The latest release includes a real cross-frame regression corpus: an untrusted
iframe must not invoke backend authority by hand or resolve a different frame's
pending calls. This is a **fixed historical issue**, not a claim that the latest
release still permits the old exploit. Adapt the failure classes into Keld's
own framing/origin/generation tests, without copying TinyJS's string protocol.
Include navigation races and window replacement, not only two static domains.

The Windows bridge also enables file-to-file access and relaxed WebGPU/GPU
flags globally. These are explicit compatibility tradeoffs in a full-authority
app, not safe Keld defaults. Prefer narrowly authorized features and qualified
platform policies. Origin glob syntax should not become Keld's trust boundary:
parse scheme/host/port and validate each grant explicitly.

In the inspected generic bridge receive path, strings accumulate until newline
and handlers dispatch without a visible global in-flight ceiling. Generic
`pendingGets` promises also have no deadline in their helper. That identifies
bounded-memory, cancellation and peer-death questions to test; it does not claim
that every subsystem is unbounded (audio paths have specific backpressure).
Keld should preserve explicit frame limits, per-role queues, cancellation,
request deadlines and rejection of stale-generation replies.

Sources: [subframe negative controls](https://github.com/tarwin/tinyjsapp/blob/2ea9f0ef7e83a4962adaaa78d4590c412e9f87a9/test/subframe-gate/README.md),
[bridge policy, transport and platform flags](https://github.com/tarwin/tinyjsapp/blob/2ea9f0ef7e83a4962adaaa78d4590c412e9f87a9/runtime/bridge.js).

## Updater and supply chain

TinyJS's updater checks HTTPS, artifact SHA-256, and macOS signatures with
same-team matching when the running app has a real signing identity. Those
checks are useful, but Windows/Linux rely on HTTPS plus manifest hashes in the
inspected implementation. Windows rollback uses an in-memory file journal;
macOS/Linux remove the old backup before post-relaunch health is established.
Caught-exception rollback is not equivalent to recovery after power loss or
process death. Keld's durable journal, anti-rollback and health-commit design
must not be replaced by the smaller updater. Its own production composition is
still incomplete and must not be advertised as finished.

Borrow the small public command surface and clear platform/architecture
selection. Keep authority, identity binding, retained handles and durable
transactions behind it. Release archive hashes provide repeatable dependency
selection, not independent source-build attestation or notarization.

Source: [update.js](https://github.com/tarwin/tinyjsapp/blob/2ea9f0ef7e83a4962adaaa78d4590c412e9f87a9/runtime/update.js).

## Runtime and maintenance cost

The pinned txiki runtime has documented fetch and child-stdin issues. TinyJS
repairs selected HTTP cases through system curl, handles redirects itself, and
stages some request bodies in private temporary files. The small-POST shim hang
was fixed in September; do not report it as still present. The remaining repair
layer shows why runtime size alone does not determine dependency or maintenance
cost. Reproduce wire behavior using an independent peer: testing two instances
of a runtime with the same normalization bug can conceal it.

The inspected main tree contains roughly 25,000 lines across the three native
launcher files, plus the JS bridge, client, updater and CLI. This is not evidence
of bad code, but native feature count has a real audit/porting burden. Keld should
keep optional native features modular instead of expanding its trusted host for
unrelated media/AI functionality before core product composition is usable.

Source: [runtime limitations and repair evidence](https://github.com/tarwin/tinyjsapp/blob/2ea9f0ef7e83a4962adaaa78d4590c412e9f87a9/TODO-txiki.md).

## Recommended Keld priorities

1. Finish one useful vertical slice: renderer request, authenticated host
   dispatch, authorized operation, typed response and failure handling. Add a
   real example such as picking, reading and persisting a note. Do not turn a
   library-only guard test into a product-completion claim.
2. Add host-owned capability introspection: distinguish available, unsupported,
   denied and not-qualified. Expose understandable remediation through doctor
   and developer diagnostics; do not let JS grant itself authority.
3. Improve the development loop: frontend reload and supervised backend restart
   must invalidate old pending calls and retain generation-bound cleanup.
4. Give existing packaging/updater primitives a small coherent public workflow.
   Keep strong durable admission, identity and health requirements underneath.
5. Add TinyJS's relevant failure classes to regression tests. Do not adopt
   permissive default access, broad browser flags, newline framing or an
   additional QuickJS runtime merely to win an empty-window size test.

These are priorities to map onto existing Keld owners, not authorization to
create duplicate frameworks or a parallel security policy engine.

## Benchmark decision and remaining gates

The added [macOS fixture](macos/tinyjs/hello/README.md) is an ordinary release
`.app`, with canonical HTML and unmodified upstream runtime/launcher behavior.
It provides a discriminating baseline for the cost of a full JS-backend app
versus host-only experiments. It is intentionally **unmeasured**.

For future measurement, keep native host floor, full application readiness,
idle process-family resources and renderer-to-backend round trips as different
questions. CPU/worker/library workloads need explicit common semantics, not
borrowed author's numbers. Security tests are qualification evidence, not a
scalar speed score. Compare like engine/build/cache/architecture/security
configurations and label deliberate differences.

The macOS runner owner is still absent from benchmark main; do not implement a
second runner. Its eventual arm registration must cover nonce negative
controls, source/artifact binding, all relevant process roles and clean shutdown.
Only then run the same-session randomized paired campaign required by
`HARNESS-CONTRACT.md`. No Keld/TinyJS ranking is supportable from this change.
Windows/Linux fixture implementation and device qualification remain separate.
