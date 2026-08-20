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
| [`linux/*/hello/`](./linux/) | stub READMEs | Linux packs (AppImage / deb / etc.) |
| [`linux/gtk4/hello/`](./linux/gtk4/hello/) | contract only | Linux native floor (GTK4 + WebKitGTK) — app not implemented |

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
