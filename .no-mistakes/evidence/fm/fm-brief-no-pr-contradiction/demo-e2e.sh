#!/usr/bin/env bash
# End-to-end demo of the ship-brief self-contradiction refusal, driven only
# through the public commands bin/fm-brief.sh and bin/fm-spawn.sh.
set -u
ROOT=$1
W=$(mktemp -d)
HOME_DIR="$W/home"; PROJ="$W/projects/proj"; FAKEBIN="$W/bin"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$PROJ" "$FAKEBIN"
# The backend a cleared spawn would reach; it announces itself and then refuses,
# so nothing is ever created and "launched" is visible in the transcript.
printf '#!/bin/sh\necho "[backend] tmux reached - delivery checks cleared" >&2\nexit 1\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"

scaffold() { # <id> <mode> <task>
  rm -rf "$HOME_DIR/data/$1"
  FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-brief.sh" "$1" proj --mode "$2" >/dev/null || exit 1
  awk -v repl="$3" '$0 == "{TASK}" { print repl; next } { print }' \
    "$HOME_DIR/data/$1/brief.md" > "$HOME_DIR/data/$1/b" && mv "$HOME_DIR/data/$1/b" "$HOME_DIR/data/$1/brief.md"
}
spawn() { # <id> <mode>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$W/unused" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" claude --mode "$2" --yolo off 2>&1
  echo "[exit $?]"
}

TASK='Rebuild the product sets import screen and verify it in the running preview at 390px.

- Do NOT push and do NOT open a PR. The captain approves that himself after his own QA.'

echo "=============================================================="
echo "1. The real 2026-08-22 incident (cosmic-sets-import), scaffolded"
echo "   --mode direct-PR, whose generated definition of done says:"
scaffold cosmic-sets-import direct-PR "$TASK"
sed -n '/^# Definition of done/,$p' "$HOME_DIR/data/cosmic-sets-import/brief.md" | sed -n '1,12p' | sed 's/^/   | /'
echo
echo "   ...while the task text the captain wrote says:"
sed -n '/^# Task/,/^# /p' "$HOME_DIR/data/cosmic-sets-import/brief.md" | sed -n '2,6p' | sed 's/^/   | /'
echo
echo "   $ fm-spawn.sh cosmic-sets-import <proj> claude --mode direct-PR --yolo off"
spawn cosmic-sets-import direct-PR | sed 's/^/   /'
echo "   metadata written? $( [ -e "$HOME_DIR/state/cosmic-sets-import.meta" ] && echo YES || echo 'no - nothing was created' )"
echo
echo "=============================================================="
echo "2. Same task text through the mode whose contract fits the stop point"
scaffold cosmic-sets-import-local local-only "$TASK"
echo "   $ fm-spawn.sh cosmic-sets-import-local <proj> claude --mode local-only --yolo off"
spawn cosmic-sets-import-local local-only | sed 's/^/   /'
echo
echo "=============================================================="
echo "3. Ordinary direct-PR work still launches (control: cosmic-hero-video,"
echo "   the 2026-08-22 incident that carried no prohibition)"
scaffold cosmic-hero-video direct-PR 'Re-encode the hero video to AV1 and check the LCP in the preview.

- If the re-encode misses the budget, fall back to option A and say so plainly in the PR body.'
echo "   $ fm-spawn.sh cosmic-hero-video <proj> claude --mode direct-PR --yolo off"
spawn cosmic-hero-video direct-PR | sed 's/^/   /'
echo
echo "=============================================================="
echo "4. Ordinary programming senses of push are NOT delivery refusals"
i=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  i=$((i+1))
  scaffold "prog-$i" direct-PR "Do the work.

$line"
  out=$(spawn "prog-$i" direct-PR)
  case "$out" in
    *"contradictory brief"*) verdict="REFUSED (false positive!)" ;;
    *"delivery checks cleared"*) verdict="launched" ;;
    *) verdict="?? $out" ;;
  esac
  printf '   %-8s %s\n' "$verdict" "$line"
done <<'ROWS'
- Do not push to the analytics queue on every keystroke.
- Never push to npm from CI.
- Do not push it to the array; use concat.
- Do not push this event to the dataLayer.
- Do not push and pop the same stack twice.
- Do not push anything to the CDN.
- Do not push until the animation finishes.
- No push notifications in this milestone; skip the service worker.
- Do not push secrets or .env files to the remote.
- Do not create a PR template file.
- Do not push until the tests are green, then open the PR as usual.
Do not open a PR against upstream; open it against the fork.
ROWS
echo
echo "=============================================================="
echo "5. Real delivery prohibitions still refuse"
i=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  i=$((i+1))
  scaffold "true-$i" direct-PR "Do the work.

$line"
  out=$(spawn "true-$i" direct-PR)
  case "$out" in
    *"contradictory brief"*) verdict="refused" ;;
    *"delivery checks cleared"*) verdict="LAUNCHED (miss!)" ;;
    *) verdict="?? $out" ;;
  esac
  printf '   %-15s %s\n' "$verdict" "$line"
done <<'ROWS'
- Do NOT push and do NOT open a PR. The captain approves that himself after his own QA.
- Do not push, do not open a PR. The captain approves after his own QA.
5. Commit the branch and stop. Do not invoke no-mistakes, push, or open a PR without captain approval.
- Never push this branch; leave the dev server running for the captain's QA.
- Never open a pull request; the captain reviews the running preview first.
- Do not push anything.
- No pushing and no PR until the captain approves.
- Do not push yet.
- No PR yet; the captain reviews first.
You cannot push until the captain signs off on the preview.
ROWS
rm -rf "$W"
