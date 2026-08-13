# Wails hello — Linux (stub)

Scaffold with the **official** Wails release tooling for Linux.
system **WebKitGTK**. **Do not** vendor Go caches.

## Weigh recipe (outline)

1. Minimal hello window (same spirit as Keld / Swift fixtures — one window).
2. Build a **Release** Linux pack (AppImage / binary; note WebKitGTK.).
3. Record installer / unpacked sizes and idle main-process RSS in
   [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `linux/wails/hello/`.

Place sources under this OS folder only — never at the repo root.
