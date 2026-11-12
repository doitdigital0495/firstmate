#!/usr/bin/env bash
# Worker compaction settings and compact-time task card (Claude task workers only).
# Usage: fm-worker-compact.sh --settings CONFIG STATE ID BRIEF SETTINGS_FILE
#        fm-worker-compact.sh --card STATE ID BRIEF
# config/worker-compaction: off (default), half (cksum task-id parity), all.
# Change the flag before spawning/relaunching workers; existing sessions are unchanged.
# --settings emits merged JSON, retaining every existing hook. Enabled workers get
# autoCompactWindow=300000 and a SessionStart compact hook. --card reads the native
# JSON payload on stdin, emits nothing for other sources, and caps stdout at 10000
# characters. Notes live beside the brief as notes.md; no transcript is replayed.
set -eu

case "${1:-}" in
  --help|-h)
    head -n 10 "${BASH_SOURCE[0]}"
    exit 0
    ;;
  --settings)
    config=$2 state=$3 id=$4 brief=$5 settings=$6
    mode=off
    if [ -f "$config/worker-compaction" ]; then
      mode=$(tr -d '[:space:]' < "$config/worker-compaction")
    fi
    case "$mode" in
      off|'') enabled=0 ;;
      all) enabled=1 ;;
      half)
        checksum=$(printf '%s' "$id" | cksum)
        enabled=$(( ${checksum%% *} % 2 ))
        ;;
      *) echo 'error: config/worker-compaction must be off, half, or all' >&2; exit 1 ;;
    esac
    if [ "$enabled" -eq 0 ]; then
      jq . "$settings"
      exit 0
    fi
    printf -v command 'bash %q --card %q %q %q' "${BASH_SOURCE[0]}" "$state" "$id" "$brief"
    jq --arg command "$command" '
      .autoCompactWindow = 300000
      | .hooks.SessionStart = ((.hooks.SessionStart // []) +
          [{matcher: "compact", hooks: [{type: "command", command: $command, timeout: 5}]}])
    ' "$settings"
    ;;
  --card)
    state=$2 id=$3 brief=$4
    source=$(jq -r '.source // ""' 2>/dev/null) || exit 0
    [ "$source" = compact ] || exit 0
    notes="$(dirname "$brief")/notes.md"
    # Byte-bounded reads also bound memory use. jq's final Unicode slice is the
    # single output ceiling, including labels and unexpectedly long paths.
    {
      printf 'Worker task card: %s\nStatus: %s/%s.status\nInbox: %s/%s.inbox\nNotes: %s\n' "$id" "$state" "$id" "$state" "$id" "$notes"
      printf '\nTask and goal (brief excerpt):\n'
      if [ -f "$brief" ] && [ ! -L "$brief" ]; then
        awk '/^# Task$/ {on=1; next} on && /^# / {exit} on {print}' "$brief" | head -c 3000
        printf '\nDone rule (brief excerpt):\n'
        awk '/^# Definition of done$/ {on=1; next} on && /^# / {exit} on {print}' "$brief" | head -c 2000
      fi
      printf '\nLast status lines:\n'
      if [ -f "$state/$id.status" ] && [ ! -L "$state/$id.status" ]; then
        tail -n 8 "$state/$id.status" | tail -c 1000
      fi
      printf '\nWorker notes:\n'
      if [ -f "$notes" ] && [ ! -L "$notes" ]; then head -c 3000 "$notes"; fi
      printf '\nContinue this task; consult the on-disk brief for the complete contract.\n'
    } | jq -Rrjs '.[0:10000]'
    ;;
  *) echo 'usage: fm-worker-compact.sh --help' >&2; exit 1 ;;
esac
