#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 /path/to/keld SOURCE_GIT_SHA '/absolute/output/Keld Hello.app'" >&2
  exit 64
fi

source_repo=$1
source_sha=$2
output_app=$3
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
recipe_patch_file="$script_dir/keld-bench-url.patch"
recipe_plist_template="$script_dir/Info.plist"

if [ "${0##*/}" != build.sh ]; then
  echo "benchmark recipe must execute the canonical build.sh path" >&2
  exit 65
fi
if ! invoked_script_identity=$(/usr/bin/stat -f '%d:%i' "$0") || \
   ! canonical_script_identity=$(/usr/bin/stat -f '%d:%i' "$script_dir/build.sh") || \
   [ "$invoked_script_identity" != "$canonical_script_identity" ]; then
  echo "benchmark recipe must execute the canonical build.sh file" >&2
  exit 65
fi

# Git provenance must not inherit repository selectors, object stores, config,
# credential helpers, or URL rewrites from the invoking shell. Repository-local
# config is still available to commands that explicitly use -C, so network
# queries run from /var/empty and name the canonical public HTTPS URL directly.
clean_git() {
  /usr/bin/env -i \
    HOME=/var/empty \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git "$@"
}

reject_local_git_includes() {
  checkout_path=$1
  checkout_name=$2
  if clean_git -C "$checkout_path" config --local --no-includes --get-regexp \
    '^[Ii][Nn][Cc][Ll][Uu][Dd][Ee]([Ii][Ff])?\.' >/dev/null 2>&1; then
    echo "$checkout_name local Git config must not include external config" >&2
    return 1
  fi
}

sha256_file() {
  if ! sha256_output=$(/usr/bin/shasum -a 256 "$1"); then
    echo "could not hash a benchmark recipe input" >&2
    return 1
  fi
  sha256_value=${sha256_output%% *}
  case "$sha256_value" in
    *[!0-9a-f]*|'')
      echo "benchmark recipe input hash was not lowercase hexadecimal" >&2
      return 1
      ;;
  esac
  if [ "${#sha256_value}" -ne 64 ]; then
    echo "benchmark recipe input hash was not SHA-256" >&2
    return 1
  fi
  printf '%s\n' "$sha256_value"
}

remote_has_exact_branch_head() {
  branch_head_sha=$1
  branch_heads=$2
  /usr/bin/awk -v sha="$branch_head_sha" '
    $1 == sha && $2 ~ /^refs\/heads\// { found = 1 }
    END { exit found ? 0 : 1 }
  ' <<EOF
$branch_heads
EOF
}

snapshot_head_blob() {
  recipe_relative_path=$1
  recipe_worktree_path=$2
  verified_path=$3

  if [ ! -f "$recipe_worktree_path" ] || [ -L "$recipe_worktree_path" ]; then
    echo "benchmark recipe input must be a regular non-symlink file: $recipe_relative_path" >&2
    return 1
  fi
  if ! recipe_blob=$(clean_git --git-dir="$recipe_object_repo" rev-parse --verify \
    "$recipe_commit:$recipe_relative_path"); then
    echo "benchmark recipe input is absent from the recipe commit: $recipe_relative_path" >&2
    return 1
  fi
  if ! recipe_blob_type=$(clean_git --git-dir="$recipe_object_repo" \
    cat-file -t "$recipe_blob"); then
    echo "could not inspect committed benchmark recipe input: $recipe_relative_path" >&2
    return 1
  fi
  if [ "$recipe_blob_type" != blob ]; then
    echo "committed benchmark recipe input is not a blob: $recipe_relative_path" >&2
    return 1
  fi
  if ! clean_git --git-dir="$recipe_object_repo" \
    cat-file blob "$recipe_blob" >"$verified_path"; then
    echo "could not read committed benchmark recipe input: $recipe_relative_path" >&2
    return 1
  fi
  if ! /usr/bin/cmp -s "$recipe_worktree_path" "$verified_path"; then
    echo "benchmark recipe input bytes differ from HEAD: $recipe_relative_path" >&2
    return 1
  fi
}

case "$source_sha" in
  *[!0-9a-f]*|'') echo "SOURCE_GIT_SHA must be a lowercase hexadecimal commit" >&2; exit 64 ;;
esac
case "$output_app" in
  /*.app) ;;
  *) echo "output must be an absolute .app path" >&2; exit 64 ;;
esac
if [ -e "$output_app" ] || [ -L "$output_app" ]; then
  echo "refusing to overwrite existing output: $output_app" >&2
  exit 73
fi

if clean_git -C /var/empty rev-parse --git-dir >/dev/null 2>&1; then
  echo "canonical Git network-query directory must not be a repository" >&2
  exit 65
fi

reject_local_git_includes "$source_repo" "Keld checkout"
if ! source_remote=$(clean_git -C "$source_repo" config --local --no-includes \
  --get-all remote.origin.url); then
  echo "could not read the Keld checkout's origin" >&2
  exit 65
fi
case "$source_remote" in
  https://github.com/gyldlab/keld|https://github.com/gyldlab/keld.git|git@github.com:gyldlab/keld|git@github.com:gyldlab/keld.git)
    source_repository=github.com/gyldlab/keld
    ;;
  *)
    echo "source origin must be the canonical gyldlab/keld repository" >&2
    exit 65
    ;;
esac
resolved_sha=$(clean_git -C "$source_repo" rev-parse --verify "$source_sha^{commit}")
if [ "$resolved_sha" != "$source_sha" ]; then
  echo "SOURCE_GIT_SHA must be the full immutable commit ($resolved_sha)" >&2
  exit 65
fi
if ! source_heads=$(cd /var/empty && clean_git -c protocol.file.allow=never \
  ls-remote --heads \
  https://github.com/gyldlab/keld.git); then
  echo "could not query canonical Keld origin branch heads" >&2
  exit 69
fi
if ! remote_has_exact_branch_head "$resolved_sha" "$source_heads"; then
  echo "SOURCE_GIT_SHA must equal a branch head currently advertised by canonical origin" >&2
  exit 65
fi

reject_local_git_includes "$script_dir" "adapter recipe checkout"
recipe_root=$(clean_git -C "$script_dir" rev-parse --show-toplevel)
recipe_prefix=$(clean_git -C "$script_dir" rev-parse --show-prefix)
if [ "$recipe_prefix" != macos/keld/hello/ ]; then
  echo "adapter recipe must run from its committed macos/keld/hello location" >&2
  exit 65
fi
if ! recipe_remote=$(clean_git -C "$recipe_root" config --local --no-includes \
  --get-all remote.origin.url); then
  echo "could not read the adapter recipe checkout's origin" >&2
  exit 65
fi
case "$recipe_remote" in
  https://github.com/gyldlab/keld-benches|https://github.com/gyldlab/keld-benches.git|git@github.com:gyldlab/keld-benches|git@github.com:gyldlab/keld-benches.git)
    recipe_repository=github.com/gyldlab/keld-benches
    ;;
  *)
    echo "adapter recipe origin must be the canonical gyldlab/keld-benches repository" >&2
    exit 65
    ;;
esac
recipe_commit=$(clean_git -C "$recipe_root" rev-parse --verify HEAD^{commit})
recipe_status=$(clean_git \
  -c core.fsmonitor=false \
  -c core.untrackedCache=false \
  -c core.fileMode=true \
  -C "$recipe_root" \
  status --porcelain=v1 --untracked-files=all)
if [ -n "$recipe_status" ]; then
  echo "adapter recipe checkout must be clean before building" >&2
  exit 65
fi
recipe_index_flags=$(clean_git -C "$recipe_root" ls-files -v)
if printf '%s\n' "$recipe_index_flags" | /usr/bin/grep -qv '^H '; then
  echo "adapter recipe checkout index must not carry non-default flags" >&2
  exit 65
fi
if ! recipe_heads=$(cd /var/empty && clean_git -c protocol.file.allow=never \
  ls-remote --heads \
  https://github.com/gyldlab/keld-benches.git); then
  echo "could not query canonical adapter-recipe origin branch heads" >&2
  exit 69
fi
if ! remote_has_exact_branch_head "$recipe_commit" "$recipe_heads"; then
  echo "adapter recipe commit must equal a branch head currently advertised by canonical origin" >&2
  exit 65
fi

build_home=${HOME:?HOME must be set for the pinned Rust toolchain}
build_path=${PATH:?PATH must be set for the pinned Rust toolchain}
build_tmpdir=${TMPDIR:-/tmp}
temporary_root=$(/usr/bin/mktemp -d "$build_tmpdir/keld-bench-build.XXXXXX")
worktree="$temporary_root/source"
target_dir="$temporary_root/target"
cargo_home_dir="$temporary_root/cargo-home"
staged_app="$temporary_root/Keld Hello.app"
verified_recipe_dir="$temporary_root/recipe-inputs"
recipe_object_repo="$temporary_root/recipe.git"
patch_file="$verified_recipe_dir/keld-bench-url.patch"
plist_template="$verified_recipe_dir/Info.plist"
clean_build_env() {
  /usr/bin/env -i \
    HOME="$build_home" \
    PATH="$build_path" \
    TMPDIR="$build_tmpdir" \
    LC_ALL=C \
    CARGO_HOME="$cargo_home_dir" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    "$@"
}
cleanup() {
  /bin/rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

/bin/mkdir -m 700 "$verified_recipe_dir"
clean_git -C /var/empty init --bare "$recipe_object_repo" >/dev/null
clean_git -C /var/empty --git-dir="$recipe_object_repo" \
  -c protocol.file.allow=never fetch --depth=1 \
  https://github.com/gyldlab/keld-benches.git "$recipe_commit"
snapshot_head_blob macos/keld/hello/build.sh \
  "$script_dir/build.sh" "$verified_recipe_dir/build.sh"
snapshot_head_blob macos/keld/hello/Info.plist \
  "$recipe_plist_template" "$plist_template"
snapshot_head_blob macos/keld/hello/keld-bench-url.patch \
  "$recipe_patch_file" "$patch_file"

# Fetching the exact live branch head into a fresh checkout keeps local source
# config, checkout filters, hooks, alternates, and object replacements outside
# the measured build. The fixture does not need post-checkout synchronization
# hooks, and disabling them does not bypass a commit or verification gate.
clean_git -C /var/empty init "$worktree" >/dev/null
clean_git -C /var/empty --git-dir="$worktree/.git" \
  -c protocol.file.allow=never fetch --depth=1 \
  https://github.com/gyldlab/keld.git "$resolved_sha"
clean_git -c core.hooksPath=/dev/null -C "$worktree" \
  checkout --detach "$resolved_sha"
clean_git -C "$worktree" apply --check "$patch_file"
clean_git -C "$worktree" apply "$patch_file"
if ! patch_sha=$(sha256_file "$patch_file") || \
   ! build_script_sha=$(sha256_file "$verified_recipe_dir/build.sh") || \
   ! info_plist_sha=$(sha256_file "$plist_template"); then
  exit 65
fi
if ! rustc_version_output=$(cd "$worktree" && clean_build_env rustc -Vv); then
  echo "could not capture rustc build provenance" >&2
  exit 69
fi
if ! rustc_version=$(printf '%s\n' "$rustc_version_output" | /usr/bin/paste -sd ';' -); then
  echo "could not normalize rustc build provenance" >&2
  exit 69
fi
if ! cargo_version=$(cd "$worktree" && clean_build_env cargo -V); then
  echo "could not capture Cargo build provenance" >&2
  exit 69
fi
if ! sdk_version=$(clean_build_env /usr/bin/xcrun --sdk macosx --show-sdk-version); then
  echo "could not capture macOS SDK build provenance" >&2
  exit 69
fi
if ! xcode_version_output=$(clean_build_env /usr/bin/xcodebuild -version); then
  echo "could not capture Xcode build provenance" >&2
  exit 69
fi
if ! xcode_version=$(printf '%s\n' "$xcode_version_output" | /usr/bin/paste -sd ';' -); then
  echo "could not normalize Xcode build provenance" >&2
  exit 69
fi
if [ -z "$rustc_version" ] || [ -z "$cargo_version" ] || \
   [ -z "$sdk_version" ] || [ -z "$xcode_version" ]; then
  echo "Rust, Cargo, SDK, and Xcode provenance commands must return nonempty values" >&2
  exit 65
fi

(
  cd "$worktree"
  clean_build_env CARGO_TARGET_DIR="$target_dir" \
    cargo build --release --locked -p keld-host
)

contents="$staged_app/Contents"
mkdir -p "$contents/MacOS"
cp "$target_dir/release/keld-host" "$contents/MacOS/keld-host"
cp "$plist_template" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchSourceCommit -string "$resolved_sha" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchSourceRepository -string "$source_repository" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchRecipeRepository -string "$recipe_repository" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchRecipeCommit -string "$recipe_commit" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchAdapterPatchSHA256 -string "$patch_sha" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchBuildScriptSHA256 -string "$build_script_sha" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchInfoPlistTemplateSHA256 -string "$info_plist_sha" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchRustcVersion -string "$rustc_version" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchCargoVersion -string "$cargo_version" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchMacOSSDKVersion -string "$sdk_version" "$contents/Info.plist"
/usr/bin/plutil -replace KeldBenchXcodeVersion -string "$xcode_version" "$contents/Info.plist"
if /usr/bin/grep -q '__KELD_' "$contents/Info.plist"; then
  echo "benchmark Info.plist still contains an unresolved provenance placeholder" >&2
  exit 65
fi
/usr/bin/plutil -lint "$contents/Info.plist"
/usr/bin/codesign --force --sign - "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"
if ! executable_sha=$(sha256_file "$contents/MacOS/keld-host"); then
  exit 65
fi
mkdir -p "$(dirname -- "$output_app")"
if [ -e "$output_app" ] || [ -L "$output_app" ]; then
  echo "refusing to overwrite output created during the build: $output_app" >&2
  exit 73
fi
if ! clean_build_env /usr/bin/xcrun swift -e '
import Darwin
let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(64) }
guard renameatx_np(
    AT_FDCWD,
    arguments[1],
    AT_FDCWD,
    arguments[2],
    UInt32(RENAME_EXCL)
) == 0 else {
    perror("renameatx_np")
    exit(73)
}
' "$staged_app" "$output_app"; then
  echo "could not atomically install the app without overwriting; set TMPDIR on the output filesystem if rename reported a cross-device error" >&2
  exit 73
fi

echo "app=$output_app"
echo "source_git_sha=$resolved_sha"
echo "source_repository=$source_repository"
echo "recipe_repository=$recipe_repository"
echo "recipe_commit=$recipe_commit"
echo "adapter_patch_sha256=$patch_sha"
echo "build_script_sha256=$build_script_sha"
echo "info_plist_template_sha256=$info_plist_sha"
echo "rustc_version=$rustc_version"
echo "cargo_version=$cargo_version"
echo "macos_sdk_version=$sdk_version"
echo "xcode_version=$xcode_version"
echo "executable_sha256=$executable_sha"
