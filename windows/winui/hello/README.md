# Windows native floor — Win32/WinUI + WebView2 (contract; app not yet implemented)

The Windows equivalent of `macos/swift/{appkit-wk,swiftui-wk}`: what does
Windows charge for **one window + the system webview with no framework**?
Without this row, Keld/Tauri/Wails Windows numbers have competitors but no
floor. See `HARNESS-CONTRACT.md` §6.

## Fixture contract

- One top-level window created with raw Win32 (`CreateWindowExW`) or WinUI 3 —
  pick ONE and name it in this README when implementing; do not ship both in
  one fixture folder (the macOS floor splits AppKit and SwiftUI into two
  fixtures for the same reason).
- One WebView2 control (`CreateCoreWebView2Controller`) loading the canonical
  hello payload — same HTML class as every other arm, no extra flags. Note
  that wry passes `--disable-features=msSmartScreenProtection` by default and
  a bare fixture does not; the KEL-66 isolation run measured that difference
  as noise, but record the browser args regardless.
- Emits the standard double-rAF image beacon; no privileged instrumentation.
- Release build from a committed script (MSVC or `cargo build --release` if
  the shell is Rust + `webview2-com`; the shell language is not the point —
  the absence of a framework layer is).
- Lane: `webview2`. Comparable with Keld / Tauri / Wails / Neutralino Windows
  arms; never with Electron/NW.js bundled-Chromium rows.
- Record in the result document's arm: `arm_id: "winui"` (or `"win32"`),
  toolchain versions, WebView2 Evergreen runtime version.

There is deliberately no Swift here and no WinUI under `macos/` or `linux/`:
native floors do not exist cross-OS.
