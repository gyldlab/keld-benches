const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const createWindow = () => {
  const mainWindow = new BrowserWindow({
    width: 960,
    height: 640,
    show: false,
    title: 'Electron Hello',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  const localURL = pathToFileURL(path.join(__dirname, 'index.html')).href;
  const benchmarkURL = process.env.KELD_BENCH_URL;
  const targetURL = benchmarkURL || localURL;
  const focusTargetDocument = () => {
    if (mainWindow.webContents.getURL() !== targetURL) {
      return;
    }
    mainWindow.show();
    mainWindow.focus();
    mainWindow.webContents.focus();
    mainWindow.webContents.removeListener('dom-ready', focusTargetDocument);
  };
  mainWindow.webContents.on('dom-ready', focusTargetDocument);

  if (benchmarkURL) {
    mainWindow.loadURL(benchmarkURL);
  } else {
    mainWindow.loadURL(localURL);
  }
  mainWindow.webContents.on('did-finish-load', () => {
    try {
      fs.writeFileSync('/tmp/keld-benches-electron-painted', 'painted');
    } catch {
      // measurement marker only
    }
  });
};

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  app.quit();
});
