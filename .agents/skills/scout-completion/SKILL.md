---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation, and when any worker report lists numbered follow-ups.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it, and the same holds for its follow-ups.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-dispatch.sh promote` (operator contract: `docs/configuration.md` "Typed dispatch resolution") rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.

## Follow-up intake

This section owns what happens to any report's numbered follow-ups, on a ship or a scout: a follow-up is a lead, not a decision, so it never becomes a backlog row without the captain's pick.
`bin/fm-suggestions.sh` owns the store, de-duplication, expiry and the teardown check; never file a follow-up with `tasks-axi add`.

1. Group the list by root cause or area, across this report and recent ones.
2. Record each numbered item with `bin/fm-suggestions.sh add --origin <id> --item <n>` and its one-line outcome, file:line, size, kind and risk; a duplicate comes back as `repeat`.
3. Fold nits into one polish suggestion per repo area with `bundle`, so the digest states them as one candidate.
4. State each real finding by its outcome, with `--recommend pick`, `bundle` or `drop`.
5. Pass `--hold` for a question only the captain can answer, so it takes the captain-hold path instead of waiting in the list.
6. Treat a security or data-loss finding as urgent even when the worker did not label it: start its `--risk` with `security` or `data-loss`, which holds it for the captain, then tell the captain in the same turn.
