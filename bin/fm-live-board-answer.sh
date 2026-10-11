#!/usr/bin/env bash
# fm-live-board-answer.sh - answer on the live board what the captain asked on it.
#
# Usage:
#   fm-live-board-answer.sh record <source-id> <sequence> [--item <n>]
#                           [--source <text>] [--question <text>]
#                           [--file <path>] [--no-build]
#   fm-live-board-answer.sh gate <source-id> <sequence> [--no-answer-needed <reason>]
#   fm-live-board-answer.sh list
#   fm-live-board-answer.sh path
#
# A question the captain types on the live board is answered on the live board.
# Typed words arrive as one captured Lavish result of the board's own source
# (bin/fm-procevent.sh owns the capture, `bin/fm-procevent-lavish.sh comments`
# reads its typed items), and each item is one question, identified by
# <source-id>.<sequence>.<item>: the board's Lavish session, the result's
# number, and the item's position in that result.
#
# record   Store the answer to one typed item and rebuild the board through
#          `fm-live-board.sh build`, so the answer shows where it was asked.
#          The answer is plain text, at most 6000 bytes, read from --file or
#          standard input; it is published on the board, so it must hold no
#          secret. --source says where the answer comes from and is shown with
#          it. --item picks the item when the result carries more than one.
#          The question text is read from the capture; --question supplies it
#          when the capture is gone. Recording again replaces the answer.
#          When the installed Lavish has `reply`, the answer is also posted to
#          the board's conversation; an older Lavish is left alone.
#          Prints `recorded: <key>`. --no-build skips the rebuild and the post.
# gate     The rule `bin/fm-procevent.sh handled` enforces through the Lavish
#          adapter: exit 3, naming each item and the exact command to run, when
#          a typed item of that result has neither an answer nor a recorded
#          reason that it needs none, or when the record cannot be read; exit
#          0 otherwise.
#          --no-answer-needed records that reason for every such item first.
# list     Print the board's "Your questions and answers" data as one JSON
#          document, schema fm-live-board-questions.v1: {status, items[]},
#          each item {key, question, on, asked_at_epoch, status: answered|open,
#          answer, answered_at_epoch, source}, newest first. An item is open
#          while its result is captured and not yet handled and nothing is
#          recorded for it, so a question shows "Not answered yet" from the
#          moment it arrives until its answer does. An item recorded as
#          needing no answer is not listed. status is `unreadable` when the
#          record cannot be parsed; open items are still listed then.
# path     Print the record's path, $FM_HOME/data/live-board/answers.json.
#
# The record is {"schema":"fm-live-board-answers.v1","answers":[{key,
# source_id, sequence, item, uid, on, question, asked_at_epoch, answer,
# waived, answered_at_epoch, source}]}; answer is null on an entry that
# records a reason no answer is needed, and waived is that reason.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORD="$DATA/live-board/answers.json"
RECORD_LOCK="$STATE/.live-board-answers.lock"
ANSWER_MAX_BYTES=6000
LAVISH="$SCRIPT_DIR/fm-procevent-lavish.sh"

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-procevent-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-live-board-answer: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

result_file() { printf '%s/%s.%s.result\n' "$(fm_procevent_inbox_dir "$STATE")" "$1" "$2"; }

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# The typed items of one captured result as a JSON array; [] when it is gone.
typed_items() {  # <source-id> <sequence>
  local result
  result=$(result_file "$1" "$2")
  if [ -f "$result" ] && [ ! -L "$result" ]; then
    "$LAVISH" comments "$result" 2>/dev/null | jq -cs . 2>/dev/null && return 0
  fi
  printf '[]\n'
}

# Print the record's entries as a JSON array, or fail when it is unreadable.
record_entries() {
  [ -e "$RECORD" ] || [ -L "$RECORD" ] || { printf '[]\n'; return 0; }
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  jq -ce 'select(type == "object" and .schema == "fm-live-board-answers.v1"
    and (.answers | type == "array") and all(.answers[]; .key | type == "string")) | .answers' "$RECORD" 2>/dev/null
}

# Replace or add the entries on standard input (a JSON array), under the lock.
record_store() {
  local staged tries=0 entries
  (umask 077; mkdir -p "${RECORD%/*}" "$STATE") || fail "cannot create ${RECORD%/*}"
  until fm_lock_try_acquire "$RECORD_LOCK"; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || fail "the answers record is locked by another writer; retry"
    perl -e 'select(undef, undef, undef, 0.1)'
  done
  if ! entries=$(record_entries); then
    fm_lock_release "$RECORD_LOCK" || true
    fail "the answers record is unreadable and was left untouched: $RECORD"
  fi
  staged=$(umask 077; mktemp "${RECORD%/*}/.answers.XXXXXX") || {
    fm_lock_release "$RECORD_LOCK" || true
    fail "cannot stage the answers record"
  }
  if jq -c --argjson old "$entries" '. as $new
      | {schema:"fm-live-board-answers.v1",
         answers:([$old[] | select(.key as $k | any($new[]; .key == $k) | not)] + $new)}' > "$staged" \
    && chmod 0600 "$staged" && mv -f -- "$staged" "$RECORD"; then
    fm_lock_release "$RECORD_LOCK" || true
    return 0
  fi
  rm -f -- "$staged"
  fm_lock_release "$RECORD_LOCK" || true
  fail "cannot write the answers record: $RECORD"
}

check_identity() {  # <source-id> <sequence>
  fm_procevent_source_id_valid "${1-}" || fail "source id must be path-safe: ${1-}"
  case "${2-}" in ''|*[!0-9]*) fail "sequence must be a nonnegative integer: ${2-}" ;; esac
}

command_record() {
  local id=${1-} seq=${2-} item='' source='' question='' file='' build=1
  local items picked answer bytes asked key result board reply status=0
  check_identity "$id" "$seq"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --item) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; item=$2; shift 2 ;;
      --source) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; source=$2; shift 2 ;;
      --question) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; question=$2; shift 2 ;;
      --file) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; file=$2; shift 2 ;;
      --no-build) build=0; shift ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$item" in *[!0-9]*|0) fail "--item must be a positive integer: $item" ;; esac
  items=$(typed_items "$id" "$seq")
  if [ -z "$item" ]; then
    case "$(printf '%s' "$items" | jq 'length')" in
      0|1) item=$(printf '%s' "$items" | jq -r '.[0].item // 1') ;;
      *) fail "result $id $seq carries more than one typed item; pass --item <n>: $(printf '%s' "$items" | jq -r 'map("\(.item)=\(.text[:60] | tojson)") | join(", ")')" ;;
    esac
  fi
  picked=$(printf '%s' "$items" | jq -c --argjson item "$item" '[.[] | select(.item == $item)][0] // {}')
  [ -n "$question" ] || question=$(printf '%s' "$picked" | jq -r '.text // ""')
  case "$question" in
    *[![:space:]]*) ;;
    *) fail "item $item of result $id $seq is not something the captain typed; pass --question <text> when the capture is gone" ;;
  esac
  if [ -n "$file" ]; then
    [ -f "$file" ] || fail "answer file does not exist: $file"
    answer=$(cat -- "$file") || fail "cannot read the answer file: $file"
  else
    answer=$(cat)
  fi
  case "$answer" in *[![:space:]]*) ;; *) fail "the answer is empty" ;; esac
  bytes=$(printf '%s' "$answer" | LC_ALL=C wc -c | tr -d '[:space:]')
  [ "$bytes" -le "$ANSWER_MAX_BYTES" ] || fail "the answer is $bytes bytes; the limit is $ANSWER_MAX_BYTES"
  if printf '%s' "$answer$question$source" | LC_ALL=C tr -d '\n\t' | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "the answer, question and source must be plain text without control characters"
  fi
  result=$(result_file "$id" "$seq")
  asked=$(file_mtime "$result" || true)
  case "$asked" in ''|*[!0-9]*) asked=null ;; esac
  key="$id.$seq.$item"
  jq -cn --arg key "$key" --arg id "$id" --argjson seq "$seq" --argjson item "$item" \
    --argjson picked "$picked" --arg question "$question" --arg answer "$answer" \
    --arg source "$source" --argjson asked "$asked" --argjson now "$(date +%s)" \
    '[{key:$key,source_id:$id,sequence:$seq,item:$item,uid:($picked.uid // ""),on:($picked.on // ""),
       question:$question,asked_at_epoch:$asked,answer:$answer,waived:null,answered_at_epoch:$now,
       source:(if ($source | test("[^[:space:]]")) then $source else null end)}]' | record_store
  printf 'recorded: %s\n' "$key"
  [ "$build" -eq 1 ] || return 0
  "$SCRIPT_DIR/fm-live-board.sh" build >/dev/null \
    || printf 'fm-live-board-answer: the answer is recorded, but the board rebuild failed; the next refresh shows it\n' >&2
  board=$("$SCRIPT_DIR/fm-live-board.sh" path)
  [ -f "$board" ] || return 0
  reply=$(umask 077; mktemp "$STATE/.live-board-reply.XXXXXX") || return 0
  printf 'You asked: %s\n\n%s\n' "$question" "$answer" > "$reply"
  "$LAVISH" reply "$board" "$reply" >/dev/null 2>&1 || status=$?
  rm -f -- "$reply"
  case "$status" in
    0) printf 'posted: the board conversation\n' ;;
    3) ;;
    *) printf 'fm-live-board-answer: the answer is on the board, but posting it to the board conversation failed\n' >&2 ;;
  esac
}

command_gate() {
  local id=${1-} seq=${2-} reason='' items entries owed
  check_identity "$id" "$seq"
  case "$#" in
    2) ;;
    4) [ "$3" = --no-answer-needed ] || { usage >&2; exit 2; }
       reason=$4
       case "$reason" in *[![:space:]]*) ;; *) fail "--no-answer-needed needs a reason" ;; esac ;;
    *) usage >&2; exit 2 ;;
  esac
  items=$(typed_items "$id" "$seq")
  [ "$(printf '%s' "$items" | jq 'length')" -gt 0 ] || return 0
  if ! entries=$(record_entries); then
    printf 'not handled: the captain typed on the live board (result %s %s) and the answers record cannot be read: %s\n' "$id" "$seq" "$RECORD"
    printf 'Repair that file or move it aside, record the answers, then mark the result handled.\n'
    exit 3
  fi
  owed=$(jq -cn --argjson items "$items" --argjson entries "$entries" --arg prefix "$id.$seq." \
    '[$items[] | select(($prefix + (.item | tostring)) as $k | any($entries[]; .key == $k) | not)]')
  [ "$(printf '%s' "$owed" | jq 'length')" -gt 0 ] || return 0
  if [ -n "$reason" ]; then
    printf '%s' "$owed" | jq -c --arg id "$id" --argjson seq "$seq" --arg reason "$reason" \
      --argjson now "$(date +%s)" \
      'map({key:"\($id).\($seq).\(.item)",source_id:$id,sequence:$seq,item,uid,on,question:.text,
            asked_at_epoch:null,answer:null,waived:$reason,answered_at_epoch:$now,source:null})' | record_store
    return 0
  fi
  printf '%s' "$owed" | jq -r --arg id "$id" --arg seq "$seq" '
    "not handled: the captain typed on the live board and \(length) item\(if length == 1 then " has" else "s have" end) no answer on the board yet (result \($id) \($seq)).",
    (.[] | "  item \(.item): \(.text | gsub("\\s+"; " ") | .[:160])"),
    "Answer each one where it was asked, then mark the result handled:",
    (.[] | "  bin/fm-live-board-answer.sh record \($id) \($seq) --item \(.item) --source \"<where the answer comes from>\" --file <answer.txt>"),
    "Or, when nothing in this result asks for an answer, say why:",
    "  bin/fm-procevent.sh handled \($id) \($seq) --no-answer-needed \"<reason>\""'
  exit 3
}

command_list() {
  local entries status=ok board id='' result seq rows open asked
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  entries=$(record_entries) || { entries='[]'; status=unreadable; }
  board=$("$SCRIPT_DIR/fm-live-board.sh" path 2>/dev/null) || board=''
  if [ -n "$board" ] && [ -f "$board" ]; then id=$("$LAVISH" source-id "$board" 2>/dev/null) || id=''; fi
  open='[]'
  if [ -n "$id" ]; then
    rows=$(fm_procevent_pending "$STATE" | while IFS= read -r result; do
      case "${result##*/}" in "$id".*.result) ;; *) continue ;; esac
      seq=${result%.result}; seq=${seq##*.}
      asked=$(file_mtime "$result" || true)
      case "$asked" in ''|*[!0-9]*) asked=null ;; esac
      typed_items "$id" "$seq" | jq -c --arg id "$id" --argjson seq "$seq" --argjson asked "$asked" \
        '.[] | {key:"\($id).\($seq).\(.item)",sequence:$seq,item,on,question:.text,asked_at_epoch:$asked}'
    done)
    open=$(printf '%s\n' "$rows" | jq -cs .)
  fi
  jq -cn --arg status "$status" --argjson entries "$entries" --argjson open "$open" '
    {schema:"fm-live-board-questions.v1",status:$status,
     items:([$entries[] | select(.answer != null)
         | {key,sequence,item,question,on,asked_at_epoch,status:"answered",answer,answered_at_epoch,source}]
       + [$open[] | select(.key as $k | any($entries[]; .key == $k) | not)
         | {key,sequence,item,question,on,asked_at_epoch,status:"open",answer:null,answered_at_epoch:null,source:null}]
       | sort_by([-(.asked_at_epoch // .answered_at_epoch // 0),-(.sequence // 0),(.item // 0)])
       | map(del(.sequence,.item)))}'
}

case "${1-}" in
  record) shift; command_record "$@" ;;
  gate) shift; command_gate "$@" ;;
  list) shift; command_list "$@" ;;
  path) printf '%s\n' "$RECORD" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
