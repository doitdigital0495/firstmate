#!/usr/bin/env bash
# Live lifecycle matrix for the superseded duplicate slot record fix.
# Real tmux (private socket per case), real treehouse pool (TREEHOUSE_ROOT in /tmp),
# real git, real bin/fm-teardown.sh. Nothing touches the host's tmux or pools.
set -u
ROOT=${1:?worktree root}
TEARDOWN="$ROOT/bin/fm-teardown.sh"
REAL_TMUX=$(command -v tmux)
BASE=$(mktemp -d /tmp/fm-live-superseded.XXXXXX)
FAILS=0
SOCKETS=()
cleanup() { for s in "${SOCKETS[@]}"; do "$REAL_TMUX" -L "$s" kill-server >/dev/null 2>&1; done; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
ok() { say "  PASS: $*"; }
bad() { say "  FAIL: $*"; FAILS=$((FAILS + 1)); }

# stage <case> : project, pool, home, tmux shim; older window takes slot then exits,
# newer window takes the same reused slot and stays in it.
stage() {
  C="$BASE/$1"; SOCK="fmlive-$1-$$"; SOCKETS+=("$SOCK")
  mkdir -p "$C/home/state" "$C/home/data" "$C/home/config" "$C/bin" "$C/pool"
  git init -q "$C/project"
  git -C "$C/project" -c user.name=t -c user.email=t@e commit --allow-empty -qm init
  printf '#!/usr/bin/env bash\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$SOCK" > "$C/bin/tmux"
  # A fake harness binary so a pane can read as a live agent.
  printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$C/bin/claude"
  chmod +x "$C/bin/tmux" "$C/bin/claude"
  export PATH="$C/bin:$ORIG_PATH" TREEHOUSE_ROOT="$C/pool"
  tmux new-session -d -s firstmate -n hold -c "$C/project"
  # Older task: acquire slot through interactive treehouse get, then exit (worker gone).
  tmux new-window -d -t firstmate -n fm-older-task -c "$C/project"
  tmux send-keys -t firstmate:fm-older-task 'treehouse get --no-fetch' Enter
  SLOT=$(wait_slot firstmate:fm-older-task) || { bad "$1: older never entered slot"; return 1; }
  tmux send-keys -t firstmate:fm-older-task 'exit' Enter
  sleep 2
  # Newer task: gets the SAME reused slot and stays in it.
  tmux new-window -d -t firstmate -n fm-newer-task -c "$C/project"
  tmux send-keys -t firstmate:fm-newer-task 'treehouse get --no-fetch' Enter
  NSLOT=$(wait_slot firstmate:fm-newer-task) || { bad "$1: newer never entered slot"; return 1; }
  [ "$NSLOT" = "$SLOT" ] || { bad "$1: pool did not reuse slot ($SLOT vs $NSLOT)"; return 1; }
  cat > "$C/home/state/older-task.meta" <<EOF
window=firstmate:fm-older-task
endpoint_task_id=older-task
worktree=$SLOT
project=$C/project
kind=ship
mode=local-only
yolo=off
spawn_gen=s1789119828.100.1
EOF
  cat > "$C/home/state/newer-task.meta" <<EOF
window=firstmate:fm-newer-task
endpoint_task_id=newer-task
worktree=$SLOT
project=$C/project
kind=scout
spawn_gen=s1789387687.200.2
EOF
  say "  staged: slot=$SLOT (reused by both tasks)"
}

wait_slot() {
  local i p
  for i in $(seq 1 100); do
    p=$(tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null)
    case "$p" in "$TREEHOUSE_ROOT"/*/project) printf '%s\n' "$p"; return 0 ;; esac
    sleep 0.2
  done
  return 1
}

td() {  # <id> [--force]
  # FM_GATE_REFUSE_BYPASS: documented escape hatch for temp-sandbox fleets (this one).
  ( cd "$C/project" && FM_GATE_REFUSE_BYPASS=1 FM_HOME="$C/home" FM_ROOT_OVERRIDE="$ROOT" "$TEARDOWN" "$@" ) > "$C/out.$1" 2>&1
}
why() {  # <id> <text> : refusal names the expected reason
  grep -Fq -- "$2" "$C/out.$1" && ok "refusal reason: '$2'" || bad "refusal reason missing: '$2'"
}

newer_alive() { tmux list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -qx fm-newer-task; }
slot_status() { ( cd "$C/project" && treehouse status 2>&1 ) | sed 's/\x1b\[[0-9;]*m//g'; }

assert_untouched() {  # <label>
  [ -f "$C/home/state/older-task.meta" ] && ok "$1: older record kept" || bad "$1: older record removed"
  [ -f "$C/home/state/newer-task.meta" ] && ok "$1: newer record kept" || bad "$1: newer record removed"
  newer_alive && ok "$1: newer worker window alive" || bad "$1: newer worker killed"
  [ -e "$SLOT/.git" ] && ok "$1: slot checkout present" || bad "$1: slot checkout removed"
}

ORIG_PATH=$PATH

if [ -n "${BASE_TREE:-}" ]; then
  say "== S0 baseline (pre-fix $BASE_TREE): same staging deadlocks in both orders =="
  FIXED=$TEARDOWN; TEARDOWN="$BASE_TREE/bin/fm-teardown.sh"; SAVED_ROOT=$ROOT; ROOT=$BASE_TREE
  stage baseline
  tmux send-keys -t firstmate:fm-newer-task 'exit' Enter; sleep 2
  if td older-task; then say "  (baseline older retired?)"; else ok "pre-fix: older-task refused"; fi
  why older-task "not even with --force"
  if td newer-task --force; then say "  (baseline newer tore down?)"; else ok "pre-fix: newer-task --force refused"; fi
  why newer-task "not even with --force"
  sed 's/^/    | /' "$C/out.newer-task" | grep -E 'REFUSED|force'
  TEARDOWN=$FIXED; ROOT=$SAVED_ROOT
fi

say "== S1+S2 incident order: older retires, then newer tears down and returns slot (unclaimed) =="
stage incident-unclaimed
if td older-task; then ok "older-task teardown exit 0"; else bad "older-task teardown refused"; fi
sed 's/^/    | /' "$C/out.older-task"
[ ! -f "$C/home/state/older-task.meta" ] && ok "older record retired" || bad "older record still present"
[ -f "$C/home/state/newer-task.meta" ] && ok "newer record kept" || bad "newer record removed"
newer_alive && ok "newer worker window alive" || bad "newer worker killed"
[ -e "$SLOT/.git" ] && ok "slot checkout present" || bad "slot checkout removed"
say "  treehouse status after older retire:"; slot_status | sed 's/^/    | /'
tmux send-keys -t firstmate:fm-newer-task 'exit' Enter; sleep 2
mkdir -p "$C/home/data/newer-task"; printf '# catalog scout report\n' > "$C/home/data/newer-task/report.md"
say "  treehouse status before newer teardown:"; slot_status | sed 's/^/    | /'
# --force only lifts the scout report/captain-call gates; the slot collision ignored --force.
if td newer-task --force; then ok "newer-task teardown exit 0 (no deadlock)"; else bad "newer-task teardown refused"; fi
sed 's/^/    | /' "$C/out.newer-task"
[ ! -f "$C/home/state/newer-task.meta" ] && ok "newer record removed" || bad "newer record still present"
say "  treehouse status after newer teardown:"; slot_status | sed 's/^/    | /'

say "== S1b claim names newer task: older retires =="
stage claimed-by-newer
printf 'task=newer-task\nhome=%s\n' "$C/home" > "$(dirname "$SLOT")/.fm-slot-owner"
if td older-task; then ok "older-task teardown exit 0"; else bad "older-task teardown refused"; fi
sed 's/^/    | /' "$C/out.older-task"
[ ! -f "$C/home/state/older-task.meta" ] && ok "older record retired" || bad "older record still present"
newer_alive && ok "newer worker window alive" || bad "newer worker killed"
[ -f "$(dirname "$SLOT")/.fm-slot-owner" ] && ok "newer's claim left untouched" || bad "claim removed"

say "== S3 adversarial: tear down newer (current owner) first =="
stage current-owner
tmux send-keys -t firstmate:fm-newer-task 'exit' Enter; sleep 2
tmux new-window -d -t firstmate -n bystander -c "$SLOT"   # a process still in the slot
if td newer-task; then bad "newer-task teardown succeeded while older record names slot"; else ok "newer-task refused"; fi
why newer-task "not even with --force"
sed 's/^/    | /' "$C/out.newer-task"
[ -f "$C/home/state/older-task.meta" ] && [ -f "$C/home/state/newer-task.meta" ] && ok "both records kept" || bad "a record removed"
[ -e "$SLOT/.git" ] && ok "slot checkout present" || bad "slot removed"
tmux list-windows -t firstmate -F '#{window_name}' | grep -qx bystander && ok "slot process alive" || bad "slot process killed"

say "== S4a adversarial: older endpoint live (claude running) =="
stage live-endpoint
tmux respawn-window -k -t firstmate:fm-older-task claude
sleep 1
if td older-task; then bad "retired despite live older endpoint"; else ok "older-task refused"; fi
why older-task "bin/fm-control.sh older-task exit"
sed 's/^/    | /' "$C/out.older-task"
assert_untouched live-endpoint
tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-older-task && ok "older live agent not killed" || bad "older live agent killed"

say "== S4b adversarial: spawn_gen epoch tie =="
stage epoch-tie
sed -i 's/^spawn_gen=.*/spawn_gen=s1789119828.300.3/' "$C/home/state/newer-task.meta"
if td older-task; then bad "retired on epoch tie"; else ok "older-task refused"; fi
why older-task "not even with --force"
sed 's/^/    | /' "$C/out.older-task"
assert_untouched epoch-tie

say "== S4c adversarial: slot claim names older task =="
stage claim-older
printf 'task=older-task\nhome=%s\n' "$C/home" > "$(dirname "$SLOT")/.fm-slot-owner"
if td older-task; then bad "retired while claim names older"; else ok "older-task refused"; fi
why older-task "not even with --force"
sed 's/^/    | /' "$C/out.older-task"
assert_untouched claim-older

say "== S5a adversarial: uncommitted work in slot =="
stage uncommitted
printf 'newer work\n' > "$SLOT/uncommitted.txt"
if td older-task; then bad "retired with uncommitted slot work"; else ok "older-task refused"; fi
why older-task "taken by newer task newer-task"
sed 's/^/    | /' "$C/out.older-task"
assert_untouched uncommitted
[ -f "$SLOT/uncommitted.txt" ] && ok "uncommitted file preserved" || bad "uncommitted file lost"

say "== S5b adversarial: unlanded commit in slot =="
stage unlanded
git -C "$SLOT" -c user.name=t -c user.email=t@e commit --allow-empty -qm unlanded
HEAD_BEFORE=$(git -C "$SLOT" rev-parse HEAD)
if td older-task; then bad "retired with unlanded slot commit"; else ok "older-task refused"; fi
why older-task "taken by newer task newer-task"
why older-task "has work not yet merged"
sed 's/^/    | /' "$C/out.older-task"
assert_untouched unlanded
[ "$(git -C "$SLOT" rev-parse HEAD)" = "$HEAD_BEFORE" ] && ok "unlanded commit preserved" || bad "slot HEAD changed"

say "== RESULT: $FAILS failure(s); case dirs under $BASE =="
exit "$FAILS"
