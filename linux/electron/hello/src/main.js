"use strict";

const { app, BrowserWindow } = require("electron");

const WINDOW_TITLE = "Electron Linux benchmark";
const RUN_PATH = /^\/run\/[0-9a-f]{32}\/index\.html$/;

function parseBenchmarkUrl(raw) {
  if (typeof raw !== "string" || raw.length === 0) {
    throw new Error("KELD_BENCH_URL is required");
  }
  const parsed = new URL(raw);
  if (
    parsed.protocol !== "http:" ||
    parsed.hostname !== "127.0.0.1" ||
    !parsed.port ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash ||
    !RUN_PATH.test(parsed.pathname)
  ) {
    throw new Error("KELD_BENCH_URL must be an exact loopback benchmark URL");
  }
  return parsed.href;
}

let benchmarkUrl;
try {
  benchmarkUrl = parseBenchmarkUrl(process.env.KELD_BENCH_URL);
} catch (error) {
  console.error(`electron-linux-benchmark: ${error.message}`);
  process.exit(64);
}

app.enableSandbox();

app.whenReady().then(async () => {
  const window = new BrowserWindow({
    width: 960,
    height: 640,
    show: false,
    title: WINDOW_TITLE,
    backgroundColor: "#000000",
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      devTools: false,
    },
  });
  window.setMenu(null);
  window.once("ready-to-show", () => {
    window.show();
    window.focus();
  });

  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event, target) => {
    if (target !== benchmarkUrl) {
      event.preventDefault();
      console.error("KELD-BENCH-URL-BLOCKED");
    }
  });

  try {
    await window.loadURL(benchmarkUrl);
  } catch (error) {
    console.error(`electron-linux-benchmark: load failed: ${error.message}`);
    app.exit(65);
  }
});

app.on("window-all-closed", () => {
  app.quit();
});
