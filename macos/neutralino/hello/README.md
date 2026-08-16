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

## macOS focus patch proof (KEL-64)

Stock Neutralino **v6.9.0** reaches the KEL-64 canonical page on this macOS
host but its document reports `hasFocus=false`, even when the harness observes
the native application becoming foreground. This is not a loopback-server or
fixture-navigation issue: the canonical HTML returns 200 and its focus-aware
beacon is rejected with HTTP 422.

[`patches/v6.9.0-macos-window-focus-webview.patch`](./patches/v6.9.0-macos-window-focus-webview.patch)
contains the smallest validated runtime change. After Neutralino's existing
macOS focus handling (which either restores or keys and brings the window
front), its documented `window.focus()` API also makes the runtime's `WKWebView`
the `NSWindow` first responder. It does not synthesize input or change the
benchmark oracle.

Build an arm64 patched runtime from a clean checkout at exact v6.9.0 commit
`2cec764ac5e3ccc5b1b44d046d6e6d6c85c3099e`:

```bash
./build-macos-focus-runtime.sh /absolute/path/to/neutralinojs \
  "$PWD/bin/neutralino-mac_arm64"
npx --yes @neutralinojs/neu build --release --macos-bundle --embed-resources
```

The builder refuses a dirty or non-v6.9.0 source checkout and refuses to
overwrite a runtime. Its temporary source copy is retained so that the exact
build is inspectable. This is a **patched-runtime proof**, not a stock
Neutralino v6.9.0 score or an upstream release claim.

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
then navigates to that loopback URL. The canonical document's double-rAF beacon
independently verifies focus; a failed focus proof is a failed measurement rather
than a substitute metric. When the variable is absent, normal bundled-page
startup is unchanged.
