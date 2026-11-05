#!/usr/bin/env bash
# fm-suggestions.sh - the suggested-tasks list: worker follow-ups kept off the board.
#
# A worker follow-up is a lead, not a decision, so it is never a backlog row until
# the captain picks it. This script is the only writer of two local files in the
# home's data directory (FM_DATA_OVERRIDE, else $FM_HOME/data):
#   suggestions.jsonl             every recorded follow-up not yet expired
#   suggestions-not-picked.jsonl  the "not picked" archive; records are never deleted
# Nothing dispatches from either file, and neither is a tasks-axi state.
# .agents/skills/scout-completion/SKILL.md owns the judgment applied before intake;
# this script owns the mechanics below.
#
# Usage:
#   fm-suggestions.sh add --origin <task-id> --title <one-line outcome>
#       [--item <report-number>] [--file-line <path:line>] [--size S|M|L]
#       [--kind defect|hardening|doc-nit|question|research] [--risk <text>]
#       [--repo <name>] [--recommend pick|bundle|drop] [--hold]
#   fm-suggestions.sh summary [--json]
#   fm-suggestions.sh digest [--json]
#   fm-suggestions.sh pick <suggestion-id>... [--task-kind <kind>]
#   fm-suggestions.sh bundle <suggestion-id>... --into <suggestion-or-task-id>
#   fm-suggestions.sh expire
#   fm-suggestions.sh archive [--json]
#   fm-suggestions.sh check <task-id> [--report <path>]
#
# Recorded outcomes (the `outcome` field):
#   suggested  waiting in the list
#   picked     the captain picked it; `target` is the backlog row it filed
#   bundled    folded into `target`
#   repeat     duplicate of `target`, a suggestion or an open backlog row
#   expired    went unpicked for FM_SUGGESTIONS_EXPIRE_DAYS (default 30) days
#   escalated  sent to the captain; `target` is the captain-held row
#
# add        Prints `<outcome> <id> [<target>]`. A repeated --origin/--item pair,
#            or the same origin and title, returns the first result unchanged.
#            A repeat is an earlier record with the same normalized title, or the
#            same --file-line and --kind, or an open backlog row with the same
#            normalized title or naming that --file-line. A repeat of a suggestion
#            raises that suggestion's `seen` count, which the digest shows.
#            Escalation: a --risk starting with `security` or `data-loss`, or
#            --hold, creates a captain-held row through bin/fm-captain-hold.sh and
#            records `escalated`. It skips de-duplication because a waiting or
#            filed lookalike does not put the finding in front of the captain; only
#            an earlier escalation of the same finding counts as a repeat, and a
#            waiting lookalike becomes a repeat of the new escalation.
#            A backlog that cannot be read refuses the intake rather than skipping
#            the de-duplication.
# summary    Read-only and lock-free, so bin/fm-bearings-snapshot.sh can call it.
#            Past-due records already count as gone even before `expire` moves them.
#            --json prints {count, oldest_age_days, line}; plain prints the line,
#            which is empty when nothing is waiting.
# digest     Expires past-due records, then lists what is waiting, oldest first.
# pick       Files a backlog row for each id with a stable row id, so a retry after
#            a partial failure reuses the row. Works on an archived record too.
#            Does not start the row. Prints `picked <id> <task-id>`.
#            Default task kind: scout for question and research, otherwise ship.
# bundle     Records each id as bundled into the target, which must be a waiting
#            suggestion or an open backlog row.
# expire     Moves past-due records to the archive. Idempotent, also after a crash
#            between the archive append and the list rewrite.
# archive    Lists the "not picked" archive.
# check      The teardown gate. Counts the numbered items under the report's
#            follow-ups heading (default report: <data>/<task-id>/report.md) and
#            exits 1 naming each number with no record for that --origin/--item.
#            A missing report or a section with no numbered items passes.
#
# Environment: FM_SUGGESTIONS_NOW (epoch override), FM_SUGGESTIONS_EXPIRE_DAYS.
# Exit: 0 ok, 1 refused or failed check, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LIST="$DATA/suggestions.jsonl"
ARCHIVE="$DATA/suggestions-not-picked.jsonl"
LOCK="$DATA/.suggestions.lock"
NOW="${FM_SUGGESTIONS_NOW:-$(date +%s)}"
EXPIRE_DAYS="${FM_SUGGESTIONS_EXPIRE_DAYS:-30}"
LOCK_HELD=0

die() { printf 'fm-suggestions: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

require_jq() { command -v jq >/dev/null 2>&1 || die "jq not found"; }
case "$NOW" in ''|*[!0-9]*) die "FM_SUGGESTIONS_NOW must be an epoch" 2 ;; esac
case "$EXPIRE_DAYS" in ''|*[!0-9]*) die "FM_SUGGESTIONS_EXPIRE_DAYS must be a whole number" 2 ;; esac

# shellcheck disable=SC2016
JQ_DEFS='
  def norm: ascii_downcase | [scan("[a-z0-9]+")] | join(" ");
  def age_days($now): (($now - .filed_at) / 86400 | floor);
  def past_due($now; $days): .outcome == "suggested" and ($now - .filed_at) >= ($days * 86400);
  def names_ref($ref):
    ($ref != "") and (. as $text | ($text | split($ref)) as $parts
      | ($parts | length) > 1
        and any($parts[1:][]; test("^[0-9]") | not));
'

release_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null
  LOCK_HELD=0
}

# A directory lock, because flock is absent on macOS. A holder that died is
# reclaimed by renaming its lock first, so two waiters cannot both remove it.
acquire_lock() {
  local tries=0 holder stale
  mkdir -p "$DATA" || die "cannot create $DATA"
  until mkdir "$LOCK" 2>/dev/null; do
    holder=$(cat "$LOCK/pid" 2>/dev/null) || holder=
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      stale="$LOCK.stale.$$"
      if mv "$LOCK" "$stale" 2>/dev/null; then
        rm -f "$stale/pid"
        rmdir "$stale" 2>/dev/null
        continue
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 150 ] || die "timed out waiting for $LOCK"
    sleep 0.2
  done
  printf '%s\n' "$$" > "$LOCK/pid"
  LOCK_HELD=1
  trap release_lock EXIT
}

# One JSON array of a store's records. An unreadable store refuses, because a
# rewrite built from a partial read would delete what it could not parse.
read_store() {  # <file>
  [ -s "$1" ] || { printf '[]\n'; return 0; }
  jq -s -c '.' "$1" 2>/dev/null || die "cannot parse $1; refusing to read or rewrite it"
}

write_store() {  # <file> <json-array>
  local tmp
  case "$2" in '['*) ;; *) die "refusing to rewrite $1 from an unreadable state" ;; esac
  tmp=$(mktemp "$1.XXXXXX") || die "cannot write beside $1"
  if ! printf '%s' "$2" | jq -c '.[]' > "$tmp" || ! mv "$tmp" "$1"; then
    rm -f "$tmp"
    die "cannot write $1"
  fi
}

# Open backlog rows as a JSON array of {id, title, body}. tasks-axi lists rows as
# TOON, whose quoted cells are JSON strings and whose other cells have no comma.
open_rows() {
  local listing
  listing=$("$SCRIPT_DIR/fm-tasks-axi.sh" list --fields body 2>/dev/null) || return 1
  case "$listing" in count:*|tasks*) ;; *) return 1 ;; esac
  printf '%s\n' "$listing" | jq -R -s -c '
    [ split("\n")[]
      | select(test("^  [A-Za-z0-9._-]+,"))
      | [ ltrimstr("  ")
          | match("(?:^|,)(\"(?:[^\"\\\\]|\\\\.)*\"|[^,]*)"; "g").captures[0].string
          | if startswith("\"") then fromjson else . end ]
      | select(.[1] != "done")
      | {id:.[0], title:.[4], body:(.[5] // "")} ]'
}

# A readable, stable id for a row filed from a suggestion.
row_id_for() {  # <suggestion-id> <title>
  local slug
  slug=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40)
  slug=${slug#-}
  slug=${slug%-}
  printf '%s%s\n' "${slug:+$slug-}" "${1#sg-}"
}

hash_of() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-8
  else
    printf '%s' "$1" | sha256sum | cut -c1-8
  fi
}

# Move past-due records to the archive. The append comes first and skips ids the
# archive already holds, so a crash before the rewrite converges on the next run.
do_expire() {
  local list archive due merged
  list=$(read_store "$LIST") || exit 1
  due=$(jq -c --argjson now "$NOW" --argjson days "$EXPIRE_DAYS" "$JQ_DEFS"'
    [ .[] | select(past_due($now; $days)) | .outcome = "expired" | .resolved_at = $now ]' <<<"$list")
  [ "$due" != "[]" ] || { printf '0\n'; return 0; }
  archive=$(read_store "$ARCHIVE") || exit 1
  merged=$(jq -c --argjson due "$due" '. as $old
    | ($old | map(.id)) as $ids
    | $old + [ $due[] | select(.id as $id | $ids | index($id) | not) ]' <<<"$archive")
  write_store "$ARCHIVE" "$merged"
  write_store "$LIST" "$(jq -c --argjson due "$due" \
    '($due | map(.id)) as $ids | [ .[] | select(.id as $id | $ids | index($id) | not) ]' <<<"$list")"
  jq 'length' <<<"$due"
}

cmd_add() {
  local origin='' title='' item='' file_line='' size='' kind='' risk='' repo='' recommend='' hold=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --hold) hold=1; shift; continue ;;
      --origin|--title|--item|--file-line|--size|--kind|--risk|--repo|--recommend)
        [ $# -ge 2 ] || die "$1 needs a value" 2 ;;
      *) die "add: unknown argument $1" 2 ;;
    esac
    case "$1" in
      --origin) origin=$2 ;;
      --title) title=$2 ;;
      --item) item=$2 ;;
      --file-line) file_line=$2 ;;
      --size) size=$2 ;;
      --kind) kind=$2 ;;
      --risk) risk=$2 ;;
      --repo) repo=$2 ;;
      --recommend) recommend=$2 ;;
    esac
    shift 2
  done
  title=$(printf '%s' "$title" | tr '\n\t' '  ' | sed 's/^ *//; s/ *$//')
  [ -n "$origin" ] || die "add: --origin is required" 2
  [ -n "$title" ] || die "add: --title is required" 2
  case "$item" in *[!0-9]*) die "add: --item must be a number" 2 ;; esac
  [ -z "$item" ] || item=$((10#$item))
  case "$size" in ''|S|M|L) ;; *) die "add: --size must be S, M or L" 2 ;; esac
  case "$kind" in ''|defect|hardening|doc-nit|question|research) ;; *) die "add: --kind must be defect, hardening, doc-nit, question or research" 2 ;; esac
  case "$recommend" in ''|pick|bundle|drop) ;; *) die "add: --recommend must be pick, bundle or drop" 2 ;; esac
  case "$(printf '%s' "$risk" | tr '[:upper:]' '[:lower:]')" in
    security|security[!a-z-]*|data-loss|data-loss[!a-z-]*|data\ loss|data\ loss[!a-z-]*) hold=1 ;;
  esac

  acquire_lock
  do_expire >/dev/null
  local list archive prior id record match rows row_match held_reason held_id
  list=$(read_store "$LIST") || exit 1
  archive=$(read_store "$ARCHIVE") || exit 1

  id="sg-$(hash_of "$origin|$item|$title")"
  prior=$(jq -r -n --argjson l "$list" --argjson a "$archive" --arg id "$id" --arg o "$origin" --arg n "$item" '
    first(($l + $a)[] | select(.id == $id or ($n != "" and .origin == $o and .item == ($n | tonumber))))
    | [.outcome, .id, (.target // "")] | join(" ")')
  if [ -n "$prior" ]; then
    printf '%s\n' "$prior" | sed 's/ *$//'
    return 0
  fi

  record=$(jq -c -n --arg id "$id" --arg origin "$origin" --arg item "$item" --arg title "$title" \
    --arg fl "$file_line" --arg size "$size" --arg kind "$kind" --arg risk "$risk" --arg repo "$repo" \
    --arg recommend "$recommend" --argjson now "$NOW" '
    {id:$id, origin:$origin, item:(if $item == "" then null else ($item | tonumber) end), title:$title,
     file_line:$fl, size:$size, kind:$kind, risk:$risk, repo:$repo, recommend:$recommend,
     filed_at:$now, resolved_at:null, outcome:"suggested", target:null, seen:1}')

  # An earlier record of the same finding; repeats point at their target instead.
  match=$(jq -c -n --argjson l "$list" --argjson a "$archive" --argjson r "$record" "$JQ_DEFS"'
    ($r.title | norm) as $t
    | [ ($l + $a)[] | select(.outcome != "repeat")
        | select((.title | norm) == $t
                 or ($r.file_line != "" and .file_line == $r.file_line and .kind == $r.kind)) ]
    | sort_by(.filed_at) | first // empty')

  if [ "$hold" = 1 ]; then
    if [ -n "$match" ] && [ "$(jq -r .outcome <<<"$match")" = escalated ]; then
      record_repeat "$list" "$record" "$(jq -r .id <<<"$match")" "$(jq -r .id <<<"$match")"
      return 0
    fi
    held_id=$(row_id_for "$id" "$title")
    held_reason="Follow-up from $origin: $title${file_line:+ ($file_line)}${risk:+ - risk if ignored: $risk}"
    "$SCRIPT_DIR/fm-captain-hold.sh" hold "$held_id" --reason "$held_reason" --title "$title" \
      ${repo:+--repo "$repo"} >/dev/null \
      || die "the captain hold for $held_id failed; nothing recorded, so retry this intake"
    list=$(jq -c --argjson m "${match:-null}" --arg id "$id" --argjson now "$NOW" '
      if $m == null then . else
        map(if .id == $m.id and .outcome == "suggested"
            then .outcome = "repeat" | .target = $id | .resolved_at = $now else . end) end' <<<"$list")
    write_store "$LIST" "$(jq -c --argjson r "$record" --arg t "$held_id" --argjson now "$NOW" \
      '. + [$r | .outcome = "escalated" | .target = $t | .resolved_at = $now]' <<<"$list")"
    printf 'escalated %s %s\n' "$id" "$held_id"
    return 0
  fi

  if [ -n "$match" ]; then
    record_repeat "$list" "$record" "$(jq -r .id <<<"$match")" "$(jq -r .id <<<"$match")"
    return 0
  fi

  rows=$(open_rows) || die "cannot read the backlog to de-duplicate; nothing recorded, so retry this intake"
  row_match=$(jq -r -n --argjson rows "$rows" --argjson r "$record" "$JQ_DEFS"'
    ($r.title | norm) as $t
    | first($rows[] | select((.title | norm) == $t
        or ((.title + "\n" + .body) | names_ref($r.file_line)))) | .id')
  if [ -n "$row_match" ]; then
    record_repeat "$list" "$record" "$row_match" ""
    return 0
  fi

  write_store "$LIST" "$(jq -c --argjson r "$record" '. + [$r]' <<<"$list")"
  printf 'suggested %s\n' "$id"
}

# Records the repeat and raises the seen count of the suggestion it repeats. An
# archived target is left as archived: repeats do not revive what went unpicked.
record_repeat() {  # <list-json> <record> <target-id> <suggestion-id-or-empty>
  local list=$1 record=$2 target=$3 bump=$4 updated
  updated=$(jq -c --argjson r "$record" --arg t "$target" --arg b "$bump" --argjson now "$NOW" '
    map(if .id == $b then .seen = ((.seen // 1) + 1) else . end)
    + [$r | .outcome = "repeat" | .target = $t | .resolved_at = $now]' <<<"$list")
  write_store "$LIST" "$updated"
  printf 'repeat %s %s\n' "$(jq -r .id <<<"$record")" "$target"
}

cmd_summary() {
  local json=0 list
  case "${1-}" in --json) json=1 ;; '') ;; *) die "summary: unknown argument $1" 2 ;; esac
  list=$(read_store "$LIST") || exit 1
  jq -n --argjson l "$list" --argjson now "$NOW" --argjson days "$EXPIRE_DAYS" --argjson json "$json" "$JQ_DEFS"'
    [ $l[] | select(.outcome == "suggested" and (past_due($now; $days) | not)) ] as $open
    | ($open | length) as $n
    | (if $n == 0 then null else ($open | map(age_days($now)) | max) end) as $oldest
    | (if $n == 0 then "" else
         "\($n) suggested task\(if $n == 1 then "" else "s" end), oldest \($oldest)d" end) as $line
    | if $json == 1 then {count:$n, oldest_age_days:$oldest, line:$line} else $line end' \
    | if [ "$json" = 1 ]; then cat; else jq -r .; fi
}

cmd_digest() {
  local json=0 list
  case "${1-}" in --json) json=1 ;; '') ;; *) die "digest: unknown argument $1" 2 ;; esac
  acquire_lock
  do_expire >/dev/null
  release_lock
  list=$(read_store "$LIST") || exit 1
  if [ "$json" = 1 ]; then
    jq --argjson now "$NOW" "$JQ_DEFS"'
      [ .[] | select(.outcome == "suggested") | . + {age_days:age_days($now)} ] | sort_by(.filed_at)' <<<"$list"
    return 0
  fi
  cmd_summary
  jq -r --argjson now "$NOW" "$JQ_DEFS"'
    [ .[] | select(.outcome == "suggested") ] | sort_by(.filed_at)[]
    | "- \(.id) [\(age_days($now))d\(if .repo != "" then ", " + .repo else "" end)\(if .kind != "" then ", " + .kind else "" end)\(if .size != "" then ", " + .size else "" end)] \(.title)"
      + (if .file_line != "" then " (\(.file_line))" else "" end)
      + (if .risk != "" then " - risk: \(.risk)" else "" end)
      + (if .seen > 1 then " - seen \(.seen) times" else "" end)
      + (if .recommend != "" then " - recommend \(.recommend)" else "" end)' <<<"$list"
}

cmd_pick() {
  local ids=() task_kind=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-kind) [ $# -ge 2 ] || die "--task-kind needs a value" 2; task_kind=$2; shift 2 ;;
      -*) die "pick: unknown argument $1" 2 ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  [ "${#ids[@]}" -gt 0 ] || die "pick: name at least one suggestion id" 2
  acquire_lock
  do_expire >/dev/null
  local id status=0
  for id in "${ids[@]}"; do
    pick_one "$id" "$task_kind" || status=1
  done
  return "$status"
}

pick_one() {  # <id> <task-kind-or-empty>
  local id=$1 kind=$2 store=$LIST content record outcome row title rows body
  content=$(read_store "$store") || exit 1
  record=$(jq -c --arg id "$id" 'first(.[] | select(.id == $id)) // empty' <<<"$content")
  if [ -z "$record" ]; then
    store=$ARCHIVE
    content=$(read_store "$store") || exit 1
    record=$(jq -c --arg id "$id" 'first(.[] | select(.id == $id)) // empty' <<<"$content")
  fi
  [ -n "$record" ] || { printf 'fm-suggestions: no suggestion %s\n' "$id" >&2; return 1; }
  outcome=$(jq -r .outcome <<<"$record")
  case "$outcome" in
    picked) printf 'picked %s %s\n' "$id" "$(jq -r .target <<<"$record")"; return 0 ;;
    suggested|expired) ;;
    *) printf 'fm-suggestions: %s is already %s (%s)\n' "$id" "$outcome" "$(jq -r '.target // "-"' <<<"$record")" >&2; return 1 ;;
  esac
  title=$(jq -r .title <<<"$record")
  row=$(row_id_for "$id" "$title")
  rows=$(open_rows) || { printf 'fm-suggestions: cannot read the backlog; %s not picked\n' "$id" >&2; return 1; }
  if ! jq -e --arg row "$row" 'any(.[]; .id == $row)' <<<"$rows" >/dev/null; then
    [ -n "$kind" ] || case "$(jq -r .kind <<<"$record")" in
      question|research) kind=scout ;;
      *) kind=ship ;;
    esac
    body=$(jq -r '"Picked from suggestion \(.id), a follow-up of \(.origin)."
      + (if .file_line != "" then "\nWhere: \(.file_line)" else "" end)
      + (if .size != "" then "\nSize: \(.size)" else "" end)
      + (if .kind != "" then "\nKind: \(.kind)" else "" end)
      + (if .risk != "" then "\nRisk if ignored: \(.risk)" else "" end)' <<<"$record")
    local repo
    repo=$(jq -r .repo <<<"$record")
    "$SCRIPT_DIR/fm-tasks-axi.sh" add "$row" "$title" --kind "$kind" ${repo:+--repo "$repo"} --body "$body" >/dev/null \
      || { printf 'fm-suggestions: filing a row for %s failed\n' "$id" >&2; return 1; }
  fi
  write_store "$store" "$(jq -c --arg id "$id" --arg row "$row" --argjson now "$NOW" '
    map(if .id == $id then .outcome = "picked" | .target = $row | .resolved_at = $now else . end)' <<<"$content")"
  printf 'picked %s %s\n' "$id" "$row"
}

cmd_bundle() {
  local ids=() into=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --into) [ $# -ge 2 ] || die "--into needs a value" 2; into=$2; shift 2 ;;
      -*) die "bundle: unknown argument $1" 2 ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  [ -n "$into" ] || die "bundle: --into is required" 2
  [ "${#ids[@]}" -gt 0 ] || die "bundle: name at least one suggestion id" 2
  acquire_lock
  do_expire >/dev/null
  local list rows id
  list=$(read_store "$LIST") || exit 1
  if ! jq -e --arg t "$into" 'any(.[]; .id == $t and .outcome == "suggested")' <<<"$list" >/dev/null; then
    rows=$(open_rows) || die "cannot read the backlog to verify $into"
    jq -e --arg t "$into" 'any(.[]; .id == $t)' <<<"$rows" >/dev/null \
      || die "bundle target $into is neither a waiting suggestion nor an open backlog row"
  fi
  for id in "${ids[@]}"; do
    [ "$id" != "$into" ] || die "cannot bundle $id into itself"
    jq -e --arg id "$id" 'any(.[]; .id == $id and .outcome == "suggested")' <<<"$list" >/dev/null \
      || die "$id is not a waiting suggestion; nothing bundled"
    list=$(jq -c --arg id "$id" --arg t "$into" --argjson now "$NOW" '
      map(if .id == $id then .outcome = "bundled" | .target = $t | .resolved_at = $now else . end)' <<<"$list")
  done
  write_store "$LIST" "$list"
  printf 'bundled %s into %s\n' "${ids[*]}" "$into"
}

cmd_expire() {
  [ $# -eq 0 ] || die "expire: takes no arguments" 2
  acquire_lock
  local moved
  moved=$(do_expire) || exit 1
  printf 'expired %s\n' "$moved"
}

cmd_archive() {
  local json=0 archive
  case "${1-}" in --json) json=1 ;; '') ;; *) die "archive: unknown argument $1" 2 ;; esac
  archive=$(read_store "$ARCHIVE") || exit 1
  if [ "$json" = 1 ]; then
    jq . <<<"$archive"
  else
    jq -r '.[] | "- \(.id) [\(.outcome)] \(.title)" + (if .target then " -> \(.target)" else "" end)' <<<"$archive"
  fi
}

# The numbered items directly under the report's follow-ups heading.
report_items() {  # <report>
  awk '
    /^#+[[:space:]]/ {
      heading = tolower($0)
      inside = (heading ~ /follow-?ups?/)
      next
    }
    inside && /^[0-9]+[.)][[:space:]]/ {
      n = $0
      sub(/[.)].*/, "", n)
      print n + 0
    }
  ' "$1"
}

cmd_check() {
  local id='' report='' items list archive records missing='' n
  while [ $# -gt 0 ]; do
    case "$1" in
      --report) [ $# -ge 2 ] || die "--report needs a value" 2; report=$2; shift 2 ;;
      -*) die "check: unknown argument $1" 2 ;;
      *) [ -z "$id" ] || die "check: one task id only" 2; id=$1; shift ;;
    esac
  done
  [ -n "$id" ] || die "check: name the task id" 2
  [ -n "$report" ] || report="$DATA/$id/report.md"
  [ -f "$report" ] || { printf 'ok %s: no report\n' "$id"; return 0; }
  items=$(report_items "$report")
  [ -n "$items" ] || { printf 'ok %s: no numbered follow-ups\n' "$id"; return 0; }
  require_jq
  list=$(read_store "$LIST") || exit 1
  archive=$(read_store "$ARCHIVE") || exit 1
  records=$(jq -c -n --argjson l "$list" --argjson a "$archive" --arg o "$id" \
    '[($l + $a)[] | select(.origin == $o) | .item]')
  for n in $items; do
    jq -e --argjson n "$n" 'index($n) != null' <<<"$records" >/dev/null || missing="$missing $n"
  done
  if [ -n "$missing" ]; then
    printf 'missing %s: follow-ups without a recorded outcome:%s\n' "$id" "$missing"
    return 1
  fi
  printf 'ok %s: every follow-up has a recorded outcome\n' "$id"
}

command=${1-}
[ $# -eq 0 ] || shift
# check needs jq only once a report has items, so teardown of a task with no
# follow-ups keeps working on a host or PATH without it.
case "$command" in add|summary|digest|pick|bundle|expire|archive) require_jq ;; esac
case "$command" in
  add) cmd_add "$@" ;;
  summary) cmd_summary "$@" ;;
  digest) cmd_digest "$@" ;;
  pick) cmd_pick "$@" ;;
  bundle) cmd_bundle "$@" ;;
  expire) cmd_expire "$@" ;;
  archive) cmd_archive "$@" ;;
  check) cmd_check "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command $command" 2 ;;
esac
