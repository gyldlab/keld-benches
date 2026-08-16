#!/bin/sh
set -eu

fixture_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

node - "$fixture_dir" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const fixtureDir = process.argv[2];
const config = JSON.parse(fs.readFileSync(path.join(fixtureDir, 'neutralino.config.json'), 'utf8'));
const source = fs.readFileSync(path.join(fixtureDir, 'resources/js/main.js'), 'utf8');

if (!config.nativeAllowList.includes('window.focus')) {
  throw new Error('KELD_BENCH_URL navigation requires the native window.focus permission');
}

const focus = source.indexOf('await Neutralino.window.focus();');
const focusEvent = source.indexOf('Neutralino.events.on("windowFocus",');
const focusObserved = source.indexOf('await windowFocusObserved;');
const navigate = source.indexOf('window.location.replace(benchmarkURL);');
if (
  focusEvent < 0 ||
  focus < 0 ||
  focusObserved < 0 ||
  navigate < 0 ||
  focusEvent > focus ||
  focus > focusObserved ||
  focusObserved > navigate
) {
  throw new Error('KELD_BENCH_URL navigation must await the native windowFocus event after window.focus');
}
NODE
