import AppKit
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

/// `NSApplication.delegate` is weak; keep the nib-less delegate alive for the run loop.
private var retainedDelegate: AppDelegate?

@main
enum HelloAppKit {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

/// Closest AppKit analogue to wry's WKWebView host: one `NSWindow`, one `WKWebView`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var navigationDelegate: FirstPaintDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Native Hello AppKit"
        window.center()

        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        let nav = FirstPaintDelegate()
        webView.navigationDelegate = nav
        navigationDelegate = nav
        webView.loadHTMLString(helloHTML, baseURL: nil)

        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

final class FirstPaintDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = URL(fileURLWithPath: "/tmp/keld-native-hello-appkit-painted")
        try? "painted".write(to: url, atomically: true, encoding: .utf8)
    }
}
