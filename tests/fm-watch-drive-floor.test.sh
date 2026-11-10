#!/usr/bin/env bash
# Drive-floor backstop through the watcher's real queue interface. The floor is
# config/drive-floor; only the crew-state verdict is stubbed through
# FM_CREW_STATE_BIN, its documented test seam. No endpoint, harness process,
# model call, or remote host is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-drive-floor)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"

# The stub prints the line recorded in <state>/<id>.crew-state-line, exactly as
# bin/fm-crew-state.sh would print its one canonical line, and records whether
# the caller asked it to skip the forge read.
STUB="$TMP_ROOT/crew-state-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${FM_CREW_STATE_NO_FORGE:-0}" >> "$FM_STATE_OVERRIDE/.stub-calls"
cat "$FM_STATE_OVERRIDE/$1.crew-state-line" 2>/dev/null || printf 'state: unknown · source: none · no metadata for %s\n' "$1"
EOF
chmod +x "$STUB"
export FM_CREW_STATE_BIN="$STUB"

# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

DRIVE_FLOOR_SCAN_SECS=0
PAUSE_RESURFACE_SECS=10000

reset_case() {
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$CONFIG"/*
  DRIVE_FLOOR=
}

floor() {  # <value>
  printf '%s\n' "$1" > "$CONFIG/drive-floor"
}

lane() {  # <task> <crew-state line> [meta-kind]
  printf 'working [at=1000]: on it\n' > "$STATE/$1.status"
  printf 'worktree=%s\nkind=%s\n' "$TMP_ROOT" "${3:-ship}" > "$STATE/$1.meta"
  printf '%s\n' "$2" > "$STATE/$1.crew-state-line"
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

stub_calls() {
  if [ -f "$STATE/.stub-calls" ]; then wc -l < "$STATE/.stub-calls" | tr -d ' '; else printf 0; fi
}

test_off_without_config() {
  reset_case
  lane w 'state: working · source: run-step · validating (running) · run: r1'
  lane p 'state: parked · source: run-step · parked at rebase · run: r2'
  drive_floor_tick 1000
  drive_floor_tick 2000
  [ "$(count_wakes)" = 0 ] || fail "a home without config/drive-floor raised a drive wake"
  [ "$(stub_calls)" = 0 ] || fail "an unconfigured home paid a crew-state read"
  [ ! -e "$STATE/.drive-floor" ] || fail "an unconfigured home kept a ledger"
  [ ! -e "$STATE/.drive-floor-scan" ] || fail "an unconfigured home kept a scan stamp"
  pass "without config/drive-floor the tick reads nothing and wakes nothing"
}

test_invalid_settings_stop_the_tick() {
  reset_case
  lane p 'state: parked · source: run-step · parked at rebase · run: r1'
  for value in '' abc 0 007 8x -8 1234567890; do
    floor "$value"
    if drive_floor_tick 1000; then fail "floor '$value' did not fail the tick"; fi
    [ "$(count_wakes)" = 0 ] || fail "floor '$value' raised a wake"
  done
  floor 8
  if FM_DRIVE_FLOOR_HOLD_SECS=abc drive_floor_tick 1000; then fail "an invalid hold did not fail the tick"; fi
  pass "a present but invalid floor or hold stops the tick with an error"
}

test_counts_only_busy_workers() {
  reset_case
  floor 8
  lane busy 'state: working · source: run-step · validating (running) · run: r1'
  lane held 'state: blocked · source: status-log · daemon socket refuses connections'
  lane listener 'state: parked · source: run-step · parked at review · run: r3'
  lane finished 'state: done · source: run-step · checks green: PR merged (ci monitor ended) · run: r4'
  lane wedged 'state: unknown · source: none · unreadable verdict'
  lane pausedlane 'state: paused · source: status-log · waiting on external condition'
  lane mate 'state: working · source: run-step · validating (running) · run: r7' secondmate
  printf 'working [at=1000]: no meta\n' > "$STATE/nometa.status"
  printf 'state: parked · source: run-step · parked at rebase · run: r8' > "$STATE/nometa.crew-state-line"
  drive_floor_tick 1000
  drive_floor_tick 1900
  [ "$(count_wakes)" = 1 ] || fail "the below-floor fleet did not raise exactly one wake"
  [ "$DRIVE_FLOOR" = 'check: drive floor: 1 working < 8 900s (threshold 900s): idle: finished=done, held=blocked, listener=parked, wedged=unknown' ] \
    || fail "unexpected drive-floor reason: $DRIVE_FLOOR"
  case "$DRIVE_FLOOR" in *pausedlane*|*mate*|*nometa*) fail "the reason named a non-lane or expected-idle worker: $DRIVE_FLOOR" ;; esac
  grep -q '^pausedlane ' "$STATE/.stub-calls" || fail "a paused lane was not read as a lane"
  grep -v ' 1$' "$STATE/.stub-calls" >/dev/null && fail "a drive scan did not skip the forge"
  ! grep -q '^mate ' "$STATE/.stub-calls" || fail "a secondmate meta was read as a lane"
  ! grep -q '^nometa ' "$STATE/.stub-calls" || fail "a status file without meta was read as a lane"
  pass "only busy lanes count as working; parked, held, finished and unknown are named idle; paused stays expected idle and secondmates are no lane"
}

test_silent_without_startable_work() {
  reset_case
  floor 8
  lane a 'state: working · source: run-step · validating (running) · run: r1'
  lane b 'state: working · source: run-step · validating (fixing) · run: r2'
  drive_floor_tick 1000
  drive_floor_tick 9900
  [ "$(count_wakes)" = 0 ] || fail "a fleet with every lane busy raised a drive wake"
  [ ! -s "$STATE/.drive-floor" ] || fail "a saturated fleet kept a below-floor episode"
  reset_case
  floor 8
  lane p 'state: paused · source: status-log · waiting on external condition'
  lane d 'state: done · source: run-step · checks green: PR merged (ci monitor ended) · run: r2'
  drive_floor_tick 1000
  drive_floor_tick 9900
  [ "$(count_wakes)" = 0 ] || fail "a fleet with nothing but pauses and done lanes raised a drive wake"
  reset_case
  floor 8
  drive_floor_tick 1000
  drive_floor_tick 9900
  [ "$(count_wakes)" = 0 ] || fail "an empty home raised a drive wake"
  [ "$(stub_calls)" = 0 ] || fail "an empty home paid a crew-state read"
  pass "without startable lanes - all busy, only pauses and done, or no lanes - the tick stays silent"
}

test_hold_and_repeat() {
  reset_case
  floor 8
  lane a 'state: working · source: run-step · validating (running) · run: r1'
  lane b 'state: parked · source: run-step · parked at rebase · run: r2'
  drive_floor_tick 1000
  [ "$(count_wakes)" = 0 ] || fail "the floor fired before its hold elapsed"
  [ "$(cat "$STATE/.drive-floor")" = $'1000\t0' ] || fail "the first scan did not open the episode: $(cat "$STATE/.drive-floor")"
  drive_floor_tick 1899
  [ "$(count_wakes)" = 0 ] || fail "the floor fired one second before its hold"
  drive_floor_tick 1900
  [ "$(count_wakes)" = 1 ] || fail "the floor did not fire at its hold"
  [ "$(cat "$STATE/.drive-floor")" = $'1000\t1900' ] || fail "the escalation was not ledgered: $(cat "$STATE/.drive-floor")"
  drive_floor_tick 11899
  [ "$(count_wakes)" = 1 ] || fail "the floor repeated before the recheck cadence"
  drive_floor_tick 11900
  [ "$(count_wakes)" = 2 ] || fail "the floor did not repeat on the recheck cadence"
  [ "$DRIVE_FLOOR" = 'check: drive floor: 1 working < 8 10900s (threshold 900s): idle: b=parked' ] \
    || fail "the repeat did not carry the whole age: $DRIVE_FLOOR"
  pass "the floor holds for FM_DRIVE_FLOOR_HOLD_SECS, then repeats once per recheck cadence"
}

test_episode_resets() {
  reset_case
  floor 8
  lane a 'state: working · source: run-step · validating (running) · run: r1'
  lane b 'state: parked · source: run-step · parked at rebase · run: r2'
  drive_floor_tick 1000
  printf '%s\n' 'state: working · source: run-step · validating (running) · run: r2' > "$STATE/b.crew-state-line"
  drive_floor_tick 1200
  [ ! -s "$STATE/.drive-floor" ] || fail "a recovered fleet kept its episode"
  printf '%s\n' 'state: parked · source: run-step · parked at rebase · run: r2' > "$STATE/b.crew-state-line"
  drive_floor_tick 1300
  drive_floor_tick 2199
  [ "$(count_wakes)" = 0 ] || fail "a second dip inherited the first episode's clock"
  drive_floor_tick 2200
  [ "$(count_wakes)" = 1 ] || fail "the fresh episode did not fire on its own clock"
  rm -f -- "$CONFIG/drive-floor"
  drive_floor_tick 2300
  [ ! -e "$STATE/.drive-floor" ] || fail "removing the config kept the ledger"
  [ ! -e "$STATE/.drive-floor-scan" ] || fail "removing the config kept the scan stamp"
  pass "recovering to the floor, dipping again, or removing the config each start fresh"
}

test_scan_throttle() {
  reset_case
  floor 8
  DRIVE_FLOOR_SCAN_SECS=300
  lane a 'state: working · source: run-step · validating (running) · run: r1'
  lane b 'state: parked · source: run-step · parked at rebase · run: r2'
  drive_floor_tick 1000
  drive_floor_tick 1299
  [ "$(stub_calls)" = 2 ] || fail "the scan ran inside its interval: $(stub_calls)"
  drive_floor_tick 1300
  [ "$(stub_calls)" = 4 ] || fail "the scan did not run after its interval: $(stub_calls)"
  DRIVE_FLOOR_SCAN_SECS=0
  pass "the scan runs once per interval"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/state/home-summary.json"
  printf '8\n' > "$dir/config/drive-floor"
  printf 'working [at=1000]: on it\n' > "$dir/state/worker.status"
  printf 'worktree=%s\nkind=ship\n' "$dir" > "$dir/state/worker.meta"
  printf '%s\n' 'state: working · source: run-step · validating (running) · run: r1' > "$dir/state/worker.crew-state-line"
  printf 'parked [at=1000]: listener\n' > "$dir/state/listener.status"
  printf 'worktree=%s\nkind=ship\n' "$dir" > "$dir/state/listener.meta"
  printf '%s\n' 'state: parked · source: run-step · parked at review · run: r2' > "$dir/state/listener.crew-state-line"
  # A ledger an earlier watcher left behind: the episode clock survives a restart.
  printf '1000\t0\n' > "$dir/state/.drive-floor"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$STUB" \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on a below-floor fleet"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F 'check: drive floor: 1 working < 8 ' "$dir/out" >/dev/null \
    || fail "real watcher did not print the drive-floor wake: $(cat "$dir/out")"
  grep -F 'drive-floor' "$dir/state/.wake-queue" >/dev/null \
    || fail "real watcher did not durably queue the drive-floor wake"
  pass "the actual watcher wakes and exits on a below-floor fleet, keeping the clock across a restart"
}

fm_test_run test_off_without_config test_invalid_settings_stop_the_tick \
  test_counts_only_busy_workers test_silent_without_startable_work \
  test_hold_and_repeat test_episode_resets test_scan_throttle test_watcher_loop
