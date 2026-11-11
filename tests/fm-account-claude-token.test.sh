#!/usr/bin/env bash
# Long-lived Claude token seats (config/accounts.json claudeTokenEnv): a seat
# that names a .env.op reference file runs its Claude task workers under
# `opr -f <file> --` with the terminal bridge inside, sheds ambient credentials
# ahead of opr, and keeps Herdr's agent record through firstmate:claude reports;
# every other seat launches exactly as before, and an unusable setup refuses
# before anything is published. Hermetic: opr and script are fakes, and the
# reference file holds a marker that must never reach launch text or state.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-account-lib.sh
. "$ROOT/bin/fm-account-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-claude-token)
unset PI_CODING_AGENT_DIR LAVISH_AXI_HOST CLAUDE_CODE_OAUTH_TOKEN

REFMARK=fm-test-reference-DO-NOT-COPY
BRIDGE="$ROOT/bin/fm-pi-tty-bridge.sh"

# ---- registry: the field is optional, path-shaped, and Claude-only -------------
test_registry_field() {
  local f="$TMP_ROOT/registry.json" out
  valid() { printf '%s\n' "$1" > "$f"; fm_account_registry_valid "$f"; }
  valid '{"accounts":{"c1":{"claude":"~/.claude","claudeTokenEnv":"~/tok/c1.env.op"}}}' \
    || fail 'a ~/ claudeTokenEnv must register'
  valid '{"accounts":{"c1":{"claude":"/h/.claude","claudeTokenEnv":"/h/tok/c1.env.op"}}}' \
    || fail 'an absolute claudeTokenEnv must register'
  ! valid '{"accounts":{"c1":{"claude":"~/.claude","claudeTokenEnv":"tok/c1.env.op"}}}' \
    || fail 'a relative claudeTokenEnv must refuse the registry like a malformed store'
  ! valid '{"accounts":{"c1":{"claude":"~/.claude","claudeTokenEnv":7}}}' \
    || fail 'a non-string claudeTokenEnv must refuse the registry'
  printf '%s\n' '{"accounts":{"glm":{"pi":"~/.pi/agent","claudeTokenEnv":"~/tok/glm.env.op"},"c1":{"claude":"~/.claude","claudeTokenEnv":"~/tok/c1.env.op"}}}' > "$f"
  out=$(fm_account_registry_problems "$f")
  assert_contains "$out" 'account glm sets claudeTokenEnv but owns no claude store' \
    'bootstrap must name a token on a seat with no Claude store'
  assert_not_contains "$out" 'account c1' 'a Claude seat with a token is not a problem'
  pass 'claudeTokenEnv is optional, must be a path, and belongs on a Claude seat'
}

test_token_env_lookup() {
  local f="$TMP_ROOT/lookup.json" HOME="$TMP_ROOT/lookup-home"
  printf '%s\n' '{"accounts":{"c1":{"claude":"~/.claude","claudeTokenEnv":"~/tok/c1.env.op"},"c2":{"claude":"~/.claude-2"}}}' > "$f"
  [ "$(fm_account_claude_token_env "$f" c1)" = "$HOME/tok/c1.env.op" ] || fail 'the token file path must expand ~/'
  [ -z "$(fm_account_claude_token_env "$f" c2)" ] || fail 'a seat without the field names no token file'
  [ -z "$(fm_account_claude_token_env "$f" nope)" ] || fail 'an unknown seat names no token file'
  [ -z "$(fm_account_claude_token_env "$f" '')" ] || fail 'no seat names no token file'
  printf '%s\n' '{"accounts":{"c1":{"claude":"relative","claudeTokenEnv":"~/tok/c1.env.op"}}}' > "$f"
  [ -z "$(fm_account_claude_token_env "$f" c1)" ] || fail 'a malformed registry names no token file'
  pass 'only a seat that declares claudeTokenEnv in a valid registry resolves a token file'
}

test_token_check() {
  local dir="$TMP_ROOT/check" fakebin noopr err
  fakebin=$(fm_fakebin "$dir/fake")
  fm_fake_exit0 "$fakebin" opr script
  noopr="$dir/noopr"
  mkdir -p "$noopr"
  fm_fake_exit0 "$noopr" script
  printf 'CLAUDE_CODE_OAUTH_TOKEN="op://vault/item/%s"\n' "$REFMARK" > "$dir/good.env.op"
  printf 'OTHER_TOKEN="op://vault/item/%s"\n' "$REFMARK" > "$dir/other.env.op"
  PATH="$fakebin:$PATH" fm_account_claude_token_check c1 "$dir/good.env.op" \
    || fail 'a readable file with a CLAUDE_CODE_OAUTH_TOKEN reference must pass'
  err=$(PATH="$fakebin:$PATH" fm_account_claude_token_check c1 "$dir/missing.env.op" 2>&1) \
    && fail 'a missing token file must refuse'
  assert_contains "$err" "account 'c1' runs Claude on its claudeTokenEnv token" 'the refusal names the seat'
  assert_contains "$err" "$dir/missing.env.op is not a readable file" 'the refusal names the file'
  err=$(PATH="$fakebin:$PATH" fm_account_claude_token_check c1 "$dir/other.env.op" 2>&1) \
    && fail 'a file without CLAUDE_CODE_OAUTH_TOKEN must refuse'
  assert_contains "$err" 'declares no CLAUDE_CODE_OAUTH_TOKEN' 'the refusal names the missing variable'
  assert_not_contains "$err" "$REFMARK" 'a refusal never prints a reference'
  err=$(PATH="$noopr" fm_account_claude_token_check c1 "$dir/good.env.op" 2>&1) \
    && fail 'a launch without opr must refuse'
  assert_contains "$err" 'opr is not on PATH' 'the refusal names opr'
  pass 'an unusable token setup refuses by name without printing a reference'
}

# ---- spawn ---------------------------------------------------------------------
new_case() {
  CASE="$TMP_ROOT/$1"; HOME_DIR="$CASE/home"; PROJ="$CASE/project"; WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake" opr script)
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  CASE=$(cd -P "$CASE" && pwd -P)
  HOME_DIR="$CASE/home"
  UH="$HOME_DIR/user-home"
  ENVOP="$CASE/tok/c1.env.op"
  mkdir -p "$UH/.claude" "$UH/.claude-2" "$CASE/tok"
  printf 'CLAUDE_CODE_OAUTH_TOKEN="op://vault/item/%s"\n' "$REFMARK" > "$ENVOP"
  jq -n --arg tok "$ENVOP" '{crossAccount:{enabled:true}, accounts:{
    c1:{provider:"claude", claude:"~/.claude", claudeTokenEnv:$tok, plans:{claude:"Max 20x"}},
    c2:{provider:"claude", claude:"~/.claude-2", plans:{claude:"Ultra"}}}}' \
    > "$HOME_DIR/config/accounts.json"
}

spawn_case() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

assert_token_launch() {  # <launch-text> <what>
  local launch=$1 what=$2 shed_at opr_at
  assert_contains "$launch" "CLAUDE_CODE_SEND_FEEDBACK=0 opr -f '$ENVOP' -- '$BRIDGE' claude " \
    "$what: claude must run under opr with the terminal bridge inside it"
  shed_at=${launch%%-u CLAUDE_CODE_OAUTH_TOKEN*}
  opr_at=${launch%%opr -f*}
  [ "$shed_at" != "$launch" ] || fail "$what: an inherited CLAUDE_CODE_OAUTH_TOKEN must be shed"
  [ "${#shed_at}" -lt "${#opr_at}" ] || fail "$what: the shed must precede opr, which injects the seat's own token"
  assert_contains "$launch" '--source firstmate:claude --agent claude --state working --message "firstmate claude task worker starting"' \
    "$what: the launch must open a firstmate:claude Herdr record"
  assert_contains "$launch" 'firstmate claude task worker exited rc=' "$what: the launch must close the Herdr record on exit"
  assert_not_contains "$launch" '__CLAUDEPREFIX__' "$what: no placeholder may survive"
  assert_not_contains "$launch" "$REFMARK" "$what: no reference may reach launch text"
}

assert_token_hooks() {  # <id>
  local settings="$HOME_DIR/state/$1.claude-settings.json"
  assert_contains "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$settings")" \
    '--source firstmate:claude --agent claude --state working' 'a turn must report working to Herdr'
  assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")" \
    '--source firstmate:claude --agent claude --state idle' 'a turn end must report idle to Herdr'
  assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")" \
    'fm-busy-event.sh' 'the busy hook must still run'
}

test_token_seat_explicit_account() {
  local out rc id=tok-explicit launch
  new_case explicit
  out=$(spawn_case "$id" --account c1 --model sonnet); rc=$?
  expect_code 0 "$rc" "a token seat must launch: $out"
  assert_contains "$out" 'seat=c1' 'the spawned line names the token seat'
  launch=$(cat "$CASE/launch.log")
  assert_token_launch "$launch" 'explicit --account'
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$UH/.claude'" 'the seat store stays pinned for settings and sessions'
  assert_token_hooks "$id"
  assert_not_contains "$out" "$REFMARK" 'no reference may reach spawn output'
  ! grep -rqF "$REFMARK" "$HOME_DIR/state" || fail 'no reference may reach state files'
  pass 'an explicit token seat launches claude under opr, sheds ambient credentials, and reports to Herdr'
}

test_token_seat_from_store() {
  local out rc id=tok-store
  new_case store
  # No --account: the worker runs on the default store, which c1 owns.
  out=$(spawn_case "$id" --model sonnet); rc=$?
  expect_code 0 "$rc" "a worker on the token seat's store must launch: $out"
  [ "$(fm_meta_get "$HOME_DIR/state/$id.meta" seat)" = c1 ] || fail 'the store-derived seat must be recorded'
  assert_token_launch "$(cat "$CASE/launch.log")" 'store-derived seat'
  pass 'a worker on the token seat store gets the token without naming the account'
}

test_other_seat_unchanged() {
  local out rc id=plain launch settings
  new_case plain
  out=$(spawn_case "$id" --account c2 --model sonnet); rc=$?
  expect_code 0 "$rc" "a seat without a token must launch: $out"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" 'CLAUDE_CODE_SEND_FEEDBACK=0 claude ' 'a plain seat runs claude directly'
  assert_not_contains "$launch" 'opr ' 'a plain seat never rides opr'
  assert_not_contains "$launch" 'firstmate:claude' 'a plain seat adds no Herdr bracket'
  assert_not_contains "$launch" '-u CLAUDE_CODE_OAUTH_TOKEN' 'a plain unpinned seat keeps its environment'
  assert_not_contains "$launch" '__CLAUDEPREFIX__' 'no placeholder may survive'
  settings="$HOME_DIR/state/$id.claude-settings.json"
  assert_not_contains "$(cat "$settings")" 'firstmate:claude' 'a plain seat keeps its hooks'
  pass 'a seat without claudeTokenEnv launches exactly as before'
}

test_unusable_token_refuses() {
  local out rc id=tok-missing filtered entry
  new_case missing
  rm -f "$ENVOP"
  out=$(spawn_case "$id" --account c1 --model sonnet); rc=$?
  expect_code 1 "$rc" 'a missing token file must refuse'
  assert_contains "$out" "account 'c1' runs Claude on its claudeTokenEnv token" 'the refusal names the seat'
  assert_contains "$out" "$ENVOP is not a readable file" 'the refusal names the file'
  assert_absent "$HOME_DIR/state/$id.meta" 'a refusal publishes no metadata'
  assert_absent "$CASE/launch.log" 'a refusal sends no launch'
  printf 'CLAUDE_CODE_OAUTH_TOKEN="op://vault/item/%s"\n' "$REFMARK" > "$ENVOP"
  rm -f "$FAKEBIN/opr"
  # The developer's own opr must not answer for the missing one.
  filtered=
  while IFS= read -r entry; do
    [ -n "$entry" ] && [ ! -x "$entry/opr" ] || continue
    filtered="${filtered:+$filtered:}$entry"
  done < <(printf '%s\n' "$PATH" | tr ':' '\n')
  out=$(PATH="$filtered" spawn_case "$id-noopr" --account c1 --model sonnet); rc=$?
  expect_code 1 "$rc" 'a token seat without opr must refuse'
  assert_contains "$out" 'opr is not on PATH' 'the refusal names opr'
  assert_absent "$HOME_DIR/state/$id-noopr.meta" 'an opr refusal publishes no metadata'
  assert_absent "$CASE/launch.log" 'an opr refusal sends no launch'
  pass 'an unusable token setup refuses before any endpoint, record, or launch'
}

test_registry_field
test_token_env_lookup
test_token_check
test_token_seat_explicit_account
test_token_seat_from_store
test_other_seat_unchanged
test_unusable_token_refuses
echo '# all fm-account-claude-token tests passed'
