#!/usr/bin/env bash
# fm-claude-admission.sh - per-credential-store release shaping and committed-
# demand evidence for firstmate-launched Claude Code workers.
#
# Usage:
#   fm-claude-admission.sh demand [--store <path|default>]
#   fm-claude-admission.sh gate <task-id> [--priority <1-99>] [--reason <text>] [--store <path|default>]
#   fm-claude-admission.sh check <task-id> [--priority <1-99>] [--store <path|default>]
#   fm-claude-admission.sh withdraw <task-id> [--store <path|default>]
#   fm-claude-admission.sh queue [--store <path|default>]
#   fm-claude-admission.sh poll
#   fm-claude-admission.sh arm
#   fm-claude-admission.sh disarm
#   fm-claude-admission.sh --help
#
# WHY THIS EXISTS. A Claude subscription window's reset instant is a
# synchronization edge: every session holding Claude Code's own "continuing
# automatically at <time>" timer fires on it, and firstmate's own dispatch and
# relaunch paths read the same edge as "the account is free again". Nothing in
# the stack held an account-level admission decision, so the whole backlog
# discharged into a fresh window at once. This script is that missing decision,
# and it is deliberately narrow: it shapes WHEN firstmate's own Claude launches
# are released, and it publishes what is already committed to a store. It never
# cancels work, never reroutes it to another harness or account, never disables
# Claude Code's automatic continuation, and never pauses work on a usage
# percentage.
#
# SCOPE IS OPT-IN AND PER STORE. config/claude-shaped-store lists the Claude
# credential stores this home shapes, one absolute path per line ('#' comments
# and blank lines ignored). A store not listed - and every store in a home with
# no such file - takes no state, no lock, and no decision: `gate` returns
# admitted without touching the filesystem, which is what keeps the default
# personal store byte-for-byte unshaped. The store a launch will use is
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}, the same value bin/fm-spawn.sh forwards
# onto a claude pane, so the identity here is the one the worker actually bills.
# `--store` names that store explicitly, which is how a caller passes a task's OWN
# recorded binding instead of the ambient one; the literal `default` means the
# no-CLAUDE_CONFIG_DIR store.
# There is no name matching and no vendor string in that identity, and no
# credential value is ever read, printed, or copied.
#
# THE TWO HALVES.
#
#   demand   The committed-demand census. It counts LIVE PARKED sessions in the
#            store: a transcript whose last decisive record is Claude Code's own
#            "Usage limit reached ... continuing automatically" notice, with no
#            later real turn, no later "Usage limit reset" resume, no later
#            continued-in fork, and a park no older than
#            FM_CLAUDE_DEMAND_MAX_AGE. For each one it reports that session's
#            own measured average billable input tokens per turn. This is
#            EVIDENCE, never a route and never a quota reading: point-in-time
#            headroom stays quota-axi's, and the two are read side by side and
#            never folded into one number.
#            floorInputTokens is a measured FLOOR - one resumed turn per parked
#            session - not a forecast of the burst those sessions will produce.
#
#   gate     The release decision, taken once per launch, before the caller has
#            created anything. Shaping is ARMED while the store carries parked
#            demand, and stays armed for FM_CLAUDE_DEMAND_HORIZON after the last
#            time it did, so the reset edge itself is covered while an ordinary
#            unlimited window is not shaped at all. While armed, at most one
#            launch is released per FM_CLAUDE_RELEASE_INTERVAL, highest priority
#            first. A withheld launch is recorded in a durable queue that
#            survives restarts, and `poll` wakes firstmate when the next slot
#            opens. Nothing is ever dropped from the queue except by an explicit
#            `withdraw` or by being released.
#
# PRIORITY. --priority takes 1..99, LOWER IS RELEASED FIRST, default 50. Ties
# break on enqueue time, oldest first. A request that is not the head is
# withheld and told which task must go first, unless the head has already waited
# FM_CLAUDE_HEAD_MAX_WAIT (default: three release intervals), which is the
# bounded valve that keeps an abandoned queue entry from stalling the rest.
#
# FAIL-CLOSED BOUNDARY. Unreadable or malformed evidence - a config line that is
# not an absolute path, a torn armed-since record, a transcript with an
# unparseable non-final line, an unreadable transcript, a missing python3 - exits
# 3 and refuses the launch, after recording the request in the durable queue.
# Work is preserved and named, never consumed and never lost. That refusal is an
# evidence failure to repair, not a usage stop line: it is never keyed to how
# full a window is.
#
# EXIT CODES
#   0  admitted, or the verb's ordinary success
#   1  withheld (the queue holds the request; the message names the next slot)
#   2  usage error
#   3  configuration or evidence problem; nothing was released and nothing lost
#
# Environment knobs:
#   FM_CLAUDE_RELEASE_INTERVAL  seconds between releases while armed (420, 1..3600)
#   FM_CLAUDE_DEMAND_HORIZON    seconds shaping stays armed after demand clears (1800, 0..86400)
#   FM_CLAUDE_DEMAND_MAX_AGE    oldest park still counted as live (21600, 60..604800)
#   FM_CLAUDE_DEMAND_TURNS      recent turns averaged per parked session (10, 1..500)
#   FM_CLAUDE_DEMAND_TAIL_BYTES transcript tail read per file (1048576, 65536..67108864)
#   FM_CLAUDE_HEAD_MAX_WAIT     head-of-queue block bound (3 x release interval, 0..604800)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG="$CONFIG_DIR/claude-shaped-store"
ADMISSION_ROOT="$STATE/claude-admission"
HOME_REFUSAL="$ADMISSION_ROOT/.home-evidence-refusal"
CHECK_ID=claude-admission
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-claude-admission: %s\n' "$1" >&2
  exit 2
}

die_evidence() {
  printf 'fm-claude-admission: %s\n' "$1" >&2
  exit 3
}

# --- knobs ------------------------------------------------------------------

read_bounded() {  # <name> <value> <default> <min> <max>
  local name=$1 value=$2 def=$3 min=$4 max=$5
  [ -n "$value" ] || value=$def
  case "$value" in
    ''|*[!0-9]*) die_usage "$name must be a whole number from $min to $max" ;;
  esac
  if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    die_usage "$name must be a whole number from $min to $max"
  fi
  printf '%s\n' "$value"
}

RELEASE_INTERVAL=$(read_bounded FM_CLAUDE_RELEASE_INTERVAL "${FM_CLAUDE_RELEASE_INTERVAL:-}" 420 1 3600) || exit $?
DEMAND_HORIZON=$(read_bounded FM_CLAUDE_DEMAND_HORIZON "${FM_CLAUDE_DEMAND_HORIZON:-}" 1800 0 86400) || exit $?
DEMAND_MAX_AGE=$(read_bounded FM_CLAUDE_DEMAND_MAX_AGE "${FM_CLAUDE_DEMAND_MAX_AGE:-}" 21600 60 604800) || exit $?
DEMAND_TURNS=$(read_bounded FM_CLAUDE_DEMAND_TURNS "${FM_CLAUDE_DEMAND_TURNS:-}" 10 1 500) || exit $?
DEMAND_TAIL=$(read_bounded FM_CLAUDE_DEMAND_TAIL_BYTES "${FM_CLAUDE_DEMAND_TAIL_BYTES:-}" 1048576 65536 67108864) || exit $?
HEAD_MAX_WAIT=$(read_bounded FM_CLAUDE_HEAD_MAX_WAIT "${FM_CLAUDE_HEAD_MAX_WAIT:-}" $((RELEASE_INTERVAL * 3)) 0 604800) || exit $?

# --- store identity ---------------------------------------------------------

# The store a claude launch from this environment will actually bill, in the
# same form bin/fm-spawn.sh forwards onto the pane. Canonicalized when it
# exists so two spellings of one store never take two queues.
canonical_store() {  # <path>
  local path=$1 real
  path=${path%/}
  [ -n "$path" ] || path=/
  if real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# STORE_OVERRIDE carries a task's OWN recorded credential binding, which is what
# a relaunch must use: the ambient value belongs to whichever session firstmate
# happens to be running in, and a task's account must not follow it.
# The literal "default" is the no-CLAUDE_CONFIG_DIR binding, not a path.
STORE_OVERRIDE=

launch_store() {
  local raw=${STORE_OVERRIDE:-${CLAUDE_CONFIG_DIR:-}}
  [ "$raw" != default ] || raw=
  if [ -z "$raw" ]; then
    [ -n "${HOME:-}" ] || die_evidence "neither CLAUDE_CONFIG_DIR nor HOME is set, so the Claude credential store a launch would use cannot be identified"
    raw="$HOME/.claude"
  fi
  case "$raw" in
    /*) ;;
    *) die_evidence "CLAUDE_CONFIG_DIR '$raw' is not an absolute path, so the Claude credential store a launch would use cannot be identified" ;;
  esac
  canonical_store "$raw"
}

# 0 when <store> is listed in config/claude-shaped-store. An absent config file
# means no store is shaped, which is the unconfigured default.
store_is_shaped() {  # <canonical-store>
  local store=$1 line entry
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    # shellcheck disable=SC2001  # Trimming both ends needs two anchored cuts.
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$line" ] || continue
    case "$line" in
      /*) ;;
      *) die_evidence "config/claude-shaped-store lists '$line', which is not an absolute path; fix the file before any Claude launch can be released" ;;
    esac
    entry=$(canonical_store "$line")
    [ "$entry" = "$store" ] || continue
    return 0
  done < "$CONFIG" || die_evidence "config/claude-shaped-store could not be read; fix the file before any Claude launch can be released"
  return 1
}

# A filesystem-safe, human-recognizable directory name for one store: the
# store's own basename plus a short digest of its canonical path, so two stores
# with the same basename never share state.
store_slug() {  # <canonical-store>
  local store=$1 base digest
  base=$(basename -- "$store")
  base=${base//[!A-Za-z0-9._-]/_}
  [ -n "$base" ] || base=store
  digest=$(printf '%s' "$store" | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } | awk '{print $1}')
  [ -n "$digest" ] || die_evidence "no sha256 tool (shasum or sha256sum) is available to identify the Claude credential store"
  printf '%s-%s\n' "$base" "${digest:0:12}"
}

# --- committed-demand census ------------------------------------------------

# Emits key=value lines plus one "session" row per live parked session, or a
# single "error=<reason>" line. Reads only <store>/projects/*/*.jsonl, and only
# the tail of each file: a parked session writes nothing after its park notice,
# so the decisive records are always at the end.
demand_census() {  # <canonical-store>
  local store=$1 out status
  command -v python3 >/dev/null 2>&1 \
    || die_evidence "python3 is required to read the committed-demand evidence for $store"
  out=$(FM_CA_STORE="$store" FM_CA_MAX_AGE="$DEMAND_MAX_AGE" FM_CA_TURNS="$DEMAND_TURNS" \
    FM_CA_TAIL="$DEMAND_TAIL" python3 - <<'PY'
import json, os, sys, time, glob

store = os.environ["FM_CA_STORE"]
max_age = int(os.environ["FM_CA_MAX_AGE"])
want_turns = int(os.environ["FM_CA_TURNS"])
tail_bytes = int(os.environ["FM_CA_TAIL"])

PARK_PREFIX = "Usage limit reached"
RESUME_PREFIX = "Usage limit reset"
AUTO_MARKER = "continuing automatically"


def fail(reason):
    print("error=%s" % reason)
    sys.exit(0)


def read_tail(path):
    # Returns the decoded tail with any leading partial line dropped, plus a
    # flag for whether the file was read from its very beginning.
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        if size > tail_bytes:
            fh.seek(size - tail_bytes)
            whole = False
        else:
            whole = True
        blob = fh.read()
    text = blob.decode("utf-8", "replace")
    if not whole:
        cut = text.find("\n")
        text = "" if cut < 0 else text[cut + 1:]
    return text, whole


def parse_ts(value):
    if not isinstance(value, str) or not value:
        return None
    raw = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        import datetime

        return datetime.datetime.fromisoformat(raw).timestamp()
    except Exception:
        return None


now = time.time()
projects = os.path.join(store, "projects")
files = []
if os.path.isdir(projects):
    try:
        files = sorted(glob.glob(os.path.join(projects, "*", "*.jsonl")))
    except OSError as exc:
        fail("transcript directory %s could not be listed (%s)" % (projects, exc.strerror or "unreadable"))

scanned = 0
skipped = 0
parked = []
for path in files:
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        fail("transcript %s could not be inspected" % os.path.basename(path))
    if now - mtime > max_age:
        skipped += 1
        continue
    try:
        text, _whole = read_tail(path)
    except OSError:
        fail("transcript %s could not be read" % os.path.basename(path))
    scanned += 1
    lines = text.splitlines()
    records = []
    for index, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except ValueError:
            # A torn FINAL line is a concurrent write, not malformed evidence.
            if index == len(lines) - 1:
                continue
            fail("transcript %s holds an unreadable record" % os.path.basename(path))

    park_at = -1
    park_ts = None
    session_id = None
    decisive_at = -1
    turns = []
    for index, rec in enumerate(records):
        kind = rec.get("type")
        if rec.get("sessionId"):
            session_id = rec.get("sessionId")
        if kind == "system":
            content = rec.get("content")
            if isinstance(content, str):
                if content.startswith(PARK_PREFIX) and AUTO_MARKER in content:
                    park_at = index
                    park_ts = parse_ts(rec.get("timestamp"))
                elif content.startswith(RESUME_PREFIX):
                    decisive_at = index
        elif kind == "continued-in":
            decisive_at = index
        elif kind == "assistant":
            message = rec.get("message")
            if not isinstance(message, dict):
                continue
            if message.get("model") == "<synthetic>":
                continue
            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue
            decisive_at = index
            billable = 0
            for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
                value = usage.get(key)
                if isinstance(value, int):
                    billable += value
            turns.append((message.get("id"), billable))

    if park_at < 0 or park_at < decisive_at:
        continue
    if park_ts is None:
        fail("transcript %s records a park with no readable timestamp" % os.path.basename(path))
    age = int(now - park_ts)
    if age > max_age:
        skipped += 1
        continue

    seen = set()
    recent = []
    for message_id, billable in reversed(turns):
        key = message_id if message_id else object()
        if key in seen:
            continue
        seen.add(key)
        recent.append(billable)
        if len(recent) >= want_turns:
            break
    observed = len(recent)
    average = int(sum(recent) / observed) if observed else 0
    parked.append((session_id or "unknown", int(park_ts), age, observed, average))

parked.sort(key=lambda row: row[1])
print("scannedFiles=%d" % scanned)
print("skippedStaleFiles=%d" % skipped)
print("parkedSessions=%d" % len(parked))
print("floorInputTokens=%d" % sum(row[4] for row in parked))
for session_id, park_epoch, age, observed, average in parked:
    print("session\t%s\t%d\t%d\t%d\t%d" % (session_id, park_epoch, age, observed, average))
PY
  )
  status=$?
  [ "$status" -eq 0 ] || die_evidence "the committed-demand census for $store exited $status"
  case "$out" in
    error=*) die_evidence "${out#error=}" ;;
  esac
  printf '%s\n' "$out"
}

census_value() {  # <census> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=\\(.*\\)$/\\1/p" | head -n 1
}

# --- durable per-store state ------------------------------------------------

STORE=
SLUG=
STORE_DIR=
QUEUE=
LAST_RELEASE=
ARMED_SINCE=
REPORTED=
LOCK=

resolve_store_state() {  # <canonical-store>
  STORE=$1
  SLUG=$(store_slug "$STORE") || exit $?
  STORE_DIR="$ADMISSION_ROOT/$SLUG"
  QUEUE="$STORE_DIR/queue"
  LAST_RELEASE="$STORE_DIR/last-release"
  ARMED_SINCE="$STORE_DIR/armed-since"
  REPORTED="$STORE_DIR/reported"
  LOCK="$STORE_DIR/.lock"
}

ensure_store_dir() {
  (umask 077; mkdir -p "$STORE_DIR") \
    || die_evidence "the release-shaping record directory $STORE_DIR could not be created"
  [ -d "$STORE_DIR" ] && [ ! -L "$STORE_DIR" ] \
    || die_evidence "the release-shaping record directory $STORE_DIR is not a plain directory"
  printf '%s\n' "$STORE" > "$STORE_DIR/store" \
    || die_evidence "the shaped store could not be recorded at $STORE_DIR/store"
}

# Whole-file replace through a temp file in the same directory, so an
# interrupted write leaves the previous durable record intact.
write_record() {  # <path> <content>
  local path=$1 content=$2 tmp
  tmp=$(umask 077; mktemp "$STORE_DIR/.fm-claude-admission.XXXXXX") \
    || die_evidence "a durable release-shaping record could not be staged in $STORE_DIR"
  if ! printf '%s' "$content" > "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    die_evidence "the durable release-shaping record $path could not be written"
  fi
}

read_epoch_record() {  # <path> -> epoch, or empty when absent
  local path=$1 value
  [ -f "$path" ] || { printf '\n'; return 0; }
  [ ! -L "$path" ] || die_evidence "$path is a symlink, not a durable record"
  value=$(head -n 1 -- "$path" 2>/dev/null) \
    || die_evidence "$path could not be read"
  value=${value%%	*}
  case "$value" in
    ''|*[!0-9]*) die_evidence "$path does not hold a readable timestamp; repair or remove it before any Claude launch can be released" ;;
  esac
  printf '%s\n' "$value"
}

# queue lines are: <enqueued-epoch>\t<priority>\t<task-id>\t<reason>
read_queue() {
  [ -f "$QUEUE" ] || return 0
  [ ! -L "$QUEUE" ] || die_evidence "$QUEUE is a symlink, not a durable queue"
  cat -- "$QUEUE" 2>/dev/null || die_evidence "the durable release queue $QUEUE could not be read"
}

# Sorted by priority then enqueue time, both ascending, so the head is the
# highest-priority oldest request. Malformed rows refuse rather than reorder.
sorted_queue() {
  local queue row epoch priority id
  queue=$(read_queue) || exit $?
  [ -n "$queue" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r epoch priority id _ <<< "$row"
    case "$epoch" in ''|*[!0-9]*) die_evidence "the durable release queue $QUEUE holds an unreadable row; repair or remove it before any Claude launch can be released" ;; esac
    case "$priority" in ''|*[!0-9]*) die_evidence "the durable release queue $QUEUE holds an unreadable priority; repair or remove it before any Claude launch can be released" ;; esac
    fm_pr_task_id_valid "$id" || die_evidence "the durable release queue $QUEUE names an unusable task; repair or remove it before any Claude launch can be released"
  done <<< "$queue"
  printf '%s\n' "$queue" | grep -v '^$' | sort -t$'\t' -k2,2n -k1,1n
}

queue_has() {  # <task-id>
  local id=$1 row queue
  queue=$(read_queue) || exit $?
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in
      *$'\t'"$id"$'\t'*) return 0 ;;
    esac
  done <<< "$queue"
  return 1
}

queue_enqueue() {  # <task-id> <priority> <reason>
  local id=$1 priority=$2 reason=$3 queue
  queue_has "$id" && return 0
  queue=$(read_queue) || exit $?
  reason=${reason//$'\t'/ }
  reason=${reason//$'\n'/ }
  if [ -n "$queue" ]; then
    write_record "$QUEUE" "$queue"$'\n'"$(date +%s)"$'\t'"$priority"$'\t'"$id"$'\t'"$reason"$'\n'
  else
    write_record "$QUEUE" "$(date +%s)"$'\t'"$priority"$'\t'"$id"$'\t'"$reason"$'\n'
  fi
}

queue_remove() {  # <task-id>
  local id=$1 queue kept
  queue=$(read_queue) || exit $?
  [ -n "$queue" ] || return 0
  kept=$(printf '%s\n' "$queue" | awk -F'\t' -v id="$id" '$0 != "" && $3 != id')
  if [ -n "$kept" ]; then
    write_record "$QUEUE" "$kept"$'\n'
  else
    write_record "$QUEUE" ""
  fi
}

# --- the release decision ---------------------------------------------------

DECISION=
DECISION_MESSAGE=
DECISION_ARMED=
DECISION_WAIT=
DECISION_PARKED=0

# Fills the DECISION_* globals for <task-id> at <priority>. Mutates nothing.
evaluate() {  # <task-id> <priority> [census]
  local id=$1 priority=$2 census=${3:-} parked now armed_since last head head_epoch head_row sorted waited
  [ -n "$census" ] || census=$(demand_census "$STORE") || exit $?
  parked=$(census_value "$census" parkedSessions)
  case "$parked" in
    ''|*[!0-9]*) die_evidence "the committed-demand census for $STORE returned no readable parked-session count" ;;
  esac
  DECISION_PARKED=$parked
  now=$(date +%s)
  armed_since=$(read_epoch_record "$ARMED_SINCE") || exit $?

  if [ "$parked" -gt 0 ]; then
    DECISION_ARMED=yes
  elif [ -n "$armed_since" ] && [ $((now - armed_since)) -le "$DEMAND_HORIZON" ]; then
    DECISION_ARMED=yes
  else
    DECISION_ARMED=no
  fi

  DECISION_WAIT=0
  if [ "$DECISION_ARMED" = no ]; then
    DECISION=admit
    DECISION_MESSAGE="no parked demand on $STORE and none within the last ${DEMAND_HORIZON}s, so this launch is not shaped"
    return 0
  fi

  last=$(read_epoch_record "$LAST_RELEASE") || exit $?
  if [ -n "$last" ] && [ $((now - last)) -lt "$RELEASE_INTERVAL" ]; then
    DECISION=withhold
    DECISION_WAIT=$((RELEASE_INTERVAL - (now - last)))
    DECISION_MESSAGE="a Claude worker was released onto $STORE $((now - last))s ago; the next release slot opens in ${DECISION_WAIT}s"
    return 0
  fi

  sorted=$(sorted_queue) || exit $?
  head_row=$(printf '%s\n' "$sorted" | head -n 1)
  if [ -n "$head_row" ]; then
    IFS=$'\t' read -r head_epoch _ head _ <<< "$head_row"
    if [ "$head" != "$id" ]; then
      waited=$((now - head_epoch))
      if [ "$waited" -lt "$HEAD_MAX_WAIT" ]; then
        DECISION=withhold
        DECISION_MESSAGE="$head is higher-priority waiting work on $STORE and takes the next release slot; release it first, or withdraw it if it is no longer wanted"
        return 0
      fi
    fi
  fi

  DECISION=admit
  DECISION_MESSAGE="release slot open on $STORE with $parked parked session(s) of committed demand"
}

# --- verbs ------------------------------------------------------------------

PRIORITY=50
REASON=

parse_store_arg() {  # <verb> [--store <path|default>]
  local verb=$1
  shift
  case "$#" in
    0) return 0 ;;
    1)
      case "$1" in
        --store=*) STORE_OVERRIDE=${1#--store=}; return 0 ;;
      esac
      ;;
    2)
      [ "$1" = --store ] || die_usage "$verb takes only --store"
      STORE_OVERRIDE=$2
      return 0
      ;;
  esac
  die_usage "$verb takes only --store"
}

parse_task_args() {  # <verb> <args...>
  local verb=$1 want=
  shift
  TASK_ID=
  for arg in "$@"; do
    if [ -n "$want" ]; then
      case "$want" in
        priority) PRIORITY=$arg ;;
        reason) REASON=$arg ;;
        store) STORE_OVERRIDE=$arg ;;
      esac
      want=
      continue
    fi
    case "$arg" in
      --priority) want=priority ;;
      --priority=*) PRIORITY=${arg#--priority=} ;;
      --reason) want=reason ;;
      --reason=*) REASON=${arg#--reason=} ;;
      --store) want=store ;;
      --store=*) STORE_OVERRIDE=${arg#--store=} ;;
      -*) die_usage "unknown option for $verb: $arg" ;;
      *)
        [ -z "$TASK_ID" ] || die_usage "$verb takes exactly one task id"
        TASK_ID=$arg
        ;;
    esac
  done
  [ -z "$want" ] && [ -n "$TASK_ID" ] || die_usage "$verb requires a task id"
  fm_pr_task_id_valid "$TASK_ID" || die_usage "'$TASK_ID' is not a usable task id"
  PRIORITY=$(read_bounded --priority "$PRIORITY" 50 1 99) || exit $?
}

action_demand() {
  local store census row session epoch age turns average shaped
  store=$(launch_store) || exit $?
  census=$(demand_census "$store") || exit $?
  if store_is_shaped "$store"; then shaped=yes; else shaped=no; fi
  printf 'store=%s\n' "$store"
  printf 'shaped=%s\n' "$shaped"
  printf '%s\n' "$census" | grep -v '^session	' || true
  printf 'maxAgeSeconds=%s\n' "$DEMAND_MAX_AGE"
  printf 'turnsAveraged=%s\n' "$DEMAND_TURNS"
  printf 'sessions{sessionId,parkedAtEpoch,parkedAgeSeconds,turnsObserved,avgInputTokensPerTurn}:\n'
  while IFS= read -r row; do
    case "$row" in
      session$'\t'*) ;;
      *) continue ;;
    esac
    IFS=$'\t' read -r _ session epoch age turns average <<< "$row"
    printf '  %s,%s,%s,%s,%s\n' "$session" "$epoch" "$age" "$turns" "$average"
  done <<< "$census"
}

action_gate() {
  local store
  store=$(launch_store) || exit $?
  if ! store_is_shaped "$store"; then
    printf 'admitted: %s (store %s is not shaped by this home)\n' "$TASK_ID" "$store"
    return 0
  fi
  resolve_store_state "$store"
  ensure_store_dir
  fm_lock_acquire_wait "$LOCK" || die_evidence "the release-shaping lock for $store could not be taken"
  # shellcheck disable=SC2064  # $LOCK is fixed by the time the trap is armed.
  trap "fm_lock_release '$LOCK'" EXIT

  # Record the request BEFORE deciding, so an evidence refusal below still
  # leaves the work durable rather than dropping it on the floor.
  queue_enqueue "$TASK_ID" "$PRIORITY" "$REASON"
  evaluate "$TASK_ID" "$PRIORITY"

  # Only committed parked demand refreshes the record, never the horizon branch
  # that reads it: shaping must expire DEMAND_HORIZON after the demand clears,
  # rather than being held armed forever by the gate calls it is pacing.
  if [ "$DECISION_PARKED" -gt 0 ]; then
    write_record "$ARMED_SINCE" "$(date +%s)"$'\n'
  fi
  if [ "$DECISION" = admit ]; then
    queue_remove "$TASK_ID"
    write_record "$LAST_RELEASE" "$(date +%s)"$'\t'"$TASK_ID"$'\n'
    rm -f -- "$REPORTED"
    printf 'admitted: %s (%s)\n' "$TASK_ID" "$DECISION_MESSAGE"
    return 0
  fi
  printf 'withheld: %s (%s)\n' "$TASK_ID" "$DECISION_MESSAGE" >&2
  printf '          the request is held in %s and released when the slot opens; nothing was cancelled\n' "$QUEUE" >&2
  return 1
}

action_check() {
  local store
  store=$(launch_store) || exit $?
  if ! store_is_shaped "$store"; then
    printf 'admitted: %s (store %s is not shaped by this home)\n' "$TASK_ID" "$store"
    return 0
  fi
  resolve_store_state "$store"
  evaluate "$TASK_ID" "$PRIORITY"
  if [ "$DECISION" = admit ]; then
    printf 'admitted: %s (%s)\n' "$TASK_ID" "$DECISION_MESSAGE"
    return 0
  fi
  printf 'withheld: %s (%s)\n' "$TASK_ID" "$DECISION_MESSAGE" >&2
  return 1
}

action_withdraw() {
  local store
  store=$(launch_store) || exit $?
  store_is_shaped "$store" || { printf 'withdrawn: %s (store %s is not shaped by this home)\n' "$TASK_ID" "$store"; return 0; }
  resolve_store_state "$store"
  [ -d "$STORE_DIR" ] || { printf 'withdrawn: %s (nothing was waiting)\n' "$TASK_ID"; return 0; }
  fm_lock_acquire_wait "$LOCK" || die_evidence "the release-shaping lock for $store could not be taken"
  # shellcheck disable=SC2064  # $LOCK is fixed by the time the trap is armed.
  trap "fm_lock_release '$LOCK'" EXIT
  queue_remove "$TASK_ID"
  rm -f -- "$REPORTED"
  printf 'withdrawn: %s\n' "$TASK_ID"
}

action_queue() {
  local store census last row epoch priority id reason sorted
  store=$(launch_store) || exit $?
  printf 'store=%s\n' "$store"
  if ! store_is_shaped "$store"; then
    printf 'shaped=no\n'
    return 0
  fi
  printf 'shaped=yes\n'
  resolve_store_state "$store"
  census=$(demand_census "$store") || exit $?
  printf 'parkedSessions=%s\n' "$(census_value "$census" parkedSessions)"
  printf 'floorInputTokens=%s\n' "$(census_value "$census" floorInputTokens)"
  printf 'releaseIntervalSeconds=%s\n' "$RELEASE_INTERVAL"
  last=$(read_epoch_record "$LAST_RELEASE") || exit $?
  printf 'lastReleaseEpoch=%s\n' "${last:-none}"
  sorted=$(sorted_queue) || exit $?
  printf 'waiting{enqueuedEpoch,priority,taskId,reason}:\n'
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r epoch priority id reason <<< "$row"
    printf '  %s,%s,%s,%s\n' "$epoch" "$priority" "$id" "$reason"
  done <<< "$sorted"
}

# The watcher's poll. Silent unless firstmate should act, and never repeats one
# release slot: the report record retires when the head changes or a release
# happens. Silent-and-cheap when nothing waits, so the census never runs on the
# ordinary cycle.
# The watcher reads this verb's STDOUT and discards its stderr, so an evidence
# refusal that only writes stderr leaves a stuck queue invisible to firstmate
# forever. EVERY refusal reachable from a poll is therefore pre-captured and
# reported as the one wake line before the status is preserved for a direct
# caller: the poll still releases nothing on bad evidence, it just says so where
# firstmate can see it. The reason leads the line because fm_cap_line cuts the
# tail, and the report record retires the repeat the same way a release slot
# does - except before a store is resolved, where there is no record to write
# and writing one would give an unlisted store state it must never take.
poll_refuse() {  # <status> <reason>
  local status=$1 reason=$2 stamp=evidence-refusal record
  reason=${reason#fm-claude-admission: }
  reason=${reason//$'\n'/ }
  [ -n "$reason" ] || reason="its durable evidence could not be read"
  if [ -n "$STORE_DIR" ]; then
    record=$REPORTED
  else
    # A refusal that fires before any store could be resolved has no per-store
    # record to retire the repeat, so it dedupes on this home's own marker
    # instead, keyed by the problem itself: a persistent misconfiguration wakes
    # firstmate once, and a different one wakes it again.
    record=$HOME_REFUSAL
    stamp=$reason
  fi
  if [ -f "$record" ] && [ "$(cat -- "$record" 2>/dev/null)" = "$stamp" ]; then
    exit "$status"
  fi
  fm_cap_line "claude admission: $reason; no Claude worker is released${SLUG:+ onto $SLUG} until that is repaired"
  if [ -n "$STORE_DIR" ]; then
    [ -d "$STORE_DIR" ] && write_record "$REPORTED" "$stamp"
  elif (umask 077; mkdir -p "$ADMISSION_ROOT") 2>/dev/null; then
    printf '%s\n' "$stamp" > "$HOME_REFUSAL" 2>/dev/null || true
  fi
  exit "$status"
}

action_poll() {
  local store head_row head priority waiting stamp line sorted last armed
  local shaped shaped_status census parked slug
  # A home that lists no shaped store has nothing to do here and is never a
  # fault, so it stays silent even when this environment could not name a store
  # at all. Past that point, "cannot tell" is a refusal firstmate must hear.
  # The home-scoped refusal marker is retired the moment its condition no longer
  # holds, on every one of these exits: a refusal that clears and later recurs
  # must wake firstmate again rather than matching a stale stamp forever.
  if [ ! -f "$CONFIG" ] || [ -L "$CONFIG" ]; then
    rm -f -- "$HOME_REFUSAL"
    return 0
  fi
  store=$(launch_store 2>&1) || poll_refuse "$?" "$store"
  shaped=$(store_is_shaped "$store" 2>&1); shaped_status=$?
  case "$shaped_status" in
    0|1) rm -f -- "$HOME_REFUSAL" ;;
    *) poll_refuse "$shaped_status" "$shaped" ;;
  esac
  [ "$shaped_status" -eq 0 ] || return 0
  slug=$(store_slug "$store" 2>&1) || poll_refuse "$?" "$slug"
  resolve_store_state "$store"
  [ -d "$STORE_DIR" ] || return 0
  sorted=$(sorted_queue 2>&1) || poll_refuse "$?" "$sorted"
  head_row=$(printf '%s\n' "$sorted" | head -n 1)
  [ -n "$head_row" ] || return 0
  armed=$(read_epoch_record "$ARMED_SINCE" 2>&1) || poll_refuse "$?" "$armed"
  last=$(read_epoch_record "$LAST_RELEASE" 2>&1) || poll_refuse "$?" "$last"
  census=$(demand_census "$STORE" 2>&1) || poll_refuse "$?" "$census"
  parked=$(census_value "$census" parkedSessions)
  case "$parked" in
    ''|*[!0-9]*) poll_refuse 3 "the committed-demand census for $STORE returned no readable parked-session count" ;;
  esac
  IFS=$'\t' read -r _ priority head _ <<< "$head_row"
  waiting=$(printf '%s\n' "$sorted" | grep -c '' || true)
  evaluate "$head" "$priority" "$census"
  [ "$DECISION" = admit ] || return 0
  stamp="$head:$last"
  if [ -f "$REPORTED" ] && [ "$(cat -- "$REPORTED" 2>/dev/null)" = "$stamp" ]; then
    return 0
  fi
  ensure_store_dir
  write_record "$REPORTED" "$stamp"
  line="claude admission: $waiting task(s) waiting on $SLUG; $head can be released now"
  fm_cap_line "$line"
}

# --- check shim -------------------------------------------------------------

shim_content() {  # <resolved-home>
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-claude-admission.sh - Claude release-shaping poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-claude-admission.sh") poll"
}

SHIM_WRITE_TMP=

shim_write() {  # <wanted-content>
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-claude-admission-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# An unregistered shim is not inert: the watcher rejects it every cycle and
# wakes firstmate about unauthenticated state checks. So a failed arm leaves the
# home either armed with a bound shim or plainly unarmed, never in between.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-claude-admission: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -f "$CONFIG" ]; then
    printf 'fm-claude-admission: no shaped-store list at %s; nothing to poll for\n' "$CONFIG" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-claude-admission: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-claude-admission: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-claude-admission: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

# --- dispatch ---------------------------------------------------------------

VERB=${1:-}
case "$VERB" in
  -h|--help) usage; exit 0 ;;
  '') die_usage "a verb is required" ;;
esac
shift

case "$VERB" in
  demand) parse_store_arg demand "$@"; action_demand ;;
  gate) parse_task_args gate "$@"; action_gate ;;
  check) parse_task_args check "$@"; action_check ;;
  withdraw) parse_task_args withdraw "$@"; action_withdraw ;;
  queue) parse_store_arg queue "$@"; action_queue ;;
  poll) [ "$#" -eq 0 ] || die_usage "poll takes no arguments"; action_poll ;;
  arm) [ "$#" -eq 0 ] || die_usage "arm takes no arguments"; action_arm ;;
  disarm) [ "$#" -eq 0 ] || die_usage "disarm takes no arguments"; action_disarm ;;
  *) die_usage "unknown verb: $VERB" ;;
esac
