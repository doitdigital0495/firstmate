#!/usr/bin/env bash
# Quiet relays (bin/fm-bridge.sh header, QUIET RELAYS): a secondmate's relayed
# `captain-hold-<task>-<n>` line is quiet in this home - no watcher wake, no
# OPEN DECISIONS listing, no overdue reminder - exactly while that secondmate's
# Bridge export is fresh and shows the hold. Every other case (export missing,
# stale, invalid, a hold the export does not show, an older occurrence, the
# Bridge off) keeps the relay waking as before. Each case runs the real
# relay-shown command, the real wake drain, and the watcher's own signal,
# secondmate-routine and reminder functions over a crafted home.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

BRIDGE="$ROOT/bin/fm-bridge.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-bridge-quiet-relays)
H="$TMP_ROOT/home"
SM="$TMP_ROOT/sm"
NOW=$(date +%s)
OPENED=$((NOW - 4000))

export FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config"
export FM_DATA_OVERRIDE="$H/data"

# fixture <export: fresh|missing|stale|invalid> [relay-key] [bridge: on|off]
fixture() {
  local export=$1 key=${2:-captain-hold-pick-1} bridge=${3:-on} gen=$NOW
  rm -rf "$H" "$SM"
  mkdir -p "$H/state" "$H/config" "$H/data" "$SM/state/bridge"
  [ "$bridge" = off ] || printf '{"schema":"fm-bridge-config.v1","enabled":true}\n' > "$H/config/bridge.json"
  fm_write_meta "$H/state/sm1.meta" 'kind=secondmate' "home=$SM" "worktree=$SM"
  [ "$export" != stale ] || gen=$((NOW - 3600))
  case "$export" in
    missing) ;;
    invalid) printf 'not json' > "$SM/state/bridge/asks.json" ;;
    *)
      jq -n --argjson gen "$gen" '{schema:"fm-bridge-export.v1", generated_epoch:$gen, complete:true, asks:[
        {route:{kind:"hold", task:"pick", lifecycle:"2026-01-01T00:00:00Z#0"}, who:"you", source:"hold",
         question:"Which colour for the harbor sign?"}]}' > "$SM/state/bridge/asks.json"
      ;;
  esac
  printf 'needs-decision [key=%s] [at=%s]: captain hold pick: which colour\n' "$key" "$OPENED" > "$H/state/sm1.status"
}

relay_shown() { printf 'sm1\t%s\n' "${1:-captain-hold-pick-1}" | "$BRIDGE" relay-shown; }

# The watcher's three wake paths, in a subshell that sources the real watcher.
# Prints: span=<rc>/<needs-decision>/<quiet-only> routine=<0|1> reminder=<reason or none>
watch_paths() {
  (
    # shellcheck source=bin/fm-watch.sh
    . "$ROOT/bin/fm-watch.sh"
    local rec='' nd=0 q=0 rc=0 rt=0
    status_span_first_actionable_record "$STATE/sm1.status" 0 rec nd q || rc=$?
    _fm_secondmate_status_new_lines_routine "$STATE/sm1.status" "$STATE" || rt=$?
    touch "$CONFIG/open-decision-reminders"
    FM_OPEN_DECISION_OVERDUE_SECS=100
    OPEN_DECISION_REMINDER=
    open_decision_reminder_tick "$NOW" >/dev/null 2>&1 || true
    printf 'span=%s/%s/%s routine=%s reminder=%s\n' "$rc" "$nd" "$q" "$rt" "${OPEN_DECISION_REMINDER:-none}"
  )
}

drain() { "$DRAIN" 2>/dev/null; }

# A relay that stays loud: relay-shown prints nothing, the drain lists it, and
# every watcher path treats it as an actionable needs-decision.
assert_loud() {  # <case-label> <key>
  local label=$1 key=$2 out
  out=$(relay_shown "$key") || true
  [ -z "$out" ] || fail "$label: relay-shown called the relay shown: $out"
  out=$(drain)
  assert_contains "$out" "key=$key" "$label: the drain did not list the relay"
  case "$out" in *'relayed captain holds not listed'*) fail "$label: the drain counted the relay as quiet" ;; esac
  out=$(watch_paths)
  case "$out" in
    'span=0/1/0 routine=1 reminder=check: open decision overdue: sm1 key='"$key"' age='*) ;;
    *) fail "$label: the watcher did not keep the relay waking: $out" ;;
  esac
}

test_fresh_matching_export_is_quiet() {
  local out
  fixture fresh
  out=$(relay_shown) || fail "relay-shown failed with the Bridge on"
  [ "$out" = "$(printf 'sm1\tcaptain-hold-pick-1')" ] || fail "relay-shown did not print the shown relay: $out"
  out=$(drain)
  case "$out" in *'OPEN DECISIONS'*) fail "the drain printed a section for quiet relays alone: $out" ;; esac
  # Beside a real open decision the quiet relay is counted, not listed.
  printf 'needs-decision [key=api] [at=%s]: REST or RPC\n' "$NOW" > "$H/state/w1.status"
  out=$(drain)
  assert_contains "$out" 'key=api' "the drain dropped a real decision"
  case "$out" in *'key=captain-hold-pick-1'*) fail "the drain listed a relay the Bridge shows: $out" ;; esac
  assert_contains "$out" 'OPEN DECISIONS: 1 relayed captain holds not listed' "the drain did not count the quiet relay"
  rm -f "$H/state/w1.status"
  out=$(watch_paths)
  [ "$out" = 'span=1/0/1 routine=0 reminder=none' ] || fail "the watcher woke for a quiet relay: $out"
  # The relay's keyed line is untouched: it is still open in the shared fold.
  assert_grep 'captain-hold-pick-1' "$H/state/sm1.status" "the relay line was rewritten"
  pass "a relay of a hold the fresh export shows neither wakes, lists, nor reminds"
}

test_fresh_export_beside_a_loud_line_still_wakes() {
  local out
  fixture fresh
  printf 'blocked [at=%s]: the harbor is closed\n' "$NOW" >> "$H/state/sm1.status"
  out=$(watch_paths)
  case "$out" in 'span=0/'*'/0 routine=1 '*) ;; *) fail "a quiet relay hid a real line in the same span: $out" ;; esac
  pass "a quiet relay never hides another line in the same span"
}

test_missing_export_wakes() {
  fixture missing
  assert_loud "missing export" captain-hold-pick-1
  pass "with no export the relay wakes, lists and reminds as before"
}

test_stale_export_wakes() {
  fixture stale
  assert_loud "stale export" captain-hold-pick-1
  pass "with a stale export the relay wakes, lists and reminds as before"
}

test_invalid_export_wakes() {
  fixture invalid
  assert_loud "invalid export" captain-hold-pick-1
  pass "with an invalid export the relay wakes, lists and reminds as before"
}

test_hold_not_shown_wakes() {
  fixture fresh captain-hold-other-1
  assert_loud "hold not in export" captain-hold-other-1
  fixture fresh captain-hold-pick-2
  assert_loud "older occurrence" captain-hold-pick-2
  pass "a relay of a hold the export does not show, or of another occurrence, wakes as before"
}

test_bridge_off_wakes() {
  local rc=0
  fixture fresh captain-hold-pick-1 off
  relay_shown >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "relay-shown with the Bridge off did not exit 1 (rc=$rc)"
  assert_loud "Bridge off" captain-hold-pick-1
  pass "with the Bridge off every relay wakes as before"
}

fm_test_run test_fresh_matching_export_is_quiet test_fresh_export_beside_a_loud_line_still_wakes \
  test_missing_export_wakes test_stale_export_wakes test_invalid_export_wakes \
  test_hold_not_shown_wakes test_bridge_off_wakes
