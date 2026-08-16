#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then
  echo "usage: $0" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
package_json="$script_dir/package.json"
asar_bin="$script_dir/node_modules/.bin/asar"
node_bin=$(command -v node || true)

if [ -z "$node_bin" ] || [ ! -x "$node_bin" ]; then
  echo "node must be installed and executable" >&2
  exit 69
fi
if [ ! -x "$asar_bin" ]; then
  echo "Electron dependencies are missing; run npm install first" >&2
  exit 69
fi
for required in ditto codesign plutil shasum; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "required macOS tool is missing: $required" >&2
    exit 69
  fi
done

electron_version=$(
  cd "$script_dir" &&
  "$node_bin" -p "require('./package.json').devDependencies.electron"
)
case "$electron_version" in
  43.4.0) ;;
  *)
    echo "fixture expects Electron 43.4.0, found $electron_version" >&2
    exit 65
    ;;
esac
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "this fixture recipe requires a macOS arm64 host" >&2
  exit 69
fi

zip_path=${KELD_ELECTRON_ZIP:-}
if [ -z "$zip_path" ]; then
  cache_root=${HOME:?HOME must be set}/Library/Caches/electron
  zip_path=$(
    find "$cache_root" -type f \
      -name "electron-v${electron_version}-darwin-arm64.zip" \
      -print -quit 2>/dev/null || :
  )
fi
if [ -z "$zip_path" ] || [ ! -f "$zip_path" ] || [ -L "$zip_path" ]; then
  echo "official Electron zip not found; run node node_modules/electron/install.js" >&2
  exit 69
fi

output_root=${KELD_ELECTRON_OUTPUT:-$script_dir/out}
if [ -L "$output_root" ] || { [ -e "$output_root" ] && [ ! -d "$output_root" ]; }; then
  echo "Electron output root must be a real directory: $output_root" >&2
  exit 65
fi
/bin/mkdir -p "$output_root"
output_app="$output_root/Electron Hello.app"
if [ -e "$output_app" ] || [ -L "$output_app" ]; then
  echo "refusing to overwrite existing Electron app: $output_app" >&2
  echo "remove that ignored build product explicitly, then rerun this recipe" >&2
  exit 73
fi

temporary_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/keld-electron-build.XXXXXX")
cleanup() {
  /bin/rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

runtime_root="$temporary_root/runtime"
staged_app="$temporary_root/Electron Hello.app"
app_source="$temporary_root/app-source"
app_asar="$staged_app/Contents/Resources/app.asar"
/bin/mkdir -m 700 "$runtime_root" "$app_source"
/usr/bin/ditto -x -k "$zip_path" "$runtime_root"
if [ ! -d "$runtime_root/Electron.app" ] || [ -L "$runtime_root/Electron.app" ]; then
  echo "official Electron zip did not contain Electron.app" >&2
  exit 65
fi
/usr/bin/ditto "$runtime_root/Electron.app" "$staged_app"

for source_file in package.json src/index.js src/index.html src/preload.js; do
  if [ ! -f "$script_dir/$source_file" ] || [ -L "$script_dir/$source_file" ]; then
    echo "Electron fixture source must be a regular file: $source_file" >&2
    exit 65
  fi
  destination_directory="$app_source/$(dirname "$source_file")"
  /bin/mkdir -p "$destination_directory"
  /bin/cp "$script_dir/$source_file" "$app_source/$source_file"
done

resources_directory="$staged_app/Contents/Resources"
if [ -e "$resources_directory/app" ] || [ -L "$resources_directory/app" ]; then
  echo "Electron app must not contain a loose Resources/app fallback" >&2
  exit 65
fi
"$asar_bin" pack "$app_source" "$app_asar"
if [ ! -f "$app_asar" ] || [ -L "$app_asar" ]; then
  echo "Electron app.asar was not created" >&2
  exit 65
fi

info_plist="$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Electron Hello" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Electron Hello" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.keld.benches.electron" "$info_plist"

# Electron's embedded ASAR integrity fuse validates the hash of the raw ASAR
# header stored in this plist dictionary. Keep this beside the fuse write so a
# package cannot claim integrity while omitting the corresponding hash.
(
  cd "$script_dir"
  "$node_bin" - "$staged_app" "$app_asar" <<'NODE'
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { getRawHeader } = require('@electron/asar');
const { flipFuses, FuseVersion, FuseV1Options } = require('@electron/fuses');

const app = process.argv[2];
const asar = process.argv[3];
const plist = `${app}/Contents/Info.plist`;
const rawHeader = getRawHeader(asar);
const headerHash = crypto.createHash('sha256').update(rawHeader.headerString).digest('hex');
const plistBuddy = (command) => execFileSync(
  '/usr/libexec/PlistBuddy',
  ['-c', command, plist],
  { stdio: ['ignore', 'pipe', 'pipe'] },
);
const addIfMissing = (command) => {
  try {
    plistBuddy(command);
  } catch (error) {
    if (!String(error.stderr || '').includes('Already Exists')) throw error;
  }
};
const setOrAddString = (key, value) => {
  try {
    plistBuddy(`Set ${key} ${value}`);
  } catch (error) {
    if (!String(error.stderr || '').includes('Does Not Exist')) throw error;
    plistBuddy(`Add ${key} string ${value}`);
  }
};
addIfMissing('Add :ElectronAsarIntegrity dict');
addIfMissing('Add :ElectronAsarIntegrity:Resources/app.asar dict');
setOrAddString(':ElectronAsarIntegrity:Resources/app.asar:algorithm', 'SHA256');
setOrAddString(':ElectronAsarIntegrity:Resources/app.asar:hash', headerHash);

(async () => {
  await flipFuses(app, {
    version: FuseVersion.V1,
    [FuseV1Options.RunAsNode]: false,
    [FuseV1Options.EnableCookieEncryption]: true,
    [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
    [FuseV1Options.EnableNodeCliInspectArguments]: false,
    [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
    [FuseV1Options.OnlyLoadAppFromAsar]: true,
  });
  console.log(`asar_header_sha256=${headerHash}`);
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
NODE
)

/usr/bin/codesign --force --deep --sign - "$staged_app"
/usr/bin/plutil -lint "$staged_app/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$staged_app"
if ! "$asar_bin" list "$app_asar" | /usr/bin/grep -Fqx '/package.json'; then
  echo "app.asar is missing package.json at its root" >&2
  exit 65
fi
if ! "$asar_bin" list "$app_asar" | /usr/bin/grep -Fqx '/src/index.js'; then
  echo "app.asar is missing src/index.js" >&2
  exit 65
fi

(
  cd "$script_dir"
  "$node_bin" - "$staged_app" <<'NODE'
const { getCurrentFuseWire } = require('@electron/fuses');

(async () => {
  const app = process.argv[2];
  const wire = await getCurrentFuseWire(app);
  const enabled = [1, 4, 5];
  const disabled = [0, 2, 3];
  for (const index of enabled) {
    if (wire[index] !== 49) throw new Error(`Electron fuse ${index} is not enabled`);
  }
  for (const index of disabled) {
    if (wire[index] !== 48) throw new Error(`Electron fuse ${index} is not disabled`);
  }
  console.log('electron_fuses=OnlyLoadAppFromAsar,EnableEmbeddedAsarIntegrityValidation');
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
NODE
)

/usr/bin/ditto "$staged_app" "$output_app"
/usr/bin/codesign --verify --deep --strict "$output_app"
echo "app=$output_app"
echo "app_asar=$output_app/Contents/Resources/app.asar"
echo "electron_version=$electron_version"
