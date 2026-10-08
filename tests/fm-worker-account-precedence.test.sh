#!/usr/bin/env bash
# Composition guard: authoritative home pins, registered seats, and recorded
# relaunch stores must resolve one identity before quota, trust, or launch.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$ROOT/bin/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-account-precedence)
unset PI_CODING_AGENT_DIR LAVISH_AXI_HOST

new_case() {
  CASE="$TMP_ROOT/$1"; HOME_DIR="$CASE/home"; PROJ="$CASE/project"; WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$CASE/work" "$CASE/other" "$CASE/pi-work" "$CASE/pi-other" "$CASE/codex"
  CASE=$(cd -P "$CASE" && pwd -P)
  : > "$CASE/work/signed-in"; : > "$CASE/pi-work/signed-in"
  jq -n --arg work "$CASE/work" --arg other "$CASE/other" --arg pi "$CASE/pi-work" --arg pi_other "$CASE/pi-other" --arg codex "$CASE/codex" '
    {crossAccount:{enabled:true}, accounts:{
      matching:{claude:$work, pi:$pi, codex:$codex},
      conflicting:{claude:$other, pi:$pi_other, codex:$codex}}}
  ' > "$HOME_DIR/config/accounts.json"
  cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ]; then
  [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/signed-in" ]; exit
fi
printf 'root=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
SH
  cat > "$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --tui-mode <mode>'; exit ;;
  auth)
    [ -f "$PI_CODING_AGENT_DIR/signed-in" ] || exit 1
    printf '{"status":"ready"}\n'; exit ;;
esac
printf 'root=%s\n' "${PI_CODING_AGENT_DIR-unset}"
SH
  chmod +x "$FAKEBIN/claude" "$FAKEBIN/pi"
}

spawn_case() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

test_pin_and_registered_seat() {
  local harness pin other trust_file store_key out rc id launch model
  for harness in claude pi; do
    new_case "precedence-$harness" "$harness"
    if [ "$harness" = claude ]; then
      pin="$CASE/work"; other="$CASE/other"; trust_file=.claude.json; store_key=claude_config_dir; model=sonnet
      printf '%s\n' "$pin" > "$HOME_DIR/config/claude-account"
    else
      pin="$CASE/pi-work"; other="$CASE/pi-other"; trust_file=trust.json; store_key=pi_agent_dir; model=openai-codex/gpt-5.5
      printf '%s\nopenai-codex\n' "$pin" > "$HOME_DIR/config/pi-account"
    fi
    id="precedence-$harness-conflict"
    out=$(FM_QUOTA_INTAKE_TEST_BYPASS=0 spawn_case "$id" --account conflicting --model "$model"); rc=$?
    expect_code 1 "$rc" "$harness: conflicting seat must refuse before the real quota gate"
    assert_contains "$out" 'the configured pin is authoritative' "$harness: mismatch must name the authority"
    assert_absent "$HOME_DIR/state/$id.meta" "$harness: mismatch must not publish metadata"
    assert_absent "$CASE/launch.log" "$harness: mismatch must not send a launch"
    assert_absent "$HOME_DIR/state/quota-intake" "$harness: mismatch must not consume quota"
    assert_absent "$pin/$trust_file" "$harness: mismatch must not write trust into the pinned store"
    assert_absent "$other/$trust_file" "$harness: mismatch must not write trust into the conflicting store"
    id="precedence-$harness-match"
    out=$(spawn_case "$id" --account matching --model "$model"); rc=$?
    expect_code 0 "$rc" "$harness: matching registered seat should launch: $out"
    [ "$(fm_meta_get "$HOME_DIR/state/$id.meta" account)" = matching ] || fail "$harness: preserve the registered seat id"
    [ "$(fm_meta_get "$HOME_DIR/state/$id.meta" "$store_key")" = "$pin" ] || fail "$harness: metadata must name the effective store"
    launch=$(<"$CASE/launch.log")
    assert_contains "$launch" "$pin" "$harness: launch must use the metadata store"
    if [ "$harness" = claude ]; then
      assert_contains "$launch" '-u ANTHROPIC_API_KEY' 'a matching seat must still shed ambient credentials'
      assert_present "$pin/.claude.json" 'trust registration must use the same pinned store'
    fi
  done
  pass 'authoritative pins refuse conflicting seats before quota/trust/launch and preserve matching seat identities'
}

test_recorded_relaunch_bindings() {
  local meta selection store out rc
  new_case recorded claude
  meta="$CASE/recorded.meta"
  selection=$(printf '%s\t%s\t\n' "$CASE/work" "$CASE/work")
  printf 'harness=claude\naccount=%s\n' "$CASE/other" > "$meta"
  store=$(fm_worker_account_recorded_store claude "$meta")
  [ "$store" = "$CASE/other" ] || fail 'legacy upstream metadata must retain its store'
  out=$(fm_worker_account_effective_store claude "$selection" "$store" 'recorded relaunch binding' 2>&1); rc=$?
  expect_code 1 "$rc" 'a recorded legacy binding must not drift under a changed pin'
  assert_contains "$out" 'recorded relaunch binding' 'refusal must identify the existing task binding'
  printf 'harness=claude\nclaude_config_dir=default\n' > "$meta"
  store=$(fm_worker_account_recorded_store claude "$meta")
  out=$(fm_worker_account_effective_store claude "$selection" "$store" 'recorded relaunch binding' 2>&1); rc=$?
  expect_code 1 "$rc" 'the fork default binding must not drift onto a different store'
  out=$(fm_worker_account_effective_store claude '' "$CASE/other" 'registered seat')
  [ "$out" = "$CASE/other" ] || fail 'absent pins must preserve registered routing'
  selection=$(printf 'ordinary\t\t\n')
  out=$(fm_worker_account_effective_store claude "$selection" default 'recorded binding')
  [ "$out" = default ] || fail 'ordinary Claude must preserve its unset-root identity'
  out=$(fm_worker_account_effective_store claude "$selection" "$HOME/.claude" 'registered seat' 2>&1); rc=$?
  expect_code 1 "$rc" 'ordinary and an explicit ~/.claude root are different Keychain identities'
  pass 'legacy and fork relaunch bindings cannot silently drift; unpinned and ordinary identities remain stable'
}

test_pin_and_registered_seat
test_recorded_relaunch_bindings
echo '# all fm-worker-account-precedence tests passed'
