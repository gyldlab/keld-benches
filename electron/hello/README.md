# Electron hello (stub)

Scaffold with the **official** Electron release tooling (Forge or
`npm create electron-app@latest` / current Electron docs). Place app sources in
this directory. **Do not** commit Chromium, Electron prebuilds, or
`node_modules`.

## Weigh recipe (outline)

1. Create a minimal hello window that loads static HTML (same spirit as Keld /
   Swift fixtures — one window, no extras).
2. Build a **Release** package for the host OS/arch (darwin/arm64 first).
3. Record in [`../../MEASUREMENTS.md`](../../MEASUREMENTS.md): zip / `.app`
   unpacked size, UDZO or installer if used, idle main-process RSS (and note
   Chromium helpers separately).
4. Mirror a one-line summary into Keld `docs/engineering/budget-scoreboard.md`
   with a link to `electron/hello/`.

Chromium-class: do not put these numbers in the same `vs` cell as system
WebKit (Swift / Tauri / Wails / Keld host).
