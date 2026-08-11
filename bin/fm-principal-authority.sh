#!/usr/bin/env bash
# fm-principal-authority.sh - durable dual-principal command and lifecycle owner.
#
# Mercury ingress is accepted only from the mode-600 Hermes event ledger after
# the upstream bridge has verified its HMAC. This consumer independently
# requires the configured Mercury caller, key id, and Ed25519 public key,
# reconstructs the exact canonical payload, and verifies both its hash and
# producer signature before recording any task. Relayed captain text is always
# recorded as refused unverified input.
# This relay-facing executable exposes no captain mutation or identity-admission
# command. Direct captain decisions are recorded by Firstmate through the
# separate local fm-principal-session-authority.sh administrative surface after
# Firstmate receives them in its own trusted interactive session.
#
# Durable data lives under data/principal-authority/:
#   tasks/<task-id>.json       materialized canonical task view
#   receipts/<sha256>.json     content-addressed immutable transition receipts
# Every mutating receipt embeds task_after. A retry or reboot can therefore
# replay the highest contiguous receipt revision into the task view. Health
# refuses receipt gaps, hash drift, duplicate objective records, and task-view
# divergence. Blockers are a canonical constraint set, while public state and
# required boundaries derive purely from recorded progress plus that set. The
# shared implementation lock serializes every writer entrypoint and recovers
# stale owners after a stopped process or reboot.
#
# Usage:
#   fm-principal-authority.sh ingest [--events <jsonl>]
#   fm-principal-authority.sh accept --task-id <uuid> --decision-key <key> \
#     --owner <owner> --assessment <reason> --boundaries none
#   fm-principal-authority.sh hold --task-id <uuid> --decision-key <key> \
#     --boundaries <comma-list> --reason <reason>
#   fm-principal-authority.sh transition --task-id <uuid> --transition-key <key> \
#     --to <running|blocked|failed|completed> [state evidence flags]
#   fm-principal-authority.sh status [--task-id <uuid>|--objective <text>|--pending|--refusals]
#   fm-principal-authority.sh health
#   fm-principal-authority.sh recover
#
# Run --help for the complete version-matched flag surface and boundary names.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
node "$SCRIPT_DIR/fm-principal-authority.mjs" "$@"
