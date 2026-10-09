#!/usr/bin/env bash
# Executable-interface coverage for the separate home-local board input/projection.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-board-snapshot)
BOARD="$ROOT/bin/fm-live-board-snapshot.sh"
FLEET="$ROOT/bin/fm-fleet-snapshot.sh"
MODE="$ROOT/bin/fm-project-mode.sh"
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
home() {
  mkdir -p "$TMP_ROOT/$1/"{data,state,config,projects}
  printf '%s\n' "$TMP_ROOT/$1"
}
check() { jq -e "$2" "$1" >/dev/null || fail "$3"; }
collect() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z \
    "$FLEET" --live-board-input > "$2"
}
render() { "$BOARD" --json --input "$1" > "$2"; }

h=$(home empty)
FM_HOME="$h" "$BOARD" --json > "$TMP_ROOT/empty.json"
check "$TMP_ROOT/empty.json" '.schema == "fm-live-board.v1" and .counts.open_tasks == 0
  and (.projects|length == 0) and .coverage.local.shown == 0
  and any(.omissions[]; .kind == "registry-unavailable")
  and any(.omissions[]; .kind == "backlog-unavailable")
  and any(.omissions[]; .kind == "registered-homes-uncollected")
  and .coverage.local.complete == false' 'empty board must disclose unavailable sources'
pass 'empty home is explicit, not an all-fleet clear verdict'

h=$(home registry)
cat > "$h/data/projects.md" <<'REG'
- alpha [no-mistakes-prod-only +yolo preview-on-push] - private descriptive context (added 2026-01-01)
- beta [direct-PR] - fixture (added 2026-01-01)
- typo [unknown-mode +yolo] - fixture (added 2026-01-01)
- alpha [local-only] - duplicate (added 2026-01-01)
REG
FM_HOME="$h" "$MODE" --list-json > "$TMP_ROOT/registry.json"
check "$TMP_ROOT/registry.json" '.present and .duplicates == ["alpha"]
  and (.projects|length == 3)
  and any(.projects[]; .name == "alpha" and .mode == "no-mistakes-prod-only" and .yolo == "on")
  and any(.projects[]; .name == "typo" and .recognised == false and .mode == "no-mistakes" and .yolo == "off")' 'registry enumeration loses registered posture or duplicate disclosure'
[ "$(FM_HOME="$h" "$MODE" alpha)" = 'no-mistakes on' ] || fail 'mechanical mode mapping changed'
[ "$(FM_HOME="$h" "$MODE" --raw alpha)" = 'no-mistakes-prod-only on' ] || fail 'raw mapping changed'
FM_HOME="$h" "$BOARD" > "$TMP_ROOT/portfolio.json"
check "$TMP_ROOT/portfolio.json" '(.projects|length == 3) and .counts.open_tasks == 0
  and any(.warnings[]; .kind == "duplicate-project-registration")
  and any(.warnings[]; .kind == "unrecognised-project-posture")' 'idle registry or posture warnings absent'
pass 'registry enumeration reuses mechanical posture, preserves idle projects and discloses duplicates'

h=$(home inventory)
cat > "$h/data/backlog.md" <<'BACKLOG'
## In flight
- [ ] rollup - Program rollup (repo: alpha) (kind: program)
- [ ] missing - Missing worker (repo: alpha) (kind: ship)
- [ ] stale - Still underway (repo: alpha) (kind: ship)
## Queued
- [ ] queue - Queued without worker (repo: beta) (kind: ship)
- [ ] no-repo - Unassigned task (kind: scout)
- [ ] duplicate - First identity (repo: alpha) (kind: ship)
- [ ] duplicate - Other project identity (repo: beta) (kind: ship)
Unstructured current work must be disclosed.
## Done
- [x] landed - Landed task (repo: alpha) (kind: ship) (merged 2026-07-24)
BACKLOG
fm_write_meta "$h/state/stale.meta" 'kind=ship' 'harness=claude' 'project=contradiction'
printf 'blocked [at=1700000000]: historical blocker\ncontinuation text\n' > "$h/state/stale.status"
fm_write_meta "$h/state/metadata-only.meta" 'kind=scout' 'project=metadata-project'
fm_write_meta "$h/state/landed.meta" 'kind=ship' 'project=alpha'
collect "$h" "$TMP_ROOT/inventory-input.json"
render "$TMP_ROOT/inventory-input.json" "$TMP_ROOT/inventory.json"
check "$TMP_ROOT/inventory.json" '.counts.open_tasks == 8
  and ([.projects[].tasks[] | select(.id == "duplicate")]|length == 2)
  and ([.projects[].tasks[] | select(.id == "landed")]|length == 0)
  and any(.projects[]; .name == null and .label == "Unassigned")
  and any(.warnings[]; .kind == "project-conflict" and .id == "stale")
  and any(.warnings[]; .kind == "duplicate-backlog-id")
  and any(.warnings[]; .kind == "missing-worker-metadata" and .id == "missing")
  and any(.warnings[]; .kind == "metadata-without-backlog" and .id == "metadata-only")
  and any(.omissions[]; .kind == "unstructured-open-work" and .count == 1)
  and (.coverage.local.trustworthy | not) and .coverage.local.complete == false
  and any(.projects[].tasks[]; .id == "queue" and .state == "queued" and .current_state == null)
  and any(.projects[].tasks[]; .id == "rollup" and .role == "program" and .current_state == null)
  and any(.projects[].tasks[]; .id == "stale" and .project == "alpha"
    and .last_meaningful_event.verb == "blocked"
    and .current_state.state == "unknown")' 'complete local inventory, roles or conflict provenance incorrect'
# Replay a canonical current-state observation; it must never be derived from history.
jq '(.tasks[] | select(.id == "stale") | .current_state) =
  {state:"working",source:"pane",detail:"semantic busy",observed_at:"2026-07-25T00:00:00Z",freshness:"fresh"}
  | (.tasks[] | select(.id == "metadata-only") | .current_state.state) = "done"' \
  "$TMP_ROOT/inventory-input.json" > "$TMP_ROOT/working-input.json"
render "$TMP_ROOT/working-input.json" "$TMP_ROOT/working.json"
check "$TMP_ROOT/working.json" 'any(.projects[].tasks[]; .id == "stale" and .state == "working"
  and .current_state.source == "pane" and .last_meaningful_event.verb == "blocked")
  and any(.projects[].tasks[]; .id == "metadata-only" and .state == "finished-awaiting-processing")' 'historical event overrode current state or runtime done implied landed'
pass 'full open inventory retains programs, queued work, conflicting repo/id and current-state provenance'

h=$(home holds)
{
  printf '## In flight\n\n## Queued\n'
  for i in $(seq 1 25); do
    printf -- '- [ ] call-%02d - Call %s (repo: alpha) (kind: captain) (priority: 3) (since 2026-07-20) (hold: urgent in prose is not priority) (hold-kind: captain)\n' "$i" "$i"
  done
  printf '%s\n' \
    '- [ ] urgent-new - Urgent new (repo: alpha) (kind: captain) (priority: 0) (hold: choose) (hold-kind: captain)' \
    '  Captain hold set: 2026-07-24T00:00:00Z' \
    '- [ ] urgent-old - Urgent old (repo: alpha) (kind: captain) (priority: 1) (hold: choose) (hold-kind: captain)' \
    '  Captain hold set: 2026-07-23T00:00:00Z' \
    '- [ ] aged - Aged call (repo: alpha) (kind: captain) (since 2026-06-01) (hold: choose) (hold-kind: captain)' \
    '- [ ] deferred - Deferred call (repo: alpha) (kind: captain) (hold: choose) (hold-kind: captain) (hold-until: 2026-08-01)' \
    '- [ ] blocked - Blocked call blocked-by: missing (repo: alpha) (kind: captain) (hold: choose) (hold-kind: captain)' \
    '- [ ] unknown-date - Unknown date (repo: beta) (kind: captain) (hold: choose) (hold-kind: captain)' \
    '## Done'
} > "$h/data/backlog.md"
collect "$h" "$TMP_ROOT/holds-input.json"
render "$TMP_ROOT/holds-input.json" "$TMP_ROOT/holds.json"
check "$TMP_ROOT/holds.json" '.counts.questions == 31 and .counts.open_tasks == 31
  and .projects[0].name == "alpha" and .projects[0].questions[0].id == "urgent-new"
  and .projects[0].questions[1].id == "urgent-old"
  and .projects[0].questions[2].id == "call-01"
  and any(.projects[].questions[]; .id == "aged" and .hold.bucket == "aged")
  and any(.projects[].questions[]; .id == "deferred" and .hold.bucket == "dated")
  and any(.projects[].questions[]; .id == "blocked" and .hold.bucket == "blocked" and .unresolved_blockers == ["missing"])
  and all(.projects[].questions[]; .answerable == false)
  and .coverage.local.shown == 31 and .coverage.local.truncated == false
  and .coverage.local.complete == true' 'questions were capped, prose-ranked, hidden or auto-answerable'
pass 'more than twenty holds retain all buckets with structured priority and oldest-first order'

h=$(home events)
fm_write_meta "$h/state/history.meta" 'kind=scout' 'project=alpha'
sha=0123456789abcdef0123456789abcdef01234567
printf 'blocked [at=100]: historical blocker\nmilestone [at=101] [name=local-proof] [sha=%s]: passed proof\ncontinuation that mentions done\ndone in bare prose\nmilestone [at=102] [name=local-proof]: malformed\nworking [key=bad/key]: invalid event\n' "$sha" > "$h/state/history.status"
collect "$h" "$TMP_ROOT/event-input.json"
check "$TMP_ROOT/event-input.json" '.tasks[0].last_meaningful_event.type == "measurement"
  and .tasks[0].last_meaningful_event.name == "local-proof"
  and .tasks[0].last_meaningful_event.emitted_at_epoch == 101' 'strict milestone did not win append order or invalid tails hid it'
printf 'note: unknown-time note\ncontinuation\n' >> "$h/state/history.status"
collect "$h" "$TMP_ROOT/unknown-input.json"
check "$TMP_ROOT/unknown-input.json" '.tasks[0].last_meaningful_event.verb == "note"
  and .tasks[0].last_meaningful_event.emitted_at_epoch == null
  and .tasks[0].last_meaningful_event.age_seconds == null' 'legacy event time was inferred'
printf 'resolved [at=oops] [key=api]: captain chose route\n' >> "$h/state/history.status"
collect "$h" "$TMP_ROOT/resolved-input.json"
check "$TMP_ROOT/resolved-input.json" '.tasks[0].last_meaningful_event.verb == "resolved"
  and .tasks[0].last_meaningful_event.emitted_at_epoch == null' 'resolution lost or malformed event time invented'
printf 'note [at=10:30]: malformed readable clock\n' >> "$h/state/history.status"
collect "$h" "$TMP_ROOT/clock-input.json"
check "$TMP_ROOT/clock-input.json" '.tasks[0].last_meaningful_event.verb == "note"
  and .tasks[0].last_meaningful_event.note == "malformed readable clock"
  and .tasks[0].last_meaningful_event.emitted_at_epoch == null' 'malformed clock swallowed event head or note'
pass 'strict append-order history accepts milestones and resolutions, skips malformed tails, preserves unknown time'

# A secondmate status decision is not an independently answerable hold.
h=$(home decisions)
fm_write_meta "$h/state/mate.meta" 'kind=secondmate' 'project=alpha' 'remote_host=fixture.invalid'
printf 'needs-decision [key=api]: owner must register context\n' > "$h/state/mate.status"
collect "$h" "$TMP_ROOT/decision-input.json"
render "$TMP_ROOT/decision-input.json" "$TMP_ROOT/decision.json"
check "$TMP_ROOT/decision.json" '.counts.questions == 0
  and any(.warnings[]; .kind == "owner-must-register-call" and .decision.key == "api")' 'status-fold decision became answer mechanism or vanished'
pass 'unregistered keyed calls remain owner-registration warnings, not another answer path'

# The projection is an allowlisted serialized protocol, not a raw-state dump.
jq '.tasks[0].private_extra = "private fixture sentinel"
  | .tasks[0].paths.private_file = "private fixture sentinel"
  | .tasks[0].last_meaningful_event.raw = "private fixture sentinel"
  | .tasks[0].pr = {url:"file:///not-a-PR",source:"meta"}
  | .backlog.records = [{state:"queued",structured:false,raw:"private fixture sentinel"}]' \
  "$TMP_ROOT/event-input.json" > "$TMP_ROOT/privacy-input.json"
render "$TMP_ROOT/privacy-input.json" "$TMP_ROOT/privacy.json"
check "$TMP_ROOT/privacy.json" '([.. | strings | select(contains("private fixture sentinel"))]|length == 0)
  and .projects[0].tasks[0].pr.url == null
  and ([.. | objects | select(has("paths") or has("raw") or has("body_lines") or has("actions"))]|length == 0)
  and (.revision | test("^[0-9a-f]{64}$"))' 'projection leaked non-allowlisted data or unsafe link'
render "$TMP_ROOT/privacy-input.json" "$TMP_ROOT/privacy-again.json"
cmp "$TMP_ROOT/privacy.json" "$TMP_ROOT/privacy-again.json" || fail 'replay not deterministic'
# Same task ids in separate homes must never share keys.
jq '.fm_home += "-other-home"' "$TMP_ROOT/privacy-input.json" > "$TMP_ROOT/other-home-input.json"
render "$TMP_ROOT/other-home-input.json" "$TMP_ROOT/other-home.json"
[ "$(jq -r '.projects[0].tasks[0].key' "$TMP_ROOT/privacy.json")" != "$(jq -r '.projects[0].tasks[0].key' "$TMP_ROOT/other-home.json")" ] || fail 'home-qualified identities collided'
pass 'allowlisted replay strips raw paths/bodies, rejects unsafe links and qualifies ids by home'

for change in '.schema = "unexpected.v2"' '.tasks = {}' '.backlog.records[0].id = 42'; do
  jq "$change" "$TMP_ROOT/inventory-input.json" > "$TMP_ROOT/bad-input.json"
  if "$BOARD" --input "$TMP_ROOT/bad-input.json" > "$TMP_ROOT/bad-out" 2> "$TMP_ROOT/bad-err"; then fail 'malformed input succeeded'; fi
  [ ! -s "$TMP_ROOT/bad-out" ] || fail 'malformed input produced partial board'
done
pass 'unknown or malformed input fails closed without partial board output'

# The opt-in fields must not leak into either original default contract.
h=$(home compatibility)
printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"
fm_write_meta "$h/state/default.meta" 'kind=ship' 'project=alpha'
printf 'note: original historical tail\n' > "$h/state/default.status"
FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$FLEET" --json > "$TMP_ROOT/default-fleet.json"
check "$TMP_ROOT/default-fleet.json" '.schema == "fm-fleet-snapshot.v1"
  and (has("registry") or has("coverage") | not)
  and (.tasks[0] | has("last_meaningful_event") | not)
  and .tasks[0].paths.status_log.last_event.note == "original historical tail"' 'opt-in board fields leaked into default fleet output'
FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$TMP_ROOT/default-bearings.json"
check "$TMP_ROOT/default-bearings.json" '.schema == "fm-bearings.v1" and (has("projects") | not)' 'board portfolio leaked into Bearings'
pass 'default canonical and original Bearings contracts remain separate from the live board'


# Only owner-authored, current, unique context can supply answer semantics.
h=$(home context)
context='{"schema":"fm-captain-question.v1","close":"release","lifecycle":"2026-07-24T00:00:00Z#0","options":[{"value":"go","label":"Go café"}],"recommendation":"go","subject":{"artifact":"widget","version":"1.2.3"}}'
{
  printf '## In flight\n\n## Queued\n'
  for id in valid-release valid-done invalid duplicate stale legacy unsupported duplicate-member ambiguous; do
    printf -- '- [ ] %s - Choose widget (repo: alpha) (kind: ship) (hold: choose) (hold-kind: captain)\n' "$id"
    printf '  Captain hold set: 2026-07-24T00:00:00Z\n'
    case "$id" in
      valid-release|ambiguous) printf '  Captain question context: %s\n' "$context" ;;
      valid-done) printf '  Captain question context: %s\n' "$(printf '%s' "$context" | jq -c '.close = "done"')" ;;
      invalid) printf '%s\n' '  Captain question context: {not JSON}' ;;
      unsupported) printf '  Captain question context: %s\n' "$(printf '%s' "$context" | jq -c '.schema = "future.v2"')" ;;
      duplicate) printf '  Captain question context: %s\n  Captain question context: %s\n' "$context" "$context" ;;
      stale) printf '  Captain question context: %s\n' "$(printf '%s' "$context" | jq -c '.lifecycle = "2026-07-23T00:00:00Z#0"')" ;;
      duplicate-member) printf '%s\n' '  Captain question context: {"schema":"fm-captain-question.v1","close":"done","close":"release","lifecycle":"2026-07-24T00:00:00Z#0"}' ;;
    esac
  done
  printf '%s\n' '- [ ] ambiguous - Other owning row (repo: beta) (hold: choose) (hold-kind: captain)' \
    '  Captain hold set: 2026-07-24T00:00:00Z'
  printf '  Captain question context: %s\n' "$context"
  printf '\n## Done\n'
} > "$h/data/backlog.md"
collect "$h" "$TMP_ROOT/context-input.json"
render "$TMP_ROOT/context-input.json" "$TMP_ROOT/context-board.json"
check "$TMP_ROOT/context-board.json" '.counts.questions == 10
  and ([.projects[].questions[] | select(.answerable)] | map(.id) | sort) == ["valid-done","valid-release"]
  and any(.projects[].questions[]; .id == "valid-release" and .context.close == "release"
    and .context.options == [{value:"go",label:"Go café"}]
    and .context.recommendation == "go" and .context.subject.version == "1.2.3")
  and any(.projects[].questions[]; .id == "duplicate" and .context_status == "duplicate")
  and any(.projects[].questions[]; .id == "stale" and .context_status == "stale")
  and any(.projects[].questions[]; .id == "legacy" and .context_status == "legacy")
  and all(.projects[].questions[] | select(.id == "ambiguous"); .answerable == false)
  and all(.projects[].questions[] | select(.id == "invalid" or .id == "unsupported" or .id == "duplicate-member");
    .answerable == false and .context == null)
  and ([.. | objects | select(has("body_lines") or has("raw"))] | length == 0)' \
  'context projection lost explicit mode/options or exposed ambiguous/malformed calls as answerable'
# Summary transport preserves the same validated field but remains bounded,
# and adding it must not alter the original Bearings decision digest.
FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z \
  "$FLEET" --secondmate-home-summary > "$TMP_ROOT/context-summary.json"
check "$TMP_ROOT/context-summary.json" 'any(.decisions_open[]; .id == "valid-release" and .question_context.context.close == "release")
  and any(.queued[]; .id == "valid-done" and .question_context.context.close == "done")' \
  'home summary dropped the canonical owner context'
FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z \
  "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$TMP_ROOT/context-bearings.json"
check "$TMP_ROOT/context-bearings.json" 'all(.decisions_open[]; has("question_context") | not)' \
  'safe context changed the original Bearings digest'
# A malformed replayed structured field is not trusted merely because it says ready.
jq '(.backlog.records[] | select(.id == "valid-release") | .question_context.context).private_extra = "private context sentinel"
  | (.backlog.records[] | select(.id == "valid-done") | .question_context.status) = "private context sentinel"' \
  "$TMP_ROOT/context-input.json" > "$TMP_ROOT/context-malformed-input.json"
render "$TMP_ROOT/context-malformed-input.json" "$TMP_ROOT/context-malformed-board.json"
check "$TMP_ROOT/context-malformed-board.json" 'all(.projects[].questions[]; .answerable == false)
  and ([.. | strings | select(contains("private context sentinel"))] | length == 0)' \
  'replayed context bypassed the validator or leaked non-allowlisted data'
pass 'canonical owner context preserves explicit modes and summaries; legacy, stale, duplicate and malformed calls stay read-only'
