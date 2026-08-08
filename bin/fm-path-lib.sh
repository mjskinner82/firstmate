# shellcheck shell=bash
# Pure shared path predicates and directory-input resolution.
# Usage: . bin/fm-path-lib.sh

# Return success only when <path> is a strict lexical descendant of the
# nonempty <ancestor>. Equality and sibling prefixes are rejected.
fm_path_is_strict_descendant() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

# Pass an absolute directory spelling through unchanged, or resolve an existing
# relative directory physically from the caller's current working directory.
fm_resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}
