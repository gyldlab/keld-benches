//! KEL-129 Rust<->Rust kipc echo server: one OS process, one accepted
//! connection, one authenticated session served to EOF. Cross-process (not
//! `UnixStream::pair()` in one process, unlike `crates/keld-ipc/tests/echo_link.rs`)
//! so the OS process/scheduler boundary the product client also crosses is
//! real here too.
//!
//! Usage: kel129-echo-server <socket-path> <app-link-out-path>
//!
//! Mints a fresh `SessionToken`, writes `<endpoint>#<64 hex>` to
//! `app-link-out-path` (the same `KELD_APP_LINK` shape the product uses),
//! then accepts exactly one connection and serves it with
//! `keld_ipc::serve_echo_session` until the peer disconnects.

use std::io::Write as _;
use std::os::unix::net::UnixListener;

use keld_ipc::{SessionToken, format_app_link, serve_echo_session};

fn main() -> std::process::ExitCode {
    let mut args = std::env::args().skip(1);
    let (Some(socket_path), Some(app_link_out)) = (args.next(), args.next()) else {
        eprintln!("usage: kel129-echo-server <socket-path> <app-link-out-path>");
        return std::process::ExitCode::FAILURE;
    };
    if args.next().is_some() {
        eprintln!("kel129-echo-server accepts exactly two arguments");
        return std::process::ExitCode::FAILURE;
    }

    let _ = std::fs::remove_file(&socket_path);
    let listener = match UnixListener::bind(&socket_path) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("bind {socket_path}: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };

    let token = match SessionToken::random() {
        Ok(token) => token,
        Err(error) => {
            eprintln!("mint session token: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    let app_link = format_app_link(&socket_path, &token);
    match std::fs::File::create(&app_link_out).and_then(|mut file| {
        file.write_all(app_link.as_bytes())?;
        file.sync_all()
    }) {
        Ok(()) => {}
        Err(error) => {
            eprintln!("write {app_link_out}: {error}");
            return std::process::ExitCode::FAILURE;
        }
    }

    let (mut stream, _peer) = match listener.accept() {
        Ok(pair) => pair,
        Err(error) => {
            eprintln!("accept: {error}");
            let _ = std::fs::remove_file(&socket_path);
            return std::process::ExitCode::FAILURE;
        }
    };

    let result = serve_echo_session(&mut stream, &token);
    let _ = std::fs::remove_file(&socket_path);

    match result {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("serve_echo_session: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}
