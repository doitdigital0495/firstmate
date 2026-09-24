#!/usr/bin/env bash
# Live Herdr-lab proof: real fm-spawn.sh --account geris places a Pi worker in a
# real lab pane whose process sees the Geris PI_CODING_AGENT_DIR; relaunch after
# the kill switch is turned off keeps the recorded store; an unpinned Pi spawn
# without an ambient store leaves the variable alone.
# The `pi` binary is a stub that records its environment, so no model is billed.
set -u
ROOT=${1:?repo root}
EV=${2:?evidence dir}
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
command -v treehouse >/dev/null || { echo 'skip: treehouse missing'; exit 3; }

TMP=$(mktemp -d "$(cd /tmp && pwd -P)/fm-acct-lab.XXXXXX")
LAB="$ROOT/bin/fm-herdr-lab.sh"
S=$("$LAB" name fm-acct-pin) || exit 1
export HERDR_SESSION=$S
WTS=()
CLEANED=0
cleanup() {
  [ "$CLEANED" = 0 ] || return 0; CLEANED=1
  for wt in ${WTS[@]+"${WTS[@]}"}; do treehouse return --force "$wt" >/dev/null 2>&1; done
  "$LAB" teardown "$S"; echo "teardown rc=$?"
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "not ok - $1"; exit 1; }

# Fake pi on PATH before provision so lab panes inherit it.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/pi" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in --version|-v) echo 0.0.0-stub; exit 0 ;; esac
{ echo "PI_CODING_AGENT_DIR=\${PI_CODING_AGENT_DIR-<unset>}"; echo "CODEX_HOME=\${CODEX_HOME-<unset>}"; echo "CLAUDE_CONFIG_DIR=\${CLAUDE_CONFIG_DIR-<unset>}"; } >> "$TMP/pi-env.\$(basename "\$PWD").log"
sleep 2
EOF
chmod +x "$TMP/fakebin/pi"
export PATH="$TMP/fakebin:$PATH"
unset PI_CODING_AGENT_DIR CODEX_HOME

"$LAB" provision "$S" || fail 'provision'
SOCK=$("$LAB" run "$S" session list --json 2>/dev/null | jq -r --arg s "$S" '.sessions[]?|select(.name==$s)|.socket_path')
[ -n "$SOCK" ] || fail 'lab socket'

PROJ="$TMP/proj"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; echo x > "$PROJ/README.md"; git -C "$PROJ" add .; git -C "$PROJ" -c user.name=t -c user.email=t@x commit -qm i
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

H="$TMP/home"; mkdir -p "$H/state" "$H/config"
printf 'off\n' > "$H/config/herdr-presentation-spaces"
cat > "$H/config/accounts.json" <<EOF
{"crossAccount":{"enabled":true},"accounts":{
 "personal":{"claude":"$TMP/stores/.claude","pi":"$TMP/stores/.pi/agent","codex":"$TMP/stores/.codex"},
 "geris":{"claude":"$TMP/stores/.claude-geris","pi":"$TMP/stores/.pi-geris/agent","codex":"$TMP/stores/.codex-geris"}}}
EOF
for id in acctgeris acctplain; do
  mkdir -p "$H/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLab account pin %s.\n\n## Firstmate spec\nNothing.\n' "$id" > "$H/data/$id/brief.md"
done
spawn() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$S" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" "$@"
}
wait_log() { for _ in $(seq 60); do [ -s "$1" ] && [ "$(wc -l < "$1")" -ge "$2" ] && return 0; sleep 0.5; done; return 1; }

echo '== 1. spawn --harness pi --account geris (switch on)'
spawn acctgeris "$PROJ" --mode no-mistakes --yolo off --harness pi --account geris --backend herdr; echo "rc=$?"
WT=$(grep '^worktree=' "$H/state/acctgeris.meta" | cut -d= -f2-); WTS+=("$WT")
grep -E '^(account|claude_config_dir|pi_agent_dir|codex_home|herdr_session|herdr_pane_id)=' "$H/state/acctgeris.meta"
LOG="$TMP/pi-env.$(basename "$WT").log"
wait_log "$LOG" 3 || fail 'pinned pi never ran in lab pane'
echo '-- env seen by the worker process in the Herdr lab pane:'; cat "$LOG"

echo '== 2. adversarial: switch off, a NEW --account geris spawn refuses before mutation'
FM_HOME="$H" "$ROOT/bin/fm-account-routing.sh" off
mkdir -p "$H/data/acctoff"; cp "$H/data/acctgeris/brief.md" "$H/data/acctoff/brief.md"
spawn acctoff "$PROJ" --mode no-mistakes --yolo off --harness pi --account geris --backend herdr; echo "rc=$?"
[ -e "$H/state/acctoff.meta" ] && echo 'acctoff.meta EXISTS (bad)' || echo 'acctoff.meta absent (no durable mutation)'

echo '== 3. adversarial: --relaunch --account personal refuses'
spawn acctgeris --relaunch --account personal; echo "rc=$?"

echo '== 4. relaunch with switch off keeps recorded Geris store'
sleep 3
spawn acctgeris --relaunch; echo "rc=$?"
wait_log "$LOG" 6 && { echo '-- env seen by relaunched worker:'; tail -3 "$LOG"; } || echo 'relaunched worker did not record env'
grep -E '^(account|pi_agent_dir)=' "$H/state/acctgeris.meta"

echo '== 5. unpinned pi spawn, no ambient PI_CODING_AGENT_DIR: launch leaves the pane store alone'
spawn acctplain "$PROJ" --mode no-mistakes --yolo off --harness pi --backend herdr; echo "rc=$?"
WT2=$(grep '^worktree=' "$H/state/acctplain.meta" | cut -d= -f2-); WTS+=("$WT2")
grep -c '^pi_agent_dir=' "$H/state/acctplain.meta" | sed 's/^/pi_agent_dir lines in meta: /'
LOG2="$TMP/pi-env.$(basename "$WT2").log"
wait_log "$LOG2" 3 && { echo '-- env seen by unpinned worker:'; cat "$LOG2"; } || echo 'unpinned worker did not record env'
