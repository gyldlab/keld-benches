# Keld shipping dev hello — Linux product-flow fixture

This fixture is the exact seven-file output of `keld create product-bench` at
Keld `0ea0780bb574ad242e9f1105fa4af5842872bad3`. It exists beside the
historical `linux/keld/hello` fixture because the two measure different
things:

- `linux/keld/hello` launches `keld-host --hello` through a benchmark-only
  navigation adapter.
- this fixture launches the shipping Release `keld dev` flow: doctor checks,
  owner-private boot staging, the no-flag host, Linux strict-profile Bun,
  authenticated KIPC echo, the real WebKitGTK window, and normal native-close
  lifecycle.

The benchmark runner never patches Keld source. For each measured launch it
copies this committed project into a fresh owner-private temporary root and
injects the separately committed `paint-beacon.js` into only that temporary
copy's stock `index.html`. The committed seven-file project remains byte
identical to `keld create`, while measurement instrumentation has its own
reviewable digest.

## Build

```bash
linux/keld/dev-hello/build.sh \
  /path/to/keld \
  0ea0780bb574ad242e9f1105fa4af5842872bad3 \
  /absolute/output/directory
```

The recipe fetches the exact Keld commit from the canonical origin, builds with
`cargo build --release --locked -p keld-cli -p keld-host`, verifies that the
built CLI reproduces all seven committed project files exactly, and emits the
shipping sibling executable set:

- `keld`
- `keld-host`
- `keld-role-launcher`
- `provenance.json`

Linux `keld dev` requires all three executables. Omitting the role launcher
must fail boot staging rather than falling back to an uncontained child.

## Measurement boundary

This is a **developer-flow product path**, not a packaged installer/application
startup claim. Spawn-to-paint therefore includes CLI doctor/staging work, Bun
strict-profile admission and the stock authenticated echo before the native
window paints.

Two backend-qualified measurement lanes are supported:

- X11 requires `GDK_BACKEND=x11`, a usable `DISPLAY`, no `WAYLAND_DISPLAY`,
  `xdotool`, and `wmctrl`. Window discovery is bound to the captured
  `keld-host` PID before the exact native window is closed.
- Wayland requires `GDK_BACKEND=wayland`, a usable `WAYLAND_DISPLAY`, no
  `DISPLAY`, the desktop session D-Bus, and a live AT-SPI bus. The runner
  resolves the accessibility application by the captured `keld-host` PID,
  requires exactly one frame with the fixture title and exactly one accessible
  `Close` button, then invokes that button's `click` action.

Both lanes accept a sample only if the shipping lifecycle exits cleanly, the
per-launch stage is removed, and the captured CLI/host/Bun/WebKit descendants
are gone. X11 through Xwayland does not prove a native Xorg login.

For memory, the scored `MEM-IDLE` value stays the **Keld host RSS**, preserving
the existing metric denominator. CLI RSS, Bun RSS, WebKit helper RSS, Keld-owned
CLI+host RSS, and total owned-tree RSS are separate diagnostics.
