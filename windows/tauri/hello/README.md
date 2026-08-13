# Tauri 2 hello — Windows (stub)

Scaffold with the **official** Tauri 2 release tooling for Windows.
system **WebView2**; official `create-tauri-app`. **Do not** vendor `target/`.

## Weigh recipe (outline)

1. Minimal hello window (same spirit as Keld / Swift fixtures — one window).
2. Build a **Release** Windows pack (MSI / NSIS; record whether WebView2 Evergreen was bootstrapped.).
3. Record installer / unpacked sizes and idle main-process RSS in
   [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `windows/tauri/hello/`.

Place sources under this OS folder only — never at the repo root.
