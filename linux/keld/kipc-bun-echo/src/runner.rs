//! KEL-90 Linux Bun-to-Rust KIPC diagnostic host runner.
//!
//! Uses Keld's shipping HostOwnedHelloSession so listener, authentication,
//! Bun supervision, and echo dispatch are product primitives under test.

use std::env;
use std::path::PathBuf;
use std::time::Duration;

use keld_core::HostOwnedHelloSession;
use keld_runtime::RestartPolicy;

const RESULT_MARKER: &str = "KELD-90-BUN-IPC-RESULT";
const EXPECTED_FAILURE_MARKER: &str = "KELD-90-BUN-IPC-EXPECTED-FAIL";

fn main() {
    if let Err(error) = run() {
        eprintln!("KELD-90 Bun IPC runner failure: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let project_root = env::var_os("KELD_BENCH_PROJECT")
        .map(PathBuf::from)
        .ok_or_else(|| "KELD_BENCH_PROJECT is required".to_owned())?;
    let fault = env::var("KELD_BENCH_FAULT").unwrap_or_else(|_| "none".to_owned());
    let expected_marker = if fault == "none" {
        RESULT_MARKER
    } else {
        EXPECTED_FAILURE_MARKER
    };

    let session = HostOwnedHelloSession::start_with_stdout_markers(
        &project_root,
        project_root.join("src").join("main.ts"),
        RestartPolicy::default(),
        &[RESULT_MARKER, EXPECTED_FAILURE_MARKER],
    )
    .map_err(|error| error.to_string())?;

    let wait_result = session.wait_until_output_contains(expected_marker, Duration::from_secs(120));
    let output = session.output();
    let shutdown_result = session.shutdown();

    print!("{}", output.stdout);
    eprint!("{}", output.stderr);

    wait_result.map_err(|error| error.to_string())?;
    shutdown_result.map_err(|error| error.to_string())?;
    let marker_count = output.stdout.match_indices(expected_marker).count();
    if marker_count != 1 {
        return Err(format!(
            "expected exactly one {expected_marker} marker, observed {marker_count}"
        ));
    }
    if fault != "none" {
        return Err(format!(
            "negative control {fault} produced the expected client failure; no timing result is valid"
        ));
    }
    Ok(())
}
