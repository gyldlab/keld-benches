#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_script="$script_dir/build.sh"
test_root=$(/usr/bin/mktemp -d /tmp/tauri-build-isolation-test.XXXXXX)

cleanup() {
  case "${test_root:-}" in
    /tmp/tauri-build-isolation-test.*|/private/tmp/tauri-build-isolation-test.*)
      /bin/rm -rf -- "$test_root"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

contract="$test_root/isolation-contract.sh"
/usr/bin/awk '
  /^# BEGIN TAURI BUILD ISOLATION CONTRACT$/ { copying = 1; next }
  /^# END TAURI BUILD ISOLATION CONTRACT$/ { copying = 0 }
  copying { print }
' "$build_script" >"$contract"
if [ ! -s "$contract" ]; then
  fail "build isolation contract could not be loaded"
fi
# shellcheck disable=SC1090
. "$contract"

case_root="$test_root/checkout-case"
repository="$case_root/repository"
output_parent="$repository/src-tauri/target/release/bundle/macos"
inside_tmpdir="$repository/hostile-tmp"
external_tmpdir="$case_root/external-tmp"
/bin/mkdir -p "$output_parent" "$inside_tmpdir" "$external_tmpdir" \
  "$repository/node_modules" "$repository/.cargo"
printf '%s\n' '[build]' 'rustc = "/definitely/hostile-rustc"' \
  >"$repository/.cargo/config.toml"
printf '%s\n' '{"workspaces":["*"]}' >"$repository/package.json"
repository_physical=$(canonical_directory "$repository")

# A caller-controlled TMPDIR inside the checkout must not become a source or
# target ancestor. The production selector deliberately falls back to /tmp.
selected_tmpdir=$(select_external_tmpdir "$repository_physical" "$inside_tmpdir")
if directory_is_within "$selected_tmpdir" "$repository_physical"; then
  fail "TMPDIR inside the checkout was accepted"
fi

# The output target may not exist on a clean checkout. Selecting the external
# staging root must validate the nearest existing output ancestor without
# creating anything under the checkout first.
missing_output_case="$test_root/missing-output"
missing_repository="$missing_output_case/repository"
missing_output_parent="$missing_repository/src-tauri/target/release/bundle/macos"
missing_external_tmpdir="$missing_output_case/external-tmp"
/bin/mkdir -p "$missing_repository/src-tauri" "$missing_external_tmpdir"
missing_repository_physical=$(canonical_directory "$missing_repository")
create_external_staging_root \
  "$missing_repository_physical" "$missing_external_tmpdir" \
  "$missing_output_parent"
missing_staging_root=$created_staging_root
missing_staging_identity=$created_staging_identity
if [ -e "$missing_output_parent" ] || [ -L "$missing_output_parent" ]; then
  fail "staging selection created the checkout output target before validation"
fi
if [ -e "$missing_repository/src-tauri/target" ] || \
   [ -L "$missing_repository/src-tauri/target" ]; then
  fail "staging selection created the checkout target before validation"
fi
/bin/mkdir -p "$missing_repository/src-tauri/target"
if [ ! -d "$missing_repository/src-tauri/target" ] || \
   [ -L "$missing_repository/src-tauri/target" ]; then
  fail "output target could not be created after external staging validation"
fi
if [ "$(/usr/bin/stat -f '%d' "$missing_staging_root")" != \
     "$(/usr/bin/stat -f '%d' "$missing_repository/src-tauri/target")" ]; then
  fail "staging and output target do not share a filesystem"
fi
remove_owned_staging_root "$missing_staging_root" "$missing_external_tmpdir" \
  "$missing_staging_identity"

# Hostile ignored state in the checkout is a sibling of the isolated archive,
# so it cannot participate in Bun or Cargo ancestor discovery.
external_physical=$(canonical_directory "$external_tmpdir")
create_external_staging_root \
  "$repository_physical" "$external_physical" "$output_parent"
staging_root=$created_staging_root
source_directory="$staging_root/source/macos/tauri/hello"
build_target="$staging_root/target"
/bin/mkdir -p "$source_directory" "$build_target"
verify_isolated_directory "$repository_physical" "$staging_root" \
  "$source_directory" "test source"
verify_isolated_directory "$repository_physical" "$staging_root" \
  "$build_target" "test target"
reject_ambient_dependency_ancestors "$source_directory" "$staging_root"

# A node_modules directory above the isolated source would be discoverable by
# Bun. The contract must fail closed rather than rely on package-manager luck.
node_case="$test_root/node-ancestor"
node_staging="$node_case/staging"
node_source="$node_staging/source/macos/tauri/hello"
/bin/mkdir -p "$node_source" "$node_case/node_modules"
if reject_ambient_dependency_ancestors "$node_source" "$node_staging" \
  >"$test_root/node.out" 2>"$test_root/node.err"; then
  fail "hostile ancestor node_modules was accepted"
fi
if ! /usr/bin/grep -Fq "$node_case/node_modules" "$test_root/node.err"; then
  fail "node_modules rejection did not identify the hostile path"
fi

# Cargo walks parent directories for .cargo/config.toml. Verify that this
# ambient control channel is rejected before dependency installation or build.
cargo_case="$test_root/cargo-ancestor"
cargo_staging="$cargo_case/staging"
cargo_source="$cargo_staging/source/macos/tauri/hello"
/bin/mkdir -p "$cargo_source" "$cargo_case/.cargo"
printf '%s\n' '[build]' 'rustc = "/definitely/hostile-rustc"' \
  >"$cargo_case/.cargo/config.toml"
if reject_ambient_dependency_ancestors "$cargo_source" "$cargo_staging" \
  >"$test_root/cargo.out" 2>"$test_root/cargo.err"; then
  fail "hostile ancestor Cargo configuration was accepted"
fi
if ! /usr/bin/grep -Fq "$cargo_case/.cargo/config.toml" "$test_root/cargo.err"; then
  fail "Cargo-config rejection did not identify the hostile path"
fi

# Bun also walks upward for workspace manifests. The fixture's own package.json
# is allowed, but a package.json strictly above it must fail closed.
package_case="$test_root/package-ancestor"
package_staging="$package_case/staging"
package_source="$package_staging/source/macos/tauri/hello"
/bin/mkdir -p "$package_source"
printf '%s\n' '{"workspaces":["*"]}' >"$package_case/package.json"
if reject_ambient_dependency_ancestors "$package_source" "$package_staging" \
  >"$test_root/package.out" 2>"$test_root/package.err"; then
  fail "hostile ancestor Bun workspace manifest was accepted"
fi
if ! /usr/bin/grep -Fq "$package_case/package.json" "$test_root/package.err"; then
  fail "package.json rejection did not identify the hostile path"
fi

# Cleanup must operate on the exact mktemp pathname and inode. Replacing that
# directory with a symlink must leak/refuse the path, never follow it into a
# sentinel directory.
cleanup_parent="$test_root/cleanup-parent"
cleanup_output="$test_root/cleanup-output"
sentinel_directory="$test_root/sentinel"
/bin/mkdir -p "$cleanup_parent" "$cleanup_output" "$sentinel_directory"
printf '%s\n' preserve >"$sentinel_directory/preserve.txt"
create_external_staging_root \
  "$repository_physical" "$cleanup_parent" "$cleanup_output"
owned_staging=$created_staging_root
owned_identity=$created_staging_identity
/bin/mv "$owned_staging" "$owned_staging.original"
/bin/ln -s "$sentinel_directory" "$owned_staging"
if remove_owned_staging_root "$owned_staging" "$cleanup_parent" "$owned_identity" \
  >"$test_root/cleanup.out" 2>"$test_root/cleanup.err"; then
  fail "cleanup accepted a replaced staging symlink"
fi
if [ ! -f "$sentinel_directory/preserve.txt" ]; then
  fail "cleanup followed the replaced staging symlink into the sentinel"
fi
if [ ! -L "$owned_staging" ]; then
  fail "mismatched cleanup did not refuse and leak the replaced pathname"
fi

# Keep the behavioral contract wired into the real recipe. These assertions
# make the test fail if staging is moved back under src-tauri/target or any
# ambient dependency root is restored.
/usr/bin/grep -Fq 'if ! create_external_staging_root \' "$build_script" || \
  fail "production recipe no longer creates external staging"
/usr/bin/grep -Fq 'temporary_root_identity=$created_staging_identity' "$build_script" || \
  fail "production recipe no longer retains the original staging inode"
/usr/bin/grep -Fq 'build_target="$temporary_root/target"' "$build_script" || \
  fail "Cargo target is no longer rooted in isolated staging"
/usr/bin/grep -Fq 'BUN_INSTALL="$bun_install_dir"' "$build_script" || \
  fail "Bun install root is no longer isolated"
/usr/bin/grep -Fq 'reject_ambient_dependency_ancestors "$isolated_source_dir" "$temporary_root"' \
  "$build_script" || fail "production recipe no longer rejects ambient ancestors"
/usr/bin/grep -Fq 'remove_owned_staging_root "$temporary_root" "$sanitized_tmpdir"' \
  "$build_script" || fail "production recipe no longer uses identity-bound cleanup"
if /usr/bin/grep -Fq '$source_target_root/.tauri-bench-target' "$build_script"; then
  fail "build staging was restored inside the checkout"
fi
if ! /usr/bin/awk '
  /if ! create_external_staging_root/ { staging_line = NR }
  /ensure_real_directory "\$source_target_root"/ { target_line = NR }
  END { exit (staging_line > 0 && target_line > staging_line) ? 0 : 1 }
' "$build_script"; then
  fail "checkout target directories are created before external staging validation"
fi

echo "PASS: Tauri source, dependency, and target staging stays external"
