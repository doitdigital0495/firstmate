#!/usr/bin/env bash
# Seat registry and worker seat labels: a Claude-only account registers without
# borrowing Pi/Codex stores, a launch needing a store the seat does not own is
# refused by name, and a worker's window shows its seat, plan and login email
# with the seat id recorded in the task's meta. No credential value is read.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-account-lib.sh
. "$ROOT/bin/fm-account-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-seat)
unset PI_CODING_AGENT_DIR LAVISH_AXI_HOST

SECRET=sk-ant-DO-NOT-LEAK

# ---- registry validity: each store optional, at least one present --------------
test_registry_validity() {
  local f="$TMP_ROOT/registry.json" doc
  valid() { printf '%s\n' "$1" > "$f"; fm_account_registry_valid "$f"; }
  valid '{"accounts":{"claude2":{"claude":"~/.claude-2"}}}' || fail 'a Claude-only account must register'
  valid '{"accounts":{"codex1":{"codex":"/h/.codex","pi":"/h/.pi/agent"}}}' || fail 'a Codex+Pi account without Claude must register'
  valid '{"accounts":{"glm":{"pi":"~/.pi/agent"}}}' || fail 'a Pi-only account must register'
  valid '{"accounts":{"x":{"claude":"~/.c","pi":"~/.p","codex":"~/.x"}}}' || fail 'a full account must keep registering'
  ! valid '{"accounts":{"empty":{}}}' || fail 'an account with no store at all must be refused'
  ! valid '{"accounts":{"nulls":{"claude":null,"pi":null,"codex":null}}}' || fail 'an account whose stores are all null must be refused'
  ! valid '{"accounts":{"bad":{"claude":"relative/path"}}}' || fail 'a present store must still be a valid path'
  ! valid '{"accounts":{"bad":{"claude":"~/.c","pi":7}}}' || fail 'a present malformed store must still refuse the registry'
  ! valid '{"accounts":{"Bad":{"claude":"~/.c"}}}' || fail 'account ids keep their pattern'
  doc='{"crossAccount":{"enabled":true},"accounts":{"claude2":{"claude":"/h/.claude-2"}}}'
  printf '%s\n' "$doc" > "$f"
  fm_account_enabled "$f" || fail 'a Claude-only registry must enable routing'
  pass 'claude, pi and codex stores are each optional but at least one is required'
}

test_stores_and_require() {
  local f="$TMP_ROOT/stores.json" stores err
  printf '%s\n' '{"crossAccount":{"enabled":true},"accounts":{"claude2":{"claude":"/h/.claude-2"},"full":{"claude":"/h/c","pi":"/h/p","codex":"/h/x"}}}' > "$f"
  stores=$(fm_account_stores "$f" claude2)
  [ "$stores" = $'/h/.claude-2\n-\n-' ] || fail "claude2 stores wrong: $stores"
  [ "$(fm_account_stores "$f" full)" = $'/h/c\n/h/p\n/h/x' ] || fail 'a full account keeps its three stores'
  ! fm_account_stores "$f" nope >/dev/null || fail 'an unknown account must not resolve'
  fm_account_has_store "$stores" claude || fail 'claude2 owns a Claude store'
  ! fm_account_has_store "$stores" pi || fail 'claude2 owns no Pi store'
  fm_account_require_store "$f" claude2 claude || fail 'claude2 can launch Claude'
  err=$(fm_account_require_store "$f" claude2 pi 2>&1) && fail 'claude2 must refuse a Pi launch'
  assert_contains "$err" "account 'claude2' has no pi store" 'refusal must name the account and the store'
  err=$(fm_account_require_store "$f" claude2 codex 2>&1) && fail 'claude2 must refuse a Codex launch'
  assert_contains "$err" "account 'claude2' has no codex store" 'refusal must name the codex store'
  fm_account_require_store "$f" /legacy/path pi || fail 'a non-registry binding is not judged here'
  [ "$(fm_account_read_store codex -)" = /nonexistent/fm-account-no-codex-store ] || fail 'a missing store reads as a path that never exists'
  [ "$(fm_account_read_store codex /h/x)" = /h/x ] || fail 'a real store is read unchanged'
  pass 'absent stores are marked, refused by name, and never read as the personal store'
}

test_seat_label_and_lookup() {
  local home="$TMP_ROOT/label-home" f out
  mkdir -p "$home/.claude-2" "$home/.claude-3"
  HOME=$home
  f="$TMP_ROOT/label.json"
  printf '%s\n' '{"accounts":{
    "claude2":{"claude":"~/.claude-2","plans":{"claude":"Ultra"}},
    "claude3":{"claude":"~/.claude-3","plans":{"claude":"Team premium"}},
    "codex1":{"pi":"~/.pi/agent","codex":"~/.codex","plans":{"codex":"ChatGPT Pro"}},
    "glm":{"pi":"~/.pi/agent","plans":{"zai":"Z.ai Pro"}}}}' > "$f"
  printf '{"oauthAccount":{"emailAddress":"cap@example.com","accessToken":"%s"},"token":"%s"}\n' "$SECRET" "$SECRET" > "$home/.claude-2/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"bad email\\u001b[31m@x"}}\n' > "$home/.claude-3/.claude.json"
  [ "$(fm_account_seat_for_store "$f" claude "$home/.claude-2")" = claude2 ] || fail 'store lookup must find the owning seat'
  [ "$(fm_account_seat_for_store "$f" claude "$home/.claude-2/")" = claude2 ] || fail 'a trailing slash must not hide the seat'
  [ -z "$(fm_account_seat_for_store "$f" claude "$home/.claude")" ] || fail 'an unregistered store names no seat'
  [ -z "$(fm_account_seat_for_store "$f" pi "$home/.pi/agent")" ] || fail 'a Pi store shared by two seats is ambiguous and names none'
  [ "$(fm_account_seat_for_store "$f" codex "$home/.codex")" = codex1 ] || fail 'a unique Codex store names its seat'
  out=$(fm_account_seat_label "$f" claude2 claude "$home/.claude-2")
  [ "$out" = 'claude2 · Ultra · cap@example.com' ] || fail "label wrong: $out"
  assert_not_contains "$out" "$SECRET" 'the label must never carry a credential value'
  out=$(fm_account_seat_label "$f" claude3 claude "$home/.claude-3")
  [ "$out" = 'claude3 · Team premium' ] || fail "an invalid email must be dropped, not cleaned: $out"
  out=$(fm_account_seat_label "$f" codex1 codex)
  [ "$out" = 'codex1 · ChatGPT Pro' ] || fail "a Codex seat shows seat and plan only: $out"
  out=$(fm_account_seat_label "$f" glm zai)
  [ "$out" = 'glm · Z.ai Pro' ] || fail "a Pi zai seat uses its provider plan: $out"
  out=$(fm_account_seat_label "$f" claude2 claude "$home/missing-store")
  [ "$out" = 'claude2 · Ultra' ] || fail "no email known shows seat and plan only: $out"
  [ -z "$(fm_account_seat_label "$f" '' claude)" ] || fail 'no seat prints no label'
  pass 'seat labels carry seat, declared plan and a validated email only'
}

# ---- spawn: the window label and the recorded seat ---------------------------
new_case() {
  CASE="$TMP_ROOT/$1"; HOME_DIR="$CASE/home"; PROJ="$CASE/project"; WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  CASE=$(cd -P "$CASE" && pwd -P)
  UH="$HOME_DIR/user-home"
  mkdir -p "$UH/.claude-2" "$UH/.pi/agent" "$UH/.codex"
  : > "$UH/.claude-2/signed-in"
  printf '{"oauthAccount":{"emailAddress":"cap@example.com","accessToken":"%s"}}\n' "$SECRET" > "$UH/.claude-2/.claude.json"
  jq -n '{crossAccount:{enabled:true}, accounts:{
    claude2:{claude:"~/.claude-2", plans:{claude:"Ultra"}},
    full:{claude:"~/.claude-2", pi:"~/.pi/agent", codex:"~/.codex", plans:{claude:"Max 20x", codex:"ChatGPT Pro"}}}}' \
    > "$HOME_DIR/config/accounts.json"
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
  auth) printf '{"status":"ready"}\n'; exit ;;
esac
SH
  chmod +x "$FAKEBIN/claude" "$FAKEBIN/pi"
  fm_test_pi_operator_extensions "$UH"
}

spawn_case() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

test_claude_window_label() {
  local out rc id=seat-claude settings cmd shown
  new_case claude claude
  out=$(spawn_case "$id" --account claude2 --model sonnet); rc=$?
  expect_code 0 "$rc" "a Claude-only seat must launch Claude: $out"
  assert_contains "$out" 'seat=claude2' 'the spawned line names the seat'
  [ "$(fm_meta_get "$HOME_DIR/state/$id.meta" seat)" = claude2 ] || fail 'meta must record the seat id'
  [ "$(fm_meta_get "$HOME_DIR/state/$id.meta" account)" = claude2 ] || fail 'the account= line is unchanged'
  [ "$(fm_meta_get "$HOME_DIR/state/$id.meta" claude_config_dir)" = "$UH/.claude-2" ] || fail 'the Claude store is the seat own'
  [ -z "$(fm_meta_get "$HOME_DIR/state/$id.meta" pi_agent_dir)" ] || fail 'no Pi store may be borrowed'
  [ -z "$(fm_meta_get "$HOME_DIR/state/$id.meta" codex_home)" ] || fail 'no Codex store may be borrowed'
  settings="$HOME_DIR/state/$id.claude-settings.json"
  cmd=$(jq -r '.statusLine.command' "$settings")
  shown=$(printf '%s' '{"model":{"display_name":"Opus"},"effort":{"level":"high"}}' | bash -c "$cmd")
  [ "$shown" = 'claude2 · Ultra · cap@example.com · Opus · high' ] || fail "status line wrong: $shown"
  shown=$(printf '%s' '{"model":{"display_name":"Opus"}}' | bash -c "$cmd")
  [ "$shown" = 'claude2 · Ultra · cap@example.com · Opus' ] || fail "a missing effort keeps the label: $shown"
  ! grep -rq "$SECRET" "$HOME_DIR/state" || fail 'no credential value may reach state files'
  assert_not_contains "$(cat "$CASE/launch.log")" "$SECRET" 'no credential value may reach the launch'
  # An account with no readable email shows seat and plan only.
  rm -f "$UH/.claude-2/.claude.json"
  out=$(spawn_case seat-claude-noemail --account claude2 --model sonnet); rc=$?
  expect_code 0 "$rc" "no email must not block the launch: $out"
  cmd=$(jq -r '.statusLine.command' "$HOME_DIR/state/seat-claude-noemail.claude-settings.json")
  shown=$(printf '%s' '{"model":{"display_name":"Opus"}}' | bash -c "$cmd")
  [ "$shown" = 'claude2 · Ultra · Opus' ] || fail "no email shows seat and plan only: $shown"
  pass 'a Claude task worker status line leads with seat, plan and email; the seat id is recorded'
}

test_unseated_worker_unchanged() {
  local out rc id=seat-none cmd shown
  new_case none claude
  rm -f "$HOME_DIR/config/accounts.json"
  out=$(spawn_case "$id" --model sonnet); rc=$?
  expect_code 0 "$rc" "a home with no registry must still launch: $out"
  [ -z "$(fm_meta_get "$HOME_DIR/state/$id.meta" seat)" ] || fail 'no seat is recorded when none is known'
  assert_not_contains "$out" 'seat=' 'the spawned line has no seat when none is known'
  cmd=$(jq -r '.statusLine.command' "$HOME_DIR/state/$id.claude-settings.json")
  shown=$(printf '%s' '{"model":{"display_name":"Opus"},"effort":{"level":"high"}}' | bash -c "$cmd")
  [ "$shown" = 'Opus · high' ] || fail "an unseated worker keeps the model/effort line: $shown"
  pass 'a worker with no known seat is launched and labelled exactly as before'
}

test_missing_store_refusals() {
  local out rc h model
  new_case refuse claude
  for h in pi codex; do
    rm -f "$CASE/launch.log"
    if [ "$h" = pi ]; then model=openai-codex/gpt-5.5; else model=gpt-5; fi
    out=$(spawn_case "seat-refuse-$h" --account claude2 --harness "$h" --model "$model"); rc=$?
    expect_code 1 "$rc" "a Claude-only seat must refuse a $h worker"
    assert_contains "$out" "account 'claude2' has no $h store" "$h: the refusal names the missing store"
    assert_absent "$HOME_DIR/state/seat-refuse-$h.meta" "$h: a refusal publishes no metadata"
    assert_absent "$CASE/launch.log" "$h: a refusal sends no launch"
  done
  pass 'a launch needing a store the seat does not own refuses clearly instead of falling through'
}

test_pi_and_codex_labels() {
  local out rc
  new_case other claude
  out=$(spawn_case seat-pi --account full --harness pi --model openai-codex/gpt-5.5); rc=$?
  expect_code 0 "$rc" "a full seat must launch Pi: $out"
  [ "$(fm_meta_get "$HOME_DIR/state/seat-pi.meta" seat)" = full ] || fail 'a Pi worker records its seat'
  assert_contains "$(cat "$HOME_DIR/state/seat-pi.pi-ext.ts")" 'const seatLabel = "full · ChatGPT Pro";' 'the Pi extension carries the seat label'
  assert_contains "$(cat "$HOME_DIR/state/seat-pi.pi-ext.ts")" 'setStatus("firstmate-seat", seatLabel)' 'the Pi extension publishes it on the footer status line'
  assert_not_contains "$(cat "$HOME_DIR/state/seat-pi.pi-ext.ts")" "$SECRET" 'the Pi extension carries no credential'
  rm -f "$CASE/launch.log"
  out=$(spawn_case seat-codex --account full --harness codex --model gpt-5); rc=$?
  expect_code 0 "$rc" "a full seat must launch Codex: $out"
  [ "$(fm_meta_get "$HOME_DIR/state/seat-codex.meta" seat)" = full ] || fail 'a Codex worker records its seat'
  assert_contains "$(cat "$CASE/launch.log")" "printf '%s\\n' 'seat: full · ChatGPT Pro'; codex" 'the Codex launch prints the seat once above the TUI'
  pass 'Pi workers show the label on the footer status line and Codex workers print it at launch'
}

# ---- quota snapshots never read the personal store for a missing one -----------
test_quota_snapshot_pins_absent_store() {
  local home="$TMP_ROOT/quota-home" fakebin out log="$TMP_ROOT/quota-pins.log"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/user-home/.claude-2"
  printf '%s\n' '{"crossAccount":{"enabled":true},"accounts":{"claude2":{"claude":"~/.claude-2"}}}' > "$home/config/accounts.json"
  fakebin=$(fm_fakebin "$TMP_ROOT/quota-fake")
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf 'claude=%s pi=%s codex=%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${PI_CODING_AGENT_DIR-unset}" "\${CODEX_HOME-unset}" >> "$log"
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  env HOME="$home/user-home" CLAUDE_CONFIG_DIR= PI_CODING_AGENT_DIR=/personal/pi CODEX_HOME=/personal/codex \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-quota-intake.sh" record >/dev/null 2>&1 || true
  out=$(grep "claude=$home/user-home/.claude-2 " "$log" || true)
  [ -n "$out" ] || fail "the claude2 snapshot was never read: $(cat "$log" 2>&1)"
  assert_contains "$out" 'pi=/nonexistent/fm-account-no-pi-store' 'a missing Pi store is not the personal one'
  assert_contains "$out" 'codex=/nonexistent/fm-account-no-codex-store' 'a missing Codex store is not the personal one'
  pass 'the quota snapshot of a Claude-only seat never reads the personal Pi or Codex store'
}

test_registry_validity
test_stores_and_require
test_seat_label_and_lookup
test_claude_window_label
test_unseated_worker_unchanged
test_missing_store_refusals
test_pi_and_codex_labels
test_quota_snapshot_pins_absent_store
echo '# all fm-account-seat tests passed'
