# keld-benches

Public, reproducible **hello-window / installer / RSS fixtures** for the
[Keld](https://github.com/gyldlab/keld) size and memory scoreboard.

**Product is Keld.** This repo is fixtures only — competitor and native-floor
hellos so measurements can be rebuilt on the same machine protocol (same HTML
class, official release flags, fair lanes). Do not treat anything here as the
Keld app framework.

Measured summaries are mirrored in Keld
[`docs/engineering/budget-scoreboard.md`](https://github.com/gyldlab/keld/blob/main/docs/engineering/budget-scoreboard.md)
(private monorepo paths may differ by branch). Record raw disk / RSS / DMG here
in [`MEASUREMENTS.md`](./MEASUREMENTS.md).

## What the initial benchmarks say

KELD is still early, and this repository deliberately avoids an "overall
winner" score. Different benchmarks answer different questions.

The clearest story in the evidence today is that **KELD's native host is
already very lean**: it uses less host memory in the strongest paired Tauri
campaign, a much smaller main-process working set than Electron in the cited
Windows session, and a very small Windows host executable. Startup is a more
mixed story, and we show that too.

### Strongest evidence-backed signals

| Question | KELD | Comparison | What the benchmark is telling you |
|---|---:|---:|---|
| **How much memory does the native host keep resident?** Windows MEM-IDLE, 30 matched rounds | **22,788 KiB** | Tauri **26,856 KiB** | **~15.2% lower host working set.** Paired median ratio **0.8484**, CI95 **[0.846864, 0.849548]**; the interval excludes 1.0. This is the strongest current KELD-vs-Tauri memory result. [Result JSON](./windows/bench/results/mem-idle/2026-08-25.kel25-windows-keld-vs-tauri-canonical-30.fresh-process.json). |
| **How heavy is the framework's main native process?** Windows direct-COM session | **19,552 KB** | Electron **89,140 KB** | KELD used about **4.6× less main-process RSS**. This describes the native/main process, **not total application memory**. |
| **How much native host code is there to ship?** Windows host executable | **484,864 B** | Tauri **8,634,880 B** | KELD's direct-COM host is about **17.8× smaller** in the host-executable lane. This is **not installer-to-installer**; KELD does not ship an installer yet. |
| **How quickly does the first frame appear?** Windows direct-COM session | **469 ms** | Tauri **479 ms** · Electron **275 ms** | KELD and Tauri were close in this session. The 10 ms KELD/Tauri margin is too small against run noise to call a speed win. Electron was faster here. |
| **Did the Windows host itself get leaner?** KEL-65 direct-COM rewrite | **484,864 B** | prior KELD wry host **625,152 B** | The KELD host shrank **22.4%**. This is an internal improvement, not a competitor comparison. |

### Why a non-technical user should care

| Metric | Plain-English meaning |
|---|---|
| **Host working set / main-process RSS** | Memory consumed by the framework's native shell itself. A leaner host can leave more RAM for the actual application. |
| **Total process-tree RSS** | Memory used by all processes belonging to the app. This is broader than host memory and can produce a different winner. |
| **Host executable size** | Size of the native framework binary. It tells you how much native host code is present, but it is not the same as download or installer size. |
| **First paint** | Time from launch until the first rendered frame can be observed. Lower usually feels more immediate to the user. |
| **IPC round-trip time** | Cost of sending a framework message to another KELD process and receiving the reply. It measures communication overhead, not app startup. |

### Broader initial Windows context

The original same-machine Windows hello session also measured the main process
of the other frameworks that successfully opened a window. It used **median of
3 runs**, so treat this as **initial context**, not as a stronger claim than the
30-round paired result above.

| Framework | Main-process RSS |
|---|---:|
| **KELD** | **22,656 KB** |
| Neutralino 6.9.0 | 26,548 KB |
| Tauri 2.11.5 | 27,436 KB |
| Wails v3.0.0-beta.8 | 30,264 KB |
| Electron 43.4.0 | 89,500 KB |
| NW.js 0.114.1 | 143,456 KB |

In that session, KELD had the smallest main-process working set among the valid
window-opening arms. This still does **not** imply the lowest total application
memory: helper-process architecture matters, and Electron had the lower total
RSS in the broader Windows measurements.

### What the current data does **not** support

- Do **not** say "KELD beats Tauri and Electron overall." These benchmarks
  measure separate properties, not a universal winner.
- Electron still leads KELD on **first paint** and **total RSS** in the cited
  Windows sessions. KELD's clear Electron advantage is the native/main-process
  memory lane.
- The current Linux KELD-vs-Tauri paired paint evidence is **not directional**:
  the confidence intervals cross 1.0 on Wayland and X11/Xwayland.
- Never build a public ratio from different sessions, operating systems, engine
  classes, or packaging lanes.

For the full evidence trail, see [MEASUREMENTS.md](./MEASUREMENTS.md), the
machine-readable result documents under each OS's bench/results tree, and
the measurement contract in [HARNESS-CONTRACT.md](./HARNESS-CONTRACT.md).

## Layout (OS → framework → fixture)

Fixtures are organized **by operating system first**, then framework:

```
{macos|windows|linux}/<framework>/...
```

| Path | Status | Fixture |
|---|---|---|
| [`macos/swift/appkit-wk/`](./macos/swift/appkit-wk/) | **sources** | AppKit `NSWindow` + `WKWebView` hello |
| [`macos/swift/swiftui-wk/`](./macos/swift/swiftui-wk/) | **sources** | SwiftUI + `WKWebView` hello |
| [`macos/electron/hello/`](./macos/electron/hello/) | **sources + measured** | Electron 43.4.0 darwin/arm64 `.app` (2026-08-14) |
| [`macos/tauri/hello/`](./macos/tauri/hello/) | **sources + measured** | Tauri 2.11.5 Release `.app` / DMG (2026-08-14) |
| [`macos/wails/hello/`](./macos/wails/hello/) | **sources + measured** | Wails v3.0.0-beta.8 `wails3 package` (2026-08-14) |
| [`macos/neutralino/hello/`](./macos/neutralino/hello/) | **sources + measured** | Neutralino 6.9.0 embedded arm64 + wrapped `.app` (2026-08-14) |
| [`macos/nwjs/hello/`](./macos/nwjs/hello/) | **app sources + measured** | NW.js 0.114.1 normal flavor; runtime zip not committed (2026-08-14) |
| [`macos/electrobun/hello/`](./macos/electrobun/hello/) | **sources + measured** | Electrobun 1.18.1 stable zstd / extracted `.app` (2026-08-14) |
| [`windows/*/hello/`](./windows/) | **sources + measured** (2026-08-13/15) | Six framework hellos; see `MEASUREMENTS.md` Windows section |
| [`windows/bench/`](./windows/bench/) | **harness + results** | First-paint / RSS oracle (`Measure-FirstPaint.ps1`) + negative controls |
| [`windows/winui/hello/`](./windows/winui/hello/) | contract only | Windows native floor (Win32/WinUI + WebView2) — app not implemented |
| [`linux/keld/hello/`](./linux/keld/hello/) | **Release recipe** | Keld product host + loopback-navigation benchmark adapter |
| [`linux/bench/`](./linux/bench/) | **harness** | Linux `PAINT-OPPORTUNITY`, `MEM-IDLE`, and raw-host `DISK`, with negative controls |
| [`linux/{electron,electrobun,neutralino,nwjs,tauri,wails}/hello/`](./linux/) | stub READMEs | Linux competitor packs (AppImage / deb / etc.) |
| [`linux/gtk4/hello/`](./linux/gtk4/hello/) | **sources + Release recipe + paint arm** | Linux native floor (GTK4 + WebKitGTK 6.0) |
| [`linux/webkitgtk/dmabuf-matrix/`](./linux/webkitgtk/dmabuf-matrix/) | **research fixture** | GTK3 + WebKitGTK 4.1 opaque/transparent DMA-BUF correctness matrix (KEL-171) |

Native floors are per-OS: Swift under `macos/` only, Win32/WinUI under
`windows/` only, GTK4 under `linux/` only.

## Measurement standard

Harnesses, result documents, and result naming follow the **metric-runner
contract** — see [`HARNESS-CONTRACT.md`](./HARNESS-CONTRACT.md) and the
versioned schema + metric registry in [`schema/`](./schema/)
(`python3 schema/check.py` validates everything). One interface per OS
harness, one result shape, immutable result files.

**Agents MUST** place new fixtures under the OS folder for the machine / pack they
actually ran. **MUST NOT** dump OS-agnostic apps at the repo root. When linking
from Keld `budget-scoreboard.md`, use the OS-qualified path
(e.g. `macos/swift/appkit-wk`).

**Do not vendor** full Electron / Chromium / Node trees into this repo. Scaffold
with each framework’s official release tooling, place *app sources* under the
matching `{os}/<framework>/hello/` tree, gitignore `node_modules`, `dist`, and
toolchain caches, then record artifacts in `MEASUREMENTS.md`.

## Build & run — Swift (macOS)

Needs Xcode / Command Line Tools (`swiftc`).

```bash
# AppKit + WKWebView
mkdir -p dist/HelloAppKit.app/Contents/MacOS
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o dist/HelloAppKit.app/Contents/MacOS/HelloAppKit \
  macos/swift/appkit-wk/HelloAppKit.swift
cp macos/swift/appkit-wk/Info.plist dist/HelloAppKit.app/Contents/
codesign --force --sign - dist/HelloAppKit.app
open dist/HelloAppKit.app

# SwiftUI + WKWebView
mkdir -p dist/HelloSwiftUI.app/Contents/MacOS
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o dist/HelloSwiftUI.app/Contents/MacOS/HelloSwiftUI \
  macos/swift/swiftui-wk/HelloSwiftUI.swift
cp macos/swift/swiftui-wk/Info.plist dist/HelloSwiftUI.app/Contents/
codesign --force --sign - dist/HelloSwiftUI.app
open dist/HelloSwiftUI.app
```

Optional UDZO DMG (as in the scoreboard session):

```bash
hdiutil create -volname HelloAppKit -srcfolder dist/HelloAppKit.app \
  -ov -format UDZO dist/HelloAppKit.dmg
hdiutil create -volname HelloSwiftUI -srcfolder dist/HelloSwiftUI.app \
  -ov -format UDZO dist/HelloSwiftUI.dmg
```

First paint writes `/tmp/keld-native-hello-appkit-painted` or
`/tmp/keld-native-hello-swiftui-painted` when `WKNavigationDelegate.didFinish`
fires.

## Fair comparison

- Same machine, same day, **Release** packages only for `vs` cells.
- Split lanes: host / runtime / engine-in-bundle / wrapping — never blend.
- Do not mix WKWebView / Chromium / Skia in one `vs` cell.
- Stub frameworks: follow each directory’s README; do not invent numbers.
- Cross-OS numbers are **not** interchangeable — always cite the OS folder.

## License

MIT — see [`LICENSE`](./LICENSE).

## History maintenance: 2026-09-18

Main was intentionally rewritten from PR #21 onward to compact the 40 macOS
IPC raw-evidence JSON documents without changing their parsed values. The
rewrite also translated downstream benchmark provenance fields to the
equivalent rewritten commits. Raw IPC corpora are now marked -diff, and the
macOS producer emits compact JSON so sample-per-line diff explosions do not
recur.

Old commit references map to the rewritten history as follows:

| Before rewrite | Rewritten equivalent |
|---|---|
| b7137c1c2107e0f622eb350819d32605be7a781f | 43ec7358fe6a5baeb7b183be17f07708198982ba |
| b31a0d7dfbc89e38aa4a1d999f6162fe610753fc | e5f204d6b243e2eca0f262be02b7e6b1d8faea38 |
| 5a2d6d3b4039c44abcb77c327b86166ffde5c752 | edaae38dd321881b2444097dbc1700c159be26dd |
| e3712ee3d4324d49a3e17c0960e7f1e32ede8f0c | 17f66666746834dda1a272d63e7ad23c46533a0f |
| 05cbc070d087d45038d21caedfb7aae6fb6f341f | 082d5fff8597e640a9549daacbe4c096e1316977 |
| aa0db1276bbd5ba9e037b58f56aa3a492de8b7be | a37023344381d26e470e64014528284f78dd9643 |
| f6af26893a5ac76af1cae12e89e0a2bf39f89cf9 | 6ef1a7d321a711927e1d24665bc6bbdc9e1a0ada |
| be6143c8d494a35d24c3063fc73fd9635cc0ee55 | 437720a8275684675f4aa97293179091347e0c1b |

The current history then adds 80da58b86581748a232c54bb427823796edcfcff
for rustfmt-only cleanup of the macOS IPC fixture. The pre-rewrite branch tips
were removed from normal remote refs after the migration.
