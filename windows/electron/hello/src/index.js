const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

const createWindow = () => {
  const mainWindow = new BrowserWindow({
    width: 960,
    height: 640,
    title: 'Electron Hello',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  mainWindow.loadFile(path.join(__dirname, 'index.html'));
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
