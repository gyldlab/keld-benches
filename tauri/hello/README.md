# Tauri hello (stub)

Scaffold with the **official** `create-tauri-app` (Tauri 2) release path. Place
app sources here. **Do not** vendor Rust `target/`, Node `node_modules`, or
platform toolchains.

## Weigh recipe (outline)

1. Minimal hello window + system webview (WKWebView on macOS).
2. `tauri build` (Release) for darwin/arm64 first.
3. Record `.app` / DMG / MSI sizes and idle RSS in
   [`../../MEASUREMENTS.md`](../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `tauri/hello/`.

Same engine class as Keld / Swift (system webview) — fair for WK `vs` cells
when measured same-day Release.
