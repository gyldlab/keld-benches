#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 /path/to/keld SOURCE_GIT_SHA /absolute/output-directory" >&2
  exit 64
fi

source_repo=$1
source_sha=$2
output_dir=$3
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
clean_git() {
  /usr/bin/env -i \
    HOME=/var/empty \
    PATH=/usr/bin:/bin \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git "$@"
}
recipe_root=$(clean_git -C "$script_dir" rev-parse --show-toplevel)
recipe_prefix=$(clean_git -C "$script_dir" rev-parse --show-prefix)
patch_path="$script_dir/keld-bench-url.patch"
payload_path="$script_dir/index.html"

case "$source_sha" in
  *[!0-9a-f]*|'') echo "SOURCE_GIT_SHA must be a full lowercase SHA-1 commit" >&2; exit 64 ;;
esac
if [ "${#source_sha}" -ne 40 ]; then
  echo "SOURCE_GIT_SHA must contain exactly 40 hexadecimal characters" >&2
  exit 64
fi
case "$output_dir" in
  /*) ;;
  *) echo "output directory must be absolute" >&2; exit 64 ;;
esac
if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
  echo "refusing to overwrite existing output: $output_dir" >&2
  exit 73
fi
if [ "$recipe_prefix" != "linux/keld/hello/" ]; then
  echo "recipe must run from linux/keld/hello" >&2
  exit 65
fi

source_remote=$(clean_git -C "$source_repo" config --local --no-includes --get remote.origin.url || true)
case "$source_remote" in
  https://github.com/gyldlab/keld|https://github.com/gyldlab/keld.git|git@github.com:gyldlab/keld|git@github.com:gyldlab/keld.git) ;;
  *) echo "source origin must be the canonical gyldlab/keld repository" >&2; exit 65 ;;
esac
recipe_remote=$(clean_git -C "$recipe_root" config --local --no-includes --get remote.origin.url || true)
case "$recipe_remote" in
  https://github.com/gyldlab/keld-benches|https://github.com/gyldlab/keld-benches.git|git@github.com:gyldlab/keld-benches|git@github.com:gyldlab/keld-benches.git) ;;
  *) echo "recipe origin must be the canonical gyldlab/keld-benches repository" >&2; exit 65 ;;
esac

resolved_sha=$(clean_git -C "$source_repo" rev-parse --verify "$source_sha^{commit}")
if [ "$resolved_sha" != "$source_sha" ]; then
  echo "SOURCE_GIT_SHA did not resolve exactly" >&2
  exit 65
fi
if ! clean_git ls-remote --heads https://github.com/gyldlab/keld.git | awk -v sha="$source_sha" '$1 == sha { found = 1 } END { exit found ? 0 : 1 }'; then
  echo "SOURCE_GIT_SHA must be a branch head advertised by canonical origin" >&2
  exit 65
fi

recipe_commit=$(clean_git -C "$recipe_root" rev-parse --verify HEAD^{commit})
for relative in linux/keld/hello/build.sh linux/keld/hello/index.html linux/keld/hello/keld-bench-url.patch; do
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

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/keld-linux-build.XXXXXX")
worktree="$temporary_root/source"
target_dir="$temporary_root/target"
product_artifact="$temporary_root/keld-host-product"
verified_dir="$temporary_root/recipe"
staged=
cleanup() {
  if [ -n "$staged" ] && { [ -e "$staged" ] || [ -L "$staged" ]; }; then
    rm -rf -- "$staged"
  fi
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM
mkdir -m 700 "$verified_dir"
clean_git -C "$recipe_root" show "$recipe_commit:linux/keld/hello/build.sh" > "$verified_dir/build.sh"
clean_git -C "$recipe_root" show "$recipe_commit:linux/keld/hello/index.html" > "$verified_dir/index.html"
clean_git -C "$recipe_root" show "$recipe_commit:linux/keld/hello/keld-bench-url.patch" > "$verified_dir/keld-bench-url.patch"
cmp -s "$0" "$verified_dir/build.sh" || { echo "executed build.sh differs from committed bytes" >&2; exit 65; }
cmp -s "$payload_path" "$verified_dir/index.html" || { echo "payload differs from committed bytes" >&2; exit 65; }
cmp -s "$patch_path" "$verified_dir/keld-bench-url.patch" || { echo "adapter patch differs from committed bytes" >&2; exit 65; }

clean_git -c protocol.file.allow=never init "$worktree" >/dev/null
clean_git -C "$worktree" -c protocol.file.allow=never fetch --depth=1 https://github.com/gyldlab/keld.git "$source_sha"
clean_git -C "$worktree" -c core.hooksPath=/dev/null checkout --detach "$source_sha"

rustc_version=$(rustc -Vv | paste -sd ';' -)
cargo_version=$(cargo -V)
(
  cd "$worktree"
  CARGO_TARGET_DIR="$target_dir" cargo build --release --locked -p keld-host
)
cp "$target_dir/release/keld-host" "$product_artifact"
clean_git -C "$worktree" apply --check "$verified_dir/keld-bench-url.patch"
clean_git -C "$worktree" apply "$verified_dir/keld-bench-url.patch"
(
  cd "$worktree"
  CARGO_TARGET_DIR="$target_dir" cargo build --release --locked -p keld-host
)

bench_artifact="$target_dir/release/keld-host"
if [ ! -x "$product_artifact" ] || [ ! -x "$bench_artifact" ]; then
  echo "Release builds did not produce both Keld host artifacts" >&2
  exit 65
fi
product_sha=$(sha256sum "$product_artifact" | awk '{print $1}')
product_bytes=$(stat -Lc '%s' "$product_artifact")
bench_artifact_sha=$(sha256sum "$bench_artifact" | awk '{print $1}')
bench_artifact_bytes=$(stat -Lc '%s' "$bench_artifact")
build_sha=$(sha256sum "$verified_dir/build.sh" | awk '{print $1}')
patch_sha=$(sha256sum "$verified_dir/keld-bench-url.patch" | awk '{print $1}')
payload_sha=$(sha256sum "$verified_dir/index.html" | awk '{print $1}')
output_parent=$(dirname -- "$output_dir")
mkdir -p "$output_parent"
staged=$(mktemp -d "$output_parent/.keld-linux-artifact.XXXXXX")
cp "$product_artifact" "$staged/keld-host-product"
cp "$bench_artifact" "$staged/keld-host-bench"
chmod 755 "$staged/keld-host-product" "$staged/keld-host-bench"
SOURCE_SHA="$source_sha" RECIPE_SHA="$recipe_commit" PRODUCT_SHA="$product_sha" \
PRODUCT_BYTES="$product_bytes" BENCH_ARTIFACT_SHA="$bench_artifact_sha" \
BENCH_ARTIFACT_BYTES="$bench_artifact_bytes" BUILD_SHA="$build_sha" PATCH_SHA="$patch_sha" \
PAYLOAD_SHA="$payload_sha" RUSTC_VERSION="$rustc_version" CARGO_VERSION="$cargo_version" \
python3 - "$staged/provenance.json" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

document = {
    "schema_version": 1,
    "source_repository": "github.com/gyldlab/keld",
    "source_git_sha": os.environ["SOURCE_SHA"],
    "recipe_repository": "github.com/gyldlab/keld-benches",
    "recipe_commit": os.environ["RECIPE_SHA"],
    "recipe_files": {
        "linux/keld/hello/build.sh": os.environ["BUILD_SHA"],
        "linux/keld/hello/index.html": os.environ["PAYLOAD_SHA"],
        "linux/keld/hello/keld-bench-url.patch": os.environ["PATCH_SHA"],
    },
    "artifacts": {
        "product": {
            "basename": "keld-host-product",
            "sha256": os.environ["PRODUCT_SHA"],
            "bytes": int(os.environ["PRODUCT_BYTES"]),
        },
        "benchmark_adapter": {
            "basename": "keld-host-bench",
            "sha256": os.environ["BENCH_ARTIFACT_SHA"],
            "bytes": int(os.environ["BENCH_ARTIFACT_BYTES"]),
        },
    },
    "adapter": {
        "kind": "loopback-navigation-only",
        "environment": "KELD_BENCH_URL",
    },
    "toolchains": {
        "rustc": os.environ["RUSTC_VERSION"],
        "cargo": os.environ["CARGO_VERSION"],
    },
    "built_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
with open(sys.argv[1], "x", encoding="utf-8", newline="\n") as output:
    json.dump(document, output, indent=2, sort_keys=True)
    output.write("\n")
PY
if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
  rm -rf -- "$staged"
  echo "refusing to overwrite output created during build: $output_dir" >&2
  exit 73
fi
if ! mv -T -n "$staged" "$output_dir"; then
  echo "could not atomically install benchmark artifacts: $output_dir" >&2
  exit 74
fi
if [ -e "$staged" ] || [ -L "$staged" ]; then
  find "$staged" -type f -delete
  rmdir "$staged"
  echo "refusing to overwrite output created during build: $output_dir" >&2
  exit 73
fi

printf 'product_artifact=%s/keld-host-product\n' "$output_dir"
printf 'benchmark_artifact=%s/keld-host-bench\n' "$output_dir"
printf 'source_git_sha=%s\n' "$source_sha"
printf 'recipe_commit=%s\n' "$recipe_commit"
printf 'product_sha256=%s\n' "$product_sha"
printf 'product_bytes=%s\n' "$product_bytes"
printf 'benchmark_sha256=%s\n' "$bench_artifact_sha"
printf 'benchmark_bytes=%s\n' "$bench_artifact_bytes"
printf 'payload_sha256=%s\n' "$payload_sha"
