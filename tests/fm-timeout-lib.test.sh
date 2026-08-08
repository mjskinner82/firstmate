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

test_single_owner_and_migrated_callers() {
  local legacy caller
  legacy=$(LC_ALL=C grep -R -n -E --include='*.sh' '^run_timed\(\)' "$ROOT/bin" || true)
  [ -z "$legacy" ] || fail "legacy run_timed definitions remain: $legacy"

  for caller in "$ROOT/bin/fm-vendor-auth-probe.sh" "$ROOT/bin/fm-fleet-snapshot.sh"; do
    assert_grep 'fm-timeout-lib.sh' "$caller" "$(basename "$caller") does not source the shared owner"
    assert_grep 'fm_run_timed ' "$caller" "$(basename "$caller") does not call the shared runner"
  done
  pass "fm_run_timed is the single owner used by both reported callers"
}

test_source_is_quiet() {
  local out status=0
  out=$(/bin/bash -c '. "$1"' _ "$TIMEOUT_LIB") || status=$?
  expect_code 0 "$status" "sourcing fm-timeout-lib.sh"
  [ -z "$out" ] || fail "sourcing fm-timeout-lib.sh emitted stdout: $out"
  pass "fm-timeout-lib.sh is side-effect-free when sourced"
}

test_perl_fallback_preserves_status_and_bounds() {
  local toolbin driver marker status started elapsed
  toolbin="$TMP_ROOT/perl-only"
  driver="$TMP_ROOT/perl-driver.sh"
  marker="$TMP_ROOT/perl-late-marker"
  mkdir -p "$toolbin"
  ln -s "$(command -v perl)" "$toolbin/perl"
  make_driver "$driver"

  status=0
  env PATH="$toolbin" /bin/bash "$driver" "$TIMEOUT_LIB" 2 \
    /bin/bash -c 'exit 23' || status=$?
  expect_code 23 "$status" "Perl fallback natural command status"

  started=$(date +%s)
  status=0
  # shellcheck disable=SC2016  # These expressions are expanded by Perl.
  env PATH="$toolbin" /bin/bash "$driver" "$TIMEOUT_LIB" 1 \
    /usr/bin/perl -e '$SIG{TERM} = "IGNORE"; sleep 10; open my $fh, ">", $ARGV[0] or die $!; print {$fh} "late\n"' \
    "$marker" || status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 124 "$status" "Perl fallback expiry"
  [ "$elapsed" -lt 5 ] || fail "Perl fallback exceeded its one-second bound (${elapsed}s)"
  sleep 1
  assert_absent "$marker" "Perl fallback left a TERM-resistant command running"
  pass "Perl fallback preserves command status, returns 124, and kills the bounded process group"
}

test_bash_fallback_preserves_status_and_bounds() {
  local driver marker status started elapsed
  driver="$TMP_ROOT/bash-driver.sh"
  marker="$TMP_ROOT/bash-late-marker"
  make_driver "$driver"

  status=0
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash /bin/bash "$driver" "$TIMEOUT_LIB" 2 \
    /bin/bash -c 'exit 137' || status=$?
  expect_code 137 "$status" "Bash fallback natural command status"

  started=$(date +%s)
  status=0
  # shellcheck disable=SC2016  # These expressions are expanded by Perl.
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash /bin/bash "$driver" "$TIMEOUT_LIB" 1 \
    /usr/bin/perl -e '$SIG{TERM} = "IGNORE"; sleep 10; open my $fh, ">", $ARGV[0] or die $!; print {$fh} "late\n"' \
    "$marker" || status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 124 "$status" "Bash fallback expiry"
  [ "$elapsed" -lt 5 ] || fail "Bash fallback exceeded its one-second bound (${elapsed}s)"
  sleep 1
  assert_absent "$marker" "Bash fallback left a TERM-resistant command running"
  pass "Bash fallback preserves command status, returns 124, and kills the bounded process group"
}

test_single_owner_and_migrated_callers
test_source_is_quiet
test_perl_fallback_preserves_status_and_bounds
test_bash_fallback_preserves_status_and_bounds
