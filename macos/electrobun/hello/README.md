# Electrobun hello — macOS

Official `electrobun init` **hello-world** template (Electrobun **1.18.1**),
slimmed to one 960×640 window + local HTML. System webview (`bundleCEF: false`)
+ bundled **Bun**. **Release weigh is `bunx electrobun build --env=stable`.**

Do not vendor Bun runtimes, `node_modules/`, `build/`, or `artifacts/`.

## Requires

- Bun (this machine: 1.3.14)
- `bun install` then `bunx electrobun build --env=stable` (downloads
  `electrobun-core-darwin-arm64` on first build)

## Build (Release)

```bash
cd macos/electrobun/hello
bun install
bunx electrobun build --env=stable
```

Lanes (different — do not blend):

| Lane | Path |
|---|---|
| Self-extracting `.app` (zstd payload inside) | `build/stable-macos-arm64/Electrobun Hello.app` |
| zstd tarball artifact | `artifacts/stable-macos-arm64-ElectrobunHello.app.tar.zst` |
| Extracted `.app` after first launch | `~/Library/Application Support/com.keld.benches.electrobun/stable/self-extraction/Electrobun Hello.app` |

## Weigh

See [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md) (2026-08-14).
The wrapped `.app` stays ~18 MB until first launch extracts Bun + launcher.

For the shared KEL-64 oracle, the harness supplies `KELD_BENCH_URL`; the Bun
entrypoint opens that loopback URL when present and keeps the bundled view otherwise.
The entrypoint creates the window hidden, calls the documented
`BrowserWindow.show()` and `activate()` lifecycle methods after the WebView is
attached, then starts navigation with the documented `BrowserView.loadURL()`
method. This ordering keeps the externally supplied page visible and active
when the oracle samples its double-rAF beacon.
