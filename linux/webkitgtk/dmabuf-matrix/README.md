# WebKitGTK NVIDIA DMA-BUF correctness matrix

This OS-qualified fixture answers KEL-171's narrow question: on one real Linux
NVIDIA host, does WebKitGTK render and composite opaque and transparent content
with the DMA-BUF renderer mitigation disabled and enabled? It is a correctness
probe, not a performance metric and not evidence for untested driver, GPU,
module-flavor, compositor, backend, or WebKitGTK cells.

The C probe records the initialized GDK backend and runtime/header versions,
waits for a nonce-bearing double-animation-frame title beacon, and obtains a
WebKit snapshot with transparent alpha preserved. Two solid pixels are the
renderer oracle: a magenta content marker and either an opaque `#203040`
background or zero-alpha background. While the nonce-bearing page remains
live, the runner captures a real Mutter compositor frame through its ScreenCast
PipeWire service. A transparent window is centered over a separate green
backdrop, so the external crop must expose green while its internal WebKit
snapshot remains zero-alpha. The final negative control makes only the WebView
backing color opaque black: navigation and the internal snapshot still pass,
but the compositor oracle must reject the visible black degradation.

Builds are accepted only from committed, clean recipe bytes in the canonical
`gyldlab/keld-benches` repository:

```sh
sh linux/webkitgtk/dmabuf-matrix/build.sh /absolute/artifact-directory
```

Run the real X11 + Wayland matrix from an active desktop session. The run also
binds current Keld's opaque tao/wry construction. Build the existing Keld hello
adapter from the exact product commit first, then pass it to the matrix. The
output directory must not exist:

```sh
sh linux/keld/hello/build.sh /path/to/keld KELD_FULL_SHA /absolute/keld-artifact
python3 linux/webkitgtk/dmabuf-matrix/run_matrix.py \
  --artifact /absolute/artifact-directory/kel171-webkitgtk-probe \
  --provenance /absolute/artifact-directory/provenance.json \
  --keld-artifact-dir /absolute/keld-artifact \
  --expected-keld-sha KELD_FULL_SHA \
  --out /absolute/new-evidence-directory \
  --samples 5 --seed 171
```

The Keld arm uses the existing nonce-bound double-rAF fixture and a read-only
`LD_PRELOAD` audit library to record the actual Keld WebKitGTK backend and flag
state. Flag-off rows remove `WAYLAND_DISPLAY` while forcing the requested GDK
backend to bypass Keld's environment-based predicate; the row is accepted only
when the audit reports a real `GdkWaylandDisplay`, without assuming a socket
name. Keld's current public `WebviewSpec` has no transparent-window option, so
the manifest records those product cells as unavailable rather than inventing
an implementation. The native control owns the opaque/transparent renderer and
compositor comparison.

The real compositor oracle requires an active GNOME/Mutter session,
`org.gnome.Mutter.ScreenCast`, PipeWire, GStreamer `pipewiresrc`, and Python GI
bindings for Gio and GdkPixbuf. Direct `org.gnome.Shell.Screenshot` access is
not used.

The output contains every PNG, audit receipt, private verified executable,
`manifest.json`, and `SHA256SUMS`. The manifest
contains raw stdout/stderr, exit/signal state, runtime receipts, host/driver
census commands, artifact provenance, cell order, bounded rejected acquisition
attempts, and the negative control. Full-desktop ScreenCast frames are never
retained; only the 320×240 marked-window crop enters the artifact.
Copy a completed bundle into the private research repository as a new immutable
artifact; never overwrite an existing run.
