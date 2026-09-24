#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --skill, the per-task skill passthrough to a
# lean Pi ship or scout launch.
#
# The fake tmux captures the literal launch command fm-spawn types, so these
# assertions pin the command a real worker would run without starting Pi.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-skill)

# make_case <name> <harness> <id> -> sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG
make_case() {
  local name=$1 harness=$2 id=$3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake" pi)
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  mkdir -p "$CASE_DIR/skills/seo-audit" "$CASE_DIR/skills/not-a-skill"
  printf '%s\n' '# seo-audit' > "$CASE_DIR/skills/seo-audit/SKILL.md"
  printf '%s\n' '# schema' > "$CASE_DIR/skills/schema.md"
  : > "$LAUNCH_LOG"
}

run_ship_spawn() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@" --mode direct-PR --yolo off
}

assert_refused_before_launch() {
  local out=$1 status=$2 id=$3 needle=$4 what=$5
  expect_code 1 "$status" "$what should refuse"
  assert_contains "$out" "$needle" "$what refusal did not name the offending input"
  assert_absent "$HOME_DIR/state/$id.meta" "$what refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "$what refusal still launched: $(cat "$LAUNCH_LOG")"
}

test_default_launch_is_unchanged() {
  local id=pi-skill-default-s1 out status launch contract expected
  make_case default pi "$id"
  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn without --skill should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  contract=$(cd "$ROOT" && pwd -P)/.pi/fm-worker-contract.md
  # shellcheck disable=SC2016
  expected='export COMPACT_ADVISER_DISABLE=1; if [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then herdr pane report-agent "$HERDR_PANE_ID" --source firstmate:pi --agent pi --state working --message "firstmate pi task worker starting" >/dev/null 2>&1 || true; fi; '
  expected+="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u PI_PROVIDER -u PI_MODEL -u PI_REASONING_LEVEL FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --no-context-files --no-skills --no-extensions -e '$HOME_DIR/user-home/.pi/agent/extensions/herdr-agent-state.ts' -e '$HOME_DIR/user-home/.pi/agent/extensions/rtk-compact.ts' -e '$HOME_DIR/state/$id.pi-ext.ts' --tools read,bash,edit,write --provider 'openai-codex' --model 'gpt-5.6-sol' --thinking 'medium' --append-system-prompt \"\$(cat '$contract')\" \"\$('$ROOT/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md')\""
  # shellcheck disable=SC2016
  expected+='; __fm_pi_rc=$?; if [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then if [ "$__fm_pi_rc" -eq 0 ]; then __fm_pi_st=idle; else __fm_pi_st=blocked; fi; herdr pane report-agent "$HERDR_PANE_ID" --source firstmate:pi --agent pi --state "$__fm_pi_st" --message "firstmate pi task worker exited rc=$__fm_pi_rc" >/dev/null 2>&1 || true; fi; unset __fm_pi_rc __fm_pi_st'
  assert_equals "$expected" "$launch" "pi launch without --skill changed shape"
  assert_not_contains "$launch" "--skill" "pi launch without --skill gained a skill flag"
  pass "a Pi worker launch without --skill keeps the exact lean command"
}

test_skills_reach_launch_in_order() {
  local id=pi-skill-order-s2 out status launch
  make_case order pi "$id"
  # The directory skill is relative to the caller, so it must reach the worker
  # absolute; the .md skill uses the --skill=<path> spelling.
  out=$(cd "$CASE_DIR" && run_ship_spawn "$id" "$PROJ_DIR" \
    --skill skills/seo-audit --skill="$CASE_DIR/skills/schema.md" --skill "$CASE_DIR/skills/seo-audit")
  status=$?
  expect_code 0 "$status" "pi spawn with valid skills should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--no-skills --skill '$CASE_DIR/skills/seo-audit' --skill '$CASE_DIR/skills/schema.md' --skill '$CASE_DIR/skills/seo-audit' --no-extensions" \
    "skills did not all reach the launch as absolute --skill paths in order"
  pass "directory and .md skills reach the Pi launch as --skill paths in the order given"
}

test_scout_takes_skills() {
  local id=pi-skill-scout-s3 out status
  make_case scout pi "$id"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --scout --skill "$CASE_DIR/skills/schema.md")
  status=$?
  expect_code 0 "$status" "pi scout with a skill should succeed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "--no-skills --skill '$CASE_DIR/skills/schema.md' --no-extensions" \
    "pi scout launch dropped its skill"
  pass "a Pi scout receives its skills too"
}

test_missing_path_refuses() {
  local id=pi-skill-missing-s4 out status
  make_case missing pi "$id"
  out=$(run_ship_spawn "$id" "$PROJ_DIR" --skill "$CASE_DIR/skills/seo-audit" --skill "$CASE_DIR/skills/nope")
  status=$?
  assert_refused_before_launch "$out" "$status" "$id" "--skill $CASE_DIR/skills/nope does not exist" "a nonexistent skill path"
  pass "a nonexistent skill path refuses before launch"
}

test_directory_without_skill_md_refuses() {
  local id=pi-skill-nomd-s5 out status
  make_case nomd pi "$id"
  out=$(run_ship_spawn "$id" "$PROJ_DIR" --skill "$CASE_DIR/skills/not-a-skill")
  status=$?
  assert_refused_before_launch "$out" "$status" "$id" "--skill $CASE_DIR/skills/not-a-skill is a directory without SKILL.md" "a directory without SKILL.md"
  pass "a directory without SKILL.md refuses before launch"
}

test_non_md_file_refuses() {
  local id=pi-skill-txt-s6 out status
  make_case txt pi "$id"
  printf 'x\n' > "$CASE_DIR/skills/notes.txt"
  out=$(run_ship_spawn "$id" "$PROJ_DIR" --skill "$CASE_DIR/skills/notes.txt")
  status=$?
  assert_refused_before_launch "$out" "$status" "$id" "--skill $CASE_DIR/skills/notes.txt is not a .md file" "a non-.md skill file"
  pass "a skill file that is not .md refuses before launch"
}

test_non_pi_harness_refuses() {
  local id=pi-skill-codex-s7 out status
  make_case codex codex "$id"
  out=$(run_ship_spawn "$id" "$PROJ_DIR" --skill "$CASE_DIR/skills/seo-audit")
  status=$?
  assert_refused_before_launch "$out" "$status" "$id" "resolved harness 'codex'" "--skill on a codex worker"
  pass "--skill on a harness without an equivalent refuses and names the harness"
}

test_secondmate_refuses() {
  local id=sm-pi-skill-s8 out status
  make_case secondmate pi "$id"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --secondmate --skill "$CASE_DIR/skills/seo-audit")
  status=$?
  assert_refused_before_launch "$out" "$status" "$id" "a --secondmate spawn has no lean worker launch" "--skill on a secondmate"
  pass "--skill on a --secondmate spawn refuses before any secondmate routing"
}

test_default_launch_is_unchanged
test_skills_reach_launch_in_order
test_scout_takes_skills
test_missing_path_refuses
test_directory_without_skill_md_refuses
test_non_md_file_refuses
test_non_pi_harness_refuses
test_secondmate_refuses

echo "# all fm-spawn-pi-skill tests passed"
