# Electron hello — macOS

Official Electron **v43.4.0** darwin/arm64 runtime (`electron-v43.4.0-darwin-arm64.zip`)
plus a Forge-style hello (`npx create-electron-app@latest` base template, slimmed
to one 960×640 window + local HTML). **Weigh the packaged `.app`**, not
`electron .` / `npm start`.

Chromium-class: do not put these numbers in the same `vs` cell as system
WebKit (Swift / Tauri / Wails / Neutralino / Keld host).

## Requires

- Node.js (this machine: npm 11 / Node 26) to install Electron
- Apple Silicon Mac for `darwin/arm64`

## Package (Release `.app`)

The tracked recipe below assembles the **same official zip** with `ditto`,
because Forge's macOS `extract-zip` step can return without writing its `out/`
bundle on this host. It then creates `Resources/app.asar`, records the ASAR
header hash in `Info.plist`, flips the Electron fuses, and verifies the signed
bundle. In particular, `OnlyLoadAppFromAsar` is enabled, so a loose
`Resources/app` directory is not a valid substitute.

```bash
cd macos/electron/hello
npm install
node node_modules/electron/install.js   # fetches electron-v43.4.0-darwin-arm64.zip
./build.sh
```

The artifact is written to `out/Electron Hello.app` (ignored by Git). Remove
that ignored bundle explicitly before rebuilding; the recipe refuses to
overwrite an existing artifact. `KELD_ELECTRON_ZIP=/path/to/electron-v43.4.0-
darwin-arm64.zip` may be supplied to select a specific official download.

Do not commit `node_modules/`, `out/`, or the Electron zip.

Before packaging, verify the KEL-64 focus-first navigation seam:

```bash
node test-keld-bench-focus.js
```

## Weigh

1. `du -sh` on `Electron Hello.app`; `stat` the zip
2. Idle RSS: wait for `/tmp/keld-benches-electron-painted`, then `ps -o rss=`
   on the **main** Electron process. Note Chromium GPU / renderer helpers
   separately.
3. Record in [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).

For the shared KEL-64 oracle, the harness supplies `KELD_BENCH_URL`; the fixture
loads that loopback URL when present and keeps the bundled page for normal runs.
Its window is created hidden and is shown/focused from Electron's `dom-ready`
lifecycle event only after its URL is the canonical document; the fixture also
calls `webContents.focus()` so the renderer, not merely the native window,
owns focus before its first rendering opportunity.
