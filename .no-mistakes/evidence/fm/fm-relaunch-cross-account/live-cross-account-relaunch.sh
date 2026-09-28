#!/usr/bin/env bash
# Live proof: a real worker spawned in an isolated Herdr lab on account "geris"
# is moved by `fm-control.sh <id> relaunch --account personal` onto the
# "personal" seat, keeping its worktree; plus adversarial refusals.
set -u
ROOT=${ROOT:?}
EVD=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-xacct-live.XXXXXX")
HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB=$("$HELPER" name xacct-relaunch) || exit 1
export HERDR_SESSION="$LAB"
WT=
cleanup() {
  [ -n "$WT" ] && treehouse return --force "$WT" >/dev/null 2>&1
  "$HELPER" teardown "$LAB"; echo "teardown rc=$?"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
"$HELPER" provision "$LAB" || { echo "provision failed"; exit 1; }
lab() { "$HELPER" run "$LAB" "$@"; }
LAB_SOCKET=$(lab session list --json | jq -r --arg s "$LAB" '.sessions[]|select(.name==$s)|.socket_path')
echo "lab session: $LAB"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/xa1"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
G="$TMP_ROOT/stores/geris"; P="$TMP_ROOT/stores/personal"
mkdir -p "$G"/{claude,pi,codex} "$P"/{claude,pi,codex}
jq -n --arg g "$G" --arg p "$P" '{crossAccount:{enabled:true},accounts:{
  geris:{claude:($g+"/claude"),pi:($g+"/pi"),codex:($g+"/codex")},
  personal:{claude:($p+"/claude"),pi:($p+"/pi"),codex:($p+"/codex")}}}' > "$HOME_DIR/config/accounts.json"
cat > "$HOME_DIR/data/xa1/brief.md" <<'EOF'
# Task
## Captain's intent
Idle lab worker used to prove a cross-account relaunch.

## Firstmate spec
Do nothing; this is a lab proof.

## Request checklist
- [ ] nothing
EOF
PROJ="$TMP_ROOT/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"; git -C "$PROJ" add .
git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

fmenv() { env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$LAB" \
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$@"; }
codex_env_of_pane() {  # prints CODEX_HOME of codex processes whose cwd is the worktree
  local pid
  for pid in $(pgrep -f codex); do
    [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$WT" ] || continue
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^CODEX_HOME=' | sed "s/^/pid $pid /"
  done | sort -u
}

echo "== 1. fresh spawn on account geris (harness codex)"
fmenv "$ROOT/bin/fm-spawn.sh" xa1 "$PROJ" --mode local-only --yolo off --harness codex --account geris --backend herdr; echo "spawn rc=$?"
META="$HOME_DIR/state/xa1.meta"
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
grep -E '^(account|codex_home|claude_config_dir|pi_agent_dir|worktree|harness|herdr_pane_id)=' "$META"
sleep 6; echo "live codex process env:"; codex_env_of_pane
cp "$META" "$EVD/xa1.meta.before"

echo "== 2. adversarial: unlisted seat refuses before the agent is touched"
fmenv "$ROOT/bin/fm-control.sh" xa1 relaunch --account nosuch --note "usage-limit move"; echo "rc=$?"
cmp -s "$META" "$EVD/xa1.meta.before" && echo "meta unchanged: yes"
echo "codex still alive on geris:"; codex_env_of_pane

echo "== 3. adversarial: --account on a non-relaunch verb is refused"
fmenv "$ROOT/bin/fm-control.sh" xa1 interrupt --account personal; echo "rc=$?"

kill_codex() {  # the lab codex sits on an unauthenticated login screen, so model the exited agent
  local pid
  for pid in $(pgrep -f codex); do
    [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$WT" ] && kill "$pid"
  done
  sleep 3; echo "codex after kill:"; codex_env_of_pane; echo "(end)"
}
kill_codex
echo "== 4. cross-account relaunch geris -> personal"
fmenv "$ROOT/bin/fm-control.sh" xa1 relaunch --account personal --note "usage-limit move to personal seat"; echo "relaunch rc=$?"
grep -E '^(account|codex_home|claude_config_dir|pi_agent_dir|worktree|harness|herdr_pane_id)=' "$META"
cp "$META" "$EVD/xa1.meta.after"
sleep 6; echo "live codex process env:"; codex_env_of_pane
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
lab pane read "$PANE" --lines 40 > "$EVD/pane-after-relaunch.txt" 2>&1 || lab pane read "$PANE" > "$EVD/pane-after-relaunch.txt" 2>&1

kill_codex
echo "== 5. relaunch without --account keeps the (new) recorded seat"
fmenv "$ROOT/bin/fm-control.sh" xa1 relaunch --note "same-seat restart"; echo "relaunch rc=$?"
grep -E '^(account|codex_home)=' "$META"
sleep 6; echo "live codex process env:"; codex_env_of_pane

echo "== 6. crossAccount disabled: switch back refuses, agent untouched"
jq '.crossAccount.enabled=false' "$HOME_DIR/config/accounts.json" > "$HOME_DIR/config/a.next" && mv "$HOME_DIR/config/a.next" "$HOME_DIR/config/accounts.json"
cp "$META" "$TMP_ROOT/m6"
fmenv "$ROOT/bin/fm-control.sh" xa1 relaunch --account geris --note "move back"; echo "rc=$?"
cmp -s "$META" "$TMP_ROOT/m6" && echo "meta unchanged: yes"
codex_env_of_pane

echo "== teardown worker"
fmenv "$ROOT/bin/fm-teardown.sh" xa1 --force >/dev/null 2>&1; echo "fm-teardown rc=$?"
