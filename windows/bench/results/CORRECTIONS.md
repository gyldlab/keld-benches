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

## 2026-08-25 — environment.power.ac_power described the wrong moment

**What was wrong.** The emitter sampled `Win32_Battery` at EMISSION time and
wrote the answer into `environment.power.ac_power`. HARNESS-CONTRACT.md requires
AC power *during the measurement*, so the field named the machine's state when
the document was written, not when the session ran.

**How it surfaced.** Re-emitting the 2026-08-25 canonical session to correct an
unrelated sentence produced `ac_power: false` and a blocking `NOT_ON_AC_POWER`
reason. The same session had published `ac_power: true`, `eligible: true` hours
earlier. Nothing about the measurement changed; the laptop had been unplugged in
between. One session, two publication verdicts, neither of them a fact about the
measurement.

**It failed in both directions.** Measure on battery, emit on AC, and the
document would have carried a false AC claim straight through the publication
gate — the same failure with the sign reversed, and that one publishes rather
than refuses.

**Was the published document wrong?** No. The 2026-08-25 canonical session
genuinely ran on mains power: `Win32_Battery.BatteryStatus` read 2 before launch
and the thermal probe's context recorded `CurrentClockSpeed` at the full
3201 MHz throughout, which a discharging laptop on this machine does not hold.
The published value is true — but it was true by the accident of when the
emitter ran, not because anything checked.

**Fix.** `Measure-WindowsGuiSession.ps1` samples power at BOTH session
boundaries and stamps `power_start` / `power_end` into the session, next to the
thermal boundaries it already records. `Emit-PairedSession.ps1` reads those and
refuses to emit a session that has none, rather than substituting its own
reading. `NOT_ON_AC_POWER` now names which boundary failed, because a machine
unplugged mid-session is a different fault from one that was never plugged in.

**The counter is `GetSystemPowerStatus.ACLineStatus`, not
`Win32_Battery.BatteryStatus`.** The first version of this fix tested
`BatteryStatus -ne 1`, which is wrong twice over. Per the `Win32_Battery`
documentation, `1` is "Other", not "discharging"; `4` (Low) and `5` (Critical)
are unambiguously discharging and that test classified both as AC. No value of
`BatteryStatus` establishes the AC line at all — it reports the battery's charge
state. `GetSystemPowerStatus` answers the actual question: `ACLineStatus` 0 is
offline, 1 is online, 255 is unknown.

It also **failed open**: `$onAc` defaulted to `$true` when the query failed or
no battery was found, so an unavailable reading published as AC. That is the
same fail-open the thermal cooling gate had already had to have fixed out of it.
Unknown now yields `null`, and every consumer treats `null` as not-on-AC. The
emitter keeps `null` distinct from `false` so the blocking reason can say which
it was: "we measured battery" and "we could not tell" are different facts for
whoever decides whether to re-run. A desktop with no battery needs no special
case — `ACLineStatus` reports 1 directly.

**Consequence for the published document.** It stays as published at
`b30d145`. It cannot be re-emitted until a session exists that carries a power
record, so the unrelated `session.notes` correction below also waits for the
next measurement. Correcting the sentence today would have meant emitting a
document that falsely said the session was not on AC — trading a wording
overclaim for a false fact.

## 2026-08-25 — a paired document overclaimed what randomized interleaving buys

**What the document said.** `session.notes` on the 2026-08-25 canonical paired
document read "order shuffled within the round, so drift over the session
cannot land on one arm."

**Why that is wrong.** Round-major pairing plus within-round shuffling does buy
a great deal: each arm gets exactly one sample per round, so a session-scale
trend is sampled by both arms alike instead of accumulating on one, and no arm
systematically occupies the first slot. What it does not buy is the absence of
drift. Within a round the second arm is still measured later than the first by
about one launch. Shuffling randomizes *which* arm that is, converting a
systematic order effect into a random one; it does not remove the gap. "Cannot"
was an absolute the method does not support.

Numbers are unaffected: this is a claim about what the design controls for, not
a computation. The medians, the paired ratio 0.8484 and its interval
[0.846864, 0.849548] are unchanged, and the re-emitted document differs from
the withdrawn wording only in `session.notes` and `provenance.bench_sha`.

**Fix.** The sentence is corrected in `Emit-PairedSession.ps1`, which is the
single source of that text. The canonical document is **not** re-emitted today:
the `ac_power` defect recorded above means an emission on battery would write a
false power claim into it, and trading a wording overclaim for a false fact is
not a fix. The document carries the corrected sentence from the next session. The two 2026-08-24 paired documents carry the same sentence and
are deliberately left alone: they are already withdrawn as Keld-versus-Tauri
results, and rewriting a withdrawn record makes the history less legible, not
more.

Found by CodeRabbit on gyldlab/keld#93, reviewing the scoreboard row that
repeated the claim.

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

