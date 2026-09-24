#!/usr/bin/env bash
# Behavior regression for the Claude task-worker launch and per-task skill delivery.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-lean)

make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake" claude)
  LAUNCH_LOG="$CASE_DIR/launch.log"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$LAUNCH_LOG"
}

spawn() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

make_case ship lean-ship-s1
out=$(spawn lean-ship-s1 "$PROJ_DIR" --mode direct-PR --yolo off)
expect_code 0 "$?" "Claude ship should launch: $out"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--setting-sources '' --strict-mcp-config --disable-slash-commands" "worker must exclude settings and discovery"
assert_contains "$launch" "--tools Read,Bash,Edit,Write --allowedTools Read,Bash,Edit,Write" "ship tool boundary"
assert_contains "$launch" "--model 'sonnet' --effort 'medium'" "ship defaults must be explicit"
assert_contains "$launch" "--settings '$HOME_DIR/state/lean-ship-s1.claude-settings.json'" "Firstmate hooks must still load"
assert_contains "$launch" "--append-system-prompt \"\$(cat '$ROOT/.pi/fm-worker-contract.md'" "worker contract must be appended"
pass "Claude ship excludes discovered settings, tools and skills but retains Firstmate hooks and contract"

make_case scout lean-scout-s2
mkdir -p "$CASE_DIR/skills/skill with spaces"
printf '%s\n' '# Scout skill' > "$CASE_DIR/skills/skill with spaces/SKILL.md"
out=$(spawn lean-scout-s2 "$PROJ_DIR" --scout --model opus --effort high --skill "$CASE_DIR/skills/skill with spaces")
expect_code 0 "$?" "Claude scout with a skill should launch: $out"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--tools Read,Bash --allowedTools Read,Bash" "scout should be read-only"
assert_not_contains "$launch" "--tools Read,Bash,Edit" "scout must not get write tools"
assert_contains "$launch" "--model 'opus' --effort 'high'" "requested model and effort"
assert_contains "$launch" "cat '$CASE_DIR/skills/skill with spaces/SKILL.md'" "explicit skill directory must be read"
assert_not_contains "$launch" "--skill " "Claude does not support a --skill flag"
cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --append-system-prompt ]; then
    printf '%s\n' "$2" > "$FM_FAKE_CLAUDE_PROMPT"
    break
  fi
  shift
done
SH
chmod +x "$FAKEBIN_DIR/claude"
FM_FAKE_CLAUDE_PROMPT="$CASE_DIR/delivered-prompt" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" >/dev/null \
  || fail "Claude scout launch did not execute with a synthetic skill"
assert_contains "$(cat "$CASE_DIR/delivered-prompt")" "# Scout skill" "skill content did not reach appended system prompt"
assert_contains "$(cat "$CASE_DIR/delivered-prompt")" "Stay within assigned task" "worker contract did not reach appended system prompt"
pass "Claude scout gets only read tools, explicit model/effort and requested skill content"

make_case auto lean-auto-s3
printf 'auto\n' > "$HOME_DIR/config/claude-permission-mode"
out=$(spawn lean-auto-s3 "$PROJ_DIR" --mode direct-PR --yolo off)
expect_code 0 "$?" "Claude auto worker should launch: $out"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--permission-mode auto" "auto permission mode must survive lean launch"
assert_contains "$launch" "--tools Read,Bash,Edit,Write" "auto mode still limits available tools"
assert_not_contains "$launch" "--allowedTools" "auto mode must not preapprove tools around its classifier"
pass "Claude auto posture restricts tools without bypassing classifier review"

make_case invalid lean-invalid-s4
out=$(spawn lean-invalid-s3 "$PROJ_DIR" --mode direct-PR --yolo off --skill "$CASE_DIR/missing.md" 2>&1)
expect_code 1 "$?" "missing skill must refuse"
assert_contains "$out" "does not exist" "missing skill refusal"
assert_absent "$HOME_DIR/state/lean-invalid-s3.meta" "invalid skill must not provision"
[ ! -s "$LAUNCH_LOG" ] || fail "invalid skill still launched"
pass "invalid Claude skill refuses before provisioning"

echo "all fm-spawn-claude-lean tests passed"
