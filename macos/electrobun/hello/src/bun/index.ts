import { BrowserWindow } from "electrobun/bun";

const benchmarkURL = process.env.KELD_BENCH_URL;
const _mainWindow = new BrowserWindow({
	title: "Electrobun Hello",
	url: benchmarkURL || "views://mainview/index.html",
	frame: {
		width: 960,
		height: 640,
		x: 200,
		y: 200,
	},
});
