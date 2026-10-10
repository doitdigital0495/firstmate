#!/usr/bin/env bash
# fm-live-board-prs.sh - read each project's recent pull requests and the
# runs their merges started, for the live board's timelines.
#
# Usage: fm-live-board-prs.sh [--json] [--git-cache DIR]
#
# Read-only: it lists pull requests and runs, fetches environment branches (see
# ENVIRONMENTS) and nothing else. It never queues or re-runs a pipeline, votes,
# merges, comments or writes to a forge, and it changes no home state beyond
# the history kept under --git-cache. bin/fm-live-board.sh owns when it runs
# and where its output is cached; bin/fm-live-board-prs.jq owns every rule
# named below.
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
#           use places in that read too, so on such a repository the small
#           read often omits recent merges.
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
# ENVIRONMENTS. A source named in config/live-board-environments.json (whose
# contract bin/fm-live-board.sh's header owns) has an ordered list of
# environments, each one branch. For such a source the Azure DevOps read asks
# for the 1000 newest pull requests instead of 200, and the listed branches are
# fetched from the clone's origin, with git's own credentials, into a bare
# repository per source under --git-cache (a directory removed on exit when the
# option is not given) that borrows the clone's objects, so the clone itself is
# never written and only history it lacks is downloaded. A merged pull request
# whose target is one of those branches then gets, per environment, whether it
# has reached it. It has when the environment's branch holds its merge commit,
# a commit recording itself as a cherry-pick of that merge commit, or - commit
# by commit, for every commit its merge brought in - that commit, a recorded
# cherry-pick of it, or the commit it is itself a recorded cherry-pick of. "A
# recorded cherry-pick" is git's own `(cherry picked from commit <sha>)` line,
# followed through a picked merge to what that merge brought in. Nothing else
# counts: a change redone by hand without that line has not reached the
# environment as far as this read can tell. copy_of lists the pull requests of
# the same source a pull request carries recorded cherry-picks of. A source
# whose branches could not be fetched, or whose pull requests were not read,
# carries no verdict at all.
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
#   {schema, collected_at, collected_at_epoch,
#    environment_config: absent|ok|invalid, repos:[{project, forge,
#    status: ok|failed|none, reason, branch_prefix, window_full,
#    environments: null|{status: ok|failed, reason, stages:[{name, branch}]},
#    prs:[{number, url, title, body, body_truncated,
#    state: open|merged|closed, draft, branch, target, merge_commit, opened_at,
#    closed_at, merged_at, runs:{status: ok|failed|not-merged|out-of-window,
#    items:[{name, result: succeeded|failed|running|skipped|superseded}]},
#    environment: null|{stage, reached: null|[bool per stage],
#    copy_of:[number]}}]}]}
# window_full says the read returned as many pull requests as it asked for, so
# older ones exist that were not read. environments is null for a source the
# environment list does not name; its reason is prs-unread, no-clone,
# fetch-failed or history-unreadable. A pull request's environment is null
# unless it is merged into an environment's branch; stage is that
# environment's position and reached is null when its merge commit is not in
# the fetched history.
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
ENVS_FILE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/live-board-environments.json"
ENVS_MAX_BYTES=65536
CALL_TIMEOUT=25
SOURCE_BUDGET=70
GITHUB_FETCH=50
GITHUB_FETCH_SMALL=15
ADO_FETCH=200
ADO_FETCH_ENVS=1000
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

GIT_CACHE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) shift ;;
    --git-cache) [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }; GIT_CACHE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo 'fm-live-board-prs: jq not found' >&2; exit 1; }

tmp=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-live-board-prs.XXXXXX") || exit 1
trap 'rm -rf -- "$tmp"' EXIT
[ -n "$GIT_CACHE" ] || GIT_CACHE="$tmp/git"
ENV_CONFIG=absent

# Print one repo record that carries no pull requests.
repo_note() {  # <project> <forge> <status> <reason> <branch-prefix>
  jq -cn --arg project "$1" --arg forge "$2" --arg status "$3" --arg reason "$4" --arg prefix "$5" \
    '{project:$project,forge:$forge,status:$status,reason:$reason,branch_prefix:$prefix,prs:[]}'
}

# Read the environment list once: absent, ok (kept for stages_of) or invalid.
load_environments() {
  local size
  [ -e "$ENVS_FILE" ] || [ -L "$ENVS_FILE" ] || return 0
  ENV_CONFIG=invalid
  [ -f "$ENVS_FILE" ] && [ ! -L "$ENVS_FILE" ] || return 0
  size=$(LC_ALL=C wc -c < "$ENVS_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -le "$ENVS_MAX_BYTES" ] || return 0
  if jq -L "$SCRIPT_DIR" -cs 'include "fm-live-board-prs";
      if length == 1 and (.[0] | lbp_stages_valid) then .[0] else error("invalid") end' \
      "$ENVS_FILE" > "$tmp/stages.json" 2>/dev/null; then
    ENV_CONFIG=ok
  fi
}

# Print one source's environments as a JSON array, or fail when it has none.
stages_of() {  # <project>
  [ "$ENV_CONFIG" = ok ] || return 1
  jq -ce --arg repo "$1" '[.repos[] | select(.repo == $repo)][0].environments // empty' "$tmp/stages.json" 2>/dev/null
}

# Record on a collected source that its environments carry no verdict, and why.
stages_note() {  # <out> <stages-json> <reason>
  jq -c --argjson stages "$2" --arg reason "$3" \
    '. + {environments:{status:"failed",reason:$reason,stages:$stages}}' "$1" > "$1.staged" 2>/dev/null \
    && mv -f -- "$1.staged" "$1"
}

# Which environments each merged pull request has reached, from one history
# dump. `heads` holds "<stage> <sha>" per environment branch, `prs` holds
# "<number> <merge-sha> <stage>" per pull request, `old` every commit all the
# branches share, and the main input one record per commit above those, as
# RS-separated "<sha> US <parents> US <message>". Prints one JSON object per
# pull request. The ENVIRONMENTS section of this file's header owns the rule.
# shellcheck disable=SC2016 # awk source, not shell expansions.
REACH_AWK='
function reach_of(start, set,    stack, top, c, i, p) {
  if (!(start in seen) || (start in set)) return
  top = 0; stack[++top] = start; set[start] = 1
  while (top > 0) {
    c = stack[top--]
    for (i = 1; i <= np[c]; i++) {
      p = par[c, i]
      if ((p in seen) && !(p in set)) { set[p] = 1; stack[++top] = p }
    }
  }
}
# The commits a commit added to its first parent, itself included.
function brought(m,    below, took, stack, top, c, i, p, out) {
  if (m in bro) return bro[m]
  if (np[m] > 0) reach_of(par[m, 1], below)
  out = ""; top = 0; stack[++top] = m; took[m] = 1
  while (top > 0) {
    c = stack[top--]; out = out " " c
    for (i = 1; i <= np[c]; i++) {
      p = par[c, i]
      if ((p in seen) && !(p in below) && !(p in took)) { took[p] = 1; stack[++top] = p }
    }
  }
  bro[m] = out
  return out
}
# Stage s holds commit x, so it holds what x records being a cherry-pick of.
function hold(s, x,    k) {
  if ((s, x) in held) return
  held[s, x] = 1
  if (!(x in seen)) return
  for (k = 1; k <= ntr[x]; k++) hold_picked(s, trail[x, k])
}
function hold_picked(s, t,    list, n, j) {
  if ((s, t) in picked) return
  picked[s, t] = 1
  hold(s, t)
  if ((t in seen) && np[t] > 1) {
    n = split(brought(t), list, " ")
    for (j = 1; j <= n; j++) hold(s, list[j])
  }
}
function has(s, c,    k) {
  if ((s, c) in held) return 1
  for (k = 1; k <= ntr[c]; k++) if ((s, trail[c, k]) in held) return 1
  return 0
}
function owners_of(t, n, into,    list, k, j) {
  if ((t in owner) && owner[t] != num[n]) into[owner[t]] = 1
  if ((t in seen) && np[t] > 1) {
    k = split(brought(t), list, " ")
    for (j = 1; j <= k; j++) if ((list[j] in owner) && owner[list[j]] != num[n]) into[owner[list[j]]] = 1
  }
}
BEGIN {
  stages = 0; count = 0
  while ((getline line < heads) > 0) { split(line, f, " "); head[f[1] + 0] = f[2]; if (f[1] + 1 > stages) stages = f[1] + 1 }
  while ((getline line < old) > 0) shared[line] = 1
  while ((getline line < prs) > 0) { split(line, f, " "); count++; num[count] = f[1]; sha[count] = f[2]; own[count] = f[3] + 0 }
  RS = sprintf("%c", 30); US = sprintf("%c", 31)
}
{
  if (index($0, US) != 41) next
  h = substr($0, 1, 40); rest = substr($0, 42); cut = index(rest, US)
  if (cut == 0) next
  seen[h] = 1
  np[h] = split(substr(rest, 1, cut - 1), f, " ")
  for (i = 1; i <= np[h]; i++) par[h, i] = f[i]
  body = substr(rest, cut + 1); ntr[h] = 0
  while (match(body, /cherry picked from commit [0-9a-f]+/)) {
    t = substr(body, RSTART + 26, RLENGTH - 26); body = substr(body, RSTART + RLENGTH)
    if (length(t) == 40) trail[h, ++ntr[h]] = t
  }
}
END {
  # Walk each branch along its first parents, oldest first, so every commit is
  # credited once to the commit that brought it in.
  for (s = 0; s < stages; s++) {
    k = 0; c = head[s]
    while (c in seen) { chain[++k] = c; if (np[c] < 1) break; c = par[c, 1] }
    split("", cover)
    for (j = k; j >= 1; j--) {
      m = chain[j]
      if (m in bro) {
        n = split(bro[m], list, " ")
        for (i = 1; i <= n; i++) cover[list[i]] = 1
        continue
      }
      out = ""; top = 0; stack[++top] = m; cover[m] = 1
      while (top > 0) {
        c = stack[top--]; out = out " " c
        for (i = 1; i <= np[c]; i++) {
          p = par[c, i]
          if ((p in seen) && !(p in cover)) { cover[p] = 1; stack[++top] = p }
        }
      }
      bro[m] = out
    }
    split("", inside); reach_of(head[s], inside)
    for (c in inside) hold(s, c)
  }
  for (n = 1; n <= count; n++) {
    if (!(sha[n] in seen)) continue
    k = split(brought(sha[n]), list, " ")
    for (j = 1; j <= k; j++) if (!(list[j] in owner)) owner[list[j]] = num[n]
  }
  for (n = 1; n <= count; n++) {
    m = sha[n]; line = ""; copies = ""
    if (m in shared) {
      for (s = 0; s < stages; s++) { sep = s ? "," : ""; line = line sep "true" }
    } else if (m in seen) {
      k = split(brought(m), list, " ")
      for (s = 0; s < stages; s++) {
        got = ((s, m) in held)
        if (!got) {
          plain = 0; got = 1
          for (j = 1; j <= k; j++) if (np[list[j]] <= 1) { plain++; if (!has(s, list[j])) { got = 0; break } }
          if (plain == 0) got = 0
        }
        sep = s ? "," : ""; word = got ? "true" : "false"; line = line sep word
      }
      split("", from)
      for (j = 1; j <= k; j++) for (i = 1; i <= ntr[list[j]]; i++) owners_of(trail[list[j], i], n, from)
      for (c in from) { sep = copies == "" ? "" : ","; copies = copies sep c }
    }
    line = line == "" ? "null" : "[" line "]"
    printf "{\"number\":%s,\"stage\":%d,\"reached\":%s,\"copy_of\":[%s]}\n", num[n], own[n], line, copies
  }
}'

# Add to one collected source which environments each merged pull request has
# reached, read from the environment branches' own history.
annotate_environments() {  # <project> <clone-dir> <out> <stages-json>
  local dir=$2 out=$3 stages=$4 store="$GIT_CACHE/$1.git" url objects left base branch index=0
  local -a refspecs=() heads=()
  [ "$(jq -r '.status' "$out" 2>/dev/null)" = ok ] || { stages_note "$out" "$stages" prs-unread; return 0; }
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || { stages_note "$out" "$stages" no-clone; return 0; }
  if [ ! -d "$store/objects" ]; then
    if ! (umask 077; mkdir -p "$GIT_CACHE") 2>/dev/null || ! git init -q --bare "$store" >/dev/null 2>&1; then
      stages_note "$out" "$stages" fetch-failed
      return 0
    fi
  fi
  # Borrow the clone's objects so only history it lacks is downloaded.
  if objects=$(cd "$dir" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)/objects" 2>/dev/null && pwd -P); then
    printf '%s\n' "$objects" > "$store/objects/info/alternates" 2>/dev/null || true
  fi
  while IFS= read -r branch; do
    refspecs+=("+refs/heads/$branch:refs/heads/stage-$index")
    heads+=("refs/heads/stage-$index")
    index=$((index + 1))
  done < <(printf '%s' "$stages" | jq -r '.[].branch')
  left=$((SOURCE_DEADLINE - SECONDS))
  [ "$left" -lt "$CALL_TIMEOUT" ] || left=$CALL_TIMEOUT
  # The origin address travels in the environment, so a credential inside it
  # is neither stored in the cache nor shown on a command line.
  if [ "$left" -le 0 ] || ! GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0="$url" \
      fm_run_timed "$left" git --git-dir="$store" fetch --quiet --no-tags origin "${refspecs[@]}" >/dev/null 2>&1; then
    stages_note "$out" "$stages" fetch-failed
    return 0
  fi
  : > "$out.heads"
  index=0
  for branch in "${heads[@]}"; do
    printf '%s %s\n' "$index" "$(git --git-dir="$store" rev-parse --verify --quiet "$branch^{commit}" 2>/dev/null)" >> "$out.heads"
    index=$((index + 1))
  done
  : > "$out.old"
  base=$(git --git-dir="$store" merge-base --octopus "${heads[@]}" 2>/dev/null) || base=
  [ -z "$base" ] || git --git-dir="$store" rev-list "$base" > "$out.old" 2>/dev/null || base=
  if jq -r --argjson stages "$stages" '($stages | map(.branch)) as $branches
        | .prs[] | select(.state == "merged" and ((.merge_commit // "") | test("^[0-9a-f]{40}$")))
        | (.target as $target | $branches | index($target)) as $stage | select($stage != null)
        | "\(.number) \(.merge_commit) \($stage)"' "$out" > "$out.merged" 2>/dev/null \
    && git --git-dir="$store" log --format='%x1e%H%x1f%P%x1f%B' "${heads[@]}" ${base:+--not "$base"} > "$out.log" 2>/dev/null \
    && LC_ALL=C awk -v heads="$out.heads" -v prs="$out.merged" -v old="$out.old" "$REACH_AWK" "$out.log" > "$out.reach" 2>/dev/null \
    && jq -L "$SCRIPT_DIR" -c --argjson stages "$stages" --slurpfile reach "$out.reach" \
        'include "fm-live-board-prs"; lbp_stages_attach($reach; $stages)' "$out" > "$out.staged" 2>/dev/null \
    && [ -s "$out.staged" ]; then
    mv -f -- "$out.staged" "$out"
    return 0
  fi
  stages_note "$out" "$stages" history-unreadable
}

# shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
GITHUB_QUERY='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){
  pullRequests(first:$n,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{
    number title body url state isDraft createdAt closedAt mergedAt headRefName baseRefName
    mergeCommit{oid
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
      && jq -L "$SCRIPT_DIR" -c --arg project "$project" --arg prefix "$prefix" --argjson cap "$BODY_CAP" --argjson n "$n" '
          include "fm-live-board-prs";
          lbp_github_prs($cap) as $prs
          | {project:$project,forge:"github",status:"ok",reason:null,branch_prefix:$prefix,
             window_full:(($prs | length) >= $n),prs:$prs}' \
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
  local deadline=$SOURCE_DEADLINE left fetch=$ADO_FETCH
  stages_of "$project" >/dev/null && fetch=$ADO_FETCH_ENVS
  az_bin=$(fm_ado_az_bin) || { repo_note "$project" ado none no-cli "$prefix" > "$out"; return 0; }
  org_url="https://dev.azure.com/$org"
  base="$org_url/$ado_project/_git/$repo"
  if ! fm_run_timed "$CALL_TIMEOUT" "$az_bin" repos pr list --organization "$org_url" --project "$ado_project" \
      --repository "$repo" --status all --top "$fetch" --output json \
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
      --slurpfile by_branch "$branches" --argjson fetch "$fetch" '
      include "fm-live-board-prs";
      {project:$project,forge:"ado",status:"ok",reason:null,branch_prefix:$prefix,window_full:(length >= $fetch),
       prs:lbp_ado_prs($by_branch | first; $base; $cap)}' \
      "$list" > "$out" 2>/dev/null \
    && [ -s "$out" ]; then
    return 0
  fi
  repo_note "$project" ado failed fetch-failed "$prefix" > "$out"
}

# Read one source, then say which of its environments each merge has reached.
collect_source() {  # <project> <dir> <prefix> <out>
  local stages SOURCE_DEADLINE=$((SECONDS + SOURCE_BUDGET))
  collect_forge "$@"
  ! stages=$(stages_of "$1") || annotate_environments "$1" "$2" "$4" "$stages"
}

# Resolve one source's forge from the clone's origin and collect it.
collect_forge() {  # <project> <dir> <prefix> <out>
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
  local started count=0 home_real registry name mode prefix pid index=0 stages
  local -a pids=() files=()
  started=$(date +%s)
  load_environments

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
        ! stages=$(stages_of "$name") || stages_note "$tmp/repo.$count" "$stages" prs-unread
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
  jq -cn --argjson epoch "$started" --arg environments "$ENV_CONFIG" '
    {schema:"fm-live-board-prs.v1",collected_at:($epoch | todate),collected_at_epoch:$epoch,
     environment_config:$environments,repos:([inputs] | unique_by(.project))}' ${files[@]+"${files[@]}"} < /dev/null
}

# A test that sources this file gets the functions and constants above only.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  collect_all
fi
