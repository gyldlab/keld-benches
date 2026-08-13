# Measurements

## Fixture index

| Fixture path | Stack | Sources in repo? | Notes |
|---|---|---|---|
| [`macos/swift/appkit-wk/`](./macos/swift/appkit-wk/) | Native Swift AppKit + WK | yes | Measured 2026-08-13 |
| [`macos/swift/swiftui-wk/`](./macos/swift/swiftui-wk/) | Native Swift SwiftUI + WK | yes | Measured 2026-08-13 |
| [`macos/electron/hello/`](./macos/electron/hello/) | Electron (Chromium + Node) | stub | Scaffold official Release; weigh then fill row |
| [`macos/tauri/hello/`](./macos/tauri/hello/) | Tauri 2 (system webview) | stub | same |
| [`macos/wails/hello/`](./macos/wails/hello/) | Wails (system webview) | stub | same |
| [`macos/neutralino/hello/`](./macos/neutralino/hello/) | Neutralino | stub | same |
| [`macos/nwjs/hello/`](./macos/nwjs/hello/) | NW.js (Chromium + Node) | stub | same |
| [`macos/electrobun/hello/`](./macos/electrobun/hello/) | Electrobun (system webview + Bun) | stub | same |
| [`windows/electron/hello/`](./windows/electron/hello/) | Electron (Chromium + Node) | stub | WebView2 / Win packs |
| [`windows/tauri/hello/`](./windows/tauri/hello/) | Tauri 2 (WebView2) | stub | same |
| [`windows/wails/hello/`](./windows/wails/hello/) | Wails (WebView2) | stub | same |
| [`windows/neutralino/hello/`](./windows/neutralino/hello/) | Neutralino | stub | same |
| [`windows/nwjs/hello/`](./windows/nwjs/hello/) | NW.js (Chromium + Node) | stub | same |
| [`windows/electrobun/hello/`](./windows/electrobun/hello/) | Electrobun | stub | same |
| [`linux/electron/hello/`](./linux/electron/hello/) | Electron (Chromium + Node) | stub | AppImage / deb / etc. |
| [`linux/tauri/hello/`](./linux/tauri/hello/) | Tauri 2 (WebKitGTK) | stub | same |
| [`linux/wails/hello/`](./linux/wails/hello/) | Wails (WebKitGTK) | stub | same |
| [`linux/neutralino/hello/`](./linux/neutralino/hello/) | Neutralino | stub | same |
| [`linux/nwjs/hello/`](./linux/nwjs/hello/) | NW.js (Chromium + Node) | stub | same |
| [`linux/electrobun/hello/`](./linux/electrobun/hello/) | Electrobun | stub | same |

Mirror summary numbers (not full recipes) into Keld
`docs/engineering/budget-scoreboard.md` with a link back to the **OS-qualified**
fixture path here (e.g. `macos/swift/appkit-wk`).

---

## Swift — macos (2026-08-13)

Captured from `/tmp/keld-native-swift-hello` on **2026-08-13**.

| Field | Value |
|---|---|
| Machine | Apple M4, macOS 26.5.1 (25F80) |
| Xcode | 26.5 (Build 17F42) |
| Swift | 6.3.2 (swiftlang-6.3.2.1.108) |
| SDK | MacOSX26.5.sdk |
| Compile | `swiftc -O -parse-as-library -target arm64-apple-macos14.0` |
| Sign | `codesign --force --sign -` (adhoc); no sandbox |
| Keld hello cite (same day scoreboard) | host Mach-O at git SHA `b93ebb6` (darwin/arm64) |
| Fixture paths | [`macos/swift/appkit-wk/`](./macos/swift/appkit-wk/), [`macos/swift/swiftui-wk/`](./macos/swift/swiftui-wk/) |

Source of truth for these rows: session `MEASUREMENTS.txt` under `/tmp/keld-native-swift-hello`.

### Disk

| Artifact | `du -sh` | File sum inside `.app` | Executable (`stat`) | UDZO DMG |
|---|---|---|---|---|
| HelloSwiftUI | 96K | 92,740 B | 89,696 B | 31,655 B |
| HelloAppKit | 88K | 80,976 B | 77,936 B | 29,774 B |

### Idle RSS (main process)

After `WKNavigationDelegate.didFinish` + window title via osascript:

| App | pid (session) | `ps -o rss=` |
|---|---|---|
| HelloSwiftUI | 26308 | 101,168 KB (~98.8 MiB) |
| HelloAppKit | 26378 | 97,344 KB (~95.1 MiB) |

Window titles: `Native Hello SwiftUI`, `Native Hello AppKit`.

RSS is the main process only; WebKit helper XPCs are not included in these figures.

---

## Electron / Tauri / Wails / Neutralino / NW.js / Electrobun

*No same-protocol Release weigh yet.* Scaffold per each OS folder’s
`*/hello/README.md` (`macos/`, `windows/`, or `linux/`), then append a dated
table here (disk, RSS, installer, machine, toolchain versions). Do not fill
`vs` cells from blog citations alone.
