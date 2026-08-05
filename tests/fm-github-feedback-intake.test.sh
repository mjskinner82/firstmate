#!/usr/bin/env bash
# Behavior tests for the retained nightly GitHub feedback consumer.
#
# Coverage:
#   - a transport failure is visible and cannot be mistaken for a quiet day
#   - transport failure on one date does not suppress later retained dates
#   - route-wide failure is bounded by the aggregate intake deadline
#   - GET-side 404 remains distinct from an unexpected response
#   - malformed or unsafe cards are rejected without advancing review state
#   - current-date cards are included and normalized-empty prose is rejected
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
is_head=0
while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      shift
      output=${1:-}
      ;;
    --write-out|--connect-timeout|--max-time)
      shift
      ;;
    --head) is_head=1 ;;
    http://*|https://*) url=$1 ;;
  esac
  shift
done
day=$(printf '%s\n' "$url" | sed -nE 's#.*/([0-9]{4}-[0-9]{2}-[0-9]{2})/card\.json$#\1#p')
[ -n "$day" ] || exit 22
printf '%s\n' "$day" >> "${FM_TEST_CURL_LOG:?}"
if [ "${FM_TEST_FETCH_FAIL_ALL:-0}" = 1 ]; then
  /bin/sleep 1.2
  printf '%s\n' 'fixture route failure' >&2
  exit 7
fi
if [ "${FM_TEST_FETCH_FAIL_DATE:-}" = "$day" ]; then
  printf '%s\n' 'fixture transport failure' >&2
  exit 7
fi
if [ "${FM_TEST_GET_404_DATE:-}" = "$day" ]; then
  if [ "$is_head" -eq 1 ]; then
    printf '200'
  else
    printf '404'
  fi
  exit 0
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
    FM_GITHUB_FEEDBACK_TOTAL_TIMEOUT="${FM_TEST_TOTAL_TIMEOUT:-20}" \
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
  if out=$(FM_TEST_FETCH_FAIL_DATE=2026-08-04 run_intake "$dir" "$fakebin" 2026-08-04); then
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

test_transport_failure_does_not_stop_catchup() {
  local record dir fakebin out
  record=$(make_world transport-catchup)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF
  write_ready_card "$dir/cards/2026-08-05.json" 2026-08-05 'Later Project' 'owner/later' \
    'Repair the later release check' 'Correct the later release validation.' 'The later release cannot land safely.' \
    'https://github.com/owner/later/pull/44' 'PRC_later'
  write_pr_state "$dir/gh/owner--later--44.out" $'PR\tOPEN\tfalse\tfalse\tfalse'

  out=$(FM_TEST_FETCH_FAIL_DATE=2026-08-04 run_intake "$dir" "$fakebin" 2026-08-05)
  assert_contains "$out" 'OVERNIGHT GITHUB WORK UNAVAILABLE' 'failed date was not reported'
  assert_contains "$out" 'Later Project' 'later retained date was suppressed by an earlier transport failure'
  assert_contains "$(cat "$dir/curl.log")" '2026-08-05' 'later retained date was not fetched'
  assert_contains "$(cat "$dir/home/state/github-feedback-pending-dates")" '2026-08-05' 'later actionable date was not pending'
  pass 'transport failure does not suppress later retained dates'
}

test_route_failure_respects_total_timeout() {
  local record dir fakebin out calls
  record=$(make_world route-timeout)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF

  out=$(FM_TEST_FETCH_FAIL_ALL=1 FM_TEST_TOTAL_TIMEOUT=1 run_intake "$dir" "$fakebin" 2026-08-08)
  assert_contains "$out" 'could not be fully fetched within the available time' 'aggregate timeout was not reported'
  calls=$(wc -l < "$dir/curl.log" | tr -d ' ')
  [ "$calls" -le 2 ] || fail "aggregate timeout allowed too many route attempts: $calls"
  assert_absent "$dir/home/state/github-feedback-reviewed-dates" 'route timeout advanced the review record'
  pass 'route-wide failure is bounded by the aggregate deadline'
}

test_get_404_is_reported_distinctly() {
  local record dir fakebin out
  record=$(make_world get-404)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF

  out=$(FM_TEST_GET_404_DATE=2026-08-04 run_intake "$dir" "$fakebin" 2026-08-04)
  assert_contains "$out" 'no completed overnight work was available for this date' 'GET-side 404 was not reported as missing input'
  assert_not_contains "$out" 'unexpected response' 'GET-side 404 was misclassified as unexpected'
  assert_absent "$dir/home/state/github-feedback-reviewed-dates" 'GET-side 404 advanced the review record'
  pass 'GET-side 404 is distinct from an unexpected response'
}

test_invalid_card_is_not_reviewed() {
  local record dir fakebin out
  record=$(make_world invalid-card)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF
  jq -n '{
    schema_version:"github-feedback-card.v1",
    card_date:"2026-08-04",
    status:"ready",
    projects:[{}],
    captain_needed:[]
  }' > "$dir/cards/2026-08-04.json"

  out=$(run_intake "$dir" "$fakebin" 2026-08-04)
  assert_contains "$out" 'did not match the required complete-card contract' 'malformed nested card was not reported as invalid'
  assert_absent "$dir/home/state/github-feedback-reviewed-dates" 'malformed card advanced the review record'
  assert_absent "$dir/home/state/github-feedback-pending-dates" 'malformed card became actionable'
  pass 'malformed nested card is rejected without review acknowledgment'
}

test_empty_ready_card_is_not_reviewed() {
  local record dir fakebin out
  record=$(make_world empty-ready-card)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF
  jq -n '{
    schema_version:"github-feedback-card.v1",
    card_date:"2026-08-04",
    status:"ready",
    projects:[],
    captain_needed:[]
  }' > "$dir/cards/2026-08-04.json"

  out=$(run_intake "$dir" "$fakebin" 2026-08-04)
  assert_contains "$out" 'did not match the required complete-card contract' 'empty ready card was not reported as invalid'
  assert_absent "$dir/home/state/github-feedback-reviewed-dates" 'empty ready card advanced the review record'
  pass 'empty ready card is rejected without review acknowledgment'
}

test_unsafe_prose_is_rejected_without_echo() {
  local record dir fakebin out unsafe
  record=$(make_world unsafe-prose)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF
  unsafe='Run fm-spawn for PR #71 at https://github.com/owner/unsafe/pull/71'
  write_ready_card "$dir/cards/2026-08-04.json" 2026-08-04 'Unsafe Project' 'owner/unsafe' \
    "$unsafe" 'Apply the requested correction.' 'The release cannot land safely.' \
    'https://github.com/owner/unsafe/pull/71' 'PRC_unsafe'

  out=$(run_intake "$dir" "$fakebin" 2026-08-04)
  assert_contains "$out" 'did not match the required complete-card contract' 'unsafe visible prose was not rejected'
  assert_not_contains "$out" "$unsafe" 'unsafe visible prose was echoed'
  assert_not_contains "$out" 'PR #71' 'a GitHub identifier leaked from rejected prose'
  assert_absent "$dir/home/state/github-feedback-reviewed-dates" 'unsafe card advanced the review record'
  pass 'unsafe prose is rejected without leaking identifiers or mechanics'
}

test_current_date_card_is_included() {
  local record dir fakebin out
  record=$(make_world current-date)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF
  write_ready_card "$dir/cards/2026-08-04.json" 2026-08-04 'Current Project' 'owner/current' \
    'Repair the current release check' 'Correct the current release validation.' 'The current release cannot land safely.' \
    'https://github.com/owner/current/pull/72' 'PRC_current'
  write_pr_state "$dir/gh/owner--current--72.out" $'PR\tOPEN\tfalse\tfalse\tfalse'

  out=$(run_intake "$dir" "$fakebin" 2026-08-04)
  assert_contains "$out" 'Current Project' 'current-date project was not surfaced'
  assert_contains "$(cat "$dir/home/state/github-feedback-pending-dates")" '2026-08-04' 'current date was not pending'
  pass 'current-date retained card is included'
}

test_normalized_empty_prose_is_rejected() {
  local record dir fakebin out invisible
  record=$(make_world normalized-empty)
  IFS='|' read -r dir fakebin <<EOF
$record
EOF
  invisible=$' \t\u2063\n '
  write_ready_card "$dir/cards/2026-08-04.json" 2026-08-04 'Invisible Project' 'owner/invisible' \
    "$invisible" 'Apply the requested correction.' 'The release cannot land safely.' \
    'https://github.com/owner/invisible/pull/73' 'PRC_invisible'

  out=$(run_intake "$dir" "$fakebin" 2026-08-04)
  assert_contains "$out" 'did not match the required complete-card contract' 'normalized-empty prose was not rejected'
  assert_not_contains "$out" 'OVERNIGHT GITHUB WORK'$'\n\n' 'normalized-empty prose produced a work section'
  assert_absent "$dir/home/state/github-feedback-reviewed-dates" 'normalized-empty card advanced the review record'
  pass 'normalized-empty visible prose is rejected'
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

  out=$(run_intake "$dir" "$fakebin" 2026-08-05)
  assert_contains "$out" 'Alpha Project' 'oldest unread project was not surfaced'
  assert_contains "$out" 'Repair the release check' 'oldest unread job was not surfaced'
  assert_contains "$out" 'Beta Project' 'newer unread project was not surfaced'
  assert_contains "$out" 'Keep narrow navigation readable' 'newer unread job was not surfaced'
  assert_contains "$out" 'Every item above remains current and needs resolution' 'actionable output lacked outcome-only resolution wording'
  assert_not_contains "$out" 'workflow' 'actionable output exposed internal workflow mechanics'
  assert_contains "$(cat "$dir/home/state/github-feedback-pending-dates")" '2026-08-04' 'oldest actionable date was not pending'
  assert_contains "$(cat "$dir/home/state/github-feedback-pending-dates")" '2026-08-05' 'newer actionable date was not pending'

  run_intake "$dir" "$fakebin" 2026-08-05 acknowledge >/dev/null
  assert_contains "$(cat "$dir/home/state/github-feedback-reviewed-dates")" '2026-08-04' 'acknowledgment omitted the oldest date'
  assert_contains "$(cat "$dir/home/state/github-feedback-reviewed-dates")" '2026-08-05' 'acknowledgment omitted the newer date'
  second=$(run_intake "$dir" "$fakebin" 2026-08-05)
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

  out=$(run_intake "$dir" "$fakebin" 2026-08-04)
  [ -z "$out" ] || fail "resolved review thread reached the output: $out"
  assert_contains "$(cat "$dir/home/state/github-feedback-reviewed-dates")" '2026-08-04' 'fully stale date was not recorded silently'
  assert_absent "$dir/home/state/github-feedback-pending-dates" 'fully stale date remained pending'
  pass 'a live card item resolved after generation is dropped silently'
}

test_fetch_failure_is_not_quiet
test_transport_failure_does_not_stop_catchup
test_route_failure_respects_total_timeout
test_get_404_is_reported_distinctly
test_invalid_card_is_not_reviewed
test_empty_ready_card_is_not_reviewed
test_unsafe_prose_is_rejected_without_echo
test_current_date_card_is_included
test_normalized_empty_prose_is_rejected
test_multiple_unreviewed_days_surface_and_acknowledge
test_resolved_thread_is_dropped_silently

echo '# fm-github-feedback-intake.test.sh: all assertions passed'
