#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, and az for Azure DevOps, so an upstream checkout needs no extra
# tooling to follow any of them.
#
# The optional --validated state-dir and task-id arguments (and the same two
# facts derived from the check path itself) let the Azure DevOps branch look up
# the task's worktree for its git conflict probe; with them absent the probe is
# skipped silently and only the forge's own conflict flag is observed. The
# task's state directory is read for that probe alone and is never written.
#
# The Azure DevOps branch emits two non-terminal observations while the pull
# request is open, both data the captain can act on:
# - one "ado conflict" line whenever the source branch conflicts with its
#   target, detected through the forge's own merge status and confirmed or
#   discovered through a local git merge-tree probe against the fetched branch
#   tips, because the forge's flag alone is known to lag or miss conflicts;
# - one "merged" line with the per-pipeline verdicts on the merge commit once
#   every observed run has completed, or once it is clear none will start.
#   A failed or cancelled run is RED and a succeeded run is GREEN, spelled out
#   in the line itself so the two can never be confused at a glance. The merge
#   itself is never held back indefinitely: once FM_ADO_POSTMERGE_CAP_SECS
#   (default 7200) have passed since completion, the merged line is emitted
#   with any unfinished run marked PENDING, or with the runs noted unreadable.
#   The watcher wakes once per standing conflict: an "ado clear" line, printed
#   only when the forge or the git probe positively confirms a clean merge,
#   ends the conflict silently, while silence on a failed lookup does not.
set -u
LC_ALL=C
export LC_ALL

meta_path=
if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 8 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  meta_state=$7
  meta_task=$8
  case "$meta_task" in
    ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;;
  esac
  [ "${#meta_task}" -le 64 ] || exit 0
  if [ -d "$meta_state" ] && [ ! -L "$meta_state" ]; then
    meta_path="$meta_state/$meta_task.meta"
  fi
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
  # The same two facts the watcher passes to --validated, derived from the
  # check path itself, so a directly executed copy probes conflicts too.
  meta_state=${0%/*}
  meta_task=${0##*/}
  meta_task=${meta_task%.check.sh}
  case "$meta_task" in
    ''|.*|*[!A-Za-z0-9._-]*) ;;
    *)
      if [ "${#meta_task}" -le 64 ] && [ -d "$meta_state" ] && [ ! -L "$meta_state" ]; then
        meta_path="$meta_state/$meta_task.meta"
      fi
      ;;
  esac
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Convert an ISO 8601 timestamp like Azure DevOps' 2026-09-22T19:20:36.296140+00:00
# into epoch seconds without depending on any date implementation's extension
# syntax: GNU date and BSD date read these strings differently. Pure integer
# arithmetic in awk is exact and portable.
ado_iso_epoch() {
  local iso=${1-} off_secs=0 sign
  local LC_ALL=C
  local rx='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|[+-]([0-9]{2}):([0-9]{2}))$'
  [[ "$iso" =~ $rx ]] || return 1
  if [ "${BASH_REMATCH[8]}" != Z ]; then
    case ${BASH_REMATCH[8]:0:1} in
      +) sign=1 ;;
      *) sign=-1 ;;
    esac
    off_secs=$((sign * (10#${BASH_REMATCH[9]} * 3600 + 10#${BASH_REMATCH[10]} * 60)))
  fi
  awk -v y="${BASH_REMATCH[1]}" -v mo="${BASH_REMATCH[2]}" -v d="${BASH_REMATCH[3]}" \
    -v hh="${BASH_REMATCH[4]}" -v mi="${BASH_REMATCH[5]}" -v ss="${BASH_REMATCH[6]}" \
    -v off="$off_secs" 'BEGIN {
      y -= mo <= 2 ? 1 : 0
      era = int(y / 400)
      yoe = y - era * 400
      mp = mo > 2 ? mo - 3 : mo + 9
      doy = int((153 * mp + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      days = era * 146097 + doe - 719468
      printf "%d\n", days * 86400 + hh * 3600 + mi * 60 + ss - off
    }'
}

# The task's worktree path, read only for the Azure DevOps conflict probe.
# The metadata file is firstmate's own record; every deviation from a plain
# regular file or a single absolute path on the worktree= line is refused.
ado_meta_worktree() {
  local meta=$1 line wt=
  local LC_ALL=C
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree=*) wt=${line#worktree=} ;;
    esac
  done < "$meta" || return 1
  case "$wt" in
    /*) [ "${#wt}" -le 4096 ] && printf '%s\n' "$wt" && return 0 ;;
  esac
  return 1
}

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  ado)
    # The same segment rules bin/fm-pr-lib.sh applies when parsing the URL,
    # restated here because this static copy revalidates the sidecar itself.
    [ "$host" = dev.azure.com ] || exit 0
    IFS=/ read -r ado_org ado_project ado_marker ado_repo << POLL_EOF
$path
POLL_EOF
    [ "$ado_marker" = _git ] || exit 0
    [ -n "$ado_org" ] && [ "${#ado_org}" -le 63 ] || exit 0
    case "$ado_org" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ -n "$ado_project" ] && [ "${#ado_project}" -le 64 ] || exit 0
    case "$ado_project" in
      .|..|_git|-*|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ -n "$ado_repo" ] && [ "${#ado_repo}" -le 64 ] || exit 0
    case "$ado_repo" in
      .|..|_git|-*|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://dev.azure.com/$ado_org/$ado_project/_git/$ado_repo/pullrequest/$number" ] || exit 0
    # Read-only az usage, exactly like the arming guard resolved it: az on
    # PATH, or the Microsoft installer's ~/.local/bin/az.
    az_bin=$(command -v az 2>/dev/null || true)
    if [ -z "$az_bin" ] || [ ! -x "$az_bin" ]; then
      if [ -f "$HOME/.local/bin/az" ] && [ -x "$HOME/.local/bin/az" ]; then
        az_bin=$HOME/.local/bin/az
      else
        az_bin=
      fi
    fi
    [ -n "$az_bin" ] || exit 0
    org_url="https://dev.azure.com/$ado_org"
    # One read of the pull request record. az renders a null field as the
    # literal word None in tsv output, so that is the empty value here.
    pr_raw=$("$az_bin" repos pr show --id "$number" --organization "$org_url" \
      --query "[status, mergeStatus, targetRefName, headRef.sourceRefName, lastMergeCommit.commitId, closedDate]" \
      --output tsv 2>/dev/null) || exit 0
    line_no=0
    pr_status=
    merge_status=
    target_ref=
    source_ref=
    merge_commit=
    closed_date=
    while IFS= read -r pr_line; do
      line_no=$((line_no + 1))
      case $line_no in
        1) pr_status=$pr_line ;;
        2) merge_status=$pr_line ;;
        3) target_ref=$pr_line ;;
        4) source_ref=$pr_line ;;
        5) merge_commit=$pr_line ;;
        6) closed_date=$pr_line ;;
        *) exit 0 ;;
      esac
    done << PR_EOF
$pr_raw
PR_EOF
    [ "$line_no" -eq 6 ] || exit 0
    [ "$pr_status" = None ] && pr_status=
    [ "$merge_status" = None ] && merge_status=
    [ "$target_ref" = None ] && target_ref=
    [ "$source_ref" = None ] && source_ref=
    [ "$merge_commit" = None ] && merge_commit=
    [ "$closed_date" = None ] && closed_date=
    # abandoned and any unreadable status stay silent, exactly like a pull
    # request on GitHub that is closed without merging.
    case "$pr_status" in
      active) ;;
      completed) ;;
      *) exit 0 ;;
    esac
    if [ "$pr_status" = active ]; then
      conflict=0
      conflict_why=
      probe_clean=0
      if [ "$merge_status" = conflicts ]; then
        conflict=1
        conflict_why="azure devops reports the source branch conflicts with ${target_ref:-the target branch}"
      fi
      if [ "$conflict" -eq 0 ] && [ -n "$meta_path" ] && command -v git >/dev/null 2>&1; then
        # The forge's own merge flag is known to lag or miss conflicts, so an
        # authoritative second opinion is computed locally: fetch the recorded
        # branch tips into the task's worktree and ask git whether merging the
        # two current tips conflicts. Every failure skips the probe silently;
        # a conflict is only ever reported from an answer git actually gave.
        src_branch=${source_ref#refs/heads/}
        tgt_branch=${target_ref#refs/heads/}
        if [ "$src_branch" != "$source_ref" ] && [ "$tgt_branch" != "$target_ref" ] \
          && case "$src_branch" in
               ''|..|-*|.*|*..*|*/*|*[!A-Za-z0-9._-]*) false ;;
               *) [ "${#src_branch}" -le 255 ] ;;
             esac \
          && case "$tgt_branch" in
               ''|..|-*|.*|*..*|*/*|*[!A-Za-z0-9._-]*) false ;;
               *) [ "${#tgt_branch}" -le 255 ] ;;
             esac; then
          if ado_wt=$(ado_meta_worktree "$meta_path") \
            && [ -d "$ado_wt" ] \
            && remote_url=$(git -C "$ado_wt" remote get-url origin 2>/dev/null); then
            case "$remote_url" in
              *"dev.azure.com/$ado_org/$ado_project/_git/$ado_repo"* \
              |*"ssh.dev.azure.com:v3/$ado_org/$ado_project/$ado_repo"* \
              |*"vs-ssh.visualstudio.com:v3/$ado_org/$ado_project/$ado_repo"*)
                git -C "$ado_wt" fetch --quiet origin "$src_branch" "$tgt_branch" 2>/dev/null || true
                head_sha=$(git -C "$ado_wt" rev-parse --verify --quiet "refs/remotes/origin/$src_branch^{commit}" 2>/dev/null) || head_sha=
                tip_sha=$(git -C "$ado_wt" rev-parse --verify --quiet "refs/remotes/origin/$tgt_branch^{commit}" 2>/dev/null) || tip_sha=
                if [ -n "$head_sha" ] && [ -n "$tip_sha" ]; then
                  if [ "$head_sha" = "$tip_sha" ] \
                    || git -C "$ado_wt" merge-base --is-ancestor "$tip_sha" "$head_sha" 2>/dev/null; then
                    probe_clean=1
                  else
                    git -C "$ado_wt" merge-tree --write-tree "$head_sha" "$tip_sha" >/dev/null 2>/dev/null
                    merge_tree_rc=$?
                    if [ "$merge_tree_rc" -eq 1 ]; then
                      conflict=1
                      conflict_why="git merge-tree reports merging origin/$src_branch into origin/$tgt_branch conflicts"
                    elif [ "$merge_tree_rc" -eq 0 ]; then
                      probe_clean=1
                    fi
                  fi
                fi
                ;;
            esac
          fi
        fi
      fi
      if [ "$conflict" -eq 1 ]; then
        printf 'ado conflict: %s needs a rebase: %s\n' "$url" "$conflict_why"
      elif [ "$merge_status" = succeeded ] || [ "$probe_clean" -eq 1 ]; then
        printf 'ado clear: %s\n' "$url"
      fi
      exit 0
    fi
    # Completed: watch the pipeline runs on the merge commit itself, so the
    # verdict is derived from live runs and no pipeline name is ever assumed.
    # A squash merge can land under a different commit than the PR's recorded
    # merge commit; in that case no runs match and the grace message below
    # reports that honestly instead of inventing a verdict.
    # An unreadable completion time counts as long past, so it can only
    # release the merge line early, never hold it back, and the line then
    # says so instead of claiming a wait that never happened.
    run_grace=${FM_ADO_POSTMERGE_GRACE_SECS-900}
    case "$run_grace" in
      ''|*[!0-9]*) run_grace=900 ;;
    esac
    run_cap=${FM_ADO_POSTMERGE_CAP_SECS-7200}
    case "$run_cap" in
      ''|*[!0-9]*) run_cap=7200 ;;
    esac
    [ "$run_cap" -ge "$run_grace" ] || run_cap=$run_grace
    if closed_epoch=$(ado_iso_epoch "$closed_date" 2>/dev/null); then
      grace_note="within ${run_grace}s of completion"
      cap_note="within ${run_cap}s of completion"
    else
      closed_epoch=0
      grace_note="before any wait, because the completion time could not be read"
      cap_note=$grace_note
    fi
    closed_age=$(($(date +%s) - closed_epoch))
    if [ "${#merge_commit}" -ne 40 ] || case "$merge_commit" in *[!0-9a-f]*) true ;; *) false ;; esac; then
      printf 'merged azure-devops %s: no merge commit was recorded, so no pipeline runs were watched\n' "$url"
      exit 0
    fi
    if ! runs_raw=$("$az_bin" pipelines runs list --organization "$org_url" --project "$ado_project" \
      ${target_ref:+--branch "$target_ref"} --top 200 --query "[?sourceVersion=='$merge_commit'].[definition.name, status, result, id]" \
      --output tsv 2>/dev/null); then
      if [ "$closed_age" -ge "$run_cap" ]; then
        printf 'merged azure-devops %s merge commit %s: pipeline runs could not be read %s\n' \
          "$url" "${merge_commit:0:8}" "$cap_note"
      fi
      exit 0
    fi
    if [ -n "$runs_raw" ]; then
      runs_sorted=$(printf '%s\n' "$runs_raw" | sort -t $'\t' -k 4,4n)
    else
      runs_sorted=
    fi
    run_total=0 run_pending=0 verdicts=
    while IFS=$'\t' read -r run_name run_status run_result run_id; do
      case "$run_id" in
        ''|*[!0-9]*) continue ;;
      esac
      run_total=$((run_total + 1))
      [ "$run_name" = None ] && run_name="run $run_id"
      case "$run_status" in
        completed)
          if [ "$run_result" = succeeded ]; then
            run_outcome=GREEN
            run_result_text=$run_result
          else
            run_outcome=RED
            if [ -z "$run_result" ] || [ "$run_result" = None ]; then
              run_result_text=no-result
            else
              run_result_text=$run_result
            fi
          fi
          verdicts="$verdicts$run_name=$run_outcome ($run_result_text, run $run_id); "
          ;;
        *)
          run_pending=$((run_pending + 1))
          verdicts="$verdicts$run_name=PENDING ($run_status, run $run_id); "
          ;;
      esac
    done << RUNS_EOF
$runs_sorted
RUNS_EOF
    if [ "$run_total" -eq 0 ]; then
      # Zero runs right after completion is the normal gap before the forge
      # creates them; stateless ageing on the closed timestamp tells that gap
      # apart from a merge that truly triggered nothing.
      if [ "$closed_age" -ge "$run_grace" ]; then
        printf 'merged azure-devops %s: no pipeline runs were observed on merge commit %s %s\n' \
          "$url" "${merge_commit:0:8}" "$grace_note"
      fi
      exit 0
    fi
    if [ "$run_pending" -gt 0 ] && [ "$closed_age" -lt "$run_cap" ]; then
      exit 0
    fi
    # Azure DevOps can enqueue separate deploy/build pipelines shortly after
    # PR completion. Keep the registration alive for the same grace window used
    # to distinguish a delayed run from no run at all, then summarize every
    # run observed on the merge commit together in one terminal wake.
    [ "$closed_age" -ge "$run_grace" ] || exit 0
    verdicts=${verdicts%; }
    printf 'merged azure-devops %s merge commit %s: %s\n' "$url" "${merge_commit:0:8}" "$verdicts"
    ;;
  *) exit 0 ;;
esac
exit 0
