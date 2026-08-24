#!/usr/bin/env bash
# (a) Counterfactual: the same brief on the base commit's fm-spawn.sh.
# (b) Recall on the live fleet: every real ship brief in ~/.firstmate/data driven
#     through fm-spawn.sh with the mode the brief itself records.
set -u
ROOT=$1; BASE=$2
W=$(mktemp -d)
HOME_DIR="$W/home"; PROJ="$W/projects/proj"; FAKEBIN="$W/bin"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$PROJ" "$FAKEBIN"
printf '#!/bin/sh\necho "[backend] tmux reached - delivery checks cleared" >&2\nexit 1\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"

spawn() { # <spawn-bin> <id> <mode>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$W/unused" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$1" "$2" "$PROJ" claude --mode "$3" --yolo off 2>&1
}

# --- (a) counterfactual --------------------------------------------------
cp -r "$ROOT/bin" "$W/basebin"
git -C "$ROOT" show "$BASE:bin/fm-spawn.sh" > "$W/basebin/fm-spawn.sh"
chmod +x "$W/basebin/fm-spawn.sh"
mkdir -p "$HOME_DIR/data/cosmic-sets-import"
FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-brief.sh" cosmic-sets-import proj --mode direct-PR >/dev/null
awk '$0 == "{TASK}" { print "Rebuild the product sets import screen and verify it in the running preview at 390px.\n\n- Do NOT push and do NOT open a PR. The captain approves that himself after his own QA."; next } { print }' \
  "$HOME_DIR/data/cosmic-sets-import/brief.md" > "$W/b" && mv "$W/b" "$HOME_DIR/data/cosmic-sets-import/brief.md"

echo "=============================================================="
echo "COUNTERFACTUAL - the identical contradictory brief, two fm-spawn.sh"
echo
echo "  base commit $BASE:"
spawn "$W/basebin/fm-spawn.sh" cosmic-sets-import direct-PR | sed 's/^/    /'
echo
echo "  this branch:"
spawn "$ROOT/bin/fm-spawn.sh" cosmic-sets-import direct-PR | sed 's/^/    /'

# --- (b) live-fleet recall ------------------------------------------------
echo
echo "=============================================================="
echo "LIVE FLEET RECALL - every real ship brief in ~/.firstmate/data,"
echo "driven through this branch's fm-spawn.sh with its own recorded mode"
echo
total=0; push=0; refused=0
for b in "$HOME/.firstmate"/data/*/brief.md; do
  id=$(basename "$(dirname "$b")")
  mode=$(sed -n 's/^Delivery contract: mode=//p' "$b" | head -n1)
  [ -n "$mode" ] || continue
  total=$((total+1))
  case "$mode" in no-mistakes|direct-PR) ;; *) continue ;; esac
  push=$((push+1))
  rm -rf "$HOME_DIR/data/live"; mkdir -p "$HOME_DIR/data/live"
  cp "$b" "$HOME_DIR/data/live/brief.md"
  out=$(spawn "$ROOT/bin/fm-spawn.sh" live "$mode")
  case "$out" in
    *"contradictory brief"*)
      refused=$((refused+1))
      printf '  REFUSED  %-34s mode=%-11s %s\n' "$id" "$mode" \
        "$(printf '%s\n' "$out" | sed -n 's/.*forbids it: //p' | cut -c1-90)" ;;
  esac
done
echo
echo "  ship briefs with a recorded contract : $total"
echo "  of those in a push mode              : $push"
echo "  refused as self-contradictory        : $refused"
rm -rf "$W"
