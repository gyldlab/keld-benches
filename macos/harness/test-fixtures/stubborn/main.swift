import AppKit
import Darwin
import Foundation
import WebKit

final class StubbornProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var child: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["120"]
        do {
            try child.run()
        } catch {
            FileHandle.standardError.write(Data("could not launch cleanup probe child: \(error)\n".utf8))
            Darwin.exit(70)
        }
        self.child = child

        guard let rawURL = ProcessInfo.processInfo.environment["KELD_BENCH_URL"],
              let url = URL(string: rawURL) else {
            Darwin.exit(64)
        }
        let contentRect = NSRect(x: 0, y: 0, width: 960, height: 640)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let webView = WKWebView(frame: contentRect)
        window.contentView = webView
        window.title = "Stubborn cleanup probe"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: url))
        self.window = window
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateCancel
    }
}

let application = NSApplication.shared
let delegate = StubbornProbeDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
