#!/usr/bin/env bash
# PreToolUse guard that flags a worker's sleep-then-check turn.
#
# Every turn resends the worker's whole context, so a Bash call that only
# sleeps (`sleep 60`, `sleep 90 && gh pr checks 12`) and is followed by a
# separate checking turn costs a full context read for no work. A wait belongs in
# ONE blocking command that loops internally and prints only the final state
# (`until <condition>; do sleep 30; done`, `gh pr checks --watch`,
# `no-mistakes axi run --wait`), which the task brief's "Work economy" section
# already requires. This guard enforces that deterministically instead of
# relying on the worker remembering it.
#
# Flagged: a Bash command that runs `sleep N` (N >= FM_WAIT_GUARD_MIN_SECS,
# default 20) at a command position, outside any `until`/`while`/`for ... do ...
# done` loop. Allowed: short pacing sleeps, any sleep inside such a loop, and
# every other tool or command. The classification is a deliberate heuristic over
# the command text (no shell parsing, nothing is evaluated), so it only ever
# advises: it never replaces the shell command classifier owned by
# bin/fm-arm-command-policy.mjs.
#
# Usage:  <PreToolUse JSON on stdin> | bin/fm-wait-pretool-check.sh
#
# Modes (FM_WAIT_GUARD):
#   flag (default) - exit 0 and print a Claude PreToolUse additionalContext object
#                    on stdout naming the one-call wait; the command still runs.
#   deny           - exit 2 and print the same advice on stderr; the command is refused.
#   off            - allow everything silently.
# FM_WAIT_GUARD_LOG=<file>, when set, gets one `<epoch> <mode>` line per flagged
# command, so a weekly report can count them (tools/quota-weekly-report.py).
# FAIL OPEN: malformed or empty stdin, a missing jq, or a non-Bash tool is allowed.
set -u

MODE=${FM_WAIT_GUARD:-flag}
MIN=${FM_WAIT_GUARD_MIN_SECS:-20}
case "$MODE" in off) exit 0 ;; esac
case "$MIN" in ''|*[!0-9]*) MIN=20 ;; esac
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0
tool=$(printf '%s' "$input" | jq -r '.tool_name // .toolName // empty' 2>/dev/null) || exit 0
[ "$tool" = Bash ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // .toolInput.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# A loop that holds the sleep is the sanctioned one-call wait.
if printf '%s' "$cmd" | grep -Eq '(^|[;&|(]|[[:space:]])(until|while|for)[[:space:]].*(;|[[:space:]])do([[:space:]]|$)'; then
  exit 0
fi

# `sleep N` at a command position: start, after ; & | ( or a newline.
secs=
while IFS= read -r n; do
  [ -n "$n" ] || continue
  if [ "$n" -ge "$MIN" ] 2>/dev/null; then secs=$n; break; fi
done < <(printf '%s\n' "$cmd" | grep -Eo '(^|[;&|(])[[:space:]]*sleep[[:space:]]+[0-9]+' | grep -Eo '[0-9]+$')
[ -n "$secs" ] || exit 0

msg="Sleep-then-check turn (sleep $secs): every turn resends your whole context, so waiting across turns is expensive. Wait in ONE blocking command that loops internally and prints only the final state, for example \`until <condition>; do sleep 30; done\`, \`gh pr checks <pr> --watch\`, or \`no-mistakes axi run --wait\`, and pass the Bash tool its maximum timeout."

if [ -n "${FM_WAIT_GUARD_LOG:-}" ]; then
  printf '%s %s\n' "$(date +%s)" "$MODE" >> "$FM_WAIT_GUARD_LOG" 2>/dev/null || true
fi

if [ "$MODE" = deny ]; then
  printf '%s\n' "$msg" >&2
  exit 2
fi
jq -cn --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
exit 0
