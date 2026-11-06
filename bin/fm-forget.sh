#!/usr/bin/env bash
# fm-forget.sh - take tasks off this home's lists without losing them, and put
# them back: the one guarded owner of the Bridge's Remove and Restore.
#
# Usage:
#   fm-forget.sh remove  [--batch <batch-id>] [--by <who>] <id>[@<rev>]...
#   fm-forget.sh restore [--batch <batch-id>] [--by <who>] [<id>...]
#   fm-forget.sh list [--json]
#   fm-forget.sh feed
#
# remove   Moves each allowed task row, byte for byte, out of the task list
#          into data/forgotten.md with `tasks-axi mv`, so it leaves every lane,
#          digest, session-start listing and board, and records it in
#          data/forgotten-index.jsonl. Nothing is deleted. A suggestion id
#          (sg-...) is dropped through `fm-suggestions.sh drop` instead and
#          recorded the same way. All ids of one call share one batch id
#          (--batch, else a new one). An `@<rev>` suffix is the row revision
#          the caller saw (`feed`); a row that changed since is kept.
# restore  Moves rows back from data/forgotten.md, unchanged, and relinks any
#          dependency the removal had to cut. `--batch <id>` with no ids restores
#          every row of that batch still waiting; ids alone restore just those.
#          A dropped suggestion goes back to the waiting suggestions.
# list     The removed rows still restorable, newest first: plain lines of
#          `<id> <batch> <removed-at> <title>`, or `--json`.
# feed     Read-only, lock-free JSON (fm-forget-feed.v1) for bin/fm-bridge.sh:
#          every row of the task list with its revision and the reason it
#          cannot be removed (`keep`), the removed list, the waiting
#          suggestions and the wording of every keep reason. It decides nothing
#          the guarded verbs do not decide again under their locks.
#
# Each id of remove and restore prints one result line, then a summary:
#   removed <id> | restored <id> | kept <id>: <why, in plain words>
#   batch <batch-id> removed=<n> kept=<n>    (restored=<n> for restore)
# Exit 0 when the call ran, even if some ids were kept; 1 when nothing could
# be checked (unreadable list, lock timeout, bad home); 2 for usage.
#
# GUARDS. Removal is for unwanted waiting work only. Under this home's store
# lock and each task's `.control-<id>.lock` and meta lock (the locks spawn,
# teardown, the PR poller and captain holds take), remove re-reads the list and
# keeps, with its reason, any task that:
#   - is not a waiting (queued) row of this home's own task list, including a
#     row already removed or a secondmate home;
#   - has started, or still has a worker record, a pending backlog close or a
#     relaunch record: its worktree may hold unlanded work, and teardown must
#     find its row (finish it with the normal teardown instead);
#   - is a captain hold: it is a question for the captain, answered in Needs you,
#     never closed by Remove (no words are written in the captain's name);
#   - has an open keyed question in its status log;
#   - carries a recorded pull request or report link;
#   - is still needed by an open task that is not removed in the same call;
#   - changed since the caller's revision, or has another action running.
# A task whose blocker stays on the list can be removed: the link is cut first,
# recorded in the index, and restored with the row. Restore keeps a row whose
# id is on the list again, or whose blocker or dependent was removed with it
# and is not restored in the same call. Rows are restored in one `mv`.
#
# FILES (all mode 0600, in the home's data directory):
#   forgotten.md            removed rows, in the task list's own format
#   forgotten-archive.md    rows removed more than FM_FORGET_KEEP_DAYS (90)
#                           days ago; never deleted, restorable only by hand
#   forgotten-index.jsonl   append-only events, one JSON object per line:
#     {"schema":"fm-forget.v1","event":"removed"|"restored"|"archived",
#      "id","kind":"task"|"suggestion","batch","at":<epoch>,"by","title",
#      "unlinked":[<blocker ids cut at removal>],"relinked":[...],"note"}
# A row counts as removed only while it is in forgotten.md; the index adds who,
# when and which batch. Every remove or restore first moves rows older than the
# keep window to forgotten-archive.md (a connected set only when all of it is
# due). state/.forget-journal records cut links before they are cut, so a crash
# between cutting and moving is repaired by the next call. --by is recorded as
# given (default "firstmate"); bin/fm-bridge-intake.sh passes the Lavish result
# the captain pressed, never the captain's words.
#
# Removal needs the markdown task list (the default backend); another backend
# refuses. FM_FORGET_NOW (epoch) and FM_FORGET_KEEP_DAYS exist for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FORGOTTEN="$DATA/forgotten.md"
ARCHIVE_MD="$DATA/forgotten-archive.md"
INDEX="$DATA/forgotten-index.jsonl"
JOURNAL="$STATE/.forget-journal"
STORE_LOCK="$STATE/.forget.lock"
NOW="${FM_FORGET_NOW:-$(date +%s)}"
KEEP_DAYS="${FM_FORGET_KEEP_DAYS:-90}"
MAX_IDS=500
# The fields a row's revision covers: everything a person could have read on
# the page, and nothing derived from other rows or from today's date.
LIST_FIELDS=body,created,links,deps,blocked_by,hold_kind,hold_reason,hold_until,priority
# jq helper: array membership that binds the element before piping.
# shellcheck disable=SC2016 # jq source, not a shell expansion.
JQ_MEMBER='def member($a; $x): (($a // []) | index($x)) != null;'
REV_KEYS='["id","state","kind","repo","title","body","created","links","deps","hold_kind","hold_reason","hold_until","priority"]'

case "$NOW" in ''|*[!0-9]*) printf 'fm-forget: FM_FORGET_NOW must be an epoch\n' >&2; exit 2 ;; esac
case "$KEEP_DAYS" in ''|*[!0-9]*) printf 'fm-forget: FM_FORGET_KEEP_DAYS must be a whole number\n' >&2; exit 2 ;; esac

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() { printf 'fm-forget: %s\n' "$1" >&2; exit "${2:-1}"; }

# The plain words for every keep reason; `feed` publishes them so the Bridge's
# preflight says exactly what the guarded verbs say.
REASONS_JSON='{
  "absent": "It is not on this home'"'"'s task list.",
  "already-removed": "It is already removed; restore it from the removed list.",
  "secondmate": "It is a secondmate'"'"'s home, not a task.",
  "started": "Work on it has started; Firstmate must stop or finish it first.",
  "worker": "A worker record is still attached, so its worktree may hold unlanded work; finish it with the normal teardown.",
  "captain": "It is a question for you; answer it in Needs you instead.",
  "question": "A crew question about it is still open; answer it first.",
  "linked": "It has a recorded pull request or report; close it instead of removing it.",
  "needed": "Another open task still needs it; select that task too.",
  "changed": "It changed after the page was built; reload the page and try again.",
  "busy": "Another action on it is running; try again in a minute.",
  "backend": "Removal needs the markdown task list.",
  "suggestion-gone": "It is no longer a waiting suggestion.",
  "not-removed": "It is not in the removed list (already restored, archived, or never removed).",
  "on-list": "A task with this id is on the list again.",
  "together": "It was removed together with a task it is linked to; restore them together.",
  "failed": "The task list refused the change; nothing was moved."
}'

reason() {  # <code> [detail]
  local words
  words=$(jq -r --arg c "$1" '.[$c] // "Kept."' <<<"$REASONS_JSON")
  if [ -n "${2-}" ]; then printf '%s (%s)' "$words" "$2"; else printf '%s' "$words"; fi
}

valid_id() { [[ $1 =~ ^[A-Za-z0-9._-]{1,128}$ ]] && [[ $1 != .* ]]; }
valid_batch() { [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }

new_batch() {
  local r
  r=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  printf 'b%s-%s\n' "$NOW" "${r:-$$}"
}

# Resolve this home's markdown task list; sets AXI_ROOT and BACKLOG_FILE.
resolve_backlog() {
  FM_BACKLOG_TRANSITION_ERROR=
  if ! fm_backlog_tasks_axi_addressing "$DATA"; then
    die "${FM_BACKLOG_TRANSITION_ERROR:-the task list cannot be resolved: $DATA}"
  fi
  [ -n "$FM_BACKLOG_AXI_FILE" ] || die "$(reason backend)"
  [ ! -L "$FM_BACKLOG_AXI_FILE" ] || die "$FM_BACKLOG_AXI_FILE is a symlink; refusing to move rows through it"
  AXI_ROOT=$FM_BACKLOG_AXI_ROOT
  BACKLOG_FILE=$FM_BACKLOG_AXI_FILE
}

# Run tasks-axi against one of this owner's side files (forgotten.md or its
# archive). bin/fm-tasks-axi.sh pins every call to backlog.md, so the side
# files are addressed here, from the same root.
axi_side() {  # <file> <tasks-axi args...>
  local file=$1
  shift
  (cd "$AXI_ROOT" 2>/dev/null && TASKS_AXI_FILE="$file" tasks-axi "$@")
}

ensure_side_file() {  # <file>
  [ -e "$1" ] && return 0
  (umask 077; printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$1") || die "cannot create $1"
}

# Parse a `tasks-axi list` TOON listing on stdin into a JSON array of objects
# keyed by its header fields. Quoted cells are JSON strings; "-" and "none"
# become null; other cells hold no comma. A cell tasks-axi cut short ends in
# "..." instead of its pointer to `show --full`.
toon_rows() {
  perl -MJSON::PP -e '
    use strict; use warnings;
    my $j = JSON::PP->new->allow_nonref->canonical(1);
    my (@f, @rows);
    while (my $line = <STDIN>) {
      chomp $line;
      if ($line =~ /^tasks\[\d+\]\{([^}]*)\}:$/) { @f = split /,/, $1; next }
      next unless @f && $line =~ /^  ([^ -].*)$/;
      my $l = $1; my @c;
      while (1) {
        if ($l =~ s/^"((?:[^"\\]|\\.)*)"//) { push @c, $j->decode(qq("$1")) }
        elsif ($l =~ s/^([^,]*)//) { push @c, $1 }
        last unless $l =~ s/^,//;
      }
      next unless @c == @f;
      my %r;
      for my $i (0..$#f) {
        my $v = $c[$i];
        # tasks-axi list cuts long cells with a pointer to `show --full`.
        $v =~ s/\s*\.\.\. \(truncated, \d+ chars total - use show \S+ --full to see complete text\)\z/.../;
        $r{$f[$i]} = ($v eq "-" || $v eq "none") ? undef : $v;
      }
      push @rows, \%r;
    }
    print $j->encode(\@rows), "\n";
  '
}

# Every row of this home's task list (open and done) as JSON, each with its
# revision `rev` (first 16 hex of SHA-256 over REV_KEYS) and `blockers`.
list_backlog() {
  local out
  out=$("$SCRIPT_DIR/fm-tasks-axi.sh" list --fields "$LIST_FIELDS" 2>/dev/null) || return 1
  case "$out" in count:*|tasks*) ;; *) return 1 ;; esac
  printf '%s\n' "$out" | toon_rows | add_revs
}

list_side() {  # <file>
  local out
  [ -s "$1" ] || { printf '[]\n'; return 0; }
  out=$(axi_side "$1" list --fields "$LIST_FIELDS" 2>/dev/null) || return 1
  case "$out" in count:*|tasks*) ;; *) return 1 ;; esac
  printf '%s\n' "$out" | toon_rows | add_revs
}

add_revs() {
  REV_KEYS="$REV_KEYS" perl -MJSON::PP -MDigest::SHA=sha256_hex -e '
    use strict; use warnings;
    my $j = JSON::PP->new->canonical(1);
    local $/; my $rows = $j->decode(<STDIN>);
    my $keys = $j->decode($ENV{REV_KEYS});
    for my $r (@$rows) {
      my %sub = map { $_ => $r->{$_} } @$keys;
      $r->{rev} = substr(sha256_hex($j->encode(\%sub)), 0, 16);
      $r->{blockers} = [ grep { length } split /,/, ($r->{blocked_by} // "") ];
    }
    print $j->encode($rows), "\n";
  '
}

open_keyed_questions() {  # <id>  -> count of open keyed decisions
  local f="$STATE/$1.status" open
  [ -f "$f" ] || { printf '0\n'; return 0; }
  open=$(status_open_decisions "$f" 2>/dev/null) || open=''
  printf '%s\n' "$open" | grep -c . || true
}

# One tab-separated line per row for row_keep_code, from a JSON array of rows.
keep_fields() {  # <rows-json>
  jq -r '.[] | [.id, (.state // ""), (.kind // ""), (.hold_kind // ""), (.links // "")] | join("\u001f")' <<<"$1"
}

# The structural keep reason of one row, or nothing when removal is allowed.
# Dependents, revisions and locks are checked by the caller.
row_keep_code() {  # <id> <state> <kind> <hold-kind> <links>
  local id=$1 state=$2 kind=$3 hold_kind=$4 links=$5
  [ "$kind" != secondmate ] || { printf 'secondmate'; return; }
  [ "$state" = queued ] || { printf 'started'; return; }
  if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ] || [ -e "$STATE/$id.backlog-close" ] \
    || [ -L "$STATE/$id.backlog-close" ] || [ -e "$STATE/$id.control-relaunch" ]; then
    printf 'worker'; return
  fi
  [ "$hold_kind" != captain ] || { printf 'captain'; return; }
  case "$links" in *pr:*|*report:*) printf 'linked'; return ;; esac
  [ "$(open_keyed_questions "$id")" -eq 0 ] || { printf 'question'; return; }
}

row_keep_of() {  # <row-json>
  local f
  IFS=$'\037' read -r -a f < <(keep_fields "[$1]")
  row_keep_code "${f[0]}" "${f[1]-}" "${f[2]-}" "${f[3]-}" "${f[4]-}"
}

append_index() {  # <json-object>
  (umask 077; printf '%s\n' "$1" >> "$INDEX") || die "cannot append to $INDEX"
}

# The latest index event per id (fold of the append-only file).
index_latest() {
  [ -s "$INDEX" ] || { printf '{}\n'; return 0; }
  jq -s -c 'reduce .[] as $e ({}; if ($e | type) == "object" and ($e.id | type) == "string" then .[$e.id] = $e else . end)' "$INDEX" 2>/dev/null \
    || die "cannot parse $INDEX; refusing to act on an unreadable index"
}

HELD_LOCKS=()
release_all() {
  local i
  for ((i=${#HELD_LOCKS[@]} - 1; i >= 0; i--)); do
    fm_lock_release "${HELD_LOCKS[$i]}" >/dev/null 2>&1 || true
  done
  HELD_LOCKS=()
}
trap release_all EXIT

store_lock() {
  (umask 077; mkdir -p "$STATE") || die "cannot create $STATE"
  fm_lock_acquire_wait_max "$STORE_LOCK" 30 || die "timed out waiting for $STORE_LOCK"
  HELD_LOCKS+=("$STORE_LOCK")
}

# Try (never wait for) the task's control and meta locks, so a running spawn,
# teardown or hold change keeps the row instead of racing it.
task_locks() {  # <id>
  local control="$STATE/.control-$1.lock" meta
  meta=$(fm_meta_lock_path "$STATE/$1.meta") || return 1
  fm_lock_try_acquire "$control" || return 1
  HELD_LOCKS+=("$control")
  fm_lock_try_acquire "$meta" || return 1
  HELD_LOCKS+=("$meta")
}

# Repair a crash between cutting links and moving rows: any row the journal
# names that is still on the task list gets its cut links back.
recover_journal() {
  local id blocker
  [ -f "$JOURNAL" ] || return 0
  while IFS=$'\t' read -r id blocker; do
    [ -n "$id" ] && [ -n "$blocker" ] || continue
    if "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" >/dev/null 2>&1 \
      && "$SCRIPT_DIR/fm-tasks-axi.sh" show "$blocker" >/dev/null 2>&1; then
      "$SCRIPT_DIR/fm-tasks-axi.sh" block "$id" --by "$blocker" >/dev/null 2>&1 || true
    fi
  done < "$JOURNAL"
  rm -f -- "$JOURNAL"
}

# Move rows removed more than KEEP_DAYS ago to the archive, whole connected
# sets only, so neither file strands a link.
sweep_expired() {
  local rows latest due ids
  [ -s "$FORGOTTEN" ] || return 0
  rows=$(list_side "$FORGOTTEN") || return 0
  latest=$(index_latest)
  due=$(jq -c -n --argjson rows "$rows" --argjson ev "$latest" --argjson now "$NOW" --argjson days "$KEEP_DAYS" "$JQ_MEMBER"'
    [ $rows[] | select(($ev[.id].event // "") == "removed" and ($now - ($ev[.id].at // $now)) >= ($days * 86400)) | .id ] as $due0
    | def linked($r): [$rows[] | select(member(.blockers; $r.id) or member($r.blockers; .id)) | .id];
      def settle($set): ([$set[] as $id | select(all(linked(first($rows[] | select(.id == $id)))[]; member($set; .))) | $id]) as $next
        | if ($next | length) == ($set | length) then $set else settle($next) end;
    settle($due0)')
  [ "$due" != "[]" ] || return 0
  ensure_side_file "$ARCHIVE_MD"
  mapfile -t ids < <(jq -r '.[]' <<<"$due")
  if axi_side "$FORGOTTEN" mv "${ids[@]}" --to "$ARCHIVE_MD" >/dev/null 2>&1; then
    chmod 600 "$ARCHIVE_MD" 2>/dev/null || true
    for id in "${ids[@]}"; do
      append_index "$(jq -c -n --arg id "$id" --argjson now "$NOW" \
        '{schema:"fm-forget.v1", event:"archived", id:$id, kind:"task", at:$now, by:"fm-forget"}')"
    done
  fi
}

parse_common() {  # sets BATCH BY IDS
  BATCH='' BY=firstmate IDS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --batch) [ $# -ge 2 ] || die "--batch needs a value" 2; BATCH=$2; shift 2 ;;
      --by) [ $# -ge 2 ] || die "--by needs a value" 2; BY=$2; shift 2 ;;
      --) shift; while [ $# -gt 0 ]; do IDS+=("$1"); shift; done ;;
      -*) die "unknown flag $1" 2 ;;
      *) IDS+=("$1"); shift ;;
    esac
  done
  [ -z "$BATCH" ] || valid_batch "$BATCH" || die "--batch must be 1-64 letters, digits, dot, dash or underscore" 2
  BY=$(printf '%s' "$BY" | tr -d '\000-\037\177' | cut -c1-200)
  [ -n "$BY" ] || BY=firstmate
  [ "${#IDS[@]}" -le "$MAX_IDS" ] || die "at most $MAX_IDS ids per call" 2
}

cmd_remove() {
  parse_common "$@"
  [ "${#IDS[@]}" -gt 0 ] || die "remove: name at least one id" 2
  [ -n "$BATCH" ] || BATCH=$(new_batch)
  command -v jq >/dev/null 2>&1 || die "jq is required"
  resolve_backlog
  store_lock
  recover_journal
  sweep_expired

  local rows removed_side spec id rev row code seen=' ' kept=0 done_n=0
  local -a cand=() sugg=() out=()
  local -A why=()
  rows=$(list_backlog) || die "cannot read this home's task list; nothing was removed"
  removed_side=$(list_side "$FORGOTTEN") || removed_side='[]'
  for spec in "${IDS[@]}"; do
    id=${spec%%@*}
    rev=''
    [ "$id" = "$spec" ] || rev=${spec#*@}
    valid_id "$id" || { out+=("kept $spec: $(reason absent)"); kept=$((kept + 1)); continue; }
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    case "$id" in sg-*) sugg+=("$id"); continue ;; esac
    row=$(jq -c --arg id "$id" 'first(.[] | select(.id == $id)) // empty' <<<"$rows")
    if [ -z "$row" ]; then
      if jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$removed_side" >/dev/null; then
        why[$id]=$(reason already-removed)
      else
        why[$id]=$(reason absent)
      fi
      continue
    fi
    code=$(row_keep_of "$row")
    if [ -n "$code" ]; then why[$id]=$(reason "$code"); continue; fi
    if [ -n "$rev" ] && [ "$rev" != "$(jq -r '.rev' <<<"$row")" ]; then why[$id]=$(reason changed); continue; fi
    if ! task_locks "$id"; then why[$id]=$(reason busy); continue; fi
    cand+=("$id")
  done

  # Re-read under the locks: a row that changed between the first read and the
  # lock is judged on what it is now.
  if [ "${#cand[@]}" -gt 0 ]; then
    rows=$(list_backlog) || die "cannot re-read this home's task list; nothing was removed"
    local -a still=()
    for id in "${cand[@]}"; do
      row=$(jq -c --arg id "$id" 'first(.[] | select(.id == $id)) // empty' <<<"$rows")
      if [ -z "$row" ]; then why[$id]=$(reason absent); continue; fi
      code=$(row_keep_of "$row")
      if [ -n "$code" ]; then why[$id]=$(reason "$code"); continue; fi
      still+=("$id")
    done
    cand=("${still[@]+"${still[@]}"}")
  fi

  # Keep any candidate an open task outside the set still needs, until stable.
  local set_json settled
  set_json=$(printf '%s\n' "${cand[@]+"${cand[@]}"}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  settled=$(jq -c -n --argjson rows "$rows" --argjson set "$set_json" "$JQ_MEMBER"'
    def needers($s; $id): [$rows[] | select(.state != "done" and member(.blockers; $id) and (member($s; .id) | not)) | .title // .id];
    def settle($s): ([$s[] | select((needers($s; .) | length) == 0)]) as $n
      | if ($n | length) == ($s | length) then $s else settle($n) end;
    settle($set) as $final
    | {keep: [$set[] | select(member($final; .) | not) | {id: ., by: needers($final; .)}], move: $final}')
  while IFS=$'\t' read -r id names; do
    [ -n "$id" ] || continue
    why[$id]=$(reason needed "needed by: $names")
  done < <(jq -r '.keep[] | [.id, (.by | join("; ") | .[0:200])] | @tsv' <<<"$settled")
  mapfile -t cand < <(jq -r '.move[]' <<<"$settled")

  if [ "${#cand[@]}" -gt 0 ]; then
    # Links from a moved row to a blocker that stays are cut first, journaled
    # so a crash before the move restores them.
    local cuts
    cuts=$(jq -r -n --argjson rows "$rows" --argjson set "$(printf '%s\n' "${cand[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" "$JQ_MEMBER"'
      $rows[] | select(member($set; .id)) | .id as $i | .blockers[] | select(member($set; .) | not) | [$i, .] | @tsv')
    if [ -n "$cuts" ]; then
      (umask 077; printf '%s\n' "$cuts" > "$JOURNAL") || die "cannot write $JOURNAL; nothing was removed"
      while IFS=$'\t' read -r id blk; do
        "$SCRIPT_DIR/fm-tasks-axi.sh" unblock "$id" --by "$blk" >/dev/null 2>&1 || true
      done <<<"$cuts"
    fi
    ensure_side_file "$FORGOTTEN"
    local mv_err
    if mv_err=$("$SCRIPT_DIR/fm-tasks-axi.sh" mv "${cand[@]}" --to "$FORGOTTEN" 2>&1); then
      chmod 600 "$FORGOTTEN" 2>/dev/null || true
      rm -f -- "$JOURNAL"
      for id in "${cand[@]}"; do
        row=$(jq -c --arg id "$id" 'first(.[] | select(.id == $id))' <<<"$rows")
        append_index "$(jq -c -n --argjson r "$row" --arg batch "$BATCH" --arg by "$BY" --argjson now "$NOW" \
          --argjson cut "$(printf '%s\n' "$cuts" | awk -F'\t' -v id="$id" '$1 == id { print $2 }' | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
          '{schema:"fm-forget.v1", event:"removed", id:$r.id, kind:"task", batch:$batch, at:$now, by:$by,
            title:($r.title // $r.id), unlinked:$cut}')"
        out+=("removed $id")
        done_n=$((done_n + 1))
      done
    else
      recover_journal
      mv_err=$(printf '%s' "$mv_err" | sed -n '1s/^error: //p' | sed 's/\\"//g; s/"//g' | cut -c1-200)
      for id in "${cand[@]}"; do why[$id]=$(reason failed "$mv_err"); done
    fi
  fi

  # Suggestions: dropped to the never-deleted "not picked" archive.
  if [ "${#sugg[@]}" -gt 0 ]; then
    local line
    for id in "${sugg[@]}"; do
      if line=$("$SCRIPT_DIR/fm-suggestions.sh" drop "$id" 2>&1) && [ "${line%% *}" = dropped ]; then
        append_index "$(jq -c -n --arg id "$id" --arg batch "$BATCH" --arg by "$BY" --argjson now "$NOW" \
          --arg title "$(printf '%s' "$line" | cut -d' ' -f3-)" \
          '{schema:"fm-forget.v1", event:"removed", id:$id, kind:"suggestion", batch:$batch, at:$now, by:$by,
            title:(if $title == "" then $id else $title end), unlinked:[]}')"
        out+=("removed $id")
        done_n=$((done_n + 1))
      else
        why[$id]=$(reason suggestion-gone)
      fi
    done
  fi

  for spec in "${IDS[@]}"; do
    id=${spec%%@*}
    [ -n "${why[$id]+x}" ] || continue
    out+=("kept $id: ${why[$id]}")
    unset "why[$id]"
    kept=$((kept + 1))
  done
  release_all
  [ "${#out[@]}" -eq 0 ] || printf '%s\n' "${out[@]}"
  printf 'batch %s removed=%s kept=%s\n' "$BATCH" "$done_n" "$kept"
}

cmd_restore() {
  parse_common "$@"
  [ -n "$BATCH" ] || [ "${#IDS[@]}" -gt 0 ] || die "restore: name ids or --batch" 2
  command -v jq >/dev/null 2>&1 || die "jq is required"
  resolve_backlog
  store_lock
  recover_journal
  sweep_expired

  local latest side rows id kept=0 done_n=0 seen=' '
  local -a want=() cand=() sugg=() out=()
  local -A why=()
  latest=$(index_latest)
  side=$(list_side "$FORGOTTEN") || die "cannot read $FORGOTTEN; nothing was restored"
  rows=$(list_backlog) || die "cannot read this home's task list; nothing was restored"
  if [ "${#IDS[@]}" -gt 0 ]; then
    want=("${IDS[@]}")
  else
    mapfile -t want < <(jq -r --arg b "$BATCH" 'to_entries[] | .value | select(.event == "removed" and .batch == $b) | .id' <<<"$latest" | sort)
  fi
  for id in "${want[@]}"; do
    valid_id "$id" || { out+=("kept $id: $(reason not-removed)"); kept=$((kept + 1)); continue; }
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    if [ "$(jq -r --arg id "$id" '.[$id].kind // ""' <<<"$latest")" = suggestion ]; then
      if [ "$(jq -r --arg id "$id" '.[$id].event // ""' <<<"$latest")" = removed ]; then sugg+=("$id")
      else why[$id]=$(reason not-removed); fi
      continue
    fi
    if ! jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$side" >/dev/null; then why[$id]=$(reason not-removed); continue; fi
    if jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$rows" >/dev/null; then why[$id]=$(reason on-list); continue; fi
    if ! task_locks "$id"; then why[$id]=$(reason busy); continue; fi
    cand+=("$id")
  done

  # Rows linked inside forgotten.md move together or not at all.
  local settled
  settled=$(jq -c -n --argjson rows "$side" --argjson set "$(printf '%s\n' "${cand[@]+"${cand[@]}"}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" "$JQ_MEMBER"'
    def row($id): first($rows[] | select(.id == $id));
    def ok($s; $id): (row($id).blockers | all(.[]; member($s; .)))
      and ([$rows[] | select(.state != "done" and member(.blockers; $id))] | all(.[]; member($s; .id)));
    def settle($s): ([$s[] | select(ok($s; .))]) as $n | if ($n | length) == ($s | length) then $s else settle($n) end;
    settle($set) as $f | {keep: [$set[] | select(member($f; .) | not)], move: $f}')
  for id in $(jq -r '.keep[]' <<<"$settled"); do why[$id]=$(reason together); done
  mapfile -t cand < <(jq -r '.move[]' <<<"$settled")

  if [ "${#cand[@]}" -gt 0 ]; then
    local mv_err blk relinked
    if mv_err=$(axi_side "$FORGOTTEN" mv "${cand[@]}" --to "$BACKLOG_FILE" 2>&1); then
      rows=$(list_backlog) || rows='[]'
      for id in "${cand[@]}"; do
        relinked=()
        while IFS= read -r blk; do
          [ -n "$blk" ] || continue
          if jq -e --arg b "$blk" 'any(.[]; .id == $b)' <<<"$rows" >/dev/null \
            && "$SCRIPT_DIR/fm-tasks-axi.sh" block "$id" --by "$blk" >/dev/null 2>&1; then
            relinked+=("$blk")
          fi
        done < <(jq -r --arg id "$id" '.[$id].unlinked // [] | .[]' <<<"$latest")
        append_index "$(jq -c -n --arg id "$id" --arg batch "${BATCH:-$(jq -r --arg id "$id" '.[$id].batch // ""' <<<"$latest")}" \
          --arg by "$BY" --argjson now "$NOW" \
          --argjson rel "$(printf '%s\n' "${relinked[@]+"${relinked[@]}"}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
          '{schema:"fm-forget.v1", event:"restored", id:$id, kind:"task", batch:$batch, at:$now, by:$by, relinked:$rel}')"
        out+=("restored $id")
        done_n=$((done_n + 1))
      done
    else
      mv_err=$(printf '%s' "$mv_err" | sed -n '1s/^error: //p' | sed 's/\\"//g; s/"//g' | cut -c1-200)
      for id in "${cand[@]}"; do why[$id]=$(reason failed "$mv_err"); done
    fi
  fi

  if [ "${#sugg[@]}" -gt 0 ]; then
    for id in "${sugg[@]}"; do
      if "$SCRIPT_DIR/fm-suggestions.sh" restore "$id" >/dev/null 2>&1; then
        append_index "$(jq -c -n --arg id "$id" --arg batch "${BATCH:-$(jq -r --arg id "$id" '.[$id].batch // ""' <<<"$latest")}" \
          --arg by "$BY" --argjson now "$NOW" \
          '{schema:"fm-forget.v1", event:"restored", id:$id, kind:"suggestion", batch:$batch, at:$now, by:$by, relinked:[]}')"
        out+=("restored $id")
        done_n=$((done_n + 1))
      else
        why[$id]=$(reason not-removed)
      fi
    done
  fi

  for id in "${want[@]}"; do
    [ -n "${why[$id]+x}" ] || continue
    out+=("kept $id: ${why[$id]}")
    unset "why[$id]"
    kept=$((kept + 1))
  done
  release_all
  [ "${#out[@]}" -eq 0 ] || printf '%s\n' "${out[@]}"
  printf 'batch %s restored=%s kept=%s\n' "${BATCH:--}" "$done_n" "$kept"
}

# The removed entries still restorable, newest first, as JSON.
removed_json() {
  local latest side
  latest=$(index_latest)
  side=$(list_side "$FORGOTTEN") || return 1
  jq -c -n --argjson ev "$latest" --argjson side "$side" --argjson now "$NOW" --argjson days "$KEEP_DAYS" '
    ($side | map({key: .id, value: .}) | from_entries) as $rows
    | [ $ev[] | select(.event == "removed")
        | select(.kind == "suggestion" or $rows[.id] != null)
        | {id, kind, batch, removed_epoch: .at, by, title: (if .kind == "task" then ($rows[.id].title // .title) else .title end),
           body: (if .kind == "task" then ($rows[.id].body // null) else null end),
           expires_epoch: (.at + $days * 86400), unlinked: (.unlinked // [])} ]
    | sort_by(-.removed_epoch, .id)'
}

cmd_list() {
  local json=0 r
  case "${1-}" in --json) json=1 ;; '') ;; *) die "list: unknown argument $1" 2 ;; esac
  resolve_backlog
  r=$(removed_json) || die "cannot read $FORGOTTEN"
  if [ "$json" = 1 ]; then jq . <<<"$r"; return 0; fi
  jq -r '.[] | "\(.id) \(.batch) \(.removed_epoch | todate) \(.title)"' <<<"$r"
}

cmd_feed() {
  [ $# -eq 0 ] || die "feed: takes no arguments" 2
  local rows removed sugg keeps id row code
  resolve_backlog
  rows=$(list_backlog) || die "cannot read this home's task list"
  removed=$(removed_json) || removed='[]'
  sugg=$("$SCRIPT_DIR/fm-suggestions.sh" list --json 2>/dev/null) || sugg='null'
  keeps='{}'
  local state kind hold links
  while IFS=$'\037' read -r id state kind hold links; do
    [ -n "$id" ] || continue
    code=$(row_keep_code "$id" "$state" "$kind" "$hold" "$links")
    [ -z "$code" ] || keeps=$(jq -c --arg id "$id" --arg c "$code" '.[$id] = $c' <<<"$keeps")
  done < <(keep_fields "$(jq -c '[.[] | select(.state != "done")]' <<<"$rows")")
  jq -n --argjson rows "$rows" --argjson removed "$removed" --argjson sugg "$sugg" --argjson keeps "$keeps" \
    --argjson reasons "$REASONS_JSON" --argjson now "$NOW" --argjson days "$KEEP_DAYS" '
    {schema: "fm-forget-feed.v1", generated_epoch: $now, keep_days: $days, reasons: $reasons,
     rows: [$rows[] | . + {keep: ($keeps[.id] // null)}],
     removed: $removed,
     suggestions: $sugg}'
}

command=${1-}
[ $# -eq 0 ] || shift
case "$command" in
  remove) cmd_remove "$@" ;;
  restore) cmd_restore "$@" ;;
  list) cmd_list "$@" ;;
  feed) cmd_feed "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command $command" 2 ;;
esac
