use std::process::ExitCode;

use tauri::{WebviewUrl, WebviewWindowBuilder};

fn benchmark_url() -> Result<tauri::Url, String> {
    let raw =
        std::env::var("KELD_BENCH_URL").map_err(|_| "KELD_BENCH_URL is required".to_owned())?;
    let url =
        tauri::Url::parse(&raw).map_err(|error| format!("invalid KELD_BENCH_URL: {error}"))?;

    if url.scheme() != "http"
        || url.host_str() != Some("127.0.0.1")
        || url.port().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(
            "KELD_BENCH_URL must be a strict http://127.0.0.1:<port>/run/<nonce>/index.html URL"
                .to_owned(),
        );
    }

    let segments: Vec<_> = url
        .path_segments()
        .ok_or_else(|| "KELD_BENCH_URL must contain a path".to_owned())?
        .collect();
    let valid_nonce = segments.get(1).is_some_and(|nonce| {
        nonce.len() == 32
            && nonce
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    });
    if segments.len() != 3 || segments[0] != "run" || !valid_nonce || segments[2] != "index.html" {
        return Err("KELD_BENCH_URL path must be /run/<32 lowercase hex>/index.html".to_owned());
    }
    Ok(url)
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let approved = benchmark_url()
        .map_err(|message| std::io::Error::new(std::io::ErrorKind::InvalidInput, message))?;
    let origin_scheme = approved.scheme().to_owned();
    let origin_host = approved.host_str().unwrap_or_default().to_owned();
    let origin_port = approved.port();

    tauri::Builder::default()
        .setup(move |app| {
            let scheme = origin_scheme.clone();
            let host = origin_host.clone();
            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(approved.clone()))
                .title("Tauri Linux benchmark")
                .inner_size(960.0, 640.0)
                .on_navigation(move |url| {
                    let allowed = url.scheme() == scheme
                        && url.host_str() == Some(host.as_str())
                        && url.port() == origin_port;
                    if !allowed {
                        eprintln!("KELD-BENCH-URL-BLOCKED");
                    }
                    allowed
                })
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())?;
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("tauri-linux-benchmark: {error}");
            ExitCode::from(64)
        }
    }
}
