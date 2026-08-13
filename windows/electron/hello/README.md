# Electron hello — Windows (stub)

Scaffold with the **official** Electron release tooling for Windows.
Chromium + Node; official Forge / create-electron-app. **Do not** vendor Chromium.

## Weigh recipe (outline)

1. Minimal hello window (same spirit as Keld / Swift fixtures — one window).
2. Build a **Release** Windows pack (MSI / NSIS / portable zip; note WebView2 is irrelevant for Electron (ships Chromium).).
3. Record installer / unpacked sizes and idle main-process RSS in
   [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `windows/electron/hello/`.

Place sources under this OS folder only — never at the repo root.
