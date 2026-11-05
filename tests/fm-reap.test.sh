#!/usr/bin/env bash
# fm-reap.sh: finished crewmates and scouts close after their time; second
# mates, active tasks, and boards in review are left alone; shadow mode only
# reports, enforce mode closes through teardown and keeps what teardown refuses.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-reap)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state/procevent" "$HOME_DIR/state/procevent-inbox" "$HOME_DIR/config" "$HOME_DIR/data"
trap 'rm -rf "$TMP_ROOT"' EXIT
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data"
REAP="$ROOT/bin/fm-reap.sh"
now=$(date +%s)
task() {  # <id> <kind> <status lines...>
  local id=$1 kind=$2
  shift 2
  printf 'kind=%s\nharness=claude\n' "$kind" > "$HOME_DIR/state/$id.meta"
  printf '%s\n' "$@" > "$HOME_DIR/state/$id.status"
}
task old ship "working [at=$((now - 9000))]: x" "done [at=$((now - 8000))]: PR https://example.invalid/1" "resolved [key=k] [at=$((now - 10))]: answered"
task fresh ship "done [at=$((now - 600))]: PR https://example.invalid/2"
task busy scout "done [at=$((now - 90000))]: report" "working [at=$((now - 60))]: board round"
task scoutdone scout "done [at=$((now - 30000))]: report"
task mate secondmate "done [at=$((now - 900000))]: idle"
task review scout "done [at=$((now - 30000))]: report"
printf 'adapter=lavish\nkind=task-owned\nowner_task=review\n' > "$HOME_DIR/state/procevent/lavish-abc.source"
touch -d "@$((now - 3600))" "$HOME_DIR/state/procevent-inbox/lavish-abc.4.result"
out=$("$REAP" list)
assert_contains "$out" 'old due done 2h ago' 'a ship done past its time is due'
assert_contains "$out" 'fresh waiting done 10m ago, closes in 110m' 'a recent done waits'
assert_contains "$out" 'busy active working' 'a task that resumed is active'
assert_contains "$out" 'scoutdone due' 'a finished scout is due'
assert_not_contains "$out" 'mate' 'second mates are never listed'
assert_contains "$out" 'review waiting done 60m ago board, closes in 1380m' 'a board in review waits a day from its last round'
pass 'verdicts: done past its time, resumed, board grace, second mates exempt'
assert_equals '' "$("$REAP" check)" 'without config/reaper the reaper is off'
printf 'shadow\n' > "$HOME_DIR/config/reaper"
out=$("$REAP" check)
assert_contains "$out" 'reap (shadow, nothing closed): 2 finished worker(s) past their close time: old done 2h ago; scoutdone done 8h ago' 'shadow names every due worker once'
assert_equals '' "$("$REAP" check)" 'an unchanged due set does not wake again'
pass 'shadow mode reports the due set once and closes nothing'
printf 'enforce\n' > "$HOME_DIR/config/reaper"
cat > "$TMP_ROOT/teardown" <<'SH'
#!/usr/bin/env bash
case "$1" in
  old) printf 'tore down old\n' ;;
  *) printf 'error: refusing - the worktree holds work that has not landed (2 commits)\n' >&2; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/teardown"
out=$(FM_REAP_TEARDOWN="$TMP_ROOT/teardown" "$REAP" run)
assert_contains "$out" 'closed old (done 2h ago)' 'a landed worker is closed'
assert_contains "$out" 'kept scoutdone: error: refusing - the worktree holds work that has not landed (2 commits)' 'an unlanded worker is kept with teardown reason'
FM_REAP_TEARDOWN="$TMP_ROOT/teardown" "$REAP" check > "$TMP_ROOT/first"
for ((i = 0; i < 50; i++)); do [ -s "$HOME_DIR/state/reaper-run.log" ] && [ ! -d "$HOME_DIR/state/.reaper-run.lock" ] && break; sleep 0.1; done
sleep 1
touch "$HOME_DIR/state/reaper-run.log"
out=$(FM_REAP_TEARDOWN="$TMP_ROOT/teardown" "$REAP" check)
assert_contains "$out" 'reap: closed old' 'enforce reports the background run outcome'
assert_contains "$out" 'kept scoutdone' 'enforce reports what it kept'
pass 'enforce closes through teardown in the background and keeps what teardown refuses'
"$REAP" arm >/dev/null 2>&1 || true
assert_present "$HOME_DIR/state/reaper.check.sh" 'arm writes the watcher check'
assert_contains "$(<"$HOME_DIR/state/reaper.check.sh")" 'fm-reap.sh check' 'the check runs the reaper'
pass 'arm writes state/reaper.check.sh'
echo '# all fm-reap tests passed'
