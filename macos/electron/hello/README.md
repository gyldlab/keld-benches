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

For an offline rebuild, `KELD_ELECTRON_RUNTIME_APP=/absolute/path/to/Electron.app`
may replace the ZIP source. The recipe accepts that fallback only when the app
is a real, strictly code-signature-verified **Electron 43.4.0** bundle; it then
replaces its `app.asar`, recalculates the integrity header, re-applies the
fuses, and signs the output. Set exactly one of the ZIP and runtime-app inputs.

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
Its window is created hidden, then its empty native `about:blank` view is
shown/focused immediately before canonical navigation. The fixture reasserts
that focus at the exact canonical main-frame navigation and Electron's
`dom-ready` lifecycle event. It calls Electron's app-level `focus({ steal:
true })`, then native and `webContents.focus()` so the renderer, not merely the
native window, owns focus before the canonical page reaches its first rendering
opportunity.

For a KEL-64 launch, pass both Chromium switches through LaunchServices—before
Chromium bootstraps—not through JavaScript after Electron has begun starting:

```bash
--app-arg 'Electron=--password-store=basic' \
--app-arg 'Electron=--use-mock-keychain'
```

The benchmark page has no credential flow. These switches avoid a per-user
macOS Keychain lookup that can foreground `SecurityAgent` and invalidate the
focused-renderer contract.
