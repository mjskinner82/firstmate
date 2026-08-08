#!/usr/bin/env bash
# Behavior tests for the guarded local-only fast-forward merge command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)
fm_git_identity fmtest fmtest@example.invalid

test_origin_head_default_is_fast_forwarded() {
  local case_dir repo base feature out
  case_dir="$TMP_ROOT/origin-head"
  repo="$case_dir/project"
  mkdir -p "$case_dir/home/state" "$case_dir/fm-root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fm-root/bin/fm-guard.sh"
  chmod +x "$case_dir/fm-root/bin/fm-guard.sh"

  git init -q -b trunk "$repo"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" branch main
  git -C "$repo" update-ref refs/remotes/origin/trunk HEAD
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  git -C "$repo" checkout -qb fm/task-x1
  printf 'feature\n' >> "$repo/file.txt"
  git -C "$repo" commit -qam feature
  feature=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q trunk

  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "project=$repo" \
    "mode=local-only"

  out=$(FM_ROOT_OVERRIDE="$case_dir/fm-root" \
    FM_HOME="$case_dir/home" \
    "$MERGE_LOCAL" task-x1)

  assert_contains "$out" "merged fm/task-x1 into local trunk" \
    "merge-local did not report the origin/HEAD-selected branch"
  [ "$(git -C "$repo" rev-parse trunk)" = "$feature" ] || \
    fail "merge-local did not fast-forward the origin/HEAD-selected trunk branch"
  [ "$(git -C "$repo" rev-parse main)" = "$base" ] || \
    fail "merge-local moved the local main fallback instead of origin/HEAD's trunk"
  pass "fm-merge-local fast-forwards the shared resolver's origin/HEAD branch"
}

test_origin_head_default_is_fast_forwarded
