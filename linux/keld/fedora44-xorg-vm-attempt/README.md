# Fedora 44 native-Xorg VM acceptance attempt

This directory preserves the sanitized public receipt from a KEL-28 Fedora 44
native-Xorg acceptance attempt performed on 2026-09-19.

This is **failed acceptance evidence**, not a scored benchmark result and not a
claim that Fedora 44 is currently qualified.

## Environment exercised

The guest was:

- Fedora Linux 44 Cloud Edition;
- Linux 6.19.10-300.fc44.x86_64;
- KVM/Q35 with a Virtio virtual GPU;
- native guest Xorg on display `:0`;
- Fluxbox as the guest X11 window manager;
- GTK3 3.24.52;
- WebKitGTK 4.1 / 2.52.5;
- bubblewrap 0.12.0;
- Bun 1.4.2, revision `744846f84`;
- Rust/Cargo 1.97.1;
- Keld `0ea0780bb574ad242e9f1105fa4af5842872bad3`.

The guest built `keld`, `keld-host`, and `keld-role-launcher` from that
exact Keld source pin. Their SHA-256 and byte counts are committed under
`receipts/keld-artifacts.txt`.

`receipts/xorg-runtime.txt` records that the guest had a real Xorg server and
Fluxbox process, rather than Xwayland or Xvfb.

## Acceptance intent

The attempt used the shipping `keld create` + `keld dev` product path. The
generated project was captured in pristine form, then modified only for the
acceptance probe:

- force the user-required black launch presentation; and
- add a second same-session authenticated IPC echo as an additional lifecycle
  assertion.

Both pristine and modified project digests are committed.

The intended acceptance required:

- both authenticated IPC echoes;
- the main-process-ready marker;
- one visible X11 window bound to the exact `keld-host` PID;
- expected Bun/WebKit/Keld process classes;
- native window close;
- exit 0; and
- zero generation-bound survivors.

## Result

The attempt **failed before window creation**.

The host process started, but the strict Linux runtime rejected the launch with:

`KELD-RUNTIME-016: Linux strict-profile admission failed during runtime mount source: No such file or directory`

The CLI then reported `KELD-CLI-048` because the staged no-flag host exited
with status 1.

Consequently:

- first IPC echo: not reached;
- second IPC echo: not reached;
- ready marker: not reached;
- visible X11 window: not reached;
- native close/lifecycle acceptance: not reached.

The sanitized machine-readable failure record is `receipt.json`.

## Why the VM itself is not committed

The local Fedora base image and mutable overlay were several gigabytes and the
working directory also contained ephemeral SSH credentials. Those are execution
assets, not repository evidence.

The large local VM assets are therefore **not** committed. Their SHA-256 values
are retained in `receipts/local-vm-assets.sha256` only to bind the original
capture. No private key material, credential-bearing transport files, VM image,
or overlay is published.

## Claim boundary

This receipt proves that the Fedora 44 KVM guest had a native Xorg environment
and that the pinned Keld product path reached strict-runtime admission before
failing on a missing runtime-mount source.

It does **not** establish:

- successful Fedora 44 `keld dev`;
- a visible Keld window on Fedora 44;
- successful IPC in this guest;
- lifecycle shutdown;
- bare-metal Fedora qualification;
- native Xorg qualification on the physical Ubuntu host;
- performance numbers; or
- general Fedora release support.

KEL-28 therefore remains open. The failure should be treated as a portability /
strict-runtime blocker, not hidden by falling back to an uncontained launch.
