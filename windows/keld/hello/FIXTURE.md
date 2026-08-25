# Keld hello — Windows

The exact `keld create hello` scaffold, pinned to one immutable Keld monorepo
commit. Sibling of [`macos/keld/hello`](../../../macos/keld/hello/FIXTURE.md);
this is the **Windows** fixture, and it closes the
[`HARNESS-CONTRACT.md`](../../../HARNESS-CONTRACT.md) top-priority gap that
`windows/bench/CONTRACT.md` item 3 names — every Windows Keld measurement
before this had to omit `arms[].fixture_path` and record
`NO_COMMITTED_KELD_FIXTURE`.

Chromium class (host-owned **WebView2 Evergreen**, a system component):
comparable with Windows Tauri / Electron / WinUI-WebView2 rows on the same
engine. **Not** comparable with macOS WKWebView paint numbers — see
`MEASUREMENTS.md`.

## Pinned versions

| What | Value |
|---|---|
| Keld monorepo | `58708bb4bb498148cc5e80d9ef9bedfaddaa47b9` (immutable commit; was `origin/main` when this fixture was captured) |
| Rust toolchain | 1.97.1 — the Keld repo's `rust-toolchain.toml`; rustup selects it automatically inside that repo |
| Bun | **1.4.0 stable** (`bun --revision` = `1.4.0+34cbb9a40`), matching the exact CI pin in Keld's `.github/workflows/ci.yml` |
| WebView2 | Evergreen 151.0.4129.101 (system component; nothing is bundled) |

> **Bun must be the stable release, never a canary.** `bun --version` will
> happily report `1.4.1` for a canary build that was never released; only
> `bun --revision` exposes the `-canary.N+<sha>` suffix. `bun upgrade --stable`
> returns to the pin and prints `Downgrading from Bun 1.4.1-canary to Bun
> v1.4.0`. Measurements taken on a canary are not reproducible from any
> published artifact — this repo already has result documents in that state
> (`windows/bench/results/ipc-rtt/*.json` record `"bun": "1.4.1"`).

## What these files are

The six files here are **byte-identical** to what `keld create hello` emits at
the pinned SHA (`{{name}}` rendered as `hello`), verified with `cmp` at
capture time:

| File | Bytes |
|---|---|
| `.gitignore` | 21 |
| `index.html` | 349 |
| `keld.config.ts` | 162 |
| `package.json` | 116 |
| `src/main.ts` | 1,315 |
| `src/kipc.ts` | 16,477 |

- `src/kipc.ts` is the hand-written, wire-exact kipc v2 client as shipped
  (KEL-30): frame header, postcard payload codec, `KELD_APP_LINK` parsing,
  HELLO handshake, echo Call/Reply. No codegen. The same file serves both
  OSes — it branches internally on `process.platform === "win32"` to pick
  loopback TCP over a unix socket, so this fixture is not a Windows fork of
  the macOS one.
- `src/kipc.test.ts` exists in the Keld template directory but is deliberately
  **not** emitted by `keld create` (the template is an explicit allow-list in
  `crates/keld-cli/src/template.rs`), so it is absent here too.

### Why this directory carries a `.gitattributes`

`keld create` writes **LF**. This repo has `core.autocrlf=true` and no
repo-level `.gitattributes`, so without a local one a Windows checkout
rewrites these files to CRLF and they stop matching `keld create`
byte-for-byte — the blob stays LF, the working tree does not, and the
byte-identity claim above silently becomes false for everyone except whoever
authored the fixture. That is observable today on the macOS sibling:
`macos/keld/hello/index.html` checks out at **366 bytes** on Windows against
its own **349-byte** LF blob. The `* text eol=lf` rule here pins the working
tree to the blob on every platform, so the claim is verifiable by anyone who
clones. `.gitattributes` and this `FIXTURE.md` are repo bookkeeping, not part
of the six emitted files.

To re-derive rather than trust this copy:

```powershell
git clone https://github.com/gyldlab/keld
git -C keld checkout 58708bb4bb498148cc5e80d9ef9bedfaddaa47b9
cd keld; cargo build --release -p keld-cli
target\release\keld.exe create hello   # writes .\hello with these six files
```

## Run (window + concurrent echo)

```powershell
cd windows\keld\hello
& "$KELD\target\release\keld.exe" dev
```

`keld dev` finds the project root via `keld.config.ts`, runs environment
checks (`bun` on `PATH` required), starts a host-owned kipc echo server on a
loopback TCP endpoint, spawns this fixture's `src/main.ts` as a supervised Bun
child with `KELD_APP_LINK` set, and opens the hello window rendering this
fixture's `index.html`, titled from `keld.config.ts`. The window blocks until
closed; the supervisor then reaps the Bun child.

## Verified on this fixture (Windows 11 build 26200, x64, 2026-08-24)

Actual output at the pinned SHA, Bun `1.4.0+34cbb9a40`, rustc 1.97.1:

```text
ipc-echo ok: message="keld" count=1
hello: main process ready (IPC echo ok)
```

- A real native window titled `hello` appeared rendering this `index.html`
  (`<h1>hello</h1>`, "Rendered by the Keld host webview. IPC echo runs in the
  Bun main process."), confirmed by `user32!IsWindowVisible` = true,
  `IsIconic` = false, and a desktop screenshot.
- **Bun child PID was alive concurrently with the visible window** (host PID
  18308, Bun PID 22020 observed live at the same instant).
- `keld dev` exited `0` on `WM_CLOSE`; host and Bun child were both reaped.

### Difference from the macOS fixture — read before comparing

`macos/keld/hello` is pinned to `a6427778`, which predates KEL-30's
host-owned concurrent app link. Its `FIXTURE.md` correctly documents "CLI
sequential path only: echo session first (Bun child exits), window after".
This Windows fixture is pinned to `58708bb`, where `src/main.ts` **stays
alive for the window duration** — the two fixtures' `src/main.ts` and
`src/kipc.ts` therefore differ, and the macOS fixture is stale with respect
to current `main`. Do not treat the two fixture trees as interchangeable, and
do not read a macOS-vs-Windows difference as a platform difference when it is
a pin difference.

## What this fixture proves

- **Windows window on screen**: the host-owned WebView2 renders this
  fixture's `index.html`, titled from config.
- **Authenticated Bun↔Rust kipc echo**: the Bun child parses `KELD_APP_LINK`
  (`<endpoint>#<64-hex token>`), completes the kipc v2 HELLO handshake with
  the 32-byte session token, and round-trips a postcard-encoded echo
  Call/Reply.
- **Concurrent host-owned lifetime**: unlike the macOS pin, the Bun child
  coexists with the window and is reaped on close.

## What this fixture does NOT prove

- **No first-paint claim in this file.** This fixture is deliberately
  byte-identical to `keld create` output, so it carries **no paint beacon**.
  `windows/bench/Measure-KeldPaint.ps1` derives a beacon-bearing copy into a
  temp directory per launch; the beacon is never committed here (that would
  break byte-identity) and never patched into `keld-wv` sources (reason code
  `SOURCE_TREE_PATCHED`, the violation this fixture exists to retire).

  **Scope warning for anyone comparing paint numbers.** A `keld dev` paint
  measurement covers the whole developer flow — environment checks, echo
  server, Bun child spawn, authenticated kipc echo, *then* window and paint.
  The committed 469 ms Windows first-paint row measured `keld-host.exe`
  alone, which spawns no Bun child. These are different scopes and must not
  be put in the same column. `keld-host --hello` renders HTML baked into
  `keld-wv`, not this fixture, so a beacon cannot reach it without patching
  product source — which is why the host-only paint lane stays unmeasured
  here rather than being obtained dishonestly.
- **No RSS or size claim in this file.** Those live in
  `windows/bench/results/` as result documents with their own publication
  blocks.
- **Nothing off Windows.**

## Measurements

None recorded here on purpose — landing a fixture and running a harness are
separate steps. Windows result documents live under
[`../../bench/results/`](../../bench/results/).
