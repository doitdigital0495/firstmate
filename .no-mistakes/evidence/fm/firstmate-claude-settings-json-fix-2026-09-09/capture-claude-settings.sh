#!/usr/bin/env bash
# Evidence capture: run the real bin/fm-spawn.sh claude launch path (crewmate ship
# launch + secondmate launch) and copy out the per-task settings file claude reads,
# for both the pre-fix and post-fix spawn script.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../../worktrees/cf62ac6bfd91/01M23NX0Q7M15D9FNGA8G77BY1/tests/lib.sh"

OUT=$(dirname "${BASH_SOURCE[0]}")
SPAWN=${SPAWN_OVERRIDE:-$ROOT/bin/fm-spawn.sh}
TAG=${TAG:-post-fix}
TMP_ROOT=$(fm_test_tmproot fm-evidence-settings)

make_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 fakebin=$2 pane=$3
  shift 3
  mkdir -p "$home/user-home"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" >/dev/null 2>&1 || true
}

new_home() {
  local home=$1
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
}

CREW="$TMP_ROOT/crew"
new_home "$CREW/home"
fm_git_worktree "$CREW/project" "$CREW/wt" wt-crew
CREW_FAKE=$(make_fakebin "$CREW/fake")
mkdir -p "$CREW/home/data/evidence-crew"
cat > "$CREW/home/data/evidence-crew/brief.md" <<'EOF'
# Task
## Captain's intent
Capture the generated claude settings file.

## Firstmate spec
Nothing to build; the launch itself is the subject.
EOF
run_spawn "$CREW/home" "$CREW_FAKE" "$CREW/wt" evidence-crew "$CREW/project" --mode no-mistakes --yolo off
cp "$CREW/home/state/evidence-crew.claude-settings.json" "$OUT/crewmate-$TAG.claude-settings.json" 2>/dev/null

# Run the hook commands claude would run, straight out of the generated file, and
# show the busy-state record the fleet watcher reads flipping busy -> idle.
CREW_STATE="$CREW/home/state"
{
  echo "== busy-state record right after launch =="
  cat "$CREW_STATE/evidence-crew.busy-state" 2>/dev/null || echo "(none)"
  for EV in UserPromptSubmit Stop; do
    CMD=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["hooks"][sys.argv[2]][0]["hooks"][0]["command"])' \
      "$CREW/home/state/evidence-crew.claude-settings.json" "$EV")
    echo
    echo "== running the $EV hook claude was handed =="
    bash -c "$CMD"
    echo "busy-state: $(cat "$CREW_STATE/evidence-crew.busy-state" 2>/dev/null || echo '(none)')"
    echo "turn-ended marker present: $([ -f "$CREW_STATE/evidence-crew.turn-ended" ] && echo yes || echo no)"
  done
} > "$OUT/crewmate-hooks-run.log" 2>&1

SM="$TMP_ROOT/sm"
new_home "$SM/home"
SM_FAKE=$(make_fakebin "$SM/fake")
SM_HOME="$SM/secondmate"
mkdir -p "$SM_HOME/bin" "$SM_HOME/data"
printf '# Firstmate\n' > "$SM_HOME/AGENTS.md"
printf 'evidence-sm\n' > "$SM_HOME/.fm-secondmate-home"
printf 'charter\n' > "$SM_HOME/data/charter.md"
mkdir -p "$SM/home/data/evidence-sm"
printf 'charter brief\n' > "$SM/home/data/evidence-sm/brief.md"
run_spawn "$SM/home" "$SM_FAKE" "$SM_HOME" evidence-sm "$SM_HOME" --secondmate
cp "$SM/home/state/evidence-sm.claude-settings.json" "$OUT/secondmate-$TAG.claude-settings.json" 2>/dev/null

echo "captured $TAG"
