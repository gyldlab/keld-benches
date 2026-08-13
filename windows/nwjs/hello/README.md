# NW.js hello — Windows (stub)

Scaffold with the **official** NW.js release tooling for Windows.
Chromium + Node. **Do not** commit NW.js SDK / Chromium trees.

## Weigh recipe (outline)

1. Minimal hello window (same spirit as Keld / Swift fixtures — one window).
2. Build a **Release** Windows pack (Windows zip / installer; Chromium-class fairness rules.).
3. Record installer / unpacked sizes and idle main-process RSS in
   [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `windows/nwjs/hello/`.

Place sources under this OS folder only — never at the repo root.
