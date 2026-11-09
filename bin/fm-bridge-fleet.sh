#!/usr/bin/env bash
# fm-bridge-fleet.sh - the Bridge's fleet collector: reads who runs where in
# this home and the secondmate homes under it, with zero model calls and no
# forge read, for bin/fm-bridge.sh, whose header owns the fleet contract
# (FLEET). bin/fm-bridge-fleet.jq owns the flags, wording and order.
#
# Usage:
#   fm-bridge-fleet.sh collect <work-dir>
#   fm-bridge-fleet.sh crew-one <task-id>
#
# collect   Write <work-dir>/fleet-in.json and print nothing. Reads, per home:
#           state/*.meta, a bounded tail (the last TAIL_BYTES) of each
#           state/<id>.status, the busy-state record's ts=, the watcher beacon
#           time and home-summary.json's `valid`; for this home also the wake
#           queue depth and the shared quota reads (percent fields only). It
#           follows kind=secondmate metas into their homes up to DEPTH_MAX
#           levels with a visited set, never into a home that has no live meta
#           here, and writes nothing outside state/bridge.
# crew-one  Refresh one local worker's cached bin/fm-crew-state.sh line under
#           state/bridge/crew. collect runs it, at most CREW_JOBS at a time and
#           each bounded by CREW_TIMEOUT seconds, only for a worker whose status
#           log, meta or busy-state changed since its cached line, or whose line
#           is CREW_EVERY seconds old. A secondmate, a remote worker or a worker
#           whose status log is over CREW_MAX_STATUS_BYTES is never sent to
#           crew-state; its row uses its own last report instead.
#
# Environment: FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE and FM_BRIDGE_STATE_DIR as
# for bin/fm-bridge.sh. FM_BRIDGE_CREW_STATE_CMD replaces the crew-state reader
# (a test seam; it gets the task id as its one argument).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BSTATE="${FM_BRIDGE_STATE_DIR:-$STATE/bridge}"
CREW_DIR="$BSTATE/crew"
CREW_CMD="${FM_BRIDGE_CREW_STATE_CMD:-$SCRIPT_DIR/fm-crew-state.sh}"
DEPTH_MAX=3
ROWS_MAX=200
TAIL_BYTES=65536
CREW_EVERY=300
CREW_JOBS=4
CREW_TIMEOUT=10
CREW_BUDGET=30
CREW_MAX_STATUS_BYTES=262144
QUOTA_MAX_BYTES=4194304
SUMMARY_MAX_BYTES=8388608

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
size_of() { LC_ALL=C stat -c %s "$1" 2>/dev/null || LC_ALL=C stat -f %z "$1" 2>/dev/null; }
# "<size> <mtime>" for each existing file, one line each, in one fork.
if [ "$(uname)" = Darwin ]; then
  stat_lines() { LC_ALL=C /usr/bin/stat -f '%z %m' "$@" 2>/dev/null || true; }
else
  stat_lines() { LC_ALL=C stat -c '%s %Y' "$@" 2>/dev/null || true; }
fi

meta_field() {  # <meta-file> <field>
  local line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#"$2="} ;; esac
  done < "$1"
  printf '%s' "$value"
}

# Status-log statistics over the last TAIL_BYTES, one TSV line:
# last-append-epoch, its source (stamp|mtime), last report verb, its epoch,
# lines in 24 h, the most repeats of one normalised line in the last hour,
# the median gap between stamped lines, the last report text.
status_stats() {  # <status-file> <now> <size> <mtime>
  local f=$1 now=$2 size=$3 mtime=$4 skip=0
  [ "${size:-0}" -gt "$TAIL_BYTES" ] && skip=1
  tail -c "$TAIL_BYTES" -- "$f" 2>/dev/null | LC_ALL=C awk -v now="$now" -v mtime="${mtime:-0}" -v skip="$skip" '
    NR == 1 && skip == 1 { next }
    {
      line = $0; gsub(/[\t\r]/, " ", line)
      head = line; c = index(head, ":"); if (c > 0) head = substr(head, 1, c - 1)
      verb = head; sub(/^[ ]+/, "", verb); sub(/[ \[].*$/, "", verb)
      if (verb !~ /^(working|needs-decision|blocked|done|failed|paused|resolved|note|captain-held)$/) next
      at = ""
      if (match(head, /\[at=[0-9]+\]/)) at = substr(head, RSTART + 4, RLENGTH - 5) + 0
      text = (c > 0) ? substr(line, c + 1) : ""
      sub(/^ +/, "", text)
      if (at != "") {
        last_at = at
        if (prev_at != "" && at >= prev_at) gaps[++ng] = at - prev_at
        prev_at = at
        if (at >= now - 86400) day++
        if (at >= now - 3600) {
          norm = tolower(verb " " text); gsub(/[0-9]+/, "#", norm); gsub(/[ ]+/, " ", norm)
          rep[norm]++; if (rep[norm] > maxrep) maxrep = rep[norm]
        }
      }
      if (verb != "resolved" && verb != "note") { rverb = verb; rtext = text; rat = at }
      any = 1
    }
    END {
      if (!any) { printf "\t\t\t\t0\t0\t\t\n"; exit }
      src = "stamp"; la = last_at
      if (la == "") { la = mtime; src = "mtime" }
      med = ""
      if (ng > 0) {
        start = (ng > 50) ? ng - 49 : 1; n = 0
        for (i = start; i <= ng; i++) g[++n] = gaps[i]
        for (i = 2; i <= n; i++) { v = g[i]; j = i - 1; while (j >= 1 && g[j] > v) { g[j + 1] = g[j]; j-- } g[j + 1] = v }
        med = g[int((n + 1) / 2)]
      }
      if (rat == "" && rverb != "") rat = la
      printf "%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\n", la, src, rverb, rat, day, maxrep, med, substr(rtext, 1, 600)
    }'
}

busy_ts() {  # <busy-state-file>
  local line ts=''
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  IFS= read -r line < "$1" || true
  case " $line " in *" ts="*) ts=${line##* ts=}; ts=${ts%% *} ;; esac
  case "$ts" in ''|*[!0-9]*) ts='' ;; esac
  printf '%s' "$ts"
}

# The status log, meta and busy-state sizes and times, as one word.
crew_sig() {  # <state-dir> <id>
  local out
  out=$(stat_lines "$1/$2.status" "$1/$2.meta" "$1/$2.busy-state")
  out=${out//$'\n'/,}
  printf '%s' "${out// /:}"
}

command_crew_one() {
  local id=${1-} raw rest state source detail sep=' · ' prev_state prev_since since now sig out
  case "$id" in ''|*/*|.*) echo "fm-bridge-fleet: bad task id" >&2; return 2 ;; esac
  (umask 077; mkdir -p "$CREW_DIR") || return 1
  now=$(date +%s)
  sig=$(crew_sig "$STATE" "$id")
  raw=$(fm_run_timed "$CREW_TIMEOUT" env FM_CREW_STATE_NO_FORGE=1 FM_CREW_STATE_NM_TIMEOUT=5 \
    "$CREW_CMD" "$id" 2>/dev/null | head -n 1) || true
  state=unknown source=none detail="the current-state reader gave no usable answer within ${CREW_TIMEOUT}s"
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest; detail='' ;;
      esac
      ;;
  esac
  out="$CREW_DIR/$id.json"
  prev_state=$(jq -r '.state // empty' "$out" 2>/dev/null || true)
  prev_since=$(jq -r '.since // empty' "$out" 2>/dev/null || true)
  since=$now
  [ "$prev_state" = "$state" ] && [ -n "$prev_since" ] && since=$prev_since
  jq -cn --arg sig "$sig" --argjson checked "$now" --argjson since "$since" \
    --arg state "$state" --arg source "$source" --arg detail "$detail" \
    '{sig:$sig, checked:$checked, since:$since, state:$state, source:$source, detail:$detail}' \
    > "$out.tmp.$$" && mv -f -- "$out.tmp.$$" "$out"
  printf '%s\t%s\n' "$sig" "$now" > "$CREW_DIR/$id.sig.tmp.$$" && mv -f -- "$CREW_DIR/$id.sig.tmp.$$" "$CREW_DIR/$id.sig"
}

# Refresh every due crew-state line, bounded in parallelism and total time; a
# worker not reached keeps its last line, or reads as unknown when it has none.
refresh_crew() {  # <due-file>
  [ -s "$1" ] || return 0
  fm_run_timed "$CREW_BUDGET" xargs -P "$CREW_JOBS" -n 1 "$0" crew-one < "$1" >/dev/null 2>&1 || true
}

quota_json() {  # <out-file>
  local f="$STATE/quota-single-flight/reads.json" size
  printf 'null\n' > "$1"
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  size=$(size_of "$f") || return 0
  [ "${size:-0}" -le "$QUOTA_MAX_BYTES" ] || return 0
  # Percent, window kind and reset time only: never an account, email or plan.
  if jq -c 'if type != "object" then null else
    [to_entries[] | select(.value | type == "object")
     | {dir: (.key | split("|") | .[2:] | join("|")), at: (.value.at | if type == "number" then . else null end),
        rows: [(.value.rows // [])[]? | select(type == "object")
          | {provider: (.provider | tostring),
             windows: [(.windows // [])[]? | select(type == "object" and (.kind == "session" or .kind == "weekly"))
               | {kind, used: (.percentUsed | if type == "number" then . else null end),
                  resets: (.resetsAt | if type == "string" then .[0:25] else null end)}]}]}]
    end' "$f" > "$1.tmp" 2>/dev/null; then
    mv -f -- "$1.tmp" "$1"
  else
    rm -f -- "$1.tmp"
  fi
}

accounts_json() {  # <out-file>
  local f="$CONFIG/accounts.json"
  printf '{}\n' > "$1"
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  if jq -c '(.accounts // {}) | if type == "object" then
      with_entries(select(.value | type == "object")
        | .value = {provider: (.value.provider // null),
                    dir: (.value[.value.provider // ""] // .value.claude // .value.codex // .value.pi // null
                      | if type == "string" then . else null end)})
    else {} end' "$f" > "$1.tmp" 2>/dev/null; then
    mv -f -- "$1.tmp" "$1"
  else
    rm -f -- "$1.tmp"
  fi
}

# One home: its rows (one per meta) and health, appended to homes.jsonl; its
# secondmates are queued for the next level.
scan_home() {  # <work-dir> <home-state-dir> <home-id> <parent-id> <depth> <local:0|1> <now>
  local w=$1 hs=$2 hid=$3 parent=$4 depth=$5 is_local=$6 now=$7 f id kind home remote stats sig cached
  local sm rows="$w/rows.$depth.$RANDOM.tsv" n=0 beacon='' valid='' size crew checked
  : > "$rows"
  for f in "$hs"/*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || continue
    n=$((n + 1))
    [ "$n" -le "$ROWS_MAX" ] || continue
    id=${f##*/}; id=${id%.meta}
    kind=$(meta_field "$f" kind)
    home=$(meta_field "$f" home)
    remote=$(meta_field "$f" remote_host)
    stats='' sm=''
    if [ -f "$hs/$id.status" ] && [ ! -L "$hs/$id.status" ] && [ -r "$hs/$id.status" ]; then
      sm=$(stat_lines "$hs/$id.status")
      stats=$(status_stats "$hs/$id.status" "$now" "${sm% *}" "${sm#* }")
    fi
    crew=''
    if [ "$is_local" = 1 ] && [ "$kind" != secondmate ] && [ -z "$remote" ]; then
      size=${sm% *}
      if [ "${size:-0}" -le "$CREW_MAX_STATUS_BYTES" ]; then
        crew=$id
        printf '%s\n' "$id" >> "$w/crew-ids"
        sig=$(crew_sig "$hs" "$id")
        cached=''
        [ -f "$CREW_DIR/$id.sig" ] && IFS= read -r cached < "$CREW_DIR/$id.sig"
        checked=${cached##*$'\t'}
        case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
        if [ "${cached%$'\t'*}" != "$sig" ] || [ $((checked + CREW_EVERY)) -le "$now" ]; then
          printf '%s\n' "$id" >> "$w/crew-due"
        fi
      fi
    fi
    # One TSV row; tabs inside a field would shift columns, so fold them.
    printf '%s\t' "$id" "$kind" "$(meta_field "$f" harness)" "$(meta_field "$f" model)" "$(meta_field "$f" seat)" \
      "$(meta_field "$f" claude_config_dir)" "$remote" "$home" "$crew" "$(meta_field "$f" pr)" \
      "$(busy_ts "$hs/$id.busy-state")" "$(meta_field "$f" project)" "$(meta_field "$f" projects)" | tr '\t\n' '\037 ' >> "$rows"
    printf '%s\n' "${stats:-$'\t\t\t\t\t\t\t'}" >> "$rows"
    if [ "$kind" = secondmate ]; then
      # A non-whitespace separator: read would merge empty tab-separated fields.
      printf '%s\037%s\037%s\037%s\n' "$id" "$home" "$remote" "$hid" >> "$w/next.$((depth + 1))"
    fi
  done
  if [ -e "$hs/.last-watcher-beat" ]; then beacon=$(mtime_of "$hs/.last-watcher-beat") || beacon=''; fi
  if [ -f "$hs/home-summary.json" ] && [ ! -L "$hs/home-summary.json" ] \
    && size=$(size_of "$hs/home-summary.json") && [ "${size:-0}" -le "$SUMMARY_MAX_BYTES" ]; then
    valid=$(jq -r '.valid | if type == "boolean" then tostring else empty end' "$hs/home-summary.json" 2>/dev/null || true)
  fi
  jq -cn --arg id "$hid" --arg parent "$parent" --argjson depth "$depth" --argjson local "$is_local" \
    --arg beacon "$beacon" --arg valid "$valid" --argjson total "$n" --rawfile rows "$rows" '
    def num: if . == null or . == "" then null else (tonumber? // null) end;
    def str: if . == null or . == "" then null else . end;
    {id:(if $id == "" then null else $id end), parent:(if $parent == "" then null else $parent end),
     depth:$depth, local:($local == 1), read:"ok",
     beacon_epoch:($beacon | tonumber? // null),
     summary_valid:(if $valid == "" then null else ($valid == "true") end),
     total:$total,
     rows:[$rows | split("\n")[] | select(length > 0) | split("\u001f") | .[0:13] as $m
       | ((.[13] // "") | split("\t")) as $s
       | {id:$m[0], kind:($m[1] | str), harness:$m[2], model:$m[3], seat:($m[4] | str), dir:($m[5] | str),
          remote:($m[6] != ""), home_path:($m[7] | str), crew_id:($m[8] | str), meta_pr:$m[9],
          busy_epoch:($m[10] | num), project:$m[11], projects:$m[12], has_status:(($s[0] // "") != "" or ($s[2] // "") != ""),
          last_epoch:($s[0] | num), last_estimated:(($s[1] // "") == "mtime"),
          verb:($s[2] | str), report_epoch:($s[3] | num),
          lines_24h:(($s[4] | num) // 0), repeat_1h:(($s[5] | num) // 0), median_gap:($s[6] | num),
          text:($s[7:] | join(" ") | str)}]}' >> "$w/homes.jsonl"
  rm -f -- "$rows"
}

home_unread() {  # <work-dir> <home-id> <parent-id> <depth> <why>
  jq -cn --arg id "$2" --arg parent "$3" --argjson depth "$4" --arg why "$5" \
    '{id:$id, parent:$parent, depth:$depth, local:false, read:$why, beacon_epoch:null,
      summary_valid:null, total:0, rows:[]}' >> "$1/homes.jsonl"
}

command_collect() {
  local w=${1-} now depth id home remote parent real queue_depth=0 last_wake='' beacon_fresh=false
  [ -n "$w" ] && [ -d "$w" ] || { echo "usage: fm-bridge-fleet.sh collect <work-dir>" >&2; return 2; }
  (umask 077; mkdir -p "$CREW_DIR") || return 1
  now=$(date +%s)
  : > "$w/homes.jsonl"
  : > "$w/crew-due"
  : > "$w/crew-ids"
  : > "$w/visited"
  real=$(cd "$STATE" && pwd -P) || return 1
  printf '%s\n' "$real" >> "$w/visited"
  scan_home "$w" "$STATE" "" "" 0 1 "$now"
  depth=1
  while [ "$depth" -le "$DEPTH_MAX" ] && [ -s "$w/next.$depth" ]; do
    while IFS=$'\037' read -r id home remote parent; do
      if [ -n "$remote" ]; then home_unread "$w" "$id" "$parent" "$depth" remote; continue; fi
      if [ -z "$home" ] || [ ! -d "$home/state" ]; then home_unread "$w" "$id" "$parent" "$depth" remote; continue; fi
      real=$(cd "$home/state" 2>/dev/null && pwd -P) || { home_unread "$w" "$id" "$parent" "$depth" failed; continue; }
      if grep -qxF -- "$real" "$w/visited"; then home_unread "$w" "$id" "$parent" "$depth" repeated; continue; fi
      printf '%s\n' "$real" >> "$w/visited"
      printf '%s\n' "$home" >> "$w/fleet-homes"
      scan_home "$w" "$home/state" "$id" "$parent" "$depth" 0 "$now"
    done < "$w/next.$depth"
    depth=$((depth + 1))
  done
  # Secondmates below the depth limit are named but not read.
  if [ -s "$w/next.$depth" ]; then
    while IFS=$'\037' read -r id home remote parent; do
      home_unread "$w" "$id" "$parent" "$depth" too-deep
    done < "$w/next.$depth"
  fi
  refresh_crew "$w/crew-due"
  # Only the cached lines of rows read this pass, in one jq.
  printf '{}\n' > "$w/crew.json"
  set --
  while IFS= read -r id; do
    [ -f "$CREW_DIR/$id.json" ] && set -- "$@" "$CREW_DIR/$id.json"
  done < "$w/crew-ids"
  if [ "$#" -gt 0 ]; then
    jq -cn 'reduce inputs as $x ({}; . + {(input_filename | sub("^.*/"; "") | sub("\\.json$"; "")): $x})' "$@" \
      > "$w/crew.json" 2>/dev/null || printf '{}\n' > "$w/crew.json"
  fi
  if [ -f "$STATE/.wake-queue" ]; then
    queue_depth=$(wc -l < "$STATE/.wake-queue" 2>/dev/null | tr -d '[:space:]') || queue_depth=0
  fi
  [ -e "$STATE/.wake-queue.seq" ] && last_wake=$(mtime_of "$STATE/.wake-queue.seq" || true)
  # shellcheck source=bin/fm-supervision-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  fm_supervision_status "$STATE" >/dev/null 2>&1 || true
  beacon_fresh=${FM_SUP_WATCHER_FRESH:-false}
  quota_json "$w/quota.json"
  accounts_json "$w/accounts.json"
  jq -n --argjson now "$now" --argjson depth_max "$DEPTH_MAX" --arg queue "${queue_depth:-0}" \
    --arg last_wake "$last_wake" --arg fresh "$beacon_fresh" \
    --slurpfile quota "$w/quota.json" --slurpfile accounts "$w/accounts.json" \
    --rawfile homes "$w/homes.jsonl" --slurpfile crew "$w/crew.json" '
    {now:$now, depth_max:$depth_max,
     firstmate:{watcher_fresh:($fresh == "true"), queue_depth:($queue | tonumber? // 0),
                last_wake_epoch:($last_wake | tonumber? // null)},
     homes:[$homes | split("\n")[] | select(length > 0) | fromjson],
     crew:$crew[0],
     quota:$quota[0], accounts:$accounts[0]}' > "$w/fleet-in.json"
  # The homes the input check watches (bin/fm-bridge.sh inputs_dirty).
  if [ -s "$w/fleet-homes" ]; then
    cp -- "$w/fleet-homes" "$BSTATE/fleet-homes.tmp" && mv -f -- "$BSTATE/fleet-homes.tmp" "$BSTATE/fleet-homes"
  else
    : > "$BSTATE/fleet-homes"
  fi
}

case "${1-}" in
  collect) shift; command_collect "$@" ;;
  crew-one) shift; command_crew_one "$@" ;;
  -h|--help|help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
  *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2; exit 2 ;;
esac
