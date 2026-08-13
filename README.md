# keld-benches

Public, reproducible **hello-window / installer / RSS fixtures** for the
[Keld](https://github.com/gyldlab/keld) size and memory scoreboard.

**Product is Keld.** This repo is fixtures only — competitor and native-floor
hellos so measurements can be rebuilt on the same machine protocol (same HTML
class, official release flags, fair lanes). Do not treat anything here as the
Keld app framework.

Measured summaries are mirrored in Keld
[`docs/engineering/budget-scoreboard.md`](https://github.com/gyldlab/keld/blob/main/docs/engineering/budget-scoreboard.md)
(private monorepo paths may differ by branch). Record raw disk / RSS / DMG here
in [`MEASUREMENTS.md`](./MEASUREMENTS.md).

## Layout

| Path | Status | Fixture |
|---|---|---|
| [`swift/appkit-wk/`](./swift/appkit-wk/) | **sources** | AppKit `NSWindow` + `WKWebView` hello |
| [`swift/swiftui-wk/`](./swift/swiftui-wk/) | **sources** | SwiftUI + `WKWebView` hello |
| [`electron/hello/`](./electron/hello/) | stub README | Official Electron Forge / create-electron-app Release weigh |
| [`tauri/hello/`](./tauri/hello/) | stub README | Official `create-tauri-app` Release weigh |
| [`wails/hello/`](./wails/hello/) | stub README | Official Wails hello Release weigh |
| [`neutralino/hello/`](./neutralino/hello/) | stub README | Official Neutralino hello Release weigh |
| [`nwjs/hello/`](./nwjs/hello/) | stub README | Official NW.js hello Release weigh |
| [`electrobun/hello/`](./electrobun/hello/) | stub README | Official Electrobun hello Release weigh |

**Do not vendor** full Electron / Chromium / Node trees into this repo. Scaffold
with each framework’s official release tooling, place *app sources* under the
matching `*/hello/` tree, gitignore `node_modules`, `dist`, and toolchain caches,
then record artifacts in `MEASUREMENTS.md`.

## Build & run — Swift (macOS)

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

First paint writes `/tmp/keld-native-hello-appkit-painted` or
`/tmp/keld-native-hello-swiftui-painted` when `WKNavigationDelegate.didFinish`
fires.

## Fair comparison

- Same Mac, same day, **Release** packages only for `vs` cells.
- Split lanes: host / runtime / engine-in-bundle / wrapping — never blend.
- Do not mix WKWebView / Chromium / Skia in one `vs` cell.
- Stub frameworks: follow each directory’s README; do not invent numbers.

## License

MIT — see [`LICENSE`](./LICENSE).
