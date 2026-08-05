#!/usr/bin/env bash
# fm-github-feedback-intake.sh - consume retained daily GitHub feedback cards.
#
# The nightly producer owns the card schema and retention contract.
# This consumer is read-only against both the producer and GitHub:
#
#   1. Fetch every unreviewed Pacific date from the private Tailnet endpoint.
#   2. Validate the complete machine-card contract before trusting a card.
#   3. Recheck every live candidate against current GitHub state through gh-axi.
#   4. Drop work whose pull request, issue, review thread, or check is no longer live.
#   5. Render only surviving jobs, grouped by project and ranked by consequence.
#
# A missing or unreachable card is printed as unavailable input and is never
# recorded as a quiet day. A valid empty card, or a ready card whose work is now
# entirely stale, is recorded locally and produces no output. A date with live
# work remains pending until Firstmate has dispatched, deferred, or otherwise
# resolved every item and runs the acknowledge command.
#
# Local state:
#   state/github-feedback-reviewed-dates  one successfully handled YYYY-MM-DD per line
#   state/github-feedback-pending-dates   exact dates in the current actionable output
#
# Usage:
#   fm-github-feedback-intake.sh [--read-only]
#   fm-github-feedback-intake.sh acknowledge
#
# The default route and first possible card date are the handoff contract that
# shipped with the producer. Environment overrides exist for isolated tests:
#   FM_GITHUB_FEEDBACK_BASE_URL
#   FM_GITHUB_FEEDBACK_EPOCH
#   FM_GITHUB_FEEDBACK_TODAY
#   FM_GITHUB_FEEDBACK_FETCH_TIMEOUT
#   FM_GITHUB_FEEDBACK_GH_TIMEOUT
#   FM_GITHUB_FEEDBACK_DISABLED=1
# shellcheck disable=SC2016 # Node, GraphQL, and jq programs are intentionally literal.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

BASE_URL=${FM_GITHUB_FEEDBACK_BASE_URL:-https://matts-mac-mini.tail8a36c5.ts.net:8765/github-feedback}
EPOCH=${FM_GITHUB_FEEDBACK_EPOCH:-2026-08-04}
TODAY=${FM_GITHUB_FEEDBACK_TODAY:-$(TZ=America/Los_Angeles date +%F)}
FETCH_TIMEOUT=${FM_GITHUB_FEEDBACK_FETCH_TIMEOUT:-8}
GH_TIMEOUT=${FM_GITHUB_FEEDBACK_GH_TIMEOUT:-8}
REVIEWED="$STATE/github-feedback-reviewed-dates"
PENDING="$STATE/github-feedback-pending-dates"

usage() {
  cat <<'EOF'
usage: fm-github-feedback-intake.sh [--read-only]
       fm-github-feedback-intake.sh acknowledge

Fetch every unreviewed retained GitHub feedback date, recheck live candidates
against current GitHub state, and print only dispatchable work or a visible
source failure. The command never writes to GitHub or the producer ledger.

Run `acknowledge` only after every item in the latest actionable output has
been dispatched, deferred, found already under way, or escalated for a captain
decision. Valid empty and fully stale dates are recorded automatically.
EOF
}

die() {
  printf 'fm-github-feedback-intake: %s\n' "$*" >&2
  exit 2
}

valid_positive_integer() {
  case "$1" in ''|*[!0-9]*|0) return 1 ;; esac
}

valid_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  node -e '
    const value = process.argv[1];
    const parsed = new Date(`${value}T00:00:00Z`);
    if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) process.exit(1);
  ' "$1" >/dev/null 2>&1
}

date_range() {
  node -e '
    const start = new Date(`${process.argv[1]}T00:00:00Z`);
    const end = new Date(`${process.argv[2]}T00:00:00Z`);
    for (let at = start.getTime(); at < end.getTime(); at += 86400000) {
      process.stdout.write(`${new Date(at).toISOString().slice(0, 10)}\n`);
    }
  ' "$1" "$2"
}

friendly_date() {
  if ! command -v node >/dev/null 2>&1; then
    printf '%s' "$1"
    return 0
  fi
  node -e '
    const parsed = new Date(`${process.argv[1]}T00:00:00Z`);
    process.stdout.write(new Intl.DateTimeFormat("en-US", {
      month: "long", day: "numeric", year: "numeric", timeZone: "UTC"
    }).format(parsed));
  ' "$1"
}

reviewed_has() {
  [ -f "$REVIEWED" ] && grep -Fqx -- "$1" "$REVIEWED" 2>/dev/null
}

mark_reviewed_from_file() {
  local dates=$1 dir tmp
  [ -s "$dates" ] || return 0
  dir=$(dirname "$REVIEWED")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  tmp=$(umask 077; mktemp "$dir/.github-feedback-reviewed.XXXXXX") || return 1
  {
    [ -f "$REVIEWED" ] && cat "$REVIEWED"
    cat "$dates"
  } | sed '/^$/d' | sort -u > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$REVIEWED"
}

write_pending() {
  local dates=$1 dir tmp
  dir=$(dirname "$PENDING")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  if [ ! -s "$dates" ]; then
    rm -f "$PENDING"
    return 0
  fi
  tmp=$(umask 077; mktemp "$dir/.github-feedback-pending.XXXXXX") || return 1
  sort -u "$dates" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$PENDING"
}

acknowledge() {
  [ -s "$PENDING" ] || die 'there is no reviewed overnight GitHub work awaiting acknowledgment'
  mark_reviewed_from_file "$PENDING" || die 'could not record the reviewed dates'
  last=$(tail -n 1 "$PENDING")
  rm -f "$PENDING" || die 'could not clear the pending review record'
  printf 'Overnight GitHub work recorded through %s.\n' "$last"
}

bounded() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
      my $seconds = shift @ARGV;
      my $pid = fork;
      die "fork failed" unless defined $pid;
      if (!$pid) { setpgrp(0, 0); exec @ARGV }
      local $SIG{ALRM} = sub {
        kill "TERM", -$pid;
        select undef, undef, undef, 0.2;
        kill "KILL", -$pid;
        exit 124;
      };
      alarm $seconds;
      waitpid $pid, 0;
      exit($? >> 8);
    ' "$seconds" "$@"
  else
    "$@"
  fi
}

decode_gh_axi_body() {
  local input=$1 body truncated
  truncated=$(sed -n 's/^  truncated: //p' "$input" | head -n 1)
  [ "$truncated" = false ] || return 1
  body=$(sed -n 's/^  body: //p' "$input" | head -n 1)
  [ -n "$body" ] || return 1
  case "$body" in
    \"*) printf '%s\n' "$body" | jq -er . ;;
    *) printf '%s\n' "$body" ;;
  esac
}

cache_key() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | cksum | awk '{print $1 "-" $2}'
  fi
}

query_pull_request() {
  local owner=$1 repo=$2 number=$3 cache=$4 output rc query filter
  [ -f "$cache" ] && return 0
  [ ! -e "$TMP/github-unavailable" ] || return 1
  query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved isOutdated comments(first:100){pageInfo{hasNextPage} nodes{id isMinimized}}}} commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){pageInfo{hasNextPage} nodes{__typename ... on CheckRun{id status conclusion}}}}}}}}}}'
  filter='.data.repository.pullRequest as $p |
    if $p == null then "MISSING"
    else
      (["PR",$p.state,($p.merged|tostring),
        (($p.reviewThreads.pageInfo.hasNextPage or any($p.reviewThreads.nodes[]?; .comments.pageInfo.hasNextPage))|tostring),
        ((($p.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.hasNextPage) // false)|tostring)]|@tsv),
      ($p.reviewThreads.nodes[]? | . as $thread | .comments.nodes[]? |
        ["COMMENT",.id,($thread.isResolved|tostring),($thread.isOutdated|tostring),(.isMinimized|tostring),($thread.comments.pageInfo.hasNextPage|tostring)]|@tsv),
      ($p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]? |
        select(.__typename == "CheckRun") | ["CHECK",.id,.status,(.conclusion // "")]|@tsv)
    end'
  output="$TMP/gh-pr-$(cache_key "$owner/$repo/$number").out"
  if bounded "$GH_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh-axi api POST graphql \
      --field "query=$query" \
      --field "owner=$owner" \
      --field "repo=$repo" \
      --field "number=$number" \
      --jq "$filter" > "$output" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ] || ! decode_gh_axi_body "$output" > "$cache"; then
    : > "$TMP/github-unavailable"
    return 1
  fi
  [ -s "$cache" ]
}

query_issue() {
  local owner=$1 repo=$2 number=$3 cache=$4 output rc query filter
  [ -f "$cache" ] && return 0
  [ ! -e "$TMP/github-unavailable" ] || return 1
  query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){issue(number:$number){state}}}'
  filter='.data.repository.issue as $i | if $i == null then "MISSING" else ["ISSUE",$i.state]|@tsv end'
  output="$TMP/gh-issue-$(cache_key "$owner/$repo/$number").out"
  if bounded "$GH_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh-axi api POST graphql \
      --field "query=$query" \
      --field "owner=$owner" \
      --field "repo=$repo" \
      --field "number=$number" \
      --jq "$filter" > "$output" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ] || ! decode_gh_axi_body "$output" > "$cache"; then
    : > "$TMP/github-unavailable"
    return 1
  fi
  [ -s "$cache" ]
}

reference_parts() {
  printf '%s\n' "$1" | sed -nE \
    's#^https://github\.com/([^/]+)/([^/]+)/(pull|issues)/([0-9]+)([/#?].*)?$#\1\t\2\t\3\t\4#p'
}

assess_pull_request() {
  local owner=$1 repo=$2 number=$3 ids=$4 key cache header kind state merged thread_more check_more
  local id row resolved outdated minimized status conclusion live=0 uncertain=0 evidence_count=0
  key=$(cache_key "pull/$owner/$repo/$number")
  cache="$TMP/cache-$key"
  query_pull_request "$owner" "$repo" "$number" "$cache" || { printf 'error\n'; return; }
  header=$(sed -n '1p' "$cache")
  [ "$header" != MISSING ] || { printf 'stale\n'; return; }
  IFS="$(printf '\t')" read -r kind state merged thread_more check_more <<EOF
$header
EOF
  [ "${kind:-}" = PR ] || { printf 'error\n'; return; }
  [ "$state" = OPEN ] && [ "$merged" = false ] || { printf 'stale\n'; return; }

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    evidence_count=$((evidence_count + 1))
    case "$id" in
      PRRC_*)
        row=$(awk -F '\t' -v want="$id" '$1 == "COMMENT" && $2 == want { print; exit }' "$cache")
        if [ -n "$row" ]; then
          IFS="$(printf '\t')" read -r _ _ resolved outdated minimized _comment_more <<EOF
$row
EOF
          if [ "$resolved" = false ] && [ "$outdated" = false ] && [ "$minimized" = false ]; then
            live=1
          fi
        elif [ "$thread_more" = true ]; then
          uncertain=1
        fi
        ;;
      CR_*|CHECK_*)
        row=$(awk -F '\t' -v want="$id" '$1 == "CHECK" && $2 == want { print; exit }' "$cache")
        if [ -n "$row" ]; then
          IFS="$(printf '\t')" read -r _ _ status conclusion <<EOF
$row
EOF
          case "$status:$conclusion" in
            COMPLETED:SUCCESS|COMPLETED:NEUTRAL|COMPLETED:SKIPPED) ;;
            *) live=1 ;;
          esac
        elif [ "$check_more" = true ]; then
          uncertain=1
        fi
        ;;
      *)
        # Top-level reviews and comments have no resolvable thread state.
        # An open current pull request is the strongest deterministic signal.
        live=1
        ;;
    esac
  done < "$ids"

  if [ "$evidence_count" -eq 0 ] || [ "$live" -eq 1 ]; then
    printf 'live\n'
  elif [ "$uncertain" -eq 1 ]; then
    printf 'error\n'
  else
    printf 'stale\n'
  fi
}

assess_issue() {
  local owner=$1 repo=$2 number=$3 key cache line kind state
  key=$(cache_key "issue/$owner/$repo/$number")
  cache="$TMP/cache-$key"
  query_issue "$owner" "$repo" "$number" "$cache" || { printf 'error\n'; return; }
  line=$(sed -n '1p' "$cache")
  [ "$line" != MISSING ] || { printf 'stale\n'; return; }
  IFS="$(printf '\t')" read -r kind state <<EOF
$line
EOF
  [ "$kind" = ISSUE ] || { printf 'error\n'; return; }
  if [ "$state" = OPEN ]; then printf 'live\n'; else printf 'stale\n'; fi
}

assess_item() {
  local item=$1 refs ids parts owner repo kind number verdict any=0 uncertain=0
  refs="$TMP/item-refs"
  ids="$TMP/item-ids"
  printf '%s' "$item" | jq -r '.references[]?.url // empty' > "$refs"
  printf '%s' "$item" | jq -r '.evidence_event_ids[]? // empty' > "$ids"
  [ -s "$refs" ] || { printf 'error\n'; return; }
  while IFS= read -r url; do
    parts=$(reference_parts "$url")
    if [ -z "$parts" ]; then
      uncertain=1
      continue
    fi
    IFS="$(printf '\t')" read -r owner repo kind number <<EOF
$parts
EOF
    case "$kind" in
      pull) verdict=$(assess_pull_request "$owner" "$repo" "$number" "$ids") ;;
      issues) verdict=$(assess_issue "$owner" "$repo" "$number") ;;
      *) verdict=error ;;
    esac
    case "$verdict" in
      live) any=1 ;;
      error) uncertain=1 ;;
    esac
  done < "$refs"
  if [ "$any" -eq 1 ]; then
    printf 'live\n'
  elif [ "$uncertain" -eq 1 ]; then
    printf 'error\n'
  else
    printf 'stale\n'
  fi
}

fetch_card() {
  local day=$1 destination=$2 errors=$3 url code rc
  url="${BASE_URL%/}/$day/card.json"
  if code=$(curl --silent --show-error --location --head --output /dev/null \
    --write-out '%{http_code}' --connect-timeout 3 --max-time "$FETCH_TIMEOUT" \
    "$url" 2> "$errors"); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || return 10
  case "$code" in
    200) ;;
    404) return 11 ;;
    *) return 12 ;;
  esac
  if code=$(curl --silent --show-error --location --output "$destination" \
    --write-out '%{http_code}' --connect-timeout 3 --max-time "$FETCH_TIMEOUT" \
    "$url" 2> "$errors"); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || return 10
  [ "$code" = 200 ] || return 12
}

validate_card() {
  local card=$1 day=$2
  jq -e --arg day "$day" '
    type == "object" and
    .schema_version == "github-feedback-card.v1" and
    .card_date == $day and
    (.status == "ready" or .status == "empty") and
    (.projects | type == "array") and
    (.captain_needed | type == "array") and
    (if .status == "empty" then
      ([.projects[]?.work_items[]? | select(.status == "live")] | length) == 0 and
      (.captain_needed | length) == 0
    else true end)
  ' "$card" >/dev/null 2>&1
}

append_failure() {
  jq -nc --arg date "$1" --arg detail "$2" '{date:$date,detail:$detail}' >> "$FAILURES"
}

emit_failures() {
  [ -s "$FAILURES" ] || return 0
  printf 'OVERNIGHT GITHUB WORK UNAVAILABLE\n\n'
  while IFS="$(printf '\t')" read -r day detail; do
    printf -- '- %s: %s\n' "$(friendly_date "$day")" "$detail"
  done < <(jq -rs 'sort_by(.date)[] | [.date,.detail] | @tsv' "$FAILURES")
  printf '\nThis is missing input, not a quiet day. Firstmate will try again at the next session.\n'
}

emit_work() {
  local read_only=$1 suffix
  [ -s "$SURVIVORS" ] || return 0
  if [ "$read_only" -eq 1 ]; then
    suffix='Every item above was rechecked against GitHub current state. This session cannot act on the review, so it will appear again.'
  else
    suffix='Every item above was rechecked against GitHub current state. Resolve each through the normal project workflow before marking this review complete.'
  fi
  jq -rs --arg suffix "$suffix" '
    def clean: tostring | gsub("[\u0000-\u001f\u007f]+"; " ") | gsub("\u2063"; "") | gsub("  +"; " ");
    def rank: if .priority == "high" then 0 elif .priority == "medium" then 1 else 2 end;
    unique_by([.kind,.project,.headline,.action,.consequence]) as $all |
    [$all[] | select(.kind == "job")] as $jobs |
    [$all[] | select(.kind == "captain")] as $captain |
    "OVERNIGHT GITHUB WORK\n\n" +
    (if ($jobs | length) > 0 then
      ($jobs | group_by(.project) |
        sort_by([(map(rank) | min), .[0].project]) |
        map((.[0].project | clean) + "\n" +
          (sort_by([rank,.headline]) |
            map("- " + (.headline | clean) + "\n  Work: " + (.action | clean) + "\n  Consequence: " + (.consequence | clean)) |
            join("\n"))) |
        join("\n\n"))
    else "" end) +
    (if ($captain | length) > 0 then
      (if ($jobs | length) > 0 then "\n\n" else "" end) +
      "Needs Matt\n" +
      ($captain | sort_by(.headline) |
        map("- " + (.headline | clean) + "\n  Why: " + (.consequence | clean)) |
        join("\n"))
    else "" end) +
    "\n\n" + $suffix
  ' "$SURVIVORS"
  printf '\n'
}

collect() {
  local read_only=$1 day card fetch_errors rc status rows row project item verdict
  local day_survivors day_error day_live

  if [ "${FM_GITHUB_FEEDBACK_DISABLED:-0}" = 1 ]; then
    return 0
  fi
  for tool in curl jq node gh-axi; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      append_failure "$EPOCH" "the required $tool tool is unavailable, so the retained work could not be checked"
      emit_failures
      return 0
    fi
  done
  valid_positive_integer "$FETCH_TIMEOUT" || die 'FM_GITHUB_FEEDBACK_FETCH_TIMEOUT must be a positive integer'
  valid_positive_integer "$GH_TIMEOUT" || die 'FM_GITHUB_FEEDBACK_GH_TIMEOUT must be a positive integer'
  valid_date "$EPOCH" || die 'FM_GITHUB_FEEDBACK_EPOCH must be YYYY-MM-DD'
  valid_date "$TODAY" || die 'FM_GITHUB_FEEDBACK_TODAY must be YYYY-MM-DD'

  while IFS= read -r day; do
    [ -n "$day" ] || continue
    reviewed_has "$day" && continue
    card="$TMP/card-$day.json"
    fetch_errors="$TMP/fetch-$day.err"
    if fetch_card "$day" "$card" "$fetch_errors"; then
      rc=0
    else
      rc=$?
    fi
    case "$rc" in
      0) ;;
      10)
        append_failure "$day" 'the retained overnight work could not be reached from this laptop'
        break
        ;;
      11)
        append_failure "$day" 'no completed overnight work was available for this date'
        continue
        ;;
      *)
        append_failure "$day" 'the retained overnight work returned an unexpected response'
        continue
        ;;
    esac
    if ! validate_card "$card" "$day"; then
      append_failure "$day" 'the retained overnight work did not match the required complete-card contract'
      continue
    fi
    status=$(jq -r '.status' "$card")
    if [ "$status" = empty ]; then
      printf '%s\n' "$day" >> "$AUTO_REVIEWED"
      continue
    fi

    day_survivors="$TMP/survivors-$day.jsonl"
    : > "$day_survivors"
    day_error=0
    day_live=0
    rows="$TMP/rows-$day.jsonl"
    jq -c '
      .projects[]? as $project |
      $project.work_items[]? |
      select(.status == "live") |
      {kind:"job",project:($project.project_name // $project.repository),repository:$project.repository,item:.}
    ' "$card" > "$rows"
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      project=$(printf '%s' "$row" | jq -r '.project')
      item=$(printf '%s' "$row" | jq -c '.item')
      verdict=$(assess_item "$item")
      case "$verdict" in
        live)
          day_live=1
          printf '%s' "$row" | jq -c --arg date "$day" '{kind,project,repository,date:$date,headline:.item.headline,action:.item.action,consequence:.item.consequence,priority:(.item.priority // "medium")}' >> "$day_survivors"
          ;;
        error)
          day_error=1
          append_failure "$day" "current GitHub state could not be checked for $project - $(printf '%s' "$item" | jq -r '.headline')"
          ;;
      esac
    done < "$rows"

    jq -c '
      .captain_needed[]? |
      {kind:"captain",project:"Needs Matt",repository:"",item:{headline:.decision,action:.decision,consequence:.why_only_captain,priority:"high",references:.references,evidence_event_ids:.evidence_event_ids}}
    ' "$card" > "$rows"
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      item=$(printf '%s' "$row" | jq -c '.item')
      verdict=$(assess_item "$item")
      case "$verdict" in
        live)
          day_live=1
          printf '%s' "$row" | jq -c --arg date "$day" '{kind,project,repository,date:$date,headline:.item.headline,action:.item.action,consequence:.item.consequence,priority:"high"}' >> "$day_survivors"
          ;;
        error)
          day_error=1
          append_failure "$day" "current GitHub state could not be checked for a decision that may still need Matt"
          ;;
      esac
    done < "$rows"

    if [ "$day_error" -eq 1 ]; then
      continue
    fi
    if [ "$day_live" -eq 1 ]; then
      cat "$day_survivors" >> "$SURVIVORS"
      printf '%s\n' "$day" >> "$NEW_PENDING"
    else
      printf '%s\n' "$day" >> "$AUTO_REVIEWED"
    fi
  done < <(date_range "$EPOCH" "$TODAY")

  if [ "$read_only" -eq 0 ]; then
    mark_reviewed_from_file "$AUTO_REVIEWED" || append_failure "$EPOCH" 'the completed local review could not be recorded'
    write_pending "$NEW_PENDING" || append_failure "$EPOCH" 'the actionable local review could not be recorded'
  fi
  emit_work "$read_only"
  if [ -s "$SURVIVORS" ] && [ -s "$FAILURES" ]; then printf '\n'; fi
  emit_failures
}

MODE=collect
READ_ONLY=0
case "${1:-}" in
  '') ;;
  --read-only) READ_ONLY=1 ;;
  acknowledge) MODE=acknowledge ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ $# -le 1 ] || { usage >&2; exit 2; }

if [ "$MODE" = acknowledge ]; then
  acknowledge
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-github-feedback-intake.XXXXXX") || die 'could not create a private temporary directory'
trap 'rm -rf "$TMP"' EXIT INT TERM
SURVIVORS="$TMP/survivors.jsonl"
FAILURES="$TMP/failures.jsonl"
AUTO_REVIEWED="$TMP/auto-reviewed"
NEW_PENDING="$TMP/new-pending"
: > "$SURVIVORS"
: > "$FAILURES"
: > "$AUTO_REVIEWED"
: > "$NEW_PENDING"

collect "$READ_ONLY"
