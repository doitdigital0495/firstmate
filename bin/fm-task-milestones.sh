#!/usr/bin/env bash
# Stamp and read task milestones in the existing append-only status stream.
# bin/fm-classify-lib.sh owns the strict record schema and timestamp grammar.
# bin/fm-nm-run-lib.sh owns the fail-closed review-coverage verdict.
#
# Usage:
#   fm-task-milestones.sh stamp FILE NAME [at=EPOCH] [sha=FULL_SHA]
#       [run=ID] [rounds=N] [snapshot=ID] [result=VALUE] -- EVIDENCE
#   fm-task-milestones.sh records FILE
#   fm-task-milestones.sh durations FILE [FILE...]
#   fm-task-milestones.sh coverage FILE RUN FULL_SHA [AXI_STATUS_OR_OUTCOME_FILE]
#   fm-task-milestones.sh deadlines FILE [NOW_EPOCH]
#
# stamp defaults to the real current epoch; at= is only for an authoritative
# event timestamp (for example the forge's actual merge time), never a guess.
# Evidence must be a non-secret single line, including the full https:// forge
# URL for pr-created, merge and uat-merge. Fields required by event:
#   brief: none
#   local-proof, dev-deploy, uat-deploy: sha
#   gate-start, gate-obsolete: sha run
#   gate-end: sha run rounds result=passed|failed|cancelled
#   review-coverage: sha run result=covered|uncovered|stale
#   pr-created, merge, uat-merge: sha
#   data-ready, uat-data-ready: sha snapshot
#   first-live-proof, uat-live-proof: sha snapshot result=passed|failed|partial|waived
#   dev-accepted, uat-accepted: sha snapshot result=passed
# Omit events the task does not reach; deployment and waived/partial/failed
# proof are not acceptance. Mark acceptance only after real same-SHA/snapshot
# data and live proof. Workers stamp their phases; the merge/deploy/proof owner
# stamps later phases even after the implementation worker has finished.
#
# records prints strict TSV: name epoch sha run rounds snapshot result.
# durations prints per-task seconds and unique gate-run counts/round totals;
# rework_rounds sums max(rounds-1,0) per ended run. Missing/reversed times,
# malformed measurements, unmatched gate ends and missing round counts are
# unknown, not zero. Duplicate run ends replace that run's earlier count.
# Accepted DEV/UAT must match preceding deployment, data and passed live proof;
# the first valid DEV acceptance and following UAT acceptance define duration.
# coverage prefers a supplied captured AXI record over status measurements.
# No completed review/green outcome/prose implies coverage. Missing explicit
# reviewed identity or a malformed record is unverified; a different run/head
# is stale. Older evidence cannot rescue a missing or stale current verdict.
# deadlines reports dispatch due at 15 minutes after the latest local proof
# without a following gate-start and escalation due at 30 minutes after a
# gate-obsolete observation without a successor gate-start. These are proposed
# service targets, not savings measurements or authority to discard fixes.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
fail() { printf 'fm-task-milestones: %s\n' "$*" >&2; exit 1; }

records() {
  local file=$1 line record
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(status_line_verb "$line")" = milestone ] || continue
    record=$(status_milestone_record "$line") || return 1
    printf '%s\n' "$record"
  done < "$file"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  stamp)
    [ "$#" -ge 5 ] || fail 'stamp requires FILE NAME [fields] -- EVIDENCE'
    file=$2 name=$3; shift 3
    line="milestone [name=$name]"; have_at=0
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
      case "$1" in at=*) have_at=1 ;; esac
      line="$line [$1]"; shift
    done
    [ "${1:-}" = -- ] && [ "$#" = 2 ] || fail 'supply one evidence argument after --'
    [ "$have_at" = 1 ] || line="$line [at=$(date +%s)]"
    line="$line: $2"
    status_milestone_record "$line" >/dev/null || fail 'invalid milestone; see --help'
    [ -d "$(dirname "$file")" ] || fail 'status parent directory is missing'
    [ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } \
      || fail 'status destination must be a regular file, not a symlink'
    printf '%s\n' "$line" >> "$file"
    ;;
  records)
    [ "$#" = 2 ] || fail 'records requires FILE'
    records "$2" || fail 'unreadable file or malformed milestone'
    ;;
  coverage)
    [ "$#" = 4 ] || [ "$#" = 5 ] || fail 'coverage requires FILE RUN FULL_SHA [AXI_FILE]'
    [[ "$4" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail 'coverage requires a full SHA'
    [[ "$3" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail 'invalid run id'
    if [ "$#" = 5 ]; then
      if [ -f "$5" ] && [ -r "$5" ] && [ ! -L "$5" ]; then
        outcome=$(< "$5")
        fm_nm_review_coverage "$outcome" "$3" "$4"
      else
        printf 'unverified\n'
      fi
    elif data=$(records "$2"); then
      latest=$(printf '%s\n' "$data" | awk -F '\t' '
        $1 == "gate-start" { last=""; obsolete=0 }
        $1 == "gate-obsolete" { last="stale"; obsolete=1 }
        $1 == "review-coverage" && !obsolete { last=$0 }
        $1 == "gate-end" && last != "" && last != "stale" {
          split(last, coverage, "\t")
          if ($3 != coverage[3] || $4 != coverage[4]) last="stale"
        }
        END { print last }')
      if [ "$latest" = stale ]; then
        printf 'stale\n'
      elif [ -n "$latest" ]; then
        IFS=$'\t' read -r name epoch sha run rounds snapshot result <<EOF
$latest
EOF
        fm_nm_review_coverage_verdict "$result" "$run" "$sha" "$3" "$4"
      else
        printf 'unverified\n'
      fi
    else
      printf 'unverified\n'
    fi
    ;;
  durations)
    [ "$#" -ge 2 ] || fail 'durations requires FILE [FILE...]'
    shift
    printf 'task\tbrief_to_accepted_dev_seconds\taccepted_dev_to_accepted_uat_seconds\tgate_runs\tgate_rounds\trework_rounds\tfailed_gates\n'
    for file in "$@"; do
      task=$(basename "$file" .status)
      if ! data=$(records "$file"); then
        printf '%s\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\n' "$task"
        continue
      fi
      printf '%s\n' "$data" | awk -F '\t' -v task="$task" '
        function delta(a,b) { return a != "" && b != "" && b >= a ? b-a : "unknown" }
        $1 == "brief" && brief == "" { brief=$2 }
        $1 == "gate-start" { starts[$4]=$2 }
        $1 == "gate-end" { ends[$4]=$2; rounds[$4]=$5; results[$4]=$7 }
        $1 == "dev-deploy" { devsha=$3; devtime=$2; ds=""; live="" }
        $1 == "data-ready" && $3 == devsha && $2 >= devtime { ds=$6; dstime=$2; live="" }
        $1 == "first-live-proof" && $3 == devsha && $6 == ds && $2 >= dstime {
          live=$7 == "passed" ? $2 : ""
        }
        $1 == "dev-accepted" && dev == "" && $3 == devsha && $6 == ds && live != "" && $2 >= live { dev=$2 }
        $1 == "uat-deploy" { uatsha=$3; uattime=$2; us=""; ulive="" }
        $1 == "uat-data-ready" && $3 == uatsha && $2 >= uattime { us=$6; ustime=$2; ulive="" }
        $1 == "uat-live-proof" && $3 == uatsha && $6 == us && $2 >= ustime {
          ulive=$7 == "passed" ? $2 : ""
        }
        $1 == "uat-accepted" && uat == "" && dev != "" && $2 >= dev && $3 == uatsha && $6 == us && ulive != "" && $2 >= ulive { uat=$2 }
        END {
          count=total=rework=failed=0; incomplete=0
          for (run in starts) {
            count++
            if (!(run in ends) || ends[run] < starts[run]) { incomplete=1; continue }
            total+=rounds[run]; rework+=rounds[run] > 1 ? rounds[run]-1 : 0
            if (results[run] == "failed") failed++
          }
          for (run in ends) if (!(run in starts)) incomplete=1
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", task, delta(brief,dev), delta(dev,uat), count,
            incomplete ? "unknown" : total, incomplete ? "unknown" : rework, incomplete ? "unknown" : failed
        }'
    done
    ;;
  deadlines)
    [ "$#" = 2 ] || [ "$#" = 3 ] || fail 'deadlines requires FILE [NOW_EPOCH]'
    now=${3:-$(date +%s)}
    status_line_at_epoch "note [at=$now]: clock" >/dev/null || fail 'invalid clock'
    data=$(records "$2") || fail 'unreadable file or malformed milestone'
    printf '%s\n' "$data" | awk -F '\t' -v now="$now" '
      $1 == "local-proof" { localproof=$2; dispatched="" }
      $1 == "gate-obsolete" { obsolete=$2; run=$4 }
      $1 == "gate-start" {
        if ($2 >= localproof) dispatched=$2
        if ($2 >= obsolete && $4 != run) obsolete=""
      }
      END {
        if (localproof != "" && dispatched == "" && now-localproof >= 900)
          print "gate dispatch overdue: " now-localproof " seconds since local proof"
        if (obsolete != "" && now-obsolete >= 1800)
          print "obsolete gate escalation due: run " run " age " now-obsolete " seconds"
      }'
    ;;
  *) usage >&2; exit 1 ;;
esac
