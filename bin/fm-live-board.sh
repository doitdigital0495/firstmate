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
# injected payload {refresh_seconds, board}, where board is exactly one
# `fm-live-board-snapshot.sh --json` document (schema fm-live-board.v1). The
# snapshot owns every fact and ordering on the page; this script reads no other
# home state and the page computes nothing beyond display and local freshness.
#
# build    Collect one snapshot, bounded by FM_LIVE_BOARD_TIMEOUT seconds
#          (default 45), inject it, and atomically replace the stable board
#          file. A failed or timed-out build leaves the previous board intact.
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
# ANSWERS. A question card is answerable only when the snapshot marks it
# answerable with owner-authored context (bin/fm-captain-hold.sh owns that
# contract). Its Queue answer control emits one Lavish `choice` carrying
# fm-bearings-answer.v1 context with the task id, selection, note, the owner's
# close mode and lifecycle. bin/fm-procevent-lavish.sh relays those to
# `fm-captain-hold.sh answers`, whose lifecycle guard refuses an answer queued
# for an earlier hold. The page never calls a command or invents options.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/live-board.json"
TEMPLATE="$SCRIPT_DIR/fm-live-board-template.html"
PLACEHOLDER='__FM_LIVE_BOARD_DATA__'
BUILD_TIMEOUT=${FM_LIVE_BOARD_TIMEOUT:-45}
REFRESH_LOCK="$STATE/.live-board-refresh.lock"
REFRESH_LOG="$STATE/.live-board-refresh.log"
REFRESH_LOG_MAX_BYTES=65536

case "$BUILD_TIMEOUT" in
  ''|*[!0-9]*|0) BUILD_TIMEOUT=45 ;;
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

build_board() {  # <refresh-seconds>
  local refresh=$1 board tmp snap json extracted
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
  if ! fm_run_timed "$BUILD_TIMEOUT" "$SCRIPT_DIR/fm-live-board-snapshot.sh" --json > "$snap"; then
    fail "the live-board snapshot failed or exceeded ${BUILD_TIMEOUT}s; the previous board is unchanged"
  fi
  json=$(jq -c --argjson refresh "$refresh" '
    if .schema == "fm-live-board.v1" and (.projects | type == "array")
    then {refresh_seconds:$refresh, board:.} else error("not fm-live-board.v1") end' "$snap" 2>/dev/null) \
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
  printf '%s\n' "$extracted" | jq -e '.board.schema == "fm-live-board.v1"' >/dev/null 2>&1 \
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
  if ! err=$(build_board "$refresh" 2>&1 >/dev/null); then
    refresh_log "$(printf '%s' "$err" | tail -n 1 | tr '\t\r\n' '   ' | cut -c1-500)"
  fi
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
