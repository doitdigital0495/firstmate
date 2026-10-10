#!/usr/bin/env bash
# Behavior tests for the live project board: bin/fm-live-board.sh build,
# refresh and open, the shipped page rendered through
# tests/assets/live-board-render-harness.mjs, the watcher's refresh tick, and
# the guarded answer path from a captured Lavish choice through
# bin/fm-procevent-lavish.sh into bin/fm-captain-hold.sh. Assertions are on
# published files, rendered output and task state, never on source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVE="$ROOT/bin/fm-live-board.sh"
HARNESS="$ROOT/tests/assets/live-board-render-harness.mjs"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-board)
WATCH_PID=

cleanup() {
  [ -z "$WATCH_PID" ] || kill -KILL "$WATCH_PID" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

ENABLED='{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}'

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  chmod 700 "$home" "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  # A protocol-shaped Lavish stub: opening lists the board open, poll blocks.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.74\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/live",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_NO_OPEN=1 "$@"
}
tasks_in() { local home=$1; shift; (cd "$home" && tasks-axi "$@" >/dev/null); }
render() {  # <home> [now-epoch] [answer-spec...]
  local home=$1
  shift
  node "$HARNESS" "$home/data/live-board/board.html" "$@"
}
check() { printf '%s\n' "$1" | jq -e "$2" >/dev/null || fail "$3: $1"; }
# Give a task a worker whose own busy-state record says what it is doing now.
worker() {  # <home> <id> <busy|idle> [meta-line...]
  local home=$1 id=$2 now=$3 gen event=stop
  shift 3
  mkdir -p "$home/projects/wt-$id"
  fm_write_meta "$home/state/$id.meta" 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" \
    "worktree=$home/projects/wt-$id" "$@"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  [ "$now" = idle ] || event=user-prompt-submit
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" "$now" --gen "$gen" --source claude-hook --event "$event"
}
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# --- Config gate ---------------------------------------------------------------
home=$(make_home config)
out=$(in_home "$home" "$LIVE" open 2>&1) && fail "open succeeded without a config"
assert_contains "$out" "live board is off" "a missing config did not say the board is off"
in_home "$home" "$LIVE" refresh || fail "refresh with no config failed"
assert_absent "$home/data/live-board/board.html" "refresh built a board that was never enabled"
for bad in '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":5}' \
  '{"schema":"fm-live-board-config.v1","enabled":"yes"}' \
  '{"schema":"fm-live-board-config.v1","enabled":true,"extra":1}' \
  '{"schema":"future.v2","enabled":true}' 'not json'; do
  printf '%s\n' "$bad" > "$home/config/live-board.json"
  out=$(in_home "$home" "$LIVE" open 2>&1) && fail "open accepted an invalid config: $bad"
  assert_contains "$out" "config is invalid" "an invalid config was not named invalid: $bad"
done
in_home "$home" "$LIVE" refresh || fail "refresh with an invalid config failed its caller"
assert_absent "$home/data/live-board/board.html" "refresh built a board from an invalid config"
assert_grep "config is invalid" "$home/state/.live-board-refresh.log" \
  "refresh did not log the invalid config"
printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":false}' > "$home/config/live-board.json"
out=$(in_home "$home" "$LIVE" open 2>&1) && fail "open accepted a disabled board"
assert_contains "$out" "enabled to false" "a disabled board did not say so"
printf '%s\n' "$ENABLED" > "$TMP_ROOT/linked.json"
rm -f "$home/config/live-board.json"
ln -s "$TMP_ROOT/linked.json" "$home/config/live-board.json"
out=$(in_home "$home" "$LIVE" open 2>&1) && fail "open followed a symlinked config"
assert_contains "$out" "not a regular file" "a symlinked config was not refused"
pass "the board stays off unless a regular, valid, enabled config opts in"

# --- Empty fleet ---------------------------------------------------------------
home=$(make_home empty)
printf -- '- quiet [local-only] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
in_home "$home" "$LIVE" build | grep -q '^board: ' || fail "build did not report the board path"
[ "$(in_home "$home" "$LIVE" path)" = "$home/data/live-board/board.html" ] \
  || fail "path does not name the published board"
out=$(render "$home")
check "$out" '.empty != null and (.empty | test("Nothing running"))
  and (.projects | length == 0) and .idle.count == 1 and .idle.names == ["quiet"]
  and .stats.questions == 0 and .stats.doing == 0 and .stats.next == 0 and .stats.charted == 0
  and .tray == null and .freshness == "live"' \
  "an empty fleet did not render the explicit empty state"
pass "an empty fleet renders its empty state with idle registered projects folded away"

# --- Large fleet ---------------------------------------------------------------
home=$(make_home large)
printf -- '- big [local-only] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
long=$(printf '%*s' 70000 '' | tr ' ' x)
tasks_in "$home" add big-a "$long" --repo big --kind ship
tasks_in "$home" add big-b "$long" --repo big --kind ship
out=$(in_home "$home" "$LIVE" build 2>&1) || fail "a board past the env-string limit did not build: $out"
[ "$(wc -c < "$home/data/live-board/board.html")" -gt 140000 ] \
  || fail "the large-fleet fixture did not produce a payload past the env-string limit"
check "$(render "$home")" '(.projects | map(.label)) == ["big"] and .idle == null
  and (.projects[0].lanes.next | .count == 2 and (.cards | map(.id)) == ["big-a","big-b"])' \
  "a large board lost its waiting work"
pass "a board whose payload exceeds one environment string still builds and renders"

# --- Three lanes: doing now, next, charted next -------------------------------
home=$(make_home lanes)
printf -- '- shop [no-mistakes] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
for row in 'ln-doing|busy|Build the new checkout' 'ln-stuck|idle|Fix the payment error' \
  'ln-paused|idle|Wait for the supplier release' 'ln-finished|idle|Tidy the product page' 'ln-lost|idle|Speed up search'; do
  id=${row%%|*}; row=${row#*|}
  tasks_in "$home" add "$id" "${row#*|}" --repo shop --kind ship --start
  worker "$home" "$id" "${row%%|*}" 'project=shop'
done
stamp=$(date +%s)
printf 'working [at=%s]: wiring the basket into the new checkout page\n' "$stamp" > "$home/state/ln-doing.status"
printf 'blocked [at=%s]: the payment sandbox keeps refusing our test card\n' "$stamp" > "$home/state/ln-stuck.status"
printf 'paused [at=%s]: waiting for the supplier to publish their release\n' "$stamp" > "$home/state/ln-paused.status"
printf 'done [at=%s]: product page tidied and checked on a phone\n' "$stamp" > "$home/state/ln-finished.status"
tasks_in "$home" add ln-next-low "Polish the footer" --repo shop --kind ship --priority 3
tasks_in "$home" add ln-next-top "Add order tracking" --repo shop --kind ship --priority 1
tasks_in "$home" add ln-next-b "Rename the basket" --repo shop --kind ship
tasks_in "$home" add ln-next-c "Refresh the icons" --repo shop --kind ship
tasks_in "$home" add ln-expired "Reopen the winter sale" --repo shop --kind ship
tasks_in "$home" hold ln-expired --reason "Start after the launch" --kind future --until 2020-01-01
tasks_in "$home" add ln-gated "Launch the loyalty scheme" --repo shop --kind ship --blocked-by ln-doing
tasks_in "$home" add ln-held "Switch payment provider" --repo shop --kind ship
tasks_in "$home" hold ln-held --reason "The supplier contract is still being signed" --kind external --until 2099-01-01
tasks_in "$home" add ln-ask "Which courier?" --repo shop --kind captain
tasks_in "$home" add ln-later "Pick a loyalty partner" --repo shop --kind captain
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ln-ask --reason "Pick a courier." >/dev/null \
  || fail "could not hold the courier question"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ln-later --reason "Decide after the summer." --until 2099-01-01 >/dev/null \
  || fail "could not defer the loyalty question"
tasks_in "$home" add ln-later-gated "Pick a gift wrap" --repo shop --kind captain --blocked-by ln-doing
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ln-later-gated --reason "Decide after the checkout." --until 2099-02-01 >/dev/null \
  || fail "could not defer the gift wrap question"
in_home "$home" "$LIVE" build >/dev/null || fail "the lanes board did not build"
out=$(render "$home")
check "$out" '.projects[0].lanes
  | (.doing | .count == 1 and (.cards | map(.id)) == ["ln-doing"] and (.say | test("A worker is on this right now"))
      and (.cards[0].note | test("wiring the basket")))
    and (.next | .count == 5 and .more == 2 and (.say | test("starts these without you"))
      and (.cards | map(.id)) == ["ln-next-top","ln-next-low","ln-expired","ln-next-b","ln-next-c"]
      and (.cards | map(.folded)) == [false,false,false,true,true] and (.cards | all(.reason == null)))
    and (.charted | .count == 9 and (.say | test("will not start on their own"))
      and (.cards | map([.id,.why])) == [["ln-stuck","stuck"],["ln-ask","your-answer"],["ln-gated","other-work"],
        ["ln-held","on-hold"],["ln-later","deferred"],["ln-later-gated","deferred"],["ln-paused","paused"],
        ["ln-finished","wrap-up"],["ln-lost","unclear"]]
      and (.cards | map(.reason)) == ["Stuck, needs help","Waits for your answer","Waits for other work to finish first",
        "Waiting until 2099-01-01","You put this off until 2099-01-01","You put this off until 2099-02-01",
        "Waiting on something outside the team",
        "Finished, waiting to be wrapped up","Started, but its current status cannot be read"]
      and (.cards[2].note == "Waits for: Build the new checkout")
      and (.cards[3].note | test("supplier contract")))' \
  "the lane rules did not put each kind of open work in its one lane with its plain reason"
check "$out" '[.projects[].lanes[].cards[].id] | length == 15 and (unique | length) == 15' \
  "a task appeared in no lane or in more than one"
check "$out" '.stats.doing == 1 and .stats.next == 5 and .stats.charted == 9 and .stats.questions == 3
  and (.projects[0].questions | map(.id) | sort) == ["ln-ask","ln-later","ln-later-gated"]
  and (.projects[0].questions[] | select(.id == "ln-later") | .answerable
    and (.badges | index("you deferred this until 2099-01-01") != null))
  and (.projects[0].questions[] | select(.id == "ln-later-gated")
    | .badges | index("you deferred this until 2099-02-01") != null)
  and .projects[0].status == "3 questions wait for you, 1 being done now, 5 starting next, 9 not starting on their own (1 stuck)"
  and ([.projects[].text] | join(" ") | test("ln-[a-z]") | not)' \
  "a question the captain put off lost its answerable card and deferred badge, or the lane totals were wrong"
pass "doing now, next and charted next each follow one rule, and every task sits in exactly one lane"

# --- Projects, questions and workers -------------------------------------------
home=$(make_home fleet)
printf -- '- web-shop [no-mistakes] - fixture (added 2026-01-01)\n- data [direct-PR] - fixture (added 2026-01-01)\n' \
  > "$home/data/projects.md"
tasks_in "$home" add ws-redesign "Redesign checkout" --repo web-shop --kind ship
tasks_in "$home" add ws-retry "Retry payments" --repo web-shop --kind ship
tasks_in "$home" add data-export "Nightly export" --repo data --kind ship
tasks_in "$home" add ws-carrier "Which carrier?" --repo web-shop --kind captain --priority 1
tasks_in "$home" add data-window "Move the window?" --repo data --kind captain
tasks_in "$home" add ws-legacy 'Logo </script><b>x</b>' --repo web-shop --kind captain
tasks_in "$home" add data-note-only "Name the release" --repo data --kind captain
cat > "$home/ctx-done.json" <<'JSON'
{"schema":"fm-captain-question.v1","close":"done",
 "about":"The web shop needs one company to deliver the spring orders to customers.",
 "purpose":"Your pick lets the team book the deliveries. Until you pick, spring orders cannot be sent out.",
 "question":"Who should ship the spring orders?",
 "options":[{"value":"dhl","label":"DHL","detail":"Next-day delivery, about 8 percent dearer."},
  {"value":"postnl","label":"PostNL","detail":"Two-day delivery at today's price, which is why it is recommended."}],
 "recommendation":"postnl"}
JSON
cat > "$home/ctx-note.json" <<'JSON'
{"schema":"fm-captain-question.v1","close":"done",
 "about":"The next release of the data platform still has no name.",
 "purpose":"The name goes on the announcement to the business. Without it the announcement waits."}
JSON
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ws-carrier --reason "Pick a carrier." --context-file "$home/ctx-done.json" >/dev/null \
  || fail "could not hold the carrier question"
# data-window is a call stored before the plain-language rule: the writer no
# longer produces that shape, so the fixture records it the way it sits in a body.
FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold data-window --reason "Load overlaps." >/dev/null \
  || fail "could not hold the window question"
printf '%s\n' 'Captain hold set: 2026-07-14T12:00:00Z' \
  'Captain question context: {"close":"release","lifecycle":"2026-07-14T12:00:00Z#0","options":[{"label":"Keep","value":"keep"},{"label":"Move","value":"move"}],"recommendation":null,"schema":"fm-captain-question.v1","subject":null}' \
  > "$home/old-shape.body"
tasks_in "$home" update data-window --body-file "$home/old-shape.body"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ws-legacy --reason "Old hold." >/dev/null \
  || fail "could not hold the legacy question"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold data-note-only --reason "Free answer." --context-file "$home/ctx-note.json" >/dev/null \
  || fail "could not hold the note-only question"
worker "$home" ws-redesign busy 'project=web-shop' 'pr=https://github.com/example/web-shop/pull/42'
printf 'working [at=%s]: checkout tests pass on fm/ws-redesign, see data/ws-redesign/report.md run=01ABCDEFGHJKMNPQRSTVWXYZ01\n' \
  "$(date +%s)" > "$home/state/ws-redesign.status"
printf '%s\n' "$ENABLED" > "$home/config/live-board.json"
in_home "$home" "$LIVE" build >/dev/null || fail "the fleet board did not build"
now=$(date +%s)
out=$(render "$home" "$now")
check "$out" '.stats.questions == 4 and .stats.urgent == 1
  and (.projects | map(.label)) == ["web-shop","data"]
  and (.projects[0].questions | map(.id)) == ["ws-carrier","ws-legacy"]
  and .projects[0].questions[0].urgent
  and (.projects[1].questions | map(.id) | sort) == ["data-note-only","data-window"]' \
  "without a project map, work did not group by repository with questions first"
check "$out" '(.projects[0].questions[0] | .answerable and .mode == "options"
    and .title == "Who should ship the spring orders?" and .topic == "Which carrier?"
    and .modeText == "Answering closes this question."
    and .options == [{value:"dhl",label:"DHL",detail:"Next-day delivery, about 8 percent dearer.",recommended:false},
      {value:"postnl",label:"PostNL",detail:"Two-day delivery at today\u0027s price, which is why it is recommended.",recommended:true}]
    and (.lavishQuestion | startswith("live-board:ws-carrier#")))
  and (.projects[1].questions[] | select(.id == "data-window") | .answerable
    and .modeText == "Answering lets the paused work continue.")
  and (.projects[1].questions[] | select(.id == "data-note-only") | .answerable and .options == [] and .mode == "text")
  and (.projects[0].questions[1] | .answerable and .mode == "free-text" and .readonly == null
    and .options == [] and .noteField == "textarea" and .lavishQuestion == "live-board:ws-legacy"
    and .title == "Logo </script><b>x</b>" and (.modeText | test("records your words")))' \
  "owner context did not drive the real question, its explained options, or the free-text fallback"
check "$out" '(.projects[0].lanes.doing.cards | map(.id)) == ["ws-redesign"]
  and (.projects[0].lanes.doing.cards[0] | .title == "Redesign checkout" and .reason == null
    and .links == [{href:"https://github.com/example/web-shop/pull/42",text:"pull request"}]
    and (.note | test("checkout tests pass")) and (.note | test("fm/|data/|run=|01ABC") | not))
  and (.projects[0].latest | test("Redesign checkout - checkout tests pass"))
  and (.projects[0].lanes.next.cards | map(.title)) == ["Retry payments"]
  and (.projects[0].lanes.charted.cards | map(.id)) == ["ws-carrier","ws-legacy"]
  and (.projects[0].lanes.charted.cards | all(.reason == "Waits for your answer"))
  and .projects[0].status == "2 questions wait for you (1 urgent), 1 being done now, 1 starting next, 2 not starting on their own"
  and (.projects[1].lanes | .doing.cards == [] and (.doing.none | test("Nothing is being worked on"))
    and (.next.cards | map(.title)) == ["Nightly export"])
  and .stats.doing == 1 and .stats.next == 2 and .stats.charted == 4' \
  "open work did not land in its doing, next and charted lanes"
check "$out" '[.projects[].text] | join(" ")
  | test("ws-redesign|ws-retry|data-export|ws-carrier|data-window|ws-legacy|data-note-only|web-shop/pull") | not' \
  "the page face showed task ids or raw links"
pass "repository fallback leads with real questions and explained options, then the three lanes"

# --- A manager can place every question ---------------------------------------
check "$out" '(.projects[0].questions[0]
    | .parts == ["project","about","purpose","question","options"] and .project == "web-shop"
    and .about == "The web shop needs one company to deliver the spring orders to customers."
    and (.purpose | test("^Your pick lets the team book the deliveries")) and .needsExplanation == null
    and .why == null and (.options | map(.recommended)) == [false,true])
  and (.projects[1].questions[] | select(.id == "data-note-only")
    | .parts == ["project","about","purpose","question"] and .needsExplanation == null)' \
  "an explained question did not lead with its project, what it is about and what it is for"
check "$out" '(.projects[1].questions[] | select(.id == "data-window")
    | .parts == ["project","needs-explanation","question","options"] and .about == null and .purpose == null
    and (.needsExplanation | test("^Needs a plain-language explanation"))
    and (.why | test("Load overlaps")) and .answerable and (.options | map(.value)) == ["keep","move"])
  and (.projects[0].questions[1]
    | .parts == ["project","needs-explanation","question"]
    and (.needsExplanation | test("^Needs a plain-language explanation")) and .answerable)
  and (.notes | index("2 questions still need a plain-language explanation from Firstmate.") != null)' \
  "a question stored without its explanation did not stay answerable under a visible marker"
pass "each card leads with project, what it is about and what it is for; an unexplained one says so and still answers"

# --- The captain's named projects ----------------------------------------------
cat > "$home/config/live-board-projects.json" <<'JSON'
{"schema":"fm-live-board-projects.v1","projects":[
  {"name":"Data platform","description":"Nightly data and its release.","match":[{"repo":"data"}]},
  {"name":"Checkout","description":"The new checkout.","match":[{"id":"ws-redesign"},{"id":"ws-carrier"},{"id":"ws-retry"}]},
  {"name":"Unused effort","match":[{"id":"nothing-*"}]}]}
JSON
in_home "$home" "$LIVE" build >/dev/null || fail "the mapped board did not build"
out=$(render "$home" "$now")
check "$out" '(.projects | map(.label)) == ["Checkout","Data platform","web-shop"]
  and .projects[0].description == "The new checkout."
  and (.projects[0].questions | map(.id)) == ["ws-carrier"]
  and (.projects[0].lanes.doing.cards | map(.id)) == ["ws-redesign"]
  and .projects[0].status == "1 question waits for you (1 urgent), 1 being done now, 1 starting next, 1 not starting on its own"
  and (.projects[2].questions | map(.id)) == ["ws-legacy"]
  and (.projects[2].description | test("Not yet sorted"))
  and .idle.names == ["Unused effort"] and (.notes | any(test("project map")) | not)' \
  "the project map did not group work under the captain's names in priority order"
printf '%s\n' '{"schema":"fm-live-board-projects.v1","projects":[{"name":"X","match":[{"branch":"x"}]}]}' \
  > "$home/config/live-board-projects.json"
in_home "$home" "$LIVE" build >/dev/null || fail "an invalid project map failed the build"
check "$(render "$home" "$now")" '(.projects | map(.label)) == ["web-shop","data"]
  and (.notes | any(test("project map is invalid")))' \
  "an invalid project map did not fall back to repository grouping with a note"
rm -f "$home/config/live-board-projects.json"
in_home "$home" "$LIVE" build >/dev/null || fail "the fleet board did not rebuild"
pass "a project map groups work under the captain's names; unmatched work and bad maps fall back by repository"

# --- Pull request timelines ----------------------------------------------------
# Each project shows its pull requests; pointing at one shows what changed and
# whether its deploy went well, and pressing it pins that with a link.
tl=$(make_home timeline)
printf '%s\n' "$ENABLED" > "$tl/config/live-board.json"
printf -- '- web-shop [no-mistakes] - fixture (added 2026-01-01)\n- data [direct-PR] - fixture (added 2026-01-01)\n- docs-site [direct-PR] - fixture (added 2026-01-01)\n' \
  > "$tl/data/projects.md"
tasks_in "$tl" add ws-redesign "Redesign checkout" --repo web-shop --kind ship
for repo in web-shop data docs-site; do
  git init -q "$tl/projects/$repo"
  git -C "$tl/projects/$repo" remote add origin "https://github.com/acme/$repo.git"
done
mkdir -p "$tl/forge"
# A forge stub that answers per repository and logs each call.
cat > "$tl/fakebin/gh" <<'SH'
#!/usr/bin/env bash
name=
for arg in "$@"; do
  case "$arg" in name=*) name=${arg#name=} ;; esac
done
printf '%s\n' "$name" >> "$FM_HOME/forge/calls.log"
[ -f "$FM_HOME/forge/$name.json" ] || exit 1
cat "$FM_HOME/forge/$name.json"
SH
chmod +x "$tl/fakebin/gh"
tl_now=$(date +%s)
tl_pr() {  # <repo> <number> <state> <head> <age-seconds> <title> <body> <suite-conclusions...>
  local repo=$1 number=$2 state=$3 head=$4 age=$5 title=$6 body=$7
  shift 7
  jq -cn --arg repo "$repo" --argjson number "$number" --arg state "$state" --arg head "$head" \
    --argjson at "$((tl_now - age))" --arg title "$title" --arg body "$body" '
    ($at | todate) as $when
    | {number:$number,title:$title,body:$body,url:"https://github.com/acme/\($repo)/pull/\($number)",state:$state,
       isDraft:false,createdAt:$when,headRefName:$head,
       closedAt:(if $state == "OPEN" then null else $when end),mergedAt:(if $state == "MERGED" then $when else null end),
       mergeCommit:(if $state != "MERGED" then null else {status:{contexts:[]},checkSuites:{nodes:[
         $ARGS.positional[] | split("=") | {status:(if .[1] == "RUNNING" then "IN_PROGRESS" else "COMPLETED" end),
           conclusion:(if .[1] == "RUNNING" then null else .[1] end),createdAt:$when,app:{slug:"github-actions",name:"GitHub Actions"},
           checkRuns:{totalCount:1},workflowRun:{event:"push",workflow:{name:.[0]}}}]}} end)}' --args "$@"
}
{
  tl_pr web-shop 1 MERGED fm/ws-redesign 7200 'feat(checkout): one-step checkout' \
    $'## Intent\n\nCustomers pay in one step instead of three, so fewer of them give up half way.\n\n## Notes\n\nprivate body sentinel' \
    'Deploy shop=FAILURE' 'Publish docs=SUCCESS'
  tl_pr web-shop 2 MERGED fm/ws-colours 90000 'Fresh colours' '' 'Deploy shop=SUCCESS'
  tl_pr web-shop 3 OPEN fm/ws-search 600 'Search by order number' ''
  tl_pr web-shop 4 MERGED fm/pay-refunds 3600 'Refunds in one click' 'Support staff refund an order with one click instead of filling in a form.' 'Deploy shop=RUNNING'
  tl_pr web-shop 5 CLOSED fm/ws-dropped 180000 'Dropped idea' ''
} | jq -cs '{data:{repository:{pullRequests:{nodes:.}}}}' > "$tl/forge/web-shop.json"
tl_pr data 7 MERGED fm/data-export 86400 'Nightly export' '' \
  | jq -cs '{data:{repository:{pullRequests:{nodes:.}}}}' > "$tl/forge/data.json"
calls() { wc -l < "$tl/forge/calls.log" | tr -d '[:space:]'; }
shop_pr() { printf 'https://github.com/acme/web-shop/pull/%s' "$1"; }

in_home "$tl" "$LIVE" build >/dev/null || fail "a board with pull requests did not build"
[ "$(calls)" = 3 ] || fail "the first build did not read each project's pull requests once: $(calls)"
out=$(TZ=UTC render "$tl" "$tl_now")
check "$out" '(.projects | map(.label)) == ["web-shop"] and (.projects[0].badges | index("1 failed after merge") != null)
  and (.projects[0].timeline | .status == "ok" and .count == "5" and .gaps == []
    and (.say | test("Oldest on the left") and test("Read "))
    and (.marks | map(.key | split("/") | .[-1])) == ["5","2","1","4","3"]
    and (.marks | map(.kind)) == ["closed","succeeded","failed","running","open"]
    and (.marks | map(.tag)) == ["closed","passed","failed","running","open"]
    and (.marks | map(.failedClass)) == [false,false,true,false,false]
    and all(.marks[]; .pressed == false and (.date | test("^[0-9]{1,2} [A-Z][a-z]{2}$")))
    and (.marks[2].label | test("^Merged .*: One-step checkout\\. Runs after merge failed\\.$"))
    and .detail.shown == null and (.detail.text | test("Point at a pull request")))' \
  "a project did not show its pull requests as a timeline, oldest first, with the failed runs after merge marked in words"
pass "each project shows a timeline of its pull requests, and a merge with a failed run is marked by shape and word"

out=$(TZ=UTC render "$tl" "$tl_now" "!pr=mouseenter=web-shop=$(shop_pr 1)")
check "$out" '.projects[0].timeline | .detail.shown == "'"$(shop_pr 1)"'" and .detail.pinned == false
  and .detail.title == "One-step checkout"
  and .detail.summary == "Customers pay in one step instead of three, so fewer of them give up half way."
  and .detail.deploy == "failed" and (.detail.badges[0] == "Runs after merge failed") and (.detail.badges[1] | test("^Merged"))
  and (.detail.deployText | test("^Runs after merge: At least one run this change.s merge started has failed"))
  and .detail.runs == [{"result":"failed","text":"Deploy shop - failed"},{"result":"succeeded","text":"Publish docs - succeeded"}]
  and .detail.links == [] and .detail.close == false and (.detail.text | test("Press it to keep this open"))
  and (.marks | map(.shown)) == [false,false,true,false,false]' \
  "pointing at a pull request did not show in plain words what changed and that a run after its merge failed"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=mouseenter=web-shop=$(shop_pr 1)" "!pr=mouseleave=web-shop=$(shop_pr 1)")" \
  '.projects[0].timeline.detail | .shown == null and .pinned == false' "moving off a pull request left its detail showing"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=focus=web-shop=$(shop_pr 4)")" \
  '.projects[0].timeline.detail | .shown == "'"$(shop_pr 4)"'" and .deploy == "running" and .badges[0] == "Runs after merge still running"
    and .summary == "Support staff refund an order with one click instead of filling in a form."' \
  "keyboard focus did not show a pull request, or an unfinished run was not named as still running"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=focus=web-shop=$(shop_pr 2)")" \
  '.projects[0].timeline.detail | .deploy == "succeeded" and .badges[0] == "Runs after merge succeeded" and .summary == null and .title == "Fresh colours"' \
  "runs after merge that went well were not named, or a pull request without a description did not fall back to its title"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=focus=web-shop=$(shop_pr 3)")" \
  '.projects[0].timeline.detail | .badges == ["Not merged yet","Open · '"$(TZ=UTC node -e 'const d=new Date(Number(process.argv[1])*1000);console.log(d.getDate()+" "+["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][d.getMonth()])' "$((tl_now - 600))")"'"]' \
  "an open pull request was not shown as not merged yet"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=focus=web-shop=$(shop_pr 5)")" \
  '.projects[0].timeline.detail | .badges[0] == "Not merged" and (.deployText | test("closed without being merged"))' \
  "a pull request closed without merging was not explained"
pass "pointing at or focusing a pull request shows what changed in plain words and whether the runs after its merge succeeded"

out=$(TZ=UTC render "$tl" "$tl_now" "!pr=click=web-shop=$(shop_pr 1)")
check "$out" '.projects[0].timeline | .detail.pinned == true and .detail.shown == "'"$(shop_pr 1)"'"
  and .detail.links == [{"href":"'"$(shop_pr 1)"'","text":"Open this pull request on GitHub","target":"_blank","rel":"noopener"}]
  and .detail.close == true and (.marks | map(.pressed)) == [false,false,true,false,false]' \
  "pressing a pull request did not pin its detail with a link to the forge"
check "$out" '.projects[0].timeline | .kept == "'"$(shop_pr 1)"'" and (.lavishQuestion | startswith("live-board-pin:"))' \
  "a pinned pull request was not kept in the field Lavish restores after a reload"
check "$out" '.queued == [] and .tray == null' "pinning a pull request queued something for Firstmate"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=restore=web-shop=$(shop_pr 1)")" \
  '.projects[0].timeline | .detail.pinned == true and .detail.shown == "'"$(shop_pr 1)"'" and (.detail.links | length) == 1
    and (.marks | map(.pressed)) == [false,false,true,false,false]' \
  "a pinned pull request did not stay pinned across a reload"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=click=web-shop=$(shop_pr 1)" "!pr=mouseenter=web-shop=$(shop_pr 2)")" \
  '.projects[0].timeline.detail | .shown == "'"$(shop_pr 2)"'" and .pinned == false and .links == []' \
  "pointing at another pull request did not preview it over the pinned one"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=click=web-shop=$(shop_pr 1)" "!pr=mouseenter=web-shop=$(shop_pr 2)" "!pr=mouseleave=web-shop=$(shop_pr 2)")" \
  '.projects[0].timeline.detail | .shown == "'"$(shop_pr 1)"'" and .pinned == true' \
  "the pinned pull request did not come back after a preview"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=click=web-shop=$(shop_pr 1)" "!pr=click=web-shop=$(shop_pr 1)")" \
  '.projects[0].timeline | .detail.shown == null and .kept == ""' "pressing a pinned pull request again did not unpin it"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=click=web-shop=$(shop_pr 1)" "!pr=close=web-shop")" \
  '.projects[0].timeline | .detail.shown == null and .kept == "" and all(.marks[]; .pressed == false)' \
  "Close did not unpin the pull request"
pass "pressing a pull request pins its detail with a link to it, across reloads, until it is pressed again or closed"

check "$out" '.idle.names == ["data","docs-site"]
  and (.idle.timelines.data | .count == "1" and (.marks | map(.tag)) == ["no runs"])
  and (.idle.timelines["docs-site"] | .gaps == ["docs-site"] and .marks == [] and (.say | test("No pull requests were found")))
  and (.notes | any(test("Pull requests for docs-site could not be read")))' \
  "a quiet project lost its timeline, or a project whose pull requests could not be read did not say so"
check "$(TZ=UTC render "$tl" "$tl_now" "!pr=click=data=https://github.com/acme/data/pull/7")" \
  '.idle.timelines.data.detail | .pinned == true and .badges[0] == "No runs after merge for this project" and .runs == []
    and (.deployText | test("starts no run after a merge"))' \
  "a project whose merges start no run was not named as having none"
if grep -q 'private body sentinel' "$tl/data/live-board/board.html"; then
  fail "pull request description text beyond the summary reached the page"
fi
pass "a project whose merges start no run says so, and a project whose pull requests could not be read is named"

cat > "$tl/config/live-board-projects.json" <<'JSON'
{"schema":"fm-live-board-projects.v1","projects":[
  {"name":"Payments","match":[{"id":"pay-*"}]},
  {"name":"Shop front","match":[{"repo":"web-shop"}]}]}
JSON
in_home "$tl" "$LIVE" build >/dev/null || fail "the mapped timeline board did not build"
[ "$(calls)" = 3 ] || fail "a rebuild inside the pull request interval read the forge again: $(calls)"
out=$(TZ=UTC render "$tl" "$tl_now")
check "$out" '(.projects | map(.label)) == ["Shop front"]
  and (.projects[0].timeline.marks | map(.key | split("/") | .[-1])) == ["5","2","1","3"]
  and (.idle.timelines.Payments.marks | map(.key | split("/") | .[-1])) == ["4"]
  and (.idle.timelines.Payments.gaps == ["docs-site"]) and (.projects[0].timeline.gaps == [])
  and (.idle.timelines.data.marks | length) == 1' \
  "pull requests did not follow their task into the captain's named project"
rm -f "$tl/config/live-board-projects.json"
pass "a pull request belongs to the named project its task belongs to"

assert_present "$tl/state/.live-board-prs.json" "the pull request read was not cached in the state directory"
[ "$(ls -A "$tl/data/live-board")" = board.html ] \
  || fail "pull request data was left beside the served board: $(ls -A "$tl/data/live-board")"
pass "the pull request read is cached outside the directory Lavish serves"

# The attempt stamp paces the reads, so an old stamp makes the next build read.
due() { touch -t 202001010000 "$tl/state/.live-board-prs-attempt"; }
due
in_home "$tl" "$LIVE" build >/dev/null || fail "a due pull request read failed the build"
[ "$(calls)" = 6 ] || fail "a due pull request read did not ask the forge again: $(calls)"
# A copy of the scripts whose collector fails stands in for a read that dies or times out.
cp -R "$ROOT/bin" "$tl/bin-down"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tl/bin-down/fm-live-board-prs.sh"
due
out=$(in_home "$tl" "$tl/bin-down/fm-live-board.sh" build 2>&1) \
  || fail "a pull request read that failed also failed the build: $out"
assert_contains "$out" "the timelines keep their previous data" "a failed pull request read was not reported"
check "$(TZ=UTC render "$tl" "$tl_now")" '.projects[0].timeline.marks | length == 5' \
  "a failed pull request read dropped the last good timeline"
touch -t 202001010000 "$tl/data/live-board/board.html"
due
in_home "$tl" "$tl/bin-down/fm-live-board.sh" refresh || fail "refresh changed its exit status"
assert_grep "the timelines keep their previous data" "$tl/state/.live-board-refresh.log" \
  "a failed pull request read during refresh was not logged"
[ "$(( $(date +%s) - $(mtime "$tl/data/live-board/board.html") ))" -lt 60 ] \
  || fail "a failed pull request read stopped refresh from rebuilding the board"
rm -f "$tl/state/.live-board-prs.json"
due
in_home "$tl" "$tl/bin-down/fm-live-board.sh" build >/dev/null 2>&1 \
  || fail "a board whose pull requests were never read did not build"
check "$(TZ=UTC render "$tl" "$tl_now")" '.projects[0].timeline | .status == "not-collected" and .marks == []
  and (.say | test("have not been read yet"))' \
  "a board whose pull requests were never read did not say so"
pass "pull requests are read at most once per interval, and a failed read keeps the last good timeline and says so"

# --- Queued answers carry the owner's guard ------------------------------------
out=$(render "$home" "$now" 'ws-carrier=postnl:cheaper' 'data-window=' 'data-note-only=:Call it Tidewater' \
  'ws-legacy=:Use the new logo')
check "$out" '(.queued | length == 3)
  and .queued[0].tag == "choice"
  and (.queued[0].data | .schema == "fm-bearings-answer.v1" and .question == "ws-carrier"
    and .selection == "postnl" and .note == "cheaper" and .close == "done"
    and (.lifecycle | test("^[0-9T:Z-]+#0$")))
  and (.queued[1].data | .question == "data-note-only" and .selection == "" and .note == "Call it Tidewater")
  and (.queued[2].data == {schema:"fm-bearings-answer.v1",question:"ws-legacy",selection:"",note:"Use the new logo"})
  and (.submits[] | select(.id == "data-window") | .queuedClass == false)' \
  "a queued answer lost its close mode or lifecycle, an empty answer queued, or free text was not sent"
pass "Queue answer emits one choice with the owner close mode and lifecycle, or plain free text"

# --- Choose and queue; answered cards shrink and stay answered ----------------
tray='{text:"Answers you queue are delivered to Firstmate when you press Send in the Lavish panel.",buttons:[]}'
check "$(render "$home" "$now")" ".tray == $tray"'
  and ([.projects[].questions[] | select(.answerable)] | length == 4 and all(.submit == "Queue answer" and .answer == "open" and .answered == null))' \
  "an unanswered board did not say how answers are sent or offered its own send control, or a card did not offer Queue answer"
check "$out" ".tray == $tray"'
  and (.projects[0].questions[0] | .answer == "queued" and .change == "Change answer"
    and (.answered | test("^Answer queued in Lavish") and test("Who should ship the spring orders\\? - PostNL - cheaper")))
  and (.projects[1].questions[] | select(.id == "data-window") | .answer == "open" and .answered == null)
  and (.projects[0].questions[1] | .answer == "queued" and (.answered | test("Use the new logo")))' \
  "a queued answer did not shrink its card to the answer, or the page offered its own send control"
kept=$(printf '%s\n' "$out" | jq -r '.projects[0].questions[0].kept')
out=$(render "$home" "$now" 'ws-carrier=dhl' 'data-note-only=:Call it Tidewater' '!change=ws-carrier')
check "$out" ".tray == $tray"'
  and (.projects[0].questions[0] | .answer == "open" and .answered == null and .submit == "Queue answer"
    and (.status | test("Queue a new answer")))
  and ([.projects[].questions[] | select(.id == "data-note-only")] | all(.answer == "queued"))' \
  "Change answer did not reopen its card, or touched another card"
out=$(render "$home" "$now" 'ws-carrier=dhl' '!change=ws-carrier' 'ws-carrier=postnl')
check "$out" '(.queued | map(.data.selection)) == ["dhl","postnl"]
  and (.projects[0].questions[0] | .answer == "queued" and (.answered | test("PostNL"))
    and (.lavishQuestion | test("^live-board:ws-carrier#")))' \
  "queueing a new answer on a changed card did not re-queue it under the same Lavish question"
out=$(render "$home" "$now" "!restore=ws-carrier=$kept" "!restore=ws-legacy=$(printf '2020-01-01T00:00:00Z#0\tOld words')")
check "$out" '(.queued | length == 0)
  and (.projects[0].questions[0] | .answer == "queued" and (.answered | test("PostNL - cheaper")))
  and (.projects[0].questions[1] | .answer == "open")' \
  "an answered card did not stay answered after a reload, or an answer to an earlier asking was shown"
pass "the captain picks an option, optionally adds a note and queues; answered cards shrink, keep Change answer and survive a reload"

# --- Local freshness ----------------------------------------------------------
check "$(render "$home" "$((now + 400))")" '.freshness == "stale" and .banner == ""' \
  "an old board did not mark itself stale"
check "$(render "$home" "$((now + 4000))")" '.freshness == "unavailable" and (.banner | test("rebuilt"))' \
  "a board whose refresh stopped did not say it is out of date"
pass "the page ages its own data from live to stale to out of date"

# --- Refresh timing and failure retention --------------------------------------
board="$home/data/live-board/board.html"
before=$(mtime "$board")
in_home "$home" "$LIVE" refresh
[ "$(mtime "$board")" = "$before" ] || fail "refresh rebuilt a board that was not yet due"
touch -t 202001010000 "$board"
in_home "$home" "$LIVE" refresh
[ "$(( $(date +%s) - $(mtime "$board") ))" -lt 60 ] || fail "refresh did not rebuild a due board"
cp "$board" "$TMP_ROOT/last-good.html"
touch -t 202001010000 "$board"
chmod 500 "$home/data/live-board"
in_home "$home" "$LIVE" refresh || fail "a failed refresh changed its exit status"
chmod 700 "$home/data/live-board"
cmp -s "$board" "$TMP_ROOT/last-good.html" || fail "a failed refresh replaced the last good board"
assert_grep "cannot stage" "$home/state/.live-board-refresh.log" "a failed refresh was not logged"
pass "refresh rebuilds only when due and keeps the last good board on failure"

# --- Open: serve, bind before arm ----------------------------------------------
out=$(in_home "$home" "$LIVE" open 2>&1) || fail "open failed: $out"
assert_contains "$out" "session: live" "open did not prove the session live"
sid=$(printf '%s\n' "$out" | sed -n 's/^bound: //p')
[ -n "$sid" ] || fail "open did not bind the board source: $out"
assert_contains "$out" "armed: $sid" "open did not arm the bound source"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" binding "$sid" >/dev/null \
  || fail "the armed source has no keyed-answer binding"
pass "open serves the board, binds its answers, then arms the source"

# --- Guarded answers through the Lavish adapter --------------------------------
lifecycle=$(render "$home" "$now" 'ws-carrier=postnl' | jq -r '.queued[0].data.lifecycle')
window_lifecycle=$(render "$home" "$now" 'data-window=move' | jq -r '.queued[0].data.lifecycle')
row() {  # <n> <question> <selection> <extra-context-members>
  printf '  "%s","Answer\\n\\nContext data:\\n{\\"schema\\": \\"fm-bearings-answer.v1\\", \\"question\\": \\"%s\\", \\"selection\\": \\"%s\\", \\"note\\": \\"\\"%s}","form",choice,"%s -> %s"\n' \
    "$1" "$2" "$3" "$4" "$2" "$3"
}
result="$TMP_ROOT/captured.result"
{
  printf 'status: feedback\nprompts[4]{id,prompt,selector,tag,text}:\n'
  row 1 ws-carrier postnl ", \\\"close\\\": \\\"done\\\", \\\"lifecycle\\\": \\\"$lifecycle\\\""
  row 2 data-window move ', \"close\": \"release\", \"lifecycle\": \"2020-01-01T00:00:00Z#0\"'
  row 3 forged yes ', \"close\": \"done\", \"lifecycle\": \"bad\\tlife#0\"'
  row 4 nomode yes ', \"lifecycle\": \"2020-01-01T00:00:00Z#0\"'
} > "$result"
rows=$(in_home "$home" "$ROOT/bin/fm-procevent-lavish.sh" answers "$result")
[ "$(printf '%s\n' "$rows" | cut -f1,2,4,5)" = "$(printf 'ws-carrier\tpostnl\tdone\t%s\ndata-window\tmove\trelease\t2020-01-01T00:00:00Z#0' "$lifecycle")" ] \
  || fail "the adapter did not relay exactly the well-formed guarded rows: $rows"
out=$(printf '%s\n' "$rows" | in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answers --any-origin --source "fixture capture" 2>&1)
assert_contains "$out" "closed: ws-carrier" "a current guarded answer did not close its question"
assert_contains "$out" "skipped: data-window (stale captain question lifecycle)" \
  "an answer for an earlier hold was not refused by the lifecycle guard"
show=$(cd "$home" && tasks-axi show ws-carrier --full)
assert_contains "$show" "state: done" "the answered question stayed open"
assert_contains "$show" "Captain answer lifecycle: $lifecycle" "the answer did not record its guarded lifecycle"
show=$(cd "$home" && tasks-axi show data-window --full)
assert_contains "$show" "held: yes" "a refused stale answer released the newer hold"
[ "$window_lifecycle" != "2020-01-01T00:00:00Z#0" ] || fail "the fixture lifecycle collided with the stale guard"
touch -t 202001010000 "$board"
in_home "$home" "$LIVE" refresh
check "$(render "$home")" '[.projects[] | .questions[].id, .lanes[].cards[].id] | index("ws-carrier") == null' \
  "the next refresh still showed an answered question"
result="$TMP_ROOT/free-text.result"
{
  printf 'status: feedback\nprompts[1]{id,prompt,selector,tag,text}:\n'
  printf '  "1","Answer\\n\\nContext data:\\n{\\"schema\\": \\"fm-bearings-answer.v1\\", \\"question\\": \\"ws-legacy\\", \\"selection\\": \\"\\", \\"note\\": \\"Use the new logo\\"}","form",choice,"Logo -> Use the new logo"\n'
} > "$result"
rows=$(in_home "$home" "$ROOT/bin/fm-procevent-lavish.sh" answers "$result")
[ "$(printf '%s\n' "$rows" | cut -f1,2)" = "$(printf 'ws-legacy\tUse the new logo')" ] \
  || fail "the adapter did not relay the free-text answer: $rows"
out=$(printf '%s\n' "$rows" | in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answers --any-origin --source "fixture capture" 2>&1)
assert_contains "$out" "closed: ws-legacy" "a free-text answer did not reach the keyed-answer intake"
show=$(cd "$home" && tasks-axi show ws-legacy --full)
assert_contains "$show" "Use the new logo" "the free-text answer did not record the captain's words"
touch -t 202001010000 "$board"
in_home "$home" "$LIVE" refresh
check "$(render "$home")" '[.projects[] | .questions[].id, .lanes[].cards[].id] | index("ws-carrier") == null and index("ws-legacy") == null' \
  "the next refresh still showed an answered question"
result="$TMP_ROOT/release.result"
{
  printf 'status: feedback\nprompts[1]{id,prompt,selector,tag,text}:\n'
  row 1 data-window move ", \\\"close\\\": \\\"release\\\", \\\"lifecycle\\\": \\\"$window_lifecycle\\\""
} > "$result"
rows=$(in_home "$home" "$ROOT/bin/fm-procevent-lavish.sh" answers "$result")
out=$(printf '%s\n' "$rows" | in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answers --any-origin --source "fixture capture" 2>&1)
show=$(cd "$home" && tasks-axi show data-window --full)
assert_contains "$show" "held: no" "an answer that lets the work continue left it held: $out"
touch -t 202001010000 "$board"
in_home "$home" "$LIVE" refresh
check "$(render "$home")" '([.projects[].questions[].id] | index("data-window") == null)
  and ([.projects[].lanes.next.cards[].id] | index("data-window") != null)
  and ([.projects[].lanes.charted.cards[].id] | index("data-window") == null)' \
  "work the captain's answer let continue kept its question card or stayed in the charted lane"
pass "answered questions leave the page on the next refresh, and work an answer lets continue moves to its lane"

# --- The watcher drives refresh -----------------------------------------------
home=$(make_home watched)
printf '%s\n' "$ENABLED" > "$home/config/live-board.json"
PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
i=0
while [ ! -s "$home/data/live-board/board.html" ] && [ "$i" -lt 300 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
kill -KILL "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
[ -s "$home/data/live-board/board.html" ] \
  || fail "the watcher did not publish an enabled board: $(cat "$TMP_ROOT/watch.err" 2>/dev/null)"
check "$(render "$home")" '.empty != null' "the watcher-published board did not render"
pass "a running watcher keeps an enabled board published"
