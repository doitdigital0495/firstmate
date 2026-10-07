# Upstream integration verification - 2026-10-06

Reconciliation checkpoint, not a merge-ready or deployment claim. The initial
ancestry integration joins upstream `e06a46fec726071618da0460f0de552d4d078ef1`
and fork `524e4105fbd46343c68c0048b2e331c428788097`. A fresh fetch on
2026-10-07 found four more upstream commits, through
`237e1cf3b035e20c151e8233a0ab842bd1e94e2d`; those require a subsequent real
merge and final validation. Fork main is unchanged.

## Verified at this checkpoint

All suites below ran through `bin/fm-test-run.sh --jobs 1` in the isolated task
worktree. No live Herdr lifecycle or authenticated live harness was driven.

| Check | Observed result | What it establishes |
| --- | --- | --- |
| `tests/fm-brief.test.sh` | exit 0, 2026-10-06 | Combined branch/base/forge contracts, fork request accounting, home-private addenda/include, and generated-worker instructions |
| `tests/fm-dispatch-resolve.test.sh` | exit 0; 50,448 ms; 2026-10-06T19:38:40Z | OpenRouter/default and direct fallback, batched Choices, per-rule floors and low-confidence runner-up-pool isolation, minimized brief text, never-send checks, per-seat snapshots, completeness/retry gates, schema-5/6 joins, and quota-tier profile preference |
| `tests/fm-worker-account.test.sh` | exit 0, 2026-10-06 | Claude/Pi pins, sign-in refusals, credential shedding, lean Pi provider/model flags, raw-command protections, and local secondmate pinning |
| `tests/fm-worker-account-precedence.test.sh` | exit 0; 8,379 ms | Conflicting registered seats refuse before quota/trust/metadata/launch; matching seats use the same recorded/launched store; legacy relaunch bindings, absent pins, and ordinary Claude identity |
| `tests/fm-backend-tmux-smoke.test.sh` | exit 0; 219 ms | Real create/send/capture/list/kill and missing-endpoint classification on a task-owned private tmux socket with disposable `HOME` |
| `bin/fm-lint.sh` | exit 0 | ShellCheck 0.11.0 and actionlint 1.7.12; three workflow files valid |
| `bin/fm-doc-audience-check.sh` | exit 0 | Audience and local-link check: 122 surfaces, 744 links at the preceding checkpoint |
| `bin/fm-test-run.sh --check-coverage` | exit 0 | 262 scripts; complete/disjoint portable partition; nine serial shards; maximum hinted serial weight 1,088,067 ms within 1,200,000 ms |

The serial weights conservatively retain the larger prior fork/upstream sample
for each overlapping script. The new precedence suite uses the local measured
8,379 ms sample above; it is a scheduling hint, not a CI performance claim.

## Root causes corrected during reconciliation

- `bin/fm-worker-account-lib.sh` owns the effective-store rule. A configured
  worker pin is authoritative; conflicting explicit or recorded bindings refuse.
  Spawn resolves it before consuming gates; control reconciles before stop.
- Resolver evidence construction now binds the complete evidence object before
  consulting profile preference. Binding only the added fallback object silently
  lost the preference even though it still appeared in rendered output.
- Schema-6 plan labels use the same provider/account join as quota eligibility,
  not the first row for a provider.
- Schema-6 fixtures carry measured reset evidence. A missing account remains
  incomplete and never permits selecting around it; it is not weakened into an
  eligible, unranked alternative.

## Broad integration run

The serial run completed all 26 requested scripts: 17 reported exit 0 and nine
reported exit 1. These are per-script log receipts, **not a green aggregate**.
The driver then reported a final parsing error and did not produce its planned
JSON artifact. Its file had been edited while it was running; current
`bash -n bin/fm-test-run.sh` succeeds. Freeze the runner before a clean rerun.

Passing scripts included controller relaunch (including changed-pin pre-stop
refusal), Claude lean/settings, Pi trust, local/remote compact-adviser controls,
endpoint-safe teardown, quota intake/choice, home identity, fake tmux/Herdr/cmux
backend contracts, busy-adapter wiring, AI-trailer stripping, and both lint
contract suites. The Herdr suite uses a fake CLI, not live lifecycle.

Failures requiring environment help:

- Installed `tasks-axi` is 0.2.5; `bin/fm-tasks-axi-lib.sh` requires 0.2.6 plus
  update and atomic multi-ID move features. This blocked teardown, Orca/Zellij
  scout teardown, and secondmate lifecycle handoff.
- Pi export rendering found a Chrome wrapper but no working user-owned browser.
  No browser installation or shared dependency update was attempted.

Failures requiring further semantic reconciliation:

- Spawn-dispatch-profile secondmate environment assertions failed.
- Pi-skill exact launch expectations omit the combined inbox and Git-hook wiring.
- Claude-admission command equality includes different generated operational
  inbox record paths; validate semantics rather than weakening shaping checks.
- Devin hook configuration failed to compile a jq expression using `$end`.

No EXIT=143/OOM result was observed. The missing aggregate remains a failure,
not a waiver.

## Dependency recovery and regression receipts - 2026-10-07

Firstmate authorized an isolated `tasks-axi@0.2.6` installation. The exact tool
used is
`/home/daan/.treehouse/.firstmate-500bef/3/.firstmate/.no-mistakes/merge-prep/tools/node_modules/.bin/tasks-axi`.
Its bin directory is prepended to `PATH` only for test invocations. The shared
`~/.npm-global` installation and production compatibility requirement are
unchanged. Pi export uses
`FM_CHROME_BIN=/home/daan/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome`
and `LD_LIBRARY_PATH=/home/daan/.local/share/agentic-chrome/lib` only for the test
process; no browser installation or existing profile modification was needed.

The recovery run produced a valid JSON receipt: nine suites, eight passes and
one dispatch-profile expectation failure. After correcting that expectation,
the complete dispatch-profile suite passed (230,296 ms, ending
2026-10-07T06:32:49Z). Thus all nine formerly failing suites now have individual
passing receipts; a fresh complete aggregate is still required.

| Corrected owner | Root cause and proof |
| --- | --- |
| `bin/fm-spawn.sh` | Secondmate home assignments must be exports across a compound launch, not assignments affecting only its first command. Dispatch-profile now executes captured launches under available sh/bash/zsh with an explicit Codex store and verifies child home, filtering, cleared state override, and preserved store. |
| `tests/fm-spawn-dispatch-profile.test.sh` | Parse Claude argument carriers with `shlex`, not by slicing at semicolons inside the system prompt; preserve required `--add-dir` grants and correct shell quoting in the exact launch expectation. Complete suite exit 0. |
| `tests/fm-spawn-pi-skill.test.sh` | Exact launch expectation retains both task-inbox and Git-hook wiring. Exit 0. |
| `tests/fm-claude-admission.test.sh` | Use an isolated user home. Validate each typed home-local launch-brief record and its exact body, then normalize only the nonce-bearing record path before command-byte comparison. Exit 0; shaping assertions remain. |
| `bin/fm-devin-config.sh` | Rename jq's reserved `$end` variable to `$session_end`. Devin contracts exit 0. |
| Dependency-blocked suites | Teardown, Orca, Zellij, and secondmate lifecycle all exit 0 with the isolated compatible tool. |
| Pi rendering | Calm/export suite exit 0 with the selected browser; no authenticated live model or live Herdr claim. |

Canonical lint passed again after these corrections. Recovery receipts are
retained as `recovery-tests-1.json`, `dispatch-profile-recovery-2.json`, and
`lint-recovery.log` in the ignored preparation directory. The earlier invalid
26-script aggregate remains historical failed evidence and is not reclassified.

## Still pending

- Frozen-runner complete aggregate and remaining harness/backend review,
  notification retirement, standing-answer, and newly fetched upstream
  regressions.
- Final marker/diff/document checks, real merge commit and ancestry proof,
  no-mistakes exact-head review, fork PR, and CI-green receipt.
- Captain-approved merge-commit landing and installation update belong to
  Firstmate after delivery; this checkpoint claims neither.
