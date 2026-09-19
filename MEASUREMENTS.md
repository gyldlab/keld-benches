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
| [`windows/keld/hello/`](./windows/keld/hello/) | Keld (WebView2 + supervised Bun) | yes | Byte-identical to `keld create hello` at keld `58708bb`; measured 2026-08-25 with a binary built at `2a8e8a4`. `crates/keld-cli/templates/` is unchanged across `58708bb..2a8e8a4` (verified `git diff --stat`, empty), so the fixture is not stale against the measured binary. |
| [`macos/keld/hello/`](./macos/keld/hello/) | Keld (WKWebView + supervised Bun) | yes | Not yet measured |
| [`windows/electron/hello/`](./windows/electron/hello/) | Electron (Chromium + Node) | yes | Measured 2026-08-13/15 |
| [`windows/tauri/hello/`](./windows/tauri/hello/) | Tauri 2 (WebView2) | yes | Measured 2026-08-13/15 |
| [`windows/wails/hello/`](./windows/wails/hello/) | Wails (WebView2) | yes | Measured 2026-08-13 |
| [`windows/neutralino/hello/`](./windows/neutralino/hello/) | Neutralino | yes | Measured 2026-08-13 |
| [`windows/nwjs/hello/`](./windows/nwjs/hello/) | NW.js (Chromium + Node) | yes | Measured 2026-08-13 |
| [`windows/electrobun/hello/`](./windows/electrobun/hello/) | Electrobun | yes | Measured 2026-08-13 — invalid row, window never opened; do not cite |
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
  first paint. Not comparable to the macOS rows, which did not instrument startup,
  and **not comparable across frameworks** — frameworks differ in when they present
  the window relative to webview construction. Superseded by
  [Time to first paint](#time-to-first-paint-2026-08-14-median-of-5); kept for
  continuity only.
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

## Time to first paint (2026-08-14, median of 5)

Same machine, same Release artifacts, one extra session. `window-visible` above
compares *presentation policy*, not speed: a titled `HWND` can appear before,
during, or after the engine has anything to show, so it is not comparable across
frameworks. First paint is the metric Keld's architecture 01 §5 budgets
(**cold start → first paint ≤ 300 ms**), and this subsection is it.

### Instrumentation — identical for every arm

* Every arm serves **byte-identical** hello HTML (M-01).
* The page fires an image beacon —
  `new Image().src = "http://127.0.0.1:45877/painted"` — from inside a **double**
  `requestAnimationFrame`, i.e. after the first frame has been composited.
* A single local `HttpListener` timestamps arrival, so **all arms share one
  clock** and none gets privileged in-process instrumentation the others lack.
* **Image beacon, not `fetch()`:** the page runs on an opaque origin (wry
  `with_html` / WebView2 `NavigateToString`), so `fetch()` is CORS-restricted;
  `<img>` is not.
* **`document.title` does not work — do not retry it.** Setting the document
  title and watching for the native window caption is a dead end in an embedded
  webview: the native window title is owned by the framework, not the document.
  That attempt failed on **every** arm.
* The beacon HTML was injected for this session only and **reverted afterwards**.
  It is not in product code or in the committed fixtures, so no committed SHA
  reproduces the instrumented binaries. Re-inject it to reproduce.

| Stack | first paint (budgeted metric) | titled `HWND` (weak) | vs ≤ 300 ms budget |
|---|---|---|---|
| **Keld** `keld-host --hello` | **906 ms** | 433 ms | **over** — 3.0x |
| Tauri 2.11.5 | **504 ms** | 32 ms | **over** — 1.7x |
| Electron 43.4.0 | **not measured** | 125 ms | — |

Raw first-paint runs (ms): Keld 906 / 943 / 867 / 857 / 977 · Tauri 504 / 568 /
464 / 500 / 510.

### Honest reading of the first-paint rows

* **Both measured arms miss the budget.** Keld 906 ms is 3.0x over ≤ 300 ms;
  Tauri 504 ms is 1.7x over. Tauri also failing is not a defence.
* **Keld does not lead on startup.** On the correct metric the gap to Tauri is
  **1.8x** (906 vs 504 ms) — not the ~10x or ~6.6x that titled-`HWND` timings
  suggested. Those larger figures were **inflated by a metric artifact**, but a
  real ~400 ms gap remains. Correcting the metric shrinks the gap; it does not
  close it.
* **Electron's first paint is missing, not fast.** `electron-forge package` had
  already baked `out/` before the fixture HTML was edited, so the packaged app
  served a **stale copy** of the page with no beacon in it. Anyone reproducing
  this row **must repackage** (`electron-forge package` again) after editing the
  fixture HTML.
* Wails, Neutralino, NW.js and Electrobun were not re-run in this session; they
  have no first-paint number.
* Titled-`HWND` medians are not stable across sessions either: Keld's moved
  205 -> 433 ms between the 2026-08-13 and 2026-08-14 sessions while Tauri's held
  (31 -> 32 ms). Run count differs (3 vs 5) and the instrumented tree carries the
  beacon, so read that as session drift, not a regression — and as one more
  reason not to build a claim on that column.

## Honest reading

* **Keld leads on disk and on main-process RSS.** 624,128 B is 13.8x smaller
  than Tauri's exe and 16.5x smaller than Wails'. 22,656 KB main RSS is the
  lowest of every arm that actually opened a window.
* **Keld does not lead on startup.** Tauri reaches a titled window in 61 ms
  against Keld's 657 ms — ~10x. **Do not cite that ratio:** titled `HWND` is not
  first paint and is not comparable across frameworks. On the budgeted metric the
  gap is **1.8x** (906 vs 504 ms) — see
  [Time to first paint](#time-to-first-paint-2026-08-14-median-of-5). Startup is
  still Keld's worst number on Windows.
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


---

## Time to first paint, reproducible harness (2026-08-14, median of 5)

Supersedes the ad-hoc figures in the previous section. Those were measured with a
throwaway fixed-port beacon that was reverted afterwards, so nobody could re-run
them. This run used the committed harness at
[`windows/bench/Measure-FirstPaint.ps1`](./windows/bench/Measure-FirstPaint.ps1);
raw per-run samples with SHAs, exe hashes and versions were written to
[`windows/bench/windows-first-paint.json`](./windows/bench/windows-first-paint.json).

> **Evidence caveat (2026-08-21):** the committed `windows-first-paint.json`
> was later **overwritten by a 2026-08-15 median-of-7 session**
> (keld @ `f28d696`), so the raw samples for THIS 2026-08-14 table are no
> longer at `main`'s tip (git history only). This overwrite is why result
> files are now immutable and session-named — see
> [`HARNESS-CONTRACT.md`](./HARNESS-CONTRACT.md) §4 and
> [`windows/bench/CONTRACT.md`](./windows/bench/CONTRACT.md).

### Current committed replacement raw (2026-08-15, median of 7)

The file currently at `windows-first-paint.json` is the later `f28d696` session
named in the caveat, not evidence for the 2026-08-14 table below. Its committed
raw samples produce these corrected medians:

| Stack | first paint | main RSS | helper RSS | procs |
|---|---|---|---|---|
| Electron 43.4.0† <!-- raw-median source=windows-first-paint.json arm=electron fields=first_paint_ms,main_rss_kb,helper_rss_kb,processes --> | **372 ms** | 91,988 KB | **224,252 KB** | **4** |
| **Keld†** <!-- raw-median source=windows-first-paint.json arm=keld fields=first_paint_ms,main_rss_kb,helper_rss_kb,processes --> | **573 ms** | **23,068 KB** | 351,472 KB | 7 |
| Tauri 2.11.5† <!-- raw-median source=windows-first-paint.json arm=tauri fields=first_paint_ms,main_rss_kb,helper_rss_kb,processes --> | 589 ms | 28,256 KB | 352,316 KB | 7 |

† Corrected: median-index bug; see PR #10. This table does not reconstruct or
replace the unrecoverable 2026-08-14 raw cited below.

| Stack | first paint | main RSS | helper RSS | total RSS | procs |
|---|---|---|---|---|---|
| **Electron** 43.4.0 | **444 ms** | 87,088 KB | **217,284 KB** | **304,372 KB** | **4** |
| Tauri 2.11.5 | 688 ms | 24,584 KB | 336,852 KB | 361,436 KB | 7 |
| **Keld** `keld-host --hello` | **1,289 ms** | **19,860 KB** | 337,192 KB | 357,052 KB | 7 |

Raw first paint (ms) — first run of each arm is cold, hence the outlier:
Keld 1629 / 1290 / 1262 / 1289 / 1276 · Tauri 1046 / 685 / 686 / 688 / 701 ·
Electron 1371 / 458 / 444 / 413 / 439. 5/5 beacons valid on every arm.

### Honest reading

* **Keld is the slowest arm to first paint** — 1.87x Tauri on the identical
  WebView2 engine, and 2.9x Electron. This is not an engine cost and not a
  measurement artifact; it is Keld's own startup path. Tracked as KEL-62.
* **Electron first-paints fastest and uses the least total RSS**, because it runs
  4 processes where WebView2 spawns 7. The Chromium-bundling tradeoff costs disk,
  not startup.
* **Keld's main-process RSS is genuinely the lowest** (19,860 KB vs Tauri 24,584
  and Electron 87,088) and remains its strongest measured result alongside binary
  size. Total RSS is dominated by the ~337 MB WebView2 helper tier, which is
  engine-fixed and near-identical for Keld and Tauri.
* These absolutes run higher than the 2026-08-13 ad-hoc numbers (Keld 906 ms,
  Tauri 504 ms) on the same machine. The **ratio** is stable (1.8x both times);
  the absolutes are not comparable across sessions. Compare within a session only.

### What this harness does and does not guarantee

Satisfied: one external monotonic clock armed before spawn; listener on port 0;
byte-identical HTML per arm (M-01); paint = image beacon after double
requestAnimationFrame; `window-visible` demoted to a non-paint diagnostic; stale
and malformed beacons fail closed; descendant-tree RSS sampled only after paint
and reported separately from main; machine-readable samples carrying git SHA,
OS/arch, exe path + SHA-256 + version, and the exact command; negative controls
in [`windows/bench/Test-Harness.ps1`](./windows/bench/Test-Harness.ps1).

Not satisfied: the nonce is **per session, not per launch**. Every Windows arm
bakes its HTML in at build time (Keld a `const`, Tauri `frontendDist`, Electron
`app.asar`), so a per-launch nonce would require a per-launch rebuild. It rejects
beacons from an earlier session or an un-rebuilt binary, but not a late beacon
from an earlier run in the same session.

Also note the harness patches product sources to inject the beacon and the
operator must restore them afterwards; it does not produce a committed binary
that reproduces these exact numbers. Closing that needs runtime-loaded content,
a different measurement lane.

## Windows first paint — KEL-65 direct-COM A/B (2026-08-15, median of 7)

Keld replaced wry with direct `webview2-com` COM calls on Windows (KEL-65).
Phase instrumentation had shown wry spending 96–109 ms of UI-thread time in an
unconditional blocking `window.ipc` bridge injection, predicting ~100 ms of
first-paint win. **The controlled A/B refuted that prediction** — both backends
were measured in the same session, same harness, same arms:

Run A — new backend (`keld` branch `agent/kel-65-webview2-direct-com` @ `39be9cc`):

| Stack | first paint | main RSS | procs |
|---|---|---|---|
| Electron 43.4.0† <!-- raw-median source=windows-first-paint-kel65-direct-com.json arm=electron fields=first_paint_ms,main_rss_kb,processes --> | 275 ms | 89,140 KB | 4 |
| **Keld (direct COM)†** <!-- raw-median source=windows-first-paint-kel65-direct-com.json arm=keld fields=first_paint_ms,main_rss_kb,processes --> | **469 ms** | **19,552 KB** | 7 |
| Tauri 2.11.5† <!-- raw-median source=windows-first-paint-kel65-direct-com.json arm=tauri fields=first_paint_ms,main_rss_kb,processes --> | 479 ms | 26,796 KB | 7 |

† Corrected: median-index bug; see PR #10.

Run B — baseline backend (`keld` main @ `137633f`, wry):

| Stack | first paint | main RSS | procs |
|---|---|---|---|
| Electron 43.4.0† <!-- raw-median source=windows-first-paint-kel65-baseline.json arm=electron fields=first_paint_ms,main_rss_kb,processes --> | 286 ms | 88,960 KB | 4 |
| **Keld (wry)†** <!-- raw-median source=windows-first-paint-kel65-baseline.json arm=keld fields=first_paint_ms,main_rss_kb,processes --> | **467 ms** | **21,972 KB** | 7 |
| Tauri 2.11.5† <!-- raw-median source=windows-first-paint-kel65-baseline.json arm=tauri fields=first_paint_ms,main_rss_kb,processes --> | 490 ms | 26,760 KB | 7 |

† Corrected: median-index bug; see PR #10.

Raw samples: [`windows/bench/windows-first-paint-kel65-direct-com.json`](./windows/bench/windows-first-paint-kel65-direct-com.json),
[`windows/bench/windows-first-paint-kel65-baseline.json`](./windows/bench/windows-first-paint-kel65-baseline.json),
[`windows/bench/windows-first-paint-kel66-smartscreen-off.json`](./windows/bench/windows-first-paint-kel66-smartscreen-off.json).

SmartScreen isolation from those same committed raws:

| SmartScreen | first paint |
|---|---|
| ON† <!-- raw-median source=windows-first-paint-kel65-direct-com.json arm=keld fields=first_paint_ms --> | 469 ms |
| OFF† <!-- raw-median source=windows-first-paint-kel66-smartscreen-off.json arm=keld fields=first_paint_ms --> | 453 ms |

† Corrected: median-index bug; see PR #10.

### Honest reading

* **First paint is unchanged by the rewrite** (469 vs 467 ms — inside run noise).
  The ~100 ms wry spent blocking the UI thread overlapped renderer boot, so it
  was never on the paint critical path. The floor is `CreateCoreWebView2Controller`
  — per Microsoft (WebView2Feedback #1536) "the bulk of starting a WebView2
  control", not reducible from app code, and environment creation is only
  runtime resolution (3–6 ms measured).
* **Keld led Tauri in both runs** (469 vs 479; 467 vs 490). The margin (10–23 ms)
  is small against run noise; claim it as "consistently ahead this session", not
  as a fixed ratio.
* **The SmartScreen comparison is inconclusive.** wry's default browser args
  disable `msSmartScreenProtection`; the direct-COM backend passes no args.
  Same-session isolation recorded SmartScreen ON 469 ms vs OFF 453 ms, a 16 ms
  delta without the sample spread or confidence interval needed to attribute a
  cost. The live browser process command line verifies the configuration: wry
  baseline shows
  `--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection`, the new
  backend shows no `--disable-features` at all.
* **Binary shrank 22.4%**: `keld-host.exe` 625,152 B (wry) → 484,864 B (direct
  COM) — wry is no longer linked on Windows.
* Each arm's absolute sits ~97–110 ms below the earlier 2026-08-15 `f28d696`
  session now preserved in the corrected table above (Electron included), which
  is exactly why cross-session absolutes are banned in this file. Within-session
  ordering is the signal.

---

## Keld vs Tauri, paired — windows (2026-08-25)

Fixtures: [`windows/keld/hello/`](./windows/keld/hello/) and
[`windows/tauri/hello/`](./windows/tauri/hello/).
Document: [`windows/bench/results/mem-idle/2026-08-25.kel25-windows-keld-vs-tauri-canonical-30.fresh-process.json`](./windows/bench/results/mem-idle/2026-08-25.kel25-windows-keld-vs-tauri-canonical-30.fresh-process.json)
— the machine-readable record, and the only citable source. This section is a
summary of it, not a second source of truth.

Windows 11 build 26200, AMD Ryzen 7 5800H, on AC. WebView2 Evergreen
151.0.4129.107. keld `2a8e8a4`, Tauri 2.11.5, Bun 1.4.0, rustc 1.97.1.

Round-major randomized interleaving, 30 paired rounds, both arms 30/30 valid.
Both arms are handed the byte-identical 225-byte canonical page
(`26f6ad05…`), verified by **extracting the embedded page from the Tauri
artifact this document cites** rather than by trusting the build.

### MEM-IDLE — host working set

| Arm | Median (KiB) | Min | Max |
|---|---|---|---|
| **Keld** host | **22,788** | 22,680 | 22,888 |
| **Tauri** host | **26,856** | 26,732 | 27,008 |

Paired percentile bootstrap over rounds, 10,000 resamples, resampling whole
rounds to preserve pairing:

**median ratio 0.8484, CI95 [0.846864, 0.849548], verdict PASS** — the Keld
host process is ~15.2% smaller, and the interval excludes 1.0.

### What this is not

**Host scope only.** `framework_ws_kib` (host + runtime) is recorded per run and
deliberately excluded from the comparison: for Keld the median is 73,620 KiB,
because the supervised Bun child is a capability the Tauri hello has no
equivalent of. Do not read 0.8484 as total application footprint.

**Do not compare a working set across sessions.** An earlier session on this
machine recorded that same diagnostic at 48,688 KiB. Its `runtime_private_kib`
was 88,918 against this session's 89,016 — flat — with one runtime process in
both. Private bytes is the allocation-side counter and it did not move; only
residency did. A working set is how much of an allocation the OS is currently
keeping in physical memory, so it tracks system pressure as well as the program.
That is safe for the scored comparison here, where both arms are measured within
the same round seconds apart under the same pressure, and it is **not** safe
between documents. Quoting a working set from one session as a standing property
of a framework — as an earlier revision of this section did — is that unsafe
read.

**The arms are not scope-matched.** The Keld arm runs the full `keld dev`
developer flow — doctor checks, echo server, supervised Bun spawn,
authenticated kipc echo, then window — against a packaged Tauri release exe.

**Payload parity is source-level, not environment-level.** Tauri exposes
`__TAURI_INTERNALS__`, `__TAURI_EVENT_PLUGIN_INTERNALS__`, `ipc` and `isTauri`
before the document runs and loads via a custom asset protocol at
`http://tauri.localhost`; Keld exposes none of those and loads via
`NavigateToString` at origin `null`. Identical bytes, non-identical environments.

**The Tauri npm layer is unpinned**: `windows/tauri/hello/package-lock.json` is
gitignored, so that fixture's npm layer is not reproducible from this repo. Its
`Cargo.lock` is committed and the CLI is not on the measured build path.

### Thermal

The document records `environment.power.thermal_state: "nominal"`. The emitter
derives that from the fixed-work probes at both session boundaries and fails
closed: publication requires nominal at both, and a probe that ran *faster* than
the claimed quiet-baseline floor is refused as `THERMAL_REFERENCE_SUSPECT`,
because such a floor was not measured on a quiet machine and understates every
ratio against it.

The probe is fixed work, not a temperature reading: 200M iterations, CPU0-pinned,
min-of-6, expressed as a ratio against this machine's quiet-baseline floor of
0.4754 ns/iter. Nominal is a ratio at or under 1.05. Temperature is recorded as
descriptive context only, because on this machine it is not a usable decision
variable — idle sweeps ranged 70–91 °C, and this session's opening probe read
82 °C while running nominal.

Every ratio below is citable from the raw session record the emitter now writes
alongside the document
([`…canonical-30.fresh-process.raw.json`](./windows/bench/results/mem-idle/2026-08-25.kel25-windows-keld-vs-tauri-canonical-30.fresh-process.raw.json)),
which carries the same session object the document was computed from.

| probe | ratio | state |
|---|---|---|
| session start | 1.0202 | nominal |
| gate after r5 | 1.0499 | nominal |
| gate after r10 | 1.0456 | nominal |
| gate after r15 | 1.0086 | nominal |
| **gate after r20** | **1.1132** | **throttled — gate entered** |
| gate after r20, recheck | 0.9729 | nominal, after idling 63,591 ms |
| gate after r25 | 0.9931 | nominal |
| gate after r30 | 1.0006 | nominal |
| session end | 0.9655 | nominal |

**The session was not uniformly nominal.** The r20 gate found the machine
throttled and idled it for 63.6 s until a fresh probe came back nominal; the
session's 7 min 40 s wall window includes that pause. Rounds 21–30 were measured
after the recovery, not during the throttle. Because the interleaving is
round-major, any residual effect lands on both arms within the same round rather
than on one of them.

Publication additionally fails closed on a probe that runs *faster* than the
claimed floor (`THERMAL_REFERENCE_SUSPECT`), because such a floor was not
measured on a quiet machine and understates every ratio against it. Neither
boundary probe was suspect here.

An earlier version of this section cited three ratios that appeared nowhere in
the repository: they came from a session file that was never committed, and the
sidecar that *was* committed belonged to a different session (see
[`CORRECTIONS.md`](./windows/bench/results/CORRECTIONS.md)).

### Superseded

The two 2026-08-24 paired documents are **withdrawn** as Keld-versus-Tauri
results; see [`windows/bench/results/CORRECTIONS.md`](./windows/bench/results/CORRECTIONS.md).
They measured a Tauri binary that embedded a paint-beacon-instrumented page.

---

## Keld hello — linux (2026-09-03, diagnostic)

These three documents supply the startup/RSS/binary-size observations requested
by KEL-25/KEL-28 for the current Linux hello slice:

- [`PAINT-OPPORTUNITY`, 30 runs](./linux/bench/results/paint-opportunity/2026-09-03.kel90-linux-keld-v2-30.fresh-process.json)
- [`MEM-IDLE`, 30 runs](./linux/bench/results/mem-idle/2026-09-03.kel90-linux-keld-memory-v2-30.fresh-process.json)
- [`DISK`, one deterministic artifact](./linux/bench/results/disk/2026-09-03.kel90-linux-keld-host-v2.fresh-process.json)

Environment: Ubuntu 26.04.1 LTS, kernel 7.0.0-30-generic, Intel i5-10500H,
GNOME Wayland, WebKitGTK 2.52.6, AC power, balanced profile. Keld source is
`8cb7934baf1636f58e96519a2ce63635d8e698bb`; the remotely advertised
measurement recipe is `e6704174bf0480864d64aabdef9e925a2919f516`.
Every run started from a clean process coalition and all 60 GUI attempts
completed their nonce-bound visible/focused double-rAF beacon and
generation-bound cleanup.

| Metric/lane | Median | Min | Max | p90 | Bootstrap CI95 |
|---|---:|---:|---:|---:|---:|
| Paint opportunity | **813.777 ms** | 297.824 | 858.460 | 842.097 | [809.404, 823.466] |
| Keld host RSS | **163,686 KiB** | 163,400 | 163,852 | 163,800 | [163,638, 163,764] |
| WebKit/helper RSS diagnostic | 232,420 KiB | 232,088 | 232,936 | — | — |
| Total process-tree RSS diagnostic | 396,128 KiB | 395,516 | 396,692 | — | — |

The memory session held exactly three process classes in every accepted
stability window: one `keld-host`, one `webkit-network`, and one `webkit-web`.
Each sample required four generation-identical censuses and at most 1% main/tree
RSS drift; observed per-sample drift was 0.0222–0.1122%. Median private-dirty
diagnostics were 26,680 KiB main, 31,568 KiB helpers, and 58,254 KiB total.

The unmodified Release `keld-host` is **954,680 bytes**, SHA-256
`d479740ef8f85f8f9c25a123a870d2286aba038df531bbd77e93711f934347d3`.
The separate loopback-navigation benchmark adapter is 956,472 bytes and is not
the DISK value.

### Honest reading

All three documents are intentionally `publication.eligible: false`. Thermal
state was not independently verified and that historical session had no paired
Linux arm. Paint and memory measure the committed `keld-host --hello`
loopback-navigation adapter because Linux KEL-96/T4 no-flag application boot
was unavailable at the recorded Keld commit; the product path has since landed,
but that does not retroactively change what these immutable documents measured;
memory therefore also records `BENCHMARK_ADAPTER_ARTIFACT`. DISK is a single
raw-host lane, where repeating a deterministic file-size read thirty times
would manufacture sample count rather than evidence.

The 813.777 ms and 163,686 KiB medians sit above architecture targets, but they
are diagnostics, not pass/fail verdicts or a cross-OS comparison. The paint
minimum is a real fresh-process observation under uncontrolled OS caches, not a
separate warm-cache class and not a value to publish alone. This section does
not close KEL-28: real X11, a non-Debian distro, and window controls remain
unverified. The later no-flag product path is separate KEL-100/KEL-96 evidence.

Feature-branch-only v1 drafts were removed before merge rather than rewritten:
they extended the already-shipped v1 shape, contrary to the schema-versioning
contract. The three v2 documents linked above are the sole citable Linux KEL-90
results; frozen v1 remains byte-identical to `main` for historical documents.

### Keld diagnostic vs GTK4 native floor (2026-09-04)

The landed paired runner produced one immutable
[`PAINT-OPPORTUNITY` document](./linux/bench/results/paint-opportunity/2026-09-04.kel90-linux-keld-vs-gtk4-v2-30.fresh-process.json)
on the same Ubuntu 26.04.1 GNOME Wayland machine. Keld source is
`8863ff4ed22f7c3d5fdf4d39b11f06dcd9b02ccd`; both fixture recipes and the
runner are `2219102f04c9d5dc6b44a651dce42e04133d39fd`. Both arms use WebKitGTK
2.52.6 (Keld's 4.1 API and GTK4's 6.0 API), and each ran first in exactly 15
of 30 balanced randomized rounds.

| Arm | Valid | Median | Min | Max | p90 | Bootstrap median CI95 |
|---|---:|---:|---:|---:|---:|---:|
| Keld `keld-host --hello` diagnostic | 30/30 | **818.233 ms** | 305.681 | 851.736 | 837.910 | [812.1415, 824.634] |
| GTK4 + WebKitGTK native floor | 30/30 | **405.7345 ms** | 375.101 | 471.142 | 439.725 | [401.747, 414.847] |

The complete matched-round candidate/baseline ratio CI95 is
**[1.936275, 2.040994]** against the registry threshold 1.05, so the document's
diagnostic verdict is `FAIL`. This is not a product scoreboard verdict: the
Keld arm deliberately measures the committed loopback-navigation `--hello`
adapter, and independently nominal thermal state was not available. Those are
the document's only two publication blockers.

Keld observations are visibly bimodal: five valid samples fall between
305.681 and 342.994 ms, while the other 25 fall between 803.767 and 851.736 ms.
The result preserves every observation rather than relabeling or deleting the
lower mode. `fresh-process` denotes a new owned process coalition, not cold OS
caches; the paired median/bootstrap result—not the minimum—is the applicable
diagnostic. This session closes the Linux paired-arm evidence slice of KEL-90,
but it does not prove Keld on X11, a non-Debian distro, window controls, or the
no-flag product path.


---

## Linux current-main refresh — 2026-09-18 (diagnostic)

This refresh measures Keld 0ea0780bb574ad242e9f1105fa4af5842872bad3
against keld-benches e5f204d6b243e2eca0f262be02b7e6b1d8faea38
on Ubuntu 26.04.1 LTS, kernel 7.0.0-31-generic, Intel i5-10500H, GNOME
Wayland, WebKitGTK 2.52.6, AC power, performance profile. Thermal state is
still independently unverified, so these remain diagnostics.

The GTK4/WebKitGTK native artifact rebuilt from the landed recipe is
byte-identical to the previously reviewed native floor:
0ac343715de021af1af162564f31ac040b4f2937294e08acd9bd21e5d4e57970
(21,992 bytes).

### Paired paint diagnostic

The first requested 30-round session is retained as rejection evidence:
[29/30 Keld + 30/30 GTK4](./linux/bench/results/paint-opportunity/2026-09-18.kel90-linux-keld-vs-gtk4-current-main-30.fresh-process.json).
Keld run 20 was rejected as document_not_focused; the page and beacon were
observed and cleanup remained generation-bound. No comparison verdict was
emitted. Before retrying, a one-retry stop rule was recorded on KEL-90.

The single bounded retry then completed all requested rounds:
[30/30 + 30/30](./linux/bench/results/paint-opportunity/2026-09-18.kel90-linux-keld-vs-gtk4-current-main-30-r2.fresh-process.json).

| Arm | Valid | Median | p90 | Bootstrap median CI95 |
|---|---:|---:|---:|---:|
| Keld keld-host --hello diagnostic | 30/30 | **437.3585 ms** | 483.109 | [431.5905, 448.5585] |
| GTK4 + WebKitGTK native floor | 30/30 | **543.205 ms** | 575.113 | [534.4485, 559.45] |

The complete matched-round candidate/baseline ratio CI95 is
**[0.785386, 0.831101]**, which is PASS against the registry's 1.05
diagnostic threshold. This is not a product scoreboard verdict: Keld still
uses the --hello benchmark adapter and the session has no independent
thermal-state oracle.

Do not subtract this result from the 2026-09-04 medians to claim a percentage
speedup. The native GTK4 arm itself moved from 405.7345 ms in that session to
543.205 ms here, demonstrating material cross-session drift. Only the
same-session paired ratio above is supported.

### Memory and raw host size

The current-main MEM-IDLE diagnostic completed
[30/30 valid samples](./linux/bench/results/mem-idle/2026-09-18.kel90-linux-keld-current-main-memory-30.fresh-process.json).
Main RSS median is **179,712 KiB**, CI95 [179,660, 179,772]; WebKit/helper RSS
median is **254,724 KiB**. Main/helper private-dirty medians are 30,354 KiB
and 34,188 KiB. This remains an unpaired adapter measurement, not a product
memory verdict.

The deterministic unmodified Release host
[DISK lane](./linux/bench/results/disk/2026-09-18.kel90-linux-keld-current-main-host.fresh-process.json)
is **1,688,160 bytes**, SHA-256
08b5b75d4bad8f2a20124ca2f99c2576e2fc69b7b58834c53c9ed933be7b2538.

### Authenticated IPC library floor

The Linux Rust-to-Rust fixture at
[linux/keld/kipc-rust-echo](./linux/keld/kipc-rust-echo/) is pinned to the same
Keld SHA and uses two OS processes over the authenticated Unix app-link wire
path. A forged-token negative control produced server-side KELD-IPC-007 and
no result file before the campaign was allowed to run.

The registry ipc policy was executed in full: 20 independent fresh-process
sessions × 100,000 requested calls × two payload tiers. Call 1 includes HELLO
and is reported separately; each raw session contains 99,999 timed
CALL-to-REPLY deltas. All 40 sessions completed and validated. Aggregate
evidence is bound by the
[campaign manifest](./linux/bench/results/ipc-rtt/2026-09-18.kel90-linux-rust-library-arm.manifest.raw.json).

| Tier | Payload | Pooled p50 | Pooled p90 | Pooled p99 | 95% session-block bootstrap CI p99 |
|---|---:|---:|---:|---:|---:|
| small | 6 B | 7.641 µs | 9.069 µs | **11.312 µs** | **[11.090, 11.559] µs** |
| representative | 1,024 B | 8.059 µs | 9.705 µs | **13.194 µs** | **[12.725, 13.494] µs** |

Statistics use nearest-rank percentiles over 1,999,980 timed calls per tier and
2,000 whole-session bootstrap resamples (seed 20260918). At the p99 CI upper
bound the Rust wire path retains about **8.65×** headroom for the 6-byte tier
and **7.41×** for the 1 KiB tier against the 100 µs architecture target.

This result proves only the authenticated cross-process keld-ipc library/wire
path on this Linux machine. It contains no Bun product client, host lifecycle,
window, or renderer; it must not be reported as Bun-to-Rust product IPC
performance. The separate `handshake_ns` interval covers HELLO plus the first
CALL/REPLY and is retained as a separate observation; it is not folded into
the scored RTT deltas or claim.


### Shipping Bun product-client IPC diagnostic (2026-09-18)

The Linux Bun fixture at
[linux/keld/kipc-bun-echo](./linux/keld/kipc-bun-echo/) uses the shipping
`AppLinkSession` client and canonical `@keld/kipc` transport from Keld
`0ea0780bb574ad242e9f1105fa4af5842872bad3`, byte-bound by SHA-256. The host
side is `keld_core::HostOwnedHelloSession`, the production primitive used by
the Keld app-session path. Only the fixture's `main.ts` adds timing.

Both negative controls passed before timing: a forged app-link token produced
no result, and an authenticated echo with a deliberately wrong expected reply
was rejected rather than accepted as a timing sample. Two 100,000-call pilots
then passed the predeclared 300 µs p99 sanity stop.

The full IPC sample policy was executed: 20 independent fresh-process sessions
× 100,000 calls × two tiers, for 2,000,000 timed calls per tier. Every session
completed and the 40 raw compact documents are bound by the
[Bun campaign manifest](./linux/bench/results/ipc-rtt/2026-09-18.kel90-linux-bun-product-client.manifest.raw.json).

| Tier | Payload | Pooled p50 | Pooled p90 | Pooled p99 | 95% session-block bootstrap CI p99 |
|---|---:|---:|---:|---:|---:|
| small | 6 B | **14.204 µs** | 19.032 µs | **27.506 µs** | **[26.723, 28.376] µs** |
| representative | 1,024 B | **18.605 µs** | 26.272 µs | **35.518 µs** | **[34.656, 36.443] µs** |

The p99 CI upper bounds retain about **3.52×** and **2.74×** headroom,
respectively, against the 100 µs architecture target. The scored interval is
`Bun.nanoseconds()` immediately before the shipping `session.echo` call
through decoded `EchoResponse` return. Socket connection + authenticated HELLO
is measured separately and excluded from the RTT samples.

The Rust library floor above and this Bun campaign use the same machine, Keld
revision, payload sizes, and session policy, but they were not interleaved in
one paired campaign. Their numerical difference therefore localizes likely
client/codec/transport/scheduling headroom but must **not** be presented as an
exact causal Bun-overhead ratio.

This evidence is stronger than the earlier Windows KEL-99 one-session
diagnostic, but it is still not an end-to-end application latency result: no
window or renderer is in the timed path. Linux thermal state remains
independently unverified, and result-v2 still lacks the independent-session
block-bootstrap corpus shape, so the result remains publication-ineligible.

#### Warm-cache state

The same shipping-client fixture was then extended with the registry's existing
`warm-cache` semantics, matching KEL-99 rather than defining a new cache
class. For each payload tier the controller first ran one unscored priming
process pair. Every scored sample was still a fresh process using the same
fixture/project, and each scored Bun process completed 1,000 untimed
authenticated echoes before its 100,000 timed calls.

The warm-cache campaign again completed 20 independent sessions per tier. Its
40 raw documents are bound by the
[warm-cache manifest](./linux/bench/results/ipc-rtt/2026-09-18.kel90-linux-bun-product-client.warm-cache.manifest.raw.json).

| Tier | Payload | Pooled p50 | Pooled p90 | Pooled p99 | 95% session-block bootstrap CI p99 |
|---|---:|---:|---:|---:|---:|
| small | 6 B | **14.705 µs** | 21.694 µs | **27.367 µs** | **[26.573, 28.120] µs** |
| representative | 1,024 B | **18.185 µs** | 26.102 µs | **34.036 µs** | **[33.377, 34.664] µs** |

At the p99 CI upper bounds, warm-cache retains about **3.56×** headroom for
the 6-byte tier and **2.88×** for the 1 KiB tier against 100 µs.

Fresh-process and warm-cache were separate campaigns rather than paired
round-by-round. Their CIs overlap and the medians move in different directions,
so these data do **not** support a causal claim that warming made KIPC faster
or slower. What they do establish is that the shipping Bun client remains well
inside the 100 µs p99 target under both registered Linux cache states on this
machine. The same thermal and result-v2 session-block limitations remain.


### X11 backend via GNOME Xwayland (2026-09-18)

KEL-28's X11 lane was exercised on the same Ubuntu 26.04.1 laptop while the
desktop session remained GNOME Wayland. The benchmark process environment
forced GDK_BACKEND=x11, set DISPLAY=:0 with the live Mutter Xwayland authority,
and deliberately removed WAYLAND_DISPLAY. The result documents record
session=wayland;...;display=:0;wayland=unset;gdk_backend=x11.

This proves the GTK/WebKit **X11 backend through Xwayland**. It is not evidence
for a native Xorg login session. Before measurement, the native GTK4 fixture's
real-display suite passed 7/7 under the forced X11 environment, including the
focused/visible double-rAF beacon and generation-bound cleanup.

The benchmark fixture commit is c98c8efcfe2c27aba8f67a2d7e85f77aa00def1d;
Keld remains pinned to 0ea0780bb574ad242e9f1105fa4af5842872bad3. The Keld
product/adapter and GTK4 native artifacts are byte-identical to the current-main
Wayland refresh.
Product host SHA-256 is
08b5b75d4bad8f2a20124ca2f99c2576e2fc69b7b58834c53c9ed933be7b2538
(1,688,160 bytes), benchmark adapter is
16c90299b30480259f67d931ed2f65e320ed2674f2e06a976b8bbf44f69f8cbc,
and GTK4 native floor is
0ac343715de021af1af162564f31ac040b4f2937294e08acd9bd21e5d4e57970.

The paired
[PAINT-OPPORTUNITY session](./linux/bench/results/paint-opportunity/2026-09-18.kel28-linux-x11-xwayland-keld-vs-gtk4-30.fresh-process.json)
completed 30/30 valid samples per arm with balanced randomized order:

| Arm | Valid | Median | p90 | Bootstrap median CI95 |
|---|---:|---:|---:|---:|
| Keld keld-host --hello diagnostic | 30/30 | **900.0135 ms** | 978.703 | [884.8095, 916.529] |
| GTK4 + WebKitGTK native floor | 30/30 | **399.8605 ms** | 467.449 | [389.5035, 422.2935] |

The complete matched-round Keld/native ratio CI95 is **[2.142053, 2.316694]**,
so this X11-on-Xwayland diagnostic is FAIL against the registry's 1.05
regression threshold.
This is a same-session comparison, not a product scoreboard verdict: Keld still
uses the --hello benchmark adapter and Linux thermal state remains independently
unverified.

The corresponding
[MEM-IDLE session](./linux/bench/results/mem-idle/2026-09-18.kel28-linux-x11-xwayland-keld-memory-30.fresh-process.json)
also completed 30/30 valid samples. Keld main RSS median is **173,458 KiB**
(CI95 [173,394, 173,554]); helper RSS median is **234,214 KiB** and total
owned-tree RSS median is **407,682 KiB**. Main/helper private-dirty medians are
28,044 KiB and 31,500 KiB. These remain adapter diagnostics.

No second DISK document is emitted: the X11 run uses the exact same unmodified
Release host bytes as the existing current-main DISK result, so repeating a
deterministic file-size observation would create duplicate evidence.

Do not compute an X11-versus-Wayland speedup/regression by subtracting the two
sessions: they were measured at different times and the native arm is also
session-sensitive. What this session establishes is narrower and actionable:
under the forced X11 backend on Xwayland, Keld's diagnostic paint path is more
than 2.14x the matched native GTK4 arm at the lower bound of the paired CI.
A native Xorg login and the required non-Debian distro spot-check remain
unverified KEL-28 acceptance limbs.


### Paired shipping Bun client vs Rust library floor (2026-09-18)

To remove the separate-session ambiguity between the Linux Rust floor and Bun
product-client campaigns, a fresh-process paired campaign was run from
keld-benches 0ce40ea6e9b91af12efaf22d78bcb5ff2928b204 against Keld
0ea0780bb574ad242e9f1105fa4af5842872bad3. The full corpus was rerun after
the paired runner moved Rust case files into a private randomized temp directory.

The campaign used 20 paired rounds per payload tier. Tier order alternated by
round, and each arm ran first exactly 10/20 rounds per tier. Both arms scored
exactly 100,000 post-handshake CALL/REPLY operations per round. The Rust
fixture was invoked with 100,001 requested calls because its first call combines
HELLO plus the first CALL and is excluded from its deltas; the remaining
100,000 echo_invoke calls match the Bun arm's 100,000 scored
AppLinkSession.echo calls.

The 80 compact raw session documents and paired-round bootstrap are bound by the
[paired manifest](./linux/bench/results/ipc-rtt/2026-09-18.kel90-linux-bun-rust-paired.fresh-process.manifest.raw.json).

| Tier | Rust floor p50 | Bun client p50 | Paired p50 ratio CI95 | Rust floor p99 | Bun client p99 | Paired p99 ratio CI95 |
|---|---:|---:|---:|---:|---:|---:|
| small, 6 B | 7.597 µs | 15.186 µs | 1.999× [1.976, 2.024] | 11.796 µs | 30.567 µs | **2.591× [2.474, 2.701]** |
| representative, 1,024 B | 8.147 µs | 19.588 µs | 2.404× [2.380, 2.433] | 13.324 µs | 40.348 µs | **3.028× [2.930, 3.175]** |

At p99, the paired Bun-minus-Rust delta is **18.771 µs** with paired CI95
[17.805, 19.844] for 6 B and **27.024 µs** with CI95 [26.006, 28.305] for
1 KiB. The Bun arm's own p99 session-block CI is [29.567, 31.741] µs for
6 B and [39.422, 41.540] µs for 1 KiB, leaving about **3.15×** and
**2.41×** headroom respectively against the 100 µs architecture target at the
conservative CI upper bounds.

This is a product-client-versus-library-floor diagnostic, not a pure Bun
language/runtime tax. The Bun arm includes the shipping TypeScript codec,
AppLinkSession client, async scheduling and HostOwnedHelloSession product
orchestration; the Rust arm is the direct keld-ipc library floor. The paired
ratio therefore quantifies the distance from the shipping Bun slice to that
floor, not the cause of every additional nanosecond.

The two handshake fields are also not compared: the Rust fixture's
handshake_ns contains HELLO plus its first CALL/REPLY, while the Bun fixture's
handshake_ns measures AppLinkSession.connect/HELLO before any scored echo.
Only the post-handshake RTT samples are matched by this campaign.

All three fail-closed controls passed before timing: Rust forged-token rejection
reported server-side KELD-IPC-007 with no result file, while Bun bad-token and
wrong-response controls both failed without a timing result. Four 100,000-call
pilots passed the predeclared 300 µs p99 sanity stop.

This closes the fresh-process same-round Rust/Bun pairing gap for the Linux IPC
diagnostic. It does not make the result publication-eligible: thermal state is
still independently unverified, result-v2 still lacks the session-block corpus
shape, and the comparison remains product-client versus library floor rather
than identical host orchestration. The warm-cache Bun campaign remains
unpaired with a Rust warm-cache arm.


### Paired warm-cache shipping Bun client vs Rust library floor (2026-09-18)

The registered warm-cache treatment was then applied symmetrically to both arms
from keld-benches 7edcf60d8a0dc3120b9ca49e80b789676a403eb6 at the same
Keld 0ea0780bb574ad242e9f1105fa4af5842872bad3 pin.

Before scored rounds, each payload tier ran one unscored priming process for
each arm. Every scored Rust and Bun process then validated 1,000 untimed
post-handshake echoes before exactly 100,000 scored RTTs. The Rust client
requests 101,001 total calls in this state: call 1 carries HELLO + first CALL,
the next 1,000 are validated warmup calls, and the final 100,000 are timed.
The Bun arm uses its existing warm-cache path with 1,000 untimed
AppLinkSession.echo calls before timing.

The 20 paired rounds per tier retain the same balanced schedule as the fresh
campaign: each arm runs first exactly 10/20 rounds per tier, and the paired
bootstrap resamples identical round indices. The 80 scored raw documents are
bound by the
[paired warm manifest](./linux/bench/results/ipc-rtt/2026-09-18.kel90-linux-bun-rust-paired.warm-cache.manifest.raw.json).

| Tier | Rust floor p50 | Bun client p50 | Paired p50 ratio CI95 | Rust floor p99 | Bun client p99 | Paired p99 ratio CI95 |
|---|---:|---:|---:|---:|---:|---:|
| small, 6 B | 7.702 µs | 15.161 µs | 1.968× [1.944, 2.001] | 11.583 µs | 29.177 µs | **2.519× [2.431, 2.607]** |
| representative, 1,024 B | 8.052 µs | 19.469 µs | 2.418× [2.396, 2.442] | 13.340 µs | 38.305 µs | **2.871× [2.756, 2.986]** |

At p99, the paired Bun-minus-Rust delta is **17.594 µs** with paired CI95
[16.916, 18.314] for 6 B and **24.965 µs** with CI95 [24.083, 26.008] for
1 KiB. The Bun arm's own p99 session-block CI is [28.648, 29.788] µs for
6 B and [37.565, 39.253] µs for 1 KiB. At those conservative upper bounds,
the shipping Bun slice retains about **3.36×** and **2.55×** headroom
respectively against the 100 µs architecture target.

This remains a shipping product-client-versus-library-floor diagnostic, not a
pure Bun language/runtime tax. The Bun arm includes the shipping TypeScript
codec/client, async scheduling and HostOwnedHelloSession orchestration; the Rust
arm is the direct keld-ipc floor. The two handshake_ns fields remain
non-comparable because their timed intervals differ.

All fail-closed controls, four 100,000-call pilots, and all four priming
receipts passed before the scored campaign. The priming receipts are hash-bound
in the manifest following the existing warm-cache evidence convention; they are
not part of the 80 scored raw files.

Do not subtract this warm session from the fresh paired session to claim a
cache-state percentage improvement: they were separate campaigns at different
times. What is established is that, under the registered warm-cache treatment,
both paired arms remain reproducible and the shipping Bun slice remains
comfortably below the 100 µs p99 target.

This closes the remaining Linux warm-cache Rust/Bun same-round pairing gap.
Thermal state remains independently unverified and result-v2 still lacks the
session-block corpus shape, so the diagnostic remains publication-ineligible.


### Tauri 2.11.5 / WebKitGTK comparator admission status (2026-09-19)

KEL-90 includes a locked Tauri 2.11.5 Rust-only fixture with Wry 0.55.1 and
system WebKitGTK 2.52.6. The fixture has no Node/Bun sidecar and does not time
Tauri CLI or package startup. Any future comparison must use the same
runner-owned visible/focused double-rAF beacon as the other Linux paint arms.

No Tauri performance row is currently admitted.

An earlier feature-branch campaign reported 30/30 samples, but review found that
the caller-supplied Tauri executable was only checked against the
`provenance.json` beside that same executable. A caller could therefore provide
different executable bytes plus matching self-reported provenance. That
campaign was removed before merge and is not benchmark evidence.

The runner now independently rebuilds the exact committed Tauri fixture before
accepting a supplied artifact. Raw ELF files are not byte-reproducible because
GNU build-id bytes and the six-character `mktemp` build-directory suffix vary.
The trust check canonicalizes only those two observed build-metadata fields,
then requires the SHA-256 of every remaining executable byte to match the
independent rebuild. Ordinary artifact SHA/size and committed recipe-file
digests remain separate checks.

After adding that gate, clean trusted builds were exercised on the physical
Ubuntu 26.04.1 GNOME machine. Under both forced native Wayland and forced
X11-through-Xwayland the fixture requested the approved loopback page and
emitted the double-rAF beacon, but the runner rejected the beacon as
`document_not_focused`. Explicit Tauri window and webview focus experiments
did not make that condition reproducible, so those experimental fixture changes
were discarded rather than weakening the oracle.

The comparator therefore remains **measurement-blocked on focused-paint
admission** on this physical desktop. Future Tauri timing requires a committed,
trusted-build-reproducible fixture that satisfies the unchanged focus/visibility
oracle. Do not cite the withdrawn feature-branch PASS, rank Keld against Tauri
from it, or substitute an unfocused page-load timing.


### Shipping Linux `keld dev` product developer flow (2026-09-18)

A new Linux product arm measures the ordinary Release `keld dev` path rather
than the historical `keld-host --hello` navigation adapter. The fixture at
[`linux/keld/dev-hello`](./linux/keld/dev-hello/) is the exact seven-file output
of `keld create product-bench` at Keld
`0ea0780bb574ad242e9f1105fa4af5842872bad3`. A separately committed paint
script is injected only into a fresh owner-private temporary copy of the stock
renderer for each launch; Keld source and the committed generated project are
never patched.

The build recipe follows Keld's documented developer installation layout and
emits the sibling Release executables `keld`, `keld-host`, and
`keld-role-launcher`. Measurement artifacts are bound to keld-benches
`a15dc83f521f94294012f7bdfb182db6ac6297c4`. The executable receipts are:

- `keld`: 3,302,192 B, SHA-256 `673b9b7d52c6bcd4f3ccc2524bae6fcee80727c9156d702e4f68f0adb2f13ee6`;
- `keld-host`: 1,688,160 B, SHA-256 `665977e46ca76b2ae1f2bf6a4d82e1a7f1e689ac3953fc42c4fb45b5309cffa0`;
- `keld-role-launcher`: 406,960 B, SHA-256 `baa25723b136d5442bc197e1f000b35041dc2d23dcf26f7491ade1b69478a588`.

The three-file sum is 5,397,312 B. It is a developer sibling-set diagnostic,
**not** an installer, compressed package, update payload, or replacement for
the existing host-only DISK metric.

The first admitted product-flow lane is X11 through the machine's live GNOME
Xwayland server. Every measured process has `GDK_BACKEND=x11`, `DISPLAY=:0`,
and `WAYLAND_DISPLAY` unset. A valid sample must additionally prove the shipping
Bun-ready echo markers, one CLI, one staged host, at least one Bun process and
WebKit helper, then close the actual native X11 window, receive CLI exit code 0,
leave no captured descendant generation alive, and remove the per-launch stage.
All four 30-sample sessions below completed with **zero rejected samples** and
the same census on every run:
`bun:1,keld-cli:1,keld-host:1,sandbox-wrapper:2,webkit-network:1,webkit-web:1`.

#### Product developer-flow paint

| Cache state | Valid | Median | p90 | Min | Max | Bootstrap median CI95 |
|---|---:|---:|---:|---:|---:|---:|
| fresh-process | 30/30 | **973.723 ms** | 986.346 | 922.031 | 1007.782 | **[958.468, 981.844]** |
| warm-cache | 30/30 | **968.0375 ms** | 984.549 | 933.897 | 996.135 | **[960.5485, 974.6175]** |

Fresh-process evidence:
[`PAINT-OPPORTUNITY`](./linux/bench/results/paint-opportunity/2026-09-18.kel90-linux-product-dev-30.fresh-process.json).
Warm-cache evidence:
[`PAINT-OPPORTUNITY`](./linux/bench/results/paint-opportunity/2026-09-18.kel90-linux-product-dev-30.warm-cache.json).

The clock starts before spawning the shipping `keld dev` CLI and stops at the
nonce-bound double-rAF beacon in the real product window. The interval therefore
includes CLI doctor/staging, no-flag host startup, Linux strict-profile Bun
admission, the stock authenticated echo, WebKitGTK window creation and renderer
paint. This is intentionally a **developer-flow** observable, not packaged-app
startup. A raw GTK4 application is not treated as a paired baseline for this
lane because it does not perform equivalent CLI/staging/Bun work.

#### Product memory with preserved host denominator

The scored `MEM-IDLE` value remains staged `keld-host` RSS so this lane does not
silently redefine the existing metric. CLI, Bun, Keld-owned CLI+host and the
complete descendant-tree RSS are retained as diagnostics for every sample.
Four generation-identical memory censuses with bounded drift are required after
a valid paint, followed by the same native-close lifecycle gate.

| Cache state | Host RSS median | Host CI95 | CLI RSS median | Bun RSS median | CLI+host median | Full tree RSS median |
|---|---:|---:|---:|---:|---:|---:|
| fresh-process | **173,102 KiB** | **[173,052, 173,154]** | 36,990 KiB | 22,742 KiB | 210,090 KiB | **468,718 KiB** |
| warm-cache | **173,056 KiB** | **[172,994, 173,098]** | 36,988 KiB | 22,742 KiB | 210,032 KiB | **468,664 KiB** |

Fresh-process private-dirty medians are 28,176 KiB for the host, 43,236 KiB
for the remaining tree, and 71,416 KiB total. Warm-cache medians are 28,172,
43,224 and 71,418 KiB respectively. The associated paint medians inside the
memory sessions are 974.862 ms fresh and 970.862 ms warm.

Fresh evidence:
[`MEM-IDLE`](./linux/bench/results/mem-idle/2026-09-18.kel90-linux-product-dev-memory-30.fresh-process.json).
Warm evidence:
[`MEM-IDLE`](./linux/bench/results/mem-idle/2026-09-18.kel90-linux-product-dev-memory-30.warm-cache.json).

All four documents remain publication-ineligible for three explicit reasons:
Linux thermal state is independently unverified, there is no semantically
matched paired arm for this full developer flow, and the observable is
`keld dev` developer startup rather than packaged-app startup. They do **not**
carry the historical `DIAGNOSTIC_HELLO_ONLY` or `BENCHMARK_ADAPTER_ARTIFACT`
blockers.

Fresh and warm sessions were separate campaigns. Their paint and memory CIs
overlap, so the data do not support a causal percentage claim for cache warming.
They establish instead that the full shipping Linux developer flow is stable at
roughly 0.97 s to double-rAF paint on this X11/Xwayland machine, while the host
RSS denominator stays near 173 MiB and the complete observed descendant tree is
about 469 MiB. Native Xorg, Wayland product-flow automation, non-Debian Linux,
and packaged release startup remain separate unmeasured limbs.


### Shipping Linux `keld dev` product flow — native Wayland (2026-09-18)

The same shipping `linux/keld/dev-hello` developer-flow arm was qualified on
the machine's native GNOME Wayland session. Measurement forces
`GDK_BACKEND=wayland`, keeps `WAYLAND_DISPLAY=wayland-0`, removes `DISPLAY`,
and records the resulting backend state in every result document.

Wayland lifecycle closure is not signal-based. The runner queries the live
AT-SPI bus, binds the accessibility application to the captured `keld-host`
PID, requires exactly one `product-bench` frame and one accessible `Close`
button, invokes that button's `click` action, and then applies the same normal
lifecycle gates as the X11 lane: CLI exit code 0, per-launch stage removal, and
no captured CLI/host/Bun/WebKit generation left alive. Cleanup signals remain a
failure-recovery path and do not satisfy the lifecycle oracle.

The benchmark recipe is
`d23e55cb2320ed15c3ffca409e4074eca577ba4b`; Keld remains pinned to
`0ea0780bb574ad242e9f1105fa4af5842872bad3`. The three shipping executable
artifacts are byte-identical to the prior X11 product campaign.

#### Native Wayland product paint

Both 30-sample sessions completed with zero rejected samples and the same
10-process census on every scored launch:
`bun:1,keld-cli:1,keld-host:1,other-descendant:1,sandbox-wrapper:4,webkit-network:1,webkit-web:1`.

| Cache state | Valid | Median | p90 | Min | Max | Bootstrap median CI95 |
|---|---:|---:|---:|---:|---:|---:|
| fresh-process | 30/30 | **533.646 ms** | 561.148 | 513.018 | 601.560 | **[524.7025, 543.4085]** |
| warm-cache | 30/30 | **542.832 ms** | 565.752 | 511.209 | 576.556 | **[529.963, 549.687]** |

Fresh evidence:
[`PAINT-OPPORTUNITY`](./linux/bench/results/paint-opportunity/2026-09-18.kel90-linux-product-wayland-30.fresh-process.json).
Warm evidence:
[`PAINT-OPPORTUNITY`](./linux/bench/results/paint-opportunity/2026-09-18.kel90-linux-product-wayland-30.warm-cache.json).

Every scored sample proves the Bun-ready IPC markers, exact PID-bound Wayland
close action, product exit code 0, stage cleanup and generation-bound descendant
cleanup. The paint interval remains the developer-flow observable from shipping
`keld dev` spawn to nonce-bound double-rAF in the real product window.

#### Native Wayland product memory

The scored denominator remains staged `keld-host` RSS, preserving the existing
`MEM-IDLE` contract. CLI, Bun, helper and total-tree values remain diagnostics.

| Cache state | Host RSS median | Host CI95 | CLI RSS median | Bun RSS median | CLI+host median | Full tree RSS median |
|---|---:|---:|---:|---:|---:|---:|
| fresh-process | **179,710 KiB** | **[179,648, 179,800]** | 36,998 KiB | 21,604 KiB | 216,732 KiB | **494,352 KiB** |
| warm-cache | **179,818 KiB** | **[179,738, 179,860]** | 37,020 KiB | 21,604 KiB | 216,846 KiB | **494,744 KiB** |

Fresh private-dirty medians are 30,552 KiB for the host, 45,394 KiB for the
remaining tree, and 75,978 KiB total. Warm medians are 30,550, 45,422 and
76,000 KiB respectively. Associated paint medians inside the memory sessions
are 545.902 ms fresh and 542.947 ms warm.

Fresh evidence:
[`MEM-IDLE`](./linux/bench/results/mem-idle/2026-09-18.kel90-linux-product-wayland-memory-30.fresh-process.json).
Warm evidence:
[`MEM-IDLE`](./linux/bench/results/mem-idle/2026-09-18.kel90-linux-product-wayland-memory-30.warm-cache.json).

All four native-Wayland documents remain diagnostic-only for the same explicit
reasons as the X11 product arm: Linux thermal state is independently unverified,
there is no semantically matched paired arm for the full developer flow, and
`keld dev` developer startup is not packaged-app startup. They do not carry the
historical `DIAGNOSTIC_HELLO_ONLY` or `BENCHMARK_ADAPTER_ARTIFACT` blockers.

Fresh and warm sessions were separate campaigns and their confidence intervals
overlap; no causal cache-state improvement is claimed. The earlier X11/Xwayland
product-flow campaign and this Wayland campaign were also measured in separate
sessions. Their medians may be reported as separate observations, but subtracting
or dividing them to claim a backend speedup/regression is not admitted evidence.
A balanced same-session backend comparison is required before attributing the
large observed difference to X11 versus Wayland itself.


### Same-session shipping product backend pair: Wayland vs X11 (2026-09-19)

The Linux runner now supports a matched shipping `keld dev` backend pair. Each
round launches the same provenance-bound product artifact once with native
Wayland and once with X11 through the live GNOME Xwayland server. Arm order is
balanced and randomized: exactly 15 Wayland-first and 15 X11-first rounds per
30-round campaign.

Both arms require the stock authenticated Bun echo, nonce-bound double-rAF
paint, complete product process census, backend-native close, exit 0, stage
cleanup and generation-bound descendant cleanup. This removes cross-session
drift, but it does **not** isolate display backend on proprietary NVIDIA:
Keld's shipping Wayland path may activate its DMA-BUF safe mode while the X11
path does not.

The benchmark recipe is `c17bdad8547794b23814acb13a4590a9d9f30b3c` and Keld
remains pinned to `0ea0780bb574ad242e9f1105fa4af5842872bad3`.

#### Paint

| cache | Wayland median | X11 median | paired X11/Wayland CI95 |
|---|---:|---:|---:|
| fresh-process | **549.6235 ms** | **963.911 ms** | **[1.735841, 1.793650]** |
| warm-cache | **553.242 ms** | **967.000 ms** | **[1.725116, 1.783941]** |

Both campaigns completed 30/30 valid samples per arm. The paired diagnostic
verdict is `FAIL` against the registry's 1.05 regression threshold in both
cache states. The ratio is a valid same-session comparison of the two
**shipping policies**, but it must not be attributed to display backend alone.

**Correction (2026-09-19):** a post-merge runtime probe of the same pinned
shipping artifact observed `WEBKIT_DISABLE_DMABUF_RENDERER=1` in the Wayland
`keld-host` and the variable absent in the X11 `keld-host`. The Keld product
predicate intentionally applies that safe mode on proprietary NVIDIA +
Wayland. Therefore PR #37 jointly varied display backend and effective
DMA-BUF policy. The later X11 DMA-BUF isolation below shows that this policy
itself has a large paint effect on this machine. The immutable PR #37 result
documents are retained as measured shipping-policy evidence; only the earlier
pure-backend interpretation is withdrawn.

#### Memory

The scored MEM-IDLE value remains the staged `keld-host` RSS.

| cache | Wayland host RSS | X11 host RSS | paired X11/Wayland CI95 |
|---|---:|---:|---:|
| fresh-process | **179,686 KiB** | **173,020 KiB** | **[0.962524, 0.963291]** |
| warm-cache | **179,640 KiB** | **173,006 KiB** | **[0.962572, 0.963300]** |

The full owned-tree medians are 494,206 KiB Wayland vs 468,552 KiB X11 in the
fresh-process campaign, and 494,268 KiB Wayland vs 468,290 KiB X11 in the
warm-cache campaign. Because effective DMA-BUF policy also differed, neither
the paint nor memory delta may be assigned to backend alone; the two
observables also must not be collapsed into one score.

All four documents remain diagnostic-only because Linux thermal state is not
independently verified and the measured observable is the shipping `keld dev`
developer flow, not packaged-app startup. Fresh and warm are separate campaigns;
the paired comparison is only between Wayland and X11 within each campaign.

A native Xorg login is still not measured: the X11 arm uses the live Mutter
Xwayland server. KEL-28's non-Debian distro spot-check also remains open.


### Linux X11 NVIDIA DMA-BUF mitigation diagnostic — 2026-09-19

This diagnostic isolates one Linux rendering variable inside the shipping
`keld dev` product path. Both arms use the same Keld artifact pinned to
`0ea0780bb574ad242e9f1105fa4af5842872bad3`, the same X11 display through
the live Mutter Xwayland server, and the same authenticated Bun/WebKitGTK
lifecycle. The benchmark recipe recorded by the result documents is
`908eb479e5749176d901c8c3d8f89a3c4744917f`.

The baseline removes `WEBKIT_DISABLE_DMABUF_RENDERER`; the candidate sets
it to exactly `1`. Both arms force `GDK_BACKEND=x11` and run with
`WAYLAND_DISPLAY` removed. The preflight refuses this lane unless the
NVIDIA proprietary driver is loaded. This is a bounded diagnostic for the
measured NVIDIA/X11 cell, not a generic Linux policy.

A later harness-isolation commit, `3a2bb7a5600290309f9d212400ed03d98d9b2387`,
restores the existing Wayland-vs-X11 backend-pair implementation byte-for-byte
from `main` and keeps this DMA-BUF experiment in its own runner lane. Result
provenance intentionally remains pinned to the immutable recipe that actually
produced the samples.

#### Paint

| cache | normal X11 median | DMA-BUF disabled median | paired disabled/normal CI95 |
|---|---:|---:|---:|
| fresh-process | **1004.266 ms** | **436.901 ms** | **[0.421042, 0.443460]** |
| warm-cache | **1008.5045 ms** | **425.132 ms** | **[0.413981, 0.433347]** |

Both retained paint sessions completed **30/30 valid samples per arm** with
balanced randomized ordering. The mitigation effect is large in both
independent cache-state campaigns, but fresh and warm are separate sessions
and are not subtracted into a causal cache percentage.

#### Memory

The fresh-process MEM-IDLE campaign also completed **30/30 per arm**.

| lane | normal X11 | DMA-BUF disabled | paired disabled/normal CI95 |
|---|---:|---:|---:|
| scored `keld-host` RSS | **173,324 KiB** | **165,838 KiB** | **[0.956242, 0.957744]** |
| full owned tree RSS median | **469,170 KiB** | **460,588 KiB** | diagnostic only |
| paint observed inside memory samples | **1002.706 ms** | **433.775 ms** | diagnostic only |

The mitigation therefore does not buy paint latency by increasing the measured
resident-memory lanes on this host; both scored host RSS and full-tree RSS are
lower in the disabled-DMA-BUF arm.

#### Rejection and stop-rule record

The retained documents are not the only campaigns that ran. Pre-publication
sessions were rejected rather than selectively trimmed:

- one 30-pair fresh-paint campaign failed completeness because the strict
  focus oracle rejected samples as `document_not_focused`; no paired verdict
  was emitted;
- the one full retry completed 30/30 + 30/30 but an unrelated clean Keld/Rust
  build overlapped the timing session, visibly inflating the tails, so that
  session was rejected as performance evidence despite its valid sample count;
- after those observations, a stricter quiet-host rule was recorded on KEL-90:
  no compiler/build process, no second benchmark runner, and <=10% NVIDIA GPU
  utilization at admission, with a side monitor during the session;
- the single campaign allowed under that revised rule was rejected in full
  because the monitor observed overlapping MEM-IDLE benchmark processes during
  **280 of 349** monitor samples. The benchmark itself also returned nonzero.
  Per the predeclared rule, there was **no further paint retry**;
- a warm-cache MEM-IDLE session that overlapped that monitored campaign was
  likewise excluded from the public result set.

The two retained 30/30 paint sessions were collected before the stricter
quiet-host rule was introduced. They remain useful, reproducible diagnostics
under the repository's normal result contract, but they are **not claimed as
quiet-host-certified publication evidence**.

The separate KEL-171 fixture remains the repository's correctness protocol for
DMA-BUF policy work. These timing and memory diagnostics do not replace that
matrix and do not authorize a production safe-mode predicate change.

All three committed result documents remain diagnostic-only because Linux
thermal state is independently unverified and the observable begins at the
shipping `keld dev` CLI rather than packaged-application startup. No Keld
production GPU predicate is changed by this benchmark work.


### Linux Keld host adapter vs trusted Tauri WebKitGTK comparator — 2026-09-19

The Linux Tauri comparator is now timing-admissible again under the unchanged
visible/focused double-rAF oracle. The earlier feature-branch timing was
withdrawn because its artifact trust path was insufficient and later trusted
builds reproduced `document_not_focused`. This refresh does not weaken that
oracle: a fresh Tauri 2.11.5 / WebKitGTK 2.52.6 build at benchmark recipe
`a4dcefd11e37cfb7a9726e4d3de4e0a8fd8567b0` was independently rebuilt by
the harness and passed the same focus/visibility checks on both native Wayland
and X11 through Mutter Xwayland.

Both retained sessions use the true-black launch surface required by the
cross-OS presentation policy. The Keld arm is pinned to
`0ea0780bb574ad242e9f1105fa4af5842872bad3`; its benchmark-adapter artifact
SHA-256 is
`16c90299b30480259f67d931ed2f65e320ed2674f2e06a976b8bbf44f69f8cbc`.
The Tauri artifact SHA-256 is
`dcde26386571f0b46830b9cef9a15ccd57b73610fab08098a299336171472a2e`.

#### Native Wayland

Fresh-process, 30 matched rounds per arm, exactly 15 Keld-first and 15
Tauri-first:

| arm | median | p90 | bootstrap median CI95 |
|---|---:|---:|---:|
| Keld `keld-host --hello` adapter | **472.2645 ms** | 491.579 | [462.605, 479.4415] |
| Tauri 2.11.5 / WebKitGTK | **462.413 ms** | 485.546 | [458.913, 472.306] |

The paired Keld/Tauri ratio CI95 is **[0.988868, 1.033292]**, which is inside
the registry's 1.05 diagnostic regression threshold. The interval crosses
1.0, so this is not evidence for a directional Keld-vs-Tauri speed claim.

#### X11 through Mutter Xwayland

Fresh-process, 30 matched rounds per arm, exactly 15 Keld-first and 15
Tauri-first:

| arm | median | p90 | bootstrap median CI95 |
|---|---:|---:|---:|
| Keld `keld-host --hello` adapter | **890.959 ms** | 923.872 | [880.298, 901.8825] |
| Tauri 2.11.5 / WebKitGTK | **911.5415 ms** | 930.755 | [902.341, 919.620] |

The paired Keld/Tauri ratio CI95 is **[0.960346, 1.002498]**, also inside the
1.05 diagnostic threshold. That interval also crosses 1.0; the lower Keld
median must not be reported as a superiority result.

The Wayland and X11 comparator sessions are independent campaigns, so their
medians are not used to claim a causal backend percentage here. The separate
same-session Keld backend-pair evidence owns backend attribution.

Both documents remain publication-ineligible because Linux thermal state is
not independently verified and the Keld arm is the committed
`keld-host --hello` benchmark adapter rather than the shipping no-flag or
`keld dev` product startup path. X11 here is Xwayland, not native Xorg.


### Controlled product backend pair: matched DMA-BUF-disabled policy (2026-09-19)

The earlier shipping-policy Wayland/X11 pair did not isolate display backend on
this proprietary-NVIDIA host because Keld's Wayland safe-mode path set
`WEBKIT_DISABLE_DMABUF_RENDERER=1` while the X11 path left it absent. This
follow-up holds that rendering-policy variable equal.

Both arms use the same Keld `0ea0780bb574ad242e9f1105fa4af5842872bad3`
product artifacts rebuilt from benchmark recipe
`ad3486d5e071b076d5873131e8cac717c726f902`. The benchmark parent sets
`WEBKIT_DISABLE_DMABUF_RENDERER=1`, and every accepted sample independently
reads the generation-bound `keld-host` environment and records the effective
value as exactly `1` for both Wayland and X11/Xwayland. Every 30-round
campaign is balanced 15 Wayland-first / 15 X11-first.

#### Paint with matched DMA-BUF policy

| cache | Wayland median | X11/Xwayland median | paired X11/Wayland CI95 |
|---|---:|---:|---:|
| fresh-process | **567.2715 ms** | **421.8185 ms** | **[0.736418, 0.759332]** |
| warm-cache | **566.4985 ms** | **427.926 ms** | **[0.747259, 0.777132]** |


Both paint campaigns completed 30/30 valid samples per arm. Under this one
matched DMA-BUF-disabled policy on this machine, X11/Xwayland has lower
shipping-`keld dev` paint latency than native Wayland. This is a bounded
backend comparison for the measured NVIDIA/WebKitGTK/GNOME cell, not a claim
that X11 is generally faster.

The direction reversal relative to the earlier shipping-policy pair confirms
that the earlier 1.73–1.79x X11/Wayland ratio was materially confounded by
effective DMA-BUF policy. It does not by itself quantify a standalone causal
"safe-mode cost" across the two separately executed campaigns.

#### Memory with matched DMA-BUF policy

| cache | Wayland host RSS | X11/Xwayland host RSS | paired X11/Wayland CI95 |
|---|---:|---:|---:|
| fresh-process | **180,848 KiB** | **166,922 KiB** | **[0.922366, 0.923342]** |
| warm-cache | **180,878 KiB** | **166,930 KiB** | **[0.922059, 0.923271]** |

Full-tree RSS medians were 501,446 KiB Wayland vs 467,376 KiB X11 in the
fresh-process campaign and 502,144 KiB Wayland vs 467,368 KiB X11 in the
warm-cache campaign.

All four results remain diagnostic-only because Linux thermal state is not
independently verified and the measured observable is the shipping `keld dev`
developer flow rather than packaged-app startup. X11 is still Mutter Xwayland,
not a native Xorg login.

### Fedora 43 bounded non-Debian acceptance receipt (2026-09-19)

KEL-28 now has a public receipt bundle at
`linux/keld/fedora43-acceptance/` for the bounded Fedora 43 spot-check. The
exact Keld pin is `0ea0780bb574ad242e9f1105fa4af5842872bad3`. A pinned Fedora
43 userland produced a locked Fedora-built host, and a Fedora-owned Xvfb +
Fluxbox X11 control passed title/PID binding, resize, minimize/restore, native
close, exit 0, and process reap. Package, toolchain, runtime, dynamic-link and
artifact-hash receipts are committed beside the capture manifest.

This is correctness/portability evidence, not a result.v2 performance row. The
Fedora environment ran under Docker Desktop rather than a bare-metal Fedora
login, and the accepted lifecycle oracle is Fedora-owned Xvfb + Fluxbox. It
does not qualify native Xorg on the physical Ubuntu machine, Fedora Wayland,
end-to-end Fedora `keld dev`, packaged startup, or release support.

### Arch Linux bounded build-portability receipt (2026-09-19)

KEL-28 also has a public Arch Linux build-portability receipt at
`linux/keld/arch-build-portability/`. The exact Keld pin is
`0ea0780bb574ad242e9f1105fa4af5842872bad3`. A pinned Arch userland produced a
locked Release host using the recorded GTK3/WebKitGTK 4.1/libsoup3/bubblewrap
package mapping, and the captured dynamic-link census reports zero unresolved
links. Artifact size/hash plus Rust/Cargo/GTK/WebKitGTK versions are committed as
receipts; generated binaries remain omitted and hash-bound.

This is build/package portability evidence only. It does not establish an Arch
desktop runtime, X11/Wayland lifecycle behavior, end-to-end `keld dev`,
containment behavior, release support, or a performance result.


### Fedora 44 native-Xorg VM acceptance attempt — failed before window creation (2026-09-19)

KEL-28 now has a sanitized public failure receipt at
`linux/keld/fedora44-xorg-vm-attempt/` for a Fedora 44 KVM guest with a real
guest Xorg server and Fluxbox window manager. The exact Keld source pin is
`0ea0780bb574ad242e9f1105fa4af5842872bad3`.

The guest built the shipping Keld CLI/host/role-launcher under Fedora 44 and
attempted the ordinary `keld create` + `keld dev` path. Strict runtime
admission failed with `KELD-RUNTIME-016` on a missing runtime-mount source,
followed by `KELD-CLI-048`; neither IPC echo, the ready marker, nor a visible
Keld window was reached.

This is failure/portability evidence, not a result.v2 performance row and not a
Fedora qualification. The multi-gigabyte VM base/overlay and ephemeral SSH
credentials are intentionally omitted; only sanitized receipts and hashes are
committed. Native Xorg on the physical Ubuntu host and successful Fedora
product-path acceptance remain open.


### Thermally verified shipping Bun IPC result.v3 corpus (2026-09-19)

The shipping Linux Bun product-client IPC campaign was rerun from
keld-benches `896198601e2bfbae88ad6c877473b4ee0ce40c27` against Keld
`0ea0780bb574ad242e9f1105fa4af5842872bad3` after the Linux thermal-boundary
oracle and result-v3 block-corpus contract landed.

The fresh-process campaign completed the registered IPC sample policy in full:
20 independent sessions × 100,000 scored calls × two payload tiers, for
2,000,000 scored RTT observations per tier. All 40 scored raw documents remain
compact one-line JSON sidecars. Each v3 tier document records only the 20 block
receipts, sidecar SHA-256/byte counts, the ordered digest chain, block-bootstrap
metadata, and pooled statistics.

The measured thermal boundary was **nominal**: CPU package temperature moved
from 71 C to 74 C against the hardware-reported 100 C critical threshold, no
CPU thermal-throttle counter advanced, and the NVIDIA GPU remained at 48 C
with both software and hardware thermal-slowdown flags inactive.

| Tier | Payload | p50 | p90 | p99 | 95% session-block bootstrap CI p99 |
|---|---:|---:|---:|---:|---:|
| small | 6 B | **15.128 us** | 20.380 us | **27.377 us** | **[26.889, 27.863] us** |
| representative | 1,024 B | **19.053 us** | 26.250 us | **35.634 us** | **[34.980, 36.257] us** |

At the p99 CI upper bounds, the shipping Bun slice retains approximately
**3.59×** headroom for the 6-byte tier and **2.76×** for the 1 KiB tier against
the 100 us architecture target.

The new result-v3 documents are:

- `2026-09-19.kel90-linux-bun-product-client-small.fresh-process.json`
- `2026-09-19.kel90-linux-bun-product-client-representative.fresh-process.json`

Each document binds 20 real raw sidecars and 2,000,000 observations while
remaining roughly 14 KB. The per-call vectors are not expanded into the result
document, so this evidence does not recreate the historical multi-million-line
JSON-diff failure mode.

The new p99 intervals overlap the corresponding 2026-09-18 fresh-process
intervals. That is useful reproducibility evidence, but the two campaigns were
separate sessions and must not be subtracted into a causal speedup/regression
claim.

The documents remain **diagnostic-only** for one explicit scope reason:
`NO_SAME_SESSION_PAIRED_RUST_ARM`. The prior thermal-state and result-v2
session-block schema blockers are absent. The scored interval is still the
shipping Bun `AppLinkSession.echo` / `HostOwnedHelloSession` slice; it does
not include a renderer/window or full `keld dev` startup.
