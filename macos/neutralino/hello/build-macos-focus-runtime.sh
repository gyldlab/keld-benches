#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 /absolute/path/to/neutralinojs-v6.9.0 /absolute/output/neutralino-mac_arm64" >&2
  exit 64
fi

source_dir=$1
output_binary=$2
fixture_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
patch_file="$fixture_dir/patches/v6.9.0-macos-window-focus-webview.patch"
source_commit=2cec764ac5e3ccc5b1b44d046d6e6d6c85c3099e

case $source_dir in
  /*) ;;
  *) echo "source checkout must be an absolute path" >&2; exit 64 ;;
esac
case $output_binary in
  /*) ;;
  *) echo "output binary must be an absolute path" >&2; exit 64 ;;
esac

test -d "$source_dir/.git" || {
  echo "Neutralino source checkout is not a Git worktree: $source_dir" >&2
  exit 65
}
test ! -e "$output_binary" || {
  echo "refusing to overwrite existing output binary: $output_binary" >&2
  exit 73
}
test -z "$(git -C "$source_dir" status --porcelain)" || {
  echo "Neutralino source checkout must be clean: $source_dir" >&2
  exit 65
}
test "$(git -C "$source_dir" rev-parse HEAD)" = "$source_commit" || {
  echo "expected Neutralino v6.9.0 commit $source_commit" >&2
  exit 65
}

command -v cmake >/dev/null || {
  echo "cmake is required to build Neutralino from source" >&2
  exit 69
}
command -v ninja >/dev/null || {
  echo "ninja is required to build Neutralino from source" >&2
  exit 69
}

work_dir=$(mktemp -d /private/tmp/keld-neutralino-v6.9.0-focus.XXXXXX)
git -C "$source_dir" archive --format=tar "$source_commit" | tar -x -C "$work_dir"
patch --batch --forward -d "$work_dir" -p1 < "$patch_file"

cmake -S "$work_dir" -B "$work_dir/build" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build "$work_dir/build"

mkdir -p "$(dirname -- "$output_binary")"
cp "$work_dir/bin/neutralino-mac_arm64" "$output_binary"
printf 'built patched Neutralino runtime: %s\n' "$output_binary"
printf 'build workspace retained for inspection: %s\n' "$work_dir"
