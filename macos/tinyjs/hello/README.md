# TinyJSApp hello — macOS

Status: **fixture and pinned packaging recipe; unmeasured comparator**.
This is a complete ordinary TinyJSApp `.app`, with its native launcher and
normal txiki.js backend. It is not a launcher-only arm or an Electron-compatible
runtime. No new metric, measurement harness, result document or scoreboard cell
is introduced here.

## Reproduce the artifact

Requires native macOS arm64 or x86_64, Python 3.9+, and Apple Command Line Tools
(`codesign`, `lipo`, `xcode-select`). Run from the repository root:

```sh
python3 macos/tinyjs/hello/test_fixture.py
python3 macos/tinyjs/hello/build.py /tmp/keld-tinyjs-build
```

The output directory must not exist and must be outside the source tree.
The recipe downloads the exact release archive in `upstream.json`, checks both
its size and SHA-256 before extraction/execution, then invokes the upstream
release CLI with `build --arch <native architecture>`. An already downloaded
archive is accepted only with the same pin:

```sh
python3 macos/tinyjs/hello/build.py /tmp/keld-tinyjs-offline \
  --sdk-archive /tmp/tinyjs-macos-arm64.tar.gz
```

No global TinyJS installation, shell installer, SDK source patch, user cache,
frontend bundler or extra package dependency is needed. The recipe uses an
isolated build home and strips inherited TinyJS/signing/engine settings.
The native-architecture check rejects a silently retained universal launcher.

The deliverable is `project/dist/TinyJS Hello.app` inside the output directory.
**Do not weigh the whole output directory**: it also holds the downloaded SDK,
its unpacked files, build intermediates, and the CLI's separate bare executable.
The release SDK archive itself is also not the app's download package.

`build-provenance.json` records the upstream release/source revision, archive
pins, source hashes, benchmark revision/dirty status, canonical payload hash,
and hashes of every file in the resulting `.app`. It is build metadata, not a
metric-result schema or a publication certificate. Upstream prebuilt binaries
are pinned; this is not a source-rebuilt or bit-reproducibility claim.

## Workload and comparison class

The recipe copies `schema/canonical-payload.v1.html` unchanged into a temporary
project. The embedded renderer and backend must still match the source after
packaging. The window is 960 x 640; no dev server, updater, custom icon, inspector,
benchmark timer or custom bridge optimization is added. Stock API policy remains
unchanged. The bundle is ad-hoc signed and verified, **not notarized or
App-Sandbox-qualified**.

Classify as `system-wkwebview + txiki/QuickJS backend`, using the actual macOS /
WebKit version. On macOS the bundle launcher starts the backend and the window;
WebKit's additional renderer/GPU/network processes must not be omitted from an
application-wide resource census. A visible page is not proof of backend-ready
interaction. Stock TinyJS backend OS authority is not equivalent to Keld strict
admission; compare both performance and security configuration explicitly.

## Admission still required before measuring

`macos/bench/README.md` prohibits a second runner: the existing KEL-64 runner must
be integrated/aligned with `HARNESS-CONTRACT.md` first. This fixture deliberately
does not invent an arm registry while that owner is absent on `main`.

That runner must add the fixture to its existing arm registry, bind the clean
benchmark commit and this artifact's provenance, and apply any nonce-bearing
instrument only in a session-derived copy. Its checks must reject missing,
stale, wrong or duplicate signals and incomplete process cleanup. Use the same
canonical workload and native architecture in every compared arm. First paint
opportunity and usable backend readiness must stay separate. A renderer-to-
backend RPC cannot share a score with a Rust-to-Rust transport echo.

Do not derive a public Keld/TinyJS ratio until a same-session, randomized paired
campaign meets registry sample and environment policy. Missing Keld product or
bridge capability is an admission blocker, not a zero or an artificial winner.
Windows/Linux fixtures and real-device qualification are not included here.

## Tests

`test_fixture.py` is offline. It covers checked extraction, checksum/size
mismatch, path escape, symlink/hardlink/device/duplicate rejection, private new
output, no overwrite, canonical staging, payload/backend tamper and release pins.
The existing macOS CI job runs these tests and packages the pinned release; it
does not launch a GUI or publish benchmark results.

See [the systems assessment](../../../TINYJSAPP-ASSESSMENT.md) for the adoption
recommendation. (Repository-root assessment: `TINYJSAPP-ASSESSMENT.md`.)
