#!/usr/bin/env bash
# tests/fm-remote-secondmate-identity.test.sh - a remote second mate stays
# steerable under the identity its home was pinned to, and refuses under any
# other one.
#
# A remote second mate is launched with HERDR_SESSION=fm-remote
# (bin/fm-remote-secondmate-control.sh cmd_launch), so its home is durably
# pinned to that session and to the Claude account that launch billed
# (bin/fm-home-identity.sh). The steering legs run from a job worker or SSH
# entrypoint whose own environment names no session at all, so they must carry
# the RECORDED identity rather than the caller's - otherwise the pin check in
# bin/fm-send.sh resolves "default" and refuses every steer.
#
# Both cases drive the real control script and the real bin/fm-send.sh against
# the repo's stateful herdr CLI fixture, so "the steer landed" is asserted from
# the pane the fake host actually received, never from source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CONTROL="$ROOT/bin/fm-remote-secondmate-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-identity)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

FAKE_ROOT="$TMP_ROOT/fake-host"
HERDR_STATE="$TMP_ROOT/herdr.state"
HERDR_LOG="$TMP_ROOT/herdr.log"
mkdir -p "$FAKE_ROOT/bin"
install_remote_herdr_fixture "$FAKE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/send-fail" "$TMP_ROOT/herdr.sock"
PATH="$FAKE_ROOT/bin:$PATH"
export PATH

ID=sm1
SESSION=fm-remote
PANE=w1:p2
TARGET_HOME="$TMP_ROOT/remote-home"

# One live pane on the fake host, with no typed or in-flight turn on it, which
# is the state a steer is delivered into.
seed_host() {
  printf '{"next":3,"workspaces":[{"workspace_id":"w1","label":"fm-%s","cwd":"%s"}],"tabs":[{"tab_id":"w1:t2","label":"1","workspace_id":"w1","pane_id":"%s"}],"typed":{},"working":{}}\n' \
    "$ID" "$TARGET_HOME" "$PANE" > "$HERDR_STATE"
  : > "$HERDR_LOG"
}

mkdir -p "$TARGET_HOME/state/parent-route" "$TARGET_HOME/data" "$TARGET_HOME/config" "$TARGET_HOME/bin"
printf '%s\n' "$ID" > "$TARGET_HOME/.fm-secondmate-home"
printf '# remote second mate fixture\n' > "$TARGET_HOME/AGENTS.md"
META="$TARGET_HOME/state/parent-route/$ID.meta"
printf 'window=%s:%s\nworktree=%s\nproject=%s\nbackend=herdr\nendpoint_task_id=%s\nherdr_session=%s\nherdr_workspace_id=w1\nherdr_tab_id=w1:t2\nherdr_pane_id=%s\nharness=codex\n' \
  "$SESSION" "$PANE" "$TARGET_HOME" "$TARGET_HOME" "$ID" "$SESSION" "$PANE" > "$META"

# A throwaway store standing in for the Claude account a work-session launch
# billed, and a second one standing in for the foreign account a host's own
# login shell might export.
WORK_STORE="$TMP_ROOT/store-work"
FOREIGN_STORE="$TMP_ROOT/store-foreign"
mkdir -p "$WORK_STORE/projects" "$FOREIGN_STORE/projects"

# write_pin <herdr-session> [claude-store]: the durable home identity a launch
# seeds. The store defaults to the personal "default" binding.
write_pin() {
  printf 'fm-home-identity-v1\nherdr_session=%s\nclaude_config_dir=%s\n' "$1" "${2:-default}" \
    > "$TARGET_HOME/data/home-identity"
}

# control <args...>: the steering leg's own environment names no Herdr session
# and no Claude account, exactly as a job worker's does.
control() {
  env -u HERDR_SESSION -u CLAUDE_CONFIG_DIR \
    FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$CONTROL" "$@" 2>&1
}

# control_with_foreign_env <args...>: the leg runs on a host whose login shell
# exports another session and another Claude account, which is exactly the
# ambient identity the recorded pin must beat.
control_with_foreign_env() {
  env HERDR_SESSION=personal CLAUDE_CONFIG_DIR="$FOREIGN_STORE" \
    FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$CONTROL" "$@" 2>&1
}

test_recorded_identity_is_propagated() {
  local out status

  write_pin "$SESSION"
  seed_host
  out=$(control key "$ID" Enter); status=$?
  assert_not_contains "$out" "fm-home-identity" \
    "a steer under the home's own recorded identity must not be refused by the pin check"
  expect_code 0 "$status" "the key steer must reach the recorded remote pane"
  assert_grep "pane send-keys $PANE" "$HERDR_LOG" \
    "the key steer must land on the recorded pane"

  seed_host
  out=$(control send "$ID" 'report the build result'); status=$?
  assert_not_contains "$out" "fm-home-identity" \
    "a send under the home's own recorded identity must not be refused by the pin check"
  expect_code 0 "$status" "the send must be confirmed against the recorded remote pane"
  assert_grep "report the build result" "$HERDR_LOG" \
    "the message must reach the recorded pane"
  pass "remote send and key carry the home's recorded session and account"
}

test_a_recorded_store_beats_the_caller_environment() {
  local out status

  # A store-bound second mate keeps its own store even though the caller's
  # environment names a different session and a different account.
  write_pin "$SESSION" "$WORK_STORE"
  seed_host
  out=$(control_with_foreign_env send "$ID" 'keep the recorded account'); status=$?
  assert_not_contains "$out" "fm-home-identity" \
    "the recorded store must satisfy the pin check, not the caller's"
  expect_code 0 "$status" "a store-bound remote second mate must still be steerable"
  assert_grep "keep the recorded account" "$HERDR_LOG" \
    "the steer must land on the recorded pane"
  assert_grep "claude_config_dir=$WORK_STORE" "$TARGET_HOME/data/home-identity" \
    "the pin must never be rewritten to the caller's account"

  # A default-bound second mate must have the foreign account actively removed
  # rather than inherited.
  write_pin "$SESSION"
  seed_host
  out=$(control_with_foreign_env send "$ID" 'do not inherit the foreign account'); status=$?
  assert_not_contains "$out" "fm-home-identity" \
    "a default-bound home must not inherit the caller's account"
  expect_code 0 "$status" "a default-bound remote second mate must still be steerable"
  assert_grep "do not inherit the foreign account" "$HERDR_LOG" \
    "the steer must land on the recorded pane"
  assert_grep "claude_config_dir=default" "$TARGET_HOME/data/home-identity" \
    "the default binding must survive a caller that exports another account"
  pass "the recorded account wins over the caller's, in both the store-bound and default cases"
}

test_conflicting_identity_still_refuses() {
  local out status

  write_pin personal
  seed_host
  out=$(control send "$ID" 'steer from the wrong account'); status=$?
  [ "$status" -ne 0 ] || fail "a home pinned to another session must not be steered"
  assert_contains "$out" "pinned to Herdr session 'personal'" \
    "the refusal must name the recorded session it will not migrate"
  assert_no_grep "steer from the wrong account" "$HERDR_LOG" \
    "a refused steer must never reach the pane"

  out=$(control key "$ID" Enter); status=$?
  [ "$status" -ne 0 ] || fail "a key steer into a foreign-pinned home must be refused"
  assert_contains "$out" "pinned to Herdr session 'personal'" \
    "the key refusal must name the recorded session"

  rm -f "$TARGET_HOME/data/home-identity"
  out=$(control send "$ID" 'steer with no identity at all'); status=$?
  [ "$status" -ne 0 ] || fail "a home with no recorded identity must not be steered"
  assert_contains "$out" "no recorded session and account" \
    "an absent pin must refuse rather than adopt the caller's environment"
  assert_no_grep "steer with no identity at all" "$HERDR_LOG" \
    "a steer with no recorded identity must never reach the pane"
  pass "a conflicting or missing recorded identity refuses instead of falling back"
}

test_recorded_identity_is_propagated
test_a_recorded_store_beats_the_caller_environment
test_conflicting_identity_still_refuses
