# Original draw.io 31.7.0 — common source document (fixture only)

This 1,040-byte file is the **same prospective input source for both KELD and Electron arms**. Do not clone it into framework-specific fixtures. It is an ordinary draw.io XML document, not the renderer or an executable. The original draw.io 31.7.0 application binaries, the adapted renderer, security profile and cache policy require separate SHA-pinned provenance.

The file is copied without transformation from a retained original-editor *application-created pre-edit backup*. Independent Apple Silicon macOS validation found byte-identical baseline/candidate pre-edit backups. Its SHA-256 is `236ffe4a7936e1d541b50e26f070177085dcdf5779055e67de6ba379801ba7a3`. The backup was created **after historical launch**; it is **not** independent prelaunch evidence for those past attempts. See Linear KEL-90, 2026-11-06 input-stage-custody and prelaunch-seed evidence. Historical runs stay unqualified.

Before **each future independent process launch**, the owning benchmark controller must capture a generation-independent timestamp and verify this exact path, size and SHA-256. Stage identical source bytes into both isolated arm inputs without altering the document; independently record which file each app actually opened and the pre-edit editor XML/geometry. After the x+10 edit, verify actual Save, genuine Exit, fresh-process Reopen and error-free IPC delivery. Report all Host/Guardian/Bun/WebKit/auxiliary members and use one common observed clock interval. Registered 30 balanced independent sessions, cache/zoom/theme/viewport and quiet-machine controls remain required. A correct file hash alone is **not** admitted useful work or proof of RAM/CPU improvement.

Low-cost local source sanity check (not a performance benchmark):

```sh
cd macos/keld/drawio-31.7.0
shasum -a 256 scene.drawio
xmllint --noout scene.drawio
wc -c < scene.drawio
```

Do not treat different post-Save `<mxfile host>` metadata as identical saved bytes, or normalize output errors. No new benchmark harness, metric, result document, permission grant or application policy is introduced by this fixture.

### Non-scoring native correctness controller

`native_research_controller.py` integrates the retained KEL-90 native
correctness investigation with the immutable source checker above. It is a
**fixture-local diagnostic**, not the OS `bench/` metric runner, a collector,
or a substitute for the KEL-64 harness. Its three explicit actions are:

- `stage`: use `--arm baseline|candidate --attempt 01 --attempt-id <UUID>
  --attempt-dir <existing-absolute-real-directory>` to create an exclusive
  source attestation, an identical staged document and a binding receipt. The
  destination must be outside the source directory and have no symlinked
  ancestors. It refuses a reused attempt or a changed checker/source.
- `screen-log`: use `--log <actual-final-native-log>` to reject known denied
  Guard/IPC calls and page failures even when the binary reports success. A
  passed screen is **negative evidence only**, never editor/workload admission.
- `run-native`: accepts an existing, OS-qualified `--pair-root` and
  `--drivers-dir` for the **previously owned** diagnostic GUI workflow. Do not
  invoke it without an exclusive Mac GUI session, authorized OS permissions,
  fresh binary/source qualification and no competing measurement/build load.
  Its output is explicitly non-scoring, including when the terminal is green.

The native control regression suite is runnable with
`python3 -B -m unittest -v test_native_research_controller` from this fixture
folder. These tests stage real SHA-pinned files and launch the real checker
subprocess, but intentionally do **not** launch a GUI or claim measured RAM/CPU.
Retained historical native logs with `KELD-IPC-005` remain inadmissible; GH540
owns delivery semantics and GH1404 owns the original-editor functional path.
Fresh application-loaded-byte, Open→Edit→Save→fresh Reopen→Quit, entire
process-coalition and independent matched-session proof remain separate
requirements before any score or KELD/Electron comparison can be published.
