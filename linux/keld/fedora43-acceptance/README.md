# Fedora 43 bounded Keld acceptance receipt

This directory preserves the public, non-secret receipts from the KEL-28
non-Debian Linux spot-check performed on 2026-09-19.

It is **not** a scored benchmark result and does not use the result.v2 schema.
It is a bounded platform/control receipt for Keld commit
`0ea0780bb574ad242e9f1105fa4af5842872bad3`.

## What was exercised

A pinned Fedora 43 container userland built the Keld host from the exact Keld
source pin with the Fedora Rust/toolchain and GTK/WebKitGTK development
packages recorded in `receipts/fedora-build-packages.txt`.

The admitted runtime control was Fedora-owned X11:

- Fedora 43 userland
- Xvfb from Fedora packages
- Fluxbox from Fedora packages
- Fedora-built `keld-host`
- title/PID binding
- resize to 800x600
- minimize
- restore
- native window close
- host exit 0
- process reap

The accepted lifecycle receipt is
`receipts/fedora-fluxbox-smoke.log`.

The captured toolchain/runtime versions are:

- Rust/Cargo: Fedora 1.98.1
- GTK3: 3.24.52
- WebKitGTK 4.1: 2.52.5
- Fluxbox: 1.3.7-28.fc43
- Xvfb: 21.1.24-1.fc43

## Provenance

The original capture manifest is committed byte-for-byte as
`evidence-manifest.json`.

Important immutable inputs/artifacts recorded by that manifest:

- Keld SHA: `0ea0780bb574ad242e9f1105fa4af5842872bad3`
- Fedora image:
  `fedora@sha256:a651ddf48ea28a06ed4e1e6519f51c9f47e7a5a138722ade87369b8fbb7e5b42`
- source tar SHA-256:
  `4da59cfb59605f8b3e05e433d85a962843d89cc9f6b579e02545c8e8e963ed02`
- Fedora-built host SHA-256:
  `046c2ace7ea29bbc11637d6f31b2416a7327a981ebdd9690307d907ab1b818d8`
- Fedora-built host size: 1,693,384 bytes

The source tar and built binary are intentionally not committed here. Their
hashes bind the original private/local capture without adding generated binary
artifacts to Git.

`SHA256SUMS` binds every public receipt in this directory.

## Claim boundary

This evidence proves a bounded **non-Debian userland/build plus Fedora-owned
X11 lifecycle/control spot-check**. It does not establish:

- a bare-metal Fedora desktop qualification;
- a Fedora `keld dev` end-to-end product qualification;
- native Xorg qualification on the physical Ubuntu machine;
- Fedora Wayland qualification;
- packaged-app or installer startup;
- a performance score or framework comparison.

The Fedora environment ran under Docker Desktop. The accepted close/lifecycle
oracle used Fedora-owned Xvfb + Fluxbox. A separate physical-display forwarding
diagnostic reached the host's Mutter/Xwayland transport, but that path was
window-manager/focus-policy distorted and is not used as the acceptance oracle.

A credential-bearing physical-display transport receipt is intentionally not
published. It is hash-bound by the original manifest but is not required for
the accepted Fedora-owned lifecycle result.

This closes the public-receipt gap for the bounded non-Debian spot-check; it
does **not** close KEL-28's native-Xorg/bare-metal Linux qualification gap.
