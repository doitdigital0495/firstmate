#!/usr/bin/env bash
# Behavior tests for bin/fm-live-board-prs.sh, the read-only pull request and
# deploy-run collector behind the live board's timelines. Stub `gh` and `az`
# answer from canned forge responses and log every call, so the assertions are
# on the collected document, on the snapshot built from it, and on which forge
# commands were run - never on source text.
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

# GitHub answers per repository name; a missing file is a failed read.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$FM_TEST_CALLS"
name=
for arg in "$@"; do
  case "$arg" in name=*) name=${arg#name=} ;; esac
done
[ -f "$FM_TEST_FORGE/gh-$name.json" ] || exit 1
cat "$FM_TEST_FORGE/gh-$name.json"
SH
# Azure DevOps answers per repository and per target branch.
cat > "$FAKEBIN/az" <<'SH'
#!/usr/bin/env bash
printf 'az %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$FM_TEST_CALLS"
repo= branch=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repo=$2; shift ;;
    --branch) branch=${2##*/}; shift ;;
  esac
  shift
done
if [ -n "$repo" ]; then file="$FM_TEST_FORGE/az-prs-$repo.json"; else file="$FM_TEST_FORGE/az-runs-$branch.json"; fi
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
pass "the collector only lists pull requests and runs"

# --- Deploy runs and outcomes --------------------------------------------------
project "$TMP_ROOT/prs.json" "$TMP_ROOT/board.json"
check "$TMP_ROOT/board.json" "$(pr shop 11)"' | .state == "merged" and .task == "shop-checkout"
  and .deploy.outcome == "failed" and .deploy.why == "run-failed"
  and .deploy.runs == [{"name":"Deploy","result":"failed"},{"name":"Checks","result":"succeeded"}]' \
  "a merge whose deploy run failed was not reported as a failed deploy with the failed run first"
check "$TMP_ROOT/board.json" "$(pr shop 12)"' | .deploy.outcome == "succeeded" and (.deploy.runs | length) == 1' \
  "a deploy re-run by hand that succeeded did not replace the run it retried"
check "$TMP_ROOT/board.json" "$(pr shop 13)"' | .deploy.outcome == "running" and (.deploy.runs | map(.name)) == ["Deploy"]' \
  "an unfinished deploy was not reported as still running, or an app that never reported counted as one"
check "$TMP_ROOT/board.json" "$(pr shop 14)"' | .deploy.outcome == "none" and .deploy.why == "change" and .deploy.runs == []' \
  "a timer run or a superseded run was counted as this change's deploy"
check "$TMP_ROOT/board.json" "$(pr shop 15)"' | .deploy.outcome == "failed" and .deploy.runs == [{"name":"vercel","result":"failed"}]' \
  "a failed commit status was not read as a failed deploy"
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
check "$TMP_ROOT/board.json" "$(pr reports 22)"' | .deploy.outcome == "failed"
  and .deploy.runs == [{"name":"infra-deploy","result":"failed"},{"name":"functions-deploy","result":"running"},
    {"name":"reports-deploy","result":"succeeded"}]' \
  "a cancelled Azure DevOps deploy run was not reported as failed ahead of the unfinished one"
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
