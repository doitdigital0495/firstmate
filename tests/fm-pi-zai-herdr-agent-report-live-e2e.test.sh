#!/usr/bin/env bash
# Default-on live guard: a Firstmate-spawned Pi GLM task worker must appear in
# Herdr's agents sidebar with a real agent_status.
#
# The defect this pins: the zai launch rides `opr` so ZAI_API_KEY stays behind
# the secret boundary, but sudoers `use_pty` moves the whole chain off the
# pane's pty and `op run` pipes stdout for output masking. Without an inner
# terminal bridge, Pi resolves print mode rather than rendering its TUI and the
# operator's herdr-agent-state extension (tui-gated by design) never reports.
# Herdr showed nothing for the worker: `agent get` answered
# agent_not_found while the worker ran. bin/fm-spawn.sh therefore brackets the
# zai opr chain with best-effort pane-side `herdr pane report-agent` calls
# (working before, idle or blocked from the exit status after) under Firstmate's
# own `firstmate:pi` source id, never the reserved `herdr:` prefix.
#
# This guard drives the REAL bin/fm-spawn.sh through a REAL isolated Herdr lab
# session, proving the pane-side reports for a zai/GLM worker without spending
# model tokens. The fake Pi requires stdout to be a terminal, prints a TUI
# marker, sleeps and exits 0; opr, the vault reference map, and Herdr run for
# real. All Herdr operations use fm-herdr-lab.sh so the test cannot affect the
# fleet's default session.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; bin/fm-herdr-lab.sh owns the isolation).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLEANED=0
SCRATCH=
WORKTREE=
CODEX_WORKTREE=
SESSION=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_PI_ZAI_HERDR_AGENT_REPORT_LIVE_E2E herdr jq treehouse opr

[ -f "$ROOT/.env.op" ] || { echo 'skip: live: no tracked .env.op reference map'; exit 0; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HERDR_LAB_HELPER" name fm-pi-herdr-sidebar-2026-09-23)
export HERDR_SESSION="$SESSION"
cleanup_all() {
  local status=$?
  [ "$CLEANED" = 0 ] || return "$status"
  CLEANED=1
  [ -n "$WORKTREE" ] && treehouse return --force "$WORKTREE" >/dev/null 2>&1
  [ -n "$CODEX_WORKTREE" ] && treehouse return --force "$CODEX_WORKTREE" >/dev/null 2>&1
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  [ -n "$SESSION" ] && "$HERDR_LAB_HELPER" teardown "$SESSION"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"
lab() { "$HERDR_LAB_HELPER" run "$SESSION" "$@"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-zai-report.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)

# A fake task pi: the help probe sees a modern surface, the task run holds the
# pane long enough to observe the working report, then exits 0 so the exit
# report must read idle. No provider is contacted, so no token is spent.
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.86.1 (firstmate fake)' 'Options: --help --tui-mode <mode>'
  exit 0
fi
if [ -t 0 ] && [ -t 1 ]; then
  printf 'FIRSTMATE_FAKE_PI_TUI_VISIBLE\n'
else
  printf 'FIRSTMATE_FAKE_PI_PRINT_MODE\n'
fi
sleep 12
exit 0
SH
chmod +x "$FAKEBIN/pi"

# Scratch world: a project with a bare origin, and a firstmate home whose
# panes stay flat (presentation spaces off).
PROJ="$SCRATCH/project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

HOME_DIR="$SCRATCH/fm-home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/data"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

ID=zai-herdr-report-e2e
mkdir -p "$HOME_DIR/data/$ID"
cat > "$HOME_DIR/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Herdr agent visibility for a zai Pi task worker.

## Firstmate spec
Nothing to do; this brief only needs to be carried.
EOF

# The spawn runs with no Herdr ancestry so the worker pane is created by the
# spawn itself; Herdr then injects that pane's own HERDR_PANE_ID, which is the
# identity the pane-side reports must read.
OUT="$SCRATCH/spawn.out"
ERR="$SCRATCH/spawn.err"
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
  PATH="$FAKEBIN:$PATH" \
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" \
  --harness pi --model zai/glm-5.3 --effort high \
  --mode no-mistakes --yolo off --backend herdr \
  >"$OUT" 2>"$ERR"
SPAWN_RC=$?
[ "$SPAWN_RC" -eq 0 ] || fail "the real zai pi spawn failed (rc=$SPAWN_RC)"$'\n'"--- stderr ---"$'\n'"$(tail -20 "$ERR")"

META="$HOME_DIR/state/$ID.meta"
PANE=$(grep '^herdr_pane_id=' "$META" 2>/dev/null | cut -d= -f2-)
[ -n "$PANE" ] || fail "spawn meta is missing herdr_pane_id"$'\n'"--- stderr ---"$'\n'"$(tail -20 "$ERR")"
WORKTREE=$(grep '^worktree=' "$META" 2>/dev/null | cut -d= -f2-)

registered_field() {  # <jq-path under .result.agent>
  lab agent get "$PANE" 2>/dev/null \
    | jq -r ".result.agent.$1 // empty" 2>/dev/null
}

wait_for_status() {  # <expected-status> <tries>
  local expected=$1 tries=$2 got i=0
  while [ "$i" -lt "$tries" ]; do
    got=$(registered_field agent_status)
    [ "$got" = "$expected" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# Working: the start report must land while the opr chain (fake pi) still runs.
wait_for_status working 120 || fail "the zai pi worker never registered as working in Herdr (agent get read '$(registered_field agent)/$(registered_field agent_status)' for 60s in pane $PANE); the pane-side herdr report wrapper is what registers it"
[ "$(registered_field agent)" = pi ] \
  || fail "the pane registered agent '$(registered_field agent)' rather than pi"
wait_for_pane_tui() {
  local i=0
  while [ "$i" -lt 120 ]; do
    lab pane read "$PANE" --lines 80 | grep -q 'FIRSTMATE_FAKE_PI_TUI_VISIBLE' && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
wait_for_pane_tui \
  || fail "zai Pi had no interactive terminal rendered in the Herdr pane: $(lab pane read "$PANE" --lines 80 | tail -12)"
lab pane read "$PANE" --lines 80 | grep -q 'FIRSTMATE_FAKE_PI_PRINT_MODE' \
  && fail "zai Pi resolved print mode instead of interactive mode"

# The sidebar fact itself: agent list must carry the pane's record.
lab agent list 2>/dev/null | grep -q "$PANE" \
  || fail "herdr agent list does not show the zai pi worker pane $PANE"

# Idle: after the chain exits 0, the exit report must read idle.
wait_for_status idle 120 || fail "the zai pi worker did not report idle after its opr chain exited (still '$(registered_field agent_status)'); pane content:"$'\n'"$(lab pane read "$PANE" 2>/dev/null | tail -5)"

note "zai Pi worker pane $PANE registered working then idle in isolated Herdr lab"

# Exercise the other supported task-worker provider too. This launch needs no
# secret wrapper, but must register through the same pane-side lifecycle path.
CODEX_ID=codex-herdr-report-e2e
mkdir -p "$HOME_DIR/data/$CODEX_ID"
cp "$HOME_DIR/data/$ID/brief.md" "$HOME_DIR/data/$CODEX_ID/brief.md"
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
  PATH="$FAKEBIN:$PATH" \
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$CODEX_ID" "$PROJ" \
  --harness pi --model openai-codex/gpt-5.6-sol --effort medium \
  --mode no-mistakes --yolo off --backend herdr \
  >"$OUT" 2>"$ERR"
SPAWN_RC=$?
[ "$SPAWN_RC" -eq 0 ] || fail "the real Codex Pi spawn failed (rc=$SPAWN_RC)"$'\n'"--- stderr ---"$'\n'"$(tail -20 "$ERR")"
CODEX_META="$HOME_DIR/state/$CODEX_ID.meta"
CODEX_PANE=$(grep '^herdr_pane_id=' "$CODEX_META" 2>/dev/null | cut -d= -f2-)
CODEX_WORKTREE=$(grep '^worktree=' "$CODEX_META" 2>/dev/null | cut -d= -f2-)
[ -n "$CODEX_PANE" ] || fail "Codex Pi spawn meta is missing herdr_pane_id"
PANE=$CODEX_PANE
wait_for_status working 120 || fail "the Codex Pi worker never registered as working in Herdr (read '$(registered_field agent)/$(registered_field agent_status)' for 60s in pane $PANE)"
[ "$(registered_field agent)" = pi ] || fail "the Codex Pi pane registered agent '$(registered_field agent)' rather than pi"
wait_for_pane_tui || fail "Codex Pi had no interactive terminal rendered in the Herdr pane"
lab agent list 2>/dev/null | grep -q "$PANE" || fail "herdr agent list does not show Codex Pi worker pane $PANE"
wait_for_status idle 120 || fail "the Codex Pi worker did not report idle after its launch exited"
note "Codex Pi worker pane $PANE registered working then idle in isolated Herdr lab"
pass "real fm-spawn + isolated Herdr lab: GLM and Codex Pi render interactive terminal output and appear in the agents sidebar with real agent_status"
