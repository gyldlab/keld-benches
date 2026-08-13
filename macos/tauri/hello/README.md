# Tauri 2 hello — macOS

Official `npm create tauri-app@latest -- --yes --manager npm --template vanilla`
scaffold, slimmed to one 960×640 window + local HTML (system WKWebView).
**Release weigh is `npm run tauri build`**, not `--debug` / `tauri dev`.

Same engine class as Keld / Swift (system webview) — fair for WK `vs` cells
when measured same-day Release.

## Requires

- Rust (this machine: rustc 1.93.0, host `aarch64-apple-darwin`)
- Node.js + npm
- Xcode / CLT (this machine: Xcode 26.5)

## Build (Release)

```bash
cd macos/tauri/hello
npm install
npm run tauri build
```

Ad-hoc codesign is set (`signingIdentity: "-"`). Artifacts (gitignored):

- `.app`: `src-tauri/target/release/bundle/macos/Tauri Hello.app`
- DMG: `src-tauri/target/release/bundle/dmg/`

Do not commit `node_modules/` or `src-tauri/target/`.

## Weigh

1. `du -sh "src-tauri/target/release/bundle/macos/Tauri Hello.app"`
2. Executable `stat` under `Contents/MacOS`
3. Idle RSS: `open` the `.app`, then `ps -o rss=` on the main process. WebKit
   helper XPCs are extra — note them separately.
4. Record in [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
