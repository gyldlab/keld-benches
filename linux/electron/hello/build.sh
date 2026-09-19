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
if [ "$recipe_prefix" != "linux/electron/hello/" ]; then
  echo "recipe must run from linux/electron/hello" >&2
  exit 65
fi
recipe_remote=$(clean_git -C "$recipe_root" config --local --no-includes --get remote.origin.url || true)
case "$recipe_remote" in
  https://github.com/gyldlab/keld-benches|https://github.com/gyldlab/keld-benches.git|git@github.com:gyldlab/keld-benches|git@github.com:gyldlab/keld-benches.git) ;;
  *) echo "recipe origin must be the canonical gyldlab/keld-benches repository" >&2; exit 65 ;;
esac

inputs="
linux/electron/hello/build.sh
linux/electron/hello/package.json
linux/electron/hello/package-lock.json
linux/electron/hello/src/main.js
linux/electron/hello/src/index.html
"
for relative in $inputs; do
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

for tool in node npm python3 sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing Electron build tool: $tool" >&2
    exit 69
  }
done

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/keld-electron-linux-build.XXXXXX")
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
  destination="$verified/${relative#linux/electron/hello/}"
  mkdir -p "$(dirname -- "$destination")"
  clean_git -C "$recipe_root" show "$recipe_commit:$relative" > "$destination"
done
for relative in $inputs; do
  local_path="$script_dir/${relative#linux/electron/hello/}"
  verified_path="$verified/${relative#linux/electron/hello/}"
  cmp -s "$local_path" "$verified_path" || {
    echo "working input differs from committed bytes: $relative" >&2
    exit 65
  }
done

(
  cd "$verified"
  npm ci --ignore-scripts --no-audit --no-fund
  node node_modules/electron/install.js
)

electron_version=$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$verified/node_modules/electron/package.json")
[ "$electron_version" = "43.4.0" ] || {
  echo "unexpected Electron version: $electron_version" >&2
  exit 65
}

dist="$verified/node_modules/electron/dist"
[ -x "$dist/electron" ] || {
  echo "official Electron install did not produce dist/electron" >&2
  exit 65
}

output_parent=$(dirname -- "$output_dir")
mkdir -p "$output_parent"
staged=$(mktemp -d "$output_parent/.electron-linux-artifact.XXXXXX")
runtime="$staged/electron-linux-hello"
cp -a "$dist" "$runtime"
rm -f "$runtime/resources/default_app.asar"
rm -rf "$runtime/resources/app"
mkdir -p "$runtime/resources/app/src"
cp "$verified/package.json" "$runtime/resources/app/package.json"
cp "$verified/src/main.js" "$verified/src/index.html" "$runtime/resources/app/src/"

artifact="$runtime/electron"
[ -x "$artifact" ] || {
  echo "packaged Electron runtime is missing its executable" >&2
  exit 65
}
artifact_sha=$(sha256sum "$artifact" | awk '{print $1}')
artifact_bytes=$(stat -Lc '%s' "$artifact")
node_version=$(node --version)
npm_version=$(npm --version)
runtime_versions=$(ELECTRON_RUN_AS_NODE=1 "$artifact" -e 'process.stdout.write(JSON.stringify(process.versions))')

TREE_ROOT="$runtime" python3 - "$staged/tree.json" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

root = pathlib.Path(os.environ["TREE_ROOT"])
records = []
total_bytes = 0
for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
    relative = path.relative_to(root).as_posix()
    if path.is_symlink():
        target = os.readlink(path)
        records.append(("L", relative, target, 0))
    elif path.is_file():
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        records.append(("F", relative, digest, len(data)))
        total_bytes += len(data)
    elif path.is_dir():
        continue
    else:
        raise SystemExit(f"unsupported artifact entry: {relative}")

hasher = hashlib.sha256()
for kind, relative, value, size in records:
    hasher.update(kind.encode())
    hasher.update(b"\0")
    hasher.update(relative.encode())
    hasher.update(b"\0")
    hasher.update(value.encode())
    hasher.update(b"\0")
    hasher.update(str(size).encode())
    hasher.update(b"\n")

json.dump(
    {
        "sha256": hasher.hexdigest(),
        "entries": len(records),
        "bytes": total_bytes,
    },
    open(sys.argv[1], "w", encoding="utf-8"),
    separators=(",", ":"),
    sort_keys=True,
)
PY

RECIPE_SHA="$recipe_commit" \
ARTIFACT_SHA="$artifact_sha" \
ARTIFACT_BYTES="$artifact_bytes" \
ELECTRON_VERSION="$electron_version" \
NODE_VERSION="$node_version" \
NPM_VERSION="$npm_version" \
RUNTIME_VERSIONS="$runtime_versions" \
python3 - "$recipe_root" "$staged/provenance.json" "$staged/tree.json" $inputs <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
tree_path = pathlib.Path(sys.argv[3])
files = sys.argv[4:]

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

tree = json.loads(tree_path.read_text(encoding="utf-8"))
runtime_versions = json.loads(os.environ["RUNTIME_VERSIONS"])
document = {
    "schema_version": 1,
    "fixture_repository": "github.com/gyldlab/keld-benches",
    "fixture_commit": os.environ["RECIPE_SHA"],
    "fixture_files": digests,
    "artifact": {
        "basename": "electron",
        "sha256": os.environ["ARTIFACT_SHA"],
        "bytes": int(os.environ["ARTIFACT_BYTES"]),
        "tree_sha256": tree["sha256"],
        "tree_entries": tree["entries"],
        "tree_bytes": tree["bytes"],
    },
    "framework": {"name": "Electron", "version": os.environ["ELECTRON_VERSION"]},
    "runtime_versions": runtime_versions,
    "toolchains": {
        "node": os.environ["NODE_VERSION"],
        "npm": os.environ["NPM_VERSION"],
    },
}
with out.open("x", encoding="utf-8", newline="\n") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
rm "$staged/tree.json"

if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
  echo "refusing to overwrite output created during build: $output_dir" >&2
  exit 73
fi
if ! mv -T -n "$staged" "$output_dir"; then
  echo "could not atomically install Electron fixture artifact: $output_dir" >&2
  exit 74
fi
staged=

printf 'artifact=%s/electron-linux-hello/electron\n' "$output_dir"
printf 'fixture_commit=%s\n' "$recipe_commit"
printf 'artifact_sha256=%s\n' "$artifact_sha"
printf 'artifact_bytes=%s\n' "$artifact_bytes"
printf 'electron_version=%s\n' "$electron_version"
