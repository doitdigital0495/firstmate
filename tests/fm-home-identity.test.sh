#!/usr/bin/env bash
# Behavior tests for the durable session/account pin that keeps a Geris firstmate
# and a personal firstmate from ever mixing (bin/fm-home-identity.sh, and its
# gates in fm-spawn.sh, fm-send.sh, and fm-control.sh).
#
# Both directions are proved, not just one: a home pinned to the work session
# refuses a personal session, and a home pinned to the personal session refuses
# the work session. Every fixture store is a throwaway directory, so no case
# reads or depends on a real credential store.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IDENTITY="$ROOT/bin/fm-home-identity.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-identity)

# Two throwaway "accounts" standing in for the work and personal Claude stores.
GERIS_STORE="$TMP_ROOT/store-geris"
mkdir -p "$GERIS_STORE/projects"

# identity <home> <session> <store> <args...>
identity() {
  local home=$1 session=$2 store=$3
  shift 3
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    HERDR_SESSION="$session" CLAUDE_CONFIG_DIR="$store" \
    "$IDENTITY" "$@" 2>&1
}

new_home() {  # <dir>
  mkdir -p "$1/data" "$1/state" "$1/config" "$1/projects"
  printf '%s\n' "$1"
}

test_a_home_refuses_the_other_session_in_both_directions() {
  local work personal out status
  work=$(new_home "$TMP_ROOT/both/work")
  personal=$(new_home "$TMP_ROOT/both/personal")

  identity "$work" geris "$GERIS_STORE" ensure >/dev/null \
    || fail "pinning a fresh home from its own session must succeed"
  out=$(identity "$work" default "" ensure); status=$?
  expect_code 3 "$status" "a work-pinned home must refuse a personal session"
  assert_contains "$out" "belongs to session geris" "the refusal must name the home's own session"
  assert_contains "$out" "never migrated or merged" "the refusal must rule out migration"

  identity "$personal" default "" ensure >/dev/null \
    || fail "pinning a personal home from its own session must succeed"
  out=$(identity "$personal" geris "$GERIS_STORE" ensure); status=$?
  expect_code 3 "$status" "a personal-pinned home must refuse the work session"
  assert_contains "$out" "belongs to session default" "the refusal must name the home's own session"

  # And neither refusal rewrote anything.
  assert_grep "herdr_session=geris" "$work/data/home-identity" \
    "a refused session must not re-pin the work home"
  assert_grep "herdr_session=default" "$personal/data/home-identity" \
    "a refused session must not re-pin the personal home"
  pass "a firstmate home refuses the other session in both directions"
}

test_the_pin_survives_a_restart() {
  local home out
  home=$(new_home "$TMP_ROOT/restart/home")
  identity "$home" geris "$GERIS_STORE" ensure >/dev/null \
    || fail "pinning must succeed"

  # A restart is simply the next process: nothing is held in memory.
  out=$(identity "$home" geris "$GERIS_STORE" check)
  assert_contains "$out" "session=geris" "a later process must read the same pin"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$IDENTITY" store 2>&1)
  [ "$out" = "$GERIS_STORE" ] \
    || fail "the recorded account must survive a restart, got: $out"
  pass "the session and account pin survives a restart"
}

test_an_unreadable_pin_is_never_replaced() {
  local home out status
  home=$(new_home "$TMP_ROOT/corrupt/home")
  identity "$home" geris "$GERIS_STORE" ensure >/dev/null || fail "pinning must succeed"
  printf 'garbage\n' > "$home/data/home-identity"

  out=$(identity "$home" default "" ensure); status=$?
  expect_code 3 "$status" "an unreadable pin must refuse rather than re-pin"
  assert_contains "$out" "repair it deliberately" "the refusal must name the repair as deliberate"
  assert_grep "garbage" "$home/data/home-identity" \
    "a refused read must leave the recorded identity untouched"
  pass "an unreadable identity is refused, never replaced from the environment"
}

# --- real entry-point gates -------------------------------------------------

make_fakebin() {  # <dir>
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

# gate_case <name> <task-id> -> "<home>|<proj>|<wt>|<fakebin>|<launchlog>"
gate_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  new_home "$home" >/dev/null
  mkdir -p "$home/data/$id"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'Delivery contract: mode=no-mistakes\nbrief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog"
}

run_spawn_as() {  # <home> <proj> <wt> <fakebin> <launchlog> <session> <store> <args...>
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 session=$6 store=$7
  shift 7
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    HERDR_SESSION="$session" CLAUDE_CONFIG_DIR="$store" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" "$proj" --mode no-mistakes --yolo off 2>&1
}

test_spawn_refuses_a_foreign_session_and_creates_nothing() {
  local home proj wt fakebin launchlog out status
  IFS='|' read -r home proj wt fakebin launchlog <<< "$(gate_case spawn-foreign task-g)"

  out=$(run_spawn_as "$home" "$proj" "$wt" "$fakebin" "$launchlog" geris "$GERIS_STORE" task-g) \
    || fail "the first spawn from the home's own session must succeed: $out"
  assert_present "$home/state/task-g.meta" "the released spawn must publish its record"
  rm -f "$home/state/task-g.meta"

  out=$(run_spawn_as "$home" "$proj" "$wt" "$fakebin" "$launchlog" default "" task-g); status=$?
  [ "$status" -ne 0 ] || fail "a spawn from a foreign session must be refused"
  assert_contains "$out" "does not belong to the current session" \
    "the refusal must name the session mismatch"
  assert_absent "$home/state/task-g.meta" "a refused spawn must create no task record"
  [ ! -s "$launchlog" ] || fail "a refused spawn must send no launch command"
  pass "a spawn from a session the home does not belong to is refused and creates nothing"
}

test_a_secondmate_spawn_from_a_foreign_session_changes_nothing() {
  local home proj wt fakebin launchlog child out status before after
  IFS='|' read -r home proj wt fakebin launchlog <<< "$(gate_case spawn-sm-foreign sm-a)"

  # A seeded second-mate home of its own: the spawn's secondmate path would
  # fast-forward this checkout, create its state directory, and copy the
  # parent's local config into it before ever reaching the identity guard.
  child="$TMP_ROOT/spawn-sm-foreign/child"
  fm_git_worktree "$TMP_ROOT/spawn-sm-foreign/child-origin" "$child" sm-child
  mkdir -p "$child/bin" "$child/data" "$child/config" "$child/projects"
  printf 'sm-a\n' > "$child/.fm-secondmate-home"
  printf '# child home\n' > "$child/AGENTS.md"

  identity "$home" geris "$GERIS_STORE" ensure >/dev/null \
    || fail "pinning the parent home must succeed"
  printf '/some/work/store\n' > "$home/config/claude-shaped-store"

  before=$(cd "$child" && { git rev-parse HEAD; find . -path ./.git -prune -o -print | sort; })
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    HERDR_SESSION=default CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" sm-a "$child" --secondmate 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn from a foreign session must be refused"
  assert_contains "$out" "does not belong to the current session" \
    "the refusal must name the session mismatch"
  after=$(cd "$child" && { git rev-parse HEAD; find . -path ./.git -prune -o -print | sort; })
  [ "$before" = "$after" ] \
    || fail "a refused secondmate spawn changed the child home:"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
  assert_absent "$child/state" "a refused secondmate spawn must create no child state directory"
  assert_absent "$child/config/claude-shaped-store" \
    "a refused secondmate spawn must copy no parent config into the child home"
  assert_absent "$child/data/home-identity" \
    "a refused secondmate spawn must not pin the child home"
  pass "a secondmate spawn from a foreign session refuses before touching the child home"
}

test_a_worker_records_the_account_its_home_is_pinned_to() {
  local home proj wt fakebin launchlog launch
  IFS='|' read -r home proj wt fakebin launchlog <<< "$(gate_case relaunch-binding task-w)"

  run_spawn_as "$home" "$proj" "$wt" "$fakebin" "$launchlog" geris "$GERIS_STORE" task-w >/dev/null \
    || fail "the first spawn must succeed"
  assert_grep "claude_config_dir=$GERIS_STORE" "$home/state/task-w.meta" \
    "a first launch must record the account its home is pinned to"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$GERIS_STORE'" \
    "the worker must launch on its home's account"
  assert_not_contains "$launch" "-u CLAUDE_CONFIG_DIR" \
    "a work-bound worker must be given its account, not have one unset"
  pass "a worker records and launches on the account its home is pinned to"
}

test_a_personal_worker_is_never_handed_a_work_account() {
  local home proj wt fakebin launchlog launch
  IFS='|' read -r home proj wt fakebin launchlog <<< "$(gate_case personal-binding task-p)"

  # A personal home: no CLAUDE_CONFIG_DIR at all.
  run_spawn_as "$home" "$proj" "$wt" "$fakebin" "$launchlog" default "" task-p >/dev/null \
    || fail "the personal spawn must succeed"
  assert_grep "claude_config_dir=default" "$home/state/task-p.meta" \
    "a personal launch must record the default-store binding"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "-u CLAUDE_CONFIG_DIR" \
    "a personal worker must actively unset any inherited work account"
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "a personal worker must never be handed a work account"
  pass "a personal worker records the default account and is never handed a work one"
}

test_send_refuses_a_foreign_session() {
  local home out status
  home=$(new_home "$TMP_ROOT/send-foreign/home")
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" HERDR_SESSION=geris \
    CLAUDE_CONFIG_DIR="$GERIS_STORE" "$IDENTITY" ensure >/dev/null \
    || fail "pinning must succeed"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    HERDR_SESSION=default CLAUDE_CONFIG_DIR='' "$SEND" some-task "hello" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a message driven from a foreign session must be refused"
  assert_contains "$out" "belongs to session geris" \
    "the refusal must name the home's own session"
  pass "a message driven from a foreign session is refused"
}

test_a_phantom_home_is_never_pinned() {
  local out status missing rel
  missing="$TMP_ROOT/phantom/never-created"

  out=$(FM_HOME="$missing" HERDR_SESSION=geris CLAUDE_CONFIG_DIR="$GERIS_STORE" \
    "$IDENTITY" ensure 2>&1); status=$?
  expect_code 3 "$status" "a home directory that does not exist must not be pinned"
  assert_absent "$missing" "a refused pin must not materialize the home"

  out=$(FM_HOME="$missing" FM_STATE_OVERRIDE="$missing/state" \
    HERDR_SESSION=geris CLAUDE_CONFIG_DIR="$GERIS_STORE" \
    "$SEND" some-task "hello" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a send against a non-existent home must be refused"
  assert_contains "$out" "is not a directory" \
    "the refusal must be the home-directory error, not an identity pin"
  assert_absent "$missing" "a refused send must not materialize the home"

  # A relative FM_HOME would otherwise pin a phantom home under the caller's
  # working directory.
  rel=$TMP_ROOT/phantom/cwd
  mkdir -p "$rel"
  out=$(cd "$rel" && FM_HOME=not-a-home FM_STATE_OVERRIDE=not-a-home/state \
    HERDR_SESSION=geris CLAUDE_CONFIG_DIR="$GERIS_STORE" \
    "$SEND" some-task "hello" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a send against a relative non-home must be refused"
  assert_absent "$rel/not-a-home" \
    "a relative FM_HOME must leave no identity record in the working directory"
  pass "an FM_HOME that is not an existing home is refused and never pinned"
}

test_a_home_pins_itself_on_first_use() {
  local home out
  home=$(new_home "$TMP_ROOT/firstuse/home")
  assert_absent "$home/data/home-identity" "a fresh home starts unpinned"
  out=$(identity "$home" geris "$GERIS_STORE" ensure)
  assert_contains "$out" "pinned now" "a fresh home must be pinned by its first session"
  assert_grep "claude_config_dir=$GERIS_STORE" "$home/data/home-identity" \
    "the pin must record the account the session uses"
  pass "an unpinned home takes the identity of the session that first uses it"
}

test_a_home_refuses_the_other_session_in_both_directions
test_the_pin_survives_a_restart
test_an_unreadable_pin_is_never_replaced
test_a_home_pins_itself_on_first_use
test_a_phantom_home_is_never_pinned
test_spawn_refuses_a_foreign_session_and_creates_nothing
test_a_secondmate_spawn_from_a_foreign_session_changes_nothing
test_a_worker_records_the_account_its_home_is_pinned_to
test_a_personal_worker_is_never_handed_a_work_account
test_send_refuses_a_foreign_session
