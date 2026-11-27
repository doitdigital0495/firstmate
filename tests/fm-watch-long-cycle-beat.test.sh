#!/usr/bin/env bash
# The watcher's liveness beacon through a maintenance pass longer than the
# stale grace, judged by a second real watcher's own re-arm verdict.
# No endpoint, harness process, model call, or remote host is needed.
#
#   1. A pass made of many short checks outlasts the grace and keeps completing
#      steps: a re-arm reads the holder as running, not as a stale heartbeat.
#   2. A pass stuck inside one step that never returns completes nothing: a
#      re-arm refuses it as stale past the grace, and replaces it once the
#      beacon passes the default hard bound of three times that grace.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-long-cycle-beat)

# A home whose due slow-check sweep runs <count> silent checks of <seconds>
# each. Every check appends one byte to check-trace as it starts.
make_home() {  # <name> <count> <seconds>
  local home="$TMP_ROOT/$1" count=$2 seconds=$3 i=1
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_test_track_watcher_state "$home/state"
  while [ "$i" -le "$count" ]; do
    cat > "$home/state/step$i.check.sh" <<SH
#!/usr/bin/env bash
printf x >> "$home/check-trace"
sleep $seconds
SH
    chmod 0700 "$home/state/step$i.check.sh"
    FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" "step$i" >/dev/null \
      || fail "could not register check step$i"
    i=$((i + 1))
  done
  printf '%s\n' "$home"
}

# Both the holder and every re-arm read one environment, so they judge the
# beacon with the same grace and the same default hard bound. The exec makes a
# backgrounded call's $! the watcher itself; a foreground call runs in its own
# subshell for the same reason.
watch_exec() {  # <home> <grace> <check-timeout>
  exec env -u FM_WATCHER_STALE_GRACE -u FM_WATCHER_STALL_BOUND \
    FM_HOME="$1" FM_GUARD_GRACE="$2" FM_CHECK_TIMEOUT="$3" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH"
}

checks_started() {  # <home>
  local size
  [ -f "$1/check-trace" ] || { printf '0\n'; return 0; }
  size=$(wc -c < "$1/check-trace")
  printf '%s\n' "$((size))"
}

wait_for_checks_started() {  # <home> <count> <polls>
  local i=0
  while [ "$i" -lt "$3" ]; do
    [ "$(checks_started "$1")" -lt "$2" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

beat_age() {  # <home>
  local beat="$1/state/.last-watcher-beat" mtime
  mtime=$(stat -c %Y "$beat" 2>/dev/null || stat -f %m "$beat" 2>/dev/null) || return 1
  printf '%s\n' "$(($(date +%s) - mtime))"
}

wait_for_beat_age() {  # <home> <seconds> <polls>
  local i=0 age
  while [ "$i" -lt "$3" ]; do
    age=$(beat_age "$1") && [ "$age" -ge "$2" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

stop_watcher() {  # <owned-pid>
  kill -TERM "$1" 2>/dev/null || true
  wait_for_exit "$1" 100 >/dev/null 2>&1 || true
}

test_long_pass_keeps_the_beacon_fresh() {
  local home holder grace=6 first_check_at elapsed status=0
  home=$(make_home long-pass 14 1)
  watch_exec "$home" "$grace" 30 > "$home/holder.out" 2> "$home/holder.err" &
  holder=$!
  wait_for_checks_started "$home" 1 600 \
    || { stop_watcher "$holder"; fail "the sweep never started: $(cat "$home/holder.err")"; }
  first_check_at=$(date +%s)
  # Nine checks started means eight finished: the pass is past the grace and
  # still has checks left to run while the re-arm below reads the beacon.
  wait_for_checks_started "$home" 9 600 \
    || { stop_watcher "$holder"; fail "the sweep stopped after $(checks_started "$home") checks"; }
  elapsed=$(($(date +%s) - first_check_at))
  [ "$elapsed" -ge "$grace" ] \
    || { stop_watcher "$holder"; fail "the pass ran only ${elapsed}s, not past the ${grace}s grace"; }
  ( watch_exec "$home" "$grace" 30 ) > "$home/rearm.out" 2> "$home/rearm.err" || status=$?
  is_live_non_zombie "$holder" || fail "the holder did not survive its long pass: $(cat "$home/holder.err")"
  stop_watcher "$holder"
  assert_not_contains "$(cat "$home/rearm.err")" "heartbeat is stale" \
    "a re-arm ${elapsed}s into a progressing pass read the holder as stale"
  expect_code 0 "$status" "re-arm against a progressing holder: $(cat "$home/rearm.err")"
  assert_contains "$(cat "$home/rearm.out")" "watcher: already running pid $holder" \
    "the re-arm did not report the progressing holder as running"
  pass "a maintenance pass longer than the grace keeps a fresh beacon while it completes steps"
}

test_hung_pass_still_goes_stale_and_is_replaced() {
  local home holder successor grace=5 bound=15 status=0 i=0
  home=$(make_home hung-pass 1 600)
  watch_exec "$home" "$grace" 600 > "$home/holder.out" 2> "$home/holder.err" &
  holder=$!
  wait_for_checks_started "$home" 1 600 \
    || { stop_watcher "$holder"; fail "the hung check never started: $(cat "$home/holder.err")"; }
  # Past the grace, under the hard bound: refused, and the holder is left alone.
  wait_for_beat_age "$home" $((grace + 1)) 300 \
    || { stop_watcher "$holder"; fail "a hung pass kept its beacon fresh (age $(beat_age "$home"))"; }
  ( watch_exec "$home" "$grace" 600 ) > "$home/refused.out" 2> "$home/refused.err" || status=$?
  if [ "$status" -eq 0 ] || ! grep -qF 'heartbeat is stale' "$home/refused.err"; then
    stop_watcher "$holder"
    fail "a re-arm did not refuse the hung holder as stale: $(cat "$home/refused.out" "$home/refused.err")"
  fi
  is_live_non_zombie "$holder" || fail "a holder under the hard bound was signalled"
  # Past the default hard bound of three times the grace: evicted and replaced.
  wait_for_beat_age "$home" $((bound + 1)) 300 \
    || { stop_watcher "$holder"; fail "the hung pass's beacon stopped ageing (age $(beat_age "$home"))"; }
  watch_exec "$home" "$grace" 600 > "$home/successor.out" 2> "$home/successor.err" &
  successor=$!
  while [ "$i" -lt 300 ]; do
    grep -qE "^watcher: replaced stalled pid $holder \(beacon [0-9]+s past hard bound ${bound}s\)\$" \
      "$home/successor.out" 2>/dev/null && break
    is_live_non_zombie "$successor" || break
    sleep 0.1
    i=$((i + 1))
  done
  if ! grep -qE "^watcher: replaced stalled pid $holder \(beacon [0-9]+s past hard bound ${bound}s\)\$" \
    "$home/successor.out"; then
    stop_watcher "$successor"
    stop_watcher "$holder"
    fail "the hard bound did not replace the hung holder: $(cat "$home/successor.out" "$home/successor.err")"
  fi
  stop_watcher "$successor"
  if is_live_non_zombie "$holder"; then
    stop_watcher "$holder"
    fail "the hung holder survived its replacement"
  fi
  wait "$holder" 2>/dev/null || true
  pass "a hung pass still reads stale past the grace and is replaced past the hard bound"
}

test_long_pass_keeps_the_beacon_fresh
test_hung_pass_still_goes_stale_and_is_replaced
