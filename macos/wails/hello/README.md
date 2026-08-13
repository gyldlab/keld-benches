# Wails hello — macOS (stub)

Scaffold with the **official** Wails CLI hello / init for a Release build. Place
app sources here. **Do not** vendor Go module caches or full frontend
`node_modules` trees if avoidable (gitignore them).

## Weigh recipe (outline)

1. Minimal hello window using the system webview (WKWebView).
2. Production / Release build for darwin/arm64 first.
3. Record binary / `.app` / installer sizes and idle RSS (main process vs WebKit
   helpers) in [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `macos/wails/hello/`.
