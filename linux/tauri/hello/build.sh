#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /absolute/output-directory" >&2
  exit 64
fi

output_dir=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$output_dir" in
  /*) ;;
  *) echo "output directory must be absolute" >&2; exit 64 ;;
esac
if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
  echo "refusing to overwrite existing output: $output_dir" >&2
  exit 73
fi

clean_git() {
  /usr/bin/env -i     PATH=/usr/bin:/bin     LC_ALL=C     GIT_CONFIG_NOSYSTEM=1     GIT_CONFIG_GLOBAL=/dev/null     GIT_NO_REPLACE_OBJECTS=1     GIT_OPTIONAL_LOCKS=0     /usr/bin/git "$@"
}

recipe_root=$(clean_git -C "$script_dir" rev-parse --show-toplevel)
recipe_prefix=$(clean_git -C "$script_dir" rev-parse --show-prefix)
recipe_commit=$(clean_git -C "$recipe_root" rev-parse --verify HEAD^{commit})
if [ "$recipe_prefix" != "linux/tauri/hello/" ]; then
  echo "recipe must run from linux/tauri/hello" >&2
  exit 65
fi
recipe_remote=$(clean_git -C "$recipe_root" config --local --no-includes --get remote.origin.url || true)
case "$recipe_remote" in
  https://github.com/gyldlab/keld-benches|https://github.com/gyldlab/keld-benches.git|git@github.com:gyldlab/keld-benches|git@github.com:gyldlab/keld-benches.git) ;;
  *) echo "recipe origin must be the canonical gyldlab/keld-benches repository" >&2; exit 65 ;;
esac

inputs="
linux/tauri/hello/build.sh
linux/tauri/hello/src/index.html
linux/tauri/hello/src-tauri/Cargo.toml
linux/tauri/hello/src-tauri/Cargo.lock
linux/tauri/hello/src-tauri/build.rs
linux/tauri/hello/src-tauri/tauri.conf.json
linux/tauri/hello/src-tauri/src/main.rs
linux/tauri/hello/src-tauri/icons/icon.png
"
for relative in $inputs; do
  if ! clean_git -C "$recipe_root" diff --quiet HEAD -- "$relative" ||      ! clean_git -C "$recipe_root" diff --cached --quiet HEAD -- "$relative"; then
    echo "recipe input differs from commit: $relative" >&2
    exit 65
  fi
  if ! clean_git -C "$recipe_root" cat-file -e "$recipe_commit:$relative"; then
    echo "recipe input is absent from commit: $relative" >&2
    exit 65
  fi
done

for package in gtk+-3.0 webkit2gtk-4.1; do
  if ! pkg-config --exists "$package"; then
    echo "missing Tauri Linux build package: $package" >&2
    exit 69
  fi
done

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/keld-tauri-linux-build.XXXXXX")
verified="$temporary_root/fixture"
staged=
cleanup() {
  if [ -n "$staged" ] && { [ -e "$staged" ] || [ -L "$staged" ]; }; then
    rm -rf -- "$staged"
  fi
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM
mkdir -m 700 "$verified"

for relative in $inputs; do
  destination="$verified/${relative#linux/tauri/hello/}"
  mkdir -p "$(dirname -- "$destination")"
  clean_git -C "$recipe_root" show "$recipe_commit:$relative" > "$destination"
done

for relative in $inputs; do
  local_path="$script_dir/${relative#linux/tauri/hello/}"
  verified_path="$verified/${relative#linux/tauri/hello/}"
  cmp -s "$local_path" "$verified_path" || {
    echo "working input differs from committed bytes: $relative" >&2
    exit 65
  }
done

(
  cd "$verified/src-tauri"
  cargo build --release --locked
)
built="$verified/src-tauri/target/release/tauri-hello"
if [ ! -x "$built" ]; then
  echo "Release build did not produce tauri-hello" >&2
  exit 65
fi

artifact_sha=$(sha256sum "$built" | awk '{print $1}')
artifact_bytes=$(stat -Lc '%s' "$built")
cargo_version=$(cargo -V)
rustc_version=$(rustc -Vv | tr '\n' ';')
gtk_version=$(pkg-config --modversion gtk+-3.0)
webkit_version=$(pkg-config --modversion webkit2gtk-4.1)
tauri_version=$(python3 - "$verified/src-tauri/Cargo.lock" <<'PY'
import sys
from pathlib import Path
name = None
for line in Path(sys.argv[1]).read_text().splitlines():
    if line == '[[package]]':
        name = None
    elif line.startswith('name = '):
        name = line.split('"', 2)[1]
    elif name == 'tauri' and line.startswith('version = '):
        print(line.split('"', 2)[1])
        break
else:
    raise SystemExit("tauri package missing from Cargo.lock")
PY
)
[ "$tauri_version" = "2.11.5" ] || { echo "unexpected Tauri version: $tauri_version" >&2; exit 65; }

output_parent=$(dirname -- "$output_dir")
mkdir -p "$output_parent"
staged=$(mktemp -d "$output_parent/.tauri-linux-artifact.XXXXXX")
cp "$built" "$staged/tauri-linux-hello"
chmod 755 "$staged/tauri-linux-hello"

RECIPE_SHA="$recipe_commit" ARTIFACT_SHA="$artifact_sha" ARTIFACT_BYTES="$artifact_bytes" CARGO_VERSION="$cargo_version" RUSTC_VERSION="$rustc_version" GTK_VERSION="$gtk_version" WEBKIT_VERSION="$webkit_version" TAURI_VERSION="$tauri_version" python3 - "$recipe_root" "$staged/provenance.json" $inputs <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
files = sys.argv[3:]

digests = {}
for relative in files:
    data = subprocess.run(
        ["/usr/bin/git", "show", f"{os.environ['RECIPE_SHA']}:{relative}"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout
    digests[relative] = hashlib.sha256(data).hexdigest()

document = {
    "schema_version": 1,
    "fixture_repository": "github.com/gyldlab/keld-benches",
    "fixture_commit": os.environ["RECIPE_SHA"],
    "fixture_files": digests,
    "artifact": {
        "basename": "tauri-linux-hello",
        "sha256": os.environ["ARTIFACT_SHA"],
        "bytes": int(os.environ["ARTIFACT_BYTES"]),
    },
    "framework": {"name": "Tauri", "version": os.environ["TAURI_VERSION"]},
    "toolchains": {
        "cargo": os.environ["CARGO_VERSION"],
        "rustc": os.environ["RUSTC_VERSION"],
        "gtk+-3.0": os.environ["GTK_VERSION"],
        "webkit2gtk-4.1": os.environ["WEBKIT_VERSION"],
    },
}
with out.open("x", encoding="utf-8", newline="\n") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
  echo "refusing to overwrite output created during build: $output_dir" >&2
  exit 73
fi
if ! mv -T -n "$staged" "$output_dir"; then
  echo "could not atomically install Tauri fixture artifact: $output_dir" >&2
  exit 74
fi
staged=

printf 'artifact=%s/tauri-linux-hello\n' "$output_dir"
printf 'fixture_commit=%s\n' "$recipe_commit"
printf 'artifact_sha256=%s\n' "$artifact_sha"
printf 'artifact_bytes=%s\n' "$artifact_bytes"
printf 'tauri_version=%s\n' "$tauri_version"
printf 'webkitgtk_version=%s\n' "$webkit_version"
