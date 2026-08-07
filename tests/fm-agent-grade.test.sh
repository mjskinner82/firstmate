#!/usr/bin/env bash
# End-to-end tests for maintenance-agent grade recording and scoreboard math.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GRADE="$ROOT/bin/fm-agent-grade.sh"
TMP_ROOT=$(fm_test_tmproot fm-agent-grade)

ledger_for() {  # <home>
  printf '%s/data/maintenance-agent-grades/events.jsonl\n' "$1"
}

test_report_math_and_filter() {
  local home ledger out filtered alpha_line
  home="$TMP_ROOT/report"
  ledger=$(ledger_for "$home")
  mkdir -p "$(dirname "$ledger")"
  cat > "$ledger" <<'EOF'
{"agent":"alpha-cleaner","task_id":"alpha-1","pr_url":"https://github.com/example/repo/pull/1","outcome":"merged_clean","false_positive_labels":[],"timestamp":"2026-08-01T00:00:00Z","note":""}
{"agent":"alpha-cleaner","task_id":"alpha-2","pr_url":"https://github.com/example/repo/pull/2","outcome":"merged_changed","false_positive_labels":["generated-path"],"timestamp":"2026-08-02T00:00:00Z","note":"review changed one candidate"}
{"agent":"alpha-cleaner","task_id":"alpha-3","pr_url":"https://github.com/example/repo/pull/3","outcome":"rejected","false_positive_labels":["live-symbol","external-reference"],"timestamp":"2026-08-03T00:00:00Z","note":""}
{"agent":"alpha-cleaner","task_id":"alpha-4","pr_url":"","outcome":"pending","false_positive_labels":[],"timestamp":"2026-08-04T00:00:00Z","note":""}
{"agent":"alpha-cleaner","task_id":"alpha-5","pr_url":"https://github.com/example/repo/pull/5","outcome":"closed","false_positive_labels":["stale-flag"],"timestamp":"2026-08-05T00:00:00Z","note":"closed for overlap"}
{"agent":"beta-cleaner","task_id":"beta-1","pr_url":"https://github.com/example/repo/pull/4","outcome":"closed","false_positive_labels":[],"timestamp":"2026-08-05T00:00:00Z","note":"duplicate work"}
EOF

  out=$(FM_HOME="$home" "$GRADE" report) || fail "report rejected a valid fixture ledger"
  alpha_line=$(printf '%s\n' "$out" | grep '^alpha-cleaner ')
  assert_contains "$alpha_line" "5" "alpha run count was wrong"
  assert_contains "$alpha_line" "40.0% (2/5)" "alpha merge rate was wrong"
  assert_contains "$alpha_line" "50.0% (1/2)" "alpha changed-on-merge rate was wrong"
  assert_contains "$alpha_line" "20.0% (1/5)" "alpha rejected rate was wrong"
  assert_contains "$alpha_line" "60.0% (3/5)" "alpha false-positive rate was wrong"
  assert_contains "$out" "beta-cleaner" "per-agent report omitted beta"

  filtered=$(FM_HOME="$home" "$GRADE" report --agent alpha-cleaner) \
    || fail "filtered report failed"
  assert_contains "$filtered" "alpha-cleaner" "filtered report omitted selected agent"
  assert_not_contains "$filtered" "beta-cleaner" "filtered report included another agent"
  pass "report computes per-agent rates with the documented denominators"
}

test_record_writes_valid_private_row() {
  local home ledger out
  home="$TMP_ROOT/record"
  ledger=$(ledger_for "$home")
  out=$(FM_HOME="$home" "$GRADE" record dead-code-cleanup task-42 \
    --pr https://github.com/example/repo/pull/42 \
    --outcome merged_changed \
    --false-positive generated-path \
    --note "review removed one candidate") \
    || fail "record rejected valid inputs"
  assert_contains "$out" "recorded: dead-code-cleanup task-42 merged_changed" \
    "record confirmation was unclear"
  python3 - "$ledger" <<'PY' || fail "record did not append the expected valid JSON row"
import json
import re
import sys
from pathlib import Path

rows = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
assert len(rows) == 1
row = json.loads(rows[0])
assert list(row) == [
    "agent",
    "task_id",
    "pr_url",
    "outcome",
    "false_positive_labels",
    "timestamp",
    "note",
]
assert row["agent"] == "dead-code-cleanup"
assert row["task_id"] == "task-42"
assert row["pr_url"] == "https://github.com/example/repo/pull/42"
assert row["outcome"] == "merged_changed"
assert row["false_positive_labels"] == ["generated-path"]
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", row["timestamp"])
assert row["note"] == "review removed one candidate"
PY
  pass "record appends the exact validated JSONL contract"
}

test_record_refuses_invalid_input_and_duplicates() {
  local home ledger before after rc
  home="$TMP_ROOT/invalid-input"
  ledger=$(ledger_for "$home")
  FM_HOME="$home" "$GRADE" record test-coverage task-1 --outcome merged_clean >/dev/null \
    || fail "valid baseline record failed"
  before=$(wc -l < "$ledger" | tr -d ' ')

  set +e
  FM_HOME="$home" "$GRADE" record 'bad agent' task-2 --outcome merged_clean >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "record accepted an unsafe agent name"

  set +e
  FM_HOME="$home" "$GRADE" record test-coverage task-2 --pr not-a-url >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "record accepted a malformed PR URL"

  set +e
  FM_HOME="$home" "$GRADE" record test-coverage task-2 --outcome almost-merged >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "record accepted an unknown outcome"

  set +e
  FM_HOME="$home" "$GRADE" record test-coverage task-2 \
    --false-positive 'private prose label' >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "record accepted an unsafe false-positive label"

  set +e
  FM_HOME="$home" "$GRADE" record test-coverage task-1 --outcome rejected >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "record accepted a duplicate agent/task pair"

  after=$(wc -l < "$ledger" | tr -d ' ')
  [ "$after" = "$before" ] || fail "invalid record attempts changed the ledger"
  pass "record refuses unsafe inputs and duplicate run rows without appending"
}

test_malformed_ledger_refuses_record_and_report() {
  local home ledger before after rc
  home="$TMP_ROOT/malformed-ledger"
  ledger=$(ledger_for "$home")
  mkdir -p "$(dirname "$ledger")"
  printf '%s\n' '{"agent":"missing-fields"}' > "$ledger"
  before=$(shasum -a 256 "$ledger" | awk '{print $1}')

  set +e
  FM_HOME="$home" "$GRADE" report > "$home/report.out" 2> "$home/report.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "report silently accepted a malformed ledger row"
  assert_grep "malformed ledger row at line 1" "$home/report.err" \
    "report did not identify the malformed row"

  set +e
  FM_HOME="$home" "$GRADE" record abstraction-police task-9 --outcome rejected \
    > "$home/record.out" 2> "$home/record.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "record appended after a malformed ledger row"
  after=$(shasum -a 256 "$ledger" | awk '{print $1}')
  [ "$after" = "$before" ] || fail "record changed a malformed ledger"
  pass "malformed rows fail closed for both report and record"
}

test_report_math_and_filter
test_record_writes_valid_private_row
test_record_refuses_invalid_input_and_duplicates
test_malformed_ledger_refuses_record_and_report
