# kipc Rust↔Rust echo (KEL-129, note 242 Gap 1)

Two OS processes (`kel129-echo-server`, `kel129-echo-client`), one authenticated
kipc session, N `CALL`→`REPLY` round trips on the client's own monotonic
clock. Closes the census note's `ipc.rtt.macos.library-arm` gap
(`library/quality-evidence/performance/238-macos-raw-evidence-census.md`) with
a real cross-process measurement instead of the in-process
[research note 140](https://github.com/0monish/keld-research/blob/main/library/quality-evidence/140-measured-opt-hunt.md)
example. It measures `keld-ipc`'s wire path only — no Bun, no host, no window;
it is **not** the product client. The Bun product client's kipc RTT stays
`unmeasured`, as recorded in
[research note 234](https://github.com/0monish/keld-research/blob/main/library/quality-evidence/performance/234-macos-budget-feasibility.md)
§7.1 B5 and its own note 242 addendum.

## Pin

`Cargo.toml` pins `keld-ipc` via a `git`/`rev` dependency to
`4fbf94bbb755854058067b986877177f00b25a39` (`gyldlab/keld` main at the time
this fixture was measured). Re-pin by editing that one line; the crate's
public API used here (`SessionToken`, `format_app_link`/`parse_app_link`,
`echo_call`/`echo_invoke`, `serve_echo_session`) is the same surface
`crates/keld-ipc/tests/echo_link.rs` exercises, so a future incompatible
change there will fail this fixture's build, not silently drift its meaning.

## Build

```bash
cd macos/keld/kipc-rust-echo
cargo build --release --locked
```

`--locked` uses the committed `Cargo.lock` as-is instead of re-resolving, so a
second operator builds the exact dependency graph this fixture was measured
against.

## Negative control

The server must reject a forged token before any call is dispatched, and the
client must produce no output file when that happens:

```bash
SOCK=/tmp/kel129-neg.sock; LINK=/tmp/kel129-neg-link.txt; SERVER_ERR=/tmp/kel129-neg-server.err
rm -f "$SOCK" "$LINK" "$SERVER_ERR" /tmp/should-not-exist.json
./target/release/kel129-echo-server "$SOCK" "$LINK" 2>"$SERVER_ERR" &
SERVER_PID=$!
sleep 0.3
./target/release/kel129-echo-client "$LINK" small 100 /tmp/should-not-exist.json --bad-token
CLIENT_STATUS=$?
wait "$SERVER_PID"
SERVER_STATUS=$?
test "$CLIENT_STATUS" -eq 0 \
  && test "$SERVER_STATUS" -ne 0 \
  && grep -q KELD-IPC-007 "$SERVER_ERR" \
  && test ! -e /tmp/should-not-exist.json \
  && echo "negative control passed"
```

The client alone cannot distinguish a token rejection from any other
connection failure: on a mismatch, `handshake_server` closes the stream
without writing a reply (`crates/keld-ipc/src/link.rs`, by design — a peer
must not be able to tell "wrong token" from any other pre-auth failure over
the wire), so the client only ever observes a plain I/O EOF. The client's
exit code therefore just confirms it did *not* see a successful echo
(`Ok(_)` is always `FAILURE`); the server's own stderr log is the
authoritative signal, which is why the compound check above greps it for
`KELD-IPC-007` rather than trusting the client's exit code alone. Verified
2026-09-10 on this device: server logged `KELD-IPC-007` and exited
non-zero; client exited zero and wrote no file.

## Run one session

```bash
SOCK=/tmp/kel129.sock; LINK=/tmp/kel129-link.txt
rm -f "$SOCK" "$LINK"
./target/release/kel129-echo-server "$SOCK" "$LINK" &
sleep 0.3
./target/release/kel129-echo-client "$LINK" small 100000 /tmp/out.json
wait
```

`<tier>` is `small` (the codec's pinned `{message:"kipc",count:3}` vector,
6-byte payload / 22-byte frame) or `representative` (a 1,024-byte payload,
binary-searched at run time against the actual postcard encoding rather than
hand-derived, so a codec version change cannot silently drift it).

## Sample policy and results

Registry `ipc` class (`schema/metrics.v1.json` `sample_policy.ipc`): ≥20
sessions × 100,000 calls, block-bootstrap by session. `results/ipc-rtt/`
holds 20 sessions × 2 tiers = 40 raw documents, one call short of 100,000
timed deltas per session (`calls_timed: 99999`) because call 1 is folded into
`handshake_ns` (`echo_call` does HELLO + the first CALL together; calls 2..N
use `echo_invoke` directly and are what `deltas_ns` times), matching the
registry oracle's "handshake excluded and reported separately."

Each session is a fresh server + client process pair (`fresh-process` cache
state); no OS-level cache warming is attempted or claimed.
