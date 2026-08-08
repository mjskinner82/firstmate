#!/usr/bin/env bash
# Behavior tests for the shared bounded command runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIMEOUT_LIB="$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-timeout-lib)

make_driver() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
. "$1"
shift
fm_run_timed "$@"
SH
  chmod +x "$1"
}

make_term_resistant_tree() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
trap '' TERM
/bin/bash -c '
  trap "" TERM
  printf "%s\n" "$$" > "$1"
  /bin/sleep 10
  printf "late\n" > "$2"
' _ "$1" "$2" &
wait
SH
  chmod +x "$1"
}

test_single_owner_and_migrated_callers() {
  local legacy owners owner_count caller
  legacy=$(LC_ALL=C grep -R -n -E --include='*.sh' '^[[:space:]]*run_timed[[:space:]]*\(\)' "$ROOT/bin" || true)
  [ -z "$legacy" ] || fail "legacy run_timed definitions remain: $legacy"

  owners=$(LC_ALL=C grep -R -n -E --include='*.sh' '^[[:space:]]*fm_run_timed[[:space:]]*\(\)' "$ROOT/bin" || true)
  owner_count=$(printf '%s\n' "$owners" | awk 'NF { count++ } END { print count + 0 }')
  [ "$owner_count" -eq 1 ] || fail "expected one fm_run_timed owner, found $owner_count: $owners"
  case "$owners" in
    "$TIMEOUT_LIB":*) ;;
    *) fail "fm_run_timed owner is not fm-timeout-lib.sh: $owners" ;;
  esac

  for caller in "$ROOT/bin/fm-vendor-auth-probe.sh" "$ROOT/bin/fm-fleet-snapshot.sh"; do
    assert_grep 'fm-timeout-lib.sh' "$caller" "$(basename "$caller") does not source the shared owner"
    assert_grep 'fm_run_timed ' "$caller" "$(basename "$caller") does not call the shared runner"
  done
  pass "fm_run_timed is the single owner used by both reported callers"
}

test_source_is_quiet() {
  local out status=0
  out=$(/bin/bash -c '. "$1"' _ "$TIMEOUT_LIB" 2>&1) || status=$?
  expect_code 0 "$status" "sourcing fm-timeout-lib.sh"
  [ -z "$out" ] || fail "sourcing fm-timeout-lib.sh emitted output: $out"
  pass "fm-timeout-lib.sh is side-effect-free when sourced"
}

test_perl_fallback_preserves_status_and_bounds() {
  local toolbin driver tree marker pidfile descendant_pid status started elapsed
  toolbin="$TMP_ROOT/perl-only"
  driver="$TMP_ROOT/perl-driver.sh"
  tree="$TMP_ROOT/perl-term-resistant-tree.sh"
  marker="$TMP_ROOT/perl-late-marker"
  pidfile="$TMP_ROOT/perl-descendant-pid"
  mkdir -p "$toolbin"
  ln -s "$(command -v perl)" "$toolbin/perl"
  make_driver "$driver"
  make_term_resistant_tree "$tree"

  status=0
  env PATH="$toolbin" /bin/bash "$driver" "$TIMEOUT_LIB" 2 \
    /bin/bash -c 'exit 23' || status=$?
  expect_code 23 "$status" "Perl fallback natural command status"

  started=$(date +%s)
  status=0
  env PATH="$toolbin" /bin/bash "$driver" "$TIMEOUT_LIB" 1 \
    /bin/bash "$tree" "$pidfile" "$marker" || status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 124 "$status" "Perl fallback expiry"
  [ "$elapsed" -lt 5 ] || fail "Perl fallback exceeded its one-second bound (${elapsed}s)"
  [ -s "$pidfile" ] || fail "Perl fallback command did not record its descendant pid"
  descendant_pid=$(cat "$pidfile")
  if kill -0 "$descendant_pid" 2>/dev/null; then
    fail "Perl fallback left TERM-resistant descendant $descendant_pid running"
  fi
  assert_absent "$marker" "Perl fallback left a TERM-resistant command running"
  pass "Perl fallback preserves command status, returns 124, and kills the bounded process group"
}

test_bash_fallback_preserves_status_and_bounds() {
  local driver tree marker pidfile descendant_pid status started elapsed
  driver="$TMP_ROOT/bash-driver.sh"
  tree="$TMP_ROOT/bash-term-resistant-tree.sh"
  marker="$TMP_ROOT/bash-late-marker"
  pidfile="$TMP_ROOT/bash-descendant-pid"
  make_driver "$driver"
  make_term_resistant_tree "$tree"

  status=0
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash /bin/bash "$driver" "$TIMEOUT_LIB" 2 \
    /bin/bash -c 'exit 137' || status=$?
  expect_code 137 "$status" "Bash fallback natural command status"

  started=$(date +%s)
  status=0
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash /bin/bash "$driver" "$TIMEOUT_LIB" 1 \
    /bin/bash "$tree" "$pidfile" "$marker" || status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 124 "$status" "Bash fallback expiry"
  [ "$elapsed" -lt 5 ] || fail "Bash fallback exceeded its one-second bound (${elapsed}s)"
  [ -s "$pidfile" ] || fail "Bash fallback command did not record its descendant pid"
  descendant_pid=$(cat "$pidfile")
  if kill -0 "$descendant_pid" 2>/dev/null; then
    fail "Bash fallback left TERM-resistant descendant $descendant_pid running"
  fi
  assert_absent "$marker" "Bash fallback left a TERM-resistant command running"
  pass "Bash fallback preserves command status, returns 124, and kills the bounded process group"
}

test_single_owner_and_migrated_callers
test_source_is_quiet
test_perl_fallback_preserves_status_and_bounds
test_bash_fallback_preserves_status_and_bounds
