const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, 'src/index.js'), 'utf8');
const hiddenWindow = source.indexOf('show: false');
const focusRegistration = source.indexOf("mainWindow.webContents.once('dom-ready'");
const show = source.indexOf('mainWindow.show();');
const focus = source.indexOf('mainWindow.focus();');
const navigation = source.indexOf('mainWindow.loadURL(benchmarkURL);');

if (
  hiddenWindow < 0 ||
  focusRegistration < 0 ||
  show < focusRegistration ||
  focus < show ||
  navigation < focus
) {
  throw new Error(
    'the KEL-64 page must be shown and focused from dom-ready before its URL is loaded',
  );
}
