import SwiftUI
import WebKit

/// Same local document Keld's hello slice loads (`crates/keld-wv/src/hello/mod.rs`).
private let helloHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Keld</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 0; display: grid;
           place-items: center; min-height: 100vh; background: #0b0f14; color: #e8eef5; }
    h1 { font-weight: 600; letter-spacing: -0.02em; }
    p { opacity: 0.75; max-width: 32rem; text-align: center; line-height: 1.5; }
  </style>
</head>
<body>
  <div>
    <h1>Keld</h1>
    <p>Hello from WKWebView — Phase 1 window-on-screen vertical slice.</p>
  </div>
</body>
</html>
"""

@main
struct HelloSwiftUIApp: App {
    var body: some Scene {
        WindowGroup("Native Hello SwiftUI") {
            WebView(html: helloHTML)
        }
        .defaultSize(width: 960, height: 640)
    }
}

/// Apple's current SwiftUI embedding path: `NSViewRepresentable` wrapping `WKWebView`
/// (not the deprecated `WebView` / `WebKit.WebView` class).
struct WebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = URL(fileURLWithPath: "/tmp/keld-native-hello-swiftui-painted")
            try? "painted".write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
