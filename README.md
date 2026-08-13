# keld-benches

Public, reproducible **hello-window fixtures** for the [Keld](https://github.com/gyldlab/keld) size/RSS scoreboard.

These are **not** the Keld product. They exist so competitor and native-floor measurements can be rebuilt on the same machine protocol (same HTML, release flags, WKWebView class).

## What’s here

| Path | Fixture |
|---|---|
| `swift/appkit-wk/` | AppKit `NSWindow` + `WKWebView`, `loadHTMLString` Hello |
| `swift/swiftui-wk/` | SwiftUI `WindowGroup` + `NSViewRepresentable` `WKWebView` |

Electron / Tauri / Wails hellos will land here later when measured the same way. No empty placeholder trees.

See [`MEASUREMENTS.md`](./MEASUREMENTS.md) for numbers captured on Apple M4 (2026-08-13).

## Build & run (macOS)

Needs Xcode / Command Line Tools (`swiftc`).

```bash
# AppKit + WKWebView
mkdir -p dist/HelloAppKit.app/Contents/MacOS
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o dist/HelloAppKit.app/Contents/MacOS/HelloAppKit \
  swift/appkit-wk/HelloAppKit.swift
cp swift/appkit-wk/Info.plist dist/HelloAppKit.app/Contents/
codesign --force --sign - dist/HelloAppKit.app
open dist/HelloAppKit.app

# SwiftUI + WKWebView
mkdir -p dist/HelloSwiftUI.app/Contents/MacOS
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o dist/HelloSwiftUI.app/Contents/MacOS/HelloSwiftUI \
  swift/swiftui-wk/HelloSwiftUI.swift
cp swift/swiftui-wk/Info.plist dist/HelloSwiftUI.app/Contents/
codesign --force --sign - dist/HelloSwiftUI.app
open dist/HelloSwiftUI.app
```

Optional UDZO DMG (as in the scoreboard session):

```bash
hdiutil create -volname HelloAppKit -srcfolder dist/HelloAppKit.app \
  -ov -format UDZO dist/HelloAppKit.dmg
hdiutil create -volname HelloSwiftUI -srcfolder dist/HelloSwiftUI.app \
  -ov -format UDZO dist/HelloSwiftUI.dmg
```

First paint writes `/tmp/keld-native-hello-appkit-painted` or `/tmp/keld-native-hello-swiftui-painted` when `WKNavigationDelegate.didFinish` fires.

## Fair comparison

Use these fixtures for the **native WKWebView floor** next to Keld’s host-lane hello. Do not mix Chromium bundles into the same cell as system WebKit. Scoreboard concept lives in the Keld monorepo (`docs/engineering/budget-scoreboard.md`).

## License

MIT — see [`LICENSE`](./LICENSE).
