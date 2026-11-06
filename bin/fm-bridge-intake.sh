#!/usr/bin/env bash
# fm-bridge-intake.sh - apply the Remove and Restore presses the captain queued
# on the Bridge, from one captured Lavish result, through bin/fm-forget.sh.
#
# Usage:
#   fm-bridge-intake.sh <result-file>
#   fm-bridge-intake.sh receipts [--json]
#
# <result-file> is a capture under state/procevent-inbox/, named
# `<source-id>.<seq>.result`, as the Lavish wake names it. The intake applies
# only when that source id is this home's Bridge page source
# (`fm-procevent-lavish.sh source-id`, bin/fm-bridge.sh `path`) and the source
# is bound to the keyed-answer intake (`fm-captain-hold.sh binding`), the
# check reconcile-requests makes. It reads the result's fm-bridge-action.v1
# choices (`fm-procevent-lavish.sh actions`); a result that is not fully
# accounted for applies nothing. Each choice becomes one call:
#   remove   fm-forget.sh remove --batch <batch> --by <press> <id>@<rev>...
#   restore  fm-forget.sh restore --batch <batch> --by <press> [<id>...]
# with --by naming the press (the Lavish result and sequence), never words in
# the captain's name. fm-forget.sh owns every guard; the intake adds three:
# an item for another home is kept ("belongs to <home>; that home's Firstmate
# removes it"), more than 200 items per choice refuses the choice, and
# config/bridge-actions holding `off` refuses every press with nothing applied.
#
# The choice data, as the page queues it:
#   {"schema":"fm-bridge-action.v1","action":"remove"|"restore",
#    "batch":"<1-64 of [A-Za-z0-9._-]>","items":[{"id":"<task>","rev":"<16 hex>"
#    [,"home":"<other home>"]}...]}
# A restore with an empty items list restores the whole batch.
#
# The result of each press is a receipt, state/bridge-requests/<source-id>.<seq>.receipt
# (mode 0600): one `press <action> batch=<batch> items=<n>` line, then
# fm-forget.sh's per-item lines. A result already applied prints its receipt
# again and applies nothing, so a repeated wake is harmless. The intake then
# refreshes the Bridge so the page shows the receipt. `receipts` prints the
# newest five receipts (fm-bridge-receipts.v1 with --json), which the Bridge's
# tasks feed carries.
# Exit 0 applied or already applied; 1 refused; 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REQUESTS="$STATE/bridge-requests"
MAX_ITEMS=200

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() { printf 'fm-bridge-intake: %s\n' "$1" >&2; exit "${2:-1}"; }

realpath_of() { perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null; }

cmd_receipts() {
  local json=0 f
  case "${1-}" in --json) json=1 ;; '') ;; *) die "receipts: unknown argument $1" 2 ;; esac
  local -a files=()
  if [ -d "$REQUESTS" ]; then
    while IFS=$'\t' read -r _ f; do files+=("$f"); done < <(
      for f in "$REQUESTS"/*.receipt; do
        [ -f "$f" ] || continue
        printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")" "$f"
      done | sort -rn | head -5)
  fi
  if [ "$json" = 0 ]; then
    for f in "${files[@]+"${files[@]}"}"; do cat -- "$f"; printf '\n'; done
    return 0
  fi
  {
    for f in "${files[@]+"${files[@]}"}"; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      jq -R -s -c --arg at "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")" '
        split("\n") | map(select(length > 0)) as $l
        | {at: ($at | tonumber), lines: $l[0:400]}' "$f"
    done
  } | jq -s -c '{schema: "fm-bridge-receipts.v1", receipts: .}'
}

cmd_apply() {
  local file=$1 real base sid seq page bridge_sid receipt tmp actions line
  [ -f "$file" ] && [ ! -L "$file" ] || die "not a captured result: $file"
  [ -f "$CONFIG/bridge-actions" ] && [ "$(head -n 1 "$CONFIG/bridge-actions" 2>/dev/null)" = off ] \
    && die "Bridge actions are switched off ($CONFIG/bridge-actions); nothing was applied"
  real=$(realpath_of "$file") || die "cannot resolve $file"
  [ "${real%/*}" = "$(realpath_of "$STATE/procevent-inbox" || printf '%s' -)" ] \
    || die "the result is not a capture in $STATE/procevent-inbox; nothing was applied"
  base=${real##*/}
  [[ $base =~ ^(lavish-[0-9a-f]{16})\.([0-9]+)\.result$ ]] || die "the result file name is not <source-id>.<seq>.result"
  sid=${BASH_REMATCH[1]}
  seq=${BASH_REMATCH[2]}
  page=$("$SCRIPT_DIR/fm-bridge.sh" path) || die "cannot find the Bridge page"
  [ -f "$page" ] || die "this home has no Bridge page; nothing was applied"
  bridge_sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$page" 2>/dev/null) || die "cannot name the Bridge page's source"
  [ "$sid" = "$bridge_sid" ] || die "the result came from $sid, not this home's Bridge ($bridge_sid); nothing was applied"
  "$SCRIPT_DIR/fm-captain-hold.sh" binding "$sid" >/dev/null 2>&1 \
    || die "the Bridge source $sid is not bound to the answer intake; open the Bridge with fm-bridge.sh open first"
  receipt="$REQUESTS/$sid.$seq.receipt"
  if [ -f "$receipt" ]; then
    printf 'already applied: %s\n' "$receipt"
    cat -- "$receipt"
    return 0
  fi
  actions=$("$SCRIPT_DIR/fm-procevent-lavish.sh" actions "$real" 2>/dev/null) \
    || die "the result is not fully accounted for; nothing was applied"
  (umask 077; mkdir -p "$REQUESTS") || die "cannot create $REQUESTS"
  tmp=$(umask 077; mktemp "$REQUESTS/.receipt.XXXXXX") || die "cannot stage the receipt"
  local by="the captain's Bridge press, Lavish result $sid sequence $seq"
  local n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    apply_one "$line" "$by" >> "$tmp"
  done <<<"$actions"
  [ "$n" -gt 0 ] || printf 'press none: the result carried no Remove or Restore\n' >> "$tmp"
  if ! { chmod 600 "$tmp" && mv -f -- "$tmp" "$receipt"; }; then rm -f -- "$tmp"; die "cannot write $receipt"; fi
  cat -- "$receipt"
  "$SCRIPT_DIR/fm-bridge.sh" refresh >/dev/null 2>&1 || true
}

apply_one() {  # <action-json-line> <by>
  local line=$1 by=$2 action batch count shape
  shape=$(jq -r --argjson max "$MAX_ITEMS" '
    .data as $d
    | if ($d.action | IN("remove", "restore") | not) then "bad-action"
      elif (($d.batch // "") | type != "string" or (test("^[A-Za-z0-9._-]{1,64}$") | not)) then "bad-batch"
      elif ($d.items | type) != "array" then "bad-items"
      elif ($d.items | length) > $max then "too-many"
      elif ($d.action == "remove" and ($d.items | length) == 0) then "bad-items"
      elif any($d.items[]; (type != "object") or ((.id | type) != "string") or (.id | test("^[A-Za-z0-9._-]{1,128}$") | not)
          or ((.rev // "") | type != "string" or (test("^([0-9a-f]{16})?$") | not))) then "bad-items"
      else "ok" end' <<<"$line")
  action=$(jq -r '.data.action // "?" | tostring | .[0:20]' <<<"$line")
  batch=$(jq -r '.data.batch // "?" | tostring | .[0:64]' <<<"$line")
  count=$(jq -r '.data.items | if type == "array" then length else 0 end' <<<"$line")
  if [ "$shape" != ok ]; then
    printf 'press %s refused: %s (nothing was applied for it)\n' "$action" "$shape"
    return 0
  fi
  printf 'press %s batch=%s items=%s\n' "$action" "$batch" "$count"
  jq -r '.data.items[] | select((.home // "") != "") | "kept \(.id): It belongs to \(.home | tostring | .[0:60]); that home'"'"'s Firstmate removes it."' <<<"$line"
  local -a args=()
  mapfile -t args < <(jq -r '.data.items[] | select((.home // "") == "") | .id + (if (.rev // "") != "" then "@" + .rev else "" end)' <<<"$line")
  if [ "$action" = remove ]; then
    [ "${#args[@]}" -gt 0 ] || return 0
    "$SCRIPT_DIR/fm-forget.sh" remove --batch "$batch" --by "$by" "${args[@]}" 2>&1
  else
    local -a ids=()
    local a
    for a in "${args[@]+"${args[@]}"}"; do ids+=("${a%%@*}"); done
    if [ "$count" -eq 0 ]; then
      "$SCRIPT_DIR/fm-forget.sh" restore --batch "$batch" --by "$by" 2>&1
    elif [ "${#ids[@]}" -gt 0 ]; then
      "$SCRIPT_DIR/fm-forget.sh" restore --batch "$batch" --by "$by" "${ids[@]}" 2>&1
    fi
  fi
}

case "${1-}" in
  receipts) shift; cmd_receipts "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  -*) die "unknown flag $1" 2 ;;
  *) [ $# -eq 1 ] || { usage >&2; exit 2; }; cmd_apply "$1" ;;
esac
