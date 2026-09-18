# Tauri 2.11.5 hello — Linux WebKitGTK comparator

This fixture is the Linux Tauri arm for KEL-90. It is intentionally Rust-only:
no Node/Bun sidecar and no Tauri CLI is present in the measured artifact.

The locked graph pins Tauri 2.11.5 / Wry 0.55.1 and uses the system
WebKitGTK 4.1 runtime, matching Keld's Linux engine release. The benchmark
runner owns the HTML and paint oracle. At launch the fixture requires
`KELD_BENCH_URL` to be exactly:

`http://127.0.0.1:<port>/run/<32 lowercase hex>/index.html`

It creates one 960x640 Tauri webview window for that URL. Top-level navigation
away from the approved loopback origin is rejected.

## Build

```bash
linux/tauri/hello/build.sh /absolute/output-dir
```

The recipe builds only committed bytes with `cargo build --release --locked`
and emits:

- `tauri-linux-hello`
- `provenance.json` with fixture commit, source hashes, artifact hash/size,
  Rust/Cargo, Tauri, GTK3 and WebKitGTK versions.

Do not commit `src-tauri/target/`.

## Measurement boundary

The PAINT-OPPORTUNITY arm is a Tauri Rust-core/system-WebKitGTK hello. It does
not include a packaged JavaScript runtime. Keld's paired arm is the existing
`keld-host --hello` loopback-navigation diagnostic, so this is a matched
renderer/host paint comparator, not a full Keld-vs-Tauri product or backend
runtime verdict.

## Admission status

No physical-desktop performance result from this fixture is currently admitted.

The runner independently rebuilds this committed fixture and compares a canonical executable digest before timing. On the Ubuntu 26.04.1 GNOME measurement machine, clean trusted builds reached the runner-owned page under both forced Wayland and X11-through-Xwayland, but their double-rAF beacons were rejected as `document_not_focused`.

The focus/visibility oracle is intentionally not relaxed. A future timing campaign must first make this committed comparator pass that control reproducibly.
