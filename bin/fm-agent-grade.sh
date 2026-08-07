#!/usr/bin/env bash
# fm-agent-grade.sh - record and report recurring maintenance-agent outcomes.
#
# The captain-private append-only ledger lives at:
#   $FM_HOME/data/maintenance-agent-grades/events.jsonl
# FM_DATA_OVERRIDE replaces the data directory for tests and isolated operators.
#
# Each JSONL row has exactly these fields:
#   agent, task_id, pr_url, outcome, false_positive_labels, timestamp, note
# Agent, task, and false-positive labels are privacy-safe slugs.
# `pr_url` is empty or an HTTPS URL, `timestamp` is UTC to whole seconds, and
# `outcome` is one of merged_clean, merged_changed, rejected, closed, or pending.
# One final row is allowed per agent/task pair; duplicate record attempts refuse.
# Keep raw prompts, private source text, and diffs out of labels and notes.
#
# Report rates are intentionally simple and show their denominators:
#   merge rate             = merged_clean + merged_changed / all runs
#   changed-on-merge rate  = merged_changed / merged runs
#   rejected rate          = rejected / all runs
#   false-positive rate    = runs with one or more false-positive labels / all runs
#
# Usage:
#   fm-agent-grade.sh record <agent> <task-id> [--pr <url>] [--outcome <outcome>]
#     [--false-positive <label> ...] [--note <one-line note>]
#   fm-agent-grade.sh report [--agent <agent>]
#   fm-agent-grade.sh --help
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/maintenance-agent-grades/events.jsonl"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 2
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "fm-agent-grade: python3 is required" >&2
  exit 1
fi

umask 077
exec python3 - "$LEDGER" "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


OUTCOMES = {"merged_clean", "merged_changed", "rejected", "closed", "pending"}
REQUIRED_FIELDS = {
    "agent",
    "task_id",
    "pr_url",
    "outcome",
    "false_positive_labels",
    "timestamp",
    "note",
}
SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class GradeError(Exception):
    """One user-facing ledger validation error."""


def fail(message: str) -> None:
    raise GradeError(message)


def validate_slug(label: str, value: object) -> str:
    if not isinstance(value, str) or not SLUG_RE.fullmatch(value):
        fail(f"{label} must be a non-empty privacy-safe slug")
    return value


def validate_url(value: object) -> str:
    if not isinstance(value, str):
        fail("pr_url must be a string")
    if not value:
        return value
    if any(ch.isspace() for ch in value):
        fail("pr_url must be an HTTPS URL without whitespace")
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or not parsed.path
        or parsed.username is not None
        or parsed.password is not None
    ):
        fail("pr_url must be an HTTPS URL without embedded credentials")
    return value


def validate_timestamp(value: object) -> str:
    if not isinstance(value, str):
        fail("timestamp must be a UTC timestamp")
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        fail("timestamp must use YYYY-MM-DDTHH:MM:SSZ")
    return value


def validate_note(value: object) -> str:
    if not isinstance(value, str):
        fail("note must be a string")
    if "\n" in value or "\r" in value:
        fail("note must be one line")
    if len(value) > 1000:
        fail("note must be at most 1000 characters")
    return value


def validate_record(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        fail("row must be a JSON object")
    if set(value) != REQUIRED_FIELDS:
        fail("row fields do not match the grade ledger schema")
    validate_slug("agent", value["agent"])
    validate_slug("task_id", value["task_id"])
    validate_url(value["pr_url"])
    outcome = value["outcome"]
    if not isinstance(outcome, str) or outcome not in OUTCOMES:
        fail("outcome is not recognized")
    labels = value["false_positive_labels"]
    if not isinstance(labels, list):
        fail("false_positive_labels must be an array")
    for label in labels:
        validate_slug("false-positive label", label)
    if len(labels) != len(set(labels)):
        fail("false_positive_labels must not contain duplicates")
    validate_timestamp(value["timestamp"])
    validate_note(value["note"])
    return value


def load_records(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"ledger is unreadable: {exc}")
    if raw and not raw.endswith("\n"):
        line_number = raw.count("\n") + 1
        fail(f"malformed ledger row at line {line_number}: final row is not newline-terminated")
    records: list[dict[str, object]] = []
    for line_number, line in enumerate(raw.splitlines(), start=1):
        if not line:
            fail(f"malformed ledger row at line {line_number}: row is empty")
        try:
            value = json.loads(line)
            records.append(validate_record(value))
        except (json.JSONDecodeError, GradeError) as exc:
            fail(f"malformed ledger row at line {line_number}: {exc}")
    return records


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fm-agent-grade.sh")
    subparsers = parser.add_subparsers(dest="command", required=True)

    record = subparsers.add_parser("record", help="append one validated outcome")
    record.add_argument("agent")
    record.add_argument("task_id")
    record.add_argument("--pr", default="", dest="pr_url")
    record.add_argument("--outcome", choices=sorted(OUTCOMES), default="pending")
    record.add_argument("--false-positive", action="append", default=[], dest="labels")
    record.add_argument("--note", default="")

    report = subparsers.add_parser("report", help="print per-agent outcome rates")
    report.add_argument("--agent")
    return parser


def record_outcome(path: Path, args: argparse.Namespace) -> None:
    validate_slug("agent", args.agent)
    validate_slug("task_id", args.task_id)
    validate_url(args.pr_url)
    labels = list(args.labels)
    for label in labels:
        validate_slug("false-positive label", label)
    if len(labels) != len(set(labels)):
        fail("false-positive labels must not contain duplicates")
    validate_note(args.note)

    records = load_records(path)
    if any(row["agent"] == args.agent and row["task_id"] == args.task_id for row in records):
        fail(f"grade already exists for agent={args.agent} task_id={args.task_id}")

    row: dict[str, object] = {
        "agent": args.agent,
        "task_id": args.task_id,
        "pr_url": args.pr_url,
        "outcome": args.outcome,
        "false_positive_labels": labels,
        "timestamp": datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "note": args.note,
    }
    validate_record(row)
    serialized = json.dumps(row, ensure_ascii=False, separators=(",", ":"))
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("a", encoding="utf-8") as ledger:
            ledger.write(serialized + "\n")
            ledger.flush()
            os.fsync(ledger.fileno())
    except OSError as exc:
        fail(f"could not append ledger record: {exc}")
    print(f"recorded: {args.agent} {args.task_id} {args.outcome}")


def rate(numerator: int, denominator: int) -> str:
    if denominator == 0:
        return "n/a (0/0)"
    return f"{100.0 * numerator / denominator:.1f}% ({numerator}/{denominator})"


def print_report(path: Path, args: argparse.Namespace) -> None:
    if args.agent is not None:
        validate_slug("agent", args.agent)
    records = load_records(path)
    if args.agent is not None:
        records = [row for row in records if row["agent"] == args.agent]
    if not records:
        suffix = f" for {args.agent}" if args.agent is not None else ""
        print(f"No maintenance-agent grades recorded{suffix}.")
        return

    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in records:
        grouped[str(row["agent"])].append(row)

    width = max(len("Agent"), *(len(agent) for agent in grouped))
    print("Maintenance-agent grade scoreboard")
    print("Merge, rejected, and false-positive rates use all runs.")
    print("Changed-on-merge uses merged runs; false-positive counts runs carrying at least one label.")
    print()
    print(
        f"{'Agent':<{width}}  {'Runs':>4}  {'Merge rate':>15}  "
        f"{'Changed-on-merge':>20}  {'Rejected rate':>15}  {'False-positive rate':>20}"
    )
    for agent in sorted(grouped):
        rows = grouped[agent]
        runs = len(rows)
        merged = sum(row["outcome"] in {"merged_clean", "merged_changed"} for row in rows)
        changed = sum(row["outcome"] == "merged_changed" for row in rows)
        rejected = sum(row["outcome"] == "rejected" for row in rows)
        false_positive = sum(bool(row["false_positive_labels"]) for row in rows)
        print(
            f"{agent:<{width}}  {runs:>4}  {rate(merged, runs):>15}  "
            f"{rate(changed, merged):>20}  {rate(rejected, runs):>15}  "
            f"{rate(false_positive, runs):>20}"
        )


def main() -> int:
    if len(sys.argv) < 3:
        print("fm-agent-grade: missing command", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    parser = build_parser()
    args = parser.parse_args(sys.argv[2:])
    try:
        if args.command == "record":
            record_outcome(path, args)
        else:
            print_report(path, args)
    except GradeError as exc:
        print(f"fm-agent-grade: {exc}", file=sys.stderr)
        return 1
    return 0


raise SystemExit(main())
PY
