#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
BRIEF_SCAFFOLD="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# Scaffold a real ship brief through fm-brief.sh and fill its {TASK} placeholder,
# so the case runs against the definition of done a worker is actually handed.
scaffold_brief() {  # <home> <id> <mode> <task-text>
  local home=$1 id=$2 mode=$3 task=$4 brief tmp
  brief="$home/data/$id/brief.md"
  rm -rf "$home/data/$id"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$BRIEF_SCAFFOLD" "$id" proj --mode "$mode" >/dev/null \
    || fail "scaffolding a $mode brief for $id failed"
  tmp="$brief.filled"
  awk -v repl="$task" '$0 == "{TASK}" { print repl; next } { print }' "$brief" > "$tmp"
  mv "$tmp" "$brief"
  grep -q '{TASK}' "$brief" && fail "$id: the task placeholder was never filled"
  printf '%s\n' "$brief"
}

# The 2026-08-22 failure: a task text that forbids the push and the PR, inside a
# brief whose generated definition of done mandates both. The generated section is
# what the worker follows, so three workers opened PRs the captain had not
# approved. A push mode must now refuse that brief before anything is created,
# while local-only - whose contract already stops at a reviewable branch - takes
# the same task text and launches.
test_spawn_refuses_a_brief_that_contradicts_its_own_delivery() {
  local rec home proj fakebin label mode task expect quote out status n=0
  rec=$(make_home contradiction)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  # The delivery checks run before any backend call, so the first thing this fake
  # tmux prints is proof that a launching row got past them. Without it a row
  # could pass vacuously on a spawn that stopped even earlier.
  printf '#!/bin/sh\necho DELIVERY_CHECKS_CLEARED >&2\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  while IFS='|' read -r label mode task expect quote; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    scaffold_brief "$home" "delivery-contra-$n" "$mode" "Do the work and verify it in the running app.

$task" >/dev/null
    out=$(run_spawn "$home" "$fakebin" "delivery-contra-$n" "$proj" claude --mode "$mode" --yolo off)
    status=$?
    case "$expect" in
      refuse)
        [ "$status" -ne 0 ] || fail "$label: a contradictory brief should exit non-zero"
        assert_contains "$out" "contradictory brief for delivery-contra-$n" \
          "$label: refusal did not name the task"
        assert_contains "$out" "$quote" \
          "$label: refusal did not quote the task line it read as forbidding delivery"
        assert_contains "$out" "--mode local-only" "$label: refusal did not name the mode that fits this stop point"
        assert_absent "$home/state/delivery-contra-$n.meta" "$label: refused spawn wrote task metadata"
        assert_not_contains "$out" "DELIVERY_CHECKS_CLEARED" \
          "$label: a refused spawn still reached the backend" ;;
      launch)
        assert_not_contains "$out" "contradictory brief" "$label: a brief that agrees with its mode was refused"
        assert_contains "$out" "DELIVERY_CHECKS_CLEARED" \
          "$label: the spawn never reached the backend, so the row proves nothing" ;;
    esac
  done <<'ROWS'
the 2026-08-22 stop point shipped direct-PR|direct-PR|- Do NOT push and do NOT open a PR. The captain approves that himself after his own QA.|refuse|Do NOT push and do NOT open a PR
the 2026-08-22 stop point shipped no-mistakes|no-mistakes|- Do NOT push and do NOT open a PR. The captain approves that himself after his own QA.|refuse|Do NOT push and do NOT open a PR
the same stop point shipped local-only|local-only|- Do NOT push and do NOT open a PR. The captain approves that himself after his own QA.|launch|
a refusal buried mid-line|no-mistakes|5. Commit the branch and stop. Do not invoke no-mistakes, push, or open a PR without captain approval.|refuse|Do not invoke no-mistakes, push, or open a PR
the PR refused without naming the push|direct-PR|- Never open a pull request; the captain reviews the running preview first.|refuse|Never open a pull request
the push refused without naming the PR|direct-PR|- Never push this branch; leave the dev server running for the captain's QA.|refuse|Never push this branch
the push refused without an explicit object|direct-PR|- Do not push anything.|refuse|Do not push anything
the refusal written as a gerund|direct-PR|- No pushing and no PR until the captain approves.|refuse|No pushing and no PR
both actions refused across a comma|direct-PR|- Do not push, do not open a PR. The captain approves after his own QA.|refuse|Do not push, do not open a PR
the push refused with a natural stop word|direct-PR|- Do not push yet.|refuse|Do not push yet
the PR refused with a natural stop word|no-mistakes|- No PR yet; the captain reviews first.|refuse|No PR yet
a push named as a noun the captain owns|direct-PR|- Do not worry about the push; the captain handles it.|launch|
an enumeration of transports the harness bans|direct-PR|- No push, no pull, no fetch in the test harness.|launch|
a push feature described with an appositive|direct-PR|- No user-visible push, the sync is silent.|launch|
a guard against writing a pushing command|direct-PR|- Do not add a command that can push, it is unsafe.|launch|
a release step that must not run twice|direct-PR|- Do not let the release push, or the deploy, run twice.|launch|
a filename that happens to read as a PR|direct-PR|- Do not name the file PR.md.|launch|
a queue push in the analytics layer|direct-PR|- Do not push to the analytics queue on every keystroke.|launch|
a publish step banned for a package registry|direct-PR|- Never push to npm from CI.|launch|
an array push|direct-PR|- Do not push it to the array; use concat.|launch|
a dataLayer push|direct-PR|- Do not push this event to the dataLayer.|launch|
state pushed into the URL|direct-PR|- Do not push any state into the URL.|launch|
a layout pushed off screen|direct-PR|- Do not push the modal off screen on mobile.|launch|
a stack pushed and popped|direct-PR|- Do not push and pop the same stack twice.|launch|
a bounded push to a content network|direct-PR|- Do not push anything to the CDN.|launch|
a bounded push to a deploy target|direct-PR|- Do not push anything to production without captain approval.|launch|
a bounded push into a client-side store|direct-PR|- Do not push anything into the global store.|launch|
a push sequenced behind an animation|direct-PR|- Do not push until the animation finishes.|launch|
a push sequenced behind a queue|direct-PR|- Do not push until the queue drains.|launch|
a cache whose name opens with a forge word|direct-PR|- Do not push to the repo cache on read.|launch|
a cache whose name opens with a forge host|direct-PR|- Do not push to github actions cache.|launch|
a PR-shaped noun popped off a stack|direct-PR|- Do not push or pop the PR badge.|launch|
a PR opened for someone other than delivery|direct-PR|- Do not open a PR for the mobile team.|launch|
the stop word carried into the hold clause|direct-PR|- Do not push anything yet; wait for captain approval.|refuse|Do not push anything yet
the push refused with a bare clause end|direct-PR|- Do not push; the captain reviews the branch himself.|refuse|Do not push
both actions refused across or|direct-PR|- Do not push or ever open a pull request without captain approval.|refuse|Do not push or ever open a pull request
the changes named as the object|direct-PR|- Do not push the changes; the captain reviews them first.|refuse|Do not push the changes
the commits named as the object|direct-PR|- Never push your commits until the captain approves.|refuse|Never push your commits
the remote named as the target|direct-PR|- Do not push to the remote.|refuse|Do not push to the remote
origin named as the target|direct-PR|- Do not push to origin.|refuse|Do not push to origin
the fork named as the target|no-mistakes|- Never push to the fork.|refuse|Never push to the fork
the repository named as the target|direct-PR|- Do not push to the repository.|refuse|Do not push to the repository
GitHub named as the target|direct-PR|- Do not push to GitHub.|refuse|Do not push to GitHub
GitLab named as the target|direct-PR|- Do not push to GitLab.|refuse|Do not push to GitLab
Bitbucket named as the target|direct-PR|- Do not push to Bitbucket.|refuse|Do not push to Bitbucket
the stop point followed by ordinary sequencing|direct-PR|- Do NOT push and do NOT open a PR. Run the tests, then create a summary in the status file.|refuse|Do NOT push and do NOT open a PR
the stop point followed by opening the preview|no-mistakes|- Do NOT push and do NOT open a PR. Start the dev server, then open the preview for the captain.|refuse|Do NOT push and do NOT open a PR
the refusal carrying its own subject|direct-PR|You cannot push until the captain signs off on the preview.|refuse|You cannot push until the captain
ordinary work that discusses its own PR|direct-PR|If the re-encode misses the budget, fall back to option A and say so plainly in the PR body.|launch|
the push bounded to the default branch|direct-PR|Never push to the default branch, and do not merge the PR yourself.|launch|
history rewriting refused, delivery not|direct-PR|- Do not force-push, do not rewrite history, do not discard any unlanded work.|launch|
prose describing a no-push stop point|no-mistakes|Reproduce the failure: scaffold a task whose stop point is a running preview with no push or PR.|launch|
a ban scoped to what may be pushed|direct-PR|- Do not push secrets or .env files to the remote.|launch|
push naming an unrelated product feature|direct-PR|- No push notifications in this milestone; skip the service worker.|launch|
a sequencing condition that permits the PR|direct-PR|- Do not push until the tests are green, then open the PR as usual.|launch|
a PR routed at a specific target|direct-PR|Do not open a PR against upstream; open it against the fork.|launch|
a ban scoped to a PR-related file|direct-PR|- Do not create a PR template file.|launch|
ROWS
  pass "fm-spawn: a push mode refuses a brief whose task text forbids the push or the PR"
}

# A safety classifier must fail closed. grep exit 1 (no match) and grep exit >1
# (a matcher that cannot compile this pattern, or is missing) used to be
# indistinguishable, so a brief carrying the 2026-08-22 contradiction launched
# silently whenever the matcher itself could not answer.
test_spawn_refuses_when_the_delivery_matcher_cannot_run() {
  local rec home proj fakebin real out status
  rec=$(make_home matcher)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  printf '#!/bin/sh\necho DELIVERY_CHECKS_CLEARED >&2\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  real=$(command -v grep) || fail "no grep on PATH to delegate to"
  cat > "$fakebin/grep" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in *'pull[[:space:]]+request'*) echo 'grep: unsupported regular expression' >&2; exit 2 ;; esac
done
exec $real "\$@"
EOF
  chmod +x "$fakebin/grep"

  scaffold_brief "$home" delivery-matcher-e1 direct-PR "Do the work and verify it in the running app.

- Do NOT push and do NOT open a PR. The captain approves that himself after his own QA." >/dev/null
  out=$(run_spawn "$home" "$fakebin" delivery-matcher-e1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose delivery matcher failed should exit non-zero"
  assert_contains "$out" "cannot check the brief for delivery-matcher-e1" \
    "the refusal did not name the matcher failure"
  assert_absent "$home/state/delivery-matcher-e1.meta" "a matcher-failure refusal wrote task metadata"
  assert_not_contains "$out" "DELIVERY_CHECKS_CLEARED" \
    "a matcher-failure refusal still reached the backend"
  pass "fm-spawn: a delivery matcher that cannot run refuses the spawn instead of launching it"
}

# The other half of the guarantee: the modes themselves still say what they always
# said, so refusing the contradiction did not quietly disarm ordinary delivery.
test_generated_definitions_of_done_keep_their_stop_points() {
  local rec home proj fakebin brief
  rec=$(make_home stop-points)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  brief=$(scaffold_brief "$home" delivery-stop-e1 direct-PR 'Ordinary work.')
  assert_grep 'push your branch and open a PR' "$brief" \
    "direct-PR no longer tells the worker to push and open the PR itself"

  brief=$(scaffold_brief "$home" delivery-stop-e2 local-only 'Ordinary work.')
  assert_grep 'Do NOT push, do NOT open a PR' "$brief" \
    "local-only no longer stops the worker before the remote"

  brief=$(scaffold_brief "$home" delivery-stop-e3 no-mistakes 'Ordinary work.')
  assert_grep 'run /no-mistakes to validate and ship a PR' "$brief" \
    "no-mistakes no longer ships its PR through the pipeline"
  assert_grep 'done: PR {url} checks green' "$brief" \
    "no-mistakes no longer ends at a PR whose checks are green"
  pass "fm-brief: all three modes still state the stop point their contract promises"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing merge posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided merge posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_refuses_a_brief_that_contradicts_its_own_delivery
test_spawn_refuses_when_the_delivery_matcher_cannot_run
test_generated_definitions_of_done_keep_their_stop_points
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_project_mode_maps_the_conditional_policy
echo "# all fm-task-delivery tests passed"
