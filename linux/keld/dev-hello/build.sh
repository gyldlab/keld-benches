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
project_dir="$script_dir/project"

clean_git() {
  /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git "$@"
}

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

recipe_root=$(clean_git -C "$script_dir" rev-parse --show-toplevel)
recipe_prefix=$(clean_git -C "$script_dir" rev-parse --show-prefix)
if [ "$recipe_prefix" != "linux/keld/dev-hello/" ]; then
  echo "recipe must run from linux/keld/dev-hello" >&2
  exit 65
fi

source_remote=$(clean_git -C "$source_repo" config --local --no-includes --get remote.origin.url || true)
case "$source_remote" in
  https://github.com/gyldlab/keld|https://github.com/gyldlab/keld.git|git@github.com:gyldlab/keld|git@github.com:gyldlab/keld.git) ;;
  *) echo "source origin must be canonical gyldlab/keld" >&2; exit 65 ;;
esac
recipe_remote=$(clean_git -C "$recipe_root" config --local --no-includes --get remote.origin.url || true)
case "$recipe_remote" in
  https://github.com/gyldlab/keld-benches|https://github.com/gyldlab/keld-benches.git|git@github.com:gyldlab/keld-benches|git@github.com:gyldlab/keld-benches.git) ;;
  *) echo "recipe origin must be canonical gyldlab/keld-benches" >&2; exit 65 ;;
esac

recipe_commit=$(clean_git -C "$recipe_root" rev-parse --verify HEAD^{commit})
recipe_files="
linux/keld/dev-hello/build.sh
linux/keld/dev-hello/paint-beacon.js
linux/keld/dev-hello/project/.gitignore
linux/keld/dev-hello/project/index.html
linux/keld/dev-hello/project/keld.config.ts
linux/keld/dev-hello/project/package.json
linux/keld/dev-hello/project/src/kipc-transport.ts
linux/keld/dev-hello/project/src/kipc.ts
linux/keld/dev-hello/project/src/main.ts
"
for relative in $recipe_files; do
  if ! clean_git -C "$recipe_root" diff --quiet HEAD -- "$relative" || \
     ! clean_git -C "$recipe_root" diff --cached --quiet HEAD -- "$relative"; then
    echo "recipe input differs from commit: $relative" >&2
    exit 65
  fi
  clean_git -C "$recipe_root" cat-file -e "$recipe_commit:$relative" || {
    echo "recipe input is absent from commit: $relative" >&2
    exit 65
  }
done

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/keld-linux-dev-build.XXXXXX")
worktree="$temporary_root/source"
target_dir="$temporary_root/target"
generated_parent="$temporary_root/generated"
staged=
cleanup() {
  if [ -n "$staged" ] && { [ -e "$staged" ] || [ -L "$staged" ]; }; then
    rm -rf -- "$staged"
  fi
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

clean_git -c protocol.file.allow=never init "$worktree" >/dev/null
if ! clean_git -C "$worktree" -c protocol.file.allow=never fetch --depth=1 \
  https://github.com/gyldlab/keld.git "$source_sha"; then
  echo "SOURCE_GIT_SHA is unavailable from canonical Keld origin" >&2
  exit 69
fi
fetched_sha=$(clean_git -C "$worktree" rev-parse --verify FETCH_HEAD^{commit})
if [ "$fetched_sha" != "$source_sha" ]; then
  echo "canonical Keld origin did not return requested SOURCE_GIT_SHA" >&2
  exit 65
fi
clean_git -C "$worktree" -c core.hooksPath=/dev/null checkout --detach "$fetched_sha"

rustc_version=$(rustc -Vv | paste -sd ';' -)
cargo_version=$(cargo -V)
(
  cd "$worktree"
  CARGO_TARGET_DIR="$target_dir" cargo build --release --locked -p keld-cli -p keld-host
)

cli="$target_dir/release/keld"
host="$target_dir/release/keld-host"
launcher="$target_dir/release/keld-role-launcher"
for artifact in "$cli" "$host" "$launcher"; do
  if [ ! -x "$artifact" ]; then
    echo "Release build did not produce $(basename "$artifact")" >&2
    exit 65
  fi
done

mkdir -p "$generated_parent"
(
  cd "$generated_parent"
  "$cli" create product-bench >/dev/null
)
generated="$generated_parent/product-bench"
expected_files=".gitignore index.html keld.config.ts package.json src/kipc-transport.ts src/kipc.ts src/main.ts"
for relative in $expected_files; do
  if ! cmp -s "$project_dir/$relative" "$generated/$relative"; then
    echo "committed dev fixture differs from keld create output: $relative" >&2
    exit 65
  fi
done
actual_count=$(find "$generated" -type f | wc -l)
if [ "$actual_count" -ne 7 ]; then
  echo "keld create emitted unexpected file count: $actual_count" >&2
  exit 65
fi

cli_sha=$(sha256sum "$cli" | awk '{print $1}')
host_sha=$(sha256sum "$host" | awk '{print $1}')
launcher_sha=$(sha256sum "$launcher" | awk '{print $1}')
cli_bytes=$(stat -Lc '%s' "$cli")
host_bytes=$(stat -Lc '%s' "$host")
launcher_bytes=$(stat -Lc '%s' "$launcher")

output_parent=$(dirname -- "$output_dir")
mkdir -p "$output_parent"
staged=$(mktemp -d "$output_parent/.keld-linux-dev-artifact.XXXXXX")
install -m 755 "$cli" "$staged/keld"
install -m 755 "$host" "$staged/keld-host"
install -m 755 "$launcher" "$staged/keld-role-launcher"

SOURCE_SHA="$source_sha" RECIPE_SHA="$recipe_commit" \
CLI_SHA="$cli_sha" CLI_BYTES="$cli_bytes" \
HOST_SHA="$host_sha" HOST_BYTES="$host_bytes" \
LAUNCHER_SHA="$launcher_sha" LAUNCHER_BYTES="$launcher_bytes" \
RUSTC_VERSION="$rustc_version" CARGO_VERSION="$cargo_version" \
RECIPE_ROOT="$recipe_root" \
python3 - "$staged/provenance.json" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
from datetime import datetime, timezone

root = pathlib.Path(os.environ["RECIPE_ROOT"])
files = [
    "linux/keld/dev-hello/build.sh",
    "linux/keld/dev-hello/paint-beacon.js",
    "linux/keld/dev-hello/project/.gitignore",
    "linux/keld/dev-hello/project/index.html",
    "linux/keld/dev-hello/project/keld.config.ts",
    "linux/keld/dev-hello/project/package.json",
    "linux/keld/dev-hello/project/src/kipc-transport.ts",
    "linux/keld/dev-hello/project/src/kipc.ts",
    "linux/keld/dev-hello/project/src/main.ts",
]
digests = {path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in files}
document = {
    "schema_version": 1,
    "source_repository": "github.com/gyldlab/keld",
    "source_git_sha": os.environ["SOURCE_SHA"],
    "recipe_repository": "github.com/gyldlab/keld-benches",
    "recipe_commit": os.environ["RECIPE_SHA"],
    "recipe_files": digests,
    "project_name": "product-bench",
    "artifacts": {
        "cli": {
            "basename": "keld",
            "sha256": os.environ["CLI_SHA"],
            "bytes": int(os.environ["CLI_BYTES"]),
        },
        "host": {
            "basename": "keld-host",
            "sha256": os.environ["HOST_SHA"],
            "bytes": int(os.environ["HOST_BYTES"]),
        },
        "role_launcher": {
            "basename": "keld-role-launcher",
            "sha256": os.environ["LAUNCHER_SHA"],
            "bytes": int(os.environ["LAUNCHER_BYTES"]),
        },
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
  echo "refusing to overwrite output created during build: $output_dir" >&2
  exit 73
fi
mv -T -n "$staged" "$output_dir"
staged=

printf 'cli=%s/keld\n' "$output_dir"
printf 'host=%s/keld-host\n' "$output_dir"
printf 'role_launcher=%s/keld-role-launcher\n' "$output_dir"
printf 'source_git_sha=%s\n' "$source_sha"
printf 'recipe_commit=%s\n' "$recipe_commit"
printf 'cli_sha256=%s\n' "$cli_sha"
printf 'host_sha256=%s\n' "$host_sha"
printf 'role_launcher_sha256=%s\n' "$launcher_sha"
