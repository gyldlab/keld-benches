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
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 \
    /usr/bin/git "$@"
}

recipe_root=$(clean_git -C "$script_dir" rev-parse --show-toplevel)
recipe_commit=$(clean_git -C "$recipe_root" rev-parse --verify HEAD^{commit})
recipe_prefix=$(clean_git -C "$script_dir" rev-parse --show-prefix)
if [ "$recipe_prefix" != "linux/webkitgtk/dmabuf-matrix/" ]; then
  echo "recipe must run from linux/webkitgtk/dmabuf-matrix" >&2
  exit 65
fi
recipe_remote=$(clean_git -C "$recipe_root" config --local --no-includes --get remote.origin.url || true)
case "$recipe_remote" in
  https://github.com/gyldlab/keld-benches|https://github.com/gyldlab/keld-benches.git|git@github.com:gyldlab/keld-benches|git@github.com:gyldlab/keld-benches.git) ;;
  *) echo "recipe origin must be the canonical gyldlab/keld-benches repository" >&2; exit 65 ;;
esac

for relative in linux/webkitgtk/dmabuf-matrix/build.sh linux/webkitgtk/dmabuf-matrix/probe.c linux/webkitgtk/dmabuf-matrix/audit.c; do
  if ! clean_git -C "$recipe_root" diff --quiet HEAD -- "$relative" || \
     ! clean_git -C "$recipe_root" diff --cached --quiet HEAD -- "$relative"; then
    echo "recipe input differs from commit: $relative" >&2
    exit 65
  fi
  clean_git -C "$recipe_root" cat-file -e "$recipe_commit:$relative"
done

for package in gtk+-3.0 webkit2gtk-4.1; do
  if ! pkg-config --exists "$package"; then
    echo "missing native build package: $package" >&2
    exit 69
  fi
done

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/kel171-build.XXXXXX")
staged=
cleanup() {
  if [ -n "$staged" ] && { [ -e "$staged" ] || [ -L "$staged" ]; }; then
    rm -rf -- "$staged"
  fi
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

verified_dir="$temporary_root/recipe"
mkdir -m 700 "$verified_dir"
for name in build.sh probe.c audit.c; do
  clean_git -C "$recipe_root" show "$recipe_commit:linux/webkitgtk/dmabuf-matrix/$name" > "$verified_dir/$name"
  cmp -s "$script_dir/$name" "$verified_dir/$name" || {
    echo "executed $name differs from committed bytes" >&2
    exit 65
  }
done

artifact="$temporary_root/kel171-webkitgtk-probe"
audit="$temporary_root/kel171-webkitgtk-audit.so"
system_includes=$(pkg-config --cflags-only-I gtk+-3.0 webkit2gtk-4.1 | sed 's/-I/-isystem /g')
other_cflags=$(pkg-config --cflags-only-other gtk+-3.0 webkit2gtk-4.1)
link_flags=$(pkg-config --libs gtk+-3.0 webkit2gtk-4.1)
cc -std=c11 -O2 -DNDEBUG -Wall -Wextra -Werror -Wpedantic \
  $system_includes $other_cflags "$verified_dir/probe.c" -o "$artifact" $link_flags
cc -std=c11 -O2 -DNDEBUG -Wall -Wextra -Werror -Wpedantic -fPIC -shared \
  $system_includes $other_cflags "$verified_dir/audit.c" -o "$audit" -ldl $link_flags

output_parent=$(dirname -- "$output_dir")
mkdir -p "$output_parent"
staged=$(mktemp -d "$output_parent/.kel171-artifact.XXXXXX")
install -m 755 "$artifact" "$staged/kel171-webkitgtk-probe"
install -m 755 "$audit" "$staged/kel171-webkitgtk-audit.so"
RECIPE_SHA="$recipe_commit" ARTIFACT_SHA=$(sha256sum "$artifact" | awk '{print $1}') \
ARTIFACT_BYTES=$(stat -Lc '%s' "$artifact") \
AUDIT_SHA=$(sha256sum "$audit" | awk '{print $1}') AUDIT_BYTES=$(stat -Lc '%s' "$audit") \
BUILD_SHA=$(sha256sum "$verified_dir/build.sh" | awk '{print $1}') \
SOURCE_SHA=$(sha256sum "$verified_dir/probe.c" | awk '{print $1}') \
AUDIT_SOURCE_SHA=$(sha256sum "$verified_dir/audit.c" | awk '{print $1}') \
CC_VERSION=$(cc --version | sed -n '1p') GTK_VERSION=$(pkg-config --modversion gtk+-3.0) \
WEBKIT_VERSION=$(pkg-config --modversion webkit2gtk-4.1) \
python3 - "$staged/provenance.json" <<'PY'
import json
import os
import sys

document = {
    "schema_version": 1,
    "fixture_repository": "github.com/gyldlab/keld-benches",
    "fixture_commit": os.environ["RECIPE_SHA"],
    "fixture_files": {
        "linux/webkitgtk/dmabuf-matrix/build.sh": os.environ["BUILD_SHA"],
        "linux/webkitgtk/dmabuf-matrix/probe.c": os.environ["SOURCE_SHA"],
        "linux/webkitgtk/dmabuf-matrix/audit.c": os.environ["AUDIT_SOURCE_SHA"],
    },
    "artifact": {
        "basename": "kel171-webkitgtk-probe",
        "sha256": os.environ["ARTIFACT_SHA"],
        "bytes": int(os.environ["ARTIFACT_BYTES"]),
    },
    "audit": {
        "basename": "kel171-webkitgtk-audit.so",
        "sha256": os.environ["AUDIT_SHA"],
        "bytes": int(os.environ["AUDIT_BYTES"]),
    },
    "toolchains": {
        "cc": os.environ["CC_VERSION"],
        "gtk+-3.0": os.environ["GTK_VERSION"],
        "webkit2gtk-4.1": os.environ["WEBKIT_VERSION"],
    },
}
with open(sys.argv[1], "x", encoding="utf-8", newline="\n") as output:
    json.dump(document, output, indent=2, sort_keys=True)
    output.write("\n")
PY

if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
  echo "refusing to overwrite output created during build: $output_dir" >&2
  exit 73
fi
if ! mv -T -n "$staged" "$output_dir"; then
  echo "could not atomically install fixture artifact: $output_dir" >&2
  exit 74
fi
if [ -e "$staged" ] || [ -L "$staged" ]; then
  echo "refusing to overwrite output created during build: $output_dir" >&2
  exit 73
fi
staged=

printf 'artifact=%s/kel171-webkitgtk-probe\n' "$output_dir"
printf 'fixture_commit=%s\n' "$recipe_commit"
