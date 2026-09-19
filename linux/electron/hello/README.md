# Electron 43.4.0 hello — Linux Chromium comparator

This fixture is the Linux Electron arm for KEL-90. It uses the exact official
Electron **43.4.0** Linux x64 runtime distributed by the `electron` npm
package plus a committed minimal main process.

The measured artifact contains Electron's embedded Chromium + Node runtime. It
is therefore a **Chromium-class** comparator and must not be presented as a
same-engine WebKitGTK comparison against Keld/Tauri.

## Launch contract

The packaged main process requires `KELD_BENCH_URL` to be exactly:

`http://127.0.0.1:<port>/run/<32 lowercase hex>/index.html`

It creates one visible 960x640 black-backed BrowserWindow, denies popup
creation, rejects top-level navigation away from the approved loopback URL,
and keeps:

- `contextIsolation: true`
- `nodeIntegration: false`
- `sandbox: true`
- DevTools disabled

No `--no-sandbox` or equivalent weakening is part of this fixture. On Linux,
Electron may use Chromium's unprivileged-user-namespace sandbox when the host
permits it. Hosts that do not permit that path must configure the official
`chrome-sandbox` helper as `root:root` mode `4755`; the hosted Linux GUI CI lane
does exactly that and fails closed if the helper metadata is not exact.

The runner owns the measured HTML and nonce-bound double-rAF paint beacon. The
committed placeholder page is also black so every directly visible launch
surface follows the repository launch-theme contract.

## Build

```bash
linux/electron/hello/build.sh /absolute/output-directory
```

The build recipe:

1. verifies every recipe input against an immutable keld-benches commit;
2. runs `npm ci --ignore-scripts` from the committed lock;
3. explicitly runs Electron's official install helper to acquire 43.4.0;
4. copies the official runtime distribution byte-for-byte;
5. installs only the committed app source under `resources/app`;
6. emits a recursive artifact-tree digest plus executable hash/size and
   embedded Electron/Chromium/Node versions.

The output is:

- `electron-linux-hello/` — packaged runtime + app
- `provenance.json`

Do not commit `node_modules/`, downloaded Electron archives, or packaged
runtime output.

## Measurement boundary

The first admitted lane is **PAINT-OPPORTUNITY only**. It uses the same external
monotonic loopback/double-rAF oracle as the existing Keld/Tauri Linux arms.

A Keld-vs-Electron document is cross-engine by construction:

- Keld arm: benchmark host adapter + system WebKitGTK
- Electron arm: packaged Electron main + embedded Chromium/Node

Any paired ratio is a workload diagnostic, not evidence that one web engine,
language, or framework is universally faster. The result stays
publication-ineligible for same-engine scoreboard use.

Memory, installer/download size, loaded responsiveness, multiwindow, and
renderer IPC remain separate future observables rather than being inferred
from this paint fixture.

## Physical-desktop admission status — 2026-09-19

The committed fixture itself passes a standalone real-display smoke on the
Ubuntu 26.04.1 GNOME machine's live Mutter Xwayland display under the unchanged
visible/focused double-rAF oracle.

A same-session 4-round Keld/Electron paired falsifier was then attempted with
both artifacts built from the same benchmark recipe. Keld was 4/4 valid;
Electron requested the page and emitted one beacon in every round, but all four
Electron beacons were rejected as `document_not_focused`. No comparison was
admitted.

A separate diagnostic tried explicit fixture-owned `focus()` at window creation;
it reproduced the same 0/4 focus failure. A hidden `ready-to-show` experiment
could suppress the rAF beacon entirely. Both experiments were discarded from
the committed fixture instead of weakening the oracle or introducing external
focus automation.

Therefore this PR adds the trusted comparator fixture and runner admission
surface, **not** an Electron performance row. A future physical-desktop timing
campaign must first make the committed, independently rebuilt fixture satisfy
the unchanged focus/visibility oracle reproducibly under a matched session.
