#!/usr/bin/env bash
# fm-bridge.sh - build, refresh, open and export this home's Bridge: one
# captain-facing page of every open question, read from durable records with
# zero model calls.
#
# Usage:
#   fm-bridge.sh build
#   fm-bridge.sh refresh
#   fm-bridge.sh open
#   fm-bridge.sh path
#   fm-bridge.sh export
#   fm-bridge.sh digest
#   fm-bridge.sh route <ask-id>
#
# build    Collect every source (SOURCES), project the cards
#          (bin/fm-bridge-asks.jq owns wording and order), and atomically
#          publish the page, this home's export and the agent digest. Prints
#          `bridge: <page>`. Starts no session and arms nothing. A build that
#          cannot finish leaves the previous files intact and exits nonzero.
# refresh  The periodic entry point bin/fm-watch.sh calls on every poll; also
#          safe to call by hand or from session start. With the Bridge enabled
#          (CONFIG) it runs one bounded build (FM_BRIDGE_TIMEOUT seconds,
#          default 60) under a home-local try-lock when an input changed, when
#          the last full read is FULL_EVERY (300) seconds old, or when nothing
#          was built yet; otherwise, once the page is refresh_seconds old, it
#          republishes the last feed with a new checked time. With nothing due
#          it changes nothing. The input check is one builtin `-nt` pass over
#          the status logs, task records, task list, name map and each
#          secondmate export, so an idle poll forks nothing. Failures go to the
#          bounded state/bridge/refresh.log and health.json and never change
#          the exit status, so the watcher cannot be slowed or failed by it.
# open     Require an enabled config, build, then serve the page through
#          bin/fm-lavish-board-lib.sh, which proves the Lavish session live
#          before binding the source to the keyed-answer intake and arming it.
#          The browser opens unless the caller set LAVISH_AXI_NO_OPEN=1.
# path     Print the page path, $FM_HOME/data/bridge/bridge.html.
# export   Collect and write only this home's export and digest, no page, and
#          print the export path. A parent home reads this file (EXPORT).
# digest   Print the agent digest (DIGEST), adding a `bridge-warning` line when
#          the file is missing, truncated or older than three refresh periods.
# route    Print where an answer to <ask-id> goes (ANSWERS); exit 3 when that
#          question is no longer open on the current Bridge, so a stale press is
#          never relayed.
#
# CONFIG. The Bridge is off unless config/bridge.json is a regular file holding
# exactly {"schema":"fm-bridge-config.v1","enabled":true} with an optional
# integer "refresh_seconds" from 15 to 3600 (default 60). Unknown keys, wrong
# types or a symlink refuse. Deleting the file switches the Bridge off.
# config/bridge-names.json is an optional home-private map from a secondmate's
# registry id to the name the captain uses for it:
#   {"schema":"fm-bridge-names.v1","names":{"<registry-id>":"<name>"}}
# Names are 1-40 printable characters. Every rendered string, including worker
# free text, has each local secondmate's registry id replaced by its name, or
# by "a secondmate" when the map has none, so a registry id never reaches the
# page or the digest. FM_BRIDGE_NAMES_FILE overrides the map's path.
#
# SOURCES, each reported with its own read state (ok, failed, stale, absent or
# remote) on the page, in the feed and in the digest:
#   task list      captain holds from this home's backlog, read through the
#                  canonical parser (`fm-fleet-snapshot.sh --contribution-input`),
#                  with question context validated by fm-captain-hold.sh.
#   status logs    every keyed needs-decision or blocked line still open in
#                  state/*.status, folded by status_open_decisions_incremental
#                  (bin/fm-classify-lib.sh) with its cursors kept in
#                  state/bridge/cursors, never beside a status file. A log that
#                  is missing, unreadable or a symlink, or whose fold did not
#                  reach the size read before it, marks this source failed or
#                  stale and is named; it is never shown as "no questions".
#   <name> export  each local secondmate's state/bridge/asks.json (EXPORT). The
#                  Bridge never opens another home's status logs.
# A source that is not ok turns the headline from a count into "at least N"
# with the unread sources named in red, and the digest says complete=no.
#
# CARDS. Needs you holds every open captain hold here and each secondmate's
# exported captain holds. Waiting on Firstmate holds keyed questions from this
# home's workers, which are addressed to Firstmate first; the captain may still
# answer them. A secondmate row's `captain-hold-<id>` key mirrors a hold in that
# secondmate's home: with its export read, the mirror folds into the exported
# card, or, when the export no longer shows that hold, is listed as probably
# settled; without its export the mirrors are listed together as relayed.
# Waiting on <name> holds a secondmate's own keyed questions from its export.
# Each card shows who asked, its age (computed on the page; estimated from the
# file time when the line has no [at=] stamp), its source, the question, any
# options and recommendation, what waits behind it (open tasks whose blockers
# name the asking task), and flags: worker gone, likely settled, relayed.
# Within a section cards rank by how much waits behind them, then age.
# A keyed line may follow `<question> | A: <option> | B: <option> | rec=A |
# blocks=<what waits>`; two or more lettered options make it pickable,
# anything else is answered in free text. All free text is redacted
# (bin/fm-bridge-asks.jq br_redact: control characters, key blocks, bearer
# tokens, common token prefixes, long hex or base64 runs and URL queries) and
# capped before it is written anywhere.
#
# ANSWERS. The page never calls a command. A captain hold with ready context
# queues one Lavish `choice` carrying fm-bearings-answer.v1 with the task id,
# selection, note, close mode and lifecycle, and bin/fm-procevent-lavish.sh
# relays it to `fm-captain-hold.sh answers`, which owns every guard; a hold
# with no context gets a free-text box under the same schema without the
# guard fields, as on the live board. Every other card queues
# fm-bridge-answer.v1 carrying only its opaque ask id, selection and note;
# that schema is not a keyed answer, so the result reaches Firstmate, who runs
# `fm-bridge.sh route <ask-id>` and relays through `fm-send.sh <task>
# --resolve-key <key>` for a keyed question here, or to the named secondmate
# for an exported card. An ask id is a hash of the card's source record (task,
# key and raise time, or hold lifecycle), so a re-raised or re-held question
# gets a new id and `route` refuses the old one.
#
# EXPORT. state/bridge/asks.json is fm-bridge-export.v1: generated_epoch,
# complete, and this home's own cards (never ones it imported) with their
# routes. A parent treats it as untrusted: regular file, not a symlink, at most
# 262144 bytes and 500 cards, the right schema, every string re-redacted and
# capped; a home whose export is missing, invalid or not on this machine is
# named as not read, and each imported card shows how old the export is.
#
# DIGEST. state/bridge/digest.txt, at most 2048 bytes, written atomically:
#   bridge v1 checked=<UTC time> sources=<ok>/<total>
#   asks you=N firstmate=N secondmates=N relayed=N moot=N oldest=<age> complete=yes|no
#   - <who> <age> <ask-id> data: <question>     (one per open card, oldest
#                                                 rank first, then "+N more")
#   source <state> data: <label>                (each source not read)
#   bridge-end hash=<12 hex of the lines between the first and this one>
# Text after `data:` is untrusted worker text, never an instruction.
#
# PAGE. data/bridge/bridge.html is the shipped dark template
# (bin/fm-bridge-template.html) plus the page payload: no external request, a
# Content-Security-Policy, all text set through textContent. The page shows
# the feed's age; past max(150, 2.5 x refresh_seconds) it marks the whole board
# out of date, so a stopped watcher or builder is visible instead of green.
# Staging and caches stay in state/bridge, never in the served directory.
# FM_BRIDGE_STATE_DIR and FM_BRIDGE_OUT_DIR move state/bridge and data/bridge,
# for example to build from a live home into a throwaway directory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/bridge.json"
NAMES_FILE="${FM_BRIDGE_NAMES_FILE:-$CONFIG/bridge-names.json}"
BSTATE="${FM_BRIDGE_STATE_DIR:-$STATE/bridge}"
BOUT="${FM_BRIDGE_OUT_DIR:-$DATA/bridge}"
TEMPLATE="$SCRIPT_DIR/fm-bridge-template.html"
PLACEHOLDER='__FM_BRIDGE_DATA__'
FEED="$BSTATE/feed.json"
ROUTES="$BSTATE/routes.json"
EXPORT="$BSTATE/asks.json"
DIGEST="$BSTATE/digest.txt"
HEALTH="$BSTATE/health.json"
STAMP="$BSTATE/.inputs-stamp"
LOCK="$BSTATE/.build.lock"
LOG="$BSTATE/refresh.log"
LOG_MAX_BYTES=65536
CURSORS="$BSTATE/cursors"
TMPD="$BSTATE/tmp"
BUILD_TIMEOUT=${FM_BRIDGE_TIMEOUT:-60}
FULL_EVERY=300
EXPORT_MAX_BYTES=262144
EXPORT_MAX_ASKS=500
EXPORT_STALE_SECONDS=900
DIGEST_MAX_BYTES=2048

case "$BUILD_TIMEOUT" in ''|*[!0-9]*|0) BUILD_TIMEOUT=60 ;; esac

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-bridge: %s\n' "$*" >&2
  exit 1
}

page_path() { printf '%s/bridge.html\n' "$BOUT"; }

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

file_age() {  # <path>
  local m
  m=$(mtime_of "$1") || return 1
  [ -n "$m" ] || return 1
  printf '%s\n' "$(( $(date +%s) - m ))"
}

# Print the refresh interval, or fail naming why the Bridge is off.
config_refresh_seconds() {
  [ -e "$CONFIG_FILE" ] || { echo "the Bridge is off: $CONFIG_FILE does not exist" >&2; return 1; }
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] \
    || { echo "Bridge config is not a regular file: $CONFIG_FILE" >&2; return 1; }
  local value
  value=$(jq -er '
    if type == "object" and .schema == "fm-bridge-config.v1"
      and ((keys - ["schema","enabled","refresh_seconds"]) | length == 0)
      and (.enabled | type == "boolean")
      and ((has("refresh_seconds") | not)
        or (.refresh_seconds | type == "number" and . == floor and . >= 15 and . <= 3600))
    then (if .enabled then (.refresh_seconds // 60) else "disabled" end)
    else "invalid" end' "$CONFIG_FILE" 2>/dev/null) || value=invalid
  case "$value" in
    disabled) echo "the Bridge is off: $CONFIG_FILE sets enabled to false" >&2; return 1 ;;
    ''|*[!0-9]*) echo "Bridge config is invalid (expected fm-bridge-config.v1): $CONFIG_FILE" >&2; return 1 ;;
  esac
  printf '%s\n' "$value"
}

ensure_dirs() {
  (umask 077; mkdir -p "$BSTATE" "$CURSORS" "$TMPD") || fail "cannot create $BSTATE"
  # Sweep staging an interrupted build left behind; it is never served.
  find "$TMPD" -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf -- {} + 2>/dev/null || true
}

atomic_write() {  # <destination> <source-file> [mode]
  local dest=$1 src=$2 mode=${3:-0600} tmp
  tmp=$(umask 077; mktemp "$TMPD/.publish.XXXXXX") || return 1
  if ! { cat -- "$src" > "$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

log_line() {  # <message>
  local size
  (umask 077; mkdir -p "$BSTATE") 2>/dev/null || return 0
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || return 0
  size=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f -- "$LOG.tmp" "$LOG" 2>/dev/null
    rm -f -- "$LOG.tmp" 2>/dev/null || true
  fi
}

# --- collection ------------------------------------------------------------

meta_field() {  # <meta-file> <field>
  local line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#"$2="} ;; esac
  done < "$1"
  printf '%s' "$value"
}

source_line() {  # <file> <label> <read> [detail]
  jq -cn --arg l "$2" --arg read "$3" --arg detail "${4-}" \
    '{label:$l, read:$read, detail:(if $detail == "" then null else $detail end)}' >> "$1"
}

collect_names() {  # <work-dir>
  local w=$1 size
  printf '{}\n' > "$w/names.json"
  [ -e "$NAMES_FILE" ] || [ -L "$NAMES_FILE" ] || return 0
  if [ -f "$NAMES_FILE" ] && [ ! -L "$NAMES_FILE" ]; then
    size=$(wc -c < "$NAMES_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) size=99999 ;; esac
    if [ "$size" -le 16384 ] && jq -e '
        type == "object" and .schema == "fm-bridge-names.v1" and ((keys - ["schema","names"]) | length == 0)
        and (.names | type == "object")
        and all(.names | to_entries[]; (.key | test("^[A-Za-z0-9._-]{1,128}$"))
          and (.value | type == "string" and test("^[[:print:]]{1,40}$")))' "$NAMES_FILE" >/dev/null 2>&1; then
      jq -c '.names' "$NAMES_FILE" > "$w/names.json"
      return 0
    fi
  fi
  printf '%s\n' "The secondmate name map is unreadable or invalid, so secondmates show as \"a secondmate\"." >> "$w/notes.txt"
}

collect_metas() {  # <work-dir>
  local w=$1 f id kind home
  : > "$w/secondmates.jsonl"
  : > "$w/metas.txt"
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || continue
    id=${f##*/}; id=${id%.meta}
    printf '%s\n' "$id" >> "$w/metas.txt"
    kind=$(meta_field "$f" kind)
    [ "$kind" = secondmate ] || continue
    home=$(meta_field "$f" home)
    jq -cn --arg id "$id" --arg home "$home" '{id:$id, home:$home}' >> "$w/secondmates.jsonl"
  done
}

# Fold every local status log into keyed rows. Cursors live under
# state/bridge/cursors; a log the fold did not fully read is reported.
collect_keyed() {  # <work-dir>
  local w=$1 f task exclude size cursor offset failed='' stale='' total=0 read_ok=0
  local key verb epoch note at_source has_meta mtime rows
  : > "$w/keyed.tsv"
  # shellcheck source=bin/fm-classify-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  exclude=$(status_scan_parent_channel_exclude "$STATE" 2>/dev/null) || exclude=''
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    task=${f##*/}; task=${task%.status}
    total=$((total + 1))
    if [ ! -f "$f" ] || [ -L "$f" ] || [ ! -r "$f" ]; then
      failed="$failed $task"
      continue
    fi
    size=$(LC_ALL=C stat -c %s "$f" 2>/dev/null || LC_ALL=C stat -f %z "$f" 2>/dev/null) || size=''
    case "$size" in ''|*[!0-9]*) failed="$failed $task"; continue ;; esac
    has_meta=false
    grep -qxF -- "$task" "$w/metas.txt" 2>/dev/null && has_meta=true
    mtime=$(mtime_of "$f") || mtime=''
    rows=$(FM_OPEN_DECISIONS_CURSOR_DIR="$CURSORS" status_open_decisions_incremental "$f" "$size" timed 2>/dev/null) \
      || { failed="$failed $task"; continue; }
    # The fold answers from its last trusted set when its own read fails, so
    # prove it reached the size captured above before trusting the rows.
    cursor="$CURSORS/.${task}.open-decisions-cursor.timed"
    offset=$(sed -n 's/^offset=//p' "$cursor" 2>/dev/null | head -1)
    if [ "$size" -gt 0 ] && [ "$offset" != "$size" ]; then
      stale="$stale $task"
    else
      read_ok=$((read_ok + 1))
    fi
    while IFS=$'\t' read -r key verb epoch note; do
      [ -n "$key" ] || continue
      at_source=stamp
      case "$epoch" in ''|*[!0-9]*) epoch=$mtime; at_source=mtime ;; esac
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$task" "$key" "$verb" "$epoch" "$at_source" "$has_meta" "$note" >> "$w/keyed.tsv"
    done <<EOF
$rows
EOF
  done
  if [ -n "$failed" ]; then
    source_line "$w/sources.jsonl" "status logs" failed "$read_ok of $total read; unreadable:$failed${stale:+; not fully read:$stale}"
  elif [ -n "$stale" ]; then
    source_line "$w/sources.jsonl" "status logs" stale "$read_ok of $total read; not fully read, shown from the last good read:$stale"
  else
    source_line "$w/sources.jsonl" "status logs" ok "$total read"
  fi
  jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
    | {task:.[0], key:.[1], verb:.[2], at:(.[3] | tonumber? // null), at_source:.[4],
       has_meta:(.[5] == "true"), note:(.[6:] | join("\t"))}]' "$w/keyed.tsv" > "$w/keyed.json"
}

collect_backlog() {  # <work-dir>
  local w=$1 backlog="$DATA/backlog.md" cache="$BSTATE/backlog.json" age
  if [ -f "$cache" ] && [ ! -L "$cache" ] && age=$(file_age "$cache") && [ "$age" -lt "$FULL_EVERY" ] \
    && { [ ! -e "$backlog" ] || [ ! "$backlog" -nt "$cache" ]; } \
    && jq -e 'type == "array"' "$cache" >/dev/null 2>&1; then
    cp -- "$cache" "$w/backlog.json"
    source_line "$w/sources.jsonl" "task list" ok "unchanged since the last read"
    return 0
  fi
  if fm_run_timed 30 env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input \
      > "$w/contribution.json" 2>/dev/null \
    && jq -c '[.backlog.records[]? | select(.structured == true and .state != "done")
        | {id, title, state, priority, hold_kind, hold_reason, hold_until, hold_set, hold_bucket, since,
           unresolved_blocker_ids, question_context}]' "$w/contribution.json" > "$w/backlog.json" 2>/dev/null; then
    if ! { cp -- "$w/backlog.json" "$cache.tmp.$$" && mv -f -- "$cache.tmp.$$" "$cache"; }; then
      rm -f -- "$cache.tmp.$$"
    fi
    source_line "$w/sources.jsonl" "task list" ok
  else
    printf '[]\n' > "$w/backlog.json"
    source_line "$w/sources.jsonl" "task list" failed "the task list could not be read, so captain questions are not shown"
  fi
}

collect_exports() {  # <work-dir>
  local w=$1 id home file size label now
  now=$(date +%s)
  printf '[]\n' > "$w/exports.json"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(printf '%s' "$line" | jq -r '.id')
    home=$(printf '%s' "$line" | jq -r '.home')
    label="$id export"
    file="$home/state/bridge/asks.json"
    if [ -z "$home" ] || [ ! -d "$home" ]; then
      source_line "$w/sources.jsonl" "$label" remote "its home is not on this machine, so its own questions are not shown"
      jq -c --arg id "$id" '. + [{id:$id, status:"remote"}]' "$w/exports.json" > "$w/e.tmp" && mv -f "$w/e.tmp" "$w/exports.json"
      continue
    fi
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      source_line "$w/sources.jsonl" "$label" absent "it has not published a Bridge export, so its own questions are not shown"
      jq -c --arg id "$id" '. + [{id:$id, status:"absent"}]' "$w/exports.json" > "$w/e.tmp" && mv -f "$w/e.tmp" "$w/exports.json"
      continue
    fi
    size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]') || size=''
    case "$size" in ''|*[!0-9]*) size=$((EXPORT_MAX_BYTES + 1)) ;; esac
    if [ ! -f "$file" ] || [ -L "$file" ] || [ "$size" -gt "$EXPORT_MAX_BYTES" ] \
      || ! jq -e --argjson max "$EXPORT_MAX_ASKS" '
          type == "object" and .schema == "fm-bridge-export.v1"
          and (.generated_epoch | type == "number") and (.asks | type == "array") and (.asks | length) <= $max
          and all(.asks[]; type == "object" and (.route | type == "object")
            and (.question | type == "string") and (.who | type == "string"))' "$file" >/dev/null 2>&1; then
      source_line "$w/sources.jsonl" "$label" failed "its export is not a valid Bridge export, so its own questions are not shown"
      jq -c --arg id "$id" '. + [{id:$id, status:"invalid"}]' "$w/exports.json" > "$w/e.tmp" && mv -f "$w/e.tmp" "$w/exports.json"
      continue
    fi
    jq -c --arg id "$id" --slurpfile doc "$file" '. + [{id:$id, status:"ok", doc:$doc[0]}]' "$w/exports.json" > "$w/e.tmp" \
      && mv -f "$w/e.tmp" "$w/exports.json"
    if jq -e --argjson now "$now" --argjson stale "$EXPORT_STALE_SECONDS" \
        '(.generated_epoch + $stale) < $now or .complete != true' "$file" >/dev/null 2>&1; then
      source_line "$w/sources.jsonl" "$label" stale "its export is old or incomplete; its cards show their age"
    else
      source_line "$w/sources.jsonl" "$label" ok
    fi
  done < "$w/secondmates.jsonl"
}

collect_watcher() {  # <work-dir>
  local w=$1
  # shellcheck source=bin/fm-supervision-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  fm_supervision_status "$STATE" >/dev/null 2>&1 || true
  jq -cn --arg fresh "${FM_SUP_WATCHER_FRESH:-false}" --arg desc "${FM_SUP_BEACON_DESC:-never}" \
    '{fresh:($fresh == "true"), beacon:$desc}' > "$w/watcher.json"
}

# Run every collector and project the feed into <work-dir>/feed.json, with each
# card's ask id assigned and its route written to <work-dir>/routes.json.
collect_feed() {  # <work-dir> <refresh-seconds>
  local w=$1 refresh=$2 away=false
  : > "$w/sources.jsonl"
  : > "$w/notes.txt"
  collect_names "$w"
  collect_metas "$w"
  collect_backlog "$w"
  collect_keyed "$w"
  collect_exports "$w"
  collect_watcher "$w"
  { [ -e "$STATE/.afk-contract" ] || [ -e "$STATE/.afk" ]; } && away=true
  jq -n -L "$SCRIPT_DIR" \
    --argjson now "$(date +%s)" --argjson refresh "$refresh" --argjson away "$away" \
    --slurpfile names "$w/names.json" --slurpfile backlog "$w/backlog.json" \
    --slurpfile keyed "$w/keyed.json" --slurpfile exports "$w/exports.json" \
    --slurpfile watcher "$w/watcher.json" \
    --rawfile sources "$w/sources.jsonl" --rawfile sms "$w/secondmates.jsonl" --rawfile notes "$w/notes.txt" '
    include "fm-bridge-asks";
    {now:$now, refresh_seconds:$refresh, away:$away, names:$names[0], backlog:$backlog[0],
     keyed:$keyed[0], exports:$exports[0], watcher:$watcher[0],
     sources:[$sources | split("\n")[] | select(length > 0) | fromjson],
     secondmates:[$sms | split("\n")[] | select(length > 0) | fromjson],
     notes:[$notes | split("\n")[] | select(length > 0)]} | br_feed' > "$w/feed0.json" \
    || return 1
  perl -MJSON::PP -MDigest::SHA=sha256_hex -e '
    use strict; use warnings;
    my ($in, $feed_out, $routes_out) = @ARGV;
    local $/; open my $fh, "<", $in or die; my $feed = decode_json(<$fh>); close $fh;
    my $json = JSON::PP->new->utf8->canonical(1);
    my %routes;
    for my $ask (@{$feed->{asks}}) {
      my $id = "q" . substr(sha256_hex($json->encode($ask->{route})), 0, 16);
      $ask->{ask} = $id;
      $routes{$id} = $ask->{route};
    }
    open my $f, ">", $feed_out or die; print $f $json->encode($feed); close $f or die;
    open my $r, ">", $routes_out or die; print $r $json->encode(\%routes); close $r or die;
  ' "$w/feed0.json" "$w/feed.json" "$w/routes.json"
}

# --- publication -----------------------------------------------------------

write_digest() {  # <work-dir> <feed>
  local w=$1 feed=$2 header body='' line count=0 more=0 budget hash end
  header=$(jq -r '"bridge v1 checked=\(.checked_epoch // .generated_epoch | todate) sources=\(.sources.ok)/\(.sources.total)"' "$feed") || return 1
  budget=$((DIGEST_MAX_BYTES - ${#header} - 1 - 40 - 16))
  while IFS= read -r line; do
    if [ "$(( ${#body} + ${#line} + 1 ))" -le "$budget" ]; then
      body="$body$line"$'\n'
      count=$((count + 1))
    else
      more=$((more + 1))
    fi
  done < <(jq -r -L "$SCRIPT_DIR" 'include "fm-bridge-asks"; br_digest_lines[]' "$feed")
  [ "$more" -eq 0 ] || body="$body+$more more"$'\n'
  hash=$(printf '%s' "$body" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)
  end="bridge-end hash=$hash"
  printf '%s\n%s%s\n' "$header" "$body" "$end" > "$w/digest.txt" || return 1
  atomic_write "$DIGEST" "$w/digest.txt"
}

publish_page() {  # <work-dir> <feed>
  local w=$1 feed=$2 page json extracted
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "page template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] || fail "page template does not carry exactly one data slot"
  page=$(page_path)
  (umask 077; mkdir -p "$BOUT") || fail "cannot create $BOUT"
  json=$(jq -c -L "$SCRIPT_DIR" 'include "fm-bridge-asks"; br_page' "$feed") || fail "cannot project the page payload"
  # `<` never appears in JSON syntax outside strings, so escaping it keeps the
  # payload valid JSON while making </script> inert.
  json=${json//</\\u003c}
  printf '%s' "$json" > "$w/payload.json" || fail "cannot stage the page payload"
  BRIDGE_DATA="$w/payload.json" perl -pe "BEGIN { local \$/; open my \$f, '<', \$ENV{BRIDGE_DATA} or die; \$data = <\$f>; close \$f }
    s/^\\Q$PLACEHOLDER\\E\$/\$data/" "$TEMPLATE" > "$w/page.html" || fail "cannot inject the page payload"
  grep -qxF "$PLACEHOLDER" "$w/page.html" && fail "the page data slot survived injection"
  extracted=$(sed -n '/<script id="bridge-data" type="application\/json">/,/<\/script>/p' "$w/page.html" | sed '1d;$d')
  printf '%s\n' "$extracted" | jq -e '.schema == "fm-bridge-asks.v1"' >/dev/null 2>&1 \
    || fail "the built page does not carry a readable fm-bridge-asks.v1 payload"
  atomic_write "$page" "$w/page.html" || fail "cannot publish the page"
}

acquire_lock() {  # <wait-seconds>
  local waited=0
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  while ! fm_lock_try_acquire "$LOCK"; do
    [ "$waited" -lt "$1" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
}

# Build: collect, then publish the page (unless page=0), export and digest.
run_build() {  # <publish-page:0|1> <lock-wait-seconds>
  local publish=$1 refresh w stamp_next
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  refresh=$(config_refresh_seconds 2>/dev/null) || refresh=60
  ensure_dirs
  acquire_lock "$2" || fail "another Bridge build is running"
  w=$(umask 077; mktemp -d "$TMPD/build.XXXXXX") || { fm_lock_release "$LOCK" || true; fail "cannot stage the build"; }
  # shellcheck disable=SC2064 # Expand the staging path now; it is fixed.
  trap "rm -rf -- '$w'; fm_lock_release '$LOCK' >/dev/null 2>&1 || true" EXIT
  # The stamp keeps the build's start time, so an input that changes while
  # this build collects is newer than it and triggers the next pass.
  stamp_next="$w/stamp"
  input_signature > "$stamp_next" 2>/dev/null || : > "$stamp_next"
  collect_feed "$w" "$refresh" || fail "the Bridge feed could not be projected; the previous files are unchanged"
  jq --argjson now "$(date +%s)" '.checked_epoch = $now' "$w/feed.json" > "$w/feed1.json" && mv -f "$w/feed1.json" "$w/feed.json"
  [ "$publish" = 0 ] || publish_page "$w" "$w/feed.json"
  { jq -L "$SCRIPT_DIR" 'include "fm-bridge-asks"; br_export' "$w/feed.json" > "$w/export.json" \
    && atomic_write "$EXPORT" "$w/export.json"; } || fail "cannot publish the export"
  { atomic_write "$FEED" "$w/feed.json" && atomic_write "$ROUTES" "$w/routes.json"; } || fail "cannot keep the feed"
  write_digest "$w" "$FEED" || fail "cannot write the digest"
  mv -f -- "$stamp_next" "$STAMP" 2>/dev/null || true
  rm -rf -- "$w"
  fm_lock_release "$LOCK" >/dev/null 2>&1 || true
  trap - EXIT
}

# Republish the last feed with a new checked time, without collecting again.
republish() {
  local w
  [ -f "$FEED" ] && [ ! -L "$FEED" ] || return 1
  w=$(umask 077; mktemp -d "$TMPD/republish.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -rf -- '$w'" EXIT
  jq --argjson now "$(date +%s)" '.checked_epoch = $now' "$FEED" > "$w/feed.json" || return 1
  publish_page "$w" "$w/feed.json"
  atomic_write "$FEED" "$w/feed.json" || return 1
  write_digest "$w" "$FEED" || return 1
  rm -rf -- "$w"
  trap - EXIT
}

# The input set as one line: a count of inputs, so a removed file also counts
# as a change. Builtins only.
input_signature() {
  local n=0 f line
  for f in "$STATE"/*.status "$STATE"/*.meta; do [ -e "$f" ] && n=$((n + 1)); done
  [ -e "$STATE/.afk-contract" ] && n=$((n + 1000))
  [ -e "$STATE/.afk" ] && n=$((n + 2000))
  printf 'inputs=%s\n' "$n"
  if [ -f "$BSTATE/secondmate-homes" ]; then
    while IFS= read -r line; do printf 'home=%s\n' "$line"; done < "$BSTATE/secondmate-homes"
  fi
}

# 0 when any input is newer than the last full build's stamp or the input set
# changed. One builtin pass; no forks.
inputs_dirty() {
  local f home
  [ -f "$STAMP" ] || return 0
  [ "$(input_signature)" = "$(cat "$STAMP" 2>/dev/null)" ] || return 0
  for f in "$STATE"/*.status "$STATE"/*.meta "$DATA/backlog.md" "$NAMES_FILE" "$CONFIG_FILE"; do
    [ "$f" -nt "$STAMP" ] && return 0
  done
  if [ -f "$BSTATE/secondmate-homes" ]; then
    while IFS= read -r home; do
      [ "$home/state/bridge/asks.json" -nt "$STAMP" ] && return 0
    done < "$BSTATE/secondmate-homes"
  fi
  return 1
}

remember_secondmate_homes() {
  local f out=''
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    [ "$(meta_field "$f" kind)" = secondmate ] || continue
    out="$out$(meta_field "$f" home)"$'\n'
  done
  printf '%s' "$out" > "$BSTATE/secondmate-homes.tmp" && mv -f "$BSTATE/secondmate-homes.tmp" "$BSTATE/secondmate-homes"
}

write_health() {  # <result> <started-epoch> [error]
  local now last_ok
  now=$(date +%s)
  last_ok=$(jq -r '.last_ok_epoch // empty' "$HEALTH" 2>/dev/null || true)
  [ "$1" = ok ] && last_ok=$now
  jq -cn --arg result "$1" --argjson now "$now" --argjson started "$2" --arg error "${3-}" \
    --arg last_ok "${last_ok:-}" '{schema:"fm-bridge-health.v1", checked_epoch:$now, result:$result,
      duration_seconds:($now - $started), last_ok_epoch:($last_ok | tonumber? // null),
      error:(if $error == "" then null else $error end)}' > "$HEALTH.tmp" 2>/dev/null \
    && mv -f "$HEALTH.tmp" "$HEALTH" 2>/dev/null || true
}

command_refresh() {
  local refresh started age err rc
  [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ] || return 0
  if ! refresh=$(config_refresh_seconds 2>&1); then
    case "$refresh" in *"enabled to false"*) return 0 ;; esac
    log_line "$refresh"
    return 0
  fi
  (umask 077; mkdir -p "$BSTATE") 2>/dev/null || return 0
  started=$(date +%s)
  if [ ! -f "$FEED" ] || inputs_dirty || ! age=$(file_age "$FEED") || [ "$age" -ge "$FULL_EVERY" ]; then
    remember_secondmate_homes 2>/dev/null || true
    rc=0
    err=$(fm_run_timed "$BUILD_TIMEOUT" "$0" build --from-refresh 2>&1 >/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      write_health ok "$started"
    else
      [ "$rc" -ne 124 ] || err="the Bridge build exceeded ${BUILD_TIMEOUT}s; the previous page is unchanged and marks itself out of date"
      err=$(printf '%s' "${err:-the Bridge build failed}" | tail -n 1 | tr '\t\r\n' '   ' | cut -c1-500)
      log_line "$err"
      write_health failed "$started" "$err"
    fi
    return 0
  fi
  if ! age=$(file_age "$(page_path)") || [ "$age" -ge "$refresh" ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    mkdir -p "$TMPD" 2>/dev/null || return 0
    fm_lock_try_acquire "$LOCK" || return 0
    if err=$( (republish) 2>&1 ); then
      write_health ok "$started"
    else
      err=$(printf '%s' "${err:-republish failed}" | tail -n 1 | cut -c1-500)
      log_line "$err"
      write_health failed "$started" "$err"
    fi
    fm_lock_release "$LOCK" >/dev/null 2>&1 || true
  fi
  return 0
}

command_digest() {
  local refresh age
  refresh=$(config_refresh_seconds 2>/dev/null) || refresh=60
  if [ ! -f "$DIGEST" ] || [ -L "$DIGEST" ]; then
    printf 'bridge v1 unavailable\nbridge-warning no digest has been written; run fm-bridge.sh build\n'
    return 0
  fi
  cat -- "$DIGEST"
  # A cut-off file may end mid-line; warnings must start their own line.
  [ -z "$(tail -c 1 "$DIGEST")" ] || printf '\n'
  tail -n 1 "$DIGEST" | grep -q '^bridge-end hash=' \
    || printf 'bridge-warning the digest is truncated; rebuild it\n'
  if age=$(file_age "$DIGEST") && [ "$age" -gt $((refresh * 3)) ] && [ "$age" -gt "$FULL_EVERY" ]; then
    printf 'bridge-warning the digest is %ss old; the Bridge builder may have stopped\n' "$age"
  fi
  if [ -f "$HEALTH" ] && jq -e '.result != "ok"' "$HEALTH" >/dev/null 2>&1; then
    printf 'bridge-warning the last build failed: %s\n' "$(jq -r '.error // "unknown"' "$HEALTH" | cut -c1-200)"
  fi
}

command_route() {
  local ask=${1-}
  case "$ask" in q[0-9a-f]*) ;; *) fail "usage: fm-bridge.sh route <ask-id>" ;; esac
  [ -f "$ROUTES" ] || fail "no Bridge has been built in this home"
  jq -er --arg ask "$ask" '.[$ask] // empty' "$ROUTES" >/dev/null 2>&1 || {
    printf 'not-current: %s is no longer open on the Bridge (answered, closed, re-asked or changed); do not relay it, check the question first\n' "$ask"
    exit 3
  }
  jq -r --arg ask "$ask" '.[$ask] as $r
    | if $r.kind == "hold" then
        "kind: captain-hold\ntask: \($r.task)\nlifecycle: \($r.lifecycle // "none")\nrelay: none; fm-captain-hold.sh answers took it when Lavish captured it"
      elif $r.kind == "key" then
        "kind: keyed-question\ntask: \($r.task)\nkey: \($r.key)\nrelay: bin/fm-send.sh \($r.task) --resolve-key \($r.key) <the captain words>"
      else
        "kind: secondmate\nhome: \($r.home)\ninner-kind: \($r.inner.kind)\ntask: \($r.inner.task)\n"
        + (if $r.inner.kind == "key" then "key: \($r.inner.key)\n" else "lifecycle: \($r.inner.lifecycle // "none")\n" end)
        + "relay: bin/fm-send.sh \($r.home) <the captain words, naming that task>"
      end' "$ROUTES"
}

# A test that sources this file gets the functions and constants above only.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1-}" in
    build)
      shift
      if [ "${1-}" = --from-refresh ]; then run_build 1 0; else [ "$#" -eq 0 ] || { usage >&2; exit 2; }; run_build 1 60; fi
      printf 'bridge: %s\n' "$(page_path)"
      ;;
    refresh) shift; (command_refresh "$@") || true ;;
    open)
      shift
      [ "$#" -eq 0 ] || { usage >&2; exit 2; }
      config_refresh_seconds >/dev/null || exit 1
      run_build 1 60
      # shellcheck source=bin/fm-lavish-board-lib.sh
      . "$SCRIPT_DIR/fm-lavish-board-lib.sh"
      fm_lavish_board_serve "$(page_path)"
      ;;
    path) page_path ;;
    export) shift; run_build 0 60; printf 'export: %s\n' "$EXPORT" ;;
    digest) command_digest ;;
    route) shift; command_route "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
fi
