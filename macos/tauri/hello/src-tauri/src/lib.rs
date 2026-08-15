#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut context = tauri::generate_context!();
    if let Ok(raw_url) = std::env::var("KELD_BENCH_URL") {
        let url = raw_url
            .parse::<tauri::Url>()
            .unwrap_or_else(|error| panic!("KELD_BENCH_URL must be an absolute HTTP URL: {error}"));
        assert!(
            url.scheme() == "http" && url.host_str() == Some("127.0.0.1"),
            "KELD_BENCH_URL must use the harness IPv4 loopback listener"
        );
        let window = context
            .config_mut()
            .app
            .windows
            .first_mut()
            .expect("the hello fixture must configure exactly one window");
        window.url = tauri::utils::config::WebviewUrl::External(url);
    }

    tauri::Builder::default()
        .run(context)
        .expect("error while running tauri application");
}
