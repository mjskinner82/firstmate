#!/usr/bin/env bash
# fm-principal-authority.sh - durable dual-principal command and lifecycle owner.
#
# Mercury ingress is accepted only from the mode-600 Hermes event ledger after
# the upstream bridge has verified its HMAC. This consumer independently
# requires the configured Mercury caller and key id, reconstructs the exact
# canonical payload, and verifies assignment_payload_hash before recording any
# task. Relayed captain text is always recorded as refused unverified input.
# A direct captain instruction enters only through the captain-submit or
# captain-directive commands after the current trusted channel has supplied an
# allowlisted identity and channel from config/principal-authority.json.
#
# Durable data lives under data/principal-authority/:
#   tasks/<task-id>.json       materialized canonical task view
#   receipts/<sha256>.json     content-addressed immutable transition receipts
# Every mutating receipt embeds task_after. A retry or reboot can therefore
# replay the highest contiguous receipt revision into the task view. Health
# refuses receipt gaps, hash drift, duplicate objective records, and task-view
# divergence. The portable lock from fm-wake-lib.sh serializes writers and
# recovers stale owners after a stopped process or reboot.
#
# Usage:
#   fm-principal-authority.sh ingest [--events <jsonl>]
#   fm-principal-authority.sh accept --task-id <uuid> --decision-key <key> \
#     --owner <owner> --assessment <reason> --boundaries none
#   fm-principal-authority.sh hold --task-id <uuid> --decision-key <key> \
#     --boundaries <comma-list> --reason <reason>
#   fm-principal-authority.sh transition --task-id <uuid> --transition-key <key> \
#     --to <running|blocked|failed|completed> [state evidence flags]
#   fm-principal-authority.sh captain-submit [assignment and trusted-source flags]
#   fm-principal-authority.sh captain-directive --task-id <uuid> \
#     --action <pause|override|narrow|cancel> [directive flags]
#   fm-principal-authority.sh status [--task-id <uuid>|--objective <text>|--pending|--refusals]
#   fm-principal-authority.sh health
#   fm-principal-authority.sh recover
#
# Run --help for the complete version-matched flag surface and boundary names.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

LOCK="$STATE/.principal-authority.lock"
fm_lock_acquire_wait "$LOCK"
trap 'fm_lock_release "$LOCK"' EXIT HUP INT TERM

node "$SCRIPT_DIR/fm-principal-authority.mjs" "$@"
