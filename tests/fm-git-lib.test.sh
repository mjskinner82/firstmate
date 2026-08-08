#!/usr/bin/env bash
# Behavior tests for the shared Git default-branch resolver.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-git-lib.sh
. "$ROOT/bin/fm-git-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-git-lib)
fm_git_identity fmtest fmtest@example.invalid

make_repo() {
  local name=$1 branch=$2 repo
  repo="$TMP_ROOT/$name"
  git init -q -b "$branch" "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  printf '%s\n' "$repo"
}

test_origin_head_wins() {
  local repo out
  repo=$(make_repo origin-head trunk)
  git -C "$repo" branch main
  git -C "$repo" update-ref refs/remotes/origin/trunk HEAD
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk

  out=$(fm_default_branch "$repo") || fail "origin/HEAD: resolver returned failure"
  [ "$out" = trunk ] || fail "origin/HEAD: expected trunk, got '$out'"
  pass "fm_default_branch prefers origin/HEAD over local fallback branches"
}

test_main_fallback_wins() {
  local repo out
  repo=$(make_repo main-fallback main)
  git -C "$repo" branch master

  out=$(fm_default_branch "$repo") || fail "main fallback: resolver returned failure"
  [ "$out" = main ] || fail "main fallback: expected main, got '$out'"
  pass "fm_default_branch prefers local main over local master"
}

test_master_fallback() {
  local repo out
  repo=$(make_repo master-fallback master)

  out=$(fm_default_branch "$repo") || fail "master fallback: resolver returned failure"
  [ "$out" = master ] || fail "master fallback: expected master, got '$out'"
  pass "fm_default_branch falls back to local master"
}

test_missing_default_fails() {
  local repo out status
  repo=$(make_repo missing-default trunk)

  set +e
  out=$(fm_default_branch "$repo")
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "missing default: expected exit 1, got $status"
  [ -z "$out" ] || fail "missing default: expected no output, got '$out'"
  pass "fm_default_branch fails silently when origin/HEAD, main, and master are absent"
}

test_origin_head_wins
test_main_fallback_wins
test_master_fallback
test_missing_default_fails
