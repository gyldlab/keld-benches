# Electrobun hello — Windows (stub)

Scaffold with the **official** Electrobun release tooling for Windows.
system webview + Bun. **Do not** vendor Bun runtimes.

## Weigh recipe (outline)

1. Minimal hello window (same spirit as Keld / Swift fixtures — one window).
2. Build a **Release** Windows pack (Windows pack; note WebView2 / runtime separately.).
3. Record installer / unpacked sizes and idle main-process RSS in
   [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `windows/electrobun/hello/`.

Place sources under this OS folder only — never at the repo root.
