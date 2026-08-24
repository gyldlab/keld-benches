# Windows Keld kipc persistent-echo fixture

This fixture owns the KEL-99 **Windows diagnostic** path. It measures one live
Keld host-owned app-link: a host mints a loopback-TCP endpoint and 32-byte
token, spawns Bun with `KELD_APP_LINK`, the current template client completes
the mutual authenticated `HELLO`, and then makes 10,000 sequential typed echo
`CALL`/`REPLY` pairs on that one connection.

Run it through [`../../bench/Run-KipcEcho.ps1`](../../bench/Run-KipcEcho.ps1),
not by invoking `main.ts` directly. The runner reuses
`keld_core::HostOwnedHelloSession`, which is the production primitive used by
both `keld dev` and `run_dev_echo`; it does not create an in-process fake echo
loop or a second socket implementation. It copies the `kipc.ts` template from
the selected Keld revision and records its hash, so the Bun client remains the
current wire-exact product client.

The exact request is `{ message: "keld-99-persistent-echo", count: 99 }`; its
postcard payload is asserted to stay no larger than 128 bytes. Each reply must
match both fields. The timer is `Bun.nanoseconds()` immediately before
`await session.echo(...)` and immediately after it returns, so the timed path
includes client encode/decode and socket I/O as well as host dispatch. HELLO
and optional warm-up calls are excluded and reported separately.

`fresh-process` records a process-cold session with no application-call
warm-up. `warm-cache` first runs one unscored process pair, then records a
fresh process pair after 1,000 validated unscored calls. They are different
cache-state documents and must never be pooled.

## Scope and limits

This fixture intentionally produces a valid but **publication-ineligible**
diagnostic. The registry policy needs at least 20 independent sessions with
100,000 calls each and block-bootstrap analysis; this KEL-99 slice is one
10,000-call Bun arm. Its raw values may report nearest-rank p50/p90/p99 for
that session, but they cannot pass or fail Keld's 100 microsecond architecture
budget, compare Rust to Bun, establish Windows/Linux parity, attribute
allocation/copy cost, or justify a protocol optimisation.

KEL-7 is a design-and-evidence survey, not a same-machine competitor baseline;
these results therefore record the current Windows product slice only. They
must not be presented as a Keld-versus-KEL-7 ratio or as evidence for a fifth
Keld unique.

`Test-KipcEcho.ps1` runs two real negative controls:

- a wrong HELLO token must fail before any timing result;
- an intentionally wrong expected echo response must fail after the live
  authenticated session starts, rather than accepting a response-shaped value.

Those controls leave no result document. Every generated result records
versions and hashes for Keld core/host, CLI, Bun, Rust, the client template,
the harness, runner, source commits, Windows build, CPU, and observed power
state. The runner refuses a dirty Keld or benches source tree before timing.
