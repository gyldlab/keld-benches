# Tauri 2 hello — macOS

Without `KELD_BENCH_URL`, the fixture loads its bundled HTML normally. The
external macOS oracle sets a validated IPv4-loopback URL in the generated
context before Tauri creates its configured single webview.

Official vanilla Tauri scaffold, slimmed to one 960×640 window + local HTML
(system WKWebView). **Release weight uses `bun run tauri build`**, not `--debug` /
`tauri dev`.

Same engine class as Keld / Swift (system webview) — fair for WK `vs` cells
when measured same-day Release.

## Requires

- Rust (this machine: rustc 1.93.0, host `aarch64-apple-darwin`)
- Bun
- Xcode / CLT (this machine: Xcode 26.5)

## Build (Release)

```bash
./macos/tauri/hello/build.sh
```

The canonical recipe refuses a dirty or non-canonical checkout, non-default
Git index flags, a commit that is not an exact live branch head at
`gyldlab/keld-benches`, and an existing output app. It runs the frozen Bun
install and Release Tauri app build from a fresh archive of the committed
fixture bytes in one validated source/dependency/target staging root physically
outside the repository, with fresh `HOME`, `BUN_INSTALL`, `CARGO_HOME`, and
`CARGO_TARGET_DIR` directories and ambient build flags removed. A caller
`TMPDIR` inside the checkout is ignored in favor of validated external `/tmp`.
The recipe also refuses a `node_modules` directory, Cargo configuration, or
ancestor `package.json` anywhere above the isolated fixture, because Bun and
Cargo search their ancestor directories. Ignored checkout state cannot select
tools or alter the build.
The checkout's `src-tauri/target` tree is not created until that external
staging root has been created and its filesystem has been validated; a clean
checkout is therefore safe to use without pre-seeding an output target. The
final target directory is rechecked against the staging device before the
build proceeds.
The recipe invokes the freshly installed local Tauri CLI by its exact path and
embeds the source/recipe commit, build-script hash, and actual Bun, Tauri CLI,
Rust, Cargo, Xcode, and macOS SDK versions in the app's `Info.plist`, then
re-signs and verifies the bundle. Staging must share a filesystem with the final
app, which is installed with an exclusive atomic rename; a path created during
the build cannot be overwritten. Cleanup is bound to the original staging
pathname and device/inode. If that path is replaced, cleanup refuses it rather
than resolving a symlink or deleting an unrelated directory.

Remove an old ignored app explicitly before rebuilding. Ad-hoc codesign is set
(`signingIdentity: "-"`). Artifact (gitignored):

- `.app`: `src-tauri/target/release/bundle/macos/Tauri Hello.app`

Do not commit `node_modules/` or `src-tauri/target/`.

The non-GUI isolation self-test does not install dependencies or build an app:

```bash
./macos/tauri/hello/test-build-isolation.sh
```

## Weigh

1. `du -sh "src-tauri/target/release/bundle/macos/Tauri Hello.app"`
2. Executable `stat` under `Contents/MacOS`
3. Use [`../../harness/`](../../harness/) for exact resource-coalition RSS.
   Main-process `ps` output is diagnostic only because WebKit XPC helpers are
   reparented and must be included in the budget.
4. Record in [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md).
