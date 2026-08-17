#!/bin/sh
set -eu

# AC1: the patched recorder emits one nonce-bound four-stage record.
# This does not open a window, run the Swift harness, or score an arm.

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/keld" >&2
  exit 64
fi

keld=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
patch_file="$script_dir/keld-bench-url.patch"

if [ ! -e "$keld/.git" ]; then
  echo "Keld path must be a git checkout" >&2
  exit 64
fi

if ! git -C "$keld" apply --check "$patch_file"; then
  echo "adapter patch does not apply to this Keld checkout" >&2
  exit 65
fi

work=$(/usr/bin/mktemp -d /tmp/keld-startup-trace-ac1.XXXXXX)
cleanup() {
  git -C "$keld" worktree remove --force "$work" >/dev/null 2>&1 || true
  /bin/rm -rf -- "$work" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

# Skip checkout hooks: they clone gitignored research/competitor trees and
# make throwaway worktree cleanup fail.
git -C "$keld" -c core.hooksPath=/dev/null worktree add --detach "$work" >/dev/null
git -C "$work" apply "$patch_file"
cd "$work"
cargo nextest run -p keld-wv bench_trace --profile ci
