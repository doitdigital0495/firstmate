#!/usr/bin/env bash
# Live drive of the wait-no-turns inheritance change. Runs INSIDE a pane of a
# private lab tmux server, so every firstmate script inherits that socket.
# Usage: drive-wait-no-turns.sh <code-root> <primary-lab-home> <secondmate-home> <secondmate-id> <label>
set -u
ROOT=$1 LAB=$2 SM=$3 ID=$4 LABEL=$5
export FM_HOME="$LAB" FM_BACKEND=tmux FM_SEND_SETTLE=0

say() { printf '\n=== [%s] %s ===\n' "$LABEL" "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '(exit %s)\n' "$?"; }
flag() { if [ -e "$1/config/wait-no-turns" ]; then echo "  $1/config/wait-no-turns: PRESENT"; else echo "  $1/config/wait-no-turns: absent"; fi; }
# A secondmate scaffolds its crew's brief from ITS OWN home and ITS OWN checkout.
brief() {
  local task=$1 out="$SM/data/$1/brief.md"
  rm -rf "$SM/data/$task"
  printf '$ FM_HOME=%s %s/bin/fm-brief.sh %s some-proj --mode no-mistakes\n' "$SM" "$SM" "$task"
  FM_HOME="$SM" "$SM/bin/fm-brief.sh" "$task" some-proj --mode no-mistakes >/dev/null 2>&1
  printf '(exit %s)\n' "$?"
  printf '  "# Waiting" section headings in brief: %s\n' "$(grep -c '^# Waiting$' "$out")"
  printf '  drive sentence: %s\n' "$(grep -E '^(Drive the run with ONE foreground|So background the drive call)' "$out")"
  printf '  inbox no-poll line: %s\n' "$(grep -c '^Do not poll or list the inbox while waiting' "$out")"
}

say "code under test"
git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "(exported tree: $ROOT)"
bash -c ". '$ROOT/bin/fm-config-inherit-lib.sh'; echo \"FM_INHERITABLE_CONFIG=\$FM_INHERITABLE_CONFIG\""

say "1. start: neither home has the flag; secondmate crew brief"
flag "$LAB"; flag "$SM"
brief crew-before

say "2. primary opts in, then pushes config to live secondmate homes"
run touch "$LAB/config/wait-no-turns"
run "$ROOT/bin/fm-config-push.sh"
flag "$LAB"; flag "$SM"
echo "  secondmate home git status for the flag: $(git -C "$SM" status --porcelain -- config/wait-no-turns | wc -l) dirty line(s); check-ignore: $(git -C "$SM" check-ignore config/wait-no-turns || echo NOT-IGNORED)"
brief crew-opted-in

say "3. second push with nothing changed"
run "$ROOT/bin/fm-config-push.sh"

say "4. primary opts out, pushes again"
run rm -f "$LAB/config/wait-no-turns"
run "$ROOT/bin/fm-config-push.sh"
flag "$LAB"; flag "$SM"
brief crew-opted-out

say "5. adversarial: secondmate sets the flag on its own while the primary has none"
run touch "$SM/config/wait-no-turns"
flag "$LAB"; flag "$SM"
run "$ROOT/bin/fm-config-push.sh"
flag "$LAB"; flag "$SM"
brief crew-local-optin

say "6. reread pointers queued for the secondmate (durable inbox records)"
for f in "$LAB/state/$ID.inbox"/*.msg "$LAB/state/$ID.inbox"/handled/*.msg; do
  [ -e "$f" ] || continue
  printf -- '--- %s\n' "$f"; cat "$f"; echo
done
for f in "$SM"/state/.fm-inherited-config-reread.*; do
  [ -f "$f" ] || continue
  printf -- '--- %s\n' "$f"; cat "$f"; echo
done
echo "=== [$LABEL] done ==="
