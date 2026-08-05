#!/usr/bin/env bash
# Behavior tests for the retained nightly GitHub feedback consumer.
#
# Coverage:
#   - a transport failure is visible and cannot be mistaken for a quiet day
#   - every unreviewed date is fetched and surfaced together
#   - current resolved-thread state drops stale card work silently
#   - acknowledgment records exactly the dates from actionable output
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-github-feedback-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-github-feedback-intake)
REAL_NODE=$(command -v node)

make_world() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/home/state" "$dir/cards" "$dir/gh"
  fakebin=$(fm_fakebin "$dir")

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
output=
url=
while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      shift
      output=${1:-}
      ;;
    --write-out|--connect-timeout|--max-time)
      shift
      ;;
    http://*|https://*) url=$1 ;;
  esac
  shift
done
day=$(printf '%s\n' "$url" | sed -nE 's#.*/([0-9]{4}-[0-9]{2}-[0-9]{2})/card\.json$#\1#p')
[ -n "$day" ] || exit 22
printf '%s\n' "$day" >> "${FM_TEST_CURL_LOG:?}"
if [ "${FM_TEST_FETCH_FAIL_DATE:-}" = "$day" ]; then
  printf '%s\n' 'fixture transport failure' >&2
  exit 7
fi
card="${FM_TEST_CARD_DIR:?}/$day.json"
if [ ! -f "$card" ]; then
  printf '404'
  exit 0
fi
if [ -n "$output" ] && [ "$output" != /dev/null ]; then
  cp "$card" "$output"
fi
printf '200'
SH
  chmod +x "$fakebin/curl"

  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
owner=
repo=
number=
previous=
for arg in "$@"; do
  if [ "$previous" = --field ]; then
    case "$arg" in
      owner=*) owner=${arg#owner=} ;;
      repo=*) repo=${arg#repo=} ;;
      number=*) number=${arg#number=} ;;
    esac
  fi
  previous=$arg
done
fixture="${FM_TEST_GH_DIR:?}/$owner--$repo--$number.out"
[ -f "$fixture" ] || exit 1
cat "$fixture"
SH
  chmod +x "$fakebin/gh-axi"

  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
exec "$REAL_NODE" "\$@"
SH
  chmod +x "$fakebin/node"
  printf '%s|%s\n' "$dir" "$fakebin"
}

write_ready_card() {
  local path=$1 date=$2 project=$3 repository=$4 headline=$5 action=$6 consequence=$7 url=$8 evidence=$9
  jq -n \
    --arg date "$date" \
    --arg project "$project" \
    --arg repository "$repository" \
    --arg headline "$headline" \
    --arg action "$action" \
    --arg consequence "$consequence" \
    --arg url "$url" \
    --arg evidence "$evidence" '
      {
        schema_version:"github-feedback-card.v1",
        card_date:$date,
        status:"ready",
        projects:[{
          repository:$repository,
          project_name:$project,
          work_items:[{
            headline:$headline,
            action:$action,
            consequence:$consequence,
            priority:"high",
            status:"live",
            status_reason:null,
            references:[{label:"source",url:$url}],
            evidence_event_ids:[$evidence]
          }]
        }],
        captain_needed:[]
      }
    ' > "$path"
}

write_pr_state() {
  local path=$1 body=$2
  jq -Rn --arg body "$body" '$body' > "$path.body"
  {
    printf '%s\n' 'api_response:'
    printf '  body: %s\n' "$(cat "$path.body")"
    printf '%s\n' '  truncated: false'
  } > "$path"
}

run_intake() {
  local dir=$1 fakebin=$2 today=$3
  shift 3
  FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_GITHUB_FEEDBACK_BASE_URL='https://fixture.invalid/github-feedback' \
    FM_GITHUB_FEEDBACK_EPOCH=2026-08-04 \
    FM_GITHUB_FEEDBACK_TODAY="$today" \
    FM_GITHUB_FEEDBACK_DISABLED=0 \
    FM_TEST_CARD_DIR="$dir/cards" \
    FM_TEST_GH_DIR="$dir/gh" \
    FM_TEST_CURL_LOG="$dir/curl.log" \
    PATH="$fakebin:$PATH" \
    "$INTAKE" "$@"
}

test_fetch_failure_is_not_quiet() {
  local record dir fakebin out
  record=$(make_world fetch-failure)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF
  if out=$(FM_TEST_FETCH_FAIL_DATE=2026-08-04 run_intake "$dir" "$fakebin" 2026-08-05); then
    :
  else
    fail 'transport failure should be reported without aborting session start'
  fi
  assert_contains "$out" 'OVERNIGHT GITHUB WORK UNAVAILABLE' 'transport failure lacked a visible unavailable section'
  assert_contains "$out" 'missing input, not a quiet day' 'transport failure could be mistaken for an empty day'
  assert_not_contains "$out" $'OVERNIGHT GITHUB WORK\n\n' 'transport failure printed an actionable-work section'
  assert_absent "$dir/home/state/github-feedback-reviewed-dates" 'transport failure advanced the review record'
  pass 'fetch failure is visibly distinct from a quiet day'
}

test_multiple_unreviewed_days_surface_and_acknowledge() {
  local record dir fakebin out second
  record=$(make_world multi-day)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF
  write_ready_card "$dir/cards/2026-08-04.json" 2026-08-04 'Alpha Project' 'owner/alpha' \
    'Repair the release check' 'Correct the failing release validation.' 'The release cannot land safely.' \
    'https://github.com/owner/alpha/pull/11' 'PRC_alpha'
  write_ready_card "$dir/cards/2026-08-05.json" 2026-08-05 'Beta Project' 'owner/beta' \
    'Keep narrow navigation readable' 'Preserve labels at the compact layout.' 'Navigation becomes ambiguous on small screens.' \
    'https://github.com/owner/beta/pull/22' 'PRC_beta'
  write_pr_state "$dir/gh/owner--alpha--11.out" $'PR\tOPEN\tfalse\tfalse\tfalse'
  write_pr_state "$dir/gh/owner--beta--22.out" $'PR\tOPEN\tfalse\tfalse\tfalse'

  out=$(run_intake "$dir" "$fakebin" 2026-08-06)
  assert_contains "$out" 'Alpha Project' 'oldest unread project was not surfaced'
  assert_contains "$out" 'Repair the release check' 'oldest unread job was not surfaced'
  assert_contains "$out" 'Beta Project' 'newer unread project was not surfaced'
  assert_contains "$out" 'Keep narrow navigation readable' 'newer unread job was not surfaced'
  assert_contains "$out" 'Resolve each through the normal project workflow before marking this review complete' 'actionable output lacked the normal-lifecycle completion instruction'
  assert_contains "$(cat "$dir/home/state/github-feedback-pending-dates")" '2026-08-04' 'oldest actionable date was not pending'
  assert_contains "$(cat "$dir/home/state/github-feedback-pending-dates")" '2026-08-05' 'newer actionable date was not pending'

  run_intake "$dir" "$fakebin" 2026-08-06 acknowledge >/dev/null
  assert_contains "$(cat "$dir/home/state/github-feedback-reviewed-dates")" '2026-08-04' 'acknowledgment omitted the oldest date'
  assert_contains "$(cat "$dir/home/state/github-feedback-reviewed-dates")" '2026-08-05' 'acknowledgment omitted the newer date'
  second=$(run_intake "$dir" "$fakebin" 2026-08-06)
  [ -z "$second" ] || fail "acknowledged dates surfaced again: $second"
  pass 'multiple unread days are grouped into one dispatchable review and acknowledged exactly'
}

test_resolved_thread_is_dropped_silently() {
  local record dir fakebin out
  record=$(make_world stale-thread)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF
  write_ready_card "$dir/cards/2026-08-04.json" 2026-08-04 'Gamma Project' 'owner/gamma' \
    'Update the old review request' 'Apply the requested correction.' 'The review remains unresolved.' \
    'https://github.com/owner/gamma/pull/33' 'PRRC_stale'
  write_pr_state "$dir/gh/owner--gamma--33.out" $'PR\tOPEN\tfalse\tfalse\tfalse\nCOMMENT\tPRRC_stale\ttrue\tfalse\tfalse\tfalse'

  out=$(run_intake "$dir" "$fakebin" 2026-08-05)
  [ -z "$out" ] || fail "resolved review thread reached the output: $out"
  assert_contains "$(cat "$dir/home/state/github-feedback-reviewed-dates")" '2026-08-04' 'fully stale date was not recorded silently'
  assert_absent "$dir/home/state/github-feedback-pending-dates" 'fully stale date remained pending'
  pass 'a live card item resolved after generation is dropped silently'
}

test_fetch_failure_is_not_quiet
test_multiple_unreviewed_days_surface_and_acknowledge
test_resolved_thread_is_dropped_silently

echo '# fm-github-feedback-intake.test.sh: all assertions passed'
