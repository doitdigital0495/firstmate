#!/usr/bin/env bash
# Behavior tests for bin/fm-live-board-prs.sh, the read-only pull request and
# deploy-run collector behind the live board's timelines and environment
# strips. Stub `gh` and `az` answer from canned forge responses and log every
# call, and a real upstream repository stands in for the forge's git history,
# so the assertions are on the collected document, on the snapshot built from
# it, and on which forge and fetch commands were run - never on source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRS="$ROOT/bin/fm-live-board-prs.sh"
BOARD="$ROOT/bin/fm-live-board-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-board-prs)
trap fm_test_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

check() { jq -e "$2" "$1" >/dev/null || fail "$3: $(jq -c . "$1" 2>/dev/null | cut -c1-1500)"; }

HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$HOME_DIR")
CALLS="$TMP_ROOT/calls.log"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$TMP_ROOT/forge"
: > "$CALLS"

clone() {  # <project> <origin-url>
  git init -q "$HOME_DIR/projects/$1"
  git -C "$HOME_DIR/projects/$1" remote add origin "$2"
}
clone shop 'https://someone:not-a-real-token@github.com/acme/shop.git'
clone docs 'git@github.com:acme/docs.git'
clone broken 'https://github.com/acme/broken'
clone reports 'https://dev.azure.com/acme-org/Insights/_git/reports'
clone ledger 'https://dev.azure.com/acme-org/Insights/_git/ledger'
clone elsewhere 'https://gitlab.example.com/acme/elsewhere.git'
clone offline 'https://github.com/acme/offline.git'
cat > "$HOME_DIR/data/projects.md" <<'REG'
- shop [direct-PR] - fixture (added 2026-01-01)
- docs [direct-PR] - fixture (added 2026-01-01)
- broken [direct-PR] - fixture (added 2026-01-01)
- reports [no-mistakes branch=ship/] - fixture (added 2026-01-01)
- ledger [direct-PR] - fixture (added 2026-01-01)
- elsewhere [direct-PR] - fixture (added 2026-01-01)
- offline [local-only] - fixture (added 2026-01-01)
- missing [direct-PR] - fixture (added 2026-01-01)
REG

# GitHub answers per repository name; a missing file is a failed read. A
# slow-* marker in the forge directory makes that kind of call answer late.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$FM_TEST_CALLS"
[ ! -f "$FM_TEST_FORGE/slow-gh" ] || sleep 6
name= n=
for arg in "$@"; do
  case "$arg" in name=*) name=${arg#name=} ;; n=*) n=${arg#n=} ;; esac
done
# A heavy-<name> marker stands in for GitHub's resource limit: the full
# 50-pull-request query is rejected and only a smaller one is answered.
[ ! -f "$FM_TEST_FORGE/heavy-$name" ] || [ "$n" -le 15 ] || exit 1
[ -f "$FM_TEST_FORGE/gh-$name.json" ] || exit 1
cat "$FM_TEST_FORGE/gh-$name.json"
SH
# Azure DevOps answers per repository and per target branch.
cat > "$FAKEBIN/az" <<'SH'
#!/usr/bin/env bash
printf 'az %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$FM_TEST_CALLS"
repo= branch= project=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repo=$2; shift ;;
    --project) project=$2; shift ;;
    --branch) branch=${2##*/}; shift ;;
  esac
  shift
done
if [ -n "$repo" ]; then file="$FM_TEST_FORGE/az-prs-$repo.json"; else file="$FM_TEST_FORGE/az-runs-$branch.json"; fi
# A project with run lists of its own answers from those.
[ -n "$repo" ] || [ ! -f "$FM_TEST_FORGE/az-runs-$project-$branch.json" ] || file="$FM_TEST_FORGE/az-runs-$project-$branch.json"
if [ -n "$repo" ]; then slow=slow-az-prs; else slow=slow-az-runs; fi
[ ! -f "$FM_TEST_FORGE/$slow" ] || sleep 6
[ -f "$file" ] || exit 1
cat "$file"
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/az"

suite() {  # <status> <conclusion|null> <created> <event|null> <workflow> [<check-runs>]
  jq -cn --arg status "$1" --arg conclusion "$2" --arg created "$3" --arg event "$4" --arg workflow "$5" \
    --argjson runs "${6:-1}" '{status:$status,conclusion:(if $conclusion == "null" then null else $conclusion end),
      createdAt:$created,app:{slug:"github-actions",name:"GitHub Actions"},checkRuns:{totalCount:$runs},
      workflowRun:(if $event == "null" then null else {event:$event,workflow:{name:$workflow}} end)}'
}
gh_pr() {  # <number> <state> <head> <title> <body> <merged-at|null> <suites-json> [<statuses-json>]
  jq -cn --argjson number "$1" --arg state "$2" --arg head "$3" --arg title "$4" --arg body "$5" \
    --arg merged "$6" --argjson suites "$7" --argjson statuses "${8:-[]}" '
    {number:$number,title:$title,body:$body,url:"https://github.com/acme/shop/pull/\($number)",state:$state,
     isDraft:false,createdAt:"2026-10-01T08:00:00Z",headRefName:$head,
     closedAt:(if $state == "OPEN" then null else "2026-10-02T09:00:00Z" end),
     mergedAt:(if $merged == "null" then null else $merged end),
     mergeCommit:(if $state == "MERGED" then {checkSuites:{nodes:$suites},status:{contexts:$statuses}} else null end)}'
}
{
  gh_pr 11 MERGED fm/shop-checkout 'feat(cart): Faster checkout' $'## Intent\n\nCustomers can now pay in one step instead of three.' \
    '2026-10-02T09:00:00Z' "[$(suite COMPLETED FAILURE 2026-10-02T09:01:00Z push Deploy),$(suite COMPLETED SUCCESS 2026-10-02T09:01:00Z push Checks)]"
  gh_pr 12 MERGED fm/shop-retry 'Retry the deploy' '' '2026-10-02T09:00:00Z' \
    "[$(suite COMPLETED FAILURE 2026-10-02T09:01:00Z push Deploy),$(suite COMPLETED SUCCESS 2026-10-02T09:30:00Z workflow_dispatch Deploy)]"
  gh_pr 13 MERGED fm/shop-slow 'Slow one' '' '2026-10-02T09:00:00Z' \
    "[$(suite IN_PROGRESS null 2026-10-02T09:01:00Z push Deploy),$(suite QUEUED null 2026-10-02T09:01:00Z null x 0)]"
  gh_pr 14 MERGED fm/shop-timer 'Timer only' '' '2026-10-02T09:00:00Z' \
    "[$(suite COMPLETED FAILURE 2026-10-02T23:00:00Z schedule Nightly),$(suite COMPLETED CANCELLED 2026-10-02T09:01:00Z push Deploy)]"
  gh_pr 15 MERGED fm/shop-status 'Status deploy' '' '2026-10-02T09:00:00Z' '[]' \
    '[{"context":"vercel","state":"FAILURE","createdAt":"2026-10-02T09:02:00Z"}]'
  gh_pr 16 OPEN fm/shop-open 'Open one' '' null '[]'
  gh_pr 17 CLOSED fm/shop-closed 'Closed one' '' null '[]'
} | jq -cs '{data:{repository:{pullRequests:{nodes:.}}}}' > "$TMP_ROOT/forge/gh-shop.json"
gh_pr 3 MERGED fm/docs-typo 'Fix a typo' '' '2026-10-02T09:00:00Z' "[$(suite QUEUED null 2026-10-02T09:01:00Z null x 0)]" \
  | jq -cs '{data:{repository:{pullRequests:{nodes:.}}}}' > "$TMP_ROOT/forge/gh-docs.json"

SHA_OK=$(printf 'a%.0s' {1..40}); SHA_RED=$(printf 'b%.0s' {1..40}); SHA_OLD=$(printf 'c%.0s' {1..40})
SHA_UAT=$(printf 'd%.0s' {1..40}); SHA_RERUN=$(printf 'e%.0s' {1..40})
SHA_REPLACED=$(printf 'f%.0s' {1..40}); SHA_PARTIAL=$(printf '9%.0s' {1..40})
ado_pr() {  # <id> <status> <source> <target> <closed|null> <sha|null> <title>
  jq -cn --argjson id "$1" --arg status "$2" --arg source "$3" --arg target "$4" --arg closed "$5" \
    --arg sha "$6" --arg title "$7" '{id:$id,title:$title,description:"Stock managers see the weekly total on the first page.",
      status:$status,draft:false,source:"refs/heads/\($source)",target:"refs/heads/\($target)",
      created:"2026-10-01T08:00:00.123456+00:00",closed:(if $closed == "null" then null else $closed end),
      merge_commit:(if $sha == "null" then null else $sha end)}'
}
{
  ado_pr 21 completed ship/stock-total main '2026-10-03T10:00:00.5+00:00' "$SHA_OK" 'Weekly total'
  ado_pr 22 completed ship/stock-red main '2026-10-03T11:00:00.5+00:00' "$SHA_RED" 'Broken deploy'
  ado_pr 23 completed ship/stock-old main '2026-09-01T11:00:00.5+00:00' "$SHA_OLD" 'Ancient change'
  ado_pr 24 completed ship/stock-uat release/uat '2026-10-03T12:00:00.5+00:00' "$SHA_UAT" 'To UAT'
  ado_pr 25 completed ship/stock-rerun main '2026-10-03T13:00:00.5+02:00' "$SHA_RERUN" 'Retried deploy'
  ado_pr 26 active ship/stock-open main null null 'Still open'
  ado_pr 27 abandoned feature/by-hand main '2026-10-03T12:00:00.5+00:00' null 'Dropped'
  ado_pr 28 completed ship/stock-replaced main '2026-10-03T14:00:00.5+00:00' "$SHA_REPLACED" 'Replaced run'
  ado_pr 29 completed ship/stock-partial main '2026-10-03T15:00:00.5+00:00' "$SHA_PARTIAL" 'Partly done'
} | jq -cs . > "$TMP_ROOT/forge/az-prs-reports.json"
ado_run() {  # <id> <name> <status> <result> <reason> <sha> [<repo>]
  jq -cn --argjson id "$1" --arg name "$2" --arg status "$3" --arg result "$4" --arg reason "$5" --arg sha "$6" \
    --arg repo "${7:-reports}" '{id:$id,name:$name,status:$status,result:(if $result == "null" then null else $result end),
      reason:$reason,sha:$sha,repo:$repo,queued:"2026-10-02T00:00:00.1+00:00"}'
}
{
  ado_run 101 reports-deploy completed succeeded individualCI "$SHA_OK"
  ado_run 102 infra-deploy completed succeeded batchedCI "$SHA_OK"
  ado_run 103 nightly completed failed schedule "$SHA_OK"
  ado_run 104 other-repo completed failed individualCI "$SHA_OK" ledger
  ado_run 105 reports-deploy completed succeeded individualCI "$SHA_RED"
  ado_run 106 infra-deploy completed canceled individualCI "$SHA_RED"
  ado_run 107 functions-deploy inProgress null individualCI "$SHA_RED"
  ado_run 108 reports-deploy completed failed individualCI "$SHA_RERUN"
  ado_run 109 reports-deploy completed succeeded manual "$SHA_RERUN"
  ado_run 110 reports-deploy completed canceled individualCI "$SHA_REPLACED"
  ado_run 111 reports-deploy completed partiallySucceeded individualCI "$SHA_PARTIAL"
} | jq -cs . > "$TMP_ROOT/forge/az-runs-main.json"
# The fixture reads at most 400 runs; a full page proves older runs exist.
jq -c '. as $runs | [range(0; 400) | $runs[. % ($runs | length)] + {id:(1000 + .)}] | . + []' \
  "$TMP_ROOT/forge/az-runs-main.json" > "$TMP_ROOT/forge/az-runs-main-full.json"
ado_pr 31 completed fm/ledger-fix main '2026-10-03T10:00:00.5+00:00' "$SHA_OK" 'Ledger fix' \
  | jq -cs . > "$TMP_ROOT/forge/az-prs-ledger.json"

collect() {  # <out>
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_CALLS="$CALLS" \
    FM_TEST_FORGE="$TMP_ROOT/forge" "$PRS" --json > "$1" || fail "the collector failed"
}
project() {  # <prs-doc> <out>; a fixed collection time keeps grace windows stable
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SNAPSHOT_NOW=2026-10-04T00:00:00Z \
    "$BOARD" --json --prs "$1" > "$2" || fail "the snapshot failed"
}
pr() { printf '[.pull_requests.repos[] | select(.project == "%s") | .prs[] | select(.number == %s)][0]' "$1" "$2"; }

# --- Sources -------------------------------------------------------------------
collect "$TMP_ROOT/prs.json"
check "$TMP_ROOT/prs.json" '.schema == "fm-live-board-prs.v1" and (.collected_at_epoch | type == "number")
  and (.repos | map({key:.project,value:"\(.forge)/\(.status)/\(.reason)"}) | from_entries) == {
    "shop":"github/ok/null","docs":"github/ok/null","broken":"github/failed/fetch-failed",
    "reports":"ado/ok/null","ledger":"ado/ok/null","elsewhere":"none/none/unsupported-forge",
    "offline":"none/none/local-only","missing":"none/none/no-clone"}
  and ([.repos[] | select(.project == "reports")][0].branch_prefix == "ship/")' \
  "each project's forge was not read from its clone, or a gap was not named"
assert_no_grep 'not-a-real-token' "$TMP_ROOT/prs.json" "a credential in a remote URL reached the collected document"
pass "every registered project is read from its clone's forge, and each gap says why"

# --- Read-only -----------------------------------------------------------------
[ -s "$CALLS" ] || fail "no forge call was logged"
if grep -vE '^(gh api graphql |az repos pr list |az pipelines runs list )' "$CALLS" | grep -q .; then
  fail "the collector ran a forge command that is not a list read: $(grep -vE '^(gh api graphql |az repos pr list |az pipelines runs list )' "$CALLS")"
fi
if grep -Eq -e ' (-X|--method) |mutation|pipelines run |pr (update|create|set-vote)|runs (tag|artifact)' "$CALLS"; then
  fail "the collector issued a write-shaped forge call"
fi
assert_grep ' -f owner=acme -f name=shop -F n=50 ' "$CALLS" \
  "the owner and repository name did not reach gh as plain strings, so an all-digit name would be sent as a number"
pass "the collector only lists pull requests and runs"

# --- Deploy runs and outcomes --------------------------------------------------
project "$TMP_ROOT/prs.json" "$TMP_ROOT/board.json"
check "$TMP_ROOT/board.json" "$(pr shop 11)"' | .state == "merged" and .task == "shop-checkout"
  and .deploy.outcome == "failed" and .deploy.why == "run-failed"
  and .deploy.runs == [{"name":"Deploy","result":"failed"},{"name":"Checks","result":"succeeded"}]' \
  "a merge whose run failed was not reported as failed with the failed run first"
check "$TMP_ROOT/board.json" "$(pr shop 12)"' | .deploy.outcome == "succeeded" and (.deploy.runs | length) == 1' \
  "a deploy re-run by hand that succeeded did not replace the run it retried"
check "$TMP_ROOT/board.json" "$(pr shop 13)"' | .deploy.outcome == "running" and (.deploy.runs | map(.name)) == ["Deploy"]' \
  "an unfinished deploy was not reported as still running, or an app that never reported counted as one"
check "$TMP_ROOT/board.json" "$(pr shop 14)"' | .deploy.outcome == "none" and .deploy.why == "superseded" and .deploy.runs == []' \
  "a timer run was counted for this change, or a merge whose only run was cancelled was not read as replaced by a newer run"
check "$TMP_ROOT/board.json" "$(pr shop 15)"' | .deploy.outcome == "failed" and .deploy.runs == [{"name":"vercel","result":"failed"}]' \
  "a failed commit status was not read as a failed run after merge"
check "$TMP_ROOT/board.json" "$(pr shop 16)"' | .state == "open" and .deploy.outcome == "not-deployed" and .deploy.why == "open"' \
  "an open pull request was not reported as not deployed yet"
check "$TMP_ROOT/board.json" "$(pr shop 17)"' | .state == "closed" and .deploy.outcome == "not-deployed" and .deploy.why == "closed"' \
  "a pull request closed without merging was not reported as not deployed"
check "$TMP_ROOT/board.json" "$(pr docs 3)"' | .deploy.outcome == "none" and .deploy.why == "project"' \
  "a repository whose merges start no run was not reported as having no deploy"
check "$TMP_ROOT/board.json" '[.pull_requests.repos[] | select(.project == "broken")][0]
  | .status == "failed" and .reason == "fetch-failed" and .prs == []' \
  "a repository whose read failed did not stay visible as unread"
pass "GitHub merges read failed, re-run, running, timer-only, status, open, closed and no-deploy outcomes"

check "$TMP_ROOT/board.json" "$(pr reports 21)"' | .url == "https://dev.azure.com/acme-org/Insights/_git/reports/pullrequest/21"
  and .task == "stock-total" and .deploy.outcome == "succeeded"
  and (.deploy.runs | map(.name)) == ["infra-deploy","reports-deploy"]
  and .summary == "Stock managers see the weekly total on the first page."' \
  "an Azure DevOps merge did not read its own branch's runs, or counted a timer run or another repository's run"
check "$TMP_ROOT/board.json" "$(pr reports 22)"' | .deploy.outcome == "running"
  and .deploy.runs == [{"name":"functions-deploy","result":"running"},{"name":"reports-deploy","result":"succeeded"}]' \
  "a cancelled Azure DevOps run was counted as failed instead of superseded, as a cancelled GitHub run is"
check "$TMP_ROOT/board.json" "$(pr reports 28)"' | .deploy.outcome == "none" and .deploy.why == "superseded" and .deploy.runs == []' \
  "an Azure DevOps merge whose only run was cancelled was not read as replaced by a newer run"
check "$TMP_ROOT/board.json" "$(pr reports 29)"' | .deploy.outcome == "failed" and .deploy.runs == [{"name":"reports-deploy","result":"failed"}]' \
  "a partially succeeded Azure DevOps run was not reported as failed"
check "$TMP_ROOT/board.json" "$(pr reports 25)"' | .deploy.outcome == "succeeded" and .at == 1791025200' \
  "an Azure DevOps re-run did not replace the failed run, or its offset close time was misread"
check "$TMP_ROOT/board.json" "$(pr reports 24)"' | .deploy.outcome == "unknown" and .deploy.why == "unreadable"' \
  "a merge onto a branch whose runs could not be read was given a verdict"
check "$TMP_ROOT/board.json" "$(pr reports 23)"' | .deploy.outcome == "none" and .deploy.why == "change"' \
  "a merge with no run inside a fully read history was not reported as having started none"
check "$TMP_ROOT/board.json" "$(pr reports 26)"' | .deploy.why == "open"' "an active Azure DevOps pull request was not open"
check "$TMP_ROOT/board.json" "$(pr reports 27)"' | .state == "closed" and .task == null and .deploy.why == "closed"' \
  "an abandoned pull request was not closed, or a branch outside the ship prefix was given a task"
check "$TMP_ROOT/board.json" "$(pr ledger 31)"' | .task == "ledger-fix" and .deploy.outcome == "failed"
  and .deploy.runs == [{"name":"other-repo","result":"failed"}]' \
  "a second repository in the same Azure DevOps project did not read only its own runs"
pass "Azure DevOps merges read succeeded, failed, re-run, unreadable, open, abandoned and no-deploy outcomes"

# --- History older than the runs that were read --------------------------------
cp "$TMP_ROOT/forge/az-runs-main-full.json" "$TMP_ROOT/forge/az-runs-main.json"
collect "$TMP_ROOT/prs-full.json"
project "$TMP_ROOT/prs-full.json" "$TMP_ROOT/board-full.json"
check "$TMP_ROOT/board-full.json" "$(pr reports 23)"' | .deploy.outcome == "unknown" and .deploy.why == "too-old"' \
  "a merge older than the runs that were read was given a no-deploy verdict"
check "$TMP_ROOT/board-full.json" "$(pr reports 21)"' | .deploy.outcome == "succeeded"' \
  "a full page of runs lost a merge whose runs were on it"
pass "a merge older than the deploy history that was read is unknown, never 'no deploy'"

# --- A repository GitHub will not answer in full ------------------------------
: > "$TMP_ROOT/forge/heavy-docs"
collect "$TMP_ROOT/prs-heavy.json"
rm -f "$TMP_ROOT/forge/heavy-docs"
check "$TMP_ROOT/prs-heavy.json" '[.repos[] | select(.project == "docs")][0] | .status == "ok" and (.prs | map(.number)) == [3]' \
  "a repository whose 50-pull-request query GitHub rejects got no timeline instead of a smaller read"
pass "a GitHub repository too heavy for the full query is still read with a smaller one"

# --- Time bounds ---------------------------------------------------------------
# The collector with one second per forge call and two per Azure DevOps source,
# against forge tools that would answer correctly a few seconds later.
collect_bounded() {  # <out>
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_CALLS="$CALLS" \
    FM_TEST_FORGE="$TMP_ROOT/forge" bash -c 'prs=$1; shift; . "$prs"; CALL_TIMEOUT=1; SOURCE_BUDGET=2; collect_all' _ "$PRS" \
    > "$1" || fail "the bounded collector failed"
}
status_of() { printf '[.repos[] | select(.project == "%s")][0] | "\\(.forge)/\\(.status)/\\(.reason)"' "$1"; }
: > "$TMP_ROOT/forge/slow-gh"
: > "$TMP_ROOT/forge/slow-az-prs"
collect_bounded "$TMP_ROOT/prs-slow.json"
check "$TMP_ROOT/prs-slow.json" "$(status_of shop)"' == "github/failed/fetch-failed"' \
  "a GitHub read that outlasted its time bound was waited for"
check "$TMP_ROOT/prs-slow.json" "$(status_of reports)"' == "ado/failed/fetch-failed"' \
  "an Azure DevOps pull request read that outlasted its time bound was waited for"
rm -f "$TMP_ROOT/forge/slow-gh" "$TMP_ROOT/forge/slow-az-prs" "$TMP_ROOT/forge/az-prs-ledger.json"

# Four target branches whose run lists each outlast the call bound: every merge
# is unreadable, and the source budget stops the reads before the last branch.
index=0
for sha in "$SHA_OK" "$SHA_RED" "$SHA_OLD" "$SHA_UAT"; do
  index=$((index + 1))
  ado_pr "4$index" completed "ship/slow-$index" "slow$index" '2026-10-03T10:00:00.5+00:00' "$sha" "Slow $index"
  ado_run "20$index" reports-deploy completed succeeded individualCI "$sha" | jq -cs . > "$TMP_ROOT/forge/az-runs-slow$index.json"
done | jq -cs . > "$TMP_ROOT/forge/az-prs-reports.json"
: > "$TMP_ROOT/forge/slow-az-runs"
: > "$CALLS"
collect_bounded "$TMP_ROOT/prs-budget.json"
project "$TMP_ROOT/prs-budget.json" "$TMP_ROOT/board-budget.json"
check "$TMP_ROOT/prs-budget.json" "$(status_of reports)"' == "ado/ok/null"' \
  "slow run lists failed the whole Azure DevOps source"
check "$TMP_ROOT/board-budget.json" '[.pull_requests.repos[] | select(.project == "reports")][0].prs
  | length == 4 and all(.[]; .deploy.outcome == "unknown" and .deploy.why == "unreadable")' \
  "a run list that outlasted its time bound was waited for, or a branch the budget skipped was given a verdict"
check "$TMP_ROOT/board-budget.json" '[.pull_requests.repos[] | select(.project == "shop")][0] | .status == "ok" and (.prs | length) == 7' \
  "a slow Azure DevOps source cost another project its pull requests"
runs_read=$(grep -c '^az pipelines runs list ' "$CALLS")
[ "$runs_read" -ge 1 ] && [ "$runs_read" -lt 4 ] \
  || fail "the source budget did not stop the run-list reads before the last branch: $runs_read of 4 were made"
pass "each forge call and each Azure DevOps source is cut off at its time bound, and what was not read is unknown"

# --- Environments ----------------------------------------------------------------
# A real upstream repository with one branch per environment stands in for the
# forge's git history. Its merges are the pull requests the forge stub lists:
#   54        squash-merged into DEV, then carried up by merging the branches
#   51        merged into DEV only
#   52        merged into DEV, cherry-picked into UAT by 53, and 53's merge
#             cherry-picked into PROD by 58
#   59        merged into DEV, cherry-picked into UAT by 60
#   61        merged into DEV, redone by hand on UAT by 62 with no recorded pick
check "$TMP_ROOT/prs.json" '.environment_config == "absent" and all(.repos[]; .environments == null)
  and all(.repos[].prs[]; .environment == null)' \
  "a home with no environment list still reported environments"
rm -f "$TMP_ROOT/forge/slow-az-runs"
REAL_GIT=$(command -v git)
UP="$TMP_ROOT/forge/upstream/stages"
fm_git_identity
mkdir -p "$UP"
g() { git -C "$UP" "$@" >/dev/null 2>&1 || fail "fixture git $* failed"; }
change() {  # <file> <message>
  printf '%s\n' "$2" >> "$UP/$1"
  g add "$1"
  g commit -qm "$2"
}
land() {  # <into> <branch>; a merge commit, as a completed pull request leaves
  g checkout -q "$1"
  g merge -q --no-ff -m "Merge $2 into $1" "$2"
  git -C "$UP" rev-parse HEAD
}
g init -q
g checkout -q -b main
change base.txt 'Base'
g branch release/uat
g branch release/prod
change everywhere.txt 'Everywhere'
M54=$(git -C "$UP" rev-parse HEAD)
M55=$(land release/uat main)
M56=$(land release/prod release/uat)
g checkout -q -b fm/st-devonly main
change devonly.txt 'Dev only'
M51=$(land main fm/st-devonly)
g checkout -q -b fm/st-picked main
change picked.txt 'Picked one'
change picked.txt 'Picked two'
M52=$(land main fm/st-picked)
g checkout -q -b cherry/uat-52 release/uat
g cherry-pick -x fm/st-picked~1 fm/st-picked
M53=$(land release/uat cherry/uat-52)
g checkout -q -b cherry/prod-53 release/prod
g cherry-pick -x -m 1 "$M53"
M58=$(land release/prod cherry/prod-53)
g checkout -q -b fm/st-halfway main
change halfway.txt 'Halfway'
M59=$(land main fm/st-halfway)
g checkout -q -b cherry/uat-59 release/uat
g cherry-pick -x fm/st-halfway
M60=$(land release/uat cherry/uat-59)
g checkout -q -b fm/st-redone main
change redone.txt 'Redone'
M61=$(land main fm/st-redone)
g checkout -q -b fm/st-redone-uat release/uat
change redone.txt 'Redone'
M62=$(land release/uat fm/st-redone-uat)
upstream_refs=$(git -C "$UP" for-each-ref)

# The real git, with a fetch of the fixture forge's address logged and served
# from the upstream of the same name, or refused while the forge is offline.
cat > "$FAKEBIN/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" fetch "*)
    printf 'git %s\n' "\$*" >> "\$FM_TEST_CALLS"
    [ ! -f "\$FM_TEST_FORGE/git-offline" ] || exit 128
    export GIT_CONFIG_VALUE_0="\$FM_TEST_FORGE/upstream/\${GIT_CONFIG_VALUE_0##*/}"
    ;;
esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$FAKEBIN/git"
clone stages 'https://someone:not-a-real-token@dev.azure.com/acme-org/Stages/_git/stages'
printf -- '- stages [direct-PR] - fixture (added 2026-01-01)\n' >> "$HOME_DIR/data/projects.md"
{
  ado_pr 51 completed fm/st-devonly main '2026-10-03T10:00:00.5+00:00' "$M51" 'Dev only change'
  ado_pr 52 completed fm/st-picked main '2026-10-03T10:10:00.5+00:00' "$M52" 'Picked change'
  ado_pr 53 completed cherry/uat-52 release/uat '2026-10-03T10:20:00.5+00:00' "$M53" 'Promote the picked change to UAT'
  ado_pr 54 completed fm/st-everywhere main '2026-10-03T09:00:00.5+00:00' "$M54" 'Everywhere change'
  ado_pr 55 completed promote/uat release/uat '2026-10-03T09:10:00.5+00:00' "$M55" 'Promote to UAT'
  ado_pr 56 completed promote/prod release/prod '2026-10-03T09:20:00.5+00:00' "$M56" 'Promote to PROD'
  ado_pr 58 completed cherry/prod-53 release/prod '2026-10-03T10:30:00.5+00:00' "$M58" 'Promote the picked change to PROD'
  ado_pr 59 completed fm/st-halfway main '2026-10-03T10:40:00.5+00:00' "$M59" 'Halfway change'
  ado_pr 60 completed cherry/uat-59 release/uat '2026-10-03T10:50:00.5+00:00' "$M60" 'Promote the halfway change to UAT'
  ado_pr 61 completed fm/st-redone main '2026-10-03T11:00:00.5+00:00' "$M61" 'Redone change'
  ado_pr 62 completed fm/st-redone-uat release/uat '2026-10-03T11:10:00.5+00:00' "$M62" 'Redo on UAT'
  ado_pr 63 active fm/st-open main null null 'Open one'
  ado_pr 64 completed fm/st-side feature/side '2026-10-03T11:20:00.5+00:00' "$M51" 'Onto a side branch'
  ado_pr 65 completed fm/st-lost main '2026-10-03T11:30:00.5+00:00' "$SHA_OLD" 'Merge the history lacks'
} | jq -cs . > "$TMP_ROOT/forge/az-prs-stages.json"
ado_run 301 stages-deploy completed succeeded individualCI "$M61" stages | jq -cs . > "$TMP_ROOT/forge/az-runs-Stages-main.json"
ado_run 302 stages-deploy completed failed individualCI "$M62" stages | jq -cs . > "$TMP_ROOT/forge/az-runs-Stages-uat.json"
STAGES='{"schema":"fm-live-board-environments.v1","repos":[{"repo":"stages","environments":[
  {"name":"DEV","branch":"main"},{"name":"UAT","branch":"release/uat"},{"name":"PROD","branch":"release/prod"}]}]}'
printf '%s\n' "$STAGES" > "$HOME_DIR/config/live-board-environments.json"
collect_staged() {  # <out>
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_CALLS="$CALLS" \
    FM_TEST_FORGE="$TMP_ROOT/forge" "$PRS" --json --git-cache "$TMP_ROOT/cache" > "$1" || fail "the collector failed"
}
stages() { printf '[.repos[] | select(.project == "stages")][0]'; }

: > "$CALLS"
collect_staged "$TMP_ROOT/prs-stages.json"
check "$TMP_ROOT/prs-stages.json" '.environment_config == "ok"
  and all(.repos[] | select(.project != "stages"); .environments == null and all(.prs[]; .environment == null))' \
  "a project the environment list does not name was given environments"
check "$TMP_ROOT/prs-stages.json" "$(stages)"' | .status == "ok" and .window_full == false
  and .environments == {status:"ok",reason:null,stages:[{name:"DEV",branch:"main"},{name:"UAT",branch:"release/uat"},{name:"PROD",branch:"release/prod"}]}' \
  "a project with environments did not carry them in order"
reach='[.prs[] | select(.environment != null)
  | {key:(.number | tostring),value:(.environment.reached | if . == null then "unknown" else map(if . then "y" else "n" end) | join("") end)}] | from_entries'
check "$TMP_ROOT/prs-stages.json" "$(stages) | $reach"' | .["51"] == "ynn" and .["61"] == "ynn"' \
  "a change merged into DEV only, or one redone by hand elsewhere with no recorded pick, was said to have reached UAT"
check "$TMP_ROOT/prs-stages.json" "$(stages) | $reach"' | .["59"] == "yyn" and .["60"] == "yyn"' \
  "a change cherry-picked into UAT was not read as in DEV and UAT only"
check "$TMP_ROOT/prs-stages.json" "$(stages) | $reach"' | .["52"] == "yyy" and .["53"] == "yyy" and .["58"] == "nyy"' \
  "a change that reached PROD through a cherry-picked merge was not followed all the way"
check "$TMP_ROOT/prs-stages.json" "$(stages) | $reach"' | .["54"] == "yyy" and .["55"] == "nyy" and .["56"] == "nny" and .["62"] == "nyn"' \
  "a change carried up by merging the branches was not read from the branches that contain it"
check "$TMP_ROOT/prs-stages.json" "$(stages) | $reach"' | .["65"] == "unknown" and (has("63") or has("64") | not)' \
  "a merge the history lacks was given a verdict, or an open pull request or one onto another branch was placed in an environment"
check "$TMP_ROOT/prs-stages.json" "$(stages)"' | [.prs[] | select(.environment != null) | {key:(.number | tostring),value:.environment}] | from_entries
  | (map_values(.stage) | .["51"] == 0 and .["53"] == 1 and .["58"] == 2 and .["65"] == 0)
    and (map_values(.copy_of) | .["53"] == [52] and .["58"] == [53] and .["60"] == [59] and .["62"] == [] and .["52"] == [])' \
  "a pull request was not placed in the environment it merged into, or a promotion did not name the change it carries"
pass "each merged change is placed from the branches' own history: DEV only, DEV and UAT, all three, and never by a guess"

project "$TMP_ROOT/prs-stages.json" "$TMP_ROOT/board-stages.json"
check "$TMP_ROOT/board-stages.json" '.pull_requests.environment_config == "ok"
  and ([.pull_requests.repos[] | select(.project == "stages")][0].environments == {status:"ok",reason:null,names:["DEV","UAT","PROD"]})
  and ([.pull_requests.repos[] | select(.project == "shop")][0].environments == null)' \
  "the snapshot did not carry which projects have environments"
check "$TMP_ROOT/board-stages.json" "$(pr stages 53)"' | .environment == {stage:1,reached:[true,true,true],copy_of:[52]} and .task == "st-picked"' \
  "a promotion did not keep its place, or did not join the task of the change it carries"
check "$TMP_ROOT/board-stages.json" "$(pr stages 62)"' | .deploy.outcome == "failed" and .environment.stage == 1' \
  "a failed run on the newest merge into an environment was not reported as failed"
check "$TMP_ROOT/board-stages.json" "$(pr stages 58)"' | .deploy.outcome == "unknown" and .deploy.why == "unreadable"' \
  "an environment whose runs could not be read was given a deploy verdict"
check "$TMP_ROOT/board-stages.json" "$(pr stages 63)"' | .environment == null' "an open pull request was placed in an environment"
pass "the snapshot carries each change's place, and a failed or unreadable deploy on an environment stays what it is"

if grep '^git ' "$CALLS" | grep -vE '^git --git-dir=[^ ]+ fetch --quiet --no-tags origin( \+refs/heads/[A-Za-z0-9._/-]+:refs/heads/stage-[0-9]+)+$' | grep -q .; then
  fail "the collector ran a git command against the forge that is not a fetch of the environment branches: $(grep '^git ' "$CALLS")"
fi
[ "$(grep -c '^git ' "$CALLS")" = 1 ] || fail "the environment branches were not fetched exactly once: $(grep '^git ' "$CALLS")"
assert_equals "$upstream_refs" "$(git -C "$UP" for-each-ref)" "the collector changed the upstream repository"
[ -z "$("$REAL_GIT" -C "$HOME_DIR/projects/stages" for-each-ref)" ] || fail "the collector wrote refs into the project's clone"
[ -d "$TMP_ROOT/cache/stages.git" ] || fail "the fetched history was not kept under the given cache directory"
if grep -rq 'not-a-real-token' "$TMP_ROOT/cache" "$CALLS" "$TMP_ROOT/prs-stages.json"; then
  fail "a credential in the remote URL reached the cache, a command line or the collected document"
fi
grep -Eq '^az repos pr list .*--repository stages .*--top 1000 ' "$CALLS" || fail "a project with environments was not read far back"
grep -Eq '^az repos pr list .*--repository reports .*--top 200 ' "$CALLS" \
  || fail "a project without environments was read further back than before"
pass "environment history is fetched read-only into the cache, never into the clone, and no credential leaves the remote URL"

# The forge's git is unreachable: the pull requests still read, and nothing is
# said about environments - the history fetched a moment ago is not reused.
: > "$TMP_ROOT/forge/git-offline"
collect_staged "$TMP_ROOT/prs-offline.json"
rm -f "$TMP_ROOT/forge/git-offline"
check "$TMP_ROOT/prs-offline.json" "$(stages)"' | .status == "ok" and (.prs | length) == 14
  and .environments.status == "failed" and .environments.reason == "fetch-failed"
  and (.environments.stages | map(.name)) == ["DEV","UAT","PROD"] and all(.prs[]; .environment == null)' \
  "a failed fetch of the environment branches still placed changes, or cost the project its pull requests"
mv "$TMP_ROOT/forge/az-prs-stages.json" "$TMP_ROOT/forge/az-prs-stages.kept"
collect_staged "$TMP_ROOT/prs-unread.json"
mv "$TMP_ROOT/forge/az-prs-stages.kept" "$TMP_ROOT/forge/az-prs-stages.json"
check "$TMP_ROOT/prs-unread.json" "$(stages)"' | .status == "failed" and .environments.status == "failed" and .environments.reason == "prs-unread"' \
  "a project whose pull requests were not read did not say its environments are unknown for that reason"
project "$TMP_ROOT/prs-offline.json" "$TMP_ROOT/board-offline.json"
check "$TMP_ROOT/board-offline.json" '[.pull_requests.repos[] | select(.project == "stages")][0]
  | .environments == {status:"failed",reason:"fetch-failed",names:["DEV","UAT","PROD"]} and all(.prs[]; .environment == null)' \
  "the snapshot gave a verdict for environments whose history was not fetched"
pass "a failed fetch or an unread project leaves its environments unknown with the reason"

printf '%s\n' '{"schema":"fm-live-board-environments.v1","repos":[{"repo":"stages","environments":[{"name":"DEV","branch":"main"}]}]}' \
  > "$HOME_DIR/config/live-board-environments.json"
collect_staged "$TMP_ROOT/prs-invalid.json"
check "$TMP_ROOT/prs-invalid.json" '.environment_config == "invalid" and all(.repos[]; .environments == null)' \
  "an invalid environment list was used, or was not reported as invalid"
pass "an invalid environment list is reported and gives no project environments"
