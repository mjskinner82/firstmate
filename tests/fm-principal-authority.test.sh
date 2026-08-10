#!/usr/bin/env bash
# Behavioral regression for the dual-principal authority and receipt lifecycle.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$ROOT/bin/fm-principal-authority.sh"
SESSION_CMD="$ROOT/bin/fm-principal-session-authority.sh"
SESSION_INTERRUPT_DRIVER="$ROOT/tests/fm-principal-authority-session-driver.mjs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-principal-authority.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
NOW=2026-08-10T04:00:00.000Z

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

run() {
  local home=$1
  shift
  FM_HOME="$home" FM_PRINCIPAL_NOW="$NOW" "$CMD" "$@"
}

run_session() {
  local home=$1
  shift
  FM_HOME="$home" FM_PRINCIPAL_NOW="$NOW" "$SESSION_CMD" "$@"
}

run_interrupted_session() {
  local home=$1
  shift
  FM_HOME="$home" FM_PRINCIPAL_NOW="$NOW" node "$SESSION_INTERRUPT_DRIVER" "$@"
}

setup_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state"
  cat > "$home/config/principal-authority.json" <<'JSON'
{
  "schema": "fm-principal-authority-config.v1",
  "captain_sources": [
    {"identity": "matt", "channel": "codex"}
  ],
  "mercury_sources": [
    {"identity": "mercury", "key_id": "mercury-firstmate-hmac-v1"}
  ]
}
JSON
  chmod 600 "$home/config/principal-authority.json"
  : > "$home/state/hermes-ingress.events.jsonl"
  chmod 600 "$home/state/hermes-ingress.events.jsonl"
}

sha256_text() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

append_mercury() { # <home> <task-id> <event-seed> <idempotency> <objective>
  local home=$1 task_id=$2 event_seed=$3 idempotency=$4 objective=$5
  local acceptance payload payload_hash event_id
  acceptance='["Observable behavior is covered by focused tests.","The durable receipt remains available after restart."]'
  payload=$(jq -cnSa \
    --arg caller mercury \
    --arg idempotency "$idempotency" \
    --arg objective "$objective" \
    --arg priority high \
    --arg repository firstmate \
    --arg channel telegram \
    --arg conversation 8617707440 \
    --arg message "$event_seed" \
    --arg created_at "2026-08-10T03:38:26.944Z" \
    --arg event_id "$(sha256_text "$event_seed")" \
    --arg event_type mercury_engineering_assignment \
    --arg identity_key_id mercury-firstmate-hmac-v1 \
    --arg task_id "$task_id" \
    --argjson acceptance "$acceptance" \
    '{acceptance_criteria:$acceptance,caller_identity:$caller,created_at:$created_at,event_id:$event_id,event_type:$event_type,idempotency_key:$idempotency,identity_key_id:$identity_key_id,objective:$objective,priority:$priority,repository_ref:$repository,source_channel:$channel,source_conversation_ref:$conversation,source_message_ref:$message,task_id:$task_id}')
  payload_hash=$(sha256_text "$payload")
  event_id=$(sha256_text "$event_seed")
  jq -cn \
    --argjson acceptance "$acceptance" \
    --arg payload_hash "$payload_hash" \
    --arg event_id "$event_id" \
    --arg task_id "$task_id" \
    --arg idempotency "$idempotency" \
    --arg objective "$objective" \
    --arg message "$event_seed" \
    '{acceptance_criteria:$acceptance,assignment_payload_hash:$payload_hash,authenticated_caller:"mercury",created_at:"2026-08-10T03:38:26.944Z",event_id:$event_id,event_type:"mercury_engineering_assignment",idempotency_key:$idempotency,identity_key_id:"mercury-firstmate-hmac-v1",objective:$objective,priority:"high",repository_ref:"firstmate",source_channel:"telegram",source_conversation_ref:"8617707440",source_message_ref:$message,task_id:$task_id}' \
    >> "$home/state/hermes-ingress.events.jsonl"
}

status_task() {
  local home=$1 task_id=$2
  run "$home" status --task-id "$task_id"
}

assert_task_state() {
  local home=$1 task_id=$2 expected=$3 json
  json=$(status_task "$home" "$task_id")
  [ "$(printf '%s' "$json" | jq -r '.task.state')" = "$expected" ] \
    || fail "task $task_id expected state $expected"
}

setup_running_task() { # <home> <task-id> <event-seed> <idempotency> <objective>
  local home=$1 task_id=$2 event_seed=$3 idempotency=$4 objective=$5
  setup_home "$home"
  append_mercury "$home" "$task_id" "$event_seed" "$idempotency" "$objective"
  run "$home" ingest >/dev/null
  run "$home" accept \
    --task-id "$task_id" \
    --decision-key "${idempotency}-accept" \
    --owner fm/constraint-worker \
    --assessment 'No higher boundary applies to the initial reversible assignment.' \
    --boundaries none >/dev/null
  run "$home" transition \
    --task-id "$task_id" \
    --transition-key "${idempotency}-running" \
    --to running >/dev/null
}

HOME_ONE="$TMP_ROOT/ordinary"
setup_home "$HOME_ONE"
TASK_ONE=11111111-1111-4111-8111-111111111111
OBJECTIVE_ONE='Implement a reversible parser correction with focused tests.'
append_mercury "$HOME_ONE" "$TASK_ONE" ordinary-event ordinary-v1 "$OBJECTIVE_ONE"

SUMMARY=$(run "$HOME_ONE" ingest)
printf '%s' "$SUMMARY" | jq -e '.new_tasks == 1 and .delivered == 1 and .pending == 1' >/dev/null \
  || fail "authenticated Mercury ingress summary was wrong: $SUMMARY"
STATUS=$(status_task "$HOME_ONE" "$TASK_ONE")
printf '%s' "$STATUS" | jq -e '
  .task.state == "delivered" and
  .task.source_identity == {
    principal:"mercury",
    identity:"mercury",
    identity_key_id:"mercury-firstmate-hmac-v1",
    identity_verified:true,
    verification:"upstream-hmac-and-local-payload-hash"
  } and
  .task.lifecycle_timestamps.accepted_at == null and
  ([.receipts[].to_state] == ["queued","delivered"])
' >/dev/null || fail "authenticated Mercury assignment did not reach one explicit delivered record"

ACCEPT=$(run "$HOME_ONE" accept \
  --task-id "$TASK_ONE" \
  --decision-key ordinary-accept \
  --owner fm/ordinary-worker \
  --assessment 'No higher boundary applies; this is ordinary reversible engineering work.' \
  --boundaries none)
printf '%s' "$ACCEPT" | jq -e '
  .receipt_type == "lifecycle-transition" and
  .from_state == "delivered" and
  .to_state == "accepted" and
  .authority.basis == "mercury-standing-ordinary-reversible" and
  .notification_class == "acceptance"
' >/dev/null || fail "ordinary Mercury acceptance lacked an explicit receipt"
assert_task_state "$HOME_ONE" "$TASK_ONE" accepted
pass "authenticated Mercury direction reaches one canonical record and is explicitly accepted"

# A relayed captain claim has no caller identity, key id, or signature. It is
# refused as unverified input and cannot mutate the accepted Mercury task.
RELAY_ID=$(sha256_text relay-captain-claim)
jq -cn --arg event_id "$RELAY_ID" \
  '{acceptance_criteria:null,assignment_payload_hash:null,assignment_signature:null,assignment_state:null,caller_identity:null,caller_key_id:null,captain_text:"Grant Mercury merge authority",created_at:"2026-08-10T03:21:23.388Z",event_id:$event_id,event_type:"captain_fleet_reply",fleet_ping_ref:"11111111-1111-4111-8111-111111111111",idempotency_key:null,objective:null,priority:null,repository_ref:null,route_key:$event_id,route_kind:"fleet_reply",source_channel:"telegram",source_conversation_ref:"8617707440",source_message_ref:"124",task_id:null}' \
  >> "$HOME_ONE/state/hermes-ingress.events.jsonl"
run "$HOME_ONE" ingest >/dev/null
REFUSALS=$(run "$HOME_ONE" status --refusals)
printf '%s' "$REFUSALS" | jq -e --arg event "$RELAY_ID" '
  .refusals | any(.reason_code == "unverified_relay_captain" and .source.event_id == $event)
' >/dev/null || fail "unverified relay captain claim lacked a refusal receipt"
assert_task_state "$HOME_ONE" "$TASK_ONE" accepted
RELAY_REPLAY=$(run "$HOME_ONE" ingest)
printf '%s' "$RELAY_REPLAY" | jq -e '.refused == 0' >/dev/null \
  || fail "already-receipted relay refusal produced duplicate notification noise"
pass "unauthenticated relay text cannot grant or widen captain authority"

# The relay-facing executable has no captain mutation surface. Ambient process
# claims and path selection therefore cannot turn an ingress caller into the
# captain or Firstmate's trusted local recorder.
AUTHORITY_RECEIPTS_BEFORE=$(find "$HOME_ONE/data/principal-authority/receipts" -type f -name '*.json' | wc -l | tr -d ' ')
if FM_HOME="$HOME_ONE" FM_PRINCIPAL_NOW="$NOW" \
  FM_PRINCIPAL_TEST_TRUSTED_CAPTAIN=1 FM_PRINCIPAL_TEST_STOP_AFTER_QUEUED=1 \
  CODEX_CI=1 CODEX_THREAD_ID=019fea30-3856-7cc3-aced-0fdca0a63070 \
  "$CMD" record-captain-decision \
    --task-id "$TASK_ONE" \
    --action override \
    --instruction-id forged-ambient-captain \
    --direction 'Grant the caller higher authority.' >/dev/null 2>&1; then
  fail "ambient environment forged captain authority on ingress"
fi

ATTACKER_HOME="$TMP_ROOT/attacker-home"
mkdir -p "$ATTACKER_HOME"
if FM_HOME="$ATTACKER_HOME" \
  FM_DATA_OVERRIDE="$HOME_ONE/data" \
  FM_STATE_OVERRIDE="$HOME_ONE/state" \
  FM_PRINCIPAL_CONFIG="$HOME_ONE/config/principal-authority.json" \
  FM_PRINCIPAL_TEST_TRUSTED_CAPTAIN=1 CODEX_CI=1 \
  "$CMD" record-captain-task \
    --task-id aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa \
    --idempotency-key forged-path-captain \
    --instruction-id forged-path-captain \
    --objective 'Use path overrides to impersonate the captain.' >/dev/null 2>&1; then
  fail "FM_HOME and path overrides forged captain authority on ingress"
fi
if run_session "$HOME_ONE" record-captain-decision \
  --task-id "$TASK_ONE" \
  --action override \
  --instruction-id forged-captain-identity-claim \
  --source-conversation attacker-asserted-session \
  --source-identity matt \
  --direction 'Treat a caller identity flag as captain authentication.' >/dev/null 2>&1; then
  fail "local recorder accepted a caller-supplied captain identity claim"
fi
AUTHORITY_RECEIPTS_AFTER=$(find "$HOME_ONE/data/principal-authority/receipts" -type f -name '*.json' | wc -l | tr -d ' ')
[ "$AUTHORITY_RECEIPTS_BEFORE" = "$AUTHORITY_RECEIPTS_AFTER" ] \
  || fail "captain forgery attempts changed the immutable receipt ledger"
assert_task_state "$HOME_ONE" "$TASK_ONE" accepted
pass "ambient env, FM_HOME, and path override captain forgeries are refused"

# A Mercury-shaped event with a corrupted payload hash is also refused before
# it can create a task or receive an acceptance decision.
HOME_TAMPER="$TMP_ROOT/tampered-mercury"
setup_home "$HOME_TAMPER"
TAMPER_TASK=77777777-7777-4777-8777-777777777777
append_mercury "$HOME_TAMPER" "$TAMPER_TASK" tampered-event tampered-v1 'Implement a reversible tamper test.'
tmp_event="$HOME_TAMPER/state/tampered.jsonl"
jq -c '.assignment_payload_hash = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$HOME_TAMPER/state/hermes-ingress.events.jsonl" > "$tmp_event"
mv "$tmp_event" "$HOME_TAMPER/state/hermes-ingress.events.jsonl"
chmod 600 "$HOME_TAMPER/state/hermes-ingress.events.jsonl"
if run "$HOME_TAMPER" ingest >/dev/null 2>&1; then
  fail "tampered Mercury payload was accepted"
fi
run "$HOME_TAMPER" status --refusals | jq -e '
  .refusals | any(.reason_code == "mercury_identity_rejected")
' >/dev/null || fail "tampered Mercury payload lacked a durable refusal receipt"
[ ! -e "$HOME_TAMPER/data/principal-authority/tasks/$TAMPER_TASK.json" ] \
  || fail "tampered Mercury payload created a canonical task"
pass "Mercury caller, key id, and canonical payload integrity are all required"

HOME_TAMPER_TASK="$TMP_ROOT/tampered-mercury-task"
setup_home "$HOME_TAMPER_TASK"
TAMPER_TASK_ORIGINAL=99999999-9999-4999-8999-999999999999
append_mercury "$HOME_TAMPER_TASK" "$TAMPER_TASK_ORIGINAL" tampered-task-event tampered-task-v1 'Implement another reversible tamper test.'
tampered_task_event="$HOME_TAMPER_TASK/state/tampered-task.jsonl"
jq -c '.task_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"' \
  "$HOME_TAMPER_TASK/state/hermes-ingress.events.jsonl" > "$tampered_task_event"
mv "$tampered_task_event" "$HOME_TAMPER_TASK/state/hermes-ingress.events.jsonl"
chmod 600 "$HOME_TAMPER_TASK/state/hermes-ingress.events.jsonl"
if run "$HOME_TAMPER_TASK" ingest >/dev/null 2>&1; then
  fail "Mercury task identity changed without invalidating payload integrity"
fi
[ ! -e "$HOME_TAMPER_TASK/data/principal-authority/tasks/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json" ] \
  || fail "tampered Mercury task identity created a canonical task"
pass "Mercury integrity covers identity, provenance, deduplication, and lifecycle fields"

# Every named higher boundary is an explicit Firstmate assessment that holds
# the task for a direct captain decision without inventing acceptance.
HOME_BOUNDARY="$TMP_ROOT/boundaries"
setup_home "$HOME_BOUNDARY"
BOUNDARIES='financial-transaction outward-facing-creation private-data-migration destructive irreversible security-sensitive remote-access identity-change secret-disclosure pr-merge'
index=1
for boundary in $BOUNDARIES; do
  suffix=$(printf '%012d' "$index")
  task_id="22222222-2222-4222-8222-$suffix"
  append_mercury "$HOME_BOUNDARY" "$task_id" "boundary-$boundary" "boundary-$boundary-v1" "Perform work touching $boundary."
  index=$((index + 1))
done
run "$HOME_BOUNDARY" ingest >/dev/null
index=1
for boundary in $BOUNDARIES; do
  suffix=$(printf '%012d' "$index")
  task_id="22222222-2222-4222-8222-$suffix"
  HOLD=$(run "$HOME_BOUNDARY" hold \
    --task-id "$task_id" \
    --decision-key "hold-$boundary" \
    --boundaries "$boundary" \
    --reason "The $boundary boundary requires direct captain authority.")
  printf '%s' "$HOLD" | jq -e --arg boundary "$boundary" '
    .from_state == "delivered" and .to_state == "blocked" and
    .authority.basis == "captain-required-higher-boundary" and
    (.authority.boundaries == [$boundary]) and
    .notification_class == "captain-decision"
  ' >/dev/null || fail "boundary $boundary was not held with an explicit receipt"
  STATUS=$(status_task "$HOME_BOUNDARY" "$task_id")
  printf '%s' "$STATUS" | jq -e --arg boundary "$boundary" '
    .task.state == "blocked" and
    .task.lifecycle_timestamps.accepted_at == null and
    (.task.authority.captain_required_boundaries == [$boundary])
  ' >/dev/null || fail "boundary $boundary gained inferred acceptance"
  index=$((index + 1))
done
pass "all higher boundaries hold Mercury work for the captain"

if run "$HOME_BOUNDARY" hold \
  --task-id 22222222-2222-4222-8222-000000000002 \
  --decision-key hold-financial-transaction \
  --boundaries outward-facing-creation \
  --reason 'The outward-facing-creation boundary requires direct captain authority.' >/dev/null 2>&1; then
  fail "hold decision key replayed successfully for another task"
fi
pass "authority decision replays are bound to one normalized operation"

BOOTSTRAP_OUT=$(FM_HOME="$HOME_BOUNDARY" FM_BACKEND=tmux FM_PRINCIPAL_NOW="$NOW" FM_BOOTSTRAP_NETWORK=skip \
  "$ROOT/bin/fm-bootstrap.sh")
case "$BOOTSTRAP_OUT" in
  *"PRINCIPAL_INGRESS: 10 authenticated direction(s) await explicit authority and lifecycle disposition"*) ;;
  *) fail "locked bootstrap did not surface the durable principal disposition work" ;;
esac
pass "locked startup consumes principal ingress and surfaces pending authority work"

CAPTAIN_APPROVED=22222222-2222-4222-8222-000000000001
run_session "$HOME_BOUNDARY" record-captain-decision \
  --task-id "$CAPTAIN_APPROVED" \
  --action override \
  --instruction-id captain-financial-approval \
  --source-conversation captain-boundary-session \
  --direction 'Authorize this exact financial-transaction boundary for the named task only.' \
  --authorized-boundaries financial-transaction \
  --owner fm/captain-approved-worker >/dev/null
STATUS=$(status_task "$HOME_BOUNDARY" "$CAPTAIN_APPROVED")
printf '%s' "$STATUS" | jq -e '
  .task.state == "accepted" and
  .task.authority.basis == "captain-direct" and
  .task.authority.captain_required_boundaries == [] and
  .task.authority.captain_authorized_boundaries == ["financial-transaction"] and
  .task.effective_instruction.principal == "captain"
' >/dev/null || fail "direct captain instruction did not explicitly clear the exact held boundary"
pass "only direct captain direction can clear a held higher boundary"

CAPTAIN_CANCELLED_HELD=22222222-2222-4222-8222-000000000010
run_session "$HOME_BOUNDARY" record-captain-decision \
  --task-id "$CAPTAIN_CANCELLED_HELD" \
  --action cancel \
  --instruction-id captain-cancel-held \
  --source-conversation captain-boundary-session \
  --direction 'Cancel this held objective.' >/dev/null
run "$HOME_BOUNDARY" status --pending | jq -e --arg task "$CAPTAIN_CANCELLED_HELD" '
  [.tasks[].task_id] | index($task) == null
' >/dev/null || fail "cancelled held task remained in the pending projection"
pass "captain cancellation resolves higher-boundary pending status"

# No delivery, process, or forge activity can substitute for acceptance.
UNACCEPTED=33333333-3333-4333-8333-333333333333
append_mercury "$HOME_ONE" "$UNACCEPTED" no-inferred-accept no-inferred-accept-v1 'Prepare another ordinary reversible correction.'
run "$HOME_ONE" ingest >/dev/null
if run "$HOME_ONE" accept \
  --task-id "$UNACCEPTED" \
  --decision-key ordinary-accept \
  --owner fm/ordinary-worker \
  --assessment 'No higher boundary applies; this is ordinary reversible engineering work.' \
  --boundaries none >/dev/null 2>&1; then
  fail "acceptance decision key replayed successfully for another task"
fi
if run "$HOME_ONE" transition \
  --task-id "$UNACCEPTED" \
  --transition-key illegal-running \
  --to running >/dev/null 2>&1; then
  fail "running was inferred without an acceptance receipt"
fi
assert_task_state "$HOME_ONE" "$UNACCEPTED" delivered
pass "acceptance is never inferred from delivery or unrelated activity"

# Exercise explicit running, blocked, resumed, and completed transitions.
run "$HOME_ONE" transition --task-id "$TASK_ONE" --transition-key ordinary-running --to running >/dev/null
run "$HOME_ONE" transition \
  --task-id "$TASK_ONE" \
  --transition-key ordinary-blocked \
  --to blocked \
  --reason 'A focused test fixture is unavailable.' >/dev/null
run "$HOME_ONE" transition --task-id "$TASK_ONE" --transition-key ordinary-resumed --to running >/dev/null

# A direct, allowlisted captain instruction always supersedes the current
# Mercury instruction and leaves a content-addressed immutable receipt.
CAPTAIN_RECEIPT=$(run_session "$HOME_ONE" record-captain-decision \
  --task-id "$TASK_ONE" \
  --action narrow \
  --instruction-id captain-narrow-1 \
  --source-conversation captain-precedence-session \
  --direction 'Keep the change limited to parser behavior and its focused tests.' \
  --supersedes "$(sha256_text ordinary-event)")
CAPTAIN_ID=$(printf '%s' "$CAPTAIN_RECEIPT" | jq -r '.receipt_id')
CAPTAIN_FILE="$HOME_ONE/data/principal-authority/receipts/$CAPTAIN_ID.json"
CAPTAIN_MODE=$(stat -f %Lp "$CAPTAIN_FILE" 2>/dev/null || stat -c %a "$CAPTAIN_FILE")
[ "$CAPTAIN_MODE" = 400 ] || fail "immutable captain receipt mode was $CAPTAIN_MODE instead of 400"
BEFORE_HASH=$(shasum -a 256 "$CAPTAIN_FILE" | awk '{print $1}')
printf '%s' "$CAPTAIN_RECEIPT" | jq -e --arg supersedes "$(sha256_text ordinary-event)" '
  .receipt_type == "captain-directive" and
  .authority.basis == "captain-direct" and
  .authority.action == "narrow" and
  .supersedes_instruction_id == $supersedes
' >/dev/null || fail "captain precedence receipt did not link the superseded Mercury instruction"

# A later Mercury assignment for the same objective is preserved as a refused
# duplicate and cannot take precedence or create a second task.
DUPLICATE_TASK=44444444-4444-4444-8444-444444444444
append_mercury "$HOME_ONE" "$DUPLICATE_TASK" duplicate-objective duplicate-objective-v2 "$OBJECTIVE_ONE"
run "$HOME_ONE" ingest >/dev/null
STATUS=$(status_task "$HOME_ONE" "$TASK_ONE")
printf '%s' "$STATUS" | jq -e '
  .task.effective_instruction.principal == "captain" and
  .task.effective_instruction.instruction_id == "captain-narrow-1" and
  (.receipts | any(.receipt_type == "duplicate-objective-refused"))
' >/dev/null || fail "later Mercury input displaced captain precedence"
[ "$(find "$HOME_ONE/data/principal-authority/tasks" -type f -name '*.json' | wc -l | tr -d ' ')" = 2 ] \
  || fail "same objective produced a duplicate task record"
AFTER_HASH=$(shasum -a 256 "$CAPTAIN_FILE" | awk '{print $1}')
[ "$BEFORE_HASH" = "$AFTER_HASH" ] || fail "captain precedence receipt changed after later ingress"
pass "captain direction has absolute precedence with an immutable supersession receipt"

run "$HOME_ONE" hold \
  --task-id "$TASK_ONE" \
  --decision-key pause-independent-hold \
  --boundaries financial-transaction \
  --reason 'The financial-transaction boundary requires direct captain authority.' >/dev/null
run_session "$HOME_ONE" record-captain-decision \
  --task-id "$TASK_ONE" \
  --action pause \
  --instruction-id captain-pause-1 \
  --source-conversation captain-precedence-session \
  --direction 'Pause this objective until I explicitly resume it.' \
  --supersedes captain-narrow-1 >/dev/null
if run "$HOME_ONE" transition \
  --task-id "$TASK_ONE" \
  --transition-key bypass-captain-pause \
  --to running >/dev/null 2>&1; then
  fail "ordinary lifecycle transition bypassed an effective captain pause"
fi
STATUS=$(status_task "$HOME_ONE" "$TASK_ONE")
printf '%s' "$STATUS" | jq -e '
  .task.state == "blocked" and
  .task.effective_instruction.instruction_id == "captain-pause-1" and
  .task.authority.captain_required_boundaries == ["financial-transaction"] and
  (.task.blockers | map(.kind) == ["captain-approval", "captain-pause"])
' >/dev/null || fail "rejected lifecycle transition did not preserve the captain pause"
run_session "$HOME_ONE" record-captain-decision \
  --task-id "$TASK_ONE" \
  --action narrow \
  --instruction-id captain-resume-1 \
  --source-conversation captain-precedence-session \
  --direction 'Resume within the previously narrowed parser scope.' \
  --supersedes captain-pause-1 >/dev/null
STATUS=$(status_task "$HOME_ONE" "$TASK_ONE")
printf '%s' "$STATUS" | jq -e '
  .task.state == "blocked" and
  .task.effective_instruction.instruction_id == "captain-resume-1" and
  .task.authority.captain_required_boundaries == ["financial-transaction"] and
  (.task.blockers | map(.kind) == ["captain-approval"])
' >/dev/null || fail "captain pause resumption cleared an unauthorized higher-boundary hold"
run_session "$HOME_ONE" record-captain-decision \
  --task-id "$TASK_ONE" \
  --action override \
  --instruction-id captain-authorize-held-resume-1 \
  --source-conversation captain-precedence-session \
  --direction 'Authorize this exact financial-transaction boundary and resume the task.' \
  --authorized-boundaries financial-transaction \
  --supersedes captain-resume-1 >/dev/null
STATUS=$(status_task "$HOME_ONE" "$TASK_ONE")
printf '%s' "$STATUS" | jq -e '
  .task.state == "running" and
  .task.effective_instruction.instruction_id == "captain-authorize-held-resume-1" and
  .task.authority.captain_required_boundaries == [] and
  .task.authority.captain_authorized_boundaries == ["financial-transaction"] and
  .task.blockers == []
' >/dev/null || fail "explicit captain boundary authorization did not resume the held task"
pass "captain pause and higher-boundary holds clear independently"

# Constraint application and clearing are order-independent. Both homes use the
# same semantic inputs in opposite order and must reach the same derived state.
HOME_ORDER_A="$TMP_ROOT/constraints-order-a"
HOME_ORDER_B="$TMP_ROOT/constraints-order-b"
ORDER_TASK=14141414-1414-4414-8414-141414141414
ORDER_OBJECTIVE='Exercise order-independent captain constraints.'
setup_running_task "$HOME_ORDER_A" "$ORDER_TASK" constraints-order-event constraints-order-v1 "$ORDER_OBJECTIVE"
setup_running_task "$HOME_ORDER_B" "$ORDER_TASK" constraints-order-event constraints-order-v1 "$ORDER_OBJECTIVE"

run_session "$HOME_ORDER_A" record-captain-decision \
  --task-id "$ORDER_TASK" \
  --action pause \
  --instruction-id order-pause \
  --source-conversation captain-constraint-session \
  --direction 'Pause the order-independence task.' >/dev/null
run "$HOME_ORDER_A" hold \
  --task-id "$ORDER_TASK" \
  --decision-key order-financial-hold \
  --boundaries financial-transaction \
  --reason 'The financial boundary remains independently held.' >/dev/null

run "$HOME_ORDER_B" hold \
  --task-id "$ORDER_TASK" \
  --decision-key order-financial-hold \
  --boundaries financial-transaction \
  --reason 'The financial boundary remains independently held.' >/dev/null
run_session "$HOME_ORDER_B" record-captain-decision \
  --task-id "$ORDER_TASK" \
  --action pause \
  --instruction-id order-pause \
  --source-conversation captain-constraint-session \
  --direction 'Pause the order-independence task.' >/dev/null

ORDER_APPLIED_A=$(status_task "$HOME_ORDER_A" "$ORDER_TASK" | jq -Sc \
  '.task | {state,progress_state,blockers,required:.authority.captain_required_boundaries}')
ORDER_APPLIED_B=$(status_task "$HOME_ORDER_B" "$ORDER_TASK" | jq -Sc \
  '.task | {state,progress_state,blockers,required:.authority.captain_required_boundaries}')
[ "$ORDER_APPLIED_A" = "$ORDER_APPLIED_B" ] \
  || fail "pause and hold application depended on command order"
printf '%s' "$ORDER_APPLIED_A" | jq -e '
  .state == "blocked" and .progress_state == "running" and
  (.blockers | map(.kind) == ["captain-approval","captain-pause"]) and
  .required == ["financial-transaction"]
' >/dev/null || fail "pause then hold did not preserve both independent constraints"

# Clear pause first in A and boundary first in B. Each decision clears only the
# constraint it names, and either remaining constraint keeps the task blocked.
run_session "$HOME_ORDER_A" record-captain-decision \
  --task-id "$ORDER_TASK" \
  --action narrow \
  --instruction-id order-resume \
  --source-conversation captain-constraint-session \
  --direction 'Lift only the named captain pause.' \
  --supersedes order-pause >/dev/null
run_session "$HOME_ORDER_B" record-captain-decision \
  --task-id "$ORDER_TASK" \
  --action override \
  --instruction-id order-authorize \
  --source-conversation captain-constraint-session \
  --direction 'Authorize only the financial boundary.' \
  --authorized-boundaries financial-transaction >/dev/null

status_task "$HOME_ORDER_A" "$ORDER_TASK" | jq -e '
  .task.state == "blocked" and .task.progress_state == "running" and
  (.task.blockers | map(.kind) == ["captain-approval"]) and
  .task.authority.captain_required_boundaries == ["financial-transaction"]
' >/dev/null || fail "pause semantics incidentally cleared the financial hold"
status_task "$HOME_ORDER_B" "$ORDER_TASK" | jq -e '
  .task.state == "blocked" and .task.progress_state == "running" and
  (.task.blockers | map(.kind) == ["captain-pause"]) and
  .task.authority.captain_required_boundaries == []
' >/dev/null || fail "boundary authorization incidentally cleared the captain pause"
if run "$HOME_ORDER_A" transition --task-id "$ORDER_TASK" --transition-key order-a-bypass --to running >/dev/null 2>&1; then
  fail "task with a remaining boundary constraint reached running"
fi
if run "$HOME_ORDER_B" transition --task-id "$ORDER_TASK" --transition-key order-b-bypass --to running >/dev/null 2>&1; then
  fail "task with a remaining pause constraint reached running"
fi

run_session "$HOME_ORDER_A" record-captain-decision \
  --task-id "$ORDER_TASK" \
  --action override \
  --instruction-id order-authorize \
  --source-conversation captain-constraint-session \
  --direction 'Authorize only the financial boundary.' \
  --authorized-boundaries financial-transaction >/dev/null
run_session "$HOME_ORDER_B" record-captain-decision \
  --task-id "$ORDER_TASK" \
  --action narrow \
  --instruction-id order-resume \
  --source-conversation captain-constraint-session \
  --direction 'Lift only the named captain pause.' \
  --supersedes order-pause >/dev/null

ORDER_CLEARED_A=$(status_task "$HOME_ORDER_A" "$ORDER_TASK" | jq -Sc \
  '.task | {state,progress_state,blockers,required:.authority.captain_required_boundaries,authorized:.authority.captain_authorized_boundaries,accepted_at:.lifecycle_timestamps.accepted_at}')
ORDER_CLEARED_B=$(status_task "$HOME_ORDER_B" "$ORDER_TASK" | jq -Sc \
  '.task | {state,progress_state,blockers,required:.authority.captain_required_boundaries,authorized:.authority.captain_authorized_boundaries,accepted_at:.lifecycle_timestamps.accepted_at}')
[ "$ORDER_CLEARED_A" = "$ORDER_CLEARED_B" ] \
  || fail "constraint clearing depended on command order"
printf '%s' "$ORDER_CLEARED_A" | jq -e '
  .state == "running" and .progress_state == "running" and .blockers == [] and
  .required == [] and .authorized == ["financial-transaction"] and .accepted_at != null
' >/dev/null || fail "clearing every constraint did not restore the derived running state"
pass "constraint apply and clear semantics are order-independent"

# One decision may explicitly clear the named pause and one named boundary, but
# an unrelated boundary remains a distinct constraint and still derives blocked.
HOME_CONSTRAINT_PARTIAL="$TMP_ROOT/constraints-partial"
PARTIAL_CONSTRAINT_TASK=15151515-1515-4515-8515-151515151515
setup_running_task "$HOME_CONSTRAINT_PARTIAL" "$PARTIAL_CONSTRAINT_TASK" \
  constraints-partial-event constraints-partial-v1 'Preserve unrelated authority constraints.'
run_session "$HOME_CONSTRAINT_PARTIAL" record-captain-decision \
  --task-id "$PARTIAL_CONSTRAINT_TASK" \
  --action pause \
  --instruction-id partial-pause \
  --source-conversation captain-constraint-session \
  --direction 'Pause while independent boundaries are assessed.' >/dev/null
run "$HOME_CONSTRAINT_PARTIAL" hold \
  --task-id "$PARTIAL_CONSTRAINT_TASK" \
  --decision-key partial-multi-hold \
  --boundaries financial-transaction,security-sensitive \
  --reason 'Financial and security boundaries require separate captain authorization.' >/dev/null
PARTIAL_ACCEPTED_AT=$(status_task "$HOME_CONSTRAINT_PARTIAL" "$PARTIAL_CONSTRAINT_TASK" | jq -r '.task.lifecycle_timestamps.accepted_at')
run_session "$HOME_CONSTRAINT_PARTIAL" record-captain-decision \
  --task-id "$PARTIAL_CONSTRAINT_TASK" \
  --action override \
  --instruction-id partial-financial-resume \
  --source-conversation captain-constraint-session \
  --direction 'Lift the named pause and authorize only the financial boundary.' \
  --supersedes partial-pause \
  --authorized-boundaries financial-transaction >/dev/null
status_task "$HOME_CONSTRAINT_PARTIAL" "$PARTIAL_CONSTRAINT_TASK" | jq -e --arg accepted "$PARTIAL_ACCEPTED_AT" '
  .task.state == "blocked" and .task.progress_state == "running" and
  .task.lifecycle_timestamps.accepted_at == $accepted and
  (.task.blockers | length == 1 and .[0].kind == "captain-approval" and .[0].boundaries == ["security-sensitive"]) and
  .task.authority.captain_required_boundaries == ["security-sensitive"] and
  .task.authority.captain_authorized_boundaries == ["financial-transaction"]
' >/dev/null || fail "combined pause and boundary decision dropped an unrelated constraint or acceptance"
run "$HOME_CONSTRAINT_PARTIAL" health | jq -e '.healthy == true' >/dev/null \
  || fail "remaining constraint did not survive restart validation"
pass "each constraint clears only through its own explicit semantics"

# A delivered, unaccepted task with both constraints becomes accepted exactly
# once when one captain decision names the pause and covers the held boundary.
HOME_UNACCEPTED_CONSTRAINTS="$TMP_ROOT/constraints-unaccepted"
setup_home "$HOME_UNACCEPTED_CONSTRAINTS"
UNACCEPTED_CONSTRAINT_TASK=16161616-1616-4616-8616-161616161616
append_mercury "$HOME_UNACCEPTED_CONSTRAINTS" "$UNACCEPTED_CONSTRAINT_TASK" \
  constraints-unaccepted-event constraints-unaccepted-v1 'Accept only after explicit combined captain authority.'
run "$HOME_UNACCEPTED_CONSTRAINTS" ingest >/dev/null
run_session "$HOME_UNACCEPTED_CONSTRAINTS" record-captain-decision \
  --task-id "$UNACCEPTED_CONSTRAINT_TASK" \
  --action pause \
  --instruction-id unaccepted-pause \
  --source-conversation captain-constraint-session \
  --direction 'Pause the delivered task.' >/dev/null
run "$HOME_UNACCEPTED_CONSTRAINTS" hold \
  --task-id "$UNACCEPTED_CONSTRAINT_TASK" \
  --decision-key unaccepted-financial-hold \
  --boundaries financial-transaction \
  --reason 'The financial boundary requires explicit captain authorization.' >/dev/null
run_session "$HOME_UNACCEPTED_CONSTRAINTS" record-captain-decision \
  --task-id "$UNACCEPTED_CONSTRAINT_TASK" \
  --action override \
  --instruction-id unaccepted-covered-resume \
  --source-conversation captain-constraint-session \
  --direction 'Lift the pause and authorize this exact financial boundary.' \
  --supersedes unaccepted-pause \
  --authorized-boundaries financial-transaction \
  --owner fm/constraint-worker >/dev/null
status_task "$HOME_UNACCEPTED_CONSTRAINTS" "$UNACCEPTED_CONSTRAINT_TASK" | jq -e '
  .task.state == "accepted" and .task.progress_state == "accepted" and
  .task.lifecycle_timestamps.accepted_at != null and .task.blockers == [] and
  .task.authority.captain_required_boundaries == []
' >/dev/null || fail "covered unaccepted pause and hold did not derive explicit acceptance"
pass "combined explicit captain semantics preserve acceptance instead of demoting lifecycle state"

run "$HOME_ONE" transition \
  --task-id "$TASK_ONE" \
  --transition-key ordinary-complete \
  --to completed \
  --reason 'The parser correction and its focused tests are complete.' \
  --artifacts-json '[{"label":"Committed branch","ref":"fm/parser-correction"}]' \
  --verification-json '[{"check":"Focused test","status":"passed","evidence":"Parser behavior passed."}]' >/dev/null
assert_task_state "$HOME_ONE" "$TASK_ONE" completed

# Separate tasks prove failed and captain-cancelled terminal paths.
FAILED_TASK=55555555-5555-4555-8555-555555555555
append_mercury "$HOME_ONE" "$FAILED_TASK" failed-task failed-task-v1 'Attempt a reversible failing experiment.'
run "$HOME_ONE" ingest >/dev/null
run "$HOME_ONE" accept --task-id "$FAILED_TASK" --decision-key failed-accept --owner fm/failure-worker \
  --assessment 'No higher boundary applies.' --boundaries none >/dev/null
if run "$HOME_ONE" transition --task-id "$FAILED_TASK" --transition-key ordinary-running --to running >/dev/null 2>&1; then
  fail "transition key replayed successfully for another task"
fi
run "$HOME_ONE" transition --task-id "$FAILED_TASK" --transition-key failed-terminal --to failed \
  --reason 'The focused experiment failed its invariant.' >/dev/null
assert_task_state "$HOME_ONE" "$FAILED_TASK" failed

CANCEL_TASK=66666666-6666-4666-8666-666666666666
append_mercury "$HOME_ONE" "$CANCEL_TASK" cancel-task cancel-task-v1 'Prepare a reversible documentation adjustment.'
run "$HOME_ONE" ingest >/dev/null
run "$HOME_ONE" accept --task-id "$CANCEL_TASK" --decision-key cancel-accept --owner fm/cancel-worker \
  --assessment 'No higher boundary applies.' --boundaries none >/dev/null
run_session "$HOME_ONE" record-captain-decision \
  --task-id "$CANCEL_TASK" \
  --action cancel \
  --instruction-id captain-cancel-1 \
  --source-conversation captain-cancellation-session \
  --direction 'Cancel this objective.' >/dev/null
assert_task_state "$HOME_ONE" "$CANCEL_TASK" cancelled

if run_session "$HOME_ONE" record-captain-decision \
  --task-id "$CANCEL_TASK" \
  --action cancel \
  --instruction-id captain-narrow-1 \
  --source-conversation captain-cancellation-session \
  --direction 'Cancel this different objective.' >/dev/null 2>&1; then
  fail "captain instruction key replayed successfully for another task"
fi
pass "captain directive replays cannot cross task boundaries"

jq -s -e '
  [.[].to_state] as $states |
  ["queued","delivered","accepted","running","blocked","failed","cancelled","completed"] |
  all(.[]; . as $wanted | $states | index($wanted) != null)
' "$HOME_ONE"/data/principal-authority/receipts/*.json >/dev/null \
  || fail "the immutable ledger did not explicitly record every lifecycle state"
pass "all lifecycle states are explicit recorded transitions"

# Both principals receive the same bounded authoritative projection.
CAPTAIN_STATUS=$(run "$HOME_ONE" status --task-id "$TASK_ONE" --viewer captain --limit 8)
MERCURY_STATUS=$(run "$HOME_ONE" status --task-id "$TASK_ONE" --viewer mercury --limit 8)
[ "$CAPTAIN_STATUS" = "$MERCURY_STATUS" ] || fail "captain and Mercury status projections differed"
printf '%s' "$CAPTAIN_STATUS" | jq -e '.receipts | length <= 8' >/dev/null \
  || fail "status receipts were not bounded"
pass "captain and Mercury see the same bounded authoritative status and receipts"

# Materialized task views are replayable after restart, while drift is loud
# until the immutable receipt ledger is deliberately recovered.
TASK_FILE="$HOME_ONE/data/principal-authority/tasks/$TASK_ONE.json"
mv "$TASK_FILE" "$TASK_FILE.interrupted"
if run "$HOME_ONE" health >/dev/null 2>&1; then
  fail "health silently accepted a missing materialized task view"
fi
if run "$HOME_ONE" ingest >/dev/null 2>&1; then
  fail "routine ingress silently repaired a missing materialized task view"
fi
run "$HOME_ONE" recover >/dev/null
run "$HOME_ONE" health | jq -e '.healthy == true' >/dev/null \
  || fail "receipt replay did not restore a healthy canonical task view"
rm -f "$TASK_FILE.interrupted"
pass "receipt replay survives restart and health reports materialized-view drift"

# Firstmate can record a direct captain objective from its own trusted local
# session. The relay-facing executable has no corresponding submit command.
HOME_CAPTAIN="$TMP_ROOT/captain-record"
setup_home "$HOME_CAPTAIN"
CAPTAIN_TASK=88888888-8888-4888-8888-888888888888
CAPTAIN_SUBMIT=$(run_session "$HOME_CAPTAIN" record-captain-task \
  --task-id "$CAPTAIN_TASK" \
  --idempotency-key captain-submit-v1 \
  --instruction-id captain-submit-instruction-1 \
  --source-conversation captain-session-original \
  --objective 'Implement a reversible captain-authored documentation correction.' \
  --acceptance-json '["The correction is focused and tested."]' \
  --repository firstmate \
  --priority normal \
  --owner fm/captain-worker)
printf '%s' "$CAPTAIN_SUBMIT" | jq -e '.from_state == "delivered" and .to_state == "accepted"' >/dev/null \
  || fail "direct captain submission lacked an explicit acceptance receipt"
STATUS=$(status_task "$HOME_CAPTAIN" "$CAPTAIN_TASK")
printf '%s' "$STATUS" | jq -e '
  .task.source_identity.principal == "captain" and
  .task.source_identity.verification == "recorded-by-firstmate-trusted-session" and
  .task.source_conversation.conversation == "captain-session-original" and
  .task.state == "accepted" and
  ([.receipts[].to_state] == ["queued","delivered","accepted"]) and
  all(.receipts[]; .source.principal == "firstmate" and .source.recorded_principal == "captain")
' >/dev/null || fail "direct captain submission did not use the canonical lifecycle"
REPLAY=$(run_session "$HOME_CAPTAIN" record-captain-task \
  --task-id "$CAPTAIN_TASK" \
  --idempotency-key captain-submit-v1 \
  --instruction-id captain-submit-instruction-1 \
  --source-conversation captain-session-after-reboot \
  --objective 'Implement a reversible captain-authored documentation correction.' \
  --acceptance-json '["The correction is focused and tested."]' \
  --repository firstmate \
  --priority normal \
  --owner fm/captain-worker)
[ "$(printf '%s' "$REPLAY" | jq -r '.receipt_id')" = "$(printf '%s' "$CAPTAIN_SUBMIT" | jq -r '.receipt_id')" ] \
  || fail "direct captain submission retry produced a duplicate receipt"
if run_session "$HOME_CAPTAIN" record-captain-task \
  --task-id aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa \
  --idempotency-key captain-submit-v1 \
  --instruction-id captain-submit-instruction-1 \
  --source-conversation captain-session-after-reboot \
  --objective 'Implement a reversible captain-authored documentation correction.' \
  --acceptance-json '["The correction is focused and tested."]' \
  --repository firstmate \
  --priority normal \
  --owner fm/captain-worker >/dev/null 2>&1; then
  fail "captain submission key replayed successfully for another task"
fi
pass "both direct captain and authenticated Mercury direction use one canonical lifecycle"

HOME_PARTIAL="$TMP_ROOT/captain-partial"
setup_home "$HOME_PARTIAL"
PARTIAL_TASK=dddddddd-dddd-4ddd-8ddd-dddddddddddd
run_interrupted_session "$HOME_PARTIAL" record-captain-task \
  --task-id "$PARTIAL_TASK" \
  --idempotency-key captain-partial-v1 \
  --instruction-id captain-partial-instruction-1 \
  --source-conversation captain-session-before-reboot \
  --objective 'Implement a reversible interrupted captain submission.' \
  --acceptance-json '["The retry preserves the original operation."]' \
  --repository firstmate \
  --priority normal \
  --owner fm/captain-worker >/dev/null
if run_session "$HOME_PARTIAL" record-captain-task \
  --task-id eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee \
  --idempotency-key captain-partial-v1 \
  --instruction-id captain-partial-instruction-1 \
  --source-conversation captain-session-after-reboot \
  --objective 'Implement a reversible interrupted captain submission.' \
  --acceptance-json '["The retry preserves the original operation."]' \
  --repository firstmate \
  --priority normal \
  --owner fm/captain-worker >/dev/null 2>&1; then
  fail "partial captain submission accepted a changed task identity"
fi
run_session "$HOME_PARTIAL" record-captain-task \
  --task-id "$PARTIAL_TASK" \
  --idempotency-key captain-partial-v1 \
  --instruction-id captain-partial-instruction-1 \
  --source-conversation captain-session-after-reboot \
  --objective 'Implement a reversible interrupted captain submission.' \
  --acceptance-json '["The retry preserves the original operation."]' \
  --repository firstmate \
  --priority normal \
  --owner fm/captain-worker >/dev/null
assert_task_state "$HOME_PARTIAL" "$PARTIAL_TASK" accepted
PARTIAL_STATUS=$(status_task "$HOME_PARTIAL" "$PARTIAL_TASK")
printf '%s' "$PARTIAL_STATUS" | jq -e '
  ([.receipts[].to_state] == ["queued","delivered","accepted"]) and
  .receipts[0].source.conversation == "captain-session-before-reboot" and
  .receipts[2].source.conversation == "captain-session-after-reboot"
' >/dev/null || fail "captain submission replay did not preserve original and resumed session provenance"
pass "partial captain submission replays bind task semantics across reboot, not session thread"

HOME_DUPLICATE_CAPTAIN="$TMP_ROOT/captain-duplicate-objective"
setup_home "$HOME_DUPLICATE_CAPTAIN"
append_mercury "$HOME_DUPLICATE_CAPTAIN" 12121212-1212-4212-8212-121212121212 captain-duplicate captain-duplicate-v1 'Keep one canonical captain objective.'
run "$HOME_DUPLICATE_CAPTAIN" ingest >/dev/null
if run_session "$HOME_DUPLICATE_CAPTAIN" record-captain-task \
  --task-id 13131313-1313-4313-8313-131313131313 \
  --idempotency-key captain-duplicate-v2 \
  --instruction-id captain-duplicate-instruction-2 \
  --source-conversation captain-duplicate-session \
  --objective 'Keep one canonical captain objective.' \
  --acceptance-json '["Changed acceptance criteria must not be discarded."]' \
  --repository another-repository \
  --priority urgent \
  --owner fm/captain-worker >/dev/null 2>&1; then
  fail "duplicate captain submission silently discarded direction fields"
fi
pass "duplicate objectives require an explicit bounded captain directive"

echo "all fm-principal-authority tests passed"
