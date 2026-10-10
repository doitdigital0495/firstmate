#!/usr/bin/env bash
# fm-live-board.sh - build, refresh and open this home's live project board.
#
# Usage:
#   fm-live-board.sh build
#   fm-live-board.sh refresh
#   fm-live-board.sh open
#   fm-live-board.sh path
#
# The live board is a separate captain-facing browser page, never a Bearings
# mode: the shipped dark template (bin/fm-live-board-template.html) plus one
# injected payload {refresh_seconds, board, view}, where board is exactly one
# `fm-live-board-snapshot.sh --json` document (schema fm-live-board.v1) less its
# per-repository pull request lists, and view is the whole document's
# fm-live-board-view.v1 grouping into the captain's named projects (see
# PROJECTS), carrying the pull requests each project shows. The snapshot owns every fact; bin/fm-live-board-projects.jq owns
# the grouping, ordering and captain-facing wording; this script reads no other
# home state and the page computes nothing beyond display and local freshness.
#
# build    Refresh the pull request data when it is due (see TIMELINE), collect
#          one snapshot, bounded by FM_LIVE_BOARD_TIMEOUT seconds (default 45),
#          inject it, and atomically replace the stable board file. A failed or
#          timed-out build leaves the previous board intact.
#          Prints `board: <path>`. Starts no session and arms nothing.
# refresh  The periodic entry point bin/fm-watch.sh calls on every poll. When
#          the board is enabled (see CONFIG) and the board file is missing or
#          at least refresh_seconds old, run one build under a home-local
#          try-lock; otherwise do nothing. Failures are appended to the bounded
#          state/.live-board-refresh.log and never change the exit status, so
#          the watcher cannot be slowed or failed by board publication.
# open     Require an enabled config, build, then serve the board through
#          bin/fm-lavish-board-lib.sh, which proves the Lavish session live
#          before binding the source to the keyed-answer intake and arming it.
#          The browser opens unless the caller set LAVISH_AXI_NO_OPEN=1.
# path     Print the stable board path, $FM_HOME/data/live-board/board.html.
#
# CONFIG. The board is off unless config/live-board.json is a regular file
# containing exactly {"schema":"fm-live-board-config.v1","enabled":true} with
# an optional integer "refresh_seconds" from 15 to 3600 (default 60). Unknown
# keys, wrong types, or a symlinked file refuse rather than guess. Lavish live
# reload repaints an open page whenever the file changes, and the page itself
# marks data stale after max(150, 2.5 x refresh_seconds) seconds and out of
# date after twice that, so a stopped watcher is visible instead of silent.
#
# PROJECTS. config/live-board-projects.json is an optional, home-private map
# from the captain's own project names to the work that belongs to them:
#   {"schema":"fm-live-board-projects.v1","projects":[{"name":"Stock report",
#     "description":"...","match":[{"id":"stock-*"},{"repo":"claims"}]}]}
# name is required (nonblank, <=60 chars, unique), description optional
# (<=200 chars), and match holds 1-64 rules; a rule has an id pattern (task-id
# characters plus `*` as the only wildcard), a repo (the backlog repo, or the
# last part of a metadata project path), or both, and matches when every key
# it has matches. A task, question or recently finished row belongs to the
# first project, in file order, with a matching rule. Unmatched work, and all
# work when the file is absent, groups by repository instead. An unreadable or
# invalid map never fails the build: the page groups by repository and says
# the map needs fixing. Firstmate maintains the file; it is never tracked.
# The view leads with projects that have questions for the captain, then
# stuck, then work being done now, then other open work, in map order;
# projects with no question and no open work fold away. Worker status, titles
# and reasons drop links, paths, branches, run ids and task ids, so ids appear
# only in data attributes.
#
# LANES. Every open task sits in exactly one of three lanes per project, and
# `lb_lane` in bin/fm-live-board-projects.jq is the one rule that decides it:
#   Doing now     a worker is on the task and its current state is working.
#   Next          queued, not held and with no unfinished prerequisite - the
#                 same "ready queued (dispatchable now)" set session start
#                 lists - so a worker starts it without the captain.
#   Charted next  everything else, each card naming why it will not start or
#                 move on its own: waiting for the captain's answer, put off
#                 by the captain until a date, on another hold, waiting for
#                 other work, stuck, paused, finished but not yet wrapped up,
#                 an umbrella row, or a started task whose state is unreadable.
# A working worker wins over a hold or prerequisite on its task; a dated hold
# that is not the captain's lapses on its date, as the backlog treats it.
# Doing now lists every card; the other two show three and fold the rest.
#
# ANSWERS. A question card offers answer controls when the snapshot marks it
# answerable with owner-authored context (bin/fm-captain-hold.sh owns that
# contract, including the plain-language about and purpose, the question text
# and the per-option detail the card shows): the captain picks an option, may
# add a note, and its Queue answer control emits one Lavish `choice` carrying
# fm-bearings-answer.v1 context with the task id, selection, note, the owner's
# close mode and lifecycle. A captain hold with no owner context at all and an
# unambiguous identity gets a free-text answer box instead, emitting the same
# choice with an empty selection and no close mode or lifecycle, exactly as a
# Bearings free-form answer does. bin/fm-procevent-lavish.sh relays either to
# `fm-captain-hold.sh answers`, whose guards refuse an answer for a task that
# is no longer held and, for guarded cards, one queued for an earlier hold.
# Stale, malformed, duplicate or ambiguous calls stay read-only. The page never
# calls a command or invents options.
# A queued card shrinks to "Answer queued in Lavish" and its answer, and always
# keeps Change answer, which reopens it; a new answer is queued under the same
# Lavish question key, so it replaces an earlier one Lavish has not yet sent.
# Delivery is Lavish's alone: the Lavish panel's own Send sends what Lavish
# holds, and the page has no send control of its own. The page cannot see
# what Lavish holds or has sent, so it counts nothing and never marks a card
# sent. The shrunken state lives in a hidden field of the card's own form,
# which Lavish restores after each live reload, keyed to the hold's lifecycle
# so an answer to an earlier asking never shows on a later one.
# REMOVAL. An answered or otherwise closed call is no longer an open captain
# hold, so the next build has no card for it; work an answer released moves to
# its lane. A call the captain put off until a later day is not answered: it
# keeps its card, badged with that day, beside its Charted next row.
#
# TIMELINE. Each project shows its 15 newest pull requests as a strip, oldest
# on the left. Pointing at one, moving keyboard focus to it, or pressing it
# shows the same detail under the strip: the cleaned title, a plain summary of
# what changed when the description yields one, and whether its deploy runs
# succeeded; pressing pins that detail, with a link to the pull request on its
# forge, until it is pressed again or closed. The pin lives in a hidden field
# of the timeline that Lavish restores after each live reload, as a card's
# queued answer does, and it queues nothing. A failed deploy is marked by
# colour, shape and the word "failed", and counted in the project's heading.
# bin/fm-live-board-prs.sh reads the pull requests and runs, read-only, and
# its header owns what is read and what counts as a deploy run. build and
# refresh run it at most once per FM_LIVE_BOARD_PR_REFRESH seconds (default
# 600), bounded by FM_LIVE_BOARD_PR_TIMEOUT seconds (default 90), into the
# home-private data/live-board/prs.json, and hand that file to the snapshot;
# a failed or timed-out read keeps the previous file, is retried after the
# same interval, and never fails the build. The page says when the pull
# requests were last read, names a project whose read failed, and says so
# when nothing was read at all. A pull request belongs to the project its
# ship branch's task id or its repository matches, by the PROJECTS rules;
# bin/fm-live-board-snapshot.sh's header owns the fields and
# bin/fm-live-board-prs.jq the summary and deploy-outcome rules.
#
# CARDS. Each card reads top to bottom as its project, what it is about, what
# it is for, the question, then every option with what picking it does and the
# recommended one highlighted. A card whose context carries no about or no
# purpose - any call stored before that rule, and every call without context -
# shows "Needs a plain-language explanation" in their place, and the board
# notes count such cards, so a missing explanation is never silent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/live-board.json"
PROJECTS_FILE="$CONFIG/live-board-projects.json"
PROJECTS_MAX_BYTES=65536
TEMPLATE="$SCRIPT_DIR/fm-live-board-template.html"
PLACEHOLDER='__FM_LIVE_BOARD_DATA__'
BUILD_TIMEOUT=${FM_LIVE_BOARD_TIMEOUT:-45}
PR_REFRESH=${FM_LIVE_BOARD_PR_REFRESH:-600}
PR_TIMEOUT=${FM_LIVE_BOARD_PR_TIMEOUT:-90}
REFRESH_LOCK="$STATE/.live-board-refresh.lock"
REFRESH_LOG="$STATE/.live-board-refresh.log"
REFRESH_LOG_MAX_BYTES=65536

case "$BUILD_TIMEOUT" in
  ''|*[!0-9]*|0) BUILD_TIMEOUT=45 ;;
esac
case "$PR_REFRESH" in
  ''|*[!0-9]*) PR_REFRESH=600 ;;
esac
case "$PR_TIMEOUT" in
  ''|*[!0-9]*|0) PR_TIMEOUT=90 ;;
esac

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-lavish-board-lib.sh
. "$SCRIPT_DIR/fm-lavish-board-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-live-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/live-board/board.html\n' "$DATA"; }

# Print the validated refresh interval, or fail naming why the board is off.
config_refresh_seconds() {
  [ -e "$CONFIG_FILE" ] || { echo "live board is off: $CONFIG_FILE does not exist" >&2; return 1; }
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] \
    || { echo "live board config is not a regular file: $CONFIG_FILE" >&2; return 1; }
  jq -er '
    if type == "object"
      and .schema == "fm-live-board-config.v1"
      and ((keys - ["schema","enabled","refresh_seconds"]) | length == 0)
      and (.enabled | type == "boolean")
      and ((has("refresh_seconds") | not)
        or (.refresh_seconds | type == "number" and . == floor and . >= 15 and . <= 3600))
    then (if .enabled then (.refresh_seconds // 60) else "disabled" end)
    else "invalid" end
  ' "$CONFIG_FILE" 2>/dev/null | {
    read -r value || value=invalid
    case "$value" in
      disabled) echo "live board is off: $CONFIG_FILE sets enabled to false" >&2; exit 1 ;;
      ''|*[!0-9]*) echo "live board config is invalid (expected fm-live-board-config.v1): $CONFIG_FILE" >&2; exit 1 ;;
    esac
    printf '%s\n' "$value"
  }
}

file_age() {  # <path>
  local mtime
  mtime=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || return 1
  printf '%s\n' "$(( $(date +%s) - mtime ))"
}

# Print the project map as one JSON value: null when absent, the parsed
# document when readable, or a string the projection reports as invalid.
project_map_json() {
  local size
  [ -e "$PROJECTS_FILE" ] || [ -L "$PROJECTS_FILE" ] || { printf 'null\n'; return 0; }
  if [ -f "$PROJECTS_FILE" ] && [ ! -L "$PROJECTS_FILE" ]; then
    size=$(LC_ALL=C wc -c < "$PROJECTS_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) size=$((PROJECTS_MAX_BYTES + 1)) ;; esac
    if [ "$size" -le "$PROJECTS_MAX_BYTES" ] \
      && jq -cs 'if length == 1 then .[0] else "unreadable" end' "$PROJECTS_FILE" 2>/dev/null; then
      return 0
    fi
  fi
  printf '"unreadable"\n'
}

# Refresh data/live-board/prs.json when the last attempt is PR_REFRESH seconds
# old. The attempt stamp, not the file, paces retries, so a forge that keeps
# failing is asked once per interval while the last good file stays in use.
refresh_prs() {  # <board-dir>
  local dir=$1 stamp="$1/.prs-attempt" out="$1/prs.json" staged age
  if age=$(file_age "$stamp"); then
    [ "$age" -ge "$PR_REFRESH" ] || return 0
  fi
  : > "$stamp" 2>/dev/null || return 0
  staged=$(umask 077; mktemp "$dir/.prs.XXXXXX") || return 0
  if fm_run_timed "$PR_TIMEOUT" "$SCRIPT_DIR/fm-live-board-prs.sh" --json > "$staged" 2>/dev/null \
    && jq -e '.schema == "fm-live-board-prs.v1"' "$staged" >/dev/null 2>&1 \
    && chmod 0600 "$staged" && mv -f -- "$staged" "$out"; then
    return 0
  fi
  rm -f -- "$staged"
  echo "fm-live-board: the pull request read failed or exceeded ${PR_TIMEOUT}s; the timelines keep their previous data" >&2
}

build_board() {  # <refresh-seconds>
  local refresh=$1 board tmp snap json extracted map
  local -a prs=()
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  snap=$(umask 077; mktemp "${board%/*}/.snapshot.XXXXXX") || fail "cannot stage the snapshot"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || { rm -f -- "$snap"; fail "cannot stage the board"; }
  # shellcheck disable=SC2064 # Expand the staged paths now; they are fixed.
  trap "rm -f -- '$snap' '$tmp'" EXIT
  refresh_prs "${board%/*}"
  [ ! -f "${board%/*}/prs.json" ] || [ -L "${board%/*}/prs.json" ] || prs=(--prs "${board%/*}/prs.json")
  if ! fm_run_timed "$BUILD_TIMEOUT" "$SCRIPT_DIR/fm-live-board-snapshot.sh" --json ${prs[@]+"${prs[@]}"} > "$snap"; then
    fail "the live-board snapshot failed or exceeded ${BUILD_TIMEOUT}s; the previous board is unchanged"
  fi
  map=$(project_map_json)
  json=$(jq -c -L "$SCRIPT_DIR" --argjson refresh "$refresh" --argjson map "$map" '
    include "fm-live-board-projects";
    if .schema == "fm-live-board.v1" and (.projects | type == "array")
    then {refresh_seconds:$refresh, view:lb_view($map),
      board:(if (.pull_requests.repos | type) == "array" then .pull_requests.repos |= map(del(.prs)) else . end)}
    else error("not fm-live-board.v1") end' "$snap" 2>/dev/null) \
    || fail "the snapshot is not a readable fm-live-board.v1 document"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}
  printf '%s' "$json" > "$snap" || fail "cannot stage the board data"
  if ! BOARD_DATA="$snap" perl -pe "BEGIN { local \$/; open my \$f, '<', \$ENV{BOARD_DATA} or die; \$data = <\$f>; close \$f }
    s/^\\Q$PLACEHOLDER\\E\$/\$data/" "$TEMPLATE" > "$tmp"; then
    fail "cannot inject the board data"
  fi
  grep -qxF "$PLACEHOLDER" "$tmp" && fail "the board data slot survived injection"
  # Round-trip the payload out of the built page so a page the browser could
  # not parse fails here instead.
  extracted=$(sed -n '/<script id="live-board-data" type="application\/json">/,/<\/script>/p' "$tmp" | sed '1d;$d')
  printf '%s\n' "$extracted" | jq -e '.board.schema == "fm-live-board.v1" and .view.schema == "fm-live-board-view.v1"' >/dev/null 2>&1 \
    || fail "the built board does not carry a readable fm-live-board.v1 payload"
  { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; } || fail "cannot publish the board"
  rm -f -- "$snap"
  trap - EXIT
  printf 'board: %s\n' "$board"
}

command_build() {
  local refresh
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  refresh=$(config_refresh_seconds 2>/dev/null) || refresh=60
  build_board "$refresh"
}

refresh_log() {  # <message>
  local size
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$REFRESH_LOG" 2>/dev/null || return 0
  size=$(wc -c < "$REFRESH_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge "$REFRESH_LOG_MAX_BYTES" ]; then
    tail -n 200 "$REFRESH_LOG" > "$REFRESH_LOG.tmp" 2>/dev/null \
      && mv -f -- "$REFRESH_LOG.tmp" "$REFRESH_LOG" 2>/dev/null
    rm -f -- "$REFRESH_LOG.tmp" 2>/dev/null || true
  fi
}

command_refresh() {
  local refresh age err
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -e "$CONFIG_FILE" ] || return 0
  if ! refresh=$(config_refresh_seconds 2>&1); then
    case "$refresh" in
      *"enabled to false"*) return 0 ;;
    esac
    refresh_log "$refresh"
    return 0
  fi
  if age=$(file_age "$(board_path)"); then
    [ "$age" -ge "$refresh" ] || return 0
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  mkdir -p "$STATE" 2>/dev/null || return 0
  fm_lock_try_acquire "$REFRESH_LOCK" || return 0
  # A build that published may still have warned that the pull request read failed.
  err=$(build_board "$refresh" 2>&1 >/dev/null) || [ -n "$err" ] || err='the board build failed'
  [ -z "$err" ] || refresh_log "$(printf '%s' "$err" | tail -n 1 | tr '\t\r\n' '   ' | cut -c1-500)"
  fm_lock_release "$REFRESH_LOCK" || true
  return 0
}

command_open() {
  local refresh
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  refresh=$(config_refresh_seconds) || exit 1
  build_board "$refresh"
  fm_lavish_board_serve "$(board_path)"
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  refresh) shift; (command_refresh "$@") || true ;;
  open) shift; command_open "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
