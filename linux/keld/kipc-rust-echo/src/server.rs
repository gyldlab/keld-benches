//! KEL-90 Linux Rust<->Rust kipc echo server: one OS process, one accepted
//! connection, one authenticated session served to EOF. Cross-process (not
//! `UnixStream::pair()` in one process, unlike `crates/keld-ipc/tests/echo_link.rs`)
//! so the OS process/scheduler boundary the product client also crosses is
//! real here too.
//!
//! Usage: kel90-linux-echo-server <socket-path> <app-link-out-path>
//!
//! Mints a fresh `SessionToken`, writes `<endpoint>#<64 hex>` to
//! `app-link-out-path` (the same `KELD_APP_LINK` shape the product uses),
//! then accepts exactly one connection and serves it with
//! `keld_ipc::serve_echo_session` until the peer disconnects.

use std::fs::OpenOptions;
use std::io::{ErrorKind, Write as _};
use std::os::unix::fs::OpenOptionsExt as _;
use std::os::unix::net::UnixListener;
use std::time::{Duration, Instant};

use keld_ipc::{format_app_link, serve_echo_session, SessionToken, APP_LINK_IO_DEADLINE};

fn main() -> std::process::ExitCode {
    let mut args = std::env::args().skip(1);
    let (Some(socket_path), Some(app_link_out)) = (args.next(), args.next()) else {
        eprintln!("usage: kel90-linux-echo-server <socket-path> <app-link-out-path>");
        return std::process::ExitCode::FAILURE;
    };
    if args.next().is_some() {
        eprintln!("kel90-linux-echo-server accepts exactly two arguments");
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
    // `create_new` refuses a path that already exists (a symlink included),
    // so a pre-planted symlink cannot redirect this write; mode 0o600 keeps
    // the live session token unreadable by other local accounts.
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&app_link_out)
        .and_then(|mut file| {
            file.write_all(app_link.as_bytes())?;
            file.sync_all()
        }) {
        Ok(()) => {}
        Err(error) => {
            eprintln!("write {app_link_out}: {error}");
            return std::process::ExitCode::FAILURE;
        }
    }

    if let Err(error) = listener.set_nonblocking(true) {
        eprintln!("set listener nonblocking: {error}");
        let _ = std::fs::remove_file(&socket_path);
        let _ = std::fs::remove_file(&app_link_out);
        return std::process::ExitCode::FAILURE;
    }
    let accept_deadline = Instant::now() + APP_LINK_IO_DEADLINE;
    let (mut stream, _peer) = loop {
        match listener.accept() {
            Ok(pair) => break pair,
            Err(error)
                if error.kind() == ErrorKind::WouldBlock && Instant::now() < accept_deadline =>
            {
                std::thread::sleep(Duration::from_millis(1));
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                eprintln!("accept timed out after {APP_LINK_IO_DEADLINE:?}");
                let _ = std::fs::remove_file(&socket_path);
                let _ = std::fs::remove_file(&app_link_out);
                return std::process::ExitCode::FAILURE;
            }
            Err(error) => {
                eprintln!("accept: {error}");
                let _ = std::fs::remove_file(&socket_path);
                let _ = std::fs::remove_file(&app_link_out);
                return std::process::ExitCode::FAILURE;
            }
        }
    };
    if let Err(error) = stream.set_nonblocking(false) {
        eprintln!("set accepted stream blocking: {error}");
        let _ = std::fs::remove_file(&socket_path);
        let _ = std::fs::remove_file(&app_link_out);
        return std::process::ExitCode::FAILURE;
    }

    // The client has already read the token out of app_link_out by the time
    // a connection lands; remove it so the file (and the token) does not
    // outlive the session it authenticates.
    let _ = std::fs::remove_file(&app_link_out);
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
