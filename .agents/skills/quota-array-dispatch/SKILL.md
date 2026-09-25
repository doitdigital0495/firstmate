---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array from quota-axi's default TOON, gathering complete window evidence
  for every candidate before ranking by spendPriority, splitting
  runway-limited work, and reserving Claude orchestration capacity
  alongside shaped-store committed demand.
  Load when a dispatch rule or default resolves to more than one profile candidate,
  and before treating a store listed in config/claude-shaped-store as having headroom.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is the single owner of the completion-aware profile-array selection procedure.
`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning/tie safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`quota-axi` remains data-only: it publishes `spendPriority` as a comparable scalar and never recommends, selects, ranks, or infers a route.
Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy, or producer-side route recommendation.
Deterministic shell owns only schema, configuration, and version validation plus concrete spawn safeguards; every model-to-provider, provider-to-credential, and quota-applicability relation is yours to establish transparently and to show your evidence for.

## Worker-side quota helper

The canonical shell helper for a worker that has already performed its model-selection reasoning and now needs to pick the first viable candidate is `bin/fm-quota-choose.sh`.
Pass it the intake's already-captured default TOON or permitted JSON fallback through stdin or `--snapshot`; it never takes another quota snapshot, so it selects from the same quota state as the intake.
Pass each candidate as `harness:model`, with earlier candidates preferred.
The helper maps each harness to its primary provider family and applies the provider-wide scopes plus the exact model or product scopes for the model.
An `exhausted_now` runway vetoes the candidate.
The helper selects a candidate only when its applicable quota has a known `effectivePercentRemaining` greater than zero.
It does not warm an unknown pool, re-read quota, split a task, or reserve Claude orchestration capacity; do not use its result as an array-selection decision when any of those judgments is outstanding.
This is an optional narrow helper with a known limitation: it maps each harness to one primary provider family only, so a candidate whose established provider differs from that primary family is checked against the wrong quota row.
omp has no primary family, so the helper keys an `omp:` candidate on its model prefix, mapping only `openai-codex/` and `claude-bridge/` and refusing every other prefix; the helper's header owns that mapping.
Authoritative multi-provider routing - including provider discovery from the harness catalog and quota matching by that explicit provider - stays owned by this skill's intake procedure above and AGENTS.md section 4, not by the helper.
Use it only when the brief already fixed the candidate order and every candidate's provider is the harness's primary family.
It does not replace the reasoning-class, runway-feasibility, or authentication gates above.
Firstmate can optionally arm `bin/fm-procevent-quota.sh` for a recurring mid-task check that wakes when the tracked provider drops below its configured threshold or its runway becomes `exhausted_now`.
The opt-in `bin/fm-dispatch-resolve.sh` (`docs/configuration.md` "Typed dispatch resolution") applies the same eligibility gates and `spendPriority` argmax in code after a typed rule match; it never removes this skill's authority, and its `incomplete`, `ambiguous`, `escalate`, and `error` outcomes return here.

## Read the default TOON

Start each intake by running `quota-axi` with no `--json` for the home's default account.
For each distinct named-account store triple referenced by a candidate, read that home's `config/accounts.json` and require `crossAccount.enabled == true` plus an allowlisted account; otherwise mark that candidate `not eligible: cross-account routing disabled` without probing its store.
Read one additional `quota-axi` snapshot per eligible distinct store triple with `CLAUDE_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, and `CODEX_HOME` pinned to that entry; use only that store's snapshot for its candidates, then rank the union with the same spendPriority procedure.
A home with no `crossAccount` block keeps the default-only intake unchanged, and a home with only the Geris registry entry cannot dispatch a personal candidate.
Reuse each snapshot for its candidates until an unknown pool requires the bounded retry below.
Post-consolidation quota-axi (the floor owned by `bin/fm-quota-axi-lib.sh`) puts `spendPriority` in the default `quota[]` block beside `effectivePercentRemaining`, `runway`, `confidence`, `limitedBy`, and `resetsAt`.
Sparse `exhaustion[]` carries finite-runway seconds only for `projected_exhaustion` and `exhausted_now`.
Sparse `attention[]` names auth, stale, and unmeasurable facts.
`spendPriority` is THE quota-perspective ranker.
It already computes the economics that older instructions reconstructed by hand from headroom, pace, reserve, and window-id lists; do not recompute those.
Do not read `--json` on the normal path, and do not reach for `--full` to rebuild that economics.

After reading each store's TOON, fall back to one env-pinned `quota-axi --json` call for that store only when its TOON is genuinely ambiguous for the decision, or when the installed quota-axi is somehow below the floor so its TOON lacks `spendPriority`.
Ambiguous means a candidate's `spendPriority` is the literal `unknown` or unmeasurable, a real tie still needs extra evidence, or a candidate's eligibility is unclear from `quota[]` plus `attention[]`.
Reuse its JSON result to identify the unknown pools before the bounded warm-up and retry below; do not let the fallback's still-unknown reading settle a choice.
Below-floor is rare: bootstrap enforces `FM_QUOTA_AXI_MIN` and normally reports `MISSING` before dispatch; if an intake somehow reaches an older build whose TOON lacks `spendPriority`, use the defensive `--json` fallback rather than treating the missing scalar as healthy.
`--json` is a defensive belt, not a habit; never reach for it because it feels more complete.
Read `quota-axi auth --json` only when a candidate's credential surface is in question.

For each candidate, preserve explicit `harness`, `model`, and `provider`; `harness-adapters` owns identity, and model/provider never infer harness.
Establish the subscription plan for that candidate's actual account and provider from quota-axi plan metadata where published, then vendor profile plan fields where available, then the declared `config/accounts.json` plans map documented in `docs/configuration.md`.
Show the plan and its source (or `unknown` and the missing evidence) for every candidate, including ineligible ones; unknown is uncertainty, never a block.
Consider the plan's allowance size when interpreting comparable percentages and task runway: equal remaining percentages on a Pro and a Max seat do not mean equal absolute capacity.
Do not invent a numeric conversion or override the published spendPriority scalar with an unsupported tier ranking; explain any plan-based judgment in the choice rationale.

## Committed demand on a shaped Claude credential store

`quota-axi` reports point-in-time headroom, and at a subscription window's reset instant that reading is at its most misleading: every Claude Code session holding the vendor's own auto-continue timer for that edge is one second from firing, and none of them has spent anything yet.
A home can declare which Claude credential stores carry that hazard in `config/claude-shaped-store`.
When a `harness=claude` candidate's store is listed there, read `bin/fm-claude-admission.sh demand` once alongside the intake TOON and discount that candidate's headroom and ranking by what it reports.

Keep the two readings distinct and both visible in the rationale.
`quota-axi`'s `effectivePercentRemaining` and `spendPriority` stay exactly what the producer published; the census is a separate subtrahend you apply in the open, never folded back into the published scalar and never used to rewrite it.
`parkedSessions` is the count of live parked sessions, and `floorInputTokens` is their measured floor: one resumed turn each, at each session's own observed average billable input tokens per turn.
It is a floor, not a forecast - a resumed session runs a burst of turns, not one - so treat a candidate whose remaining window is close to that floor as already committed rather than free, and say so.

This applies only to a store the home actually lists.
An unlisted store, including the default personal one, has no census to read and no discount to apply, and a Claude candidate on it is ranked from `quota-axi` alone exactly as before.
The census is evidence, never a route: it can lower a shaped candidate's standing, and it never selects, blocks a candidate on its own, or authorizes pausing authorized work.
An unreadable census is disclosed uncertainty for the ranking, the same as any other unmeasurable fact, and the script's own refusal is what stops a launch.

## Gates, unknown pools, spendPriority, then runway

Follow these steps in order: eligibility and reasoning-class fit first, resolve unknown pools, then rank by `spendPriority` and assess runway and the Claude reserve.
`spendPriority` cannot override a hard-gate failure, and it is never hidden inside a new composite score.
A runway-only failure on the top-ranked candidate can produce a bounded slice, never a full-task launch.

### 1. Eligibility

Deterministic shell must never map a model to a provider, a provider to a credential store, or a name prefix to a family.
You establish those relations yourself, in the open, from the candidate's own authoritative catalog (`harness-adapters` owns the per-harness discovery surface) plus the one intake snapshot.

Confirm the catalog lists the candidate's model and record the provider family it reports.
A model the catalog does not list is concrete contradictory evidence: block that candidate and quote the catalog result.
Apply quota at the granularity the vendor actually supplies.
A provider-level or `all_models`/`all_products` scope bounds every model you established in that family, including one with no window of its own.
A named-model or named-product scope is an additional bound for that model alone.
Match the candidate to its `quota[]` row by that established provider and scope; a stale, auth-required, or unmeasurable scope is named in `attention[]` instead of a fabricated number.

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the candidate actually uses rather than collapsing a provider to a single status.
A provider can carry a healthy source beside a missing or expired one; the unused source's state is not the candidate's state.
A Pi-hosted family may authenticate through the vendor's own store with no `pi:`-prefixed source at all, which is normal and never evidence against the candidate.

Uncertainty and ineligibility are different findings:

- No model-level window or no matching auth source is disclosed uncertainty, not proof of a bad credential.
  A known provider-wide bound can still supply the applicable quota when no model-level window exists; a quota-axi-unmodeled surface or an applicable scope reading `unknown` is a quota-evidence gap to resolve before ranking, not a reason to choose a known competitor early.
- An expired credential is a short-lived session token the owning vendor renews on next use, not a sign-out.
- Only concrete contradictory evidence blocks: an authoritative catalog proving the model unsupported, or proof that the credential the candidate actually selects is unusable.
- Reserve login wording for that proven-unusable case, and name the harness, model, surface, and evidence.

When a credential's local classification is the only thing standing between a candidate and a block, get ground truth before blocking.
`bin/fm-vendor-auth-probe.sh` is the only approved vendor-credential probe; its `--help` owns the registered probes and mechanics.
It takes no harness, model, or provider and returns a fact, not a route: only `authenticated` and `unauthenticated` are ground truth, while `indeterminate`, `timeout`, and `unavailable` establish nothing and must never be read as either outcome.
Never launch a vendor CLI yourself, and never probe a credential store the candidate does not use.
Grok prepaid `credits` are unrelated to paid-window headroom; never read them as exhaustion.

Malformed configuration is an actionable error, not a candidate to rank around.

### 2. Reasoning-class fit

Keep only candidates that meet the required reasoning class for this task (a simple bug fix versus very-difficult design).
Never use `spendPriority` or remaining quota to silently replace that class.
When every remaining candidate is tight, dispatch inside the strongest-reasoning class if one of those candidates can proceed, or stop and report that the strongest-class choice cannot proceed rather than downgrading it to spend or conserve quota.

### 3. Resolve unknown pools before ranking

After catalog, authentication, and reasoning-class checks, identify every eligible candidate whose applicable pool is unknown in headroom, `spendPriority`, runway, or quota applicability; missing model-specific quota alone is not unknown when a known provider-wide bound applies.
Do not compare known candidates or pick one until every candidate still in this choice has complete limit information - every applicable window's remaining percent and reset time, weekly and session alike - or the whole choice is incomplete; never resolve an unknown by dropping a candidate.
For each distinct unknown pool with a known warm-up, invoke that pool's warm-up once on demand, not on a timer; today the only known warm-up is `zai-window-warm` for Z.ai, which pings glm-5.3-flash once to open its rolling window.
This is an approved pool warm-up, not a candidate authentication probe or permission to launch another harness's CLI for model discovery; do not substitute an arbitrary vendor command when the helper is absent or fails.
After attempting the available warm-ups, re-read `quota-axi` once for the choice, including pools without a warm-up, and re-evaluate all candidates against the new snapshot.
Use default TOON first and the narrow `--json` fallback only if needed to disambiguate that retry; do not loop or repeatedly ping to force a number.
If an applicable pool is still unknown after that one retry, the whole choice is incomplete: record the attempted or unavailable warm-up and both readings, name each candidate's missing windows, wait for the published retry time or the next reset, and re-run the choice; never pick by hand, drop a candidate, or treat the unknown as healthy.
An unavailable warm-up does not stall the choice forever: its missing measurement still makes this choice incomplete now, and the report names the unavailable warm-up rather than guessing or silently switching reasoning class.
An absent auth source remains disclosed uncertainty rather than proof of failed login, but never fabricates quota evidence for an unmodeled pool.

### 4. Rank by spendPriority

Among catalog-eligible candidates in the required reasoning class with resolved quota evidence, compare the known `spendPriority` values first, then assess their runway feasibility in descending rank order.
A higher known scalar is better: positive means paid allowance is on track to reach reset unused, `0` is exact utilization, and negative means overdrawn against the reset clock.
Rank only from comparable known scalars.
Never treat absent, `unknown`, or unmeasurable `spendPriority` as zero or as healthy; `0` means exact utilization, a different claim from unknown.
Show the scalar or the literal `unknown` in the rationale; do not hide it in a score.

Do not compare headroom against runway by hand.
Do not use pace or signed reserve as a later tie-break layer.
Do not read `aheadWindowIds`, `behindWindowIds`, `onPaceWindowIds`, `limitingWindowIds`, or other window-id lists to reconstruct what `spendPriority` already computed.

Genuine ties: stop and report every tied candidate for captain choice.
Do not select by array order, harness name, or another arbitrary identity ordering.
Report duplicate concrete profiles as a configuration error.

### 5. Runway feasibility, Claude orchestration reserve, and split

Establish an inspectable likely-completion horizon for the work before accepting a full-task launch.
Read `runway` from every applicable `quota[]` bound: `through_reset` passes the generic feasibility check because the window refills without exhausting; never compare its `resetsAt` with the completion horizon as though reset were an exhaustion deadline.
`exhausted_now` is zero, and `projected_exhaustion` uses the matching `exhaustion[]` row's `usableRunwaySeconds`.
Known runway shorter than the full-task horizon fails full-task feasibility even at the highest `spendPriority`; do not launch an unsliced job into a known stall.
Unknown or unmeasurable runway cannot prove feasibility: it must already have been resolved by the bounded warm-up and retry above, or the whole choice stays incomplete.
Do not invent a generic percentage floor, and honor an explicit captain floor for a candidate when one exists.

Firstmate itself spends Claude quota while orchestrating.
For a Claude worker, estimate Firstmate's Claude orchestration demand through each applicable reset from observed usage and already committed supervision work, then include the proposed worker task or slice on every shared credential store.
If the worker uses a different store, establish the worker's task-inclusive runway on its store and the orchestration runway on Firstmate's store separately; do not debit one store for another's demand.
Choose Claude only when the task-inclusive worker runway and Firstmate's orchestration runway still reach their respective resets; `through_reset` on a point-in-time reading alone is not proof that adding the worker preserves this reserve.
If the estimate cannot be supported by inspectable evidence, do not choose Claude on an assumed free reserve; report the uncertainty.
This is a demand forecast, not a new percentage floor, and is separate from the parked-session census on stores listed in `config/claude-shaped-store`.
Never apply the Claude reserve to a non-Claude candidate or subtract it from quota-axi's published scalar.

If the top-ranked candidate fails only full-task runway feasibility, first seek a concrete bounded slice that fits safely within its measured usable runway, with an independently inspectable deliverable and a clear checkpoint before exhaustion.
Dispatch only that slice to the top candidate and requeue the remaining work as a separate task for a fresh choice; neither promise that candidate the whole job nor silently discard the remainder.
For Claude, the slice must also preserve the orchestration reserve through reset; a reserve failure is not a runway-only split opportunity.
If no meaningful safe slice can be defined, do not dispatch it: consider the next ranked candidate that can complete the whole task, or stop and report when none can proceed.
A known `exhausted_now` runway offers no slice.
Do not alter the configured profile array or add a generic floor to manufacture a split.

If no candidate survives the known-evidence and feasibility checks, report the blocker instead of treating unknown as healthy or choosing arbitrarily.

## Account for every candidate

Account for every candidate visibly before selecting or escalating, naming its catalog evidence, provider relation and account plan with source, applicable quota and authentication facts, warm-up and retry outcome or missing windows, fit and reasoning class, `spendPriority`, runway-versus-horizon result, and any Claude reserve or split decision.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label.
