# Upstream merge conflict decisions — 2026-10-06 task

The initial real ancestry merge had 124 conflicts. Classification used the already-integrated content baseline `a09090d1` only for comparison; merge parents and upstream commit identities were not rewritten. Initial classes: 50 upstream-equivalent, three fork-only, 18 independent unions, and 53 substantive reconciliations. Later merges through `237e1cf3` and `53b5bc11` applied cleanly.

“Both” means retaining complementary upstream and intentional fork contracts, not choosing one implementation wholesale. The side column compares final content against the original fork and the latest captured upstream; task-specific safety/test fixes may make it differ from both.

| File | Side retained | Resolution and reason |
| --- | --- | --- |
| `.agents/skills/afk/SKILL.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `.agents/skills/bearings/SKILL.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `.agents/skills/harness-adapters/references/harness/claude.md` | Both / task fixes | Keep upstream verification ownership and fork generated out-of-worktree settings, account identity, and shaping guarantees. |
| `.agents/skills/harness-adapters/references/harness/pi.md` | Both / task fixes | Keep upstream Pi launch/TUI contracts and fork provider/model separation, selected-account display and credential binding. |
| `.agents/skills/project-management/SKILL.md` | Both / task fixes | Combine upstream project/forge/base ownership with fork project delivery/preview contracts. |
| `.agents/skills/quota-array-dispatch/SKILL.md` | Both / task fixes | Keep upstream typed resolver owner and fork no-selection-before-complete-account/window-evidence rule. |
| `.claude/mods/firstmate-calm/.claude-plugin/plugin.json` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `.claude/mods/firstmate-calm/hooks/register.ts` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `.claude/mods/firstmate-calm/lib/fm-calm-presentation.ts` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `.claude/mods/firstmate-calm/lib/fm-operational-input.ts` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `.claude/mods/firstmate-calm/tests/calm.test.ts` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `.claude/mods/firstmate-calm/tests/support.ts` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `.github/workflows/ci.yml` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `.no-mistakes.yaml` | Both / task fixes | Upstream configuration plus authorized task safety: disable automatic CI repair without skipping CI, because v1.79 conflict repair rebases. |
| `.pi/extensions/fm-branch-supervision.ts` | Both / task fixes | Keep fork native stock outcomes rendering; remove the unused duplicate formatter and preserve upstream supervision behavior. |
| `.pi/extensions/fm-primary-pi-watch.ts` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `.pi/extensions/lib/fm-branch-dispatch.ts` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `AGENTS.md` | Both / task fixes | Combine current upstream ownership/triggers with fork identity, review authority, request accounting, and dual local/remote URL requirements. |
| `CONTRIBUTING.md` | Fork | Retain fork contribution/delivery guidance; this integration requires captain-approved merge-commit landing. |
| `README.md` | Both / task fixes | Combine upstream capabilities/owners with fork launch, account, quota, and delivery guarantees. |
| `bin/backends/herdr.sh` | Both / task fixes | Combine upstream protocol/backend capabilities with fork isolated non-default lifecycle protection; validation uses a fake CLI. |
| `bin/fm-afk-return.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-backlog-transition-lib.sh` | Both / task fixes | Combine upstream atomic backend transitions with fork safety, metadata and task accounting. |
| `bin/fm-bootstrap.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `bin/fm-branch-prompt.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-brief.sh` | Both / task fixes | Combine upstream task minimization/branch contracts with fork home-private addenda, standing-answer delegation, and request accounting. |
| `bin/fm-captain-hold.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-classify-lib.sh` | Both / task fixes | Combine upstream event classification with fork stale presentation/notification retirement and account-aware state. |
| `bin/fm-claude-stop-autoarm.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-claude-trust.sh` | Both / task fixes | Combine upstream trust registration with fork selected-store identity and generated-settings ownership. |
| `bin/fm-composer-lib.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-config-inherit-lib.sh` | Both / task fixes | Keep one option list with both upstream additions and fork shaped-store settings. |
| `bin/fm-contributions.jq` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-contributions.sh` | Both / task fixes | Keep fork contribution/actor coverage and upstream bounded observation/retirement in one implementation. |
| `bin/fm-control-lib.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `bin/fm-control.sh` | Both / task fixes | Combine upstream lifecycle/picker/generation cleanup with fork locked metadata and authoritative pre-stop account reconciliation. |
| `bin/fm-crew-state.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-dispatch-resolve.sh` | Both / task fixes | Combine upstream typed/minimized/floor/schema contracts with fork batched Choices, account completeness, quota-tier preference, and isolated fallback pools. |
| `bin/fm-dod-lib.sh` | Both / task fixes | One compatible API: upstream forge/base/branch plus fork data/lane/preview/state; retain exact-head review and immediate dispatch. |
| `bin/fm-env-lib.sh` | Fork | Retain fork home/session environment ownership and credential-context separation. |
| `bin/fm-fleet-snapshot.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-inactive-reconcile.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `bin/fm-lease-lib.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-lint.sh` | Both / task fixes | Combine upstream bounded ShellCheck/source-following with fork host/CI and workflow-lint contracts. |
| `bin/fm-merge-outcome-lib.sh` | Both / task fixes | Combine current upstream ownership/features with the corresponding fork guarantees; remove obsolete duplicate ownership. |
| `bin/fm-nm-run-lib.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `bin/fm-pending-reply-lib.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-pr-check.sh` | Both / task fixes | Combine current upstream ownership/features with the corresponding fork guarantees; remove obsolete duplicate ownership. |
| `bin/fm-pr-lib.sh` | Both / task fixes | Combine current upstream ownership/features with the corresponding fork guarantees; remove obsolete duplicate ownership. |
| `bin/fm-pr-merge.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `bin/fm-pr-poll.sh` | Both / task fixes | Combine current upstream ownership/features with the corresponding fork guarantees; remove obsolete duplicate ownership. |
| `bin/fm-project-mode.sh` | Both / task fixes | Combine upstream project/forge/base modes with fork preview/priority context. |
| `bin/fm-promote.sh` | Both / task fixes | Combine upstream promotion/branch/forge contracts with fork lane, custody and immediate validation requirements. |
| `bin/fm-quota-axi-lib.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-send.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `bin/fm-session-lock-lib.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-spawn.sh` | Both / task fixes | Combine upstream launchers, pins, task grants and base branches with fork one-store routing, admission, identity, generated settings, and compound child-home exports. |
| `bin/fm-teardown.sh` | Both / task fixes | Retain fork proven legacy recovery, Git-2.34 containment, settings dirt protection and notification retirement while adopting upstream backends/base branches. |
| `bin/fm-test-run.sh` | Both / task fixes | Keep complete/disjoint coverage and host safety; retain the larger previous duration sample for overlapping tests. |
| `bin/fm-wake-lib.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `bin/fm-watch.sh` | Both / task fixes | Combine upstream reduced polling/supervision/backends with fork stale-event handling and home-scoped safeguards. |
| `docs/agent-control.md` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `docs/architecture.md` | Both / task fixes | Combine upstream ownership/forge/supervision changes with fork account, safety, and review boundaries. |
| `docs/calm-mode-feasibility.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `docs/calm.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `docs/captain-hold-lifecycle.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `docs/configuration.md` | Both / task fixes | Combine both public configuration contracts; retain strict completeness and document upstream additions without copying private configuration. |
| `docs/documentation-audiences.json` | Both / task fixes | Union current upstream documentation inventory with fork supported surfaces. |
| `docs/fm-test-portable-shards.md` | Both / task fixes | Keep upstream partition ownership and fork conservative scheduling/host evidence. |
| `docs/herdr-backend.md` | Both / task fixes | Combine current upstream backend mechanics with fork isolated/default-session protection. |
| `docs/pi-supervision-branch.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `docs/remote-secondmates.md` | Both / task fixes | Combine upstream remote/channel continuity with fork home/session/account separation. |
| `docs/scripts.md` | Both / task fixes | Union script owners while retaining fork-owned safety/account helpers. |
| `docs/secondmate-parent-channel.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `docs/sessionstart-nudge.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `docs/supervision-protocols/pi.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `docs/turnend-guard.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `docs/verification/dispatch-auth.md` | Both / task fixes | Keep fork account/store identity evidence and current typed resolver ownership; refresh dated integration receipts separately. |
| `docs/verification/dispatch-resolve.md` | Both / task fixes | Keep both historical receipts and fork stricter account/window completeness; current results are in the dated integration evidence. |
| `docs/verification/runtime-backends.md` | Both / task fixes | Keep upstream backend capability evidence and fork isolated-lifecycle limitations; do not claim mocks as live proof. |
| `docs/watcher-continuity.md` | Both / task fixes | Combine upstream polling/event owners with fork stale-notification retirement. |
| `tests/captures/no-mistakes-v1.70.1/README.md` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-backend-orca.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-backend.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-bootstrap.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/fm-branch-supervision.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-brief.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/fm-calm-claude-mod-live-e2e.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-calm-claude-mod-plugin.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-calm-claude-mod.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-calm-pi-extension.test.sh` | Both / task fixes | Keep fork rendering/export safety and upstream current SDK/widget/PID/timing behavior; verify with the real installed SDK and selected browser. |
| `tests/fm-captain-hold-lifecycle.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-classify-corr-token.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-classify-decision-key.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-composer-lib.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-contributions.test.sh` | Both / task fixes | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-control-relaunch.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/fm-crew-state.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-dispatch-resolve.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-gotmp.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-herdr-lab.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-inactive-reconcile.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/fm-kimi-harness.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-lint.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-pi-branch-extension.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/fm-pi-primary-live-e2e.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-pi-watch-extension.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/fm-pr-check-security.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-pr-merge.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-remote-reply.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-secondmate-harness.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-secondmate-lifecycle-e2e.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-secondmate-liveness.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-send-resolve-key.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-session-lock-ancestry.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/fm-spawn-compact-adviser-disable-remote.test.sh` | Fork | Retain the intentional fork-only delta; no competing upstream delta required replacing it. |
| `tests/fm-spawn-compact-adviser-disable.test.sh` | Upstream | No fork-only content delta at the integrated baseline; accept current upstream implementation. |
| `tests/fm-spawn-dispatch-profile.test.sh` | Both / task fixes | Retain both launcher matrices; execute compound secondmate environments and verify typed Claude carriers and mandatory directory grants. |
| `tests/fm-task-delivery.test.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |
| `tests/fm-teardown-endpoint-safety.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/fm-teardown.test.sh` | Both / task fixes | Retain upstream lifecycle/backend coverage and fork Git-2.34, landed-content, legacy binding and project-settings dirt regressions. |
| `tests/fm-wake-queue.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/fm-watch-triage.test.sh` | Both / task fixes | Combine independent additions so neither side loses its distinct contract. |
| `tests/lib.sh` | Both / task fixes | Combine upstream executable coverage with fork safety regressions; reconcile fixtures against the preserved public interface rather than weakening production checks. |

## Additional reconciliation fixes

- `bin/fm-worker-account-lib.sh` and new precedence tests own captain-selected authoritative pin reconciliation.
- `bin/fm-devin-config.sh` uses `$session_end`, not jq’s reserved `$end`.
- Backend-refusal fixtures use disposable user/Firstmate homes instead of resolving the operator home.
- Contribution task-name expectations use positional jq arguments, avoiding jq-1.6 trailing-NUL split behavior.
- Pi fixtures render vendor-owned call components through their public interface and keep real SDK/export comparisons.
- Test-only tooling uses isolated tasks-axi 0.2.6 and an existing Python 3.12; no global dependency or daemon is updated.
- `bin/fm-brief-heading-lib.sh` has one trailing newline, removing upstream EOF whitespace without changing behavior.
