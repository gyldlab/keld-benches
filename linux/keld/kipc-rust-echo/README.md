# Linux kipc Rust-to-Rust echo diagnostic (KEL-90)

Two Linux OS processes (kel90-linux-echo-server and kel90-linux-echo-client)
exercise one authenticated Keld IPC session and measure persistent
CALL-to-REPLY round trips on the client's monotonic clock.

This is a library/wire-path diagnostic, not the Keld product client. It has no
Bun main process, host lifecycle, window, or renderer. A passing result must
not be reported as Bun-to-Rust product IPC performance.

## Pin and build

Cargo.toml pins keld-ipc to
gyldlab/keld@0ea0780bb574ad242e9f1105fa4af5842872bad3.

~~~bash
cd linux/keld/kipc-rust-echo
cargo build --release --locked
~~~

The committed lockfile is authoritative after it is generated for this pin.

## Negative control

A forged session token must be rejected by the server before any call is
dispatched, and no result file may be produced:

~~~bash
SOCK=/tmp/kel90-linux-neg.sock
LINK=/tmp/kel90-linux-neg-link.txt
SERVER_ERR=/tmp/kel90-linux-neg-server.err
OUT=/tmp/kel90-linux-must-not-exist.json
rm -f "$SOCK" "$LINK" "$SERVER_ERR" "$OUT"

./target/release/kel90-linux-echo-server "$SOCK" "$LINK" 2>"$SERVER_ERR" &
SERVER_PID=$!
sleep 0.3
./target/release/kel90-linux-echo-client "$LINK" small 100 "$OUT" --bad-token
CLIENT_STATUS=$?
set +e
wait "$SERVER_PID"
SERVER_STATUS=$?
set -e

test "$CLIENT_STATUS" -eq 0
test "$SERVER_STATUS" -ne 0
grep -q KELD-IPC-007 "$SERVER_ERR"
test ! -e "$OUT"
~~~

The client can only observe the pre-auth connection closing; the server-side
KELD-IPC-007 diagnostic is the authoritative forged-token rejection signal.

## One session

~~~bash
SOCK=/tmp/kel90-linux.sock
LINK=/tmp/kel90-linux-link.txt
OUT=/tmp/kel90-linux.raw.json
rm -f "$SOCK" "$LINK" "$OUT"

./target/release/kel90-linux-echo-server "$SOCK" "$LINK" &
SERVER_PID=$!
sleep 0.3
./target/release/kel90-linux-echo-client "$LINK" small 100000 "$OUT"
wait "$SERVER_PID"
~~~

Tiers:
- small: codec-pinned 6-byte EchoRequest payload / 22-byte frame.
- representative: exactly 1,024 encoded payload bytes, derived against the
  pinned codec at runtime rather than hard-coded from a codec assumption.

Call 1 includes HELLO and is recorded as handshake_ns. Calls 2 through 100000
are the 99,999 values in deltas_ns, so handshake time is excluded from the RTT
sample vector as required by the IPC-RTT oracle.

## Campaign policy

schema/metrics.v1.json owns the ipc sample policy: at least 20 independent
fresh-process sessions x 100,000 calls per tier, with statistics bootstrapped
by session blocks. Each session starts a fresh server/client process pair.

Raw documents are intentionally emitted as compact JSON. This retains every
individual timing sample while avoiding one Git diff line per call. Compact
format does not change the data or the statistical unit.

The existing result-v2 schema does not model this independent-session
library-arm corpus. These raw documents therefore remain diagnostic sidecars;
they do not become publication-eligible product results.


## Optional warmup before scored calls

The Linux Rust client also supports an optional --warmup N argument. Warmup
calls run after the authenticated HELLO-bearing first call, validate the same
echo fields, use monotonically increasing correlation IDs, and are excluded
from deltas_ns.

For a warm-cache scored process with 1,000 untimed echoes and exactly 100,000
timed echoes, request 101,001 total calls:

    ./target/release/kel90-linux-echo-client       "$LINK" small 101001 "$OUT" --warmup 1000

The resulting raw document records cache_state=warm-cache, warmup_calls=1000,
calls_requested=101001, and calls_timed=100000. With no --warmup argument the
client records cache_state=fresh-process and preserves the fresh paired
100,001-request / 100,000-scored behavior.

This option exists only to match the registry's established warm-cache
treatment in paired Rust/Bun diagnostics. It does not redefine warm-cache and
does not change historical raw evidence.
