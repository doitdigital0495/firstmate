#!/usr/bin/env bash
# usage: drive-ado-close.sh <repo-root> <label>
ROOT=$1; LABEL=$2
H=$(mktemp -d)/home; mkdir -p "$H/state" "$H/data" "$H/config"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$H/data/backlog.md"
printf 'tasks-axi\n' > "$H/config/backlog-backend" 2>/dev/null
id=ado-demo; url=https://dev.azure.com/Org/Project/_git/Repo/pullrequest/801
tasks-axi add $id "ADO demo" --kind ship --file "$H/data/backlog.md" >/dev/null
tasks-axi start $id --file "$H/data/backlog.md" >/dev/null
echo "== [$LABEL] teardown close transition: marker write + replay (--pr $url)"
( cd "$H" && FM_HOME="$H" bash -c '
  . "$1/bin/fm-tasks-axi-lib.sh"; . "$1/bin/fm-backlog-transition-lib.sh"
  fm_backlog_close_marker_write "$2/state" "$3" "$2/data" spawn-1 --pr "$4" \
    && fm_backlog_close_marker_replay "$2/state" "$2/state/$3.backlog-close" "$2/data"
  echo "exit=$? error=${FM_BACKLOG_TRANSITION_ERROR:-none}"' _ "$ROOT" "$H" $id "$url" 2>&1 )
echo "== pending marker present?"; ls "$H/state/$id.backlog-close" 2>/dev/null || echo "no (retired)"
echo "== tasks-axi show $id"; tasks-axi show $id --file "$H/data/backlog.md" 2>&1
