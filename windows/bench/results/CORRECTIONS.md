# Corrections

Result documents are immutable once committed (`HARNESS-CONTRACT.md` §4). When
a committed document is later found to be wrong or unsafe to quote, it is
corrected **here**, not edited in place.

---

## 2026-08-24 — the two paired keld-vs-tauri documents measured a beacon-instrumented Tauri binary

**Affected documents**

- `mem-idle/2026-08-24.kel25-windows-keld-vs-tauri-paired-30.fresh-process.json`
- `mem-idle/2026-08-24.kel25-windows-keld-vs-tauri-thermal-30.fresh-process.json`

Both record `arms[tauri].artifact.sha256 =
9cfee0a246326290031130bc7446de0bc854113a8c22fca7de1da3dae8484b25`.

**What is wrong**

That binary does not embed the Tauri fixture's own page. It embeds a
**paint-beacon-instrumented** page left over from an earlier
`Measure-FirstPaint.ps1`-style session. Verified by extraction, not inference:
the only `tauri-codegen-assets` blob whose bytes appear inside that exe sits at
offset `6061195`, decompresses to **1717 bytes**, contains
`requestAnimationFrame`, and fires

```js
new Image().src = "http://127.0.0.1:54321/painted?nonce=testnonce123"
```

on every launch. Port 54321 had no listener during either session, so each
Tauri launch also performed a failing loopback request.

**Why it matters, and which way it biases**

The Tauri arm therefore carried a `<script>` block, its JIT, and a failing
network request that the Keld arm did not. The two arms were not rendering
comparable content, which is exactly what `provenance.payload_sha256` exists to
prevent — and neither document carried that field.

The bias runs **in Keld's favour**: the arm Keld was compared against was doing
extra work. The reported results —

- paired-30: ratio 0.8332, "Keld 16.7% smaller"
- thermal-30: ratio 0.8468, "Keld 15.3% smaller"

— **must not be quoted as Keld-versus-Tauri results.** They remain valid as
records of what was measured, and their raw data is retained, but the
comparison conclusion is withdrawn.

**What was done**

`schema/canonical-payload.v1.html` (225 bytes, ASCII, LF, no BOM, sha256
`26f6ad058d3350b46aa131ab281aa478b6c705a60af15c8755a369f66bab7f37`) is now the
shared page. It was copied verbatim to `windows/tauri/hello/src/index.html` and
the Tauri binary was force-rebuilt (`cargo clean -p tauri-hello --release` then
`cargo build --release`, 41.5 s — a plain build is a no-op because `build.rs`
emits no `rerun-if-changed` for `../src`).

The new artifact is `d3f0fec3cb14263b33a5b643ac20178abb63e5b3b48e8954aeef517245ae1f3a`.
Verified by extracting the embedded asset from that exe: 225 bytes,
`requestAnimationFrame` absent, sha256 equal to the canonical page.

**How this was missed, and the check that now exists**

The contaminated binary was already on disk when the Tauri arm was adopted, and
nothing verified what a measured artifact actually renders — only that it built
and showed a window. A build succeeding says nothing about what it embedded.
Any future document claiming payload parity must verify by **extracting the
page from the artifact whose sha256 the document cites**, which is the check
that caught this.

**Resolved 2026-08-25**

The re-run was performed: `mem-idle/2026-08-25.kel25-windows-keld-vs-tauri-canonical-30.fresh-process.json`.
Both arms verified to deliver payload
`26f6ad058d3350b46aa131ab281aa478b6c705a60af15c8755a369f66bab7f37`, the Tauri
side by extraction from the artifact that document cites. It carries the
environment-parity and scope disclosures noted below. The withdrawal above
still stands for the two 2026-08-24 documents; this note does not reinstate
them.

Note also that source-byte parity is not rendered-environment parity: Tauri's
webview exposes `__TAURI_INTERNALS__`, `__TAURI_EVENT_PLUGIN_INTERNALS__`,
`ipc` and `isTauri` before the document runs, and Keld exposes none. Identical
bytes still execute in non-identical environments, and a future paired document
must disclose that rather than imply full parity.

---

## 2026-08-25 — a raw sidecar was paired with a document from a different session

**Affected file**

- `mem-idle/2026-08-25.kel25-windows-keld-vs-tauri-canonical-30.fresh-process.raw.json`
  (renamed to `…-superseded-1056z.fresh-process.raw.json`)

**What was wrong**

The repository pairs `X.json` with `X.raw.json` by basename. That sidecar was
committed by hand in `fe7b3d6` from a session that ran **10:56:17Z–11:00:19Z
with seed 20260824**. The document later written under the same basename came
from a different session: **11:08:26Z–11:12:38Z, seed 20260825**.

Nothing in the repository compared them. `schema/check.py` reads only
`schema/examples/`; `validate_result_v1.py` validates one document internally
and passes; `Check-PublishedMeasurements.ps1` only checks `MEASUREMENTS.md` rows
carrying an inline `raw-median source=` marker, and the paired section carries
none.

Recomputing the headline from the mismatched sidecar gives median ratio
**0.847438** against the document's **0.8501** — the document's point estimate
falls outside the sidecar's own CI95 `[0.843445, 0.848198]`. Two different
sessions, as the timestamps and seed already said.

The earlier session's document was never committed: it was discarded the same
day for recording `keld_sha=2a8e8a4` against a binary built at `58708bb`. Its
raw records were committed anyway and outlived it.

**What was done**

The sidecar is renamed rather than deleted — it is real data from a real
session, and it is now labelled with that session's own start time so it cannot
be read as belonging to any document.

The cause is fixed at the boundary rather than by convention:
`Emit-PairedSession.ps1` now writes the sidecar **itself**, from the same
session object it emits the document from, so the pair cannot diverge again.
A hand-committed sidecar was always going to drift eventually.

