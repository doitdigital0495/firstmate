#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-admission.sh and its two call sites.
#
# Every case drives the real script against a fixture Claude credential store
# built from synthetic transcripts, never a developer's own store: CLAUDE_CONFIG_DIR
# is always set explicitly so no case can read or depend on the host's real
# sessions. The spawn cases drive the real fm-spawn.sh with a fake tmux that
# records the literal launch command, so "unchanged" is asserted against the
# command firstmate would actually run rather than against source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADMISSION="$ROOT/bin/fm-claude-admission.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-admission)
mkdir -p "$TMP_ROOT"

# --- fixtures ---------------------------------------------------------------

# make_store <dir>: an empty Claude credential store with a projects root.
make_store() {
  local dir=$1
  mkdir -p "$dir/projects/-fixture"
  printf '%s\n' "$dir"
}

# add_turn_then_park <store> <session-id> <park-age-seconds> <billable-tokens>
# One real assistant turn followed by Claude Code's own auto-continue park
# notice, which is the shape a session left waiting on a reset edge has.
add_turn_then_park() {
  local store=$1 session=$2 age=$3 tokens=$4 file
  file="$store/projects/-fixture/$session.jsonl"
  FM_T_SESSION=$session FM_T_AGE=$age FM_T_TOKENS=$tokens python3 - > "$file" <<'PY'
import datetime, json, os, time

session = os.environ["FM_T_SESSION"]
age = int(os.environ["FM_T_AGE"])
tokens = int(os.environ["FM_T_TOKENS"])
park = datetime.datetime.utcfromtimestamp(time.time() - age).isoformat() + "Z"
print(json.dumps({
    "type": "assistant", "sessionId": session,
    "message": {"id": "msg-" + session, "model": "claude-opus-5",
                "usage": {"input_tokens": tokens, "cache_creation_input_tokens": 0,
                          "cache_read_input_tokens": 0}},
}))
print(json.dumps({
    "type": "system", "subtype": "informational", "level": "notice",
    "sessionId": session, "timestamp": park,
    "content": "Usage limit reached · continuing automatically at 8:20pm · esc or type to cancel",
}))
PY
}

# add_resumed_session <store> <session-id>: parked, then resumed and still
# working. Committed demand it is not: the resume and the later turn are both
# after the park.
add_resumed_session() {
  local store=$1 session=$2 file
  file="$store/projects/-fixture/$session.jsonl"
  FM_T_SESSION=$session python3 - > "$file" <<'PY'
import datetime, json, os, time

session = os.environ["FM_T_SESSION"]
stamp = datetime.datetime.utcfromtimestamp(time.time() - 60).isoformat() + "Z"
print(json.dumps({
    "type": "system", "subtype": "informational", "level": "notice",
    "sessionId": session, "timestamp": stamp,
    "content": "Usage limit reached · continuing automatically at 8:20pm · esc or type to cancel",
}))
print(json.dumps({
    "type": "system", "subtype": "informational", "level": "notice",
    "sessionId": session, "timestamp": stamp,
    "content": "Usage limit reset · continuing automatically",
}))
print(json.dumps({
    "type": "assistant", "sessionId": session,
    "message": {"id": "after-" + session, "model": "claude-opus-5",
                "usage": {"input_tokens": 1234, "cache_creation_input_tokens": 0,
                          "cache_read_input_tokens": 0}},
}))
PY
}

# make_home <dir> [shaped-store ...]
make_home() {
  local home=$1 store
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  for store in "$@"; do
    printf '%s\n' "$store" >> "$home/config/claude-shaped-store"
  done
  printf '%s\n' "$home"
}

# admission <home> <store> <args...>: run the script with an explicit home and
# an explicit credential store, and echo combined output.
admission() {
  local home=$1 store=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    CLAUDE_CONFIG_DIR="$store" \
    FM_CLAUDE_RELEASE_INTERVAL="${FM_TEST_INTERVAL:-420}" \
    FM_CLAUDE_HEAD_MAX_WAIT="${FM_TEST_HEAD_WAIT:-3600}" \
    FM_CLAUDE_DEMAND_HORIZON="${FM_TEST_HORIZON:-1800}" \
    "$ADMISSION" "$@" 2>&1
}

# The watcher keeps a check's STDOUT and discards its stderr (bin/fm-watch.sh),
# so every poll wake assertion must be made against stdout ALONE: a refusal that
# only reaches stderr is the silent-forever regression this coverage exists for.
# admission_poll runs the poll with stderr diverted to $ADMISSION_STDERR, so a
# case can assert both what firstmate sees and what it does not.
ADMISSION_STDERR="$TMP_ROOT/admission.stderr"
admission_poll() {  # <home> <store> <args...>
  local home=$1 store=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    CLAUDE_CONFIG_DIR="$store" \
    FM_CLAUDE_RELEASE_INTERVAL="${FM_TEST_INTERVAL:-420}" \
    FM_CLAUDE_HEAD_MAX_WAIT="${FM_TEST_HEAD_WAIT:-3600}" \
    FM_CLAUDE_DEMAND_HORIZON="${FM_TEST_HORIZON:-1800}" \
    "$ADMISSION" "$@" 2>"$ADMISSION_STDERR"
}

store_state_dir() {  # <home>
  local dir
  dir=$(find "$1/state/claude-admission" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
  printf '%s\n' "$dir"
}

# --- cases ------------------------------------------------------------------

test_unshaped_store_takes_no_state() {
  local case_dir home store out
  case_dir="$TMP_ROOT/unshaped"
  store=$(make_store "$case_dir/store")
  home=$(make_home "$case_dir/home")

  out=$(admission "$home" "$store" gate task-a) \
    || fail "a home with no shaped-store list must admit every Claude launch"
  assert_contains "$out" "is not shaped by this home" \
    "an unlisted store must be named as unshaped"
  assert_absent "$home/state/claude-admission" \
    "an unshaped store must leave no release-shaping state behind"

  printf '%s\n' "$case_dir/other-store" > "$home/config/claude-shaped-store"
  out=$(admission "$home" "$store" gate task-a) \
    || fail "a store the list does not name must still be admitted"
  assert_absent "$home/state/claude-admission" \
    "a store the list does not name must leave no release-shaping state behind"
  pass "an unshaped Claude credential store takes no state and no decision"
}

test_reset_herd_is_staggered_and_ordered() {
  local case_dir home store out status
  case_dir="$TMP_ROOT/herd"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  out=$(FM_TEST_INTERVAL=600 admission "$home" "$store" gate herd-a --priority 40) \
    || fail "the first launch onto a shaped store must be released"
  assert_contains "$out" "admitted: herd-a" "the first launch must be admitted"

  # The rest of the herd arrives inside the same slot.
  out=$(FM_TEST_INTERVAL=600 admission "$home" "$store" gate herd-b --priority 60); status=$?
  expect_code 1 "$status" "a second launch inside one release slot must be withheld"
  assert_contains "$out" "withheld: herd-b" "the withheld launch must be named"
  out=$(FM_TEST_INTERVAL=600 admission "$home" "$store" gate herd-c --priority 10); status=$?
  expect_code 1 "$status" "a third launch inside one release slot must be withheld"

  sleep 2
  # Highest priority first: herd-c (10) outranks herd-b (60) regardless of the
  # order the two were withheld in.
  out=$(FM_TEST_INTERVAL=1 admission "$home" "$store" gate herd-b --priority 60); status=$?
  expect_code 1 "$status" "lower-priority waiting work must not take the slot ahead of herd-c"
  assert_contains "$out" "herd-c is higher-priority waiting work" \
    "the refusal must name the task that takes the slot"
  out=$(FM_TEST_INTERVAL=1 admission "$home" "$store" gate herd-c --priority 10) \
    || fail "the highest-priority waiting task must take the next release slot"
  assert_contains "$out" "admitted: herd-c" "herd-c must be the released task"

  # And the next one is paced again rather than following immediately.
  out=$(FM_TEST_INTERVAL=600 admission "$home" "$store" gate herd-b --priority 60); status=$?
  expect_code 1 "$status" "the release after herd-c must be paced, not immediate"
  assert_contains "$out" "the next release slot opens in" \
    "a paced refusal must say when the next slot opens"
  pass "a reset-edge herd is staggered one release per interval, highest priority first"
}

test_withheld_work_is_durable_across_processes() {
  local case_dir home store out dir
  case_dir="$TMP_ROOT/durable"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  admission "$home" "$store" gate keep-a --priority 20 >/dev/null \
    || fail "the first launch must be released"
  FM_TEST_INTERVAL=600 admission "$home" "$store" gate keep-b --priority 30 >/dev/null 2>&1 \
    && fail "the second launch must be withheld"

  dir=$(store_state_dir "$home")
  [ -n "$dir" ] || fail "a shaped store must keep a durable record directory"
  assert_grep "keep-b" "$dir/queue" "the withheld task must be written to the durable queue"

  # A fresh process - the restart case - reads the same durable queue.
  out=$(admission "$home" "$store" queue)
  assert_contains "$out" "keep-b" "a new process must see the durable queue"
  assert_not_contains "$out" "keep-a" "a released task must not stay queued"

  # And the withheld task is still released later, not lost.
  sleep 2
  out=$(FM_TEST_INTERVAL=1 admission "$home" "$store" gate keep-b --priority 30) \
    || fail "durable queued work must be released once its slot opens"
  assert_contains "$out" "admitted: keep-b" "the queued task must be the released one"
  pass "a withheld launch stays durable across processes and is released later"
}

test_parked_demand_is_scoped_to_the_shaped_store() {
  local case_dir shaped plain shaped_home plain_home out
  case_dir="$TMP_ROOT/scoped"
  shaped=$(make_store "$case_dir/shaped")
  plain=$(make_store "$case_dir/plain")
  add_turn_then_park "$shaped" parked-1 60 250000
  add_turn_then_park "$plain" parked-2 60 250000
  shaped_home=$(make_home "$case_dir/shaped-home" "$shaped")
  plain_home=$(make_home "$case_dir/plain-home" "$shaped")

  out=$(admission "$shaped_home" "$shaped" demand)
  assert_contains "$out" "shaped=yes" "the listed store must report as shaped"
  assert_contains "$out" "parkedSessions=1" "the listed store's parked demand must be counted"
  assert_contains "$out" "floorInputTokens=250000" \
    "the floor must be the parked session's own measured input tokens per turn"

  # The same census run against the store the home does NOT list reports the
  # demand as evidence but shapes nothing, and its launches are never paced.
  out=$(admission "$plain_home" "$plain" demand)
  assert_contains "$out" "shaped=no" "a store the home does not list must report as unshaped"
  admission "$plain_home" "$plain" gate plain-a >/dev/null \
    || fail "an unshaped store's first launch must be admitted"
  admission "$plain_home" "$plain" gate plain-b >/dev/null \
    || fail "an unshaped store's second launch must be admitted immediately"
  admission "$plain_home" "$plain" gate plain-c >/dev/null \
    || fail "an unshaped store's third launch must be admitted immediately"
  assert_absent "$plain_home/state/claude-admission" \
    "parked demand on an unshaped store must not create release-shaping state"
  pass "parked demand paces only the store the home lists"
}

test_demand_ignores_resumed_and_stale_sessions() {
  local case_dir store home out
  case_dir="$TMP_ROOT/census"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" fresh-park 60 90000
  add_turn_then_park "$store" old-park 200000 90000
  add_resumed_session "$store" resumed
  home=$(make_home "$case_dir/home" "$store")

  out=$(admission "$home" "$store" demand)
  assert_contains "$out" "parkedSessions=1" \
    "only the live park with no later turn is committed demand"
  assert_contains "$out" "fresh-park" "the live parked session must be listed"
  assert_not_contains "$out" "resumed," "a resumed session must not count as committed demand"
  assert_not_contains "$out" "old-park," "a park older than the max age must not count"
  pass "the census counts only live parked sessions with no later real turn"
}

test_shaping_disarms_when_no_demand_remains() {
  local case_dir store home out
  case_dir="$TMP_ROOT/disarm"
  store=$(make_store "$case_dir/store")
  home=$(make_home "$case_dir/home" "$store")

  out=$(FM_TEST_HORIZON=0 admission "$home" "$store" gate calm-a) \
    || fail "a shaped store with no parked demand must not pace launches"
  assert_contains "$out" "so this launch is not shaped" \
    "an unarmed store must say why the launch was not paced"
  FM_TEST_HORIZON=0 admission "$home" "$store" gate calm-b >/dev/null \
    || fail "a second launch must follow immediately while shaping is unarmed"
  FM_TEST_HORIZON=0 admission "$home" "$store" gate calm-c >/dev/null \
    || fail "a third launch must follow immediately while shaping is unarmed"
  pass "shaping is armed by committed demand, not by the store being listed"
}

test_shaping_expires_a_horizon_after_demand_clears() {
  local case_dir store home out
  case_dir="$TMP_ROOT/horizon"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  FM_TEST_INTERVAL=1 FM_TEST_HORIZON=2 admission "$home" "$store" gate hz-a >/dev/null \
    || fail "the first launch onto a store with parked demand must be released"

  # The committed demand clears, but gate calls keep arriving inside the
  # horizon: the horizon must still expire from the last PARKED demand, not be
  # refreshed by the traffic it is pacing.
  rm -f "$store/projects/-fixture/parked-1.jsonl"
  sleep 1
  FM_TEST_INTERVAL=1 FM_TEST_HORIZON=2 admission "$home" "$store" gate hz-b >/dev/null \
    || fail "a launch inside the horizon must still be released on an open slot"
  sleep 1
  FM_TEST_INTERVAL=1 FM_TEST_HORIZON=2 admission "$home" "$store" gate hz-c >/dev/null \
    || fail "a launch inside the horizon must still be released on an open slot"
  sleep 2
  out=$(FM_TEST_INTERVAL=1 FM_TEST_HORIZON=2 admission "$home" "$store" gate hz-d) \
    || fail "a launch past the horizon must be released"
  assert_contains "$out" "so this launch is not shaped" \
    "shaping must disarm a horizon after the committed demand cleared, however many gates arrive inside it"
  pass "shaping disarms a horizon after parked demand clears, not after the last gate"
}

test_corrupted_queue_refuses_instead_of_admitting() {
  local case_dir store home out status dir
  case_dir="$TMP_ROOT/corruptqueue"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  FM_TEST_INTERVAL=600 admission "$home" "$store" gate cq-a >/dev/null \
    || fail "the first launch must be released"
  dir=$(store_state_dir "$home")
  printf 'not-an-epoch\t50\tcq-x\ttorn row\n' > "$dir/queue"

  sleep 2
  out=$(FM_TEST_INTERVAL=1 admission "$home" "$store" gate cq-b); status=$?
  expect_code 3 "$status" "an unreadable durable queue row must refuse rather than admit"
  assert_contains "$out" "unreadable row" "the refusal must name the queue problem"
  assert_grep "cq-b" "$dir/queue" \
    "a refusal on an unreadable queue must still preserve the request"
  pass "a corrupted durable queue row fails closed instead of releasing the herd"
}

test_unreadable_queue_refuses_everywhere() {
  local case_dir store home out status dir
  case_dir="$TMP_ROOT/unreadablequeue"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  FM_TEST_INTERVAL=600 admission "$home" "$store" gate uq-a >/dev/null \
    || fail "the first launch must be released"
  FM_TEST_INTERVAL=600 admission "$home" "$store" gate uq-head --priority 5 >/dev/null 2>&1 \
    && fail "the second launch must be withheld"

  # The durable queue is replaced by a symlink, which read_queue refuses to
  # treat as a durable record.
  dir=$(store_state_dir "$home")
  mv "$dir/queue" "$dir/queue.moved"
  ln -s "$dir/queue.moved" "$dir/queue"

  out=$(admission "$home" "$store" queue); status=$?
  expect_code 3 "$status" "an unreadable durable queue must refuse rather than report an empty queue"
  assert_contains "$out" "is a symlink" "the refusal must name the queue problem"

  out=$(FM_TEST_INTERVAL=1 admission "$home" "$store" gate uq-b); status=$?
  expect_code 3 "$status" "an unreadable durable queue must refuse on the gate path"

  out=$(admission "$home" "$store" withdraw uq-head); status=$?
  expect_code 3 "$status" "an unreadable durable queue must refuse on the withdraw path"
  assert_grep "uq-head" "$dir/queue.moved" \
    "a refusal must leave the recorded work untouched"

  # The watcher reads the poll's stdout only, so a stuck queue must arrive there
  # as a wake line rather than as silence.
  out=$(FM_TEST_INTERVAL=1 admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "the poll must preserve the refusal status"
  assert_contains "$out" "claude admission:" \
    "an unreadable queue must reach firstmate as a wake line on stdout, not silence"
  assert_contains "$out" "is a symlink" "the wake line must name the concrete problem"
  assert_no_grep "claude admission:" "$ADMISSION_STDERR" \
    "the wake line must not go to stderr, which the watcher discards"
  pass "an unreadable durable queue fails closed on every path and wakes firstmate"
}

test_poll_wakes_on_unreadable_committed_demand() {
  local case_dir store home out status dir line
  case_dir="$TMP_ROOT/pollcensus"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  FM_TEST_INTERVAL=600 admission "$home" "$store" gate pc-a >/dev/null \
    || fail "the first launch must be released"
  FM_TEST_INTERVAL=600 admission "$home" "$store" gate pc-head --priority 5 >/dev/null 2>&1 \
    && fail "the second launch must be withheld"
  dir=$(store_state_dir "$home")
  assert_grep "pc-head" "$dir/queue" "the withheld task must be waiting"

  # The queue is fine; the committed-demand evidence is not. Waiting work still
  # cannot be released, and the poll is the only surface that can say so.
  printf '{"type":"user"}\nnot json at all\n{"type":"user"}\n' \
    > "$store/projects/-fixture/torn.jsonl"
  out=$(FM_TEST_INTERVAL=1 admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "unreadable committed-demand evidence must refuse from the poll too"
  assert_no_grep "claude admission:" "$ADMISSION_STDERR" \
    "the wake line must reach stdout, not the stderr the watcher discards"
  assert_contains "$out" "unreadable record" \
    "the wake line must name the census problem, not just fail silently"
  assert_contains "$out" "until that is repaired" \
    "the wake line must say no worker is released while the evidence is broken"

  # The operator-actionable part leads the line, so fm_cap_line's cut can never
  # take it however long this home's paths are.
  line=$(printf '%s\n' "$out" | head -n 1)
  case "$line" in
    "claude admission: transcript "*) ;;
    *) fail "the wake line must lead with the concrete problem: $line" ;;
  esac

  # Repairing the evidence returns the poll to its ordinary release line.
  rm -f "$store/projects/-fixture/torn.jsonl"
  sleep 2
  out=$(FM_TEST_INTERVAL=1 admission_poll "$home" "$store" poll) \
    || fail "a repaired store must poll cleanly again"
  assert_contains "$out" "pc-head can be released now" \
    "the ordinary release wake must return once the evidence is readable"
  pass "unreadable committed demand wakes firstmate instead of stalling in silence"
}

test_a_different_store_problem_wakes_firstmate_again() {
  local case_dir store home out status dir
  case_dir="$TMP_ROOT/pollchange"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  FM_TEST_INTERVAL=600 admission "$home" "$store" gate pc2-a >/dev/null \
    || fail "the first launch must be released"
  FM_TEST_INTERVAL=600 admission "$home" "$store" gate pc2-head --priority 5 >/dev/null 2>&1 \
    && fail "the second launch must be withheld"
  dir=$(store_state_dir "$home")

  # First fault: the committed-demand evidence.
  printf '{"type":"user"}\nnot json at all\n{"type":"user"}\n' \
    > "$store/projects/-fixture/torn.jsonl"
  out=$(FM_TEST_INTERVAL=600 admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "the census fault must refuse"
  assert_contains "$out" "unreadable record" "the first fault must be named"
  out=$(FM_TEST_INTERVAL=600 admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "the repeated census fault must still refuse"
  [ -z "$out" ] || fail "the same fault must wake firstmate once: $out"

  # A DIFFERENT fault must not inherit the first one's silence.
  mv "$dir/queue" "$dir/queue.moved"
  ln -s "$dir/queue.moved" "$dir/queue"
  out=$(FM_TEST_INTERVAL=600 admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "a second, different fault must refuse"
  assert_contains "$out" "is a symlink" \
    "a different store fault must wake firstmate again, not inherit the first one's stamp"

  # Both repaired, but the release slot is still closed: the poll withholds
  # silently and must retire the refusal stamp anyway.
  rm -f "$dir/queue"
  mv "$dir/queue.moved" "$dir/queue"
  rm -f "$store/projects/-fixture/torn.jsonl"
  out=$(FM_TEST_INTERVAL=600 admission_poll "$home" "$store" poll) \
    || fail "a repaired store with a closed slot must poll cleanly"
  [ -z "$out" ] || fail "a withheld poll must stay silent: $out"
  assert_grep "pc2-head" "$dir/queue" "the waiting work must still be queued"

  # The fault that returns is the SAME one that was last reported, so the only
  # thing that can produce a second wake is that clean poll having retired the
  # stamp.
  mv "$dir/queue" "$dir/queue.moved"
  ln -s "$dir/queue.moved" "$dir/queue"
  out=$(FM_TEST_INTERVAL=600 admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "the recurring fault must refuse again"
  assert_contains "$out" "is a symlink" \
    "a fault that cleared and recurred must wake firstmate again, even though it is the one last reported"
  pass "each distinct store fault wakes firstmate once, and a cleared one wakes again if it returns"
}

test_poll_wakes_on_a_malformed_shaped_store_list() {
  local case_dir store home out status
  case_dir="$TMP_ROOT/pollconfig"
  store=$(make_store "$case_dir/store")
  home=$(make_home "$case_dir/home" "$store")

  printf 'relative/path\n' > "$home/config/claude-shaped-store"
  out=$(admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "a malformed shaped-store list must refuse from the poll"
  assert_contains "$out" "not an absolute path" \
    "the wake line must name the configuration problem"
  assert_no_grep "claude admission:" "$ADMISSION_STDERR" \
    "the wake line must reach stdout, not the stderr the watcher discards"
  [ -z "$(store_state_dir "$home")" ] \
    || fail "a poll that cannot tell whether a store is shaped must give no store any state"

  # The same misconfiguration must not re-wake firstmate on every cycle.
  out=$(admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "a repeated refusal must still refuse"
  [ -z "$out" ] || fail "a persistent misconfiguration must wake firstmate once, not every poll: $out"
  pass "a malformed shaped-store list wakes firstmate once and gives no store state"
}

test_poll_wakes_before_a_store_can_even_be_named() {
  local case_dir store home out status unshaped nosha

  # An unconfigured home shapes nothing, so a broken environment is not its
  # problem and must never wake firstmate.
  case_dir="$TMP_ROOT/prestore"
  store=$(make_store "$case_dir/store")
  home=$(make_home "$case_dir/quiet-home")
  out=$(admission_poll "$home" "relative/path" poll); status=$?
  expect_code 0 "$status" "an unconfigured home must not refuse on a broken environment"
  [ -z "$out" ] || fail "an unconfigured home must stay silent: $out"

  # A home that does shape a store cannot tell whether this launch would land on
  # it, so it says so where firstmate can see it.
  home=$(make_home "$case_dir/shaping-home" "$store")
  out=$(admission_poll "$home" "relative/path" poll); status=$?
  expect_code 3 "$status" "a shaping home must refuse when no store can be named"
  assert_contains "$out" "not an absolute path" \
    "the wake line must name why no credential store could be identified"
  assert_no_grep "claude admission:" "$ADMISSION_STDERR" \
    "the wake line must reach stdout, not the stderr the watcher discards"
  [ -z "$(store_state_dir "$home")" ] \
    || fail "a poll that cannot name a store must give no store any state"

  out=$(admission_poll "$home" "relative/path" poll); status=$?
  expect_code 3 "$status" "a repeated pre-store refusal must still refuse"
  [ -z "$out" ] || fail "a pre-store refusal must wake firstmate once, not every poll: $out"

  # The condition clears - the environment is repointed at a real store this
  # home does not shape - and then recurs. Quiet while unchanged must not mean
  # blind forever.
  unshaped=$(make_store "$case_dir/unshaped")
  out=$(admission_poll "$home" "$unshaped" poll); status=$?
  expect_code 0 "$status" "a store this home does not shape must not refuse"
  [ -z "$out" ] || fail "an unshaped store must stay silent: $out"
  out=$(admission_poll "$home" "relative/path" poll); status=$?
  expect_code 3 "$status" "the recurring misconfiguration must refuse again"
  assert_contains "$out" "not an absolute path" \
    "a refusal that cleared and recurred must wake firstmate again"

  # The last pre-store refusal - no sha256 tool to name the store's records by -
  # dedupes on the same marker, so it too must wake once and then stay quiet.
  nosha="$case_dir/nosha"
  mkdir -p "$nosha"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$nosha/shasum"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$nosha/sha256sum"
  chmod +x "$nosha/shasum" "$nosha/sha256sum"
  out=$(PATH="$nosha:$PATH" admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "a store whose records cannot be named must refuse"
  assert_contains "$out" "sha256" "the wake line must name the missing tool"
  out=$(PATH="$nosha:$PATH" admission_poll "$home" "$store" poll); status=$?
  expect_code 3 "$status" "the repeated tool refusal must still refuse"
  [ -z "$out" ] || fail "a store-slug refusal must wake firstmate once, not every poll: $out"
  out=$(PATH="$nosha:$PATH" admission_poll "$home" "$store" poll)
  [ -z "$out" ] || fail "a store-slug refusal must stay quiet while unchanged: $out"
  pass "every pre-store refusal wakes firstmate once per occurrence, and an unconfigured home stays silent"
}

test_queue_removal_matches_the_task_id_literally() {
  local case_dir store home out
  case_dir="$TMP_ROOT/literalid"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  FM_TEST_INTERVAL=600 admission "$home" "$store" gate lit-a >/dev/null \
    || fail "the first launch must be released"
  # Two ids that differ only by a regex metacharacter.
  FM_TEST_INTERVAL=600 admission "$home" "$store" gate a.c --priority 10 >/dev/null 2>&1 \
    && fail "the second launch must be withheld"
  FM_TEST_INTERVAL=600 admission "$home" "$store" gate abc --priority 20 >/dev/null 2>&1 \
    && fail "the third launch must be withheld"

  admission "$home" "$store" withdraw a.c >/dev/null \
    || fail "withdrawing a queued task must succeed"
  out=$(admission "$home" "$store" queue)
  assert_contains "$out" "abc" \
    "withdrawing 'a.c' must never drop the unrelated 'abc' request"
  assert_not_contains "$out" ",a.c," "the withdrawn task must be gone"
  pass "queue removal matches the task id literally, never as a pattern"
}

test_malformed_evidence_refuses_without_losing_work() {
  local case_dir store home out status dir
  case_dir="$TMP_ROOT/malformed"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  printf '{"type":"user"}\nnot json at all\n{"type":"user"}\n' \
    > "$store/projects/-fixture/torn.jsonl"
  out=$(admission "$home" "$store" gate bad-a --priority 15); status=$?
  expect_code 3 "$status" "an unreadable transcript must refuse rather than guess"
  assert_contains "$out" "unreadable record" "the refusal must name the evidence problem"
  dir=$(store_state_dir "$home")
  assert_grep "bad-a" "$dir/queue" \
    "a refusal on unreadable evidence must still preserve the request"

  # A torn FINAL line is a concurrent write, not malformed evidence.
  printf '{"type":"user"}\n{"type":"user"' > "$store/projects/-fixture/torn.jsonl"
  admission "$home" "$store" demand >/dev/null \
    || fail "a torn final line must be tolerated as a concurrent write"

  printf 'relative/path\n' > "$home/config/claude-shaped-store"
  out=$(admission "$home" "$store" gate bad-b); status=$?
  expect_code 3 "$status" "a config line that is not an absolute path must refuse"
  assert_contains "$out" "not an absolute path" "the refusal must name the bad config line"

  printf '%s\n' "$store" > "$home/config/claude-shaped-store"
  printf 'not-a-timestamp\n' > "$dir/last-release"
  out=$(admission "$home" "$store" gate bad-c); status=$?
  expect_code 3 "$status" "an unreadable durable record must refuse"
  assert_contains "$out" "does not hold a readable timestamp" \
    "the refusal must name the unreadable record"
  pass "malformed or unreadable evidence refuses safely and preserves the request"
}

test_withdraw_clears_a_head_block() {
  local case_dir store home out status
  case_dir="$TMP_ROOT/withdraw"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  FM_TEST_INTERVAL=600 admission "$home" "$store" gate w-a --priority 50 >/dev/null \
    || fail "the first launch must be released"
  FM_TEST_INTERVAL=600 admission "$home" "$store" gate w-head --priority 5 >/dev/null 2>&1 \
    && fail "the second launch must be withheld"
  sleep 2
  out=$(FM_TEST_INTERVAL=1 admission "$home" "$store" gate w-b --priority 90); status=$?
  expect_code 1 "$status" "lower-priority work must wait behind the head"

  admission "$home" "$store" withdraw w-head >/dev/null \
    || fail "withdrawing a queued task must succeed"
  out=$(FM_TEST_INTERVAL=1 admission "$home" "$store" gate w-b --priority 90) \
    || fail "withdrawing the head must let the next task take the slot"
  assert_contains "$out" "admitted: w-b" "the remaining task must be released"
  pass "an explicitly withdrawn head stops blocking the queue"
}

test_head_block_is_bounded() {
  local case_dir store home out
  case_dir="$TMP_ROOT/headbound"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  FM_TEST_INTERVAL=600 admission "$home" "$store" gate h-a --priority 50 >/dev/null \
    || fail "the first launch must be released"
  FM_TEST_INTERVAL=600 admission "$home" "$store" gate h-head --priority 5 >/dev/null 2>&1 \
    && fail "the second launch must be withheld"
  sleep 2
  out=$(FM_TEST_INTERVAL=1 FM_TEST_HEAD_WAIT=1 admission "$home" "$store" gate h-b --priority 90) \
    || fail "an abandoned head must not stall the queue past its bound"
  assert_contains "$out" "admitted: h-b" "the bounded valve must release the offered task"
  out=$(admission "$home" "$store" queue)
  assert_contains "$out" "h-head" "the bypassed head must stay queued, never dropped"
  pass "the head-of-queue block is bounded and never discards the head"
}

test_poll_reports_one_slot_once() {
  local case_dir store home out
  case_dir="$TMP_ROOT/poll"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  out=$(admission_poll "$home" "$store" poll)
  [ -z "$out" ] || fail "poll must be silent when nothing is waiting: $out"

  FM_TEST_INTERVAL=600 admission "$home" "$store" gate p-a >/dev/null \
    || fail "the first launch must be released"
  FM_TEST_INTERVAL=600 admission "$home" "$store" gate p-b --priority 20 >/dev/null 2>&1 \
    && fail "the second launch must be withheld"
  out=$(FM_TEST_INTERVAL=600 admission_poll "$home" "$store" poll)
  [ -z "$out" ] || fail "poll must stay silent while the slot is still closed: $out"

  sleep 2
  out=$(FM_TEST_INTERVAL=1 admission_poll "$home" "$store" poll)
  assert_contains "$out" "p-b can be released now" "poll must name the task to release"
  assert_contains "$out" "1 task(s) waiting" "poll must say how much is waiting"
  out=$(FM_TEST_INTERVAL=1 admission_poll "$home" "$store" poll)
  [ -z "$out" ] || fail "poll must report one release slot once, not every cycle: $out"
  pass "the watcher poll reports an open release slot exactly once"
}

test_arm_binds_the_check_shim() {
  local case_dir store home out
  case_dir="$TMP_ROOT/arm"
  store=$(make_store "$case_dir/store")
  home=$(make_home "$case_dir/home" "$store")

  out=$(admission "$home" "$store" arm) || fail "arming the poll shim must succeed: $out"
  assert_present "$home/state/claude-admission.check.sh" "arm must write the poll shim"
  assert_present "$home/state/claude-admission.check-trust" "arm must bind the shim's bytes"
  [ "$(stat -c %a "$home/state/claude-admission.check.sh" 2>/dev/null \
    || stat -f %Lp "$home/state/claude-admission.check.sh")" = 700 ] \
    || fail "the poll shim must be a private single-owner executable"

  out=$(admission "$home" "$store" disarm) || fail "disarming must succeed: $out"
  assert_absent "$home/state/claude-admission.check.sh" "disarm must remove the shim"
  assert_absent "$home/state/claude-admission.check-trust" "disarm must remove the binding"

  rm -f "$home/config/claude-shaped-store"
  admission "$home" "$store" arm >/dev/null 2>&1 \
    && fail "arming a home with no shaped-store list must refuse"
  pass "the poll shim is armed and disarmed with its trust binding"
}

test_check_is_non_consuming() {
  local case_dir store home out
  case_dir="$TMP_ROOT/check"
  store=$(make_store "$case_dir/store")
  add_turn_then_park "$store" parked-1 60 100000
  home=$(make_home "$case_dir/home" "$store")

  out=$(admission "$home" "$store" check c-a) \
    || fail "check must report the first launch as releasable"
  assert_contains "$out" "admitted: c-a" "check must report the verdict"
  assert_absent "$home/state/claude-admission" \
    "check must not create durable state or take a release slot"
  out=$(admission "$home" "$store" gate c-a) \
    || fail "a preview must not consume the slot it previewed"
  assert_contains "$out" "admitted: c-a" "the gate must still admit after a check"
  pass "check previews the decision without consuming a release slot"
}

# --- real fm-spawn integration ----------------------------------------------

# A fake tmux that records the literal launch command, so a spawn assertion pins
# what firstmate would actually run instead of reading source text.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" != "-l" ] || printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

# spawn_case <name> -> "<home>|<wt>|<fakebin>|<launchlog>|<project>", with a
# claude crew harness and one brief per task id.
spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'Delivery contract: mode=no-mistakes\nbrief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s|%s|%s|%s|%s\n' "$home" "$wt" "$fakebin" "$launchlog" "$proj"
}

run_claude_spawn() {  # <home> <wt> <fakebin> <launchlog> <store> <spawn args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 store=$5
  shift 5
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="$store" HERDR_SESSION=fm-test FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_CLAUDE_RELEASE_INTERVAL="${FM_TEST_INTERVAL:-600}" \
    FM_CLAUDE_HEAD_MAX_WAIT="${FM_TEST_HEAD_WAIT:-3600}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

test_spawn_withholds_before_creating_anything() {
  local home wt fakebin launchlog proj store out status
  IFS='|' read -r home wt fakebin launchlog proj <<< "$(spawn_case spawn-withhold ship-one ship-two)"
  store=$(make_store "$TMP_ROOT/spawn-withhold/store")
  add_turn_then_park "$store" parked-1 60 100000
  printf '%s\n' "$store" > "$home/config/claude-shaped-store"

  out=$(run_claude_spawn "$home" "$wt" "$fakebin" "$launchlog" "$store" ship-one "$proj" --priority 20) \
    || fail "the first Claude spawn onto a shaped store must be released: $out"
  assert_present "$home/state/ship-one.meta" "the released spawn must publish its task record"

  out=$(run_claude_spawn "$home" "$wt" "$fakebin" "$launchlog" "$store" ship-two "$proj" --priority 30); status=$?
  [ "$status" -ne 0 ] || fail "a second Claude spawn inside one release slot must be refused"
  assert_contains "$out" "withheld: ship-two" "the refusal must name the withheld task"
  assert_absent "$home/state/ship-two.meta"     "a withheld spawn must publish no task record"
  [ ! -s "$launchlog" ] || fail "a withheld spawn must send no launch command"
  assert_grep "ship-two" "$(store_state_dir "$home")/queue"     "a withheld spawn must be preserved in the durable queue"
  pass "a withheld Claude spawn creates nothing and keeps the request durable"
}

test_withheld_secondmate_spawn_leaves_the_child_home_untouched() {
  local home wt fakebin launchlog proj store child out status before after
  IFS='|' read -r home wt fakebin launchlog proj <<< "$(spawn_case spawn-sm-withhold ship-one sm-b)"
  store=$(make_store "$TMP_ROOT/spawn-sm-withhold/store")
  add_turn_then_park "$store" parked-1 60 100000
  printf '%s\n' "$store" > "$home/config/claude-shaped-store"

  # A second-mate home of its own. The secondmate spawn path fast-forwards this
  # checkout, creates its state directory, and copies the parent's local config
  # into it, so a withheld launch that claims "nothing was created" must not
  # have reached any of that.
  child="$TMP_ROOT/spawn-sm-withhold/child"
  fm_git_worktree "$TMP_ROOT/spawn-sm-withhold/child-origin" "$child" sm-child
  mkdir -p "$child/bin" "$child/data" "$child/config" "$child/projects"
  printf 'sm-b\n' > "$child/.fm-secondmate-home"
  printf '# child home\n' > "$child/AGENTS.md"
  printf 'claude\n' > "$home/config/crew-harness"

  run_claude_spawn "$home" "$wt" "$fakebin" "$launchlog" "$store" ship-one "$proj" >/dev/null \
    || fail "the first Claude spawn onto a shaped store must be released"

  before=$(cd "$child" && { git rev-parse HEAD; find . -path ./.git -prune -o -print | sort; })
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="$store" HERDR_SESSION=fm-test FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_CLAUDE_RELEASE_INTERVAL=600 PATH="$fakebin:$PATH" \
    "$SPAWN" sm-b "$child" --secondmate --harness claude 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a second Claude spawn inside one release slot must be withheld"
  assert_contains "$out" "nothing was created" \
    "the withheld secondmate spawn must claim it created nothing"
  after=$(cd "$child" && { git rev-parse HEAD; find . -path ./.git -prune -o -print | sort; })
  [ "$before" = "$after" ] \
    || fail "a withheld secondmate spawn changed the child home:"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
  assert_absent "$child/state" "a withheld secondmate spawn must create no child state directory"
  assert_absent "$child/config/claude-shaped-store" \
    "a withheld secondmate spawn must copy no parent config into the child home"
  assert_absent "$child/data/home-identity" \
    "a withheld secondmate spawn must not pin the child home"
  assert_grep "sm-b" "$(store_state_dir "$home")/queue" \
    "a withheld secondmate spawn must be preserved in the durable queue"
  pass "a withheld secondmate spawn leaves the child home byte-for-byte untouched"
}

test_a_refusal_after_the_gate_never_spends_the_slot() {
  local home wt fakebin launchlog proj store out status
  IFS='|' read -r home wt fakebin launchlog proj <<< "$(spawn_case spawn-slot ship-one ship-two)"
  store=$(make_store "$TMP_ROOT/spawn-slot/store")
  add_turn_then_park "$store" parked-1 60 100000
  printf '%s\n' "$store" > "$home/config/claude-shaped-store"

  # The brief records mode=no-mistakes; this spawn passes a different one, which
  # is a refusal that lives below the release gate's own position in the file.
  : > "$launchlog"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="$store" HERDR_SESSION=fm-test FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_CLAUDE_RELEASE_INTERVAL=600 PATH="$fakebin:$PATH" \
    "$SPAWN" ship-one "$proj" --mode direct-PR --yolo off 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose brief disagrees with --mode must refuse"
  assert_contains "$out" "delivery mismatch" "the refusal must be the delivery mismatch"
  assert_absent "$home/state/ship-one.meta" "a refused spawn must publish no task record"

  # The store's one release per interval must still be there for real work.
  out=$(FM_TEST_INTERVAL=600 run_claude_spawn "$home" "$wt" "$fakebin" "$launchlog" \
    "$store" ship-two "$proj") \
    || fail "a refused spawn must not have spent the release slot: $out"
  assert_present "$home/state/ship-two.meta" "the next eligible spawn must be released"
  pass "a spawn refused before it launches never spends a release slot"
}

test_spawn_on_unshaped_store_is_unchanged() {
  local home wt fakebin launchlog proj store baseline shaped_elsewhere with_config
  IFS='|' read -r home wt fakebin launchlog proj <<< "$(spawn_case spawn-unshaped ship-one)"
  store=$(make_store "$TMP_ROOT/spawn-unshaped/store")
  add_turn_then_park "$store" parked-1 60 100000

  # No shaped-store list at all: the pre-change behavior.
  run_claude_spawn "$home" "$wt" "$fakebin" "$launchlog" "$store" ship-one "$proj" >/dev/null \
    || fail "a spawn with no shaped-store list must succeed"
  baseline=$(cat "$launchlog")
  [ -n "$baseline" ] || fail "the baseline spawn must record a launch command"
  rm -f "$home/state/ship-one.meta"

  # A list that names a DIFFERENT store, with parked demand present on the store
  # this spawn actually uses. Nothing about the launch may change.
  shaped_elsewhere=$(make_store "$TMP_ROOT/spawn-unshaped/other")
  printf '%s\n' "$shaped_elsewhere" > "$home/config/claude-shaped-store"
  run_claude_spawn "$home" "$wt" "$fakebin" "$launchlog" "$store" ship-one "$proj" >/dev/null \
    || fail "a spawn onto an unlisted store must succeed unchanged"
  with_config=$(cat "$launchlog")
  [ "$with_config" = "$baseline" ] \
    || fail "an unshaped store's launch command changed:"$'\n'"--- baseline ---"$'\n'"$baseline"$'\n'"--- with config ---"$'\n'"$with_config"
  assert_absent "$home/state/claude-admission" \
    "an unshaped store must leave no release-shaping state behind"
  pass "a Claude spawn onto an unshaped store is byte-for-byte unchanged"
}

test_unshaped_store_takes_no_state
test_reset_herd_is_staggered_and_ordered
test_withheld_work_is_durable_across_processes
test_parked_demand_is_scoped_to_the_shaped_store
test_demand_ignores_resumed_and_stale_sessions
test_shaping_disarms_when_no_demand_remains
test_shaping_expires_a_horizon_after_demand_clears
test_corrupted_queue_refuses_instead_of_admitting
test_queue_removal_matches_the_task_id_literally
test_unreadable_queue_refuses_everywhere
test_poll_wakes_on_unreadable_committed_demand
test_poll_wakes_on_a_malformed_shaped_store_list
test_a_different_store_problem_wakes_firstmate_again
test_poll_wakes_before_a_store_can_even_be_named
test_malformed_evidence_refuses_without_losing_work
test_withdraw_clears_a_head_block
test_head_block_is_bounded
test_poll_reports_one_slot_once
test_arm_binds_the_check_shim
test_check_is_non_consuming
test_spawn_withholds_before_creating_anything
test_withheld_secondmate_spawn_leaves_the_child_home_untouched
test_a_refusal_after_the_gate_never_spends_the_slot
test_spawn_on_unshaped_store_is_unchanged
