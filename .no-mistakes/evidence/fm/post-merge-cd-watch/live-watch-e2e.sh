#!/usr/bin/env bash
# Live E2E: record a real GitHub merge outcome in a throwaway FM_HOME, then run
# the real bin/fm-watch.sh with the real gh CLI and show the wake it produced.
#   live-watch-e2e.sh <worktree-root> <task-id> <real-pr-url> [<task-id> <pr-url>...]
set -u
ROOT=$1; shift
home=$(mktemp -d /tmp/fm-deploy-live.XXXXXX)
state="$home/state"
mkdir -p "$state" "$home/data" "$home/config"
while [ "$#" -ge 2 ]; do
  id=$1 url=$2; shift 2
  ( . "$ROOT/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$home" "$state" "$id" "$url" self attended ) \
    || echo "record failed for $id rc=$?"
  echo "armed $state/$id.deploy-watch mode $(stat -c %a "$state/$id.deploy-watch" 2>/dev/null):"
  sed 's/^/    /' "$state/$id.deploy-watch" 2>/dev/null || echo "    (not armed)"
done
echo "--- draining and acking the merge-landed wake so the watcher reaches its check sweep"
err="$home/drain.err"
FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" 2> "$err"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p' "$err")
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
rm -f "$state/.watcher-down"
echo "--- running real fm-watch.sh (real gh on PATH)"
timeout 120 env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=60 \
  FM_POLL=0.2 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err"
echo "watcher exit $?"
echo "--- watcher stdout"; cat "$home/watch.out"
echo "--- deploy wake rows in .wake-queue"
awk -F'\t' 'index($5, " deploy ") > 0 { print $5 }' "$state/.wake-queue" 2>/dev/null
echo "--- remaining deploy watches"; ls "$state"/*.deploy-watch 2>/dev/null || echo "(none, all retired)"
echo "--- triage log deploy lines"; grep -h deploy "$state"/*triage* "$home"/*/*triage* 2>/dev/null | head
echo "$home" > /tmp/fm-deploy-live.last
