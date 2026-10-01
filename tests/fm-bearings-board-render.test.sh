#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits. This suite is about
  # what the template renders, not about session liveness, which
  # tests/fm-bearings-board.test.sh owns.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.61\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/render",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # Bounded, so a listener that escapes its test stops on its own.
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

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more] [calls-json] [landed-json] [extra-json]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  local calls=${6:-'[]'} landed=${7:-'[]'} extra=${8:-\{\}}
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson calls "$calls" --argjson landed "$landed" --argjson extra "$extra" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:$calls, underway:$underway, landed:$landed,
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more} + $extra' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "waiting to start") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 0 and .sections.charted.hidden == false
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or added empty-state noise: $out"
  pass "a warning-only board counts zero queued and shows only the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 0 and .sections.charted.hidden == false
      and (.more == ["+1 more repair warning - ask for the complete status page"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_queued_status_even_without_a_reason() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[0].tone == "warn")
      and ([.charted[1].badges[] | .text] == ["queued"])
      and ([.charted[1].badges[] | .tone] == ["neutral"])
      and (.charted[1].tone == "neutral")
      and (.charted[1].detail == "Ready for dispatch.")
  ' >/dev/null || fail "queued work without a reason was not neutral and queued: $out"
  pass "queued work waits with a reason and reads as neutral queued without one"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and .sub == "firstmate"
          and (.detail | test("no-mistakes: review round 2"))
          and (.sub | test("ship") | not) and (.detail | test("ship") | not)
          and .disclosure == true and .cue == "Current status"
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and .sub == ""
          and .detail == "fixing the failing check"
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

test_status_page_shows_every_request_and_explained_cards() {
  local home out extra
  home=$(make_home all-requests)
  extra=$(jq -n '{
    requests:[
      {id:"working",repo:"sample",title:"Speed up the portal",status:"Working",detail:"Measuring page load times."},
      {id:"queued",repo:"sample",title:"Remove old tabs",status:"Waiting for another task",detail:"Starts after the portal check."},
      {id:"held",repo:null,title:"Choose hosting",status:"Waiting on you",detail:"Choose whether to pay for dedicated hosting."},
      {id:"done",repo:"sample",title:"Update domains",status:"Completed",detail:"The new domains work.",pr_url:"https://github.com/acme/repo/pull/1"},
      {id:"unknown",repo:null,title:"Unconfirmed request",status:"Status not confirmed",detail:"Its worker could not be checked."}
    ],
    coverage:["One group could not be checked; its last known tasks are shown."],
    captains_call:[
      {key:"hosting",repo:"sample",type:"decision",title:"Choose hosting",about:"Keeps reports available during updates.",decide:"Choose the cost and outage tradeoff.",recommend_value:"dedicated",
       options:[{value:"dedicated",label:"Dedicated hosting",hint:"Costs more but updates do not interrupt reports."}]},
      {key:"merge.domains",repo:"sample",type:"merge",title:"Publish domains",about:"Uses the new report addresses.",decide:"Choose whether to publish these reviewed changes.",risk:"low",
       options:[{value:"merge",label:"Publish now",hint:"Makes the approved addresses available."}]}
    ]
  }')
  out=$(render_board "$home" '[]' '[]' 0 0 '[]' '[]' "$extra")
  printf '%s' "$out" | jq -e '
    .error == "" and (.requests | length) == 5
    and [.requests[].status] == ["Working","Waiting for another task","Waiting on you","Completed","Status not confirmed"]
    and .requests[3].href == "https://github.com/acme/repo/pull/1"
    and (.cards | length) == 2 and ([.cards[].hidden] | all(. == false))
    and (.cards[0].contexts[0] | startswith("What it is for"))
    and (.cards[1].contexts[0] | startswith("What it is for"))
    and (.cards[0].options[0] | contains("Costs more") and contains("recommended"))
    and (.cards[0].options[1] | contains("Check whether this still needs an answer"))
    and (.coverage | length) == 1
    and (.stats | any(.label == "requests" and .n == 5))
  ' >/dev/null || fail "status page lost requests or their explanations: $out"
  pass "all-tasks page shows five statuses, explained options, both cards and coverage"
}

test_projects_drop_idle_work_and_keep_shared_leads_and_unassigned_people() {
  local home out extra
  home=$(make_home projects-and-people)
  extra=$(jq -n '{requests:[],coverage:[],projects:[
    {name:"Idle project",delivery:"Changes stay local.",status:"No current work",detail:"Still managed.",questions:[]},
    {name:"Reports",delivery:"Production changes need automated validation.",status:"Working",detail:"Two people are assigned.",questions:[]},
    {name:"Portal",delivery:"You decide whether to publish.",status:"Working",detail:"One lead is assigned.",questions:[]}
  ],crew:[
    {id:"routing-only-worker",name:"Improve report loading",role:"Worker",status:"Paused",detail:"Waiting for an approved test refresh.",projects:["Reports"],questions:[{issue:"Report data is old.",choice:"Approve a test-only refresh or select another source.",recommendation:"Use the test-only refresh; do not change production."}]},
    {id:"routing-only-lead",name:"Reporting and portal coordination",role:"Project lead",status:"Working",detail:"Coordinating both projects.",projects:["Reports","Portal"],questions:[]},
    {id:"routing-only-unknown",name:"Assignment to confirm",role:"Worker",status:"Status not confirmed",detail:"Project ownership could not be verified.",projects:[],questions:[]}
  ]}')
  out=$(render_board "$home" '[]' '[]' 0 0 '[]' '[]' "$extra")
  printf '%s' "$out" | jq -e '
    .error == "" and .projectsHidden == false
    and [.projects[].name] == ["Reports","Portal","Project not confirmed"]
    and (.projects | tostring | contains("Idle project") | not)
    and [.projects[0].people[].name] == ["Improve report loading","Reporting and portal coordination"]
    and .projects[1].people[0].role == "Project lead"
    and .projects[2].people[0].name == "Assignment to confirm"
    and (.projects[0].people[0].questions[0] | contains("What it isReport data is old.") and contains("Your choiceApprove") and contains("RecommendationUse the test-only refresh"))
    and (.projects | tostring | contains("routing-only") | not)
    and (.stats | any(.label == "projects" and .n == 3))
    and (.stats | any(.label == "people" and .n == 3))
  ' >/dev/null || fail "project grouping showed an idle project or dropped people or questions: $out"
  pass "project board drops idle projects and keeps shared leads, explained questions and unassigned people without routing ids"
}

test_a_status_page_of_only_idle_projects_has_no_project_panel() {
  local home out extra
  home=$(make_home projects-all-idle)
  extra=$(jq -n '{requests:[],coverage:[],projects:[
    {name:"Idle one",delivery:"Changes stay local.",status:"No current work",detail:"Still managed.",questions:[]},
    {name:"Idle two",delivery:"You decide whether to publish.",status:"No current work",detail:"Still managed.",questions:[]}
  ],crew:[]}')
  out=$(render_board "$home" '[]' '[]' 0 0 '[]' '[]' "$extra")
  printf '%s' "$out" | jq -e '
    .error == "" and .projects == [] and .projectsHidden == true
  ' >/dev/null || fail "idle projects still rendered a project panel: $out"
  pass "a status page whose projects are all idle shows no project panel"
}

test_needs_you_comes_before_open_work_and_the_queue() {
  local home out
  home=$(make_home section-order)
  out=$(render_board "$home" '[]' '[]')
  printf '%s' "$out" | jq -e '
    .order[0:3] == ["call", "current", "charted"]
  ' >/dev/null || fail "Needs you is not the first board section: $out"
  pass "Needs you renders above open work and the waiting queue"
}

test_empty_sections_and_idle_projects_do_not_take_up_space() {
  local home out
  home=$(make_home empty-sections)
  out=$(render_board "$home" '[]' '[]')
  printf '%s' "$out" | jq -e '
    .error == "" and .idle == true
    and ([.sections[].hidden] | all)
    and (.underway | length) == 0 and (.charted | length) == 0
  ' >/dev/null || fail "empty sections occupied the board: $out"
  pass "idle projects have no panel; an empty fleet has one short empty state"
}

test_mixed_projects_stay_in_one_list_with_status_colors_and_disclosures() {
  local home out
  home=$(make_home mixed-projects)
  out=$(render_board "$home" '[
    {"id":"a","name":"Active task","repo":"alpha","state":"working","doing":"Reviewing changes","kind":"ship"},
    {"id":"b","name":"Blocked task","repo":"beta","state":"blocked","doing":"Awaiting permission","kind":"ship"},
    {"id":"c","name":"Paused task","repo":"alpha","state":"paused","doing":"Waiting for release","kind":"ship"},
    {"id":"d","name":"Review task","repo":"beta","state":"reviewing","doing":"Checking evidence","kind":"ship"},
    {"id":"e","name":"Unknown task","repo":null,"state":"future-state","doing":"Unrecognized status remains visible","kind":"ship"}
  ]' '[
    {"id":"q","title":"Queued task","repo":"gamma","reason":"Waiting for capacity","dispatchable":true},
    {"id":"w","title":"Repair warning","repo":"delta","reason":"Repair inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '
    .error == "" and .idle == false
    and [.underway[].title] == ["Active task", "Blocked task", "Paused task", "Review task", "Unknown task"]
    and [.underway[].tone] == ["online", "danger", "warn", "info", "neutral"]
    and ([.underway[], .charted[]] | all(.disclosure and .cue == "Current status" and (.detail | length > 0)))
    and .sections.current.hidden == false and .sections.charted.hidden == false
    and .sections.call.hidden == true and .sections.landed.hidden == true
  ' >/dev/null || fail "the mixed-project open-work list lost color or disclosures: $out"
  pass "all open work stays together across projects with colored status and expandable details"
}

test_captains_call_answer_contract_is_unchanged() {
  local home out
  home=$(make_home call-answer)
  render_board "$home" '[]' '[]' 0 0 '[
    {"key":"sample-call","repo":"sample","type":"credential","title":"Choose access",
     "allow_freeform":true,"close":"release","options":[{"value":"yes","label":"Allow"}]}
  ]' >/dev/null
  out=$(node "$HARNESS" "$home/.lavish/bearings-board.html" answer)
  printf '%s' "$out" | jq -e '
    .error == "" and .sections.call.hidden == false
    and (.queued | length) == 1
    and .queued[0].data == {schema:"fm-bearings-answer.v1",question:"sample-call",selection:"yes",note:"a note",close:"release"}
  ' >/dev/null || fail "Captain Call no longer emits the unchanged versioned answer: $out"
  pass "Captain Call still queues fm-bearings-answer.v1 with selection, note and close"
}

test_empty_sections_and_idle_projects_do_not_take_up_space
test_mixed_projects_stay_in_one_list_with_status_colors_and_disclosures
test_captains_call_answer_contract_is_unchanged
test_projects_drop_idle_work_and_keep_shared_leads_and_unassigned_people
test_a_status_page_of_only_idle_projects_has_no_project_panel
test_needs_you_comes_before_open_work_and_the_queue
test_status_page_shows_every_request_and_explained_cards
test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_queued_status_even_without_a_reason
