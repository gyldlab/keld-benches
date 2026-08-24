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

† Corrected: median-index bug; see this repair PR. This table does not reconstruct or
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

† Corrected: median-index bug; see this repair PR.

Run B — baseline backend (`keld` main @ `137633f`, wry):

| Stack | first paint | main RSS | procs |
|---|---|---|---|
| Electron 43.4.0† <!-- raw-median source=windows-first-paint-kel65-baseline.json arm=electron fields=first_paint_ms,main_rss_kb,processes --> | 286 ms | 88,960 KB | 4 |
| **Keld (wry)†** <!-- raw-median source=windows-first-paint-kel65-baseline.json arm=keld fields=first_paint_ms,main_rss_kb,processes --> | **467 ms** | **21,972 KB** | 7 |
| Tauri 2.11.5† <!-- raw-median source=windows-first-paint-kel65-baseline.json arm=tauri fields=first_paint_ms,main_rss_kb,processes --> | 490 ms | 26,760 KB | 7 |

† Corrected: median-index bug; see this repair PR.

Raw samples: [`windows/bench/windows-first-paint-kel65-direct-com.json`](./windows/bench/windows-first-paint-kel65-direct-com.json),
[`windows/bench/windows-first-paint-kel65-baseline.json`](./windows/bench/windows-first-paint-kel65-baseline.json),
[`windows/bench/windows-first-paint-kel66-smartscreen-off.json`](./windows/bench/windows-first-paint-kel66-smartscreen-off.json).

SmartScreen isolation from those same committed raws:

| SmartScreen | first paint |
|---|---|
| ON† <!-- raw-median source=windows-first-paint-kel65-direct-com.json arm=keld fields=first_paint_ms --> | 469 ms |
| OFF† <!-- raw-median source=windows-first-paint-kel66-smartscreen-off.json arm=keld fields=first_paint_ms --> | 453 ms |

† Corrected: median-index bug; see this repair PR.

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
