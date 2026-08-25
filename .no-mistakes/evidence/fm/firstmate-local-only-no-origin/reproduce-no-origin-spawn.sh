#!/usr/bin/env bash
# Manual end-user reproduction: a registered local-only project with no origin.
set -u
ROOT=$1
WORK=$(mktemp -d /tmp/fm-noorigin-demo.XXXXXX)
HOME_DIR="$WORK/home"; PROJECT="$WORK/project"; POOL="$WORK/pool"; FAKE="$WORK/fake"
ID=demo-local-only-task
mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$FAKE"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
printf 'demo brief\n' > "$HOME_DIR/data/$ID/brief.md"
touch "$HOME_DIR/state/.last-watcher-beat"
cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/treehouse"
chmod +x "$FAKE/tmux" "$FAKE/treehouse"
git init --quiet -b main "$PROJECT"
printf 'base\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name=Demo -c user.email=d@e.invalid commit -qm initial
BASE=$(git -C "$PROJECT" rev-parse HEAD)
git -C "$PROJECT" worktree add --quiet --detach "$POOL" "$BASE"
printf 'work landed after the pool worktree was allocated\n' > "$PROJECT/newer.txt"
git -C "$PROJECT" add newer.txt
git -C "$PROJECT" -c user.name=Demo -c user.email=d@e.invalid commit -qm advance-main
echo "\$ git -C project remote -v      # registered local-only, no remote at all"
git -C "$PROJECT" remote -v
echo "(no output: no origin configured)"
echo
echo "\$ fm-spawn.sh $ID <project> --mode local-only --yolo off"
FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 TMUX="fake,1,0" \
  FM_FAKE_PANE_PATH="$POOL" PATH="$FAKE:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --mode local-only --yolo off 2>&1 | sed "s#$WORK#<work>#g"
echo "exit=${PIPESTATUS[0]}"
echo
echo "\$ git -C pool log --oneline -1  # base the worker actually starts from"
git -C "$POOL" log --oneline -1
echo "\$ git -C project rev-parse main"; git -C "$PROJECT" rev-parse main
echo "\$ git -C pool rev-parse HEAD   "; git -C "$POOL" rev-parse HEAD
echo "\$ ls pool/newer.txt"; ls "$POOL/newer.txt" 2>&1 | sed "s#$WORK#<work>#g"
git -C "$PROJECT" worktree remove --force "$POOL" >/dev/null 2>&1
rm -rf "$WORK"
