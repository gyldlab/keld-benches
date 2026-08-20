# Linux harness (contract slot — no implementation yet)

No Linux measurement has ever been taken in this repo: every
`linux/<framework>/hello/` is a recipe README and there is no harness. This
directory reserves the implementation slot so the first Linux harness lands
inside the metric-runner contract
([`../../HARNESS-CONTRACT.md`](../../HARNESS-CONTRACT.md)) instead of
inventing a third result format.

A first implementation MUST:

- implement the `list-metrics` and `run` verbs with exit codes 0/2/3, starting
  with `PAINT-OPPORTUNITY` (double-rAF image beacon to a loopback listener on
  port 0, one monotonic clock armed before spawn — same oracle as
  `windows/bench/hello.template.html` and the macOS KEL-64 runner);
- emit `schema/result.v1.schema.json` documents (UTF-8, no BOM) into
  `results/<metric-id>/` named per contract §4;
- record the WebKitGTK version in `environment.engine` — the lane on Linux is
  WebKitGTK for system-webview arms, Chromium for Electron/NW.js; never mix
  them in one `vs` cell;
- sample memory only from the harness-owned process tree (cgroup or descendant
  walk with pid-reuse protection), never a global process-name scan;
- commit runnable negative controls alongside (stale nonce rejected, silent
  arm times out, template parameterises port and nonce) — the Windows
  `Test-Harness.ps1` cases are the minimum set;
- keep display-server facts in the environment block (X11 vs Wayland,
  compositor), since paint timing is not comparable across them.

First fixture priority on Linux is `linux/keld/hello/`, per the gap statement
at the top of the contract — before any competitor arm is measured here.
