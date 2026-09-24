#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh -> real claude 2.1.281 in an isolated fm-lab-* Herdr session.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
SESSION=$("$LAB_HELPER" name lean-claude)
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d /tmp/fm-lean-claude.XXXXXX)
export TREEHOUSE_ROOT="$SCRATCH/pool"
WTS=()
log() { printf '%s\n' "$*" | tee -a "$EV/transcript.log"; }
cleanup() {
  for wt in "${WTS[@]+"${WTS[@]}"}"; do treehouse return --force "$wt" >/dev/null 2>&1; done
  "$LAB_HELPER" teardown "$SESSION" 2>&1 | tee -a "$EV/transcript.log"
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
: > "$EV/transcript.log"
log "claude: $(claude --version)  herdr: $(herdr --version 2>&1 | head -1)  lab session: $SESSION"
"$LAB_HELPER" provision "$SESSION" >/dev/null || { log "provision failed"; exit 1; }
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

# Project with committed guard settings: a PreToolUse hook blocking any Bash command
# containing FORBIDDEN_PROBE, a deny rule on secret.txt, and a project Stop hook that must NOT run.
PROJ=$SCRATCH/project
mkdir -p "$PROJ/.claude"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
printf 'TOPSECRET_VALUE_7731\n' > "$PROJ/secret.txt"
cat > "$PROJ/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "jq -r .tool_input.command | grep -q FORBIDDEN_PROBE && { echo 'blocked by project guard' >&2; exit 2; }; exit 0"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "touch $SCRATCH/project-stop-ran"}]}]
  },
  "permissions": {"deny": ["Read(./secret.txt)", "Bash(cat:*)"]}
}
EOF
git -C "$PROJ" add -A
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

HOME_DIR=$SCRATCH/fm-home
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/data"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

# Task MCP server (stdio) exposing ping -> MCP_PING_OK_4412
cat > "$SCRATCH/mcp.py" <<'PY'
import json, sys
for line in sys.stdin:
    m = json.loads(line)
    i = m.get("id"); meth = m.get("method")
    if i is None: continue
    if meth == "initialize":
        r = {"protocolVersion": m["params"].get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}}, "serverInfo": {"name": "task-marker", "version": "1"}}
    elif meth == "tools/list":
        r = {"tools": [{"name": "ping", "description": "Returns the task marker", "inputSchema": {"type": "object", "properties": {}}}]}
    elif meth == "tools/call":
        r = {"content": [{"type": "text", "text": "MCP_PING_OK_4412"}]}
    else:
        r = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": i, "result": r}) + "\n"); sys.stdout.flush()
PY
printf '{"mcpServers":{"task-marker":{"command":"python3","args":["%s"]}}}\n' "$SCRATCH/mcp.py" > "$SCRATCH/task-mcp.json"
mkdir -p "$SCRATCH/skill"
printf -- '---\nname: lean-probe\ndescription: probe\n---\nWhen asked for the skill marker, reply SKILL_MARKER_9051.\n' > "$SCRATCH/skill/SKILL.md"

spawn() { # <id> <brief> <args...>
  local id=$1 brief=$2; shift 2
  mkdir -p "$HOME_DIR/data/$id"
  printf '# Task\n## Captain'"'"'s intent\n%s\n\n## Firstmate spec\n%s\n' "$brief" "$brief" > "$HOME_DIR/data/$id/brief.md"
  log "\$ fm-spawn.sh $id <project> $*"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "$@" > "$SCRATCH/$id.out" 2> "$SCRATCH/$id.err"
  local rc=$?
  log "rc=$rc $(tail -1 "$SCRATCH/$id.out") $(tail -3 "$SCRATCH/$id.err")"
  local wt; wt=$(grep '^worktree=' "$HOME_DIR/state/$id.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WTS+=("$wt")
  return $rc
}
wait_turn() { # <id> <seconds>
  local id=$1 n=0
  while [ ! -e "$HOME_DIR/state/$id.turn-ended" ] && [ $n -lt "$2" ]; do sleep 2; n=$((n+2)); done
  [ -e "$HOME_DIR/state/$id.turn-ended" ]
}
record() { # <id>
  local id=$1 pane cmdline pid
  pane=$(grep '^herdr_pane_id=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
  log "--- $id meta: $(grep -E '^(harness|kind|model|effort)=' "$HOME_DIR/state/$id.meta" | tr '\n' ' ')"
  log "turn-ended: $([ -e "$HOME_DIR/state/$id.turn-ended" ] && echo exists || echo MISSING)"
  lab pane read "$pane" > "$EV/$id.pane.txt" 2>&1
  log "pane tail ($id):"; grep -v '^\s*$' "$EV/$id.pane.txt" | tail -25 | tee -a "$EV/transcript.log"
  # Live argv of the running claude process in that worktree.
  local wt; wt=$(grep '^worktree=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
  for pid in $(pgrep -x claude); do
    [ "$(readlink /proc/$pid/cwd)" = "$wt" ] || continue
    tr '\0' '\n' < /proc/$pid/cmdline | grep -v '^$' | awk 'length>200{ $0=substr($0,1,200)"...[truncated]" } {print}' > "$EV/$id.argv.txt"
  done
  log "argv ($id): $(grep -E '^--(tools|setting-sources|strict-mcp-config|disable-slash-commands|model|effort|mcp-config|settings)$' -A1 "$EV/$id.argv.txt" 2>/dev/null | tr '\n' ' ')"
  # First request token usage from the session transcript.
  local slug tx
  slug=$(printf '%s' "$wt" | sed 's#[/.]#-#g')
  tx=$(ls -t "$HOME/.claude/projects/$slug"/*.jsonl 2>/dev/null | head -1)
  [ -n "$tx" ] && log "first-turn usage ($id): $(jq -c 'select(.type=="assistant") | .message.usage | {input_tokens, cache_creation_input_tokens, cache_read_input_tokens, total: (.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens)}' "$tx" | head -1)"
}

# S1: ship, no model/effort -> opus/medium fallback, lean launch, marker reply.
spawn lean-ship "Reply with exactly LEAN_SHIP_READY and nothing else. Do not use tools." --harness claude --mode direct-PR --yolo off --backend herdr
wait_turn lean-ship 240 || log "lean-ship: no turn end in 240s"
record lean-ship

# S2: scout on haiku with task skill and task MCP.
spawn lean-haiku-mcp "1) Reply the skill marker from your requested skill. 2) Call the ping tool of the task-marker MCP server and quote its result. If the tool is not available yet, run 'sleep 8' with Bash and check again (up to 3 times)." --scout --harness claude --model haiku --effort low --backend herdr --skill "$SCRATCH/skill" --mcp-config "$SCRATCH/task-mcp.json"
wait_turn lean-haiku-mcp 300 || log "lean-haiku-mcp: no turn end in 300s"
record lean-haiku-mcp

# S3: ship on sonnet; adversarial guard probes.
spawn lean-guard "Do these three steps and report the literal outcome of each: (a) run the Bash command: echo FORBIDDEN_PROBE > probe.txt ; (b) use the Read tool on secret.txt ; (c) run the Bash command: cat secret.txt . Do not work around any block; just report BLOCKED or the output for each step." --harness claude --model sonnet --effort low --mode direct-PR --yolo off --backend herdr
wait_turn lean-guard 300 || log "lean-guard: no turn end in 300s"
record lean-guard
wt=$(grep '^worktree=' "$HOME_DIR/state/lean-guard.meta" | cut -d= -f2-)
log "probe.txt exists after guard run: $([ -e "$wt/probe.txt" ] && echo YES || echo no)"
log "project Stop hook ran (must be no): $([ -e "$SCRATCH/project-stop-ran" ] && echo YES || echo no)"
log "carried guard settings: $(jq -c '{pre: [.hooks.PreToolUse[]?.hooks[]?.command | select(test("FORBIDDEN_PROBE"))] | length, deny: .permissions.deny}' "$HOME_DIR/state/lean-guard.claude-settings.json")"

# S4: refusals (no pane created).
mkdir -p "$HOME_DIR/data/refuse-codex" "$HOME_DIR/data/refuse-path"
printf '# Task\n## Captain'"'"'s intent\nx\n## Firstmate spec\nx\n' | tee "$HOME_DIR/data/refuse-codex/brief.md" > "$HOME_DIR/data/refuse-path/brief.md"
spawn refuse-codex "x" --harness codex --backend herdr --mcp-config "$SCRATCH/task-mcp.json"
log "refuse-codex meta present: $([ -e "$HOME_DIR/state/refuse-codex.meta" ] && echo YES || echo no)"
spawn refuse-path "x" --harness claude --backend herdr --claude-add-dir "$SCRATCH/does-not-exist"
log "refuse-path meta present: $([ -e "$HOME_DIR/state/refuse-path.meta" ] && echo YES || echo no)"

for id in lean-ship lean-haiku-mcp lean-guard; do
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" "$id" --force >> "$EV/transcript.log" 2>&1 || true
done
log "done"
