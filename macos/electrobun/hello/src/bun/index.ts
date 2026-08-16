import { BrowserWindow } from "electrobun/bun";

const benchmarkURL = process.env.KELD_BENCH_URL;
const _mainWindow = new BrowserWindow({
	title: "Electrobun Hello",
	url: null,
	hidden: true,
	frame: {
		width: 960,
		height: 640,
		x: 200,
		y: 200,
	},
});

// Keep native creation hidden until the WebView is attached; then show and
// activate it before navigation so WKWebView receives a focused first
// responder before the KEL-64 double-rAF beacon runs.
_mainWindow.show();
_mainWindow.activate();
_mainWindow.webview.loadURL(benchmarkURL || "views://mainview/index.html");
