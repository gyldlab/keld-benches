#!/usr/bin/env bash
# Runs the named no_flag_windows cells against a signed host with a prebuilt test binary.
# Usage: bash run-cells.sh <label> <host-label> <runs> <cell>...   (cell = h11|h12|h9|h5)
# Reads INSTALLER=/TEST_BINARY= from <evidence>/hosts/<host-label>.paths unless
# TEST_BINARY is exported. Writes runs/<label>-<cell>/ and a summary line per cell.
set -u
E=<evidence-dir>
label=${1:?label}; host_label=${2:?host label}; runs=${3:?runs}; shift 3
paths="$E/hosts/$host_label.paths"
[ -f "$paths" ] || { echo "NO_PATHS $paths"; exit 2; }
installer=$(grep '^INSTALLER=' "$paths" | cut -d= -f2-)
signed=$(grep '^SIGNED_HOST=' "$paths" | cut -d= -f2-)
test_binary=${TEST_BINARY:-$(grep '^TEST_BINARY=' "$paths" | cut -d= -f2-)}
[ -n "$test_binary" ] || { echo "NO_TEST_BINARY"; exit 2; }
declare -A names=(
  [h11]=profiles::handover::kel270_s6c2a_h11_reference_app_quits_within_d_after_handover
  [h12]=profiles::handover::kel270_s6c2a_h12_app_ignoring_last_window_closed_is_ended_at_d
  [h9]=profiles::handover::kel270_s6c2a_h9_failed_handover_tail_exits_with_its_error
  [h5]=profiles::sessions::kel270_s6c_two_consecutive_sessions_in_one_host_process
)
rc_all=0
for cell in "$@"; do
  name=${names[$cell]:?unknown cell $cell}
  echo "== $label $cell x$runs host=$host_label test_binary=$test_binary ($(date -u +%FT%TZ))"
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$E/run-cell.ps1")" \
    -Label "$label-$cell" -SignedHost "$(cygpath -w "$signed")" -Installer "$(cygpath -w "$installer")" \
    -TestBinary "$(cygpath -w "$test_binary")" -TestName "$name" -Runs "$runs" 2>&1 | tr -d '\r' | grep 'CELL_'
  rc=${PIPESTATUS[0]}
  echo "CELL_EXIT $label $cell rc=$rc"
  [ "$rc" -eq 0 ] || rc_all=1
  for f in "$E/runs/$label-$cell"/run-*.log; do
    [ -f "$f" ] || continue
    iconv -f UTF-16 -t UTF-8 "$f" > "${f%.log}.utf8.log" 2>/dev/null || cp "$f" "${f%.log}.utf8.log"
  done
done
echo "RUN_CELLS_DONE $label rc_all=$rc_all ($(date -u +%FT%TZ))"
exit $rc_all
