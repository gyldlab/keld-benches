# Linux Bun -> Rust authenticated KIPC diagnostic (KEL-90)

This fixture measures Keld's shipping Bun KIPC client on a real persistent
host-owned session. It is the Linux successor to the one-session KEL-99
Windows diagnostic, but targets the current IPC registry policy.

The host runner uses `keld_core::HostOwnedHelloSession`, the same primitive
used by the product path. `src/kipc.ts` is copied byte-for-byte from Keld
`0ea0780bb574ad242e9f1105fa4af5842872bad3`, and
`src/kipc-transport.ts` is the canonical `packages/@keld/kipc` transport
that `keld create` embeds at that revision. Only `src/main.ts` adds timing.

## Scope

The scored interval is `Bun.nanoseconds()` immediately before
`AppLinkSession.echo` through its decoded `EchoResponse` return. It includes
the shipping TypeScript codec, serialized socket write, authenticated host
dispatch, framed reply, buffering/reader policy, and response codec.
`AppLinkSession.connect` (socket + HELLO) is measured separately as
`handshake_ns` and excluded from RTT samples.

Tiers match the Linux Rust floor:
- `small`: `{message:"kipc", count:3}` = exactly 6 encoded bytes.
- `representative`: runtime binary search for exactly 1,024 encoded bytes.

This does not include a window or renderer and must not be described as
end-to-end application latency. It is the product Bun KIPC client/host echo
slice.

## Build

```bash
cd linux/keld/kipc-bun-echo
cargo build --release --locked
```

`Cargo.toml` and `Cargo.lock` pin the host runner to the exact Keld
revision. The copied product client hashes at this pin are:

- `kipc.ts`: `fb979d377fadfd2a9058dadf087f837444f17adc59c09acbe2daf24db0596e32`
- `kipc-transport.ts`: `037b7fb3b2f277c28e7ccaf594200ecfba9bca9b19bc04b2234a15590f7b2901`
## Controls and campaign

The runner inherits these variables into the supervised Bun child:
`KELD_BENCH_PROJECT`, `KELD_BENCH_TIER`, `KELD_BENCH_CALLS`,
`KELD_BENCH_OUT`, `KELD_BENCH_KELD_SHA`, and `KELD_BENCH_FAULT`.

Before timing:
- `bad-token` must fail without an output document.
- `wrong-response` must fail after authenticated echo rather than accepting a
  response-shaped value.
- both tiers must prove their exact encoded payload size.

The target campaign is 20 independent fresh-process sessions x 100,000 calls
per tier with whole-session bootstrap confidence intervals. Raw output is
compact one-line JSON preserving every timing sample.

Result-v2 does not currently model that block-sampled corpus, so this evidence
remains diagnostic raw sidecars + manifest. No publication eligibility is
inferred from collecting more samples.

Run a complete campaign only from a clean committed fixture:

```bash
python3 campaign.py \
  --cache-state fresh-process \
  --out-dir /absolute/path/outside-the-repository
```

For `warm-cache`, the controller follows the existing registry/KEL-99
semantics rather than inventing a new state:

```bash
python3 campaign.py \
  --cache-state warm-cache \
  --out-dir /absolute/path/outside-the-repository
```

It runs one unscored priming process pair per payload tier first. Every scored
sample is still a fresh process using the same fixture/project, and each warm
Bun process performs 1,000 untimed authenticated echoes before the 100,000
timed calls, matching the KEL-99 warm mode.

The campaign writes raw documents and a manifest outside the repository first.
Only a fully validated campaign is copied under `linux/bench/results/ipc-rtt/`
as immutable evidence.

### Thermal boundary

The controller uses the shared `linux/bench/thermal.py` fail-closed oracle. The
opening boundary is captured immediately before the 20 scored session pairs and
the closing boundary immediately after the last scored pair. Compilation,
negative controls, warm-cache priming, pilots, and bootstrap/statistics are
outside that thermal window. A future manifest may omit
`THERMAL_STATE_UNVERIFIED` only when CPU throttle counters do not advance, CPU
package sensors stay below their hardware critical limits, and any present
NVIDIA thermal-slowdown flags remain inactive at both boundaries. Sensor loss,
reset, or topology changes remain `unverified`; observed throttle evidence is
`THERMAL_THROTTLED`. Historical manifests are immutable.


## Paired Rust-floor comparison

paired_campaign.py runs a balanced same-machine comparison between this shipping
Bun client/HostOwnedHelloSession slice and the landed
linux/keld/kipc-rust-echo library floor. It accepts the registry-owned
fresh-process and warm-cache states; it does not define a third cache class.

Both arms score exactly 100,000 post-handshake CALL/REPLY operations per round.
For fresh-process the Rust client requests 100,001 calls because its first call
contains HELLO plus the first CALL and is excluded from deltas. For warm-cache
both arms validate 1,000 untimed post-handshake echoes before the same 100,000
scored calls; Rust therefore requests 101,001 total calls. Bun uses its existing
1,000-call warmup path.

Warm-cache also performs one unscored priming process for each arm and payload
tier before pilots/scored rounds, matching the existing registry semantics while
keeping the two arms symmetric.

The campaign uses 20 paired rounds per payload tier. Tier order alternates by
round, and arm order alternates per tier so Rust and Bun each run first exactly
10 times. The paired bootstrap resamples identical round indices for both arms
before recomputing percentile ratios and deltas.

This comparison is a product-client-versus-library-floor diagnostic. The Bun
arm includes shipping TypeScript codec/client and host supervision while the
Rust arm is a direct keld-ipc client/server floor. Therefore the ratio must not
be described as pure Bun language/runtime overhead or as full application,
window, renderer, or keld-dev startup latency.

Run only from a clean committed and pushed fixture:

    python3 paired_campaign.py       --cache-state fresh-process       --out-dir /absolute/path/outside-the-repository

or, for the registered warm-cache treatment:

    python3 paired_campaign.py       --cache-state warm-cache       --out-dir /absolute/path/outside-the-repository

The campaign executes both arms' fail-closed controls and pilots before the
20-round campaign, then writes compact raw documents plus one manifest outside
the repository. Only a fully validated corpus is eligible to be copied into
linux/bench/results/ipc-rtt/ as immutable diagnostic evidence. The same shared
Linux thermal oracle wraps only the scored 20-round paired campaign; build,
controls, priming, pilots, and paired bootstrap analysis remain outside the
thermal session.
