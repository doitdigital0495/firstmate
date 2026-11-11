#!/usr/bin/env bash
# Public task-history CLI: typed events, safe summaries, retries, concurrency,
# malformed input and storage refusal, with no harness/backend lifecycle calls.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-history)
mkdir -p "$TMP_ROOT"
export FM_STATE_OVERRIDE="$TMP_ROOT/state"
HISTORY="$ROOT/bin/fm-task-history.sh"
mkdir -p "$FM_STATE_OVERRIDE"

summary() { "$HISTORY" summary task; }
expect_json() { python3 -c "import json,sys; v=json.load(sys.stdin); assert $1, v"; }
summary | expect_json 'v["capability_failures"] == 0 and v["last_outcomes"] == []'
[ ! -e "$FM_STATE_OVERRIDE/task.history.jsonl" ] || fail 'empty summary created history'
printf 'harness=pi\nmodel=example\neffort=high\naccount=seat\nbusy_gen=attempt-1\n' > "$FM_STATE_OVERRIDE/task.meta"
"$HISTORY" append task launch-profile | expect_json 'v["event"]["profile"]["harness"] == "pi"'
for reason in infra usage-limit captain unknown; do
  "$HISTORY" append task relaunch --reason "$reason" >/dev/null
done
"$HISTORY" append task stall-escalation >/dev/null
summary | expect_json 'v["capability_failures"] == 0 and v["stall_escalations"] == 1 and len(v["last_outcomes"]) == 3'
pass 'crashes, quota moves, captain moves, unknowns and stalls do not climb the ladder'

"$HISTORY" append task relaunch --reason capability --event-id outcome-1 | expect_json 'v["appended"]'
"$HISTORY" append task relaunch --reason capability --event-id outcome-1 | expect_json 'not v["appended"]'
"$HISTORY" append task relaunch --reason capability --event-id another-notification >/dev/null
summary | expect_json 'v["capability_failures"] == 1 and len(v["failed_profiles"]) == 1'
"$HISTORY" append task relaunch --reason capability --attempt attempt-2 >/dev/null
"$HISTORY" append task relaunch --reason capability --attempt unknown >/dev/null
summary | expect_json 'v["capability_failures"] == 2'
if "$HISTORY" append task relaunch --reason infra --event-id outcome-1 2>/dev/null; then
  fail 'conflicting retry accepted'
fi
pass 'idempotent writes and distinct known-attempt capability counts'

pids=()
for n in 1 2 3 4 5 6 7 8; do
  "$HISTORY" append parallel stall-escalation --event-id "stall-$n" >/dev/null &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
"$HISTORY" read parallel | expect_json 'len(v) == 8 and len({r["id"] for r in v}) == 8'
pass 'concurrent appends preserve every complete record'

before=$("$HISTORY" read task)
for args in 'task invalid-event' 'task relaunch --reason crash' '../outside relaunch'; do
  # Deliberate word splitting supplies the invalid public CLI arguments.
  # shellcheck disable=SC2086
  if "$HISTORY" append $args >/dev/null 2>&1; then fail "accepted $args"; fi
done
if "$HISTORY" append task launch-profile --profile '{"note":"not a routing axis"}' >/dev/null 2>&1; then
  fail 'non-profile data accepted'
fi
[ "$before" = "$("$HISTORY" read task)" ] || fail 'invalid write changed history'
printf '{"broken":' > "$FM_STATE_OVERRIDE/broken.history.jsonl"
if "$HISTORY" append broken stall-escalation >/dev/null 2>&1; then fail 'appended to corrupt history'; fi
if "$HISTORY" summary broken >/dev/null 2>&1; then fail 'corrupt history looked empty'; fi
ln -s "$FM_STATE_OVERRIDE/task.history.jsonl" "$FM_STATE_OVERRIDE/link.history.jsonl"
if "$HISTORY" append link stall-escalation >/dev/null 2>&1; then fail 'followed history symlink'; fi
if "$HISTORY" read link >/dev/null 2>&1; then fail 'read history symlink'; fi
pass 'invalid inputs, corrupt history and symlink targets fail closed'

# Parsing refuses bad reason flags before resolving or touching any endpoint.
for args in 'relaunch --reason crash' 'relaunch --reason=' 'relaunch --reason' 'exit --reason infra'; do
  # shellcheck disable=SC2086
  if out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-control.sh" absent $args 2>&1); then
    fail "control accepted $args"
  fi
  assert_contains "$out" '--reason' 'reason refusal should explain the flag'
done
pass 'control rejects invalid, empty, missing and non-relaunch reason flags'
