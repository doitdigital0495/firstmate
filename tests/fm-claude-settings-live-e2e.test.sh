#!/usr/bin/env bash
# Opt-in live guard for the one vendor fact bin/fm-spawn.sh's claude branch rests on:
# `claude --settings <file>` loads hooks from a path OUTSIDE the workspace, and those
# hooks are MERGED with the project's own settings rather than replacing them.
#
# That is what lets firstmate arm per-task busy-state hooks without writing anything
# into the project worktree. A stub claude could only echo the assumption back, so
# this exercises the installed binary for real and fails naming its version.
set -u

if [ "${FM_CLAUDE_SETTINGS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_SETTINGS_LIVE_E2E=1 to run the live claude --settings guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v claude >/dev/null 2>&1 || fail "claude not found; this guard requires the installed binary"
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
[ -n "$CLAUDE_VERSION" ] || fail "installed claude did not answer --version"

LAB=$(fm_test_tmproot fm-claude-settings-live)
WORKSPACE="$LAB/workspace"
mkdir -p "$WORKSPACE/.claude"
git -C "$LAB" init -q "$WORKSPACE"

# The project's own committed settings, with content firstmate must never touch and
# a hook of its own that must keep firing.
cat > "$WORKSPACE/.claude/settings.local.json" <<JSON
{"env":{"FM_LIVE_PROJECT_KEY":"kept"},
 "hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$LAB/project-stop'"}]}]}}
JSON
PROJECT_BEFORE=$(cat "$WORKSPACE/.claude/settings.local.json")

# Firstmate's own settings, shaped like the file bin/fm-spawn.sh writes into state/.
cat > "$LAB/fm-settings.json" <<JSON
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"touch '$LAB/fm-submit'"}]}],
          "Stop":[{"hooks":[{"type":"command","command":"touch '$LAB/fm-stop'"}]}]}}
JSON

( cd "$WORKSPACE" && claude --dangerously-skip-permissions \
    --settings "$LAB/fm-settings.json" -p "reply with the single word ok" ) \
  > "$LAB/out" 2> "$LAB/err" < /dev/null \
  || fail "claude $CLAUDE_VERSION refused the --settings launch: $(cat "$LAB/err")"

[ -e "$LAB/fm-submit" ] \
  || fail "claude $CLAUDE_VERSION did not fire the UserPromptSubmit hook supplied through --settings"
[ -e "$LAB/fm-stop" ] \
  || fail "claude $CLAUDE_VERSION did not fire the Stop hook supplied through --settings"
[ -e "$LAB/project-stop" ] \
  || fail "claude $CLAUDE_VERSION let --settings REPLACE the project's own hooks instead of merging them"
[ "$(cat "$WORKSPACE/.claude/settings.local.json")" = "$PROJECT_BEFORE" ] \
  || fail "claude $CLAUDE_VERSION rewrote the project's settings file during the run"

pass "claude $CLAUDE_VERSION loads --settings hooks from outside the workspace and merges them with the project's own"
echo "all fm-claude-settings-live-e2e tests passed"
