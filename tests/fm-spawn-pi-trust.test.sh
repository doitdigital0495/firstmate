#!/usr/bin/env bash
# Behavior tests for Pi project-trust pre-registration on a pi or pi-signed
# crewmate spawn (bin/fm-pi-trust.sh, called from bin/fm-spawn.sh).
#
# Pi parks a fresh worktree that carries project resources behind its
# "Trust project folder?" dialog unless trust.json in the launch's agent dir
# already records that worktree as true. These cases spawn through the fake
# tmux and read back the store the launch would consult, without starting Pi.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-trust)
TRUST="$ROOT/bin/fm-pi-trust.sh"

# make_case <name> <harness> <id> -> sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR WT_REAL FAKEBIN_DIR LAUNCH_LOG
make_case() {
  local name=$1 harness=$2 id=$3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake" pi pi-signed)
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  WT_REAL=$(cd -P "$WT_DIR" && pwd -P)
  mkdir -p "$HOME_DIR/user-home"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$LAUNCH_LOG"
}

run_ship_spawn() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@" --mode direct-PR --yolo off
}

# trust_value <store> <key> -> prints true, false, null, or absent from parsed JSON
trust_value() {
  node -e 'const fs=require("node:fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const k=process.argv[2];console.log(Object.hasOwn(j,k)?String(j[k]):"absent");' "$1" "$2"
}

assert_trusted() {  # <store> <path> <msg>
  [ -f "$1" ] || fail "$3: no store at $1"
  assert_equals true "$(trust_value "$1" "$2")" "$3"
}

test_default_store_registers_worktree() {
  local id=pi-trust-default-t1 out status store
  make_case default pi "$id"
  store="$HOME_DIR/user-home/.pi/agent/trust.json"
  mkdir -p "${store%/*}"
  printf '%s\n' '{"/elsewhere/declined": false, "/elsewhere/kept": true, "/elsewhere/cleared": null}' > "$store"
  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn should succeed: $out"
  [ -s "$LAUNCH_LOG" ] || fail "pi spawn did not launch"
  assert_trusted "$store" "$WT_REAL" "pi spawn did not trust the worktree in ~/.pi/agent/trust.json"
  assert_equals false "$(trust_value "$store" /elsewhere/declined)" "registration clobbered a declined entry"
  assert_equals true "$(trust_value "$store" /elsewhere/kept)" "registration clobbered a trusted entry"
  assert_equals null "$(trust_value "$store" /elsewhere/cleared)" "registration clobbered a null entry"
  assert_absent "$store.lock" "registration left Pi's trust lock behind"
  pass "a pi spawn trusts its worktree in the default agent dir and preserves every other entry"
}

test_inherited_agent_dir_is_used() {
  local id=pi-trust-envdir-t2 out status agent_dir
  make_case envdir pi-signed "$id"
  agent_dir="$CASE_DIR/pi-agent"
  mkdir -p "$agent_dir/extensions"
  : > "$agent_dir/extensions/herdr-agent-state.ts"
  : > "$agent_dir/extensions/rtk-compact.ts"
  out=$(FM_TEST_PI_CODING_AGENT_DIR="$agent_dir" run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi-signed spawn should succeed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "export PI_CODING_AGENT_DIR='$agent_dir'" "launch did not export the agent dir"
  assert_trusted "$agent_dir/trust.json" "$WT_REAL" "pi-signed spawn did not trust the worktree in the launch's agent dir"
  assert_absent "$HOME_DIR/user-home/.pi/agent/trust.json" "registration wrote the default store instead of the launch's"
  pass "a pi-signed spawn trusts its worktree in the agent dir the launch exports"
}

test_pinned_account_store_is_used() {
  local id=pi-trust-account-t3 out status acct_dir
  make_case account pi "$id"
  acct_dir="$CASE_DIR/acct-pi"
  mkdir -p "$acct_dir"
  printf '%s\n' "{\"accounts\":{\"work\":{\"claude\":\"$CASE_DIR/acct-claude\",\"pi\":\"$acct_dir\",\"codex\":\"$CASE_DIR/acct-codex\"}},\"crossAccount\":{\"enabled\":true}}" > "$HOME_DIR/config/accounts.json"
  out=$(run_ship_spawn "$id" "$PROJ_DIR" --account work)
  status=$?
  expect_code 0 "$status" "pi spawn pinned to an account should succeed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "export PI_CODING_AGENT_DIR='$acct_dir'" "launch did not export the account's agent dir"
  assert_trusted "$acct_dir/trust.json" "$WT_REAL" "pinned spawn did not trust the worktree in the account's agent dir"
  assert_absent "$HOME_DIR/user-home/.pi/agent/trust.json" "pinned spawn wrote the default store"
  pass "a pi spawn pinned to an account trusts its worktree in that account's agent dir"
}

test_stale_decline_is_replaced() {
  local id=pi-trust-stale-t4 out status store
  make_case stale pi "$id"
  store="$HOME_DIR/user-home/.pi/agent/trust.json"
  mkdir -p "${store%/*}"
  printf '{"%s": false}\n' "$WT_REAL" > "$store"
  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn over a stale decline should succeed: $out"
  assert_trusted "$store" "$WT_REAL" "a stale false on a reused worktree path survived the spawn"
  pass "a stale decline left on a reused worktree path is replaced by trust"
}

test_helper_refuses_out_of_scope_paths() {
  local out status agent_dir other
  make_case scope pi scope-t5
  agent_dir="$CASE_DIR/pi-agent"
  other="$CASE_DIR/other"
  fm_git_init_commit "$other"
  out=$(HOME="$HOME_DIR/user-home" "$TRUST" "$PROJ_DIR" "$PROJ_DIR" "$agent_dir" 2>&1)
  status=$?
  expect_code 1 "$status" "a primary checkout should be refused"
  assert_contains "$out" "is a primary checkout" "primary checkout refusal did not say why"
  out=$(HOME="$HOME_DIR/user-home" "$TRUST" "$WT_DIR" "$other" "$agent_dir" 2>&1)
  status=$?
  expect_code 1 "$status" "a worktree of another project should be refused"
  assert_contains "$out" "is not a worktree of project" "unrelated-project refusal did not say why"
  mkdir -p "$WT_DIR/sub"
  out=$(HOME="$HOME_DIR/user-home" "$TRUST" "$WT_DIR/sub" "$PROJ_DIR" "$agent_dir" 2>&1)
  status=$?
  expect_code 1 "$status" "a worktree subdirectory should be refused"
  assert_absent "$agent_dir/trust.json" "a refused registration still wrote the store"
  pass "fm-pi-trust.sh refuses a primary checkout, another project's worktree, and a subdirectory"
}

test_helper_waits_for_pi_lock() {
  local out status agent_dir store
  make_case lock pi lock-t6
  agent_dir="$CASE_DIR/pi-agent"
  store="$agent_dir/trust.json"
  mkdir -p "$store.lock"
  ( sleep 1; rmdir "$store.lock" ) &
  out=$(HOME="$HOME_DIR/user-home" "$TRUST" "$WT_DIR" "$PROJ_DIR" "$agent_dir" 2>&1)
  status=$?
  wait
  expect_code 0 "$status" "registration behind a held Pi lock should succeed once released: $out"
  assert_trusted "$store" "$WT_REAL" "registration behind a held lock did not record trust"
  pass "fm-pi-trust.sh waits for Pi's own trust lock instead of writing through it"
}

test_default_store_registers_worktree
test_inherited_agent_dir_is_used
test_pinned_account_store_is_used
test_stale_decline_is_replaced
test_helper_refuses_out_of_scope_paths
test_helper_waits_for_pi_lock

echo "# all fm-spawn-pi-trust tests passed"
