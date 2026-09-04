# Linux native floor — GTK4 + WebKitGTK

The Linux equivalent of `macos/swift/{appkit-wk,swiftui-wk}`: what does Linux
charge for **one window + the system webview with no framework**? See
`HARNESS-CONTRACT.md` §6.

## Fixture contract

- One `GtkApplicationWindow` (GTK4, C or Rust via gtk4-rs — pick one and name
  it here when implementing) containing one `WebKitWebView` (webkitgtk 6.0
  API) loading the canonical hello payload — same HTML class as every other
  arm.
- Emits the standard double-rAF image beacon; no privileged instrumentation.
- Release build from a committed script; record the WebKitGTK, GTK, and
  compiler versions plus the distro/session facts (X11 vs Wayland, compositor)
  in the result document — paint timing is not comparable across display
  servers.
- Lane: `webkitgtk`. Comparable with Tauri / Wails / Neutralino Linux arms;
  never with Electron/NW.js bundled-Chromium rows.
- Package lanes (AppImage / deb) are separate DISK documents; never blend
  raw binary and packaged sizes.

There is deliberately no GTK fixture under `macos/` or `windows/`: native
floors do not exist cross-OS.

## Implementation

The fixture is a C11 `GtkApplication` with one `GtkApplicationWindow` and one
WebKitGTK 6.0 `WebKitWebView`. It accepts only a loopback runner URL shaped as
`http://127.0.0.1:<port>/run/<32-lowercase-hex>/index.html`, waits for the
window's one-shot mapped notification without polling or a fixed delay,
focuses the webview, and then loads the runner-owned canonical payload. Its
WebKit policy handler rejects every new-window request and every navigation or
redirect whose URI is not the exact approved URL. Missing or non-loopback
input exits 64 before GTK creates a resource.

This uses the GTK 4 and WebKitGTK 6.0 C APIs directly. GTK documents the
`GtkApplication`/`GtkApplicationWindow` lifecycle and `pkg-config gtk4` build
contract at <https://docs.gtk.org/gtk4/getting_started.html>. WebKitGTK's
migration guide identifies `webkitgtk-6.0` as the GTK4/libsoup3 API and states
that its web-process sandbox is mandatory:
<https://webkitgtk.org/reference/webkit2gtk/stable/migrating-to-webkitgtk-6.0.html>.

Build from a clean committed fixture revision:

```sh
linux/gtk4/hello/build.sh "$PWD/linux/gtk4/hello/dist"
```

The script refuses dirty recipe inputs and existing output, compiles with
strict warnings, and emits the executable plus `provenance.json` containing
the fixture commit, source/recipe/artifact hashes, size, compiler, GTK, and
WebKitGTK versions. Build outputs are not committed.

Run static and fail-closed input tests:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 linux/gtk4/hello/test_fixture.py
```

After building, include binary-input and real desktop proof:

```sh
GTK4_FIXTURE_ARTIFACT="$PWD/linux/gtk4/hello/dist/gtk4-webkit-hello" \
  GTK4_FIXTURE_REAL=1 \
  PYTHONDONTWRITEBYTECODE=1 \
  python3 linux/gtk4/hello/test_fixture.py
```

This fixture PR does not add a benchmark result or performance claim. Linux
runner integration and a paired Keld/native session are separate KEL-90 work.
