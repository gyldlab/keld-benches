#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then
  echo "usage: $0" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
script_path="$script_dir/build.sh"
recipe_path=macos/tauri/hello/build.sh
recipe_identifier=macos/tauri/hello/build.sh
repository_identifier=github.com/gyldlab/keld-benches
canonical_remote=https://github.com/gyldlab/keld-benches.git

if [ "${0##*/}" != build.sh ]; then
  echo "benchmark recipe must execute the canonical build.sh path" >&2
  exit 65
fi
if ! invoked_script_identity=$(/usr/bin/stat -f '%d:%i' "$0") || \
   ! canonical_script_identity=$(/usr/bin/stat -f '%d:%i' "$script_path") || \
   [ "$invoked_script_identity" != "$canonical_script_identity" ]; then
  echo "benchmark recipe must execute the canonical build.sh file" >&2
  exit 65
fi

clean_git() {
  /usr/bin/env -i \
    HOME=/var/empty \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git "$@"
}

sha256_file() {
  if ! sha256_output=$(/usr/bin/shasum -a 256 "$1"); then
    echo "could not hash benchmark build input" >&2
    return 1
  fi
  sha256_value=${sha256_output%% *}
  case "$sha256_value" in
    *[!0-9a-f]*|'')
      echo "benchmark build-input hash was not lowercase hexadecimal" >&2
      return 1
      ;;
  esac
  if [ "${#sha256_value}" -ne 64 ]; then
    echo "benchmark build-input hash was not SHA-256" >&2
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

ensure_real_directory() {
  directory=$1
  if [ -L "$directory" ]; then
    echo "benchmark output directory must not be a symlink: $directory" >&2
    return 1
  fi
  if [ -e "$directory" ]; then
    if [ ! -d "$directory" ]; then
      echo "benchmark output ancestor must be a directory: $directory" >&2
      return 1
    fi
  else
    /bin/mkdir "$directory"
  fi
}

# BEGIN TAURI BUILD ISOLATION CONTRACT
canonical_directory() {
  directory=$1
  if [ ! -d "$directory" ]; then
    echo "benchmark isolation path must be a directory: $directory" >&2
    return 1
  fi
  (CDPATH= cd -- "$directory" && pwd -P)
}

directory_is_within() {
  child=$1
  parent=$2
  case "$child" in
    "$parent"|"$parent"/*) return 0 ;;
    *) return 1 ;;
  esac
}

select_external_tmpdir() {
  repository=$1
  requested_tmpdir=${2:-/tmp}
  case "$requested_tmpdir" in
    /*) ;;
    *)
      echo "TMPDIR must be an absolute directory when set" >&2
      return 1
      ;;
  esac
  if ! requested_physical=$(canonical_directory "$requested_tmpdir"); then
    return 1
  fi
  if directory_is_within "$requested_physical" "$repository"; then
    requested_physical=$(canonical_directory /tmp) || return 1
  fi
  if directory_is_within "$requested_physical" "$repository"; then
    echo "no external temporary directory is available for the Tauri build" >&2
    return 1
  fi
  printf '%s\n' "$requested_physical"
}

create_external_staging_root() {
  repository=$1
  temporary_parent=$2
  output_parent=$3
  created_staging_root=
  created_staging_identity=
  if ! staging_root=$(/usr/bin/mktemp -d "$temporary_parent/tauri-bench-build.XXXXXX"); then
    echo "could not create the isolated Tauri build root" >&2
    return 1
  fi
  if ! staging_identity=$(staging_root_identity "$staging_root"); then
    echo "leaving unverified Tauri staging path in place: $staging_root" >&2
    return 1
  fi
  if ! /bin/chmod 700 "$staging_root" || \
     ! staging_physical=$(canonical_directory "$staging_root"); then
    remove_owned_staging_root "$staging_root" "$temporary_parent" \
      "$staging_identity" || :
    return 1
  fi
  if directory_is_within "$staging_physical" "$repository"; then
    echo "Tauri source and build staging must be outside the repository" >&2
    remove_owned_staging_root "$staging_root" "$temporary_parent" \
      "$staging_identity" || :
    return 1
  fi
  if [ "$(/usr/bin/stat -f '%d' "$staging_physical")" != \
       "$(/usr/bin/stat -f '%d' "$output_parent")" ]; then
    echo "isolated Tauri staging and the final app must share a filesystem for atomic install" >&2
    remove_owned_staging_root "$staging_root" "$temporary_parent" \
      "$staging_identity" || :
    return 1
  fi
  if [ "$(staging_root_identity "$staging_root")" != "$staging_identity" ]; then
    echo "Tauri staging root changed while it was being validated" >&2
    return 1
  fi
  created_staging_root=$staging_root
  created_staging_identity=$staging_identity
}

staging_root_identity() {
  staging_path=$1
  if [ -L "$staging_path" ]; then
    echo "Tauri staging root must not be a symlink" >&2
    return 1
  fi
  if ! /usr/bin/stat -f '%HT:%d:%i' "$staging_path"; then
    echo "could not record Tauri staging-root identity" >&2
    return 1
  fi
}

remove_owned_staging_root() {
  staging_path=$1
  expected_parent=$2
  expected_identity=$3
  staging_parent=$(/usr/bin/dirname "$staging_path")
  staging_name=${staging_path##*/}
  if [ "$staging_parent" != "$expected_parent" ]; then
    echo "refusing to clean Tauri staging outside its original parent: $staging_path" >&2
    return 1
  fi
  case "$staging_name" in
    tauri-bench-build.??????) ;;
    *)
      echo "refusing to clean unexpected Tauri staging pathname: $staging_path" >&2
      return 1
      ;;
  esac
  if [ -L "$staging_path" ]; then
    echo "refusing to follow replaced Tauri staging symlink: $staging_path" >&2
    return 1
  fi
  if [ ! -e "$staging_path" ]; then
    return 0
  fi
  if ! current_identity=$(/usr/bin/stat -f '%HT:%d:%i' "$staging_path"); then
    echo "refusing to clean unreadable Tauri staging path: $staging_path" >&2
    return 1
  fi
  if [ "$current_identity" != "$expected_identity" ]; then
    echo "refusing to clean replaced Tauri staging inode: $staging_path" >&2
    return 1
  fi
  case "$current_identity" in
    Directory:*) ;;
    *)
      echo "refusing to clean non-directory Tauri staging path: $staging_path" >&2
      return 1
      ;;
  esac
  /bin/rm -rf -- "$staging_path"
}

verify_isolated_directory() {
  repository=$1
  staging_root=$2
  directory=$3
  label=$4
  if [ -L "$directory" ] || ! directory_physical=$(canonical_directory "$directory"); then
    echo "$label must be a real directory" >&2
    return 1
  fi
  if ! directory_is_within "$directory_physical" "$staging_root" || \
     directory_is_within "$directory_physical" "$repository"; then
    echo "$label escaped the external Tauri staging root" >&2
    return 1
  fi
}

reject_ambient_dependency_ancestors() {
  source_directory=$1
  staging_root=$2
  source_physical=$(canonical_directory "$source_directory") || return 1
  staging_physical=$(canonical_directory "$staging_root") || return 1
  if ! directory_is_within "$source_physical" "$staging_physical"; then
    echo "isolated Tauri source is not inside the staging root" >&2
    return 1
  fi

  ancestor=$source_physical
  while :; do
    for ambient_path in \
      "$ancestor/node_modules" \
      "$ancestor/.cargo/config.toml" \
      "$ancestor/.cargo/config"; do
      if [ -e "$ambient_path" ] || [ -L "$ambient_path" ]; then
        echo "ambient dependency or Cargo configuration would affect the Tauri build: $ambient_path" >&2
        return 1
      fi
    done
    if [ "$ancestor" != "$source_physical" ] && \
       { [ -e "$ancestor/package.json" ] || [ -L "$ancestor/package.json" ]; }; then
      echo "ambient Bun workspace manifest would affect the Tauri build: $ancestor/package.json" >&2
      return 1
    fi
    if [ "$ancestor" = / ]; then
      break
    fi
    ancestor=$(/usr/bin/dirname "$ancestor")
  done
}
# END TAURI BUILD ISOLATION CONTRACT

if clean_git -C /var/empty rev-parse --git-dir >/dev/null 2>&1; then
  echo "canonical Git network-query directory must not be a repository" >&2
  exit 65
fi
if clean_git -C "$script_dir" config --local --no-includes --get-regexp \
  '^[Ii][Nn][Cc][Ll][Uu][Dd][Ee]([Ii][Ff])?\.' >/dev/null 2>&1; then
  echo "benchmark checkout local Git config must not include external config" >&2
  exit 65
fi
repository_root=$(clean_git -C "$script_dir" rev-parse --show-toplevel)
repository_prefix=$(clean_git -C "$script_dir" rev-parse --show-prefix)
repository_physical=$(canonical_directory "$repository_root")
if [ "$repository_prefix" != macos/tauri/hello/ ]; then
  echo "benchmark recipe must run from its committed macos/tauri/hello location" >&2
  exit 65
fi
if ! origin_urls=$(clean_git -C "$repository_root" config --local --no-includes \
  --get-all remote.origin.url); then
  echo "could not read benchmark checkout origin" >&2
  exit 65
fi
case "$origin_urls" in
  https://github.com/gyldlab/keld-benches|https://github.com/gyldlab/keld-benches.git|git@github.com:gyldlab/keld-benches|git@github.com:gyldlab/keld-benches.git)
    ;;
  *)
    echo "benchmark checkout origin must be the canonical gyldlab/keld-benches repository" >&2
    exit 65
    ;;
esac

source_commit=$(clean_git -C "$repository_root" rev-parse --verify HEAD^{commit})
source_status=$(clean_git \
  -c core.fsmonitor=false \
  -c core.untrackedCache=false \
  -c core.fileMode=true \
  -C "$repository_root" \
  status --porcelain=v1 --untracked-files=all)
if [ -n "$source_status" ]; then
  echo "benchmark checkout must be clean before building" >&2
  exit 65
fi
source_index_flags=$(clean_git -C "$repository_root" ls-files -v)
if printf '%s\n' "$source_index_flags" | /usr/bin/grep -qv '^H '; then
  echo "benchmark checkout index must not carry non-default flags" >&2
  exit 65
fi
if ! remote_heads=$(cd /var/empty && clean_git -c protocol.file.allow=never \
  ls-remote --heads "$canonical_remote"); then
  echo "could not query canonical benchmark origin branch heads" >&2
  exit 69
fi
if ! remote_has_exact_branch_head "$source_commit" "$remote_heads"; then
  echo "benchmark commit must equal a branch head currently advertised by canonical origin" >&2
  exit 65
fi

build_home=${HOME:?HOME must be set for Bun and the Rust toolchain}
build_rustup_home=${RUSTUP_HOME:-$build_home/.rustup}
if ! bun_bin=$(command -v bun) || [ ! -x "$bun_bin" ]; then
  echo "bun must be installed and executable" >&2
  exit 69
fi
if ! cargo_bin=$(command -v cargo) || [ ! -x "$cargo_bin" ]; then
  echo "cargo must be installed and executable" >&2
  exit 69
fi
if ! rustc_bin=$(command -v rustc) || [ ! -x "$rustc_bin" ]; then
  echo "rustc must be installed and executable" >&2
  exit 69
fi
bun_dir=$(CDPATH= cd -- "$(dirname -- "$bun_bin")" && pwd)
cargo_dir=$(CDPATH= cd -- "$(dirname -- "$cargo_bin")" && pwd)
rustc_dir=$(CDPATH= cd -- "$(dirname -- "$rustc_bin")" && pwd)
build_path="$bun_dir:$cargo_dir:$rustc_dir:/usr/bin:/bin:/usr/sbin:/sbin"

source_target_root="$script_dir/src-tauri/target"
ensure_real_directory "$source_target_root"
ensure_real_directory "$source_target_root/release"
ensure_real_directory "$source_target_root/release/bundle"
ensure_real_directory "$source_target_root/release/bundle/macos"
output_parent="$source_target_root/release/bundle/macos"
output_app="$output_parent/Tauri Hello.app"
if [ -e "$output_app" ] || [ -L "$output_app" ]; then
  echo "refusing to overwrite existing benchmark app: $output_app" >&2
  echo "remove that ignored build product explicitly, then rerun this recipe" >&2
  exit 73
fi

if ! sanitized_tmpdir=$(select_external_tmpdir "$repository_physical" "${TMPDIR:-/tmp}"); then
  exit 65
fi
if ! create_external_staging_root \
  "$repository_physical" "$sanitized_tmpdir" "$output_parent"; then
  exit 65
fi
temporary_root=$created_staging_root
temporary_root_identity=$created_staging_identity
cleanup() {
  if [ -n "${temporary_root:-}" ]; then
    remove_owned_staging_root "$temporary_root" "$sanitized_tmpdir" \
      "$temporary_root_identity" || :
  fi
}
trap cleanup EXIT HUP INT TERM
if [ ! -f "$script_path" ] || [ -L "$script_path" ]; then
  echo "canonical benchmark build script must be a regular non-symlink file" >&2
  exit 65
fi
verified_script="$temporary_root/verified-build.sh"
if ! clean_git -C "$repository_root" cat-file blob \
  "$source_commit:$recipe_path" >"$verified_script"; then
  echo "could not read the committed benchmark build script" >&2
  exit 65
fi
if ! /usr/bin/cmp -s "$script_path" "$verified_script"; then
  echo "benchmark build script bytes differ from the committed recipe" >&2
  exit 65
fi
if ! build_script_sha=$(sha256_file "$verified_script"); then
  exit 65
fi

build_target="$temporary_root/target"
cargo_home_dir="$temporary_root/cargo-home"
isolated_home_dir="$temporary_root/home"
isolated_tmpdir="$temporary_root/tmp"
bun_cache_dir="$temporary_root/bun-cache"
bun_install_dir="$temporary_root/bun-install"
source_archive="$temporary_root/source.tar"
isolated_source_root="$temporary_root/source"
isolated_source_dir="$isolated_source_root/macos/tauri/hello"
staged_app="$build_target/release/bundle/macos/Tauri Hello.app"
/bin/mkdir -m 700 "$cargo_home_dir" "$isolated_home_dir" "$isolated_tmpdir" \
  "$bun_cache_dir" "$bun_install_dir" "$isolated_source_root" "$build_target"

# Build only the committed fixture bytes in a fresh source tree. A frozen Bun
# install validates dependency resolution, but it does not replace a preexisting
# node_modules tree; building in the checkout would therefore let ignored or
# tampered package bytes select the Tauri CLI that creates the measured app.
if ! clean_git -C "$repository_root" archive --format=tar \
  --output="$source_archive" "$source_commit" -- macos/tauri/hello; then
  echo "could not snapshot the committed Tauri benchmark source" >&2
  exit 65
fi
if ! /usr/bin/tar -xf "$source_archive" -C "$isolated_source_root"; then
  echo "could not extract the committed Tauri benchmark source" >&2
  exit 65
fi
if [ ! -d "$isolated_source_dir" ] || [ -L "$isolated_source_dir" ] || \
   [ -e "$isolated_source_dir/node_modules" ] || [ -L "$isolated_source_dir/node_modules" ]; then
  echo "committed Tauri benchmark source was not an empty dependency workspace" >&2
  exit 65
fi
for isolated_directory in \
  "$isolated_source_root" \
  "$isolated_source_dir" \
  "$build_target" \
  "$cargo_home_dir" \
  "$isolated_home_dir" \
  "$isolated_tmpdir" \
  "$bun_cache_dir" \
  "$bun_install_dir"; do
  if ! verify_isolated_directory "$repository_physical" "$temporary_root" \
    "$isolated_directory" "Tauri build directory"; then
    exit 65
  fi
done
if ! reject_ambient_dependency_ancestors "$isolated_source_dir" "$temporary_root"; then
  exit 65
fi

clean_build_env() {
  /usr/bin/env -i \
    HOME="$isolated_home_dir" \
    PATH="$build_path" \
    TMPDIR="$isolated_tmpdir" \
    LC_ALL=C \
    LANG=C \
    BUN_INSTALL="$bun_install_dir" \
    BUN_INSTALL_CACHE_DIR="$bun_cache_dir" \
    CARGO_HOME="$cargo_home_dir" \
    CARGO_TARGET_DIR="$build_target" \
    RUSTUP_HOME="$build_rustup_home" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    "$@"
}

(
  cd "$isolated_source_dir"
  clean_build_env "$bun_bin" install --frozen-lockfile
)
tauri_cli_entrypoint="$isolated_source_dir/node_modules/@tauri-apps/cli/tauri.js"
if [ ! -f "$tauri_cli_entrypoint" ] || [ -L "$tauri_cli_entrypoint" ]; then
  echo "frozen install did not create the expected local Tauri CLI entrypoint" >&2
  exit 65
fi

if ! bun_version=$(cd "$isolated_source_dir" && clean_build_env "$bun_bin" --version); then
  echo "could not capture Bun build provenance" >&2
  exit 69
fi
if ! tauri_cli_version=$(cd "$isolated_source_dir" && clean_build_env \
  "$bun_bin" "$tauri_cli_entrypoint" --version); then
  echo "could not capture Tauri CLI build provenance" >&2
  exit 69
fi
if ! rustc_version_output=$(cd "$isolated_source_dir" && clean_build_env "$rustc_bin" -Vv); then
  echo "could not capture rustc build provenance" >&2
  exit 69
fi
rustc_version=$(printf '%s\n' "$rustc_version_output" | /usr/bin/paste -sd ';' -)
if ! cargo_version=$(cd "$isolated_source_dir" && clean_build_env "$cargo_bin" -V); then
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
xcode_version=$(printf '%s\n' "$xcode_version_output" | /usr/bin/paste -sd ';' -)
if [ -z "$bun_version" ] || [ -z "$tauri_cli_version" ] || \
   [ -z "$rustc_version" ] || [ -z "$cargo_version" ] || \
   [ -z "$sdk_version" ] || [ -z "$xcode_version" ]; then
  echo "all benchmark build-tool provenance values must be nonempty" >&2
  exit 65
fi

(
  cd "$isolated_source_dir"
  clean_build_env "$bun_bin" "$tauri_cli_entrypoint" build --bundles app
)

if [ ! -d "$staged_app" ] || [ -L "$staged_app" ]; then
  echo "Tauri did not produce the expected benchmark app bundle" >&2
  exit 65
fi
info_plist="$staged_app/Contents/Info.plist"
if [ ! -f "$info_plist" ] || [ -L "$info_plist" ]; then
  echo "Tauri benchmark app has no regular Info.plist" >&2
  exit 65
fi
/usr/bin/plutil -replace KeldBenchFixtureKind -string tauri "$info_plist"
/usr/bin/plutil -replace KeldBenchSourceRepository -string "$repository_identifier" "$info_plist"
/usr/bin/plutil -replace KeldBenchSourceCommit -string "$source_commit" "$info_plist"
/usr/bin/plutil -replace KeldBenchSourceRelativePath -string macos/tauri/hello "$info_plist"
/usr/bin/plutil -replace KeldBenchRecipeRepository -string "$repository_identifier" "$info_plist"
/usr/bin/plutil -replace KeldBenchRecipeCommit -string "$source_commit" "$info_plist"
/usr/bin/plutil -replace KeldBenchBuildRecipe -string "$recipe_identifier" "$info_plist"
/usr/bin/plutil -replace KeldBenchBuildScriptSHA256 -string "$build_script_sha" "$info_plist"
/usr/bin/plutil -replace KeldBenchBunVersion -string "$bun_version" "$info_plist"
/usr/bin/plutil -replace KeldBenchTauriCLIVersion -string "$tauri_cli_version" "$info_plist"
/usr/bin/plutil -replace KeldBenchRustcVersion -string "$rustc_version" "$info_plist"
/usr/bin/plutil -replace KeldBenchCargoVersion -string "$cargo_version" "$info_plist"
/usr/bin/plutil -replace KeldBenchMacOSSDKVersion -string "$sdk_version" "$info_plist"
/usr/bin/plutil -replace KeldBenchXcodeVersion -string "$xcode_version" "$info_plist"
/usr/bin/plutil -lint "$info_plist"
/usr/bin/codesign --force --options runtime --sign - "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"

source_status_after=$(clean_git \
  -c core.fsmonitor=false \
  -c core.untrackedCache=false \
  -c core.fileMode=true \
  -C "$repository_root" \
  status --porcelain=v1 --untracked-files=all)
if [ -n "$source_status_after" ]; then
  echo "benchmark checkout changed during the build; refusing the artifact" >&2
  exit 65
fi
if [ -e "$output_app" ] || [ -L "$output_app" ]; then
  echo "refusing to overwrite benchmark app created during the build" >&2
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
  echo "could not atomically install the benchmark app without overwriting" >&2
  exit 73
fi

echo "app=$output_app"
echo "source_git_sha=$source_commit"
echo "build_recipe=$recipe_identifier"
