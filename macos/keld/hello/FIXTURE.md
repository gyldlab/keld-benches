# Keld hello — macOS

The exact `keld create hello` scaffold, pinned to one immutable Keld monorepo
commit. First `keld/` fixture in this repo; macOS is the only OS where Keld
hello provably runs today (window on screen + authenticated Bun↔Rust kipc
echo).

System-WebKit class (host-owned WKWebView): comparable with Swift / Tauri /
Wails / Neutralino rows, not with Chromium-class Electron numbers.

## Pinned versions

| What | Value |
|---|---|
| Keld monorepo | `a6427778552ebca179b6929a2b1a748ae6d3bb46` (immutable commit; was `origin/main` — the PR #45 merge — when this fixture was captured) |
| Rust toolchain | 1.97.1 — the Keld repo's `rust-toolchain.toml`; rustup selects it automatically inside that repo |
| Bun (baseline, verified) | 1.3.14 (`bun --revision` = `1.3.14+0d9b296af` for the verified run below) |
| Bun (candidate, unverified) | 1.4.0 — Keld PR #47 (KEL-88) pins CI Bun to 1.4.0 and was still open at capture time. Re-verify this fixture under 1.4.0 once that lands. |

## What these files are

The six files here are byte-identical to what `keld create hello` emits at the
pinned SHA (`{{name}}` rendered as `hello`):

- `keld.config.ts`, `package.json`, `index.html`, `src/main.ts`,
  `src/kipc.ts`, `.gitignore`
- `src/kipc.ts` is the hand-written, wire-exact kipc v2 client as shipped
  (KEL-30): kipc frame header, postcard payload codec, `KELD_APP_LINK`
  parsing, HELLO handshake, echo Call/Reply. No codegen.
- `src/kipc.test.ts` exists in the Keld template directory but is
  deliberately **not** emitted by `keld create` (the template is an explicit
  allow-list in `crates/keld-cli/src/template.rs`), so it is absent here too.

To re-derive them instead of trusting this copy:

```bash
git clone https://github.com/gyldlab/keld
git -C keld checkout a6427778552ebca179b6929a2b1a748ae6d3bb46
cd keld && cargo build -p keld-cli
target/debug/keld create hello   # writes ./hello with these six files
```

## Run (build + window + echo)

From this fixture directory, with the pinned Keld checkout built as above
(`KELD` = path to that checkout):

```bash
cd macos/keld/hello
"$KELD/target/debug/keld" dev
# equivalently: cargo run --manifest-path "$KELD/Cargo.toml" -p keld-cli -- dev
```

`keld dev` finds the project root via `keld.config.ts` in the current
directory, runs environment checks (`bun` on PATH is required), then:

1. starts a CLI-owned kipc echo server on a unix socket, spawns this
   fixture's `src/main.ts` as a supervised Bun child with `KELD_APP_LINK`
   set, and waits for the echo session to finish;
2. opens the hello window rendering this fixture's `index.html` inline,
   titled from `keld.config.ts` `name`. The window blocks until closed.

## Verified on this fixture (macOS arm64, 2026-08-21)

Actual output of the run above at the pinned SHA, Bun 1.3.14+0d9b296af,
rustc 1.97.1:

```text
ipc-echo ok: message="keld" count=1
hello: main process ready (IPC echo ok)
```

then a window titled `hello` appeared rendering this `index.html`
(`<h1>hello</h1>`, "Rendered by the Keld host webview…"), confirmed both
visually and via System Events (process `keld`, window name `hello`).

## What this fixture proves

- **Darwin window on screen**: the host-owned WKWebView renders this
  fixture's `index.html` (inline HTML load, title from config).
- **Authenticated Bun↔Rust kipc echo**: the Bun child parses
  `KELD_APP_LINK` (`<endpoint>#<64-hex token>`), completes the kipc v2 HELLO
  handshake with the 32-byte session token, and round-trips one
  postcard-encoded echo Call/Reply on the echo channel.
- **CLI sequential path only**: echo session first (Bun child exits), window
  after. That order is the current `keld dev` contract, not a limitation of
  this fixture.

## What this fixture does NOT prove

- **No first-paint claim** — nothing here timestamps paint.
- **No RSS / memory claim** — no idle-RSS oracle has been run against it.
- **Not the host-owned concurrent app link** — KEL-30 is open; the echo
  server in this path is owned by `keld-cli`, and the Bun child has already
  exited before the window exists. `keld-host --hello` is a separate
  host-owned window slice that renders the host's built-in HTML, not this
  fixture's renderer, and spawns no Bun child.
- **No size claim** — `keld dev` runs debug binaries out of the Keld
  workspace; nothing here weighs a shipped artifact.
- **Nothing off macOS.**

## Release host binary (for future honest size numbers)

```bash
cargo build --release -p keld-host   # inside the pinned Keld checkout
```

Observed at the pinned SHA on one machine (aarch64-apple-darwin,
rustc 1.97.1): `target/release/keld-host` = 1,017,200 bytes, SHA-256
`2b4e42cf98f3e23b57057f4a7e5e53db6fba2dd97fdb7310aad09431355279c6`. Rust
builds are not bit-reproducible across machines/toolchains, so treat this as
an observed value, not a spec. Do not commit binaries.

## Measurements

None recorded here on purpose. Rows in
[`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md) come from harness
runs, which are a separate step from landing the fixture.
