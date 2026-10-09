#!/usr/bin/env bash
# Live drive: real bin/fm-spawn.sh / bin/fm-control.sh against a throwaway
# fm-lab-* Herdr session (bin/fm-herdr-lab.sh), real treehouse, real git.
# The claude/pi binaries for LAUNCHED panes are a PATH stub (no real
# credential store is mutated); refusal cases call the real claude/pi CLIs
# against the operator's signed-in stores read-only.
set -u
ROOT=${1:?worktree root}
T=$(mktemp -d /tmp/fm-pin-live.XXXXXX); T=$(cd -P "$T" && pwd -P)
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB=$("$LAB_HELPER" name pinlive)
export HERDR_SESSION="$LAB"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_ENV HERDR_SOCKET_PATH
REAL_PATH=$PATH
export FM_PIN_REAL_HERDR_BIN="$(command -v herdr)" FM_PIN_REAL_OS_HOME="$HOME" FM_PIN_LAB="$LAB"
WTS=""
cleanup() {
  for id in pin-ok unpinned-seat; do
    FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-teardown.sh" "$id" --force >/dev/null 2>&1 || true
  done
  for wt in $WTS; do [ -d "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1 || true; done
  "$LAB_HELPER" teardown "$LAB" && echo "lab teardown: ok ($LAB)"
  rm -rf "$T" 2>/dev/null || chmod -R u+w "$T" 2>/dev/null; rm -rf "$T" 2>/dev/null || true
}
trap cleanup EXIT
"$LAB_HELPER" provision "$LAB" >/dev/null || { echo "provision failed"; exit 1; }
echo "lab provisioned: $LAB"
lab() { "$LAB_HELPER" run "$LAB" "$@"; }
fail() { echo "not ok - $*" >&2; exit 1; }
panes() {
  local ids ws count total=0
  ids=$(lab workspace list | jq -r '.result.workspaces[].workspace_id') || return 1
  for ws in $ids; do
    count=$(lab pane list --workspace "$ws" | jq -er '.result.panes | length') || return 1
    total=$((total + count))
  done
  printf '%s\n' "$total"
}

H="$T/home"; P="$T/project"; FB="$T/fakebin"
mkdir -p "$H/state" "$H/config" "$H/data" "$H/projects" "$FB" "$T/other" "$T/pinB" "$T/pi-other" "$T/codex-other" "$T/user-home"
touch "$H/state/.last-watcher-beat"
: > "$T/other/signed-in"; : > "$T/pinB/signed-in"
mkdir -p "$P"; git -C "$P" init -q; echo x > "$P/README.md"; git -C "$P" add README.md
git -C "$P" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$P" "$P.origin.git"; git -C "$P" remote add origin "file://$P.origin.git"
jq -n --arg o "$T/other" --arg po "$T/pi-other" --arg co "$T/codex-other" \
  '{crossAccount:{enabled:true},accounts:{other:{claude:$o,pi:$po,codex:$co}}}' > "$H/config/accounts.json"
. "$ROOT/bin/fm-account-lib.sh"
fm_account_enabled "$H/config/accounts.json" || fail "invalid bounded account fixture"
brief() { mkdir -p "$H/data/$1"; printf '# Task\n## Captain'"'"'s intent\nlive pin check %s\n\n## Firstmate spec\nIdle.\n' "$1" > "$H/data/$1/brief.md"; }
spawn() {  # <id> [args...]  (real claude/pi on PATH)
  local id=$1; shift; brief "$id"
  FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    HOME="$T/user-home" "$ROOT/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo off --backend herdr "$@" 2>&1
}
cat > "$FB/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] || [ "${1:-}" = --version ]; then
  [ "${1:-}" = --version ] && { echo '2.1.295 (Claude Code)'; exit 0; }
  [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/signed-in" ]; exit
fi
echo "stub-claude root=${CLAUDE_CONFIG_DIR-unset}"; while :; do sleep 60; done
SH
chmod +x "$FB/claude"
# Keep disposable vendor HOME while addressing the one lab provisioned in the
# operator's Herdr namespace. Otherwise HOME creates a different same-name lab.
cat > "$FB/herdr" <<'SH'
#!/usr/bin/env bash
session=''
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[i]}" != --session ] || session=${args[i+1]:-}
done
if [ -z "$session" ]; then
  case "${1:-} ${2:-}" in
    'status --json') HOME="$FM_PIN_REAL_OS_HOME" exec "$FM_PIN_REAL_HERDR_BIN" "$@" --session "$FM_PIN_LAB" ;;
    '--version '| '--help '| 'api schema') ;;
    *) echo 'refusing Herdr call without owned session selector' >&2; exit 1 ;;
  esac
elif [ "$session" != "$FM_PIN_LAB" ]; then
  echo 'refusing non-owned Herdr session' >&2; exit 1
fi
HOME="$FM_PIN_REAL_OS_HOME" exec "$FM_PIN_REAL_HERDR_BIN" "$@"
SH
chmod +x "$FB/herdr"

echo; echo "=== S1 claude pin=/home/daan/.claude (real signed-in store, real claude CLI), --account other (conflicting seat)"
printf '%s\n' "$HOME/.claude" > "$H/config/claude-account"
before=$(panes); out=$(spawn pin-conflict --harness claude --account other); rc=$?
echo "$out" | sed "s|$T|<tmp>|g"; echo "rc=$rc panes_before=$before panes_after=$(panes) meta=$( [ -e "$H/state/pin-conflict.meta" ] && echo present || echo absent) quota=$( [ -e "$H/state/quota-intake" ] && echo present || echo absent)"
[ "$rc" -ne 0 ] && [[ "$out" == *"configured pin is authoritative"* ]] && [ "$before" = "$(panes)" ] && [ ! -e "$H/state/pin-conflict.meta" ] && [ ! -e "$H/state/quota-intake" ] || fail "S1 pin refusal/no consumption"
echo 'ok - S1 Claude conflicting seat refused before launch/trust/quota'

echo; echo "=== S2 pi pin=/home/daan/.pi/agent (real signed-in store, real pi CLI), --account other (conflicting seat)"
printf '%s\nopenai-codex\n' "$HOME/.pi/agent" > "$H/config/pi-account"
before=$(panes); out=$(spawn pi-conflict --harness pi --model openai-codex/gpt-5.5 --account other); rc=$?
echo "$out" | sed "s|$T|<tmp>|g"; echo "rc=$rc panes_before=$before panes_after=$(panes) meta=$( [ -e "$H/state/pi-conflict.meta" ] && echo present || echo absent)"
[ "$rc" -ne 0 ] && [[ "$out" == *"configured pin is authoritative"* ]] && [ "$before" = "$(panes)" ] && [ ! -e "$H/state/pi-conflict.meta" ] || fail "S2 pin refusal/no pane or metadata"
echo 'ok - S2 Pi conflicting seat refused before launch'
rm -f "$H/config/pi-account"

echo; echo "=== S3 no pin: registered cross-account seat --account other still routes (stub claude in pane)"
rm -f "$H/config/claude-account"
before=$(panes); out=$(PATH="$FB:$REAL_PATH" FM_QUOTA_INTAKE_TEST_BYPASS=1 spawn unpinned-seat --harness claude --account other); rc=$?
echo "$out" | sed "s|$T|<tmp>|g" | tail -5
m="$H/state/unpinned-seat.meta"
echo "rc=$rc panes_before=$before panes_after=$(panes) account=$(grep '^account=' "$m" | cut -d= -f2-) claude_config_dir=$(grep '^claude_config_dir=' "$m" | cut -d= -f2- | sed "s|$T|<tmp>|g") pane=$(grep '^herdr_pane_id=' "$m" | cut -d= -f2-)"
WTS="$WTS $(grep '^worktree=' "$m" | cut -d= -f2-)"
[ "$rc" -eq 0 ] && [ "$(grep '^account=' "$m" | cut -d= -f2-)" = other ] && [ "$(grep '^claude_config_dir=' "$m" | cut -d= -f2-)" = "$T/other" ] && [ "$(panes)" -eq "$((before + 1))" ] || fail "S3 registered routing/store/pane"
echo 'ok - S3 unpinned registered seat routes to its store and new live pane'
sleep 3; lab pane read "$(grep '^herdr_pane_id=' "$m" | cut -d= -f2-)" 2>/dev/null | jq -r '.result.text // .result.content // .' 2>/dev/null | grep -a 'stub-claude' | sed "s|$T|<tmp>|g" | tail -1

echo; echo "=== S4 relaunch of that task after pin B is configured: recorded binding 'other' conflicts -> refuse before stop"
printf '%s\n' "$T/pinB" > "$H/config/claude-account"
pane=$(grep '^herdr_pane_id=' "$m" | cut -d= -f2-)
meta_before=$(sha256sum "$m")
out=$(PATH="$FB:$REAL_PATH" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" HOME="$T/user-home" FM_SPAWN_NO_GUARD=1 FM_QUOTA_INTAKE_TEST_BYPASS=1 \
  "$ROOT/bin/fm-control.sh" unpinned-seat relaunch --harness claude --note "live pin conflict check" 2>&1); rc=$?
echo "$out" | sed "s|$T|<tmp>|g" | tail -4
echo "rc=$rc old_pane_alive=$(lab pane get "$pane" >/dev/null 2>&1 && echo yes || echo no) meta_store_after=$(grep '^claude_config_dir=' "$m" | cut -d= -f2- | sed "s|$T|<tmp>|g")"
[ "$rc" -ne 0 ] && [[ "$out" == *"configured pin is authoritative"* ]] && lab pane get "$pane" >/dev/null 2>&1 && [ "$meta_before" = "$(sha256sum "$m")" ] || fail "S4 refusal before stop/metadata mutation"
echo 'ok - S4 changed pin refuses before old pane stop and preserves metadata'

echo; echo "=== S5 pin B, no --account: spawn launches on the pinned store B (stub claude in pane)"
other_trust_before=$(sha256sum "$T/other/.claude.json")
before=$(panes); out=$(PATH="$FB:$REAL_PATH" FM_QUOTA_INTAKE_TEST_BYPASS=1 spawn pin-ok --harness claude); rc=$?
echo "$out" | sed "s|$T|<tmp>|g" | tail -3
m2="$H/state/pin-ok.meta"
echo "rc=$rc panes_before=$before panes_after=$(panes) claude_config_dir=$(grep '^claude_config_dir=' "$m2" | cut -d= -f2- | sed "s|$T|<tmp>|g") trust_in_pinB=$( [ -e "$T/pinB/.claude.json" ] && echo yes || echo no) trust_in_other=$( [ -e "$T/other/.claude.json" ] && echo yes || echo no)"
WTS="$WTS $(grep '^worktree=' "$m2" | cut -d= -f2-)"
[ "$rc" -eq 0 ] && [ "$(grep '^claude_config_dir=' "$m2" | cut -d= -f2-)" = "$T/pinB" ] && [ "$(panes)" -eq "$((before + 1))" ] && [ -f "$T/pinB/.claude.json" ] && [ "$other_trust_before" = "$(sha256sum "$T/other/.claude.json")" ] || fail "S5 effective store/pane/trust isolation"
echo 'ok - S5 pin B launches a new live pane on B and leaves other trust unchanged'
sleep 3; lab pane read "$(grep '^herdr_pane_id=' "$m2" | cut -d= -f2-)" 2>/dev/null | jq -r '.result.text // .result.content // .' 2>/dev/null | grep -a 'stub-claude' | sed "s|$T|<tmp>|g" | tail -1
echo; echo "=== done"
