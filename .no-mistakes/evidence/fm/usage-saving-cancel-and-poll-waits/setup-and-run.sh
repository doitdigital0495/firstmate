#!/usr/bin/env bash
# Stand up a disposable lab (marked primary home, seeded secondmate home, private
# tmux server), run drive-wait-no-turns.sh inside a lab pane, tear everything down.
# Usage: setup-and-run.sh <worktree> <evidence-dir> <label> [<base-commit>]
# With <base-commit> the code under test is an exported copy of that commit.
set -u
WT=$1 EV=$2 LABEL=$3 BASE=${4:-}
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-wnt.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
ID="labsm$LABEL"
SM="$SCRATCH/$ID"
SESSION="wntlab$LABEL"
OUT="$EV/transcript-$LABEL.txt"
tm() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
cleanup() { tm kill-server 2>/dev/null; rm -rf "$LAB" "$SCRATCH"; }
trap cleanup EXIT

if [ -n "$BASE" ]; then
  ROOT="$SCRATCH/base-root"
  git clone -q "$WT" "$ROOT" && git -C "$ROOT" checkout -q "$BASE" || exit 1
else
  ROOT="$WT"
fi
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"

# Secondmate home: a real checkout of the code under test, seeded like a home.
git clone -q "$ROOT" "$SM" || exit 1
git -C "$SM" checkout -q "$(git -C "$ROOT" rev-parse HEAD)"
mkdir -p "$SM/state" "$SM/data" "$SM/config" "$SM/projects"
printf '%s\n' "$ID" > "$SM/.fm-secondmate-home"
{
  printf 'window=%s:fm-%s\n' "$SESSION" "$ID"
  printf 'kind=secondmate\n'
  printf 'home=%s\n' "$SM"
} > "$LAB/state/$ID.meta"

rm -f "$OUT" "$SCRATCH/done"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_HOME -u TMUX \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 200 -y 50 -s "$SESSION" -n driver \
  -c "$ROOT" -e FM_HOME="$LAB" bash --norc
tm new-window -d -t "$SESSION" -n "fm-$ID" -c "$SM" -e FM_HOME="$SM" bash --norc
tm send-keys -t "$SESSION:driver" \
  "bash '$EV/drive-wait-no-turns.sh' '$ROOT' '$LAB' '$SM' '$ID' '$LABEL' > '$OUT' 2>&1; touch '$SCRATCH/done'" Enter
i=0
until [ -e "$SCRATCH/done" ] || [ "$i" -ge 180 ]; do sleep 1; i=$((i + 1)); done
[ -e "$SCRATCH/done" ] || echo "TIMEOUT waiting for the lab driver" >> "$OUT"
{
  printf '\n=== [%s] secondmate pane (fm-%s) as the doorbell left it ===\n' "$LABEL" "$ID"
  tm capture-pane -p -t "$SESSION:fm-$ID" | grep -v '^$'
} >> "$OUT"
# Paths are per-run temp dirs; normalise them so the transcript reads the same each run.
sed -i -e "s#$LAB#<PRIMARY_HOME>#g" -e "s#$SM#<SECONDMATE_HOME>#g" -e "s#$SCRATCH#<SCRATCH>#g" "$OUT"
