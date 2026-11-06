#!/usr/bin/env bash
# Structural regression tests for agent skill registration and the trigger index.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-skill-registry-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-registry)

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected', got: $out"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

write_skill() {
  local repo=$1 dir=$2 name=$3 invocable=$4 description=$5
  mkdir -p "$repo/.agents/skills/$dir"
  printf -- '---\nname: %s\ndescription: %s\nuser-invocable: %s\nmetadata:\n  internal: true\n---\n\n# %s\n' \
    "$name" "$description" "$invocable" "$dir" > "$repo/.agents/skills/$dir/SKILL.md"
}

# A minimal valid registry: two agent-only skills (one with a folded
# description), one user-invocable skill, the index, and an AGENTS.md pointer.
make_fixture() {
  local repo=$1
  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  write_skill "$repo" alpha alpha false 'Load before alpha work.'
  mkdir -p "$repo/.agents/skills/beta"
  cat > "$repo/.agents/skills/beta/SKILL.md" <<'MD'
---
name: beta
description: >-
  Agent-only beta procedure.
  Load when beta reports.
user-invocable: false
---

# beta
MD
  write_skill "$repo" afk afk true 'Captain command.'
  write_skill "$repo" agent-skill-trigger-index agent-skill-trigger-index false \
    'Load only when auditing the trigger index.'
  cat >> "$repo/.agents/skills/agent-skill-trigger-index/SKILL.md" <<'MD'

- `alpha` - load before alpha work.
- `beta` - load when beta reports.
MD
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  printf '%s\n' 'Load `alpha` before alpha work, and load `/afk` when asked.' > "$repo/AGENTS.md"
  git -C "$repo" add -A
}

test_repository_registry_passes() {
  local out
  out=$("$CHECK") || fail "repository skill registry check failed: $out"
  assert_contains "$out" "fm-skill-registry-check: ok skills=" "check did not report its summary"
  pass "every tracked skill is well formed and every agent-only skill is indexed exactly once"
}

test_valid_fixture_passes() {
  local repo="$TMP_ROOT/valid" out
  make_fixture "$repo"
  out=$("$CHECK" --root "$repo") || fail "valid fixture rejected: $out"
  assert_contains "$out" "agent_only=2 indexed=2 agents_pointers=2" "fixture summary miscounted"
  pass "a valid fixture, including a folded description, passes"
}

test_unindexed_skill_fails() {
  local repo="$TMP_ROOT/unindexed"
  make_fixture "$repo"
  write_skill "$repo" gamma gamma false 'Load before gamma work.'
  git -C "$repo" add -A
  run_expect_failure "agent-only skill \`gamma\` is missing" "$CHECK" --root "$repo"
  pass "a new agent-only skill without a trigger-index entry fails"
}

test_index_entry_faults_fail() {
  local repo="$TMP_ROOT/index-faults" index
  make_fixture "$repo"
  index="$repo/.agents/skills/agent-skill-trigger-index/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  printf '%s\n' '- `alpha` - load again.' '- `ghost` - load for nothing.' '- `afk` - load on away.' \
    '- `beta` - see the skill.' >> "$index"
  git -C "$repo" add -A
  run_expect_failure "\`alpha\` is listed 2 times" "$CHECK" --root "$repo"
  run_expect_failure "\`ghost\` is not a tracked agent-only skill" "$CHECK" --root "$repo"
  run_expect_failure "\`afk\` is not a tracked agent-only skill" "$CHECK" --root "$repo"
  run_expect_failure "\`beta\` states no load trigger" "$CHECK" --root "$repo"
  pass "duplicate, dangling, user-invocable, and triggerless index entries fail"
}

test_malformed_front_matter_fails() {
  local repo="$TMP_ROOT/front-matter"
  make_fixture "$repo"
  write_skill "$repo" alpha alfa false 'Load before alpha work.'
  write_skill "$repo" beta beta maybe 'Load when beta reports.'
  mkdir -p "$repo/.agents/skills/delta"
  printf '%s\n' '# delta without front matter' > "$repo/.agents/skills/delta/SKILL.md"
  git -C "$repo" add -A
  run_expect_failure "name must equal its directory 'alpha'" "$CHECK" --root "$repo"
  run_expect_failure "user-invocable must be true or false, got 'maybe'" "$CHECK" --root "$repo"
  run_expect_failure "delta/SKILL.md: missing --- front matter" "$CHECK" --root "$repo"

  make_fixture "$repo"
  write_skill "$repo" alpha alpha false 'Agent-only alpha procedure.'
  git -C "$repo" add -A
  run_expect_failure "alpha/SKILL.md: agent-only description states no load trigger" "$CHECK" --root "$repo"
  pass "a wrong name, invocability value, missing front matter, or triggerless description fails"
}

test_dangling_agents_pointer_fails() {
  local repo="$TMP_ROOT/pointer"
  make_fixture "$repo"
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  printf '%s\n' 'Load `omega` before omega work.' >> "$repo/AGENTS.md"
  git -C "$repo" add -A
  run_expect_failure "AGENTS.md line 2: load pointer \`omega\` names no tracked skill" "$CHECK" --root "$repo"
  pass "an AGENTS.md load pointer to a missing skill fails"
}

test_repository_registry_passes
test_valid_fixture_passes
test_unindexed_skill_fails
test_index_entry_faults_fail
test_malformed_front_matter_fails
test_dangling_agents_pointer_fails
