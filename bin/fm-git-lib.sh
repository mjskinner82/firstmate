# shellcheck shell=bash
# Pure shared Git repository identity helpers.
# Usage: . bin/fm-git-lib.sh

# Resolve the default branch name of the Git repository at <dir>: prefer
# origin/HEAD, then fall back to a local main or master branch.
# Prints the name, or returns 1 when no supported default branch can be found.
fm_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}
