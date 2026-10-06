---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding.
  This skill is the single owner of finding-decision policy: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Standing answers for recurring review gates

Apply these answers when the evidence matches the accepted contract and no destructive, irreversible, or genuinely security-sensitive choice is involved.
A new product or access guarantee still uses the escalation criteria above; a familiar label alone is not a match.

| Recurring kind | Standing answer and evidence required |
| --- | --- |
| Small documentation correction outside the anticipated file list | Fix it in the same PR through the active gate, without a new captain ask, when it keeps documentation accurate for already accepted behavior rather than adding a new requirement. |
| Machine-limit Test failure | Approve the gate with the limitation recorded and leave the affected test to CI when the failure is attributable to local resource limits, not an unexplained assertion or product failure, and CI will run the affected test. |
| UAT is missing its configured test script | Run the targeted tests available on UAT instead and return that evidence through the gate when the configured script is absent on that release branch and the replacement tests exercise the changed behavior, recording any coverage that remains unavailable. |
| Stale generated file | Include the regenerated file in the same PR through the gate when the repository's generator produces it from the accepted change or current authoritative inputs, with no unrelated semantic expansion. |

Record the matched kind, relevant evidence, and returned answer in the task's decision record.
When another gate presents the same question, even with a new finding id, reuse that answer if the accepted contract, evidence, and consequences are unchanged instead of asking the captain again.
If it recurs after a purported fix, inspect the result and authorize completion of the already-decided correction rather than reopening the same choice.
Changed consequences or a questionable abstraction still escalate under Decide above.
Workers continue routing ask-user findings to firstmate; this table never authorizes a worker to answer its own gate.

## Captain-facing escalation

For report decisions, collect all outstanding questions for each report on one plain-language page, with a clearly separated complete question, options, consequences, and recommendation for each.
Keep one page per report rather than scattering its questions across gate transcripts or partial messages.
Check every question against the complete source finding or captain message before forwarding it.
Never pass on a cut-off question or invent its missing words: retrieve the full source first, and report the missing source as a blocker if it cannot be recovered.
Use the page as the decision surface and link supporting technical evidence instead of making the captain decode raw gate output.

State all five of these elements in each concise, evidence-first question:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
