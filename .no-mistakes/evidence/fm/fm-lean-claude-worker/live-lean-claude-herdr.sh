#!/usr/bin/env bash
# Live evidence: real bin/fm-spawn.sh launches REAL Claude Code task workers in an
# isolated fm-lab-* Herdr session. Measures first-turn context for a baseline
# (base commit fm-spawn) vs the lean ship, and proves the lean scout gets only
# Read/Bash plus the requested skill content.
set -u
ROOT=${ROOT:?}
BASE_REV=${BASE_REV:?}
EV=${EV:?}
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
# Same test-harness escape hatch tests/lib.sh exports for throwaway-home spawns.
export FM_GATE_REFUSE_BYPASS=1
SESSION=$("$LAB_HELPER" name fm-lean-claude)
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-lean-claude-live.XXXXXX")
WTS=()
cleanup() {
  for w in "${WTS[@]+"${WTS[@]}"}"; do treehouse return --force "$w" >/dev/null 2>&1; done
  "$LAB_HELPER" teardown "$SESSION"; echo "teardown rc=$?"
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION" || { echo "provision failed"; exit 1; }
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

mkdir -p "$SCRATCH/base"
git -C "$ROOT" archive "$BASE_REV" | tar -x -C "$SCRATCH/base"

mkproj() { # <dir>
  mkdir -p "$1"; git -C "$1" init -q
  printf '# scratch\n' > "$1/README.md"; git -C "$1" add README.md
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  git clone -q --bare "$1" "$1.origin.git"; git -C "$1" remote add origin "file://$1.origin.git"
}
HOME_DIR="$SCRATCH/fm-home"
mkdir -p "$HOME_DIR"/{state,config,projects,data}
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
mkdir -p "$SCRATCH/skills/codeword"
printf '%s\n' '---' 'name: codeword' 'description: task codeword' '---' 'The task codeword is PELICAN-7342.' > "$SCRATCH/skills/codeword/SKILL.md"

brief() { # <id> <spec>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# Task\n## Captain'\''s intent\nLive lean-worker check.\n\n## Firstmate spec\n%s\n' "$2" > "$HOME_DIR/data/$1/brief.md"
}

spawn() { # <root> <id> <proj> args...
  local root=$1 id=$2 proj=$3; shift 3
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$root" \
    "$root/bin/fm-spawn.sh" "$id" "$proj" --harness claude --backend herdr "$@" \
    > "$SCRATCH/$id.out" 2> "$SCRATCH/$id.err"
  local rc=$?
  echo "spawn $id rc=$rc: $(cat "$SCRATCH/$id.out")"
  [ "$rc" -eq 0 ] || tail -20 "$SCRATCH/$id.err"
  local wt; wt=$(grep '^worktree=' "$HOME_DIR/state/$id.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WTS+=("$wt")
  return "$rc"
}

wait_turn() { # <id>
  local id=$1 pane i
  [ -e "$HOME_DIR/state/$id.meta" ] || { echo "$id: no meta, skipped"; return; }
  pane=$(grep '^herdr_pane_id=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
  for i in $(seq 1 120); do
    [ -e "$HOME_DIR/state/$id.turn-ended" ] && break
    sleep 2
  done
  [ -e "$HOME_DIR/state/$id.turn-ended" ] && echo "$id turn-ended: yes" || echo "$id turn-ended: NO (timeout)"
  lab pane read "$pane" > "$EV/$id.pane.txt" 2>&1
  echo "--- $id launch command (meta/launch record) ---"
  grep -E '^(harness|kind|model|effort)=' "$HOME_DIR/state/$id.meta"
}

usage() { # <id>
  local wt slug f
  [ -e "$HOME_DIR/state/$1.meta" ] || return
  wt=$(grep '^worktree=' "$HOME_DIR/state/$1.meta" | cut -d= -f2-)
  slug=$(printf '%s' "$wt" | sed 's#[^A-Za-z0-9]#-#g')
  f=$(ls -t "$HOME/.claude/projects/$slug"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "$1: no transcript for $slug"; return; }
  jq -c 'select(.type=="assistant") | .message.usage | {input_tokens, cache_creation_input_tokens, cache_read_input_tokens}' "$f" | head -1 \
    | jq -r --arg id "$1" '"\($id) first-turn usage: input=\(.input_tokens) cache_creation=\(.cache_creation_input_tokens) cache_read=\(.cache_read_input_tokens) total=\(.input_tokens+.cache_creation_input_tokens+.cache_read_input_tokens)"'
  echo "$1 final assistant text: $(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$f" | tail -3 | tr '\n' ' ')"
}

mkproj "$SCRATCH/proj-base"; mkproj "$SCRATCH/proj-ship"; mkproj "$SCRATCH/proj-scout"

brief lean-base "Reply with exactly MEASURED_READY and nothing else. Do not use any tools."
brief lean-ship "Reply with exactly MEASURED_READY and nothing else. Do not use any tools."
brief lean-scout "Do not use any tools. Reply with one line: the task codeword from your requested skill, then the exact comma-separated names of every tool available to you, then the names of any MCP servers you can use (or NONE)."

spawn "$SCRATCH/base" lean-base "$SCRATCH/proj-base" --model opus --effort medium --mode direct-PR --yolo off
spawn "$ROOT" lean-ship "$SCRATCH/proj-ship" --mode direct-PR --yolo off
spawn "$ROOT" lean-scout "$SCRATCH/proj-scout" --scout --skill "$SCRATCH/skills/codeword"

for id in lean-base lean-ship lean-scout; do wait_turn "$id"; done
for id in lean-base lean-ship lean-scout; do usage "$id"; done
