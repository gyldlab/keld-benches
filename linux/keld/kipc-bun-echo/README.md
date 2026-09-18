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


## Paired Rust-floor comparison

paired_campaign.py runs a balanced same-machine fresh-process comparison between
this shipping Bun client/HostOwnedHelloSession slice and the landed
linux/keld/kipc-rust-echo library floor.

Both arms score exactly 100,000 post-handshake CALL/REPLY operations per round.
The Rust client is invoked with 100,001 requested calls because its first call
contains HELLO plus the first CALL and is intentionally excluded from deltas;
the remaining 100,000 echo_invoke calls are scored. The Bun arm scores 100,000
AppLinkSession.echo calls after its separately measured HELLO.

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

    python3 paired_campaign.py --out-dir /absolute/path/outside-the-repository

The campaign executes both arms' fail-closed controls and pilots before the
20-round campaign, then writes compact raw documents plus one manifest outside
the repository. Only a fully validated corpus is eligible to be copied into
linux/bench/results/ipc-rtt/ as immutable diagnostic evidence.
