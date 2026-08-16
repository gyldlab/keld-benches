# Neutralino hello — macOS

Official [`neutralinojs-minimal`](https://github.com/neutralinojs/neutralinojs-minimal)
template. `neu create` failed here (`Unable to download resources from internet` /
zip extract), so the same GitHub template was cloned, then slimmed to one 960×640
window + local HTML. **Release weigh:** `neu build --release --macos-bundle --embed-resources`.

System webview (WKWebView). Binaries are fetched by `neu update` and gitignored
(`bin/`). Client `resources/js/neutralino.js` is also gitignored.

**Note:** `--macos-bundle` only *renames* the arm64 Mach-O with a `.app`
suffix — it is not a real bundle. For `open` / RSS this session wrapped that
signed binary in a real `Neutralino Hello.app` (Info.plist + `Contents/MacOS`).

## Requires

- Node.js + `npx @neutralinojs/neu` (CLI **v11.7.2** this session)
- Framework **v6.9.0** (`neu update --latest`)

## Build (Release)

```bash
cd macos/neutralino/hello
npx --yes @neutralinojs/neu update --latest
npx --yes @neutralinojs/neu build --release --macos-bundle --embed-resources
```

Before packaging, verify the KEL-64 launch seam remains focus-first:

```bash
./test-keld-bench-focus.sh
```

Official output (gitignored `dist/`):

- `dist/neutralino-hello/neutralino-hello-mac_arm64.app` — Mach-O (embedded resources)
- `dist/neutralino-hello-release.zip` — **all platforms**; not a macOS-only installer

Real bundle used for RSS (not committed):

```bash
BIN=dist/neutralino-hello/neutralino-hello-mac_arm64.app
APP=/tmp/Neutralino\ Hello.app
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Neutralino Hello"
# add Info.plist (CFBundleExecutable = Neutralino Hello), then:
codesign --force --sign - "$APP"
open "$APP"
```

## Weigh

See [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md) (2026-08-14).
Paint marker: `/tmp/keld-benches-neutralino-painted`.

For the shared KEL-64 oracle, the harness supplies `KELD_BENCH_URL`; the fixture
reads it through `os.getEnv`, awaits the documented native `window.focus` call,
then awaits Neutralino's documented `windowFocus` event before navigating to
that loopback URL. This makes the canonical document's double-rAF beacon attest
an actually focused window rather than merely a foreground app process. When
the variable is absent, normal bundled-page startup is unchanged.
