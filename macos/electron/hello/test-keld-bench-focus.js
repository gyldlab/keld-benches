const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, 'src/index.js'), 'utf8');
const hiddenWindow = source.indexOf('show: false');
const targetURL = source.indexOf('const targetURL = benchmarkURL || localURL;');
const navigationRegistration = source.indexOf("mainWindow.webContents.on('did-start-navigation', focusTargetNavigation);");
const focusRegistration = source.indexOf("mainWindow.webContents.on('dom-ready', focusTargetDocument);");
const initialFocus = source.indexOf('  focusTargetView();\n\n  if (benchmarkURL) {');
const navigationGuard = source.indexOf('if (isMainFrame && url === targetURL)');
const targetGuard = source.indexOf('mainWindow.webContents.getURL() !== targetURL');
const show = source.indexOf('mainWindow.show();');
const applicationFocus = source.indexOf('app.focus({ steal: true });');
const focus = source.indexOf('mainWindow.focus();');
const rendererFocus = source.indexOf('mainWindow.webContents.focus();');
const navigation = source.indexOf('mainWindow.loadURL(benchmarkURL);');

if (
  hiddenWindow < 0 ||
  targetURL < 0 ||
  navigationRegistration < 0 ||
  focusRegistration < 0 ||
  initialFocus < focusRegistration ||
  initialFocus > navigation ||
  navigationGuard < 0 ||
  targetGuard < 0 ||
  show < 0 ||
  applicationFocus < 0 ||
  focus < 0 ||
  rendererFocus < 0 ||
  navigation < 0
) {
  throw new Error(
    'the KEL-64 fixture must focus its empty native window before canonical navigation and reassert target focus',
  );
}
