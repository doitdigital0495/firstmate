#!/usr/bin/env bash
# Static watcher program for a validated pull request, merge request, or Gerrit
# change poll sidecar.
# It emits exactly one merged line for a merged change and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, gerrit-axi for Gerrit, tea for Forgejo, and az for Azure DevOps, so an
# upstream checkout needs no extra tooling to follow GitHub or GitLab. The
# Gerrit and Forgejo branches additionally need jq, which bin/fm-pr-check.sh
# refuses to arm those watches without.
#
# The optional --validated state-dir and task-id arguments (and the same two
# facts derived from the check path itself) let the Azure DevOps branch look up
# the task's worktree for its git conflict probe, and let the GitHub branch
# keep its merge-queue memory beside the task's other poll sidecars; with them
# absent both are skipped silently, so only the forge's own readings are
# observed. The task's state directory is otherwise never read, and the one
# file this program ever writes there is that GitHub queue memory.
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
#
# The GitHub branch emits one further non-terminal observation, for merge
# queues: a pull request this poll has read as queued (isInMergeQueue) that is
# later read open, not merged, and no longer in the queue has been ejected, and
# an ejected pull request stays open forever otherwise - the merged line is
# this poll's only terminal output. One "github queue ejected" line names the
# ejection with GitHub's own recorded removal reason, and exactly one
# re-enqueue runs with the exact flags bin/fm-pr-merge.sh names for a queue
# base (--auto --<method>, the method read from the branch rules), recorded in
# the queue memory so a second ejection is reported but never re-enqueued
# again. A pull request never read as queued stays silent exactly as before.
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

# One private per-task sidecar, <id>.pr-poll-queue, carries this poll's
# merge-queue memory across watcher sweeps: whether this pull request was ever
# read as queued, which removal event was already reported, and whether the
# single re-enqueue has been used. A strict five-line shape, an exact URL
# match, atomic publication through a same-directory temporary, and a refusal
# to write over anything but a plain file keep the record single-writer and
# trustworthy; when it cannot be written the poll degrades to its posture on
# every other unreadable fact and stays silent rather than repeat a report
# every sweep.
github_queue_memory_read() {  # <state-dir> <task> <url>
  local state=${1-} task=${2-} u=${3-} path line
  local version='' rec_url='' was=false rep='' re=false
  local LC_ALL=C
  GQ_WAS_QUEUED=false
  GQ_REPORTED_AT=
  GQ_REENQUEUED=false
  case "$task" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#task}" -le 64 ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  path="$state/$task.pr-poll-queue"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      fm-pr-poll-queue-v1) version=$line ;;
      url=*) rec_url=${line#url=} ;;
      was_queued=true|was_queued=false) was=${line#was_queued=} ;;
      reported_removed_at=*) rep=${line#reported_removed_at=} ;;
      reenqueued=true|reenqueued=false) re=${line#reenqueued=} ;;
      *) return 1 ;;
    esac
  done < "$path" || return 1
  [ "$version" = fm-pr-poll-queue-v1 ] && [ "$rec_url" = "$u" ] || return 1
  GQ_WAS_QUEUED=$was
  GQ_REPORTED_AT=$rep
  GQ_REENQUEUED=$re
  return 0
}

github_queue_memory_write() {  # <state-dir> <task> <url> <was-queued> <reported-at> <reenqueued>
  local state=${1-} task=${2-} u=${3-} was=${4-} rep=${5-} re=${6-}
  local path tmp
  local LC_ALL=C
  case "$task" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#task}" -le 64 ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  path="$state/$task.pr-poll-queue"
  [ ! -L "$path" ] && [ ! -d "$path" ] || return 1
  tmp=$(mktemp "$state/.pr-poll-queue.$$.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' fm-pr-poll-queue-v1 "url=$u" "was_queued=$was" \
      "reported_removed_at=$rep" "reenqueued=$re" > "$tmp" 2>/dev/null \
    && chmod 600 "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# One live queue-aware read of the pull request, issuing the identical GraphQL
# query and field lines bin/fm-pr-merge.sh's github_queue_read issues (restated
# here because this static body can source nothing; keep the two in lockstep).
# This copy requires exactly what its decisions depend on - state, merged,
# queued, and the head the re-enqueue binds to - plus the latest
# removed-from-queue event with GitHub's stated reason, which the merge script
# quotes on its own refusals; the id, queue entry, and branch lines are parsed
# and unused here. Any missing field fails the whole read so the plain state
# read stays the only fallback, never a half queue-aware one.
gq_id=
gq_state=
gq_merged=
gq_queued=
gq_entry=
gq_head=
gq_branch=
gq_removed_at=
gq_removed_reason=
github_queue_read() {  # <host> <owner> <repo> <number>
  local host=$1 owner=$2 repo=$3 number=$4 fields line
  local LC_ALL=C
  gq_id=
  gq_state=
  gq_merged=
  gq_queued=
  gq_entry=
  gq_head=
  gq_branch=
  gq_removed_at=
  gq_removed_reason=
  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(GH_HOST=$host gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){id state merged isInMergeQueue headRefOid headRefName mergeQueueEntry{state} timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{createdAt reason}}}}}}' \
    -f "owner=$owner" -f "repo=$repo" -F "number=$number" \
    --jq '.data.repository.pullRequest | "id=" + (.id // ""), "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "entry=" + (.mergeQueueEntry.state // ""), "head=" + (.headRefOid // ""), "branch=" + (.headRefName // ""), "removed_at=" + (.timelineItems.nodes[-1].createdAt // ""), "removed_reason=" + ((.timelineItems.nodes[-1].reason // "") | gsub("[\r\n]+"; " "))' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      id=*) gq_id=${line#id=} ;;
      state=*) gq_state=${line#state=} ;;
      merged=*) gq_merged=${line#merged=} ;;
      queued=*) gq_queued=${line#queued=} ;;
      entry=*) gq_entry=${line#entry=} ;;
      head=*) gq_head=${line#head=} ;;
      branch=*) gq_branch=${line#branch=} ;;
      removed_at=*) gq_removed_at=${line#removed_at=} ;;
      removed_reason=*) gq_removed_reason=${line#removed_reason=} ;;
      *) continue ;;
    esac
  done <<GQ_FIELDS
$fields
GQ_FIELDS
  [ -n "$gq_state" ] && [ -n "$gq_head" ] || return 1
  { [ "$gq_merged" = true ] || [ "$gq_merged" = false ]; } || return 1
  { [ "$gq_queued" = true ] || [ "$gq_queued" = false ]; } || return 1
  return 0
}

github_queue_state_is_open() {
  case "$1" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# The effective merge-queue method for the pull request's base branch, the
# same rules read bin/fm-pr-merge.sh performs before it names re-enqueue
# flags (github_read_queue_method there; restated here because this static
# body can source nothing). GQ_METHOD is set only when exactly one recognized
# method governs the branch; every other outcome reports its own status, each
# of which means a different thing to the operator reading the ejection line.
GQ_METHOD=
GQ_METHOD_STATUS=unreadable
github_queue_method_read() {  # <host> <owner> <repo> <base>
  local host=$1 owner=$2 repo=$3 base=${4-} methods line candidate
  local count=0 unrecognised=false conflicting=false method='' encoded=''
  local char octet hex
  local LC_ALL=C
  GQ_METHOD=
  GQ_METHOD_STATUS=unreadable
  [ -n "$base" ] || return 0
  while [ -n "$base" ]; do
    char=${base%"${base#?}"}
    base=${base#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  if ! methods=$(GH_HOST=$host gh api --paginate \
      "repos/$owner/$repo/rules/branches/$encoded" \
      --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
      2>/dev/null); then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ "$count" -eq 1 ]; then
      method=$candidate
    elif [ "$candidate" != "$method" ]; then
      conflicting=true
    fi
  done <<GQ_METHODS
$methods
GQ_METHODS
  if [ "$count" -eq 0 ]; then
    GQ_METHOD_STATUS=none
  elif [ "$conflicting" = true ]; then
    GQ_METHOD_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    GQ_METHOD_STATUS=unrecognised
  else
    GQ_METHOD_STATUS=single
    case "$method" in
      MERGE) GQ_METHOD=merge ;;
      SQUASH) GQ_METHOD=squash ;;
      REBASE) GQ_METHOD=rebase ;;
    esac
  fi
  return 0
}

# The ejection report. A pull request this poll has read as queued that is now
# open, not merged, and no longer in the queue has been ejected by GitHub: the
# landing strands silently otherwise, because the merged line is this poll's
# only terminal output and an ejected pull request stays open. One
# non-terminal observation names the ejection with GitHub's own recorded
# reason, and the single re-enqueue - with the exact flags bin/fm-pr-merge.sh
# names for a queue base, --auto --<method> from the branch rules, bound to the
# observed head the way its merges are - runs at most once per pull request and
# is recorded in the queue memory before anything is attempted, so it never
# loops: a memory that cannot be written keeps the whole report silent (a
# repeatable line is worse than a missed one), a second ejection is reported
# without a second re-enqueue, and the write is committed before the line is
# printed, so a crash between them cannot re-wake the same ejection.
github_queue_ejection_report() {  # <state-dir> <task> <url> <host> <owner> <repo> <number>
  local state=${1-} task=${2-} u=$3 host=$4 owner=$5 repo=$6 number=$7
  local base plan=false used_next=false note
  local LC_ALL=C
  github_queue_memory_read "$state" "$task" "$u" || true
  if [ "$gq_queued" = true ]; then
    if [ "$GQ_WAS_QUEUED" != true ]; then
      github_queue_memory_write "$state" "$task" "$u" true "$GQ_REPORTED_AT" "$GQ_REENQUEUED" || true
    fi
    return 0
  fi
  github_queue_state_is_open "$gq_state" || return 0
  [ "$GQ_WAS_QUEUED" = true ] || return 0
  [ "$GQ_REPORTED_AT" != "$gq_removed_at" ] || return 0
  if [ "$GQ_REENQUEUED" != true ]; then
    base=$(GH_HOST=$host gh pr view "$u" --json baseRefName -q .baseRefName 2>/dev/null) || base=
    github_queue_method_read "$host" "$owner" "$repo" "$base"
    if [ "$GQ_METHOD_STATUS" = single ]; then
      plan=true
      used_next=true
    else
      case "$GQ_METHOD_STATUS" in
        none) note="; not re-enqueued: the base branch reports no merge queue rule" ;;
        conflicting) note="; not re-enqueued: the base branch has conflicting merge queue methods" ;;
        unrecognised) note="; not re-enqueued: the queue's merge method is not one this poll recognises" ;;
        *) note="; not re-enqueued: the branch rules could not be read" ;;
      esac
    fi
  else
    note="; not re-enqueued again: its one automatic re-enqueue was already used"
  fi
  # The report and its used retry are committed before either is spent: a
  # write that fails here keeps the line unprinted and the retry unattempted,
  # because neither could then be kept from repeating every sweep.
  github_queue_memory_write "$state" "$task" "$u" true "$gq_removed_at" "$used_next" || return 0
  if [ "$plan" = true ]; then
    if GH_HOST=$host gh pr merge "$number" --repo "$owner/$repo" \
        --match-head-commit "$gq_head" --auto --"$GQ_METHOD" >/dev/null 2>&1; then
      note="; re-enqueued once with the queue flags --auto --$GQ_METHOD"
    else
      note="; its one re-enqueue (--auto --$GQ_METHOD) failed"
    fi
  fi
  printf 'github queue ejected: %s left the merge queue without merging (removed at %s, reason: %s)%s\n' \
    "$u" "${gq_removed_at:-<no timestamp reported>}" "${gq_removed_reason:-<no reason reported>}" "$note"
}

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot silently address a different project or a differently
# spelled URL. The host is one of those components: a GitHub Enterprise host is
# recorded only by bin/fm-pr-lib.sh after this home named it in
# config/github-hosts, and it is re-checked for shape here like every other
# provider's, because this static body sources nothing and cannot read config.
case "$provider" in
  github)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
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
    [ "$url" = "https://$host/$owner/$repo/pull/$number" ] || exit 0
    # The queue-aware read runs first: without it (an older gh, a GitHub
    # Enterprise without the queue fields, or a failed call) the plain state
    # read below remains the fallback, so merged detection keeps working and
    # queue ejection, which only this read can see, stays silent.
    if github_queue_read "$host" "$owner" "$repo" "$number"; then
      if [ "$gq_state" = MERGED ]; then
        printf '%s\n' merged
        exit 0
      fi
      github_queue_ejection_report "${meta_state-}" "${meta_task-}" \
        "$url" "$host" "$owner" "$repo" "$number"
      exit 0
    fi
    state=$(GH_HOST=$host gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
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
  gerrit)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A Gerrit project name is a path at no fixed depth that needs no enclosing
    # group, so one segment is canonical here where GitLab needs two, and Gerrit
    # reserves no route segment inside it.
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
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 1 ] || exit 0
    [ "$url" = "https://$host/c/$path/+/$number" ] || exit 0
    # gerrit-axi resolves its server from the current directory's origin remote
    # first, and the watcher runs in no repository, so the host must be passed
    # explicitly from the validated record. Without it the tool has no host to
    # reach and fails before reading anything, and this poll is silent on every
    # failure, so the watch would wait forever on a change it never looked at.
    #
    # The status is read explicitly and is the only thing that can wake this
    # poll. Gerrit's submittability is a different question: a merged change
    # still reports its submit state as OK with nothing blocking it, so reading
    # submittability, a blocked_on list, or vote values would report a merge for
    # an open change that is merely ready to submit.
    #
    # jq selects the one record whose change number matches. A change number is
    # server-global and --host already pins the server, so the number alone
    # names the change. The record's own url field is deliberately not compared
    # against the stored URL: Gerrit composes that field from
    # gerrit.canonicalWebUrl and omits it when that setting is unset, so an
    # equality test would leave a correctly armed watch silent forever on such
    # a server, and this poll has no channel to report that it never matched.
    json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) || exit 0
    [ -n "$json" ] || exit 0
    status=$(printf '%s' "$json" | jq -r --argjson change "$number" '
      if type == "object" and .ok == true and (.changes | type) == "array" then
        [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
        | if ($match | length) == 1
             and ($match[0].status | type) == "string"
          then $match[0].status
          else error("no exact change record")
          end
      else
        error("invalid gerrit record")
      end' 2>/dev/null) || exit 0
    [ "$status" = MERGED ] && printf '%s\n' merged
    ;;
  forgejo)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    case "$path" in
      */*/*|/*|*/) exit 0 ;;
    esac
    owner=${path%%/*}
    repo=${path#*/}
    [ "$owner" != "$path" ] || exit 0
    for segment in "$owner" "$repo"; do
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 100 ] || exit 0
      case "$segment" in
        .|..|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
    command -v tea >/dev/null 2>&1 || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    # tea addresses a repo by slug only; the host comes from a named login
    # rather than a URL the way gh and glab take one, so the login registered
    # for this exact host is resolved fresh on every poll rather than trusted
    # from anywhere durable. Refuse to guess when zero or more than one
    # registered login matches, rather than picking one arbitrarily.
    # The list is parsed as JSON, never split on quotes per line, so a login
    # printed as one compact object still matches; this is the same filter
    # bin/fm-pr-lib.sh's fm_pr_forgejo_login applies.
    login=$(
      tea login list --output json 2>/dev/null | jq -er --arg h "$host" '
        if type == "array" then
          [ .[]
            | select(type == "object" and (.name | type) == "string" and (.name | length) > 0
                     and (.url | type) == "string")
            | select((.url
                      | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
                      | sub("[/?#].*$"; "")
                      | sub("^.*@"; "")
                      | sub(":[0-9]+$"; "")) == $h)
            | .name ]
          | if length == 1 then .[0] else error("not exactly one matching login") end
        else
          error("login list is not an array")
        end' 2>/dev/null
    ) || exit 0
    [ -n "$login" ] || exit 0
    # tea's single-PR view ignores field selection, so the one pull request
    # is read by number from the REST record through "tea api", which keeps
    # the credential inside tea. "tea api" exits 0 on an HTTP error with the
    # error body as output, so only a boolean merged field of true wakes this
    # poll and every other reading stays silent.
    merged=$(tea api --login "$login" --repo "$owner/$repo" \
      "/repos/{owner}/{repo}/pulls/$number" 2>/dev/null | jq -r '
        if type == "object" and (.merged | type) == "boolean"
        then .merged | tostring
        else error("invalid pull request record")
        end' 2>/dev/null) || exit 0
    [ "$merged" = true ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
