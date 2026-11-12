#!/usr/bin/env bash
# Page-host lifecycle requests, executed by firstmate, never by the watcher.
# Usage: fm-page-host.sh armed TASK | park TASK NOTES_FILE | resume TASK
# armed succeeds only for a live task-owned Lavish listener with no open round.
# park requires that listener to be reply-free for FM_PAGE_HOST_IDLE_SECONDS
# (default 7200; 0 disables), and nonempty durable page notes. It records the
# recovery pointer before fm-control.sh exit, preserving worktree and listener.
# resume uses fm-control.sh relaunch --note-file to start a fresh conversation.
# A failed control operation retains the pointer for explicit recovery/retry.
# FM_HOME / FM_STATE_OVERRIDE select the owning home's records as usual.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(dirname "$SCRIPT_DIR")}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
export FM_HOME FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
usage() {
  echo 'Usage: fm-page-host.sh armed TASK | park TASK NOTES_FILE | resume TASK'
  echo 'FM_PAGE_HOST_IDLE_SECONDS: reply-free seconds before park (default 7200; 0 disables).'
  echo 'NOTES_FILE must be an absolute, nonempty durable page-notes file.'
  echo 'park preserves worktree and listener; resume relaunches with the notes in a fresh conversation.'
}
case ${1:-} in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 2 ] || { usage >&2; exit 2; }
verb=$1 id=$2
fm_task_id_path_safe "$id" || exit 2
marker="$STATE/$id.page-host-parked"
[ ! -L "$marker" ] || { echo 'error: unsafe page-host pointer' >&2; exit 1; }
case "$verb" in
  armed|park)
    grep -l -Fx "owner_task=$id" "$STATE/procevent/"*.source >/dev/null 2>&1 || exit 1
    rows=$("$SCRIPT_DIR/fm-procevent.sh" list)
    # Any open/dead source belonging to this host prevents parking it.
    selected=$(printf '%s\n' "$rows" | awk -v t="task:$id/" 'index($3,t)==1 {print}')
    [ -n "$selected" ] || exit 1
    printf '%s\n' "$selected" | awk -v t="task:$id/listening" '
      $2 != "lavish" || $3 != t || $4 != 0 {bad=1} END {exit bad}' || exit 1
    [ "$verb" != armed ] || exit 0
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    notes=$3
    case "$notes" in /*) ;; *) echo 'error: notes must be an absolute path' >&2; exit 2 ;; esac
    case "$notes" in *$'\n'*) exit 2 ;; esac
    [ -f "$notes" ] && [ -s "$notes" ] && [ ! -L "$notes" ] || {
      echo 'error: preserve nonempty page notes before exiting the host' >&2; exit 1;
    }
    limit=$(fm_procevent_page_idle_seconds) || exit 2
    [ "$limit" -gt 0 ] || exit 1
    now=$(date +%s)
    # Every page must have passed the interval, so a freshly re-armed second
    # board cannot be interrupted by the oldest board's timeout.
    while read -r source _; do
      stamp=$(fm_path_mtime "$STATE/procevent/$source.source") || exit 1
      [ $((now - stamp)) -ge "$limit" ] || exit 1
    done <<< "$selected"
    tmp=$(umask 077; mktemp "$STATE/.page-host.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    printf '%s\n' "$notes" > "$tmp"
    mv -f -- "$tmp" "$marker"
    "$SCRIPT_DIR/fm-control.sh" "$id" exit
    printf 'page-host parked: %s\n' "$id"
    ;;
  resume)
    [ "$#" -eq 2 ] && [ -f "$marker" ] || exit 1
    IFS= read -r notes < "$marker"
    [ -f "$notes" ] && [ -s "$notes" ] && [ ! -L "$notes" ] || exit 1
    "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note-file "$notes"
    rm -f -- "$marker"
    printf 'page-host rehosted: %s\n' "$id"
    ;;
  *) usage >&2; exit 2 ;;
esac
