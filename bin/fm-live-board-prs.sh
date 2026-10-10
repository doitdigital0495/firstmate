#!/usr/bin/env bash
# fm-live-board-prs.sh - read each project's recent pull requests and the
# runs their merges started, for the live board's timelines.
#
# Usage: fm-live-board-prs.sh [--json]
#
# Read-only: it lists pull requests and runs and nothing else. It never queues
# or re-runs a pipeline, votes, merges, comments or writes to a forge, and it
# changes no home state. bin/fm-live-board.sh owns when it runs and where its
# output is cached; bin/fm-live-board-prs.jq owns every rule named below.
#
# SOURCES. Every project in the registry (bin/fm-project-mode.sh --list-json)
# whose clone under the home's projects directory has an `origin` remote on a
# supported forge, plus the home's own checkout under its directory name. The
# forge is read from that remote URL, never guessed from a name or a mode:
#   github  github.com, read with one `gh api graphql` call: the 50 most
#           recently updated pull requests, each merged one with the check
#           suites and commit statuses on its merge commit. A merge or close
#           is an update, so the newest of those are always among them. A
#           read that fails is tried once more for the 15 most recently
#           updated, which GitHub still answers for a repository whose merges
#           carry too many check suites for 50. Comments on old pull requests
#           use places in that read too, so the small one can still miss a
#           merge.
#   ado     dev.azure.com, read with `az repos pr list` (the 200 newest, all
#           states) and one `az pipelines runs list` per target branch those
#           merges landed on (the 400 newest runs, at most four branches).
# A local-only project, a project without a clone, a remote on another forge
# and a missing CLI are reported as status `none` with that reason; a failed or
# timed-out read is status `failed`. Each forge call is bounded by 25 seconds
# and each source by 70 in total, and the projects are read side by side, so
# the whole read stays inside the 90 seconds bin/fm-live-board.sh allows it: an
# Azure DevOps branch whose runs were not read in time is unreadable for its
# merges only.
#
# RUNS AFTER MERGE. A merged pull request's runs are the ones on its merge
# commit on the branch it merged into: every Azure DevOps pipeline run there
# except timer and pull-request validation runs, and on GitHub every check
# suite that reported at least one check plus every commit status, keeping
# workflow runs a merge sets off or someone starts by hand and dropping timer
# runs. No pipeline or workflow name is assumed, so these are every run a
# merge started, a deploy or not. The newest run per name counts, so a re-run
# replaces the run it retried. A cancelled run is `superseded` on both forges,
# never failed. An Azure DevOps merge older than the oldest run read on its
# branch is marked `out-of-window`, never "no run".
#
# OUTPUT. One fm-live-board-prs.v1 document on stdout:
#   {schema, collected_at, collected_at_epoch, repos:[{project, forge,
#    status: ok|failed|none, reason, branch_prefix, prs:[{number, url, title,
#    body, body_truncated, state: open|merged|closed, draft, branch, opened_at,
#    closed_at, merged_at, runs:{status: ok|failed|not-merged|out-of-window,
#    items:[{name, result: succeeded|failed|running|skipped|superseded}]}}]}]}
# Times are epoch seconds. body is the description, cut to 4000 characters; it
# is private working data that bin/fm-live-board-snapshot.sh reduces to a short
# plain summary and never republishes, so bin/fm-live-board.sh caches this
# document under the home's state directory, never beside the served board.
# Remote URLs are never printed.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CALL_TIMEOUT=25
SOURCE_BUDGET=70
GITHUB_FETCH=50
GITHUB_FETCH_SMALL=15
ADO_FETCH=200
ADO_RUNS=400
ADO_BRANCHES=4
BODY_CAP=4000

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo 'fm-live-board-prs: jq not found' >&2; exit 1; }

tmp=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-live-board-prs.XXXXXX") || exit 1
trap 'rm -rf -- "$tmp"' EXIT

# Print one repo record that carries no pull requests.
repo_note() {  # <project> <forge> <status> <reason> <branch-prefix>
  jq -cn --arg project "$1" --arg forge "$2" --arg status "$3" --arg reason "$4" --arg prefix "$5" \
    '{project:$project,forge:$forge,status:$status,reason:$reason,branch_prefix:$prefix,prs:[]}'
}

# shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
GITHUB_QUERY='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){
  pullRequests(first:$n,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{
    number title body url state isDraft createdAt closedAt mergedAt headRefName
    mergeCommit{
      checkSuites(first:40){nodes{status conclusion createdAt app{slug name}
        checkRuns(first:1){totalCount} workflowRun{event workflow{name}}}}
      status{contexts{context state createdAt}}}}}}}'

collect_github() {  # <project> <prefix> <owner> <name> <out>
  local project=$1 prefix=$2 owner=$3 name=$4 out=$5 raw="$5.raw" n
  command -v gh >/dev/null 2>&1 || { repo_note "$project" github none no-cli "$prefix" > "$out"; return 0; }
  # GitHub rejects the full query on a repository whose merges carry many
  # check suites ("Resource limits for this query exceeded"), so a failed read
  # is asked once more for the pull requests the board shows.
  for n in "$GITHUB_FETCH" "$GITHUB_FETCH_SMALL"; do
    if GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 fm_run_timed "$CALL_TIMEOUT" gh api graphql -f query="$GITHUB_QUERY" \
        -f owner="$owner" -f name="$name" -F n="$n" > "$raw" 2>/dev/null \
      && jq -L "$SCRIPT_DIR" -c --arg project "$project" --arg prefix "$prefix" --argjson cap "$BODY_CAP" '
          include "fm-live-board-prs";
          {project:$project,forge:"github",status:"ok",reason:null,branch_prefix:$prefix,prs:lbp_github_prs($cap)}' \
          "$raw" > "$out" 2>/dev/null \
      && [ -s "$out" ]; then
      return 0
    fi
  done
  repo_note "$project" github failed fetch-failed "$prefix" > "$out"
}

collect_ado() {  # <project> <prefix> <org> <ado-project> <repo> <out>
  local project=$1 prefix=$2 org=$3 ado_project=$4 repo=$5 out=$6
  local az_bin org_url base branch index=0 list="$6.prs" branches="$6.branches"
  local deadline=$((SECONDS + SOURCE_BUDGET)) left
  az_bin=$(fm_ado_az_bin) || { repo_note "$project" ado none no-cli "$prefix" > "$out"; return 0; }
  org_url="https://dev.azure.com/$org"
  base="$org_url/$ado_project/_git/$repo"
  if ! fm_run_timed "$CALL_TIMEOUT" "$az_bin" repos pr list --organization "$org_url" --project "$ado_project" \
      --repository "$repo" --status all --top "$ADO_FETCH" --output json \
      --query '[].{id:pullRequestId,title:title,description:description,status:status,draft:isDraft,source:sourceRefName,target:targetRefName,created:creationDate,closed:closedDate,merge_commit:lastMergeCommit.commitId}' \
      > "$list" 2>/dev/null \
    || ! jq -e 'type == "array"' "$list" >/dev/null 2>&1; then
    repo_note "$project" ado failed fetch-failed "$prefix" > "$out"
    return 0
  fi
  printf '{}\n' > "$branches"
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    index=$((index + 1))
    left=$((deadline - SECONDS))
    [ "$left" -lt "$CALL_TIMEOUT" ] || left=$CALL_TIMEOUT
    if [ "$left" -gt 0 ] && fm_run_timed "$left" "$az_bin" pipelines runs list --organization "$org_url" --project "$ado_project" \
        --branch "$branch" --top "$ADO_RUNS" --query-order QueueTimeDesc --output json \
        --query '[].{id:id,name:definition.name,status:status,result:result,reason:reason,sha:sourceVersion,repo:repository.name,queued:queueTime}' \
        > "$out.runs.$index" 2>/dev/null \
      && jq -L "$SCRIPT_DIR" -c --arg repo "$repo" --argjson top "$ADO_RUNS" \
          'include "fm-live-board-prs"; if type == "array" then lbp_ado_branch($repo; $top) else error("not a run list") end' \
          "$out.runs.$index" > "$out.branch.$index" 2>/dev/null; then
      :
    else
      printf '{"status":"failed"}\n' > "$out.branch.$index"
    fi
    jq -c --arg branch "$branch" --slurpfile value "$out.branch.$index" '. + {($branch):$value[0]}' \
      "$branches" > "$branches.next" && mv -f -- "$branches.next" "$branches"
  done < <(jq -r --argjson max "$ADO_BRANCHES" '
    [.[] | select(.status == "completed") | .target | select(type == "string" and test("^refs/heads/[A-Za-z0-9._/-]{1,200}$"))]
    | group_by(.) | sort_by(-length) | .[:$max][] | .[0]' "$list")
  if jq -L "$SCRIPT_DIR" -c --arg project "$project" --arg prefix "$prefix" --arg base "$base" --argjson cap "$BODY_CAP" \
      --slurpfile by_branch "$branches" '
      include "fm-live-board-prs";
      {project:$project,forge:"ado",status:"ok",reason:null,branch_prefix:$prefix,prs:lbp_ado_prs($by_branch | first; $base; $cap)}' \
      "$list" > "$out" 2>/dev/null \
    && [ -s "$out" ]; then
    return 0
  fi
  repo_note "$project" ado failed fetch-failed "$prefix" > "$out"
}

# Read one source: resolve its forge from the clone's origin and collect it.
collect_source() {  # <project> <dir> <prefix> <out>
  local project=$1 dir=$2 prefix=$3 out=$4 remote pattern
  [ -d "$dir" ] || { repo_note "$project" none none no-clone "$prefix" > "$out"; return 0; }
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null) \
    || { repo_note "$project" none none no-clone "$prefix" > "$out"; return 0; }
  pattern='^(https://([^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100})/?$'
  if [[ "${remote%.git}" =~ $pattern ]]; then
    collect_github "$project" "$prefix" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "$out"
    return 0
  fi
  pattern='^(https://([^@/]+@)?dev\.azure\.com/|git@ssh\.dev\.azure\.com:v3/)([A-Za-z0-9][A-Za-z0-9-]{0,62})/([A-Za-z0-9._-]{1,64})/(_git/)?([A-Za-z0-9._-]{1,64})/?$'
  if [[ "$remote" =~ $pattern ]]; then
    collect_ado "$project" "$prefix" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[6]}" "$out"
    return 0
  fi
  repo_note "$project" none none unsupported-forge "$prefix" > "$out"
}

collect_all() {
  local started count=0 home_real registry name mode prefix pid index=0
  local -a pids=() files=()
  started=$(date +%s)

  # The home's own checkout is a source only when the home is the repository
  # root, so a home that merely sits inside another repository adds nothing.
  home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || home_real=
  if [ -n "$home_real" ] && [ "$(git -C "$home_real" rev-parse --show-toplevel 2>/dev/null)" = "$home_real" ]; then
    count=$((count + 1))
    collect_source "${home_real##*/}" "$home_real" fm/ "$tmp/repo.$count" &
    pids+=("$!")
  fi

  if registry=$("$SCRIPT_DIR/fm-project-mode.sh" --list-json 2>/dev/null); then
    while IFS=$'\t' read -r name mode; do
      case "$name" in
        ''|.|..|*/*) continue ;;
      esac
      count=$((count + 1))
      prefix=$("$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$name" 2>/dev/null) || prefix=fm/
      if [ "$mode" = local-only ]; then
        repo_note "$name" none none local-only "$prefix" > "$tmp/repo.$count"
        continue
      fi
      collect_source "$name" "$PROJECTS/$name" "$prefix" "$tmp/repo.$count" &
      pids+=("$!")
    done < <(printf '%s' "$registry" | jq -r '.projects[]? | [.name, (.mode // "")] | @tsv')
  fi

  for pid in ${pids[@]+"${pids[@]}"}; do
    wait "$pid" 2>/dev/null || true
  done

  while [ "$index" -lt "$count" ]; do
    index=$((index + 1))
    [ -s "$tmp/repo.$index" ] && files+=("$tmp/repo.$index")
  done
  jq -cn --argjson epoch "$started" '
    {schema:"fm-live-board-prs.v1",collected_at:($epoch | todate),collected_at_epoch:$epoch,
     repos:([inputs] | unique_by(.project))}' ${files[@]+"${files[@]}"} < /dev/null
}

# A test that sources this file gets the functions and constants above only.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  collect_all
fi
