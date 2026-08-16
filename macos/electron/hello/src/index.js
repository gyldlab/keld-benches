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
  const focusTargetView = () => {
    mainWindow.show();
    app.focus({ steal: true });
    mainWindow.focus();
    mainWindow.webContents.focus();
  };
  const focusTargetNavigation = (_event, url, _isInPlace, isMainFrame) => {
    if (isMainFrame && url === targetURL) {
      focusTargetView();
    }
  };
  const focusTargetDocument = () => {
    if (mainWindow.webContents.getURL() !== targetURL) {
      return;
    }
    focusTargetView();
    mainWindow.webContents.removeListener('did-start-navigation', focusTargetNavigation);
    mainWindow.webContents.removeListener('dom-ready', focusTargetDocument);
  };
  mainWindow.webContents.on('did-start-navigation', focusTargetNavigation);
  mainWindow.webContents.on('dom-ready', focusTargetDocument);

  // Focus only the new native window while it still contains about:blank. The
  // canonical page then inherits focus for its first rendering opportunity;
  // the guarded navigation and dom-ready handlers reassert it for that page.
  focusTargetView();

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
