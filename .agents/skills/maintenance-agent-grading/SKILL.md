---
name: maintenance-agent-grading
description: >-
  Agent-only procedure for recording recurring maintenance-agent outcomes,
  reading their scoreboard, and proposing reviewed reusable-brief refinements.
  Load after a maintenance-agent PR resolves, before recording its final grade
  or teardown, and before reviewing grades or proposing a brief change.
user-invocable: false
metadata:
  internal: true
---

# Maintenance-agent grading and reviewed improvement

This skill owns the review procedure for Dead Code Cleanup, Abstraction Police, Experiment Clean-up, Test Coverage, and Useless Test Removal.
`bin/fm-agent-grade.sh --help` owns the ledger path, row contract, validation rules, outcome vocabulary, commands, and scoreboard formulas.

## Record the outcome

After the PR disposition and reviewer feedback are known, and before task teardown and backlog archival, record the maintenance run exactly once.
Use a stable privacy-safe agent slug and the Firstmate task id.
Pass the canonical PR URL when one exists, label each known false-positive candidate with a privacy-safe identifier, and keep raw prompts, private source text, and diffs out of the ledger.
Choose `rejected` only when review rejected the maintenance output on its merits.
Use `closed` for an unmerged PR closed for another reason, so timing, overlap, or custody does not become a false quality signal.

```sh
bin/fm-agent-grade.sh record dead-code-cleanup cleanup-123 \
  --pr https://github.com/example/repo/pull/123 \
  --outcome merged_changed \
  --false-positive generated-path \
  --note "review removed one candidate"
```

Do not add this call to every PR merge or teardown.
Only Firstmate tasks identified as one of these recurring maintenance agents produce a grade.

## Review the scoreboard

Run `bin/fm-agent-grade.sh report` for the fleet view or add `--agent <slug>` for one agent.
Treat the displayed rates as small-sample evidence with explicit denominators, not as one magic score.
Ringer execution grades and no-mistakes findings are complementary evidence when those systems were selected, but this first loop does not import or modify either system's data.

## Propose a reviewed brief refinement

1. Review one agent's rejected runs and false-positive-labeled runs from the scoreboard and ledger.
2. Read the linked PR and review evidence before deciding that the reusable brief, rather than execution or context, caused the miss.
3. Prepare one surgical reusable-brief diff that addresses the repeated failure pattern without changing authority, safety boundaries, or the agent's approved scope.
4. Present the proposal as an ordinary governed change in the reusable brief's owner repository, with its supporting examples and expected effect.
5. Keep the proposal inert until the captain approves the diff and the selected delivery path merges it.
6. Activate or sync the merged brief only through its existing governed path, then grade later runs against the resulting behavior.

This follows the Hermes and Mercury governance boundary: an agent may propose a change, while Firstmate and the captain retain review, merge, deployment, and activation custody.
Maintenance agents never rewrite their own reusable briefs unsupervised.
This skill and the grading helper do not run a daemon, schedule reviews, generate autonomous patches, or activate a proposed refinement.
