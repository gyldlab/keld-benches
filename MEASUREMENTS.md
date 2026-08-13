# Measurements

## Fixture index

| Fixture path | Stack | Sources in repo? | Notes |
|---|---|---|---|
| [`macos/swift/appkit-wk/`](./macos/swift/appkit-wk/) | Native Swift AppKit + WK | yes | Measured 2026-08-13 |
| [`macos/swift/swiftui-wk/`](./macos/swift/swiftui-wk/) | Native Swift SwiftUI + WK | yes | Measured 2026-08-13 |
| [`macos/electron/hello/`](./macos/electron/hello/) | Electron (Chromium + Node) | yes | Measured 2026-08-14 |
| [`macos/tauri/hello/`](./macos/tauri/hello/) | Tauri 2 (system webview) | yes | Measured 2026-08-14 |
| [`macos/wails/hello/`](./macos/wails/hello/) | Wails v3 (system webview) | yes | Measured 2026-08-14 |
| [`macos/neutralino/hello/`](./macos/neutralino/hello/) | Neutralino | yes | Measured 2026-08-14 |
| [`macos/nwjs/hello/`](./macos/nwjs/hello/) | NW.js (Chromium + Node) | yes (app sources; runtime zip not committed) | Measured 2026-08-14 |
| [`macos/electrobun/hello/`](./macos/electrobun/hello/) | Electrobun (system webview + Bun) | yes | Measured 2026-08-14 |
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

## Competitor hellos — macos (2026-08-14)

Same machine as the Swift rows: **Apple M4**, macOS **26.5.1** (25F80),
darwin/arm64. One window, local HTML, **Release** artifacts only. RSS is
`ps -o rss=` after the window is up (paint file where the app writes one).
WebKit / Chromium helpers are listed separately from the main process.

| Field | Value |
|---|---|
| Node | v26.7.0 / npm 11.19.0 |
| Rust | rustc 1.93.0 |
| Go | go1.26.5 darwin/arm64 (Homebrew; used for Wails) |
| Bun | 1.3.14 |
| Xcode | 26.5 (17F42) |

`du -sk` is 1024-byte blocks (`du_bytes = du_sk × 1024`). File sum is
`stat -f%z` of regular files inside the `.app`.

Do **not** put Chromium rows (Electron, NW.js) in the same `vs` cell as
WKWebView rows (Swift, Tauri, Wails, Neutralino, Electrobun, Keld host).

---

### Electron 43.4.0 — Chromium + Node

Fixture: [`macos/electron/hello/`](./macos/electron/hello/). Official zip
`electron-v43.4.0-darwin-arm64.zip` assembled with `ditto` into
`Electron Hello.app` (Forge `extract-zip` returned 0 without writing `out/`
on this Mac). Weigh the `.app`, not `electron .`.

| Artifact | `du -sh` / `du -sk` | Bytes | Notes |
|---|---|---|---|
| Official zip | 116M | **122,121,746** | `~/Library/Caches/electron/…/electron-v43.4.0-darwin-arm64.zip` |
| `Electron Hello.app` | 275M / 281688 | **288,448,512** (`du`); file sum **287,529,748** | Ad-hoc `codesign --sign -` |

Idle RSS after `/tmp/keld-benches-electron-painted`:

| Process | `ps -o rss=` | ~MiB |
|---|---|---|
| Main (`…/MacOS/Electron`) | **138,064 KB** | 134.8 |
| GPU helper (`--type=gpu-process`) | 79,760 KB | 77.9 |
| Utility (`--type=utility`) | 40,384 KB | 39.4 |
| Renderer (`--type=renderer`) | 84,640 KB | 82.7 |
| Helpers sum | 204,784 KB | 200.0 |
| All listed | 342,848 KB | 334.8 |

---

### Tauri 2.11.5 — system WKWebView

Fixture: [`macos/tauri/hello/`](./macos/tauri/hello/).
`npm create tauri-app@latest -- --yes --manager npm --template vanilla`,
then `npm run tauri build` (not `--debug`). CLI **2.11.4**. wry **0.55.1**,
tao **0.35.3**. Ad-hoc `signingIdentity: "-"`.

| Artifact | `du -sh` / `du -sk` | Bytes | Notes |
|---|---|---|---|
| `Tauri Hello.app` | 7.9M / 8072 | **8,265,728** (`du`); file sum **8,255,340** | `bundle/macos/` |
| Host exe `Contents/MacOS/tauri-hello` | — | **8,153,472** | Mach-O arm64 |
| DMG `Tauri Hello_0.1.0_aarch64.dmg` | 2.8M / 2844 | **2,910,772** | official bundle dmg |

Idle RSS (no paint file; process + 1.5 s settle):

| Process | `ps -o rss=` | ~MiB |
|---|---|---|
| Main (`tauri-hello`) | **102,896 KB** | 100.5 |
| `com.apple.WebKit.GPU` | 30,944 KB | 30.2 |
| `com.apple.WebKit.Networking` | 17,152 KB | 16.8 |
| `com.apple.WebKit.WebContent` | 32,464 KB | 31.7 |
| WebKit XPCs sum | 80,560 KB | 78.7 |

---

### Neutralino 6.9.0 — system WKWebView

Fixture: [`macos/neutralino/hello/`](./macos/neutralino/hello/).
`neu update --latest` + `neu build --release --macos-bundle --embed-resources`.
CLI **11.7.2**. `--macos-bundle` is a **renamed Mach-O**; RSS used a real
`.app` wrapper around that binary.

| Artifact | Bytes | Notes |
|---|---|---|
| Embedded arm64 Mach-O (`…-mac_arm64.app` name) | **2,917,796** | official dist name; not a bundle |
| Wrapped `Neutralino Hello.app` exe (signed) | **2,941,808** | codesign adds a blob |
| Wrapped `.app` `du -sk` / file sum | 2,884 KB → **2,953,216** / file sum **2,944,854** | Info.plist + exe |
| UDZO of wrapped `.app` | **1,322,015** | macOS-only compressed lane |
| `neutralino-hello-release.zip` | **8,122,590** | **all OS binaries** — not a macOS installer |

Idle RSS after `/tmp/keld-benches-neutralino-painted`:

| Process | `ps -o rss=` | ~MiB |
|---|---|---|
| Main (`Neutralino Hello`) | **86,336 KB** | 84.3 |
| WebKit GPU / Networking / WebContent | 29,568 / 19,920 / 31,712 KB | 28.9 / 19.5 / 31.0 |
| WebKit XPCs sum | 81,200 KB | 79.3 |

---

### Wails v3.0.0-beta.8 — system WKWebView

Fixture: [`macos/wails/hello/`](./macos/wails/hello/).
`wails3 init -t vanilla` then `wails3 package` (production `-ldflags="-w -s"`).

| Artifact | `du -sh` / `du -sk` | Bytes | Notes |
|---|---|---|---|
| `wails-hello.app` | 9.4M / 9588 | **9,818,112** (`du`); file sum **9,804,234** | `bin/` (gitignored) |
| Host exe `Contents/MacOS/wails-hello` | — | **8,271,424** | Mach-O arm64 |
| UDZO of `.app` | 5.1M | **5,320,599** | this session |

Idle RSS:

| Process | `ps -o rss=` | ~MiB |
|---|---|---|
| Main (`wails-hello`) | **95,648 KB** | 93.4 |
| WebKit GPU / Networking / WebContent | 29,648 / 13,952 / 30,160 KB | 29.0 / 13.6 / 29.5 |
| WebKit XPCs sum | 73,760 KB | 72.0 |

---

### NW.js 0.114.1 — Chromium + Node (normal flavor, not SDK)

Fixture: [`macos/nwjs/hello/`](./macos/nwjs/hello/) (app sources only).
Runtime: `nwjs-v0.114.1-osx-arm64.zip` assembled with `app.nw`.

| Artifact | `du -sh` / `du -sk` | Bytes | Notes |
|---|---|---|---|
| Official zip | 162M | **169,495,010** | not committed |
| `NWJS Hello.app` | 391M / 400656 | **410,271,744** (`du`); file sum **409,184,403** | zip + `app.nw` |

Idle RSS after `/tmp/keld-benches-nwjs-painted`:

| Process | `ps -o rss=` | ~MiB |
|---|---|---|
| Main (`…/MacOS/nwjs`) | **205,776 KB** | 201.0 |
| GPU helper | 93,184 KB | 91.0 |
| Utility helpers (two) | 71,280 + 59,472 KB | 69.6 + 58.1 |
| Renderer | 162,944 KB | 159.1 |
| Chromium helpers sum (`--type=`) | 386,880 KB | 377.8 |
| crashpad handlers (two) | 8,624 + 7,616 KB | not in helper sum |

---

### Electrobun 1.18.1 — system webview + Bun

Fixture: [`macos/electrobun/hello/`](./macos/electrobun/hello/).
`electrobun init` hello-world + `bunx electrobun build --env=stable`
(`bundleCEF: false`). **Do not blend zstd / wrapped `.app` / extracted `.app`.**

| Lane | `du -sk` | Bytes | Notes |
|---|---|---|---|
| Wrapped self-extracting `.app` | 18272 | **18,710,528** (`du`); file sum **18,696,897** | zstd payload still inside `Resources/*.tar.zst` |
| Artifact `*.app.tar.zst` | 18084 | **18,514,771** | `artifacts/` (gitignored) |
| Extracted `.app` (first launch) | 41368 | **42,360,832** (`du`); file sum **42,333,033** | `~/Library/Application Support/com.keld.benches.electrobun/…/Electrobun Hello.app` |
| Bundled `bun` inside extracted `.app` | — | **32,287,232** | runtime lane |

Idle RSS (first launch, launcher after ~2 s settle). Bun child was **not**
matched as a separate `ps` line; WebKit GPU/WebContent were not up yet on
this sample:

| Process | `ps -o rss=` | ~MiB |
|---|---|---|
| Main (`…/MacOS/launcher`) | **72,032 KB** | 70.3 |
| `com.apple.WebKit.Networking` | 17,328 KB | 16.9 |

Treat Electrobun RSS as **incomplete vs Tauri/Wails** (helpers not fully
enumerated). Re-sample if citing vs WKWebView.

---

Linux competitor rows: still stubs (not this machine).



---

# Windows hello fixtures (2026-08-13)

**Machine:** Windows 11 Home Single Language 10.0.26200, x64.
**Engine (system-webview arms):** WebView2 Evergreen **151.0.4129.78**.
**Toolchain:** rustc 1.93.0-x86_64-pc-windows-msvc, Go 1.26.5, Zig 0.16.0,
Node 25.2.1, Bun 1.4.0, MSVC 14.44.35207.
**Builds:** Release/production for every arm. **Median of 3 runs.**

## Method (differs from the macOS rows — read before comparing)

* `window-visible` = first moment the process owns a titled `HWND`. It is **not**
  first paint. Not comparable to the macOS rows, which did not instrument startup.
* RSS is `WorkingSet64`, sampled 4 s after the window appears.
* **Helpers are the recursive descendant process tree of our own PID only.**
  A global `Get-Process msedgewebview2` is wrong on Windows: this machine idles
  with 6 unrelated WebView2 processes from other apps, which inflated an early
  draft to 1,569 MB / 21 procs. `conhost.exe` excluded.
* Main and helper RSS are reported **separately** (macOS-row convention).
  The `total` column is the M-05 sum, given only because KEL-57 asks for it.

## Fairness notes specific to these arms

* On Windows the "system webview" **is** Chromium (WebView2). The macOS
  WK-vs-Chromium lane split does **not** transfer: Keld / Tauri / Wails /
  Neutralino all render on the same Chromium-derived engine here. Only the
  **main process** differs meaningfully; helper cost is engine-fixed.
* The Wails arm was scaffolded with official `wails3 init -t vanilla`, then
  **stripped** of template extras that no other arm carries: a `GreetService`
  binding and a goroutine emitting an event **every second**. Leaving those in
  would have charged Wails CPU and RSS nothing else pays.
* Every arm serves the same hello document (M-01), differing only in the engine
  named in the copy.

## Disk

| Stack | Version | Binary / exe | Installer / archive |
|---|---|---|---|
| **Keld** `keld-host.exe` | `agent/kel-27` | **624,128 B** | none (`keld-pack` is still a `Format` enum) |
| Keld `keld.exe` (CLI) | same | 2,439,680 B | n/a (devtools, not an app installer) |
| Tauri | 2.11.5 | 8,634,880 B | MSI **2,846,720 B**; NSIS setup **1,828,010 B** |
| Neutralino | 6.9.0 | 2,490,880 B | release zip **8,291,997 B** |
| Wails | v3.0.0-beta.8 | 10,295,296 B | none produced by `wails3 build` |
| Electron | 43.4.0 | packaged dir (forge `package`) | not made |
| NW.js | 0.114.1 | runtime zip **209,290,666 B** | unpacked **552,990,288 B** / 478 files |
| Electrobun | 1.18.1 | Setup.exe **423,936 B** | `.tar.zst` **33,164,123 B**; extracted **33,588,768 B** |

## Idle RSS + startup (median of 3)

| Stack | window-visible | Main RSS | Helper RSS | Total | Procs |
|---|---|---|---|---|---|
| **Keld** `keld-host --hello` | 657 ms | **22,656 KB** | 330,400 KB | 353,056 KB | 7 |
| Tauri 2.11.5 | **61 ms** | 27,436 KB | 337,312 KB | 364,748 KB | 7 |
| Neutralino 6.9.0 | 566 ms | 26,548 KB | 351,844 KB | 378,392 KB | 7 |
| Wails v3.0.0-beta.8 | 766 ms | 30,264 KB | 344,884 KB | 375,148 KB | 7 |
| Electron 43.4.0 | 185 ms | 89,500 KB | **215,536 KB** | **305,036 KB** | 4 |
| NW.js 0.114.1 | 926 ms | 143,456 KB | 248,940 KB | 392,396 KB | 6 |
| Electrobun 1.18.1 | **never opened** | 9,396 KB | 553,416 KB | — | 8 |

## Honest reading

* **Keld leads on disk and on main-process RSS.** 624,128 B is 13.8x smaller
  than Tauri's exe and 16.5x smaller than Wails'. 22,656 KB main RSS is the
  lowest of every arm that actually opened a window.
* **Keld does not lead on startup.** Tauri reaches a titled window in 61 ms
  against Keld's 657 ms — ~10x. This is Keld's worst number on Windows.
* **Keld does not lead on total RSS.** Electron's 305,036 KB beats every
  WebView2 arm, because it runs 4 processes where WebView2 spawns 7. Keld's
  ~3% total-RSS edge over Tauri is inside noise; the 330 MB helper tier is
  engine-fixed and identical across the WebView2 arms.
* **Electrobun is not a valid row.** `electrobun build --env=stable` on Windows
  emitted a macOS-shaped bundle (`Info.plist`, extensionless `bin/launcher`),
  and no window ever appeared, so the 9,396 KB / 553,416 KB sample measures a
  launcher that never rendered. Same "incomplete" status as the macOS row, for a
  different reason. **Do not cite it.**
* Keld's row is a **host-lane diagnostic**: `keld-host --hello` does not spawn
  Bun, and there is no installer. It is not yet a packaged product, so the disk
  numbers are not installer-to-installer against Tauri MSI or NW.js zip.
