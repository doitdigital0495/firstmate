#!/usr/bin/env bash
# fm-reap.sh - close finished workers so no crewmate or scout outlives its task.
#
# Usage:
#   fm-reap.sh list    every recorded crewmate and scout with its reap verdict
#   fm-reap.sh check   the watcher check (state/reaper.check.sh): one line when
#                      the set of due workers or the last run's outcome changes
#   fm-reap.sh run     tear down every due worker now, printing closed/kept
#   fm-reap.sh arm     write state/reaper.check.sh and bind it with
#                      bin/fm-check-register.sh (bootstrap arms it every start)
#
# Due: a ship or scout task recorded in state/<id>.meta whose newest lifecycle
#   status (working, needs-decision, blocked, paused, done, failed) is done,
#   FM_REAP_DONE_SECS (default 7200) after that done line, or, while a Lavish
#   board is registered for the task (a state/procevent/*.source naming it as
#   owner_task), FM_REAP_BOARD_SECS (default 86400) after the later of that
#   line and the board's newest captured round. The done line's [at=<epoch>]
#   stamp is the clock; a line without one uses the status file's mtime.
#   Second mates are persistent homes and are never due; failed, blocked, and
#   waiting tasks are left for firstmate.
#
# Mode: config/reaper holds `shadow` (also when absent) or `enforce`.
#   shadow reports the due workers in one check line and closes nothing.
#   enforce starts `run` in the background and reports its outcome on the next
#   check. `run` calls bin/fm-teardown.sh <id> without --force, so a worker
#   whose work has not landed is kept, never discarded (AGENTS.md hard rule 3),
#   and a task the captain still holds keeps its backlog call; each kept
#   worker is named with teardown's own reason. FM_REAP_TEARDOWN replaces the
#   teardown command for tests only.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DONE_SECS=${FM_REAP_DONE_SECS:-7200}
BOARD_SECS=${FM_REAP_BOARD_SECS:-86400}
TEARDOWN=${FM_REAP_TEARDOWN:-$SCRIPT_DIR/fm-teardown.sh}

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
fail() { printf 'fm-reap: %s\n' "$1" >&2; exit 2; }
case "$DONE_SECS$BOARD_SECS" in *[!0-9]*) fail 'FM_REAP_DONE_SECS and FM_REAP_BOARD_SECS must be whole seconds' ;; esac

mode() {
  local m=shadow
  [ ! -f "$CONFIG/reaper" ] || read -r m < "$CONFIG/reaper" || true
  case "$m" in enforce) printf enforce ;; *) printf shadow ;; esac
}

meta_get() { awk -F= -v k="$2" '$1 == k { v = substr($0, length(k) + 2) } END { print v }' "$1" 2>/dev/null; }

# <status-file> -> "<state> <epoch>" of the newest lifecycle line, or nothing.
lifecycle() {
  [ -f "$1" ] || return 0
  awk -v mtime="$(stat -c %Y "$1" 2>/dev/null || printf 0)" '
    { s = $1; sub(/[^a-z-].*$/, "", s) }
    s == "working" || s == "needs-decision" || s == "blocked" || s == "paused" || s == "done" || s == "failed" {
      last = s; at = mtime
      if (match($0, /\[at=[0-9]+\]/)) at = substr($0, RSTART + 4, RLENGTH - 5)
    }
    END { if (last != "") print last, at }' "$1"
}

# <task-id> -> epoch of the newest captured board round, 0 when none; rc 1
# when no board is registered for the task.
board_last() {
  local id=$1 src base newest=0 f t found=1
  for src in "$STATE"/procevent/*.source; do
    [ -f "$src" ] || continue
    [ "$(meta_get "$src" owner_task)" = "$id" ] || continue
    found=0
    base=$(basename -- "$src" .source)
    for f in "$STATE/procevent-inbox/$base".*.result; do
      [ -f "$f" ] || continue
      t=$(stat -c %Y "$f" 2>/dev/null || printf 0)
      [ "$t" -le "$newest" ] || newest=$t
    done
  done
  printf '%s\n' "$newest"
  return "$found"
}

# One line per recorded crewmate/scout: <id> <verdict> <detail>.
verdicts() {
  local meta id kind lc state at now board last clock ttl age
  now=$(date +%s)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename -- "$meta" .meta)
    kind=$(meta_get "$meta" kind)
    case "${kind:-ship}" in ship | scout) ;; *) continue ;; esac
    lc=$(lifecycle "$STATE/$id.status")
    state=${lc%% *}
    at=${lc##* }
    if [ "$state" != "done" ]; then
      printf '%s active %s\n' "$id" "${state:-no-status}"
      continue
    fi
    clock=$at
    ttl=$DONE_SECS
    if last=$(board_last "$id"); then
      ttl=$BOARD_SECS
      [ "$last" -le "$clock" ] || clock=$last
      board=" board"
    else
      board=
    fi
    age=$(( now - clock ))
    if [ "$age" -ge "$ttl" ]; then
      printf '%s due done %sh ago%s\n' "$id" "$(( age / 3600 ))" "$board"
    else
      printf '%s waiting done %sm ago%s, closes in %sm\n' "$id" "$(( age / 60 ))" "$board" "$(( (ttl - age + 59) / 60 ))"
    fi
  done
}

cmd_run() {
  local lock="$STATE/.reaper-run.lock" id rest out
  mkdir "$lock" 2>/dev/null || { printf 'reap: a run is already in progress\n'; return 0; }
  # shellcheck disable=SC2064 # expand the lock path now
  trap "rmdir -- $(printf '%q' "$lock") 2>/dev/null" EXIT
  while read -r id rest; do
    case "$rest" in due*) ;; *) continue ;; esac
    if out=$(FM_HOME="$FM_HOME" "$TEARDOWN" "$id" < /dev/null 2>&1); then
      printf 'closed %s (%s)\n' "$id" "${rest#due }"
    else
      printf 'kept %s: %s\n' "$id" "$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-200)"
    fi
  done < <(verdicts)
}

cmd_check() {
  local due mark="$STATE/.reaper-due" log="$STATE/reaper-run.log" reported="$STATE/.reaper-reported" m
  m=$(mode)
  due=$(verdicts | awk '$2 == "due" { $2 = ""; sub(/  /, " "); print }' | LC_ALL=C sort)
  if [ "$m" = enforce ]; then
    if [ -f "$log" ] && [ "$log" -nt "$reported" ] && [ ! -d "$STATE/.reaper-run.lock" ]; then
      [ ! -s "$log" ] || printf 'reap: %s\n' "$(paste -sd';' "$log" | sed 's/;/; /g')"
      : > "$reported"
    fi
    if [ -n "$due" ] && [ ! -d "$STATE/.reaper-run.lock" ]; then
      ( setsid "$0" run > "$log" 2>&1 < /dev/null & ) 2>/dev/null
    fi
    return 0
  fi
  if [ "$due" != "$(cat "$mark" 2>/dev/null)" ]; then
    printf '%s\n' "$due" > "$mark"
    [ -z "$due" ] || printf 'reap (shadow, nothing closed): %s finished worker(s) past their close time: %s. Close each with bin/fm-teardown.sh <id>, or write enforce to config/reaper.\n' \
      "$(printf '%s\n' "$due" | wc -l)" "$(printf '%s\n' "$due" | paste -sd';' | sed 's/;/; /g')"
  fi
}

cmd_arm() {
  local staged
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  staged=$(umask 077; mktemp "$STATE/.reaper-check.XXXXXX") || fail 'could not stage the check'
  printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-reap.sh") check" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/reaper.check.sh" || fail 'could not write state/reaper.check.sh'
  "$SCRIPT_DIR/fm-check-register.sh" reaper
}

case "${1:-}" in
  list) verdicts ;;
  check) cmd_check ;;
  run) cmd_run ;;
  arm) cmd_arm ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
