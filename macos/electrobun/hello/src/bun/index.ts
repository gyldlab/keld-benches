import { BrowserWindow } from "electrobun/bun";

const _mainWindow = new BrowserWindow({
	title: "Electrobun Hello",
	url: "views://mainview/index.html",
	frame: {
		width: 960,
		height: 640,
		x: 200,
		y: 200,
	},
});
