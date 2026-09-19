# Arch Linux bounded Keld build-portability receipt

This directory preserves the public receipts from the KEL-28 Arch Linux
build-portability check performed on 2026-09-19.

It is **not** a desktop-runtime acceptance test and it is not a scored
benchmark result. The exact Keld source pin is
`0ea0780bb574ad242e9f1105fa4af5842872bad3`.

## What was exercised

A pinned Arch Linux container userland built the Keld host with a locked
Release recipe using the package set captured in
`receipts/arch-packages.txt`.

The resulting host artifact was checked for dynamic-link resolution inside
that Arch userland. The capture reports zero unresolved dynamic links.

Captured versions:

- Rust/Cargo: Arch Linux 1.98.1
- GTK3: 3.24.52
- WebKitGTK 4.1: 2.52.6
- bubblewrap: 0.12.0-1
- libsoup3: 3.6.6-2

## Provenance

The original capture manifest is committed byte-for-byte as
`evidence-manifest.json`.

Important immutable inputs/artifacts:

- Keld SHA: `0ea0780bb574ad242e9f1105fa4af5842872bad3`
- Arch image:
  `archlinux@sha256:4894f5a268c696fad671966f383175a13faf433c9d9c88cdd4e32eaa2d18838b`
- source tar SHA-256:
  `4da59cfb59605f8b3e05e433d85a962843d89cc9f6b579e02545c8e8e963ed02`
- Arch-built host SHA-256:
  `32a36ed46cda8036de4400cd1d9573633dd512133aa7b5ca4c66cf80ee5ad19f`
- Arch-built host size: 1,681,360 bytes
- unresolved dynamic links: 0

The source tar and built host are intentionally not committed. Their hashes
bind the original capture without adding generated binaries to Git.

`SHA256SUMS` binds every public receipt in this directory.

## Claim boundary

This evidence establishes only **Arch Linux package mapping and locked build
portability** for the pinned Keld source and image.

It does not establish:

- an Arch desktop runtime acceptance;
- X11 or Wayland window/lifecycle behavior on Arch;
- end-to-end Arch `keld dev`;
- containment behavior on an Arch desktop;
- packaged-app or installer startup;
- release support;
- a performance score or framework comparison.

KEL-28 therefore remains open for the physical/native-Xorg and broader
non-Debian desktop qualification boundaries.
