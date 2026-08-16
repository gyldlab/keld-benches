# NW.js hello — macOS

Official NW.js **normal** flavor (not SDK) **v0.114.1** `osx-arm64` plus a
one-window local HTML app. The Chromium/NW runtime zip is **not** committed.
App sources (`package.json` + `index.html`) live here.

Chromium-class: same fairness rules as Electron.

## Requires

- https://dl.nwjs.io/v0.114.1/nwjs-v0.114.1-osx-arm64.zip (161–162 MB download)

## Package (do not commit the runtime)

```bash
cd macos/nwjs/hello
curl -fsSL -o /tmp/nwjs-v0.114.1-osx-arm64.zip \
  https://dl.nwjs.io/v0.114.1/nwjs-v0.114.1-osx-arm64.zip
ditto -x -k /tmp/nwjs-v0.114.1-osx-arm64.zip /tmp/nwjs-hello-runtime
APP="/tmp/NWJS Hello.app"
ditto /tmp/nwjs-hello-runtime/nwjs-v0.114.1-osx-arm64/nwjs.app "$APP"
mkdir -p "$APP/Contents/Resources/app.nw"
cp package.json index.html "$APP/Contents/Resources/app.nw/"
open "$APP"
```

## Weigh

See [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md) (2026-08-14).
Paint marker: `/tmp/keld-benches-nwjs-painted`.
Weigh the assembled `.app` (runtime + `app.nw`), not the SDK zip.

For the shared KEL-64 oracle, the harness supplies `KELD_BENCH_URL`; the page
navigates to that loopback URL when present and keeps the bundled page otherwise.

NW.js 0.13 and later enforce single-instance routing despite the deprecated
`single-instance` manifest property. Each KEL-64 sample therefore needs an
isolated profile, otherwise a later launch forwards to the prior instance rather
than creating the measured app process:

```bash
macos/harness/.build/keld-macos-bench \
  --app 'NW.js=/absolute/NWJS Hello.app' \
  --app-arg 'NW.js=--user-data-dir=/tmp/keld-nwjs-profile-{token}' \
  --app-build-command 'NW.js=<exact assembly command>' \
  --output /tmp/nwjs-kel64.json
```

The profile directory is benchmark-scoped disposable state; remove only the
explicit `/tmp/keld-nwjs-profile-*` directories after the run has fully cleaned
up its NW.js process tree.
