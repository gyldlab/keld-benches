# Tauri 2 hello — Windows

Official `npm create tauri-app@latest -- --yes --manager npm --template vanilla`
scaffold, slimmed to one 960x640 window + local HTML. On Windows the engine is
the **system WebView2 Evergreen runtime** (`webviewInstallMode:
downloadBootstrapper`) — nothing is bundled.

**Release weigh is `npm run tauri build`**, not `--debug` / `tauri dev`.

Same engine class as Keld on this OS — both drive system WebView2, which is
what makes a `vs` cell legitimate here. **Not** the same class as Electron or
NW.js, which bundle their own Chromium.

> This file previously contained the macOS README verbatim: it told a Windows
> operator to `cd macos/tauri/hello`, required Xcode, and pointed at `.app` and
> DMG artifacts this platform never produces. The machine-read config was
> always Windows-correct (`"targets": ["msi", "nsis"]`); only the prose was
> wrong.

## Requires

- Rust (measured here: rustc 1.97.1, host `x86_64-pc-windows-msvc`)
- Node.js + npm (measured here: node v25.2.1, npm 11.19.0)
- MSVC Build Tools (measured here: VS 2022 17.14.37516.0, VC 14.44.35207,
  Windows SDK 10.0.26100.0)
- WebView2 Evergreen runtime (measured here: 151.0.4129.101)

## Build (Release)

```powershell
cd windows\tauri\hello
npm install
npm run tauri build
```

Measured cold on this machine: **5m38s** for `cargo build --release` into a
fresh target dir (crate cache warm), **1.5 GiB** of build tree, producing
`src-tauri\target\release\tauri-hello.exe` at **8,603,136 bytes**.

Artifacts (all gitignored):

- exe: `src-tauri\target\release\tauri-hello.exe`
- MSI: `src-tauri\target\release\bundle\msi\`
- NSIS: `src-tauri\target\release\bundle\nsis\`

Do not commit `node_modules\` or `src-tauri\target\`.

## Reproducibility caveat

`src-tauri/Cargo.lock` **is** committed (429 packages, pinning tauri 2.11.5,
wry 0.55.1, tao 0.35.3, webview2-com 0.38.2) and building on Windows did not
modify it, so the Rust layer is reproducible from this repo.

`package-lock.json` is **not** committed — the repo root `.gitignore` excludes
it — so the npm layer that selects `@tauri-apps/cli` and its platform binary is
not pinned here. That is an asymmetry against `windows/keld/hello`, which is
byte-identical to its generator output with line endings pinned. The CLI is not
on the measured path for `cargo build --release`, so it does not affect the
binary being weighed, but a paired document citing this fixture should disclose
it rather than imply the whole tree is pinned.

## Measuring

This arm is measured by
[`../../bench/Measure-WindowsGuiSession.ps1`](../../bench/Measure-WindowsGuiSession.ps1),
the round-major randomized interleaved runner, alongside the Keld arm in one
session. Window title is `Tauri Hello`; the process spawns `msedgewebview2.exe`
children and **no** JS-runtime child.

That last point matters when reading any comparison: this fixture's backend is
`tauri::Builder::default().run()` and runs **zero application JavaScript**,
while the Keld arm runs app code in a supervised Bun child over authenticated
kipc. Compare the native host lane to the native host lane; do not put
Keld-host-plus-runtime against a backend that runs no JS and call it a peer
result.

Numbers live in `windows/bench/results/`, never in this file.
