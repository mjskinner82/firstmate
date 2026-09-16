#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path("/Users/mattskinner/.no-mistakes/worktrees/d0f879512d7f/01M2MH2FBCC7XDGP4P8TZK8GQH")
EVIDENCE = Path("/Users/mattskinner/.no-mistakes/evidence/01M2MH2FBCC7XDGP4P8TZK8GQH")
RUN = EVIDENCE / "routing-outcomes-live"
RUN.mkdir(exist_ok=True)
STATE = RUN / "state"
STATE.mkdir(exist_ok=True)
CLI = ROOT / "bin" / "fm-routing-outcomes.py"
STORE = RUN / "outcomes.jsonl"
SHADOW_STORE = RUN / "shadow.jsonl"

for path in (STORE, STORE.with_name(STORE.name + ".lock"), SHADOW_STORE,
             SHADOW_STORE.with_name(SHADOW_STORE.name + ".lock")):
    if path.exists():
        path.unlink()

def write_json(name, value):
    path = RUN / name
    path.write_text(json.dumps(value), encoding="utf-8")
    return path

def run(*args, expected=0):
    env = dict(os.environ, FM_STATE_OVERRIDE=str(STATE))
    result = subprocess.run([str(CLI), *map(str, args)], text=True, capture_output=True, env=env)
    print("$", CLI.name, *args)
    if result.stdout:
        print(result.stdout.rstrip())
    if result.stderr:
        print("stderr:", result.stderr.rstrip())
    print("exit:", result.returncode)
    if result.returncode != expected:
        raise SystemExit(f"unexpected exit: wanted {expected}, got {result.returncode}")
    return result

task = "live-routing-evidence"
spawn = "spawn-live-1"
(STATE / f"{task}.meta").write_text(
    f"endpoint_task_id={task}\nspawn_gen={spawn}\nharness=pi\nkind=ship\n",
    encoding="utf-8")

receipt_rows = [
    {"type": "session", "id": "session-live", "timestamp": "2030-01-01T00:00:00Z"},
    {"type": "custom", "id": "request-1", "parentId": "user-1",
     "customType": "fm-routing-request", "timestamp": "2030-01-01T00:00:01Z",
     "data": {"schema": "fm-routing-request.v1", "taskId": task, "spawnGen": spawn,
              "requestSequence": 1, "at": "2030-01-01T00:00:01Z",
              "observationStage": "provisional-before-remaining-handlers",
              "provider": "codex", "selectedModel": "gpt-5.6-luna",
              "selectedThinkingLevel": "max", "api": "openai-codex-responses"}},
    {"type": "message", "id": "assistant-1", "parentId": "request-1",
     "timestamp": "2030-01-01T00:00:03Z",
     "message": {"role": "assistant", "provider": "codex", "model": "gpt-5.6-luna",
                 "api": "openai-codex-responses",
                 "content": [{"type": "text", "text": "PRIVATE CONTENT MUST NOT PERSIST"}],
                 "usage": {"input": 100, "output": 20, "cacheRead": 10,
                           "cacheWrite": 0, "reasoning": 5, "totalTokens": 130,
                           "cost": {"total": 0.5}}}},
]
receipt = RUN / "pi-session.jsonl"
receipt.write_text("".join(json.dumps(row) + "\n" for row in receipt_rows), encoding="utf-8")

def quota(name, remaining, *, stale=False, unknown_second=False):
    windows = [{"id": "weekly", "label": "week", "kind": "weekly",
                "resetsAt": "2030-01-02T00:00:00Z", "percentRemaining": remaining}]
    if unknown_second:
        windows.append({"id": "daily", "label": "day", "kind": "daily",
                        "resetsAt": "2030-01-02T00:00:00Z", "percentRemaining": None})
    return write_json(name, {"schemaVersion": 5,
        "generatedAt": "2030-01-01T00:00:00Z" if "before" in name else "2030-01-01T00:02:00Z",
        "providers": [{"provider": "codex",
            "state": {"status": "stale" if stale else "fresh", "stale": stale},
            "windows": windows,
            "quotaSemantics": {"status": "known", "effectiveAvailability": []}}]})

before = quota("quota-before.json", 100)
after = quota("quota-after.json", 95)

criteria = [{"id": "focused-check", "text": "focused product check passes"}]
criteria_sha = hashlib.sha256(json.dumps(criteria, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
check_payload = {"schema": "fm-routing-check.v1", "check_id": "focused-cli",
    "grader_id": "independent-check", "criteria_ids": ["focused-check"],
    "task_id": task, "spawn_gen": spawn, "attempt_id": "attempt-1",
    "acceptance_criteria_sha256": criteria_sha, "passed": True, "exit_code": 0}
check = write_json("check.json", check_payload)
check_sha = hashlib.sha256(check.read_bytes()).hexdigest()

route = {"harness": "pi", "provider": "codex", "auth_category": "subscription",
         "requested_model": "gpt-5.6-luna", "requested_effort": "max",
         "context_tier": "all", "service_tier": "standard"}
manifest = {"schema": "fm-routing-attempt.v1", "task_id": task, "attempt_id": "attempt-1",
    "task_binding": {"spawn_gen": spawn}, "phase": "measurement", "category": "1",
    "task_shape": "code-change", "route": route,
    "native_receipt": {"kind": "pi-session", "path": str(receipt)},
    "requirements": {"effective_model": "gpt-5.6-luna"},
    "started_at": "2030-01-01T00:00:00Z", "finished_at": "2030-01-01T00:01:00Z",
    "time_ms": {"queue": 10, "model": 20, "tool": 5, "review": 7,
                "retry": None, "handoff": None, "human": None},
    "billing": {"actual_incremental_usd": 0, "fixed_subscription_usd": 20},
    "quota": {"provider": "codex", "before_path": str(before), "after_path": str(after),
              "concurrent_activity": False, "attribution": "exclusive"},
    "grading": {"method": "deterministic", "independent": True,
                "acceptance_criteria": criteria,
                "grader": {"kind": "deterministic-check", "id": "independent-check"},
                "first_pass": "pass", "final_result": "pass", "defect_count": 0,
                "fix_count": 0, "retry_count": 0,
                "receipts": [{"kind": "test", "id": "focused-cli", "passed": True,
                              "criteria_ids": ["focused-check"], "artifact_path": str(check),
                              "sha256": check_sha}],
                "overhead": {"duration_ms": 3, "tokens": None,
                             "actual_incremental_usd": 0}},
    "outcome": "unresolved"}
manifest_path = write_json("manifest.json", manifest)

print("SCENARIO 1: exact fresh receipt import and scorecard")
run("import", "--manifest", manifest_path, "--store", STORE, "--json")
run("inspect", "--task", task, "--store", STORE, "--json")
run("scorecard", "--store", STORE, "--shadow-store", SHADOW_STORE, "--format", "markdown")
persisted = STORE.read_text(encoding="utf-8")
print("private_content_persisted:", "PRIVATE CONTENT MUST NOT PERSIST" in persisted)

print("\nSCENARIO 2: accepted Pi result with provisional effort is rejected")
accepted = dict(manifest)
accepted["outcome"] = "accepted"
accepted_path = write_json("manifest-accepted.json", accepted)
run("import", "--manifest", accepted_path, "--store", STORE, "--json", expected=2)

print("\nSCENARIO 2B: stale quota snapshot keeps movement unattributed")
before_payload = json.loads(before.read_text(encoding="utf-8"))
before_payload["providers"][0]["state"] = {"status": "stale", "stale": True}
before.write_text(json.dumps(before_payload), encoding="utf-8")
run("import", "--manifest", manifest_path, "--store", STORE, "--json")
run("scorecard", "--store", STORE, "--shadow-store", SHADOW_STORE, "--format", "markdown")
before_payload["providers"][0]["state"] = {"status": "fresh", "stale": False}
before.write_text(json.dumps(before_payload), encoding="utf-8")
run("import", "--manifest", manifest_path, "--store", STORE, "--json")

print("\nSCENARIO 3: shadow recommendation retains raw freshness and uncertainty")
stale_snapshot = quota("quota-shadow-stale.json", None, stale=True)
claude_route = dict(route, harness="claude", provider="anthropic",
                    requested_model="claude-sonnet-5", requested_effort="high")
shadow = {"schema": "fm-routing-shadow.v1", "task_id": task, "decision_id": "decision-1",
    "task_binding": {"spawn_gen": spawn}, "at": "2030-01-01T00:00:00Z",
    "category": "1", "task_shape": "code-change",
    "candidates": [
        {"route": route, "eligibility": "pass", "capability_class_fit": "pass",
         "runway_feasibility": "pass", "spend_priority": 1.2,
         "quota_evidence": {"snapshot_path": str(before), "provider": "codex"},
         "uncertainty": "none observed", "explanation": "known headroom after fit gates"},
        {"route": claude_route, "eligibility": "unknown", "capability_class_fit": "pass",
         "runway_feasibility": "unknown", "spend_priority": None,
         "quota_evidence": {"snapshot_path": str(stale_snapshot), "provider": "codex"},
         "uncertainty": "stale allowance evidence", "explanation": "unknown is not exhaustion"}],
    "recommended_route": route,
    "explanation": "Shadow-only heuristic recommendation; it does not execute a route."}
shadow_path = write_json("shadow-manifest.json", shadow)
run("shadow", "--manifest", shadow_path, "--shadow-store", SHADOW_STORE, "--json")
run("scorecard", "--store", STORE, "--shadow-store", SHADOW_STORE, "--format", "markdown")
