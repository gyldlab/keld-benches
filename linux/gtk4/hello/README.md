# Linux native floor — GTK4 + WebKitGTK (contract; app not yet implemented)

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
