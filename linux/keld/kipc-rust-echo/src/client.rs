//! KEL-90 Linux Rust<->Rust kipc echo client: one OS process, one authenticated
//! session, N timed `CALL`/`REPLY` round trips on the parent (this process's
//! own) monotonic clock, matching the registry `IPC-RTT` oracle
//! ("persistent authenticated CALL->REPLY; handshake excluded and reported
//! separately").
//!
//! Usage:
//!   kel90-linux-echo-client <app-link-path> <tier> <calls> <out-json-path> [--bad-token] [--warmup N]
//!
//! `<tier>` is `small` (the codec's pinned `{message:"kipc",count:3}` vector,
//! 6-byte payload / 22-byte frame) or `representative` (a 1,024-byte
//! deterministic payload / 1,040-byte frame). `--bad-token` is the negative
//! control and must fail HELLO before output. `--warmup N` validates N
//! post-handshake echoes without timing them; `<calls>` still counts every
//! CALL including the HELLO-bearing first call.

use std::io::Read as _;
use std::os::unix::net::UnixStream;
use std::time::Instant;

use keld_ipc::{echo_call, echo_invoke, parse_app_link, CorrelationId, EchoRequest, SessionToken};

fn representative_message() -> String {
    // Deterministic ASCII, count 0, so the encoded payload is exactly 1,024
    // bytes (1,040-byte frame) as specified in research note 242 SS4.1.
    // postcard string encoding = varint length prefix + bytes; count:u64=0
    // costs 1 byte; the varint length prefix for a 1017-byte string is 2
    // bytes (payload length in 128..=16383 range) -> 1017 + 2 + 1 = 1020.
    // Padded/trimmed at runtime to the exact target below rather than
    // hand-derived, so a postcard version change cannot silently drift it.
    "R".repeat(4096)
}

fn build_request(tier: &str) -> Result<(EchoRequest, usize), String> {
    match tier {
        "small" => Ok((
            EchoRequest {
                message: "kipc".to_owned(),
                count: 3,
            },
            6,
        )),
        "representative" => {
            let target_payload_bytes: usize = 1024;
            let mut msg = representative_message();
            // Binary-search the exact string length whose postcard-encoded
            // EchoRequest payload is exactly `target_payload_bytes`, rather
            // than hard-coding a length that depends on the codec version.
            let mut lo = 0usize;
            let mut hi = msg.len();
            loop {
                let mid = (lo + hi) / 2;
                let candidate = EchoRequest {
                    message: msg[..mid].to_owned(),
                    count: 0,
                };
                let encoded = keld_ipc::codec::encode(&candidate)
                    .map_err(|error| format!("encode probe: {error}"))?;
                match encoded.len().cmp(&target_payload_bytes) {
                    std::cmp::Ordering::Equal => {
                        msg.truncate(mid);
                        break;
                    }
                    std::cmp::Ordering::Less => lo = mid + 1,
                    std::cmp::Ordering::Greater => hi = mid,
                }
                if lo >= hi {
                    return Err(format!(
                        "no exact-length representative payload found near {mid} bytes"
                    ));
                }
            }
            Ok((
                EchoRequest {
                    message: msg,
                    count: 0,
                },
                target_payload_bytes,
            ))
        }
        other => Err(format!(
            "unknown tier '{other}' (want small|representative)"
        )),
    }
}

fn main() -> std::process::ExitCode {
    let raw_args: Vec<String> = std::env::args().skip(1).collect();
    let mut bad_token = false;
    let mut warmup_calls: u32 = 0;
    let mut positional: Vec<&String> = Vec::new();
    let mut index = 0usize;
    while index < raw_args.len() {
        match raw_args[index].as_str() {
            "--bad-token" => {
                bad_token = true;
                index += 1;
            }
            "--warmup" => {
                let Some(value) = raw_args.get(index + 1) else {
                    eprintln!("--warmup requires a non-negative integer");
                    return std::process::ExitCode::FAILURE;
                };
                warmup_calls = match value.parse::<u32>() {
                    Ok(value) => value,
                    Err(_) => {
                        eprintln!("--warmup requires a non-negative integer");
                        return std::process::ExitCode::FAILURE;
                    }
                };
                index += 2;
            }
            option if option.starts_with("--") => {
                eprintln!("unknown option {option}");
                return std::process::ExitCode::FAILURE;
            }
            _ => {
                positional.push(&raw_args[index]);
                index += 1;
            }
        }
    }
    let [app_link_path, tier, calls_str, out_path] = positional[..] else {
        eprintln!(
            "usage: kel90-linux-echo-client <app-link-path> <tier> <calls> <out-json-path> [--bad-token] [--warmup N]"
        );
        return std::process::ExitCode::FAILURE;
    };
    let calls: u64 = match calls_str.parse() {
        Ok(n) if n >= 1 => n,
        _ => {
            eprintln!("<calls> must be a positive integer");
            return std::process::ExitCode::FAILURE;
        }
    };
    let (request, payload_bytes) = match build_request(tier) {
        Ok(pair) => pair,
        Err(msg) => {
            eprintln!("{msg}");
            return std::process::ExitCode::FAILURE;
        }
    };

    let mut app_link = String::new();
    if let Err(error) =
        std::fs::File::open(app_link_path).and_then(|mut f| f.read_to_string(&mut app_link))
    {
        eprintln!("read {app_link_path}: {error}");
        return std::process::ExitCode::FAILURE;
    }
    let (endpoint, token) = match parse_app_link(app_link.trim()) {
        Ok(pair) => pair,
        Err(error) => {
            eprintln!("parse_app_link: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    let token = if bad_token {
        // Flip every byte of the real token so the negative control cannot
        // collide with the real one by construction.
        let mut bytes = [0u8; keld_ipc::SESSION_TOKEN_LEN];
        for (dst, src) in bytes.iter_mut().zip(token.to_hex().as_bytes().chunks(2)) {
            let hex_byte =
                u8::from_str_radix(std::str::from_utf8(src).unwrap_or("00"), 16).unwrap_or(0);
            *dst = !hex_byte;
        }
        SessionToken::from_bytes(bytes)
    } else {
        token
    };

    let mut stream = match UnixStream::connect(endpoint) {
        Ok(s) => s,
        Err(error) => {
            eprintln!("connect {endpoint}: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };

    let handshake_start = Instant::now();
    let first = echo_call(&mut stream, &request, &token);
    let handshake_ns = handshake_start.elapsed().as_nanos() as u64;

    if bad_token {
        // handshake_server (crates/keld-ipc/src/link.rs) returns Err and
        // closes without writing a reply on a token mismatch, by design
        // (admission.rs: a peer must not be able to distinguish "wrong
        // token" from any other pre-auth failure over the wire). So the
        // client can only ever observe a plain I/O EOF here, never
        // IpcError::HelloAuth directly; that is why this check is
        // necessary-but-not-sufficient and the README's negative-control
        // procedure additionally greps the server's own stderr log for
        // KELD-IPC-007 as the authoritative confirmation.
        return match first {
            Err(error) => {
                println!(
                    "bad-token negative control: client saw {error} \
                     (consistent with rejection; confirm KELD-IPC-007 in the server log)"
                );
                std::process::ExitCode::SUCCESS
            }
            Ok(_) => {
                eprintln!("bad-token negative control FAILED: server accepted a forged token");
                std::process::ExitCode::FAILURE
            }
        };
    }

    let first = match first {
        Ok(reply) => reply,
        Err(error) => {
            eprintln!("first echo_call (HELLO + call 1): {error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    if first.count != request.count || first.message != request.message {
        eprintln!("first reply did not match request fields (echo not byte-faithful)");
        return std::process::ExitCode::FAILURE;
    }

    let calls_u32: u32 = match u32::try_from(calls) {
        Ok(n) => n,
        Err(_) => {
            eprintln!("<calls> must fit in u32 (CorrelationId is u32)");
            return std::process::ExitCode::FAILURE;
        }
    };
    let post_handshake_calls = calls_u32.saturating_sub(1);
    if warmup_calls > post_handshake_calls {
        eprintln!(
            "--warmup {warmup_calls} exceeds the {post_handshake_calls} post-handshake calls"
        );
        return std::process::ExitCode::FAILURE;
    }

    let warmup_end = 1u32.saturating_add(warmup_calls);
    for corr in 2..=warmup_end {
        let reply = match echo_invoke(&mut stream, &request, CorrelationId(corr)) {
            Ok(reply) => reply,
            Err(error) => {
                eprintln!("warmup echo_invoke call {corr}: {error}");
                return std::process::ExitCode::FAILURE;
            }
        };
        if reply.count != request.count || reply.message != request.message {
            eprintln!("warmup call {corr}: reply did not match request fields");
            return std::process::ExitCode::FAILURE;
        }
    }

    let timed_start = warmup_end.saturating_add(1);
    let timed_capacity = calls_u32.saturating_sub(warmup_end) as usize;
    let mut deltas_ns: Vec<u64> = Vec::with_capacity(timed_capacity);
    for corr in timed_start..=calls_u32 {
        let t0 = Instant::now();
        let reply = match echo_invoke(&mut stream, &request, CorrelationId(corr)) {
            Ok(r) => r,
            Err(error) => {
                eprintln!("echo_invoke call {corr}: {error}");
                return std::process::ExitCode::FAILURE;
            }
        };
        let elapsed_ns = t0.elapsed().as_nanos() as u64;
        if reply.count != request.count || reply.message != request.message {
            eprintln!("call {corr}: reply did not match request fields");
            return std::process::ExitCode::FAILURE;
        }
        deltas_ns.push(elapsed_ns);
    }
    drop(stream); // clean EOF so the server's serve_echo_requests loop returns Ok(())

    let bun_revision = std::process::Command::new("bun")
        .arg("--revision")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_owned());

    let json = serde_json::json!({
        "schema_version": 1,
        "fixture": "kel90-linux-kipc-rust-echo",
        "keld_sha": "0ea0780bb574ad242e9f1105fa4af5842872bad3",
        "clock": "std::time::Instant, one call per iteration, client-owned",
        "tier": tier,
        "payload_bytes": payload_bytes,
        "handshake_ns": handshake_ns,
        "handshake_included_in_deltas": false,
        "cache_state": if warmup_calls == 0 { "fresh-process" } else { "warm-cache" },
        "warmup_calls": warmup_calls,
        "calls_requested": calls,
        "calls_timed": deltas_ns.len(),
        "note_calls_timed": format!(
            "call 1 (HELLO + first CALL) and {warmup_calls} warmup calls are excluded from deltas_ns"
        ),
        "deltas_ns": deltas_ns,
        "bun_context_process_revision_unused_control": bun_revision,
    });
    if let Err(error) = std::fs::write(out_path, serde_json::to_vec(&json).unwrap_or_default()) {
        eprintln!("write {out_path}: {error}");
        return std::process::ExitCode::FAILURE;
    }
    println!(
        "wrote {out_path}: {} timed calls, handshake {handshake_ns} ns",
        deltas_ns.len()
    );
    std::process::ExitCode::SUCCESS
}
