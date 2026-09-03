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
  /usr/bin/env -i \
    HOME=/var/empty \
    PATH=/usr/bin:/bin \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_OPTIONAL_LOCKS=0 \
    /usr/bin/git "$@"
}

recipe_root=$(clean_git -C "$script_dir" rev-parse --show-toplevel)
recipe_prefix=$(clean_git -C "$script_dir" rev-parse --show-prefix)
recipe_commit=$(clean_git -C "$recipe_root" rev-parse --verify HEAD^{commit})
if [ "$recipe_prefix" != "linux/gtk4/hello/" ]; then
  echo "recipe must run from linux/gtk4/hello" >&2
  exit 65
fi
recipe_remote=$(clean_git -C "$recipe_root" config --local --no-includes --get remote.origin.url || true)
case "$recipe_remote" in
  https://github.com/gyldlab/keld-benches|https://github.com/gyldlab/keld-benches.git|git@github.com:gyldlab/keld-benches|git@github.com:gyldlab/keld-benches.git) ;;
  *) echo "recipe origin must be the canonical gyldlab/keld-benches repository" >&2; exit 65 ;;
esac

for relative in linux/gtk4/hello/build.sh linux/gtk4/hello/main.c; do
  if ! clean_git -C "$recipe_root" diff --quiet HEAD -- "$relative" || \
     ! clean_git -C "$recipe_root" diff --cached --quiet HEAD -- "$relative"; then
    echo "recipe input differs from commit: $relative" >&2
    exit 65
  fi
  if ! clean_git -C "$recipe_root" cat-file -e "$recipe_commit:$relative"; then
    echo "recipe input is absent from commit: $relative" >&2
    exit 65
  fi
done

for package in gtk4 webkitgtk-6.0; do
  if ! pkg-config --exists "$package"; then
    echo "missing native build package: $package" >&2
    exit 69
  fi
done

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/keld-gtk4-build.XXXXXX")
verified_dir="$temporary_root/recipe"
artifact="$temporary_root/gtk4-webkit-hello"
staged=
cleanup() {
  if [ -n "$staged" ] && { [ -e "$staged" ] || [ -L "$staged" ]; }; then
    rm -rf -- "$staged"
  fi
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM
mkdir -m 700 "$verified_dir"
clean_git -C "$recipe_root" show "$recipe_commit:linux/gtk4/hello/build.sh" > "$verified_dir/build.sh"
clean_git -C "$recipe_root" show "$recipe_commit:linux/gtk4/hello/main.c" > "$verified_dir/main.c"
cmp -s "$0" "$verified_dir/build.sh" || { echo "executed build.sh differs from committed bytes" >&2; exit 65; }
cmp -s "$script_dir/main.c" "$verified_dir/main.c" || { echo "main.c differs from committed bytes" >&2; exit 65; }

system_includes=$(pkg-config --cflags-only-I gtk4 webkitgtk-6.0 | sed 's/-I/-isystem /g')
other_cflags=$(pkg-config --cflags-only-other gtk4 webkitgtk-6.0)
link_flags=$(pkg-config --libs gtk4 webkitgtk-6.0)
cc -std=c11 -O2 -DNDEBUG -Wall -Wextra -Werror -Wpedantic \
  $system_includes $other_cflags "$verified_dir/main.c" -o "$artifact" $link_flags
if [ ! -x "$artifact" ]; then
  echo "Release build did not produce an executable" >&2
  exit 65
fi

artifact_sha=$(sha256sum "$artifact" | awk '{print $1}')
artifact_bytes=$(stat -Lc '%s' "$artifact")
build_sha=$(sha256sum "$verified_dir/build.sh" | awk '{print $1}')
source_sha=$(sha256sum "$verified_dir/main.c" | awk '{print $1}')
cc_version=$(cc --version | sed -n '1p')
gtk_version=$(pkg-config --modversion gtk4)
webkit_version=$(pkg-config --modversion webkitgtk-6.0)

output_parent=$(dirname -- "$output_dir")
mkdir -p "$output_parent"
staged=$(mktemp -d "$output_parent/.gtk4-native-artifact.XXXXXX")
cp "$artifact" "$staged/gtk4-webkit-hello"
chmod 755 "$staged/gtk4-webkit-hello"
RECIPE_SHA="$recipe_commit" ARTIFACT_SHA="$artifact_sha" ARTIFACT_BYTES="$artifact_bytes" \
BUILD_SHA="$build_sha" SOURCE_SHA="$source_sha" CC_VERSION="$cc_version" \
GTK_VERSION="$gtk_version" WEBKIT_VERSION="$webkit_version" \
python3 - "$staged/provenance.json" <<'PY'
import json
import os
import sys

document = {
    "schema_version": 1,
    "fixture_repository": "github.com/gyldlab/keld-benches",
    "fixture_commit": os.environ["RECIPE_SHA"],
    "fixture_files": {
        "linux/gtk4/hello/build.sh": os.environ["BUILD_SHA"],
        "linux/gtk4/hello/main.c": os.environ["SOURCE_SHA"],
    },
    "artifact": {
        "basename": "gtk4-webkit-hello",
        "sha256": os.environ["ARTIFACT_SHA"],
        "bytes": int(os.environ["ARTIFACT_BYTES"]),
    },
    "toolchains": {
        "cc": os.environ["CC_VERSION"],
        "gtk4": os.environ["GTK_VERSION"],
        "webkitgtk-6.0": os.environ["WEBKIT_VERSION"],
    },
}
with open(sys.argv[1], "x", encoding="utf-8", newline="\n") as output:
    json.dump(document, output, indent=2, sort_keys=True)
    output.write("\n")
PY

if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
  rm -rf -- "$staged"
  staged=
  echo "refusing to overwrite output created during build: $output_dir" >&2
  exit 73
fi
if ! mv -T -n "$staged" "$output_dir"; then
  echo "could not atomically install native fixture artifact: $output_dir" >&2
  exit 74
fi
if [ -e "$staged" ] || [ -L "$staged" ]; then
  echo "refusing to overwrite output created during build: $output_dir" >&2
  exit 73
fi
staged=

printf 'artifact=%s/gtk4-webkit-hello\n' "$output_dir"
printf 'fixture_commit=%s\n' "$recipe_commit"
printf 'artifact_sha256=%s\n' "$artifact_sha"
printf 'artifact_bytes=%s\n' "$artifact_bytes"
printf 'gtk4_version=%s\n' "$gtk_version"
printf 'webkitgtk_version=%s\n' "$webkit_version"
