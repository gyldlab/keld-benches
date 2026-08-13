# Electrobun hello (stub)

Scaffold with the **official** Electrobun hello / create path. Place app sources
here. **Do not** vendor Bun runtimes or large binary caches — gitignore them.

## Weigh recipe (outline)

1. Minimal hello window (system webview + Bun).
2. Official Release / pack for darwin/arm64 first (note zstd vs uncompressed
   `.app` separately — they are different lanes).
3. Record installer / `.app` / zstd sizes and idle RSS in
   [`../../MEASUREMENTS.md`](../../MEASUREMENTS.md).
4. Mirror summary into Keld `docs/engineering/budget-scoreboard.md` →
   `electrobun/hello/`.
