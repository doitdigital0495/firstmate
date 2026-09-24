#!/usr/bin/env bash
# Opt-in live guard for the vendor facts bin/fm-spawn.sh's claude branch rests on:
# `claude --settings <file>` loads hooks from a path OUTSIDE the workspace, those
# hooks are MERGED with the project's own settings rather than replacing them, and
# the file may carry firstmate's per-launch policy keys alongside them.
#
# That is what lets firstmate arm per-task busy-state hooks without writing anything
# into the project worktree. A stub claude could only echo the assumption back, so
# this exercises the installed binary for real and fails naming its version.
#
# The policy keys ride the SAME file because claude takes one settings source. That
# fold is the risk this guard covers: a settings file claude rejects would silently
# take the busy hooks down with it, so the payload here is the real shape fm-spawn
# writes rather than hooks alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_SETTINGS_LIVE_E2E claude git

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

# Firstmate's own settings, shaped like the file bin/fm-spawn.sh writes into state/:
# the per-launch policy keys and the busy-state hooks in one source.
cat > "$LAB/fm-settings.json" <<JSON
{"feedbackDrafts":"off",
 "attribution":{"commit":"","pr":"","sessionUrl":false},
 "hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"touch '$LAB/fm-submit'"}]}],
          "Stop":[{"hooks":[{"type":"command","command":"touch '$LAB/fm-stop'"}]}]}}
JSON

# Both permission flags config/claude-permission-mode can select ride the same
# settings file, so each must still load it.
for perm in --dangerously-skip-permissions '--permission-mode auto'; do
  rm -f "$LAB/fm-submit" "$LAB/fm-stop" "$LAB/project-stop"
  # shellcheck disable=SC2086 # $perm is one flag or a flag and its value
  ( cd "$WORKSPACE" && claude $perm \
      --settings "$LAB/fm-settings.json" -p "reply with the single word ok" ) \
    > "$LAB/out" 2> "$LAB/err" < /dev/null \
    || fail "claude $CLAUDE_VERSION refused the $perm --settings launch: $(cat "$LAB/err")"

  [ -e "$LAB/fm-submit" ] \
    || fail "claude $CLAUDE_VERSION ($perm) did not fire the UserPromptSubmit hook supplied through --settings"
  [ -e "$LAB/fm-stop" ] \
    || fail "claude $CLAUDE_VERSION ($perm) did not fire the Stop hook supplied through --settings"
  [ -e "$LAB/project-stop" ] \
    || fail "claude $CLAUDE_VERSION ($perm) let --settings REPLACE the project's own hooks instead of merging them"
  [ "$(cat "$WORKSPACE/.claude/settings.local.json")" = "$PROJECT_BEFORE" ] \
    || fail "claude $CLAUDE_VERSION ($perm) rewrote the project's settings file during the run"
  # The hooks above fired from a file that also carries the per-launch policy keys,
  # which is the whole point of folding them into one source. A settings file claude
  # could not read would take the hooks down with it, so any parse or validation
  # complaint about the settings source is a failure even when the run exits 0.
  ! grep -Eiq 'settings.*(invalid|could not|failed to (parse|read)|unrecognized)' "$LAB/err" \
    || fail "claude $CLAUDE_VERSION ($perm) complained about the settings source carrying the policy keys: $(cat "$LAB/err")"

  pass "claude $CLAUDE_VERSION ($perm) loads --settings from outside the workspace, merges its hooks with the project's own, and accepts the policy keys in the same file"
done

# A task worker excludes the user/project/local setting layers without --bare:
# --bare would also suppress Firstmate's explicitly loaded hooks and OAuth.
# Check the installed CLI rather than assuming an empty --setting-sources value
# means no settings; a skipped source could silently re-enable project hooks.
for perm in bypass auto; do
  rm -f "$LAB/fm-submit" "$LAB/fm-stop" "$LAB/project-stop"
  if [ "$perm" = bypass ]; then
    permission=(--dangerously-skip-permissions)
  else
    permission=(--permission-mode auto)
  fi
  ( cd "$WORKSPACE" && claude "${permission[@]}" \
      --setting-sources '' --strict-mcp-config --disable-slash-commands \
      --tools Read,Bash --model opus --effort medium \
      --settings "$LAB/fm-settings.json" \
      --append-system-prompt "$(cat "$ROOT/.pi/fm-worker-contract.md")" \
      -p "reply with the single word ok" ) \
    > "$LAB/out" 2> "$LAB/err" < /dev/null \
    || fail "claude $CLAUDE_VERSION refused the lean $perm launch: $(cat "$LAB/err")"
  [ -e "$LAB/fm-submit" ] && [ -e "$LAB/fm-stop" ] \
    || fail "claude $CLAUDE_VERSION disabled Firstmate hooks under lean $perm settings"
  [ ! -e "$LAB/project-stop" ] \
    || fail "claude $CLAUDE_VERSION ran project hooks despite empty --setting-sources ($perm)"
  pass "claude $CLAUDE_VERSION lean $perm worker runs only Firstmate hooks, not project hooks"
done
echo "all fm-claude-settings-live-e2e tests passed"
