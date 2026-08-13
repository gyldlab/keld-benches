# NW.js hello — Linux (stub)

Scaffold with the **official** NW.js release tooling for Linux.
Chromium + Node. **Do not** commit SDK trees.

## Weigh recipe (outline)

1. Minimal hello window (same spirit as Keld / Swift fixtures — one window).
2. Build a **Release** Linux pack (Linux zip / AppImage; Chromium-class fairness.).
3. Record installer / unpacked sizes and idle main-process RSS in
   [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `linux/nwjs/hello/`.

Place sources under this OS folder only — never at the repo root.
