#!/usr/bin/env bash
# Shared helpers for the live-board live validation run. Sourced by each step.
# Every product command runs from the gate worktree against a disposable lab
# home minted by bin/fm-lab-home.sh; nothing here touches the operator's home.
EV=/home/daan/.no-mistakes/evidence/01M4NCAQMTQ69MVF3NSZGTQM50
ROOT=/home/daan/.no-mistakes/worktrees/cf62ac6bfd91/01M4NCAQMTQ69MVF3NSZGTQM50
[ ! -f "$EV/lab-paths" ] || . "$EV/lab-paths"

# Run one product command against a lab home, with no inherited fleet paths.
fm() {  # <home> <command...>
  local home=$1
  shift
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u TMUX FM_HOME="$home" TMUX_TMPDIR="$TMUXDIR" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" LAVISH_AXI_NO_OPEN=1 "$@"
}

# Give a task a worker whose own busy-state record says it is working now.
worker() {  # <home> <id>
  local home=$1 id=$2 gen
  mkdir -p "$home/projects/wt-$id"
  printf '%s\n' 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" "worktree=$home/projects/wt-$id" \
    > "$home/state/$id.meta"
  gen=$(fm "$home" "$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  fm "$home" "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

render() { node "$ROOT/tests/assets/live-board-render-harness.mjs" "$LAB/data/live-board/board.html" "$@"; }
