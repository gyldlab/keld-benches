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

`electron-forge make` is the documented path. On this Mac, Forge’s
`extract-zip` step returned without writing `out/` (see session notes);
the **same official zip** is assembled with `ditto` (identical Chromium
payload Forge would embed):

```bash
cd macos/electron/hello
npm install
node node_modules/electron/install.js   # fetches electron-v43.4.0-darwin-arm64.zip

ZIP=$(ls "$HOME/Library/Caches/electron/"*/electron-v43.4.0-darwin-arm64.zip | head -1)
DEST=/tmp/keld-electron-hello
rm -rf "$DEST"
mkdir -p "$DEST"
ditto -x -k "$ZIP" "$DEST/runtime"
APP="$DEST/Electron Hello.app"
ditto "$DEST/runtime/Electron.app" "$APP"
mkdir -p "$APP/Contents/Resources/app/src"
cp package.json "$APP/Contents/Resources/app/"
cp src/index.js src/index.html src/preload.js "$APP/Contents/Resources/app/src/"
# package.json "main" is src/index.js — keep that layout
/usr/libexec/PlistBuddy -c "Set :CFBundleName Electron Hello" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Electron Hello" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.keld.benches.electron" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
open "$APP"
```

Alternatively, if Forge works on your machine: `npm run make` and weigh
`out/Electron Hello-darwin-arm64/Electron Hello.app`.

Do not commit `node_modules/`, `out/`, or the Electron zip.

## Weigh

1. `du -sh` on `Electron Hello.app`; `stat` the zip
2. Idle RSS: wait for `/tmp/keld-benches-electron-painted`, then `ps -o rss=`
   on the **main** Electron process. Note Chromium GPU / renderer helpers
   separately.
3. Record in [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).

For the shared KEL-64 oracle, the harness supplies `KELD_BENCH_URL`; the fixture
loads that loopback URL when present and keeps the bundled page for normal runs.
