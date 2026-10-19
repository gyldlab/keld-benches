# KEL-270 T4d S6c2a: the quit deadline D measurement (keld-benches artifact)

Quantity: D, the time the reference application has after the host's `LastWindowClosed`
write at a profile handover to request `Quit` (KEL-53 §4 *Margin and deadlines*).
Rule: D = max(10 s, 4 x the measured maximum).

## What one sample is

One run of the §7 h11 cell (`profiles::handover::kel270_s6c2a_h11_reference_app_quits_within_d_after_handover`
in `crates/keld-host/tests/no_flag_windows.rs`). The host (`keld-host.exe`, debug, built
with `--features kel135-profile-test-root`, installed by the KEL-254 per-user fixture and
operator-signed with the KEL-135 acceptance publisher P1) runs under the debug seam
`KELD_TEST_WINDOWS_HANDOVER=1`: right after the first session's `Ready` it requests a
profile handover, ends its UI loop through `AppWindowCommand::Quit`, writes
`LastWindowClosed` once the loop has returned and waits for the reference application's
`Quit`. The sample is the interval on the host's monotonic clock from the return of that
`LastWindowClosed` write (`signal_last_window_closed`) to the lifecycle-Quit handler's
entry for the frame (`lifecycle_quit`), recorded only for the `Quit` that claims the
session, printed by the host as
`KELD_TEST_WINDOWS_HANDOVER {"cause":"lifecycle-quit","ui_end_us":..,"quit_wait_us":..,"forced_after_us":null,"deadline_us":10000000}`.
`quit_wait_us` is the sample; `ui_end_us` (request to loop return, the barrier wait) is
recorded beside it. The reference application is the t1b fixture
(`crates/keld-host/tests/fixtures/t1b_harness.ts`, bundled with `@keld/api`), which on
`LastWindowClosed` reports `LAST_WINDOW_CLOSED` on its control socket and then invokes
the lifecycle `Quit` call, the same path the `@keld/electron` `window-all-closed` default
takes.

## Subsets

- `idle`: 30 runs, nothing else running on the machine but the harness.
- `load`: 30 runs under full-core load: 16 busy-loop PowerShell processes
  (`while ($true) { $x = 1 }`), one per logical core, started by `burners.ps1 start`
  before the runs and stopped after them (the KEL-270 F55 method).

## Files

- `samples.json`: every run (subset, run, outcome, cause, `quit_wait_us`, `ui_end_us`,
  `deadline_us`), the per-subset min/median/p90/max and the computed D.
- `idle-samples.tsv`, `load-samples.tsv`: the raw evidence lines per run as the runner
  captured them (`run-cell.ps1`), one row per run.
- `idle-runs/`, `load-runs/`: the per-run logs (`run-NN.log`), each with the host's
  stdout (the evidence line, `KELD_PROFILE_TEST_*`, the `KELD_KEL270_H11` record) and
  the test's assertions.
- `burners.log`: the burner start/status/stop receipts of the load subset.
- `environment.json`: machine, OS build, toolchain, WebView2 runtime, host build and
  the commit hash the host and test binary were built from.
- `host-record.json`: the signed host's embed/sign record (hashes, signer thumbprint).
- `analyze_d.py`: the summariser that produced `samples.json` from the two `*-samples.tsv`
  files (`python -I analyze_d.py idle-samples.tsv load-samples.tsv samples.json`).
- `run-cell.ps1`, `run-cells.sh`, `burners.ps1`, `idle-tally.txt`, `load-tally.txt`: the
  runner, the run loop, the load generator and the per-run exit/outcome tallies.
- `SHA256SUMS`: SHA-256 of every other file in this directory (see Verification).
- `SOURCE-SHA256SUMS.txt`: the checksum list of the bundle as captured, before the
  redaction and README changes described under Publication changes.

## Result

Measured 2026-10-14 on a single Windows machine (Windows 11 Home 10.0.26300, AMD Ryzen 7 5800H, 16 logical
cores), WebView2 runtime 155.0.4283.45, rustc 1.97.1, Bun 1.4.2, debug host built from
commit 045b4a45 of the S6c2a branch, https://github.com/gyldlab/keld/pull/722
(`--features kel135-profile-test-root`; later commits of the pull request leave the
measured path unchanged), signed as `hosts/new`
(sha256 83e9e60c5e891a9ba9f3b2b28bb38804e008bee2aa5b0be499a55a4be607ff40).

| subset | n | min | median | p90 | max |
|---|---|---|---|---|---|
| idle | 30 | 0.485 ms | 0.624 ms | 1.060 ms | 1.148 ms |
| full-core load | 30 | 0.739 ms | 1.035 ms | 68.985 ms | 218.510 ms |

Maximum over both subsets: 218.510 ms; four times it is 0.874 s, below the 10 s floor,
so **D = 10 s** (`HANDOVER_QUIT_DEADLINE` in `crates/keld-core/src/app_session.rs`).
Every run passed (60/60). `ui_end_us` (the handover request to the UI loop's return,
dominated by the liveness-gated `BrowserProcessExited` barrier) reached 29.1 s under
load; it is not part of D.

Note: a `cargo check -p keld-core --tests` (one light build) ran on the machine during
load runs 15 to 17; it adds load beside the burners and can only lengthen samples.

## Estimator note

The p90 column (and `p90` in `samples.json`) is `sorted(samples)[min(n - 1, int(0.9 * n))]`
(`analyze_d.py`), the zero-based element at index `int(0.9 * n)` of the ascending sort,
which for n = 30 is the 28th smallest sample. It is **not** the nearest-rank estimator
(the `ceil(0.9 * n)`-th smallest, the 27th for n = 30), so it can read one rank higher.
p90 is descriptive only: D is derived from the maxima, never from p90.

## Publication changes

This directory is the captured bundle plus these changes, made when it was published in
keld-benches; no sample value, timing, outcome or tally was changed.

- This `Estimator note` and the `Verification` section were added, the `Files` list
  was completed, the per-run log name was corrected from `run-NN.utf8.log` to `run-NN.log`,
  and the machine name in `Result` was replaced by a generic phrase.
- `HARNESS-CONTRACT.md` section 1 forbids absolute paths, home directories and hostnames in
  committed files, so a byte-wise literal replacement was applied to the captured files:
  the user profile directory (plain and JSON-escaped) became `%USERPROFILE%`, the Keld
  worktree path became `<keld-worktree>`, the local evidence directory (also in
  `run-cell.ps1`, `run-cells.sh` and `burners.ps1`) became `<evidence-dir>`, and the
  machine name became `<redacted-hostname>` (in `environment.json`). The scripts therefore
  need `<evidence-dir>` set to a real directory before they can be re-run.
  Line endings of the captured files (CRLF in the logs, the TSVs, the tallies and the JSON
  files) are preserved; `.gitattributes` marks this directory `-text` so a checkout does
  not rewrite them.
- `SOURCE-SHA256SUMS.txt` lists the hashes of the unredacted captured files, so the
  replacement can be audited by file; it is expected to disagree with the files that were
  redacted and is not a verification list.

## Verification

```
cd windows/keld/handover-quit-deadline-2026-10-14
sha256sum -c SHA256SUMS
```

Every line must report `OK`. `SHA256SUMS` covers all files except itself, with `./`
relative paths, and is computed over the exact bytes in the repository.
