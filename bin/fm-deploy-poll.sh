#!/usr/bin/env bash
# Read-only post-merge deploy poll for one merged GitHub pull request.
#
#   fm-deploy-poll.sh <canonical-github-pr-url> <armed-epoch>
#
# bin/fm-watch.sh runs this on its check cadence for every $STATE/<id>.deploy-watch
# that bin/fm-merge-outcome-lib.sh arms when a GitHub merge outcome is recorded
# (bin/fm-pr-lib.sh fm_deploy_watch_arm owns that file). It follows everything
# the forge attaches to the merge commit, so no project, workflow, or host is
# ever assumed: every GitHub Actions workflow run the merge set off, every check
# run another app created (Vercel's included), and every commit status, which
# is where a Vercel deployment reports. Only gh reads are made; nothing is
# rerun or written to the forge.
#
# It prints at most one line and stays silent while the watch should continue,
# including on every read failure before the cap. Each run is spelled out as
# name=GREEN, name=RED, name=SKIPPED, or name=PENDING with the forge's own
# result in parentheses. The terminal lines, all ending the watch:
#   deploy RED: <url> merge commit <sha8>: <runs>        any run failed
#   deploy GREEN: <url> merge commit <sha8>: <runs>      every run passed or skipped
#   deploy UNFINISHED: <url> merge commit <sha8>: <runs> the cap passed with runs pending
#   deploy UNREAD: <url>: <why>                          the cap passed with nothing readable
#   deploy none: <url>: <why>                            no runs appeared by the cap
# The first four wake firstmate once; "deploy none" ends the watch quietly.
# A verdict waits until FM_DEPLOY_WATCH_GRACE_SECS (default 600) have passed
# since the merge, so a deploy a finished workflow triggers is not missed, and
# nothing waits past FM_DEPLOY_WATCH_CAP_SECS (default 7200). Both are measured
# from the forge's merge time, or from <armed-epoch> when that is unreadable.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

[ "$#" -eq 2 ] || exit 0
url=$1
armed=$2
fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || exit 0
case "$armed" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "${#armed}" -le 12 ] || exit 0
repo="$FM_PR_OWNER/$FM_PR_REPO"

grace=${FM_DEPLOY_WATCH_GRACE_SECS-600}
case "$grace" in
  ''|*[!0-9]*) grace=600 ;;
esac
cap=${FM_DEPLOY_WATCH_CAP_SECS-7200}
case "$cap" in
  ''|*[!0-9]*) cap=7200 ;;
esac
[ "$cap" -ge "$grace" ] || cap=$grace

merged_epoch=$armed
sha=
pr_raw=$(gh pr view "$url" --json state,mergeCommit,mergedAt \
  -q '[.state, (.mergeCommit.oid // ""), ((.mergedAt // "") | if . == "" then 0 else fromdateiso8601 end)] | @tsv' \
  2>/dev/null) && {
  IFS=$'\t' read -r pr_state pr_sha pr_merged_epoch << PR_EOF
$pr_raw
PR_EOF
  case "${pr_state-}" in
    OPEN|CLOSED)
      printf 'deploy none: %s: the pull request is %s, not merged, so no deploy was watched\n' \
        "$url" "$pr_state"
      exit 0
      ;;
    MERGED)
      case "${pr_merged_epoch-}" in
        ''|0|*[!0-9]*) ;;
        *) merged_epoch=$pr_merged_epoch ;;
      esac
      if [ "${#pr_sha}" -eq 40 ] && case "$pr_sha" in *[!0-9a-f]*) false ;; *) true ;; esac; then
        sha=$pr_sha
      fi
      ;;
  esac
}
age=$(($(date +%s) - merged_epoch))

if [ -z "$sha" ]; then
  [ "$age" -ge "$cap" ] \
    && printf 'deploy UNREAD: %s: the merge commit could not be read within %ss of merge\n' "$url" "$cap"
  exit 0
fi

# One tab-separated row per run: kind, name, status, result, id, with "-" for
# an absent field because read collapses empty tab-separated fields. The merge
# commit stays the default branch tip until the next merge, so scheduled and
# issue-driven workflows run on it too; only the events a merge sets off
# directly or through a chained workflow or deployment are followed.
if ! workflow_rows=$(gh api "repos/$repo/actions/runs?head_sha=$sha&per_page=100" \
    -q '.workflow_runs[] | select(.event | IN("push", "workflow_run", "deployment", "deployment_status", "status", "check_run", "check_suite", "repository_dispatch", "dynamic")) | ["workflow", (.name // "" | if . == "" then "unnamed" else . end), .status, (.conclusion // "-"), (.id | tostring)] | @tsv' \
    2>/dev/null) \
  || ! check_rows=$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100" \
    -q '.check_runs[] | select(.app.slug != "github-actions") | ["check", (.name // "" | if . == "" then "unnamed" else . end), .status, (.conclusion // "-"), (.id | tostring)] | @tsv' \
    2>/dev/null) \
  || ! status_rows=$(gh api "repos/$repo/commits/$sha/status?per_page=100" \
    -q '.statuses[] | ["status", (.context // "" | if . == "" then "unnamed" else . end), .state, "-", "-"] | @tsv' \
    2>/dev/null); then
  [ "$age" -ge "$cap" ] \
    && printf 'deploy UNREAD: %s: runs on merge commit %s could not be read within %ss of merge\n' \
      "$url" "${sha:0:8}" "$cap"
  exit 0
fi

total=0 red=0 pending=0 green=0 verdicts='' flagged=''
while IFS=$'\t' read -r kind name status result id; do
  [ -n "$kind" ] || continue
  total=$((total + 1))
  # Names are forge data: keep them to one printable line of bounded length.
  name=$(printf '%s' "$name" | tr -d '\000-\037\177' | cut -c1-80)
  [ -n "$name" ] || name=unnamed
  case "$kind" in
    status)
      ref=
      case "$status" in
        success) outcome=GREEN ;;
        failure|error) outcome=RED ;;
        *) outcome=PENDING ;;
      esac
      detail=$status
      ;;
    *)
      ref=", $kind $id"
      if [ "$status" = completed ]; then
        case "$result" in
          success) outcome=GREEN ;;
          neutral|skipped) outcome=SKIPPED ;;
          *) outcome=RED ;;
        esac
        [ "$result" != - ] || result=no-result
        detail=$result
      else
        outcome=PENDING
        detail=$status
      fi
      ;;
  esac
  case "$outcome" in
    RED) red=$((red + 1)) ;;
    PENDING) pending=$((pending + 1)) ;;
    *) green=$((green + 1)) ;;
  esac
  verdicts="$verdicts$name=$outcome ($detail$ref); "
  [ "$outcome" = GREEN ] || [ "$outcome" = SKIPPED ] \
    || flagged="$flagged$name=$outcome ($detail$ref); "
done << RUNS_EOF
$workflow_rows
$check_rows
$status_rows
RUNS_EOF

if [ "$total" -eq 0 ]; then
  [ "$age" -ge "$cap" ] \
    && printf 'deploy none: %s: no runs or commit statuses appeared on merge commit %s within %ss of merge\n' \
      "$url" "${sha:0:8}" "$cap"
  exit 0
fi
if [ "$pending" -gt 0 ] && [ "$age" -lt "$cap" ]; then
  exit 0
fi
[ "$age" -ge "$grace" ] || exit 0
if [ "$red" -gt 0 ]; then
  headline=RED
elif [ "$pending" -gt 0 ]; then
  headline=UNFINISHED
else
  headline=GREEN
fi
# A merge that fans out to many deploys keeps the wake readable: past
# FM_DEPLOY_WATCH_LIST_MAX runs (default 12) only the runs that are not green
# are named, with the green and skipped ones counted.
list_max=${FM_DEPLOY_WATCH_LIST_MAX-12}
case "$list_max" in
  ''|*[!0-9]*) list_max=12 ;;
esac
if [ "$total" -gt "$list_max" ]; then
  verdicts="$flagged$green more GREEN or SKIPPED; "
fi
printf 'deploy %s: %s merge commit %s: %s\n' "$headline" "$url" "${sha:0:8}" "${verdicts%; }"
exit 0
