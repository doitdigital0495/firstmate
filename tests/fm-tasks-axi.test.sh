#!/usr/bin/env bash
# Behavior tests for bin/fm-tasks-axi.sh home addressing and bootstrap's
# shadow-backlog check, over the split layout where the operational home lives
# outside the code root that carries the tracked .tasks.toml.
#
# The fork these guard against: .tasks.toml names data/backlog.md relative to
# the caller's working directory, and tasks-axi writes by renaming a temp file
# over its target, so a bare tasks-axi run from the code root turns a code-root
# symlink into the home's backlog into a private regular copy. The suite proves
# that every write through bin/fm-tasks-axi.sh lands in $FM_HOME/data from the
# code root (including archiving and relative --body-file arguments),
# that the command refuses addressing it cannot keep correct, and that bootstrap
# reports any code-root copy that is not this home's own file while staying
# silent for a link into the home, an absent copy, and the single-home layout.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The developer shell may pin any of these; each case states its own layout.
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

empty_backlog() {  # <path>
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

# A code root carrying the tracked .tasks.toml and an operational home beside
# it, with the code-root backlog linked into the home the way an operator
# would try to keep the two in sync.
make_split() {  # <name>; prints the case directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  fm_test_tasks_toml "$dir/code/.tasks.toml"
  empty_backlog "$dir/home/data/backlog.md"
  ln -s "$dir/home/data/backlog.md" "$dir/code/data/backlog.md"
  printf '%s\n' "$dir"
}

# Run the wrapper from the code root, as firstmate does.
wrapper_from_code() {  # <case-dir> <tasks-axi args...>
  local dir=$1
  shift
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "$@")
}

# Only the shadow-backlog lines matter here; the rest of a detect-only local
# bootstrap pass reports this host's toolchain, which is not under test, so it
# runs on the bare base PATH where every tool probe is a fast miss.
bootstrap_backlog_lines() {  # <code-root> [<home>]
  local code=$1 home=${2:-}
  if [ -n "$home" ]; then
    PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  else
    PATH="$BASE_PATH" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  fi
}

test_guard_reports_regular_code_root_backlog() {
  local dir out
  dir=$(make_split guard-regular)
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "a code-root link into this home must stay silent"

  rm "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "an absent code-root backlog must stay silent"

  printf '## In flight\n\n## Queued\n\n- [ ] stray: written from the code root\n\n## Done\n' \
    > "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "BACKLOG_RECONCILE: code-root $dir/code/data/backlog.md is not this home's $dir/home/data/backlog.md" \
    "a regular code-root backlog beside a separate home was not reported"
  assert_not_contains "$out" "done-archive.md" "an absent code-root archive was reported"
  pass "bootstrap reports a regular code-root backlog and stays silent for a link into the home or no copy"
}

test_guard_reports_foreign_link_and_archive() {
  local dir out
  dir=$(make_split guard-foreign)
  empty_backlog "$dir/elsewhere.md"
  rm "$dir/code/data/backlog.md"
  ln -s "$dir/elsewhere.md" "$dir/code/data/backlog.md"
  printf '## Done\n' > "$dir/code/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
    "a code-root backlog linked outside this home was not reported"
  assert_contains "$out" "code-root $dir/code/data/done-archive.md is not this home's $dir/home/data/done-archive.md" \
    "a regular code-root archive beside a separate home was not reported"
  pass "bootstrap reports a code-root backlog linked elsewhere and a forked archive"
}

test_guard_silent_for_single_home() {
  local dir out
  dir="$TMP_ROOT/single-guard"
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  printf '## Done\n' > "$dir/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir")
  assert_equals "" "$out" "the single-home layout's own backlog was reported as a fork"
  out=$(bootstrap_backlog_lines "$dir" "$dir")
  assert_equals "" "$out" "FM_HOME naming the code root was reported as a fork"
  pass "bootstrap stays silent when the code root is the home"
}

# The end-to-end fork: a bare tasks-axi write from the code root. Whatever the
# installed tasks-axi does to the link, bootstrap must agree with the result:
# a replaced link is reported, a written-through link is not.
test_bare_tasks_axi_fork_is_detected() {
  local dir out
  dir=$(make_split bare-fork)
  (cd "$dir/code" && tasks-axi add bare-1 "written from the code root" >/dev/null 2>&1) \
    || fail "bare tasks-axi add failed in the code root"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  if [ -L "$dir/code/data/backlog.md" ]; then
    assert_grep "bare-1" "$dir/home/data/backlog.md" "a written-through link lost the row"
    assert_equals "" "$out" "a written-through link was reported as a fork"
    pass "bare tasks-axi wrote through the code-root link and bootstrap stayed silent"
  else
    assert_no_grep "bare-1" "$dir/home/data/backlog.md" "the replaced link still reached the home"
    assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
      "bootstrap missed the fork a bare tasks-axi write left behind"
    pass "bare tasks-axi replaced the code-root link and bootstrap reported the fork"
  fi
}

test_wrapper_writes_through_to_home() {
  local dir i
  dir=$(make_split wrapper-home)
  for i in 1 2; do
    wrapper_from_code "$dir" add "ship-$i" "ship $i" >/dev/null || fail "add ship-$i failed"
    wrapper_from_code "$dir" start "ship-$i" >/dev/null || fail "start ship-$i failed"
    wrapper_from_code "$dir" "done" "ship-$i" >/dev/null || fail "done ship-$i failed"
  done
  wrapper_from_code "$dir" add call-1 "captain call" >/dev/null || fail "add call-1 failed"
  wrapper_from_code "$dir" hold call-1 --reason "awaiting the captain" --kind captain >/dev/null \
    || fail "hold call-1 failed"
  printf 'RELATIVE-BODY-MARKER\n' > "$dir/code/body.md"
  wrapper_from_code "$dir" update call-1 --body-file body.md >/dev/null \
    || fail "update with a caller-relative --body-file failed"
  wrapper_from_code "$dir" prune --keep 1 >/dev/null || fail "prune failed"

  [ -L "$dir/code/data/backlog.md" ] || fail "a wrapper write replaced the code-root link"
  [ "$dir/code/data/backlog.md" -ef "$dir/home/data/backlog.md" ] \
    || fail "the code-root link no longer names the home's backlog"
  assert_grep "call-1" "$dir/home/data/backlog.md" "the held row did not land in the home"
  assert_grep "RELATIVE-BODY-MARKER" "$dir/home/data/backlog.md" \
    "a caller-relative --body-file was not read from the caller's directory"
  assert_present "$dir/home/data/done-archive.md" "archiving did not reach the home"
  assert_grep "ship-1" "$dir/home/data/done-archive.md" "the oldest closed row was not archived in the home"
  assert_absent "$dir/code/data/done-archive.md" "archiving wrote a code-root archive"
  assert_equals "" "$(bootstrap_backlog_lines "$dir/code" "$dir/home")" \
    "bootstrap reported a fork after only wrapper writes"
  pass "fm-tasks-axi.sh writes, holds, archives, and reads relative body files through to the home from the code root"
}

test_wrapper_overrides_ambient_file() {
  local dir
  dir=$(make_split wrapper-ambient)
  empty_backlog "$dir/decoy.md"
  (cd "$dir/code" && TASKS_AXI_FILE="$dir/decoy.md" FM_HOME="$dir/home" "$WRAPPER" add amb-1 "ambient" >/dev/null) \
    || fail "add under an ambient TASKS_AXI_FILE failed"
  assert_grep "amb-1" "$dir/home/data/backlog.md" "an ambient TASKS_AXI_FILE diverted the write from the home"
  assert_no_grep "amb-1" "$dir/decoy.md" "an ambient TASKS_AXI_FILE received the write"
  wrapper_from_code "$dir" >/dev/null || fail "the no-command dashboard failed"
  pass "fm-tasks-axi.sh pins the home's backlog over an ambient TASKS_AXI_FILE and serves the dashboard"
}

test_wrapper_refusals() {
  local dir out rc before
  dir=$(make_split wrapper-refuse)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add r-1 "explicit" --file "$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file"
  assert_contains "$out" "drop --file" "--file refusal did not explain itself"
  out=$(wrapper_from_code "$dir" list --file="$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file="

  mv "$dir/home/data/backlog.md" "$dir/home/real-backlog.md"
  ln -s "$dir/home/real-backlog.md" "$dir/home/data/backlog.md"
  out=$(wrapper_from_code "$dir" add r-2 "through a link" 2>&1)
  rc=$?
  expect_code 2 "$rc" "symlinked home backlog"
  assert_contains "$out" "is a symlink" "the symlinked home backlog refusal did not name the link"
  [ -L "$dir/home/data/backlog.md" ] || fail "a refused call still replaced the home link"
  assert_equals "$before" "$(cat "$dir/home/real-backlog.md")" "a refused call changed the backlog"

  out=$(cd "$dir/code" && FM_HOME="$dir/missing-home" "$WRAPPER" list 2>&1)
  rc=$?
  expect_code 2 "$rc" "missing data directory"
  pass "fm-tasks-axi.sh refuses caller --file, a symlinked home backlog, and an unresolvable home"
}

# Dispatch alone moves a row to In flight, because only bin/fm-spawn.sh
# creates the task record, status file, and inbox that go with it; a row
# hand-placed there through `add --start` would count as live work nobody runs.
test_wrapper_refuses_add_start() {
  local dir out rc before
  dir=$(make_split wrapper-add-start)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add hs-1 "hand-started" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "add --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the add --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused add --start still wrote a row"
  out=$(wrapper_from_code "$dir" create hs-c "hand-started via alias" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "create --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the create --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused create --start still wrote a row"
  wrapper_from_code "$dir" add hs-2 "queued" >/dev/null || fail "plain add was refused"
  assert_grep "hs-2" "$dir/home/data/backlog.md" "plain add did not write its row"
  wrapper_from_code "$dir" start hs-2 >/dev/null || fail "start <id> was refused"
  pass "fm-tasks-axi.sh refuses add --start while plain add and start <id> pass through"
}

test_wrapper_single_home() {
  local dir
  dir="$TMP_ROOT/single-wrapper"
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  (cd "$dir" && FM_ROOT_OVERRIDE="$dir" "$WRAPPER" add solo-1 "single home" >/dev/null) \
    || fail "add in the single-home layout failed"
  assert_grep "solo-1" "$dir/data/backlog.md" "the single-home layout lost its own backlog write"
  pass "fm-tasks-axi.sh keeps the single-home layout addressing its own code-root backlog"
}

# The unstarted-row lapse. One home carries every kind of row the lapse must
# keep or close, proving by the wrapper's own output and the backlog file which
# rows move, that nothing moves without config/record-sweep=on, and that a
# close touches no other Done row.
lapse_home() {  # <name>; prints the home directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/data" "$dir/state" "$dir/config" "$dir/projects/r1"
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  git -C "$dir/projects/r1" init -q
  git -C "$dir/projects/r1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

lapse_wrapper() {  # <home> <args...>
  local dir=$1
  shift
  (cd "$dir" && FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$WRAPPER" "$@")
}

lapse_since() {  # <home> <id> <YYYY-MM-DD>
  sed -i.bak "s/^\(- \[ \] $2 .*(since \)[0-9-]*)/\1$3)/" "$1/data/backlog.md" && rm -f "$1/data/backlog.md.bak"
}

lapse_days_ago() {  # <days>
  date -u -d "$1 days ago" +%F 2>/dev/null || date -u -v-"$1"d +%F
}

done_section() {  # <home>
  sed -n '/^## Done/,$p' "$1/data/backlog.md"
}

test_lapse_due_and_close() {
  local dir out old goal_items before after id
  dir=$(lapse_home lapse)
  old=2020-01-01
  for id in due-1 edge-1 young-1 held-1 blk-1 meta-1 stat-1 data-1 br-1 wt-1 remote-1 goal-on-1 goal-off-1 dep-1; do
    lapse_wrapper "$dir" add "$id" "row $id, with a comma" --repo r1 >/dev/null || fail "add $id"
    lapse_since "$dir" "$id" "$old"
  done
  lapse_wrapper "$dir" add norepo-1 "no repo" >/dev/null
  lapse_wrapper "$dir" add noclone-1 "no clone" --repo missing >/dev/null
  lapse_wrapper "$dir" add mate-1 "standing" --repo r1 --kind secondmate >/dev/null
  lapse_wrapper "$dir" add cap-1 "captain question" --repo r1 --kind captain >/dev/null
  for id in norepo-1 noclone-1 mate-1 cap-1; do lapse_since "$dir" "$id" "$old"; done
  lapse_since "$dir" young-1 "$(lapse_days_ago 13)"
  lapse_since "$dir" edge-1 "$(lapse_days_ago 14)"
  lapse_wrapper "$dir" hold held-1 --reason "waiting, for someone" --kind captain >/dev/null || fail "hold"
  lapse_wrapper "$dir" block blk-1 --by dep-1 >/dev/null || fail "block"
  : > "$dir/state/meta-1.meta"
  : > "$dir/state/stat-1.status"
  mkdir "$dir/data/data-1"
  git -C "$dir/projects/r1" branch "fm/br-1"
  git -C "$dir/projects/r1" worktree add -q --detach "$dir/pool/wt-1"
  git -C "$dir/projects/r1" update-ref refs/remotes/origin/fm/remote-1 HEAD
  goal_items="$dir/items"
  printf '%s\n' 'item [id=a] [owner=main] [task=goal-on-1]: linked step' > "$goal_items"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$ROOT/bin/fm-goal.sh" start G1 --title t --done-when d --named-by n \
    --plan plan.md --items-file "$goal_items" >/dev/null 2>&1 || fail "goal start G1"
  printf '%s\n' 'item [id=a] [owner=main] [task=goal-off-1]: linked to a paused goal' > "$goal_items"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$ROOT/bin/fm-goal.sh" start G2 --title t --done-when d --named-by n \
    --plan plan.md --items-file "$goal_items" >/dev/null 2>&1 || fail "goal start G2"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$ROOT/bin/fm-goal.sh" pause G2 >/dev/null || fail "goal pause G2"
  for id in dn-1 dn-2 dn-3; do
    lapse_wrapper "$dir" add "$id" "finished $id" >/dev/null || fail "add $id"
    lapse_wrapper "$dir" 'done' "$id" >/dev/null || fail "done $id"
  done

  out=$(lapse_wrapper "$dir" lapse-due) || fail "lapse-due failed"
  assert_equals "$(printf 'due-1\t%s\tr1\nedge-1\t%s\tr1\ngoal-off-1\t%s\tr1\ndep-1\t%s\tr1\nlapse mode=shadow due=4 closed=0' \
    "$old" "$(lapse_days_ago 14)" "$old" "$old")" "$out" \
    "lapse-due must list exactly the unheld, unblocked, old, never-started, unlinked rows"

  before=$(cat "$dir/data/backlog.md")
  out=$(lapse_wrapper "$dir" lapse) || fail "shadow lapse failed"
  assert_contains "$out" "would-lapse	due-1	$old	r1" "shadow lapse did not list the due row"
  assert_contains "$out" "lapse mode=shadow due=4 closed=0" "shadow lapse closed something or miscounted"
  assert_equals "$before" "$(cat "$dir/data/backlog.md")" "an absent record-sweep switch must leave the backlog untouched"
  printf 'on\n' > "$dir/real-switch"
  ln -s "$dir/real-switch" "$dir/config/record-sweep"
  out=$(lapse_wrapper "$dir" lapse) || fail "symlinked switch lapse failed"
  assert_contains "$out" "lapse mode=shadow" "a symlinked record-sweep switch must stay shadow"
  assert_equals "$before" "$(cat "$dir/data/backlog.md")" "a symlinked switch must leave the backlog untouched"
  rm "$dir/config/record-sweep"
  printf 'shadow\n' > "$dir/config/record-sweep"
  lapse_wrapper "$dir" lapse >/dev/null
  assert_equals "$before" "$(cat "$dir/data/backlog.md")" "record-sweep=shadow must leave the backlog untouched"

  printf 'on\n' > "$dir/config/record-sweep"
  before=$(done_section "$dir")
  out=$(lapse_wrapper "$dir" lapse) || fail "lapse with record-sweep=on failed"
  assert_contains "$out" "lapse mode=on due=4 closed=4" "an on lapse did not close the four due rows"
  after=$(done_section "$dir")
  assert_contains "$after" "due-1" "the lapsed row did not reach Done"
  assert_contains "$after" "lapsed unstarted" "the lapse note is missing from Done"
  for id in dn-1 dn-2 dn-3; do
    assert_contains "$after" "$id" "the earlier Done row $id was lost"
  done
  assert_equals "$(printf '%s\n' "$before" | grep -c '^- \[x\]')" 3 "fixture should start with three Done rows"
  assert_equals "$(printf '%s\n' "$after" | grep -c '^- \[x\]')" 7 "exactly the four due rows should join Done"
  assert_equals "$(printf '%s\n' "$before" | grep '^- \[x\]')" \
    "$(printf '%s\n' "$after" | grep '^- \[x\]' | grep -F -e dn-1 -e dn-2 -e dn-3)" "an earlier Done row changed"
  out=$(lapse_wrapper "$dir" list --state queued)
  for id in young-1 held-1 blk-1 meta-1 stat-1 data-1 br-1 wt-1 remote-1 goal-on-1 norepo-1 noclone-1 mate-1 cap-1; do
    assert_contains "$out" "$id" "$id must stay Queued"
  done
  for id in due-1 edge-1 dep-1 goal-off-1; do
    assert_not_contains "$out" "$id," "$id should have left Queued"
  done
  out=$(lapse_wrapper "$dir" lapse-due) || fail "second lapse-due failed"
  assert_equals "$(printf 'blk-1\t%s\tr1\nlapse mode=on due=1 closed=0' "$old")" "$out" \
    "only the row whose blocker just closed should become due on the next run"
  pass "lapse closes only the due rows, gated by record-sweep=on, and leaves other Done rows alone"
}

test_lapse_single_row_leaves_done_untouched() {
  local dir out before after
  dir=$(lapse_home lapse-one)
  printf 'on\n' > "$dir/config/record-sweep"
  lapse_wrapper "$dir" add keep-1 "earlier close" >/dev/null || fail "add keep-1"
  lapse_wrapper "$dir" 'done' keep-1 --note "kept note" >/dev/null || fail "done keep-1"
  lapse_wrapper "$dir" add only-1 "the one" --repo r1 >/dev/null
  lapse_since "$dir" only-1 2020-01-01
  before=$(done_section "$dir")
  out=$(lapse_wrapper "$dir" lapse) || fail "lapse failed"
  assert_contains "$out" "lapsed	only-1" "the due row was not closed"
  after=$(done_section "$dir")
  assert_equals "$(printf '> - [x] only-1 - the one (repo: r1) (done %s)\n>   lapsed unstarted' "$(date -u +%F)")" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '^>')" "the lapse must add exactly one Done row with its note"
  assert_equals 0 "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -c '^<')" "an existing Done line changed or vanished"
  assert_contains "$after" "kept note" "the earlier Done note was lost"
  assert_equals "" "$([ -s "$dir/data/done-archive.md" ] && cat "$dir/data/done-archive.md")" "a lapse below the keep value must archive nothing"
  pass "lapse moves exactly one row and leaves the rest of Done untouched"
}

test_lapse_queue_limit_line() {
  local dir out i
  dir=$(lapse_home lapse-limit)
  for i in $(seq 1 31); do
    lapse_wrapper "$dir" add "hold-$i" "held $i" --repo r1 >/dev/null
    lapse_wrapper "$dir" hold "hold-$i" --reason "waiting" --kind captain >/dev/null
  done
  out=$(lapse_wrapper "$dir" lapse-due) || fail "lapse-due failed"
  assert_contains "$out" "queued-over-limit queued=31 limit=30" "31 queued rows must report the over-limit line"
  lapse_wrapper "$dir" add due-1 "old" --repo r1 >/dev/null
  lapse_since "$dir" due-1 2020-01-01
  out=$(lapse_wrapper "$dir" lapse-due)
  assert_contains "$out" "queued-over-limit queued=31 limit=30" "the shadow count must exclude the row it would close"
  lapse_wrapper "$dir" unhold hold-1 >/dev/null
  lapse_wrapper "$dir" 'done' hold-1 >/dev/null
  out=$(lapse_wrapper "$dir" lapse-due)
  assert_not_contains "$out" "queued-over-limit" "30 queued rows after the lapse must not report"
  pass "lapse reports one over-limit line only while the home would still exceed 30 queued rows"
}

test_lapse_unreadable_history_closes_nothing() {
  local dir out rc=0
  dir=$(lapse_home lapse-fail)
  printf 'on\n' > "$dir/config/record-sweep"
  lapse_wrapper "$dir" add old-1 "old" --repo r1 >/dev/null
  lapse_since "$dir" old-1 2020-01-01
  # bin/fm-goal.sh refuses a symlinked goal directory, so the link view is unreadable.
  mkdir -p "$dir/elsewhere" "$dir/state"
  ln -s "$dir/elsewhere" "$dir/state/goals"
  out=$(lapse_wrapper "$dir" lapse 2>&1) || rc=$?
  expect_code 1 "$rc" "lapse with an unreadable goal view"
  assert_contains "$out" "nothing lapses" "an unreadable goal view must say nothing lapses"
  assert_not_contains "$out" "lapsed" "an unreadable goal view must close nothing"
  assert_equals 1 "$(grep -c '^- \[ \] old-1 ' "$dir/data/backlog.md")" "a failed read changed the backlog"
  rc=0
  out=$(lapse_wrapper "$dir" lapse-due extra 2>&1) || rc=$?
  expect_code 2 "$rc" "lapse-due with an argument"
  assert_contains "$out" "takes no arguments" "lapse-due must refuse arguments"
  pass "lapse refuses arguments and closes nothing when it cannot read the goal links"
}

test_guard_reports_regular_code_root_backlog
test_guard_reports_foreign_link_and_archive
test_guard_silent_for_single_home
if [ "$HAVE_TASKS_AXI" = 1 ]; then
  test_bare_tasks_axi_fork_is_detected
  test_wrapper_writes_through_to_home
  test_wrapper_overrides_ambient_file
  test_wrapper_refusals
  test_wrapper_refuses_add_start
  test_wrapper_single_home
  test_lapse_due_and_close
  test_lapse_single_row_leaves_done_untouched
  test_lapse_queue_limit_line
  test_lapse_unreadable_history_closes_nothing
else
  echo "skip: tasks-axi not found; home-addressing cases not run"
fi
