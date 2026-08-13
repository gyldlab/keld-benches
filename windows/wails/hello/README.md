# Wails hello — Windows (stub)

Scaffold with the **official** Wails release tooling for Windows.
system **WebView2**. **Do not** vendor Go caches.

## Weigh recipe (outline)

1. Minimal hello window (same spirit as Keld / Swift fixtures — one window).
2. Build a **Release** Windows pack (Windows installer / exe; note WebView2 runtime.).
3. Record installer / unpacked sizes and idle main-process RSS in
   [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `windows/wails/hello/`.

Place sources under this OS folder only — never at the repo root.
