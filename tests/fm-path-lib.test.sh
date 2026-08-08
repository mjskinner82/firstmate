#!/usr/bin/env bash
# Behavior tests for the shared strict-ancestry and directory-input helpers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-path-lib.sh
. "$ROOT/bin/fm-path-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-path-lib)

test_strict_descendant_matrix() {
  local expected ancestor path label status
  while IFS='|' read -r expected ancestor path label; do
    [ -n "$label" ] || continue
    status=0
    fm_path_is_strict_descendant "$ancestor" "$path" || status=$?
    [ "$status" -eq "$expected" ] || {
      fail "$label: expected exit $expected for ancestor='$ancestor' path='$path', got $status"
    }
  done <<'ROWS'
1||/safe/home|empty ancestor is rejected
1|/safe/home||empty path is rejected
1|/safe/home|/safe/home|equality is rejected
1|/safe/home|/safe/home-other|sibling prefix is rejected
0|/safe/home|/safe/home/data|strict descendant is accepted
0|/safe/home|/safe/home/data/|path trailing separator is accepted
1|/safe/home/|/safe/home/data|ancestor trailing separator is not normalized
0|/safe/home/|/safe/home//data|ancestor trailing separator retains its exact double-separator match
1|/|/safe|filesystem-root ancestry retains the original lexical behavior
ROWS
  pass "fm_path_is_strict_descendant preserves the exact strict lexical ancestry matrix"
}

test_absolute_input_passes_through() {
  local work link out
  work="$TMP_ROOT/absolute"
  mkdir -p "$work/real"
  link="$work/link"
  ln -s "$work/real" "$link"

  out=$(fm_resolve_directory_input SAMPLE "$link") || fail "absolute symlink input returned failure"
  [ "$out" = "$link" ] || fail "absolute symlink spelling changed: expected '$link', got '$out'"
  pass "fm_resolve_directory_input passes absolute spellings through unchanged"
}

test_relative_input_resolves_physically() {
  local work target expected out
  work="$TMP_ROOT/relative work"
  target="$TMP_ROOT/physical target/dir with spaces"
  mkdir -p "$work" "$target" "$TMP_ROOT/cdpath"
  ln -s "$target" "$work/link with spaces"
  expected=$(cd "$target" && pwd -P)

  out=$(cd "$work" && CDPATH="$TMP_ROOT/cdpath" \
    fm_resolve_directory_input SAMPLE "link with spaces") || {
    fail "relative symlink input returned failure"
  }
  [ "$out" = "$expected" ] || fail "relative input: expected '$expected', got '$out'"
  pass "fm_resolve_directory_input resolves relative spaces and symlinks physically while ignoring CDPATH"
}

test_missing_relative_input_fails_loudly() {
  local work cdpath err out status
  work="$TMP_ROOT/missing-work"
  cdpath="$TMP_ROOT/cdpath-parent"
  err="$TMP_ROOT/missing.err"
  mkdir -p "$work" "$cdpath/cdpath-only"

  status=0
  out=$(cd "$work" && CDPATH="$cdpath" \
    fm_resolve_directory_input TEST_DIRECTORY cdpath-only 2>"$err") || status=$?
  [ "$status" -eq 1 ] || fail "missing relative input: expected exit 1, got $status"
  [ -z "$out" ] || fail "missing relative input emitted stdout: '$out'"
  assert_grep "error: TEST_DIRECTORY directory cannot be resolved: cdpath-only" "$err" \
    "missing relative input did not emit the exact labeled diagnostic"
  pass "fm_resolve_directory_input rejects CDPATH-only and missing relative directories"
}

test_strict_descendant_matrix
test_absolute_input_passes_through
test_relative_input_resolves_physically
test_missing_relative_input_fails_loudly
