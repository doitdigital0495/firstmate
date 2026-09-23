#!/usr/bin/env bash
# Live adversarial scenarios for the Pi Herdr sidebar change, on an isolated lab.
# A: a Pi task worker whose launch fails must end "blocked", not stuck "working".
# B: an interactive (Codex-path, --tui-mode regular) REAL Pi worker that finishes
#    its turn and stays open must flip to "idle" via the task extension, while
#    the Pi process is still running.
set -u
ROOT=${ROOT:?}
# Same scratch-sandbox harness contract as the repo's own live tests.
. "$ROOT/tests/lib.sh"
LAB="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB" name fm-pi-adv)
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-adv.XXXXXX")
WTS=()
cleanup() {
  for w in "${WTS[@]}"; do treehouse return --force "$w" >/dev/null 2>&1; done
  "$LAB" teardown "$SESSION"
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
"$LAB" provision "$SESSION" || { echo "provision failed"; exit 1; }
lab() { "$LAB" run "$SESSION" "$@"; }
REALPI=$(command -v pi)

PROJ="$SCRATCH/project"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; echo x > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
HOME_DIR="$SCRATCH/fm-home"; mkdir -p "$HOME_DIR"/{state,config,projects,data}
echo off > "$HOME_DIR/config/herdr-presentation-spaces"

spawn() { # <id> <fakebin> <model> <effort>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nSay hi.\n\n## Firstmate spec\nReply "hi" only.\n' > "$HOME_DIR/data/$1/brief.md"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH PATH="$2:$PATH" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" --harness pi --model "$3" --effort "$4" \
    --mode no-mistakes --yolo off --backend herdr >"$SCRATCH/$1.out" 2>"$SCRATCH/$1.err" \
    || { echo "spawn $1 failed"; tail -20 "$SCRATCH/$1.err"; return 1; }
  PANE=$(grep '^herdr_pane_id=' "$HOME_DIR/state/$1.meta" | cut -d= -f2-)
  WTS+=("$(grep '^worktree=' "$HOME_DIR/state/$1.meta" | cut -d= -f2-)")
}
status() { lab agent get "$PANE" 2>/dev/null | jq -c '.result.agent | {agent, agent_status}' 2>/dev/null; }
waitfor() { local i=0; while [ $i -lt 120 ]; do [ "$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" = "$1" ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }

echo "=== Scenario A: failing zai Pi launch ends blocked ==="
FB1="$SCRATCH/fb-fail"; mkdir -p "$FB1"
cat > "$FB1/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --help ] && { printf '%s\n' 'Pi 0.86.1 (fake)' 'Options: --help --tui-mode <mode>'; exit 0; }
sleep 6; exit 3
SH
chmod +x "$FB1/pi"
spawn fail-e2e "$FB1" zai/glm-5.3 high || exit 1
waitfor working && echo "A pane $PANE while running: $(status)" || echo "A FAIL: never working: $(status)"
waitfor blocked && echo "A pane $PANE after rc=3 exit: $(status)" || echo "A FAIL: not blocked: $(status)"
lab agent list 2>/dev/null | jq -c --arg p "$PANE" '[.. | objects | select(.pane_id? == $p) | {pane_id, agent, agent_status}] | unique' 2>/dev/null

echo "=== Scenario B: interactive real Pi worker goes idle while still open ==="
FB2="$SCRATCH/fb-real"; mkdir -p "$FB2"
# Real pi, real task extension and TUI; only the provider is swapped to an
# unauthenticated one so the turn errors out instantly and spends no tokens.
cat > "$FB2/pi" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --help ] && exec "$REALPI" --help
args=(); skip=0
for a in "\$@"; do
  if [ \$skip = 1 ]; then skip=0; continue; fi
  case "\$a" in --provider|--model|--thinking) skip=1; continue;; esac
  args+=("\$a")
done
exec "$REALPI" "\${args[@]}" --provider openai --model gpt-4o-mini --api-key sk-fm-test-invalid
SH
chmod +x "$FB2/pi"
spawn codex-live-e2e "$FB2" openai-codex/gpt-5.6-sol medium || exit 1
echo "B launch: $(grep -o -- '--tui-mode [a-z]*' "$HOME_DIR/state/codex-live-e2e.meta" "$SCRATCH/codex-live-e2e.out" 2>/dev/null | head -1)"
waitfor working && echo "B pane $PANE start: $(status)" || echo "B FAIL: never working: $(status)"
waitfor idle && echo "B pane $PANE after turn settled: $(status)" || echo "B FAIL: stayed $(status)"
sleep 3
echo "B status 3s later: $(status)"
echo "B pi still running in pane (process list):"
lab pane get "$PANE" 2>/dev/null | jq -c '.result' 2>/dev/null | head -c 600; echo
pgrep -af "sk-fm-test-invalid" | grep -v pgrep | head -2 | cut -c1-160
echo "--- B pane screen ---"
lab pane read "$PANE" 2>/dev/null | tail -25
