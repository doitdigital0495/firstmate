#!/usr/bin/env bash
# Behavior tests for the advisory sleep-then-check PreToolUse guard
# (bin/fm-wait-pretool-check.sh): which Bash commands it flags, the flag and
# deny modes, the flag log, and fail-open on anything it cannot read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CHECK="$ROOT/bin/fm-wait-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-wait-pretool-tests)
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

# run_check <tool> <command> [env assignments...]; sets RC, OUT, ERR.
run_check() {
  local tool=$1 cmd=$2
  shift 2
  jq -cn --arg t "$tool" --arg c "$cmd" '{tool_name: $t, tool_input: {command: $c}}' \
    | env "$@" "$CHECK" > "$OUT" 2> "$ERR"
  RC=$?
}

flagged() {  # <command> [env...]: asserts the command is flagged in flag mode
  run_check Bash "$1" "${@:2}"
  [ "$RC" -eq 0 ] || fail "flag mode must not block '$1' (exit $RC)"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | test("ONE blocking command"))' "$OUT" >/dev/null \
    || fail "'$1' was not flagged with the one-call wait advice: $(cat "$OUT")"
}

allowed() {  # <command> [env...]
  run_check Bash "$1" "${@:2}"
  [ "$RC" -eq 0 ] || fail "'$1' must be allowed (exit $RC)"
  [ ! -s "$OUT" ] || fail "'$1' must produce no output: $(cat "$OUT")"
}

flagged 'sleep 60'
flagged 'sleep 90 && gh pr checks 12'
flagged 'git push; sleep 120; gh pr view 3'
flagged $'echo start\nsleep 45\ngh pr checks 7'

allowed 'sleep 5'
allowed 'sleep 19 && echo ok'
allowed 'until gh pr checks 12 | grep -q pass; do sleep 30; done'
allowed 'while ! test -f /tmp/x; do sleep 60; done; echo done'
allowed 'for i in 1 2 3; do sleep 30; done'
allowed 'gh pr checks 12 --watch'
allowed 'echo "sleeping later"'
allowed 'ls -la'

# A non-Bash tool, empty stdin, and malformed stdin all fail open.
run_check Read 'sleep 60'
[ "$RC" -eq 0 ] && [ ! -s "$OUT" ] || fail "a non-Bash tool must be allowed silently"
if ! printf '' | "$CHECK" > "$OUT" 2> "$ERR" || [ -s "$OUT" ]; then fail "empty stdin must fail open"; fi
if ! printf 'not json' | "$CHECK" > "$OUT" 2> "$ERR" || [ -s "$OUT" ]; then fail "malformed stdin must fail open"; fi

# The threshold is configurable.
flagged 'sleep 10' FM_WAIT_GUARD_MIN_SECS=5
allowed 'sleep 60' FM_WAIT_GUARD_MIN_SECS=120

# deny mode refuses with exit 2 and the advice on stderr; off allows everything.
run_check Bash 'sleep 60' FM_WAIT_GUARD=deny
[ "$RC" -eq 2 ] || fail "deny mode must exit 2, got $RC"
grep -q 'ONE blocking command' "$ERR" || fail "deny mode must explain on stderr: $(cat "$ERR")"
[ ! -s "$OUT" ] || fail "deny mode must keep stdout empty for Claude"
allowed 'sleep 60' FM_WAIT_GUARD=off

# The flag log gets one line per flagged command and none for allowed ones.
LOG="$TMP_ROOT/wait-flags"
run_check Bash 'sleep 60' FM_WAIT_GUARD_LOG="$LOG"
run_check Bash 'until true; do sleep 60; done' FM_WAIT_GUARD_LOG="$LOG"
[ "$(wc -l < "$LOG")" -eq 1 ] || fail "expected exactly one flag-log line, got: $(cat "$LOG")"
grep -Eq '^[0-9]+ flag$' "$LOG" || fail "flag-log line is not '<epoch> flag': $(cat "$LOG")"

pass "fm-wait-pretool-check.sh flags sleep-then-check commands, allows loops and short sleeps, supports deny and off, and fails open"
echo "all fm-wait-pretool-check tests passed"
