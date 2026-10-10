# Upstream integration verification — 2026-10-06 task

Local reconciliation evidence, not a CI-ready, landing, or deployment claim.
The final frozen expanded aggregate passed 54/54 without skips through captured
`ac0811c4`, including strict Pi types, watcher continuity and project capacity.
Fresh remotes still report that upstream target and unchanged fork main.
The separately authorized single real-agent tmux E2E passed through `53b5bc11`;
it is not claimed as a repeat against the later tree. No-mistakes exact-head
review, fork PR and CI readiness remain pending.

## Source snapshots and ancestry

- Fork main: `524e4105fbd46343c68c0048b2e331c428788097`, unchanged on fresh fetches.
- Initial upstream target: `e06a46fec726071618da0460f0de552d4d078ef1`.
- Initial real merge: `78adb3c05ca668a3a2459e4f09464eaa59d6805d`; parents are the fork and initial upstream above.
- Four subsequent upstream commits through `237e1cf3b035e20c151e8233a0ab842bd1e94e2d` were merged in `5f30cb817083fb8e87f2296d2c2cf5622315f2a8`, whose parents are the initial merge and that upstream target.
- Shared Calm working-widget target `53b5bc11035877d1eb0e675d37414815d5d485f2` was integrated in real checkpoint `5a529c6231698c34043ca5c1caf5519f4ba7fbf4`, parents `5f30cb817083fb8e87f2296d2c2cf5622315f2a8 53b5bc11035877d1eb0e675d37414815d5d485f2`.
- Validated target `47aff866dbe0612bd43df66d8fa76576e06a2b3e` adds resume-lock opt-in, watcher TERM and worker-tool exclusions. Its real merge had three conflicts, all resolved. The captain explicitly approved replacing fork commit `17c15625`'s intentional always-wait default with upstream bounded/refuse behavior plus `--herdr-resume-lock-wait`. A portable production-code regression covers default contention, opt-in wait and failed-wait refusal without contacting Herdr. The frozen 53-suite aggregate passed.
- Fourth real merge checkpoint `f87be8ba632c5520da102bbf8e53715b9d59f5b4` has parents `5a529c6231698c34043ca5c1caf5519f4ba7fbf4 47aff866dbe0612bd43df66d8fa76576e06a2b3e` and records the 53-suite passing receipt.
- Latest captured upstream is `ac0811c4c820d82009d7a3b8f09555cbf38340c8`, adding opt-in machine-local project capacity. Its complete 11-file diff was reviewed and applied in a clean real merge with parents `f87be8ba632c5520da102bbf8e53715b9d59f5b4 ac0811c4c820d82009d7a3b8f09555cbf38340c8`. The identical contribution-clock fixture fix was deduplicated; fork quota/account/teardown protection remains unchanged. The new capacity preflight passed all 16 cases in 58,626 ms, ending `2026-10-07T16:44:02Z`, without skips. No operational capacity setting was created. The final frozen 54-suite aggregate passed.
- No rebase or squash was used. The [per-file conflict decisions](upstream-merge-2026-10-06-conflicts.md) cover the initial 124 conflicts and the latest three-path reconciliation; the two intervening integrations applied without conflicts.

## Recovered test environment

All tests use `bin/fm-test-run.sh --jobs 1`. The final invocation has a disposable
HOME and an empty inherited environment, with only explicit non-secret runtime
paths/settings supplied. The aggregate drives no live Herdr lifecycle,
authenticated model or operational home monitoring. The separately authorized
single real-agent tmux E2E below uses actual Claude authentication.

Firstmate authorized isolated `tasks-axi@0.2.6`. The exact test tool is
`/home/daan/.treehouse/.firstmate-500bef/3/.firstmate/.no-mistakes/merge-prep/tools/node_modules/.bin/tasks-axi`.
Its bin directory is prepended to PATH only for tests. The global installation
and production compatibility/features gate are unchanged.

Kimi requires `tomllib`; an existing Python 3.12.14 at
`/home/daan/.local/share/uv/python/cpython-3.12.14-linux-x86_64-gnu/bin/python3`
is selected through test-only PATH. No interpreter or dependency was installed.

Pi export uses the existing Chromium at
`/home/daan/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome`, with
`LD_LIBRARY_PATH=/home/daan/.local/share/agentic-chrome/lib` for the test process.
No browser installation or existing profile modification was needed.

## Executable root-cause regressions

| Owner | Correction and observed proof |
| --- | --- |
| `bin/fm-worker-account-lib.sh` | One effective-store rule makes configured pins authoritative; conflicting explicit or recorded seats refuse before consumers. Account/precedence and pre-stop relaunch suites pass. |
| `bin/fm-dispatch-resolve.sh` | Bind complete jq evidence before preference; join plan labels by provider/account; use the fallback rule's own candidate pool. Complete resolver suite passes, with measured schema-6 fixtures and no selection around missing evidence. |
| `bin/fm-spawn.sh` | Export secondmate child-home context across compound launches, rather than applying assignments only to their first command. Captured launches execute under available sh/bash/zsh with an explicit Codex store and prove filtering, child home, cleared state override, and retained store. |
| `tests/fm-spawn-dispatch-profile.test.sh` | Parse carriers with `shlex`, not semicolon slicing inside quoted prompts; retain mandatory directory grants and correct exact shell quoting. Complete suite passes. |
| `tests/fm-control-relaunch.test.sh` | A trace fixture's 500-poll launch wait was not the synchronization contract. Keep bounded 3,000-poll waits, report failed launch output, and exercise a deliberately delayed fake launch. The actual trace handshake and serialized metadata assertions pass; recovery reached prepare after 844 polls, beyond the old limit. |
| `tests/fm-spawn-pi-skill.test.sh` | Exact command retains inbox and Git-hook wiring; suite passes. |
| `tests/fm-claude-admission.test.sh` | Use an isolated fixture user home; validate each typed home-local launch-brief record and its exact body, then normalize only the nonce path before byte comparison. Shaping assertions pass unchanged. |
| `bin/fm-devin-config.sh` | Replace reserved jq `$end` with `$session_end`; Devin contracts pass. |
| `tests/fm-backend.test.sh` | Negative-backend cases now explicitly select disposable user and Firstmate homes. Their previous empty overrides resolved the operator home and hit identity refusal before backend validation. The identity protection is not weakened; the complete suite passes. |
| `tests/fm-contributions.test.sh` | Serialize expected task names through jq positional args; jq 1.6 NUL splitting otherwise removed the final real name. Complete contribution suite passes. |
| `tests/fm-pi-branch-extension.test.sh` | Vendor-owned call components are tested through `render()`, not a private Text carrier; the SDK stub models versioned call headers. Complete suite passes, including installed SDK, native execution, and HTML export comparisons. |

## Frozen aggregate receipts

The earlier 26-script run is historical failed evidence: 17 per-script passes,
nine failures, a final parsing error, and no JSON artifact. Source had changed
while the driver ran; it is not reclassified as green.

After tooling and implementation corrections, the first fresh expanded run
produced valid JSON (`integration-tests-3.json`):

```text
FM_TEST_SUMMARY total=49 failed=4 skipped_gate=0 duration_ms=3592068
runner_exit=1
```

It ended `2026-10-07T08:00:29Z`. The frozen runner's SHA-256 before and after was
`3baddc9e7aacffb39ef87dea41dc35e4c423d6326be1bf4d50be538ed0d61eda`.
The four failures were backend fixture isolation, missing default-interpreter
`tomllib`, Pi mock/header carrier expectations, and jq-1.6 fixture serialization.
All now have complete individual passing receipts:

- Backend: 28,789 ms; Kimi: 68,873 ms; contributions: 177,453 ms, in `extended-recovery-1.json`.
- Pi branch: 76,926 ms, ending `2026-10-07T08:42:04Z`, in `pi-branch-recovery-2.json`.

These individual receipts do not substitute for the final frozen aggregate.
`integration-tests-4.json` reran all 49 against the latest captured upstream,
existing compatible Python, and corrected fixtures:

```text
FM_TEST_SUMMARY total=49 failed=0 skipped_gate=0 duration_ms=3954895
runner_exit=0
```

It ended `2026-10-07T10:29:11Z`. Before/after tracked-tree hashes matched
`4c706a3e0c76b4900b0d0df1b80eaf6e5d2eabdd`; runner hashes also matched.
Additional installed-SDK account-display coverage passed (5,223 ms). The first
strict types run skipped for missing `tsc`; that receipt remains partial.
After isolated tooling authorization, TypeScript 5.9.3 was installed only in
`.no-mistakes/merge-prep/typescript/`, without top-level package/lock changes.
`final-pi-account-types-2.json` passed both suites without skips in 8,964 ms,
ending `2026-10-07T10:43:24Z`, including:

```text
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.86.1
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=8964
```

After the captain's resume-lock decision, `integration-tests-5.json` reran the
49 suites plus installed-SDK Pi account/types and watcher triage/wake-queue:

```text
FM_TEST_SUMMARY total=53 failed=0 skipped_gate=0 duration_ms=6125269
runner_exit=0
```

It ended `2026-10-07T16:29:19Z`, covering captured upstream `47aff866`.
Before/after tracked-tree hashes matched
`9868e6a4a32791510ec032b8b401557c37d10d5e`; runner SHA-256 matched the prior
runner hash above, and driver SHA-256 matched
`47f9ded41304ebbba02e8fbdc17e3ec60c08aa6fa6d743647448a12eaa94731c`.
All 53 script exits were independently checked as zero. No implementation,
runner or driver inputs changed during this aggregate. This receipt does not
claim proof of the later `ac0811c4` capacity change.

`integration-tests-6.json` then reran 54 suites through `ac0811c4`: 53 passed,
one control-relaunch trace wait failed, zero skips; 5,551,536 ms, ending
`2026-10-07T18:21:15Z`, exit 1. Tree
`12767c993ddc5926237cfde5d23f5e3fc3dc8f3c`, runner SHA-256
`806c50d558d4ad018243999419d270e858671e12511a7891585af69d5a7786f6` and driver
SHA-256 `6e232982a5f73003eed63a0dd72edb40b1ec27f7eb6c8ba2c6a0ac09a6d48020`
were unchanged. This complete receipt remains failed evidence.

The test-only handshake correction adds bounded host headroom and failure
output, not a production bypass. A six-second fake launch delay executes the
same real control/spawn path and serialized publication checks.
`control-recovery-4.json` passed the complete control-relaunch suite in
258,496 ms, ending `2026-10-07T18:33:54Z`, zero skips; its trace fixture needed
844 polling attempts, exceeding the former 500-poll guard. That individual
receipt alone did not establish a green fresh aggregate.

`integration-tests-7.json` then reran every one of the 54 suites:

```text
FM_TEST_SUMMARY total=54 failed=0 skipped_gate=0 duration_ms=5744080
runner_exit=0
```

It ended `2026-10-07T20:16:48Z`. Before/after tracked tree
`2ca7224d182acb37f41ef65abb731fd0934f9986`, runner SHA-256
`806c50d558d4ad018243999419d270e858671e12511a7891585af69d5a7786f6` and driver
SHA-256 `21b30d37a50d5e7fca332efdc5a4a69eea82e163361bddc3d0c2b98e61dc2bf3`
matched. Every script exit and zero skips were independently verified. The
delayed trace fixture prepared after 835 polls and retained the actual trace
handshake/serialized publication assertions. Only this dated evidence was
refreshed after the frozen run; no implementation, test or runner input changed.
Fresh upstream/fork refs remained `ac0811c4`/`524e4105`.

Passing expanded coverage includes every supported launch family represented
by the dispatch matrix and additional Agy, Cursor, Gemini, Grok, Kimi, Muse,
OMP, Rovo and Devin contracts; secondmate account/home/PID ancestry; mocked
runtime backends; Git-2.34 landed-content and project-settings dirt checks;
legacy endpoint authorization; notification retirement; standing-answer
routing/private brief addenda; new busy-generation, remote continuity, startup
growth and contribution regressions; and real private-socket tmux E2E.

No EXIT=143/OOM was observed. Herdr tests use a fake CLI, not live lifecycle.
The latest standalone-Calm slot comparison additionally discloses when the
optional separate extension is absent; shared-slot replacement/disposal behavior
is still exercised, not claimed as a live dual-install proof.

## Single authorized real-agent E2E

After captain authorization for normal trust/CLI session bookkeeping, one real
Claude `opus low` scout launched with explicit `--backend tmux`, fresh quota
record (240 seconds old at spawn) and a trivial no-op brief. HOME, Firstmate
home, scratch Git repository, local origin, Treehouse pool and tmux socket were
fixture-owned. No credential copying, private-store edits by the worker,
guard bypass or live Herdr was used.

The real agent confirmed its physical isolated worktree and matching Git
top-level, left the repository clean, wrote `E2E_NOOP_PROCESSED` and a report,
and appended a done status accounting `asks 1/1`. First teardown correctly
refused a missing completion inventory: the fixture's restrictive tool list
had prevented the agent from running that step. After reviewing the full
report, the owner recorded the empty inventory through `complete --none`;
teardown passed, the worker endpoint was absent, and only the private fixture
server was stopped. One agent launch; no second E2E. Finished
`2026-10-07T13:57:23Z`.

Ignored receipts: `run-live-e2e.log` retains the initial cleanup refusal;
`live-e2e-1/cleanup-result.log`, `inventory.log`, `teardown-2.log`, the owned
agent report/status and endpoint capture record final proof. No production
safety gate was weakened, and the first driver exit is not claimed as green.

## Pipeline ancestry protection

Installed no-mistakes is `v1.79.0 (fc540ac)`; its official tag resolves to
`fc540aca86bd1ab35daad31c2a2fb20b652f82ab`. Version-matched
[repository configuration documentation](https://github.com/kunchenguid/no-mistakes/blob/v1.79.0/docs/src/content/docs/reference/repo-config.md)
provides the relevant evidence:

> Set to `0` to disable the follow-up auto-fix loop for a step (findings require manual approval).

> `auto_fix.ci` covers the CI step's CI failure and merge-conflict auto-fix attempts.

> A CI merge-conflict repair is the exception: it rebases onto the base branch whichever strategy is set.

Accordingly the configuration used by this integration sets `auto_fix.ci: 0`;
the driver also skips startup rebase with `--skip rebase`. This disables
automatic CI repairs, including non-conflict CI repairs, **not CI validation**.
Review, Test, Document and Lint remain required. The repository override is
visible in the proposed change; global/private daemon configuration is untouched.
Firstmate explicitly authorized aborting this assigned run if it proposes or
performs any rebase/history-rewriting conflict repair. A merge-strategy field
alone is not protection, and its trusted-default-branch setting is not changed.

## Canonical checks and remaining proof

- Canonical lint passed after the original recovery; it must pass again at the final checkpoint.
- Documentation audience inventory now explicitly classifies both dated evidence files as maintainer verification.
- Coverage before final corrections: 263 scripts, 24 parallel, 223 portable serial, nine serial shards, 16 separately gated Herdr scripts; maximum hinted serial weight 1,093,063 ms below the 1,200,000 ms budget.
- Scheduling hints retain the larger previous fork/upstream sample. Local durations are evidence, not CI performance claims.
- Final aggregate passed 54/54 without skips through `ac0811c4`. Canonical pre-aggregate lint, syntax/diff, documentation audience/link and coverage checks passed.
- Strict installed-SDK types and credential-safe account display both pass with the authorized test-only compiler.
- `AGENTS.md:453-455` real-agent lifecycle proof passed once with the captain-authorized `opus low` tmux fixture, fresh quota intake, endpoint confirmation, empty captain-call inventory and guarded teardown.
- Current fork guarantees were reviewed at their production owners and exercised by the final aggregate: generated Claude settings and release shaping, authoritative account/home/session identity, quota completeness, Git-2.34 containment, locked legacy endpoint recovery, contradiction checks, notification retirement, Pi account display, dual URL instructions, isolated Herdr safeguards, host/CI hardening, private brief addenda and standing answers. Only the captain-approved resume-lock default is intentionally replaced.
- Final checks/current-target ancestry are recorded by the integration commit and external milestone/report; no-mistakes exact-head coverage, fork PR and CI-green receipt remain pending.
- Captain-approved merge-commit landing and installation update belong to Firstmate after delivery; none is claimed here.
