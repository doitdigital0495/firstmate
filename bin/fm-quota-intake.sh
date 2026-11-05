#!/usr/bin/env bash
# Quota intake: the mandatory pre-spawn usage-limit read every Firstmate
# dispatch must run before launching, relaunching, or moving a worker or
# second mate onto a model or account.
#
# Usage:
#   fm-quota-intake.sh                  (same as: record)
#   fm-quota-intake.sh record
#     Runs quota-axi --full for this home's DEFAULT credential stores (the
#     configured worker account pin's root for Claude and Pi when one is set,
#     exactly the store fm-spawn and fm-control relaunch resolve) and for
#     every enabled account store in config/accounts.json (fm_account_stores in
#     bin/fm-account-lib.sh), with CLAUDE_CONFIG_DIR, PI_CODING_AGENT_DIR, and
#     CODEX_HOME pinned to each entry's stores. One private (0600) timestamped
#     record is written under state/quota-intake/ listing, per account and
#     provider, EVERY window (5h, 7d, model-specific) as a USED percent
#     (100 minus percentRemaining; remaining is never shown alone), with its
#     reset time, plus spendPriority, runway, the plan size (accounts.json
#     plans map, else quota-axi's plan label, else unknown), and a Notes
#     column joined from config/accounts.json top-level notes (keyed by
#     provider) and config/crew-dispatch.json model_notes (provider- or
#     harness/model-keyed, e.g. claude/opus). The full table is printed so it lands in the transcript.
#     A store read that fails is recorded readStatus=failed and printed; that is
#     an unknown quota, so the script still exits 0. A rate limited read, in any
#     shape quota-axi or the machine quota gate reports one (FM_QUOTA_RATE_LIMITED_JQ
#     in bin/fm-quota-axi-lib.sh), says "rate limited", never "ok". Stores are read
#     in parallel and the whole record run ends within one FM_QUOTA_READ_DEADLINE
#     (45 second) deadline, so a hanging store delays no other: a read still
#     pending near the deadline is killed and recorded readStatus=unreadable, also
#     an unknown quota. The newest 50 records are kept.
#
#   fm-quota-intake.sh gate --harness <harness> [--model <model>]
#       [--account <id>] [--task <id>] [--claude-store <path>] [--pi-store <path>]
#       [--codex-store <path>] [--consume] [--refreshed]
#     Judges one launch from the newest record and never re-queries quota-axi.
#     Stops (exit 3, nothing else touched) only on something known: an
#     exhausted_now runway or 100%-used (0% remaining) window, naming the window
#     and its reset time; an unusable or missing login (auth_required); a harness
#     with no provider family, or an account declared for another provider; an
#     unresolvable worker pin; or, on a readable row, an undeclared plan size or
#     Notes entry.
#     An unknown quota never stops a start (captain 2026-11-05). A read that
#     failed, was unreadable or was rate limited, a provider with no rows, or a window with no
#     used percent or reset time passes as "PASS (quota unknown: <reason>)".
#     Exit 4 asks the launcher to run one fresh `record` and gate again with
#     --refreshed: no record, or a spent, stale, or unreadable one, or one that
#     does not cover the chosen account or store. With --refreshed the launcher
#     has already done that, so those cases also pass as quota unknown.
#     On a measured pass (exit 0) the chosen candidate's full window table with
#     used percents and notes is printed; an unpublished 5h window shows as "not
#     published by provider", never a number. See "Five-hour windows" below for
#     how an idle, unreadable, or reset-less 5h window shows.
#     --consume (the launch itself, bin/fm-spawn.sh) atomically marks the record
#     spent, so every launch needs its own read; without it the gate is a preview
#     that marks nothing. A consuming pass on an unverified reading (quota
#     unknown, or a reused or stale row) appends one "started on unverified
#     quota" line to state/quota-unverified-starts.log with the provider, reason,
#     and age of the cached reading; --task names the launch on that line.
#
# Last good reading (R11): a provider row that a read could not measure for a
#   transient reason (rate limited, stale, unavailable, or the whole read failed)
#   reuses that store's last good row from the shared cache for up to
#   FM_QUOTA_RECENT_MAX_AGE (default 86400) seconds; see fm_quota_recent_merge in
#   bin/fm-quota-axi-lib.sh. Such a provider is recorded readStatus=cached with
#   its reading age and lastRead (what the current read really returned), and
#   every window shows source=cached age=<s>. A reused exhausted row still stops
#   a start until its reset time. A credential failure (auth_required) is never
#   reused.
#
# Provider row filter: a registered account that declares `provider` in
#   config/accounts.json is recorded with that provider's rows only, so a store
#   shared by two seats (one Pi agent directory for a Codex and a Z.ai seat)
#   never shows one seat's quota under the other's name. Identical canonical
#   store triples (symlinks resolved) are read once.
#
# Five-hour windows (captain 2026-11-05): a five-hour window with a known used
#   percent and published reset counts like any other, so at its limit it stops
#   the start until that reset. An idle one (0% used, no reset) shows as "not
#   started (idle window)", one with no published reset as "no published reset,
#   does not block", and an unreadable one as "unreadable, does not block"; none
#   of those ever stops a start.
#
# Provider mapping: claude -> claude; codex, opencode -> codex; grok, kimi,
#   cursor, agy -> same; muse -> meta; omp by model prefix (openai-codex/* ->
#   codex, claude-bridge/* -> claude); pi and pi-signed by model prefix
#   (openai-codex/* and codex-native/* -> codex, zai/* -> zai), matching the
#   Pi task-worker launch contract in bin/fm-spawn.sh. A harness or model
#   whose family cannot be established is refused, never guessed around.
#
# TEST-HARNESS ESCAPE HATCH (FM_QUOTA_INTAKE_TEST_BYPASS=1): firstmate's own
#   test suite exports this from tests/lib.sh - exactly like
#   FM_GATE_REFUSE_BYPASS for bin/fm-gate-refuse-lib.sh - because that suite
#   drives the real fm-spawn thousands of times without provisioning quota
#   stores. A confused gate agent never inherits it. It is never a production
#   bypass: a workspace where this variable is set for the dispatching
#   firstmate is a misconfigured test rig, not a home.
#
# Environment:
#   FM_HOME / FM_ROOT_OVERRIDE / FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE - home
#     resolution, same defaults as bin/fm-spawn.sh.
#   FM_QUOTA_INTAKE_MAX_AGE seconds (600) - record freshness for the gate.
#   FM_QUOTA_RECENT_MAX_AGE seconds (86400) - last good reading reuse bound.
#   FM_QUOTA_READ_DEADLINE seconds (45) - deadline on one whole record run.
#   FM_QUOTA_INTAKE_KEEP records (50) - record retention count.
#   FM_QUOTA_INTAKE_TEST_BYPASS=1 - see above.
#
# This script keeps quota-axi data-only: it records and enforces evidence, it
# never ranks candidates (bin/fm-quota-choose.sh, fm-dispatch-resolve.sh, and
# the quota-array-dispatch skill own selection). Windows and semantics come
# from `quota-axi --full --json` because a machine-readable capture is the
# only way to store every window verbatim; no economics are recomputed here.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 2
# shellcheck source=bin/fm-account-lib.sh
. "$SCRIPT_DIR/fm-account-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
INTAKE_DIR=$STATE/quota-intake
MAX_AGE=${FM_QUOTA_INTAKE_MAX_AGE:-600}
UNVERIFIED_LOG=$STATE/quota-unverified-starts.log
KEEP=${FM_QUOTA_INTAKE_KEEP:-50}
SCHEMA_VERSION=2

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
refuse() { printf '%s\n' "$1"; exit 3; }
# The record itself is missing, spent, stale, unreadable, or does not cover the
# chosen account or store: a fresh `record` run is what cures it, so the gate
# says so with its own exit status and bin/fm-spawn.sh can run that intake once
# and gate again. Once that has happened (--refreshed) nothing more can be
# learned, which makes it an unknown quota, never a refusal.
GATE_REFRESHED=0 GATE_CONSUME=0 GATE_RECORD='' GATE_PROVIDER='' GATE_ACCOUNT='' GATE_MODEL='' GATE_TASK=''
refresh() { # <message> <short reason>
  [ "$GATE_REFRESHED" -eq 0 ] || gate_pass_unknown "$2"
  printf '%s\n' "$1"
  exit 4
}

# The one "started on unverified quota" line per launch: printed, and appended
# to the log only by the consuming gate, so a preview never counts as a start.
gate_log_unverified() { # <reason> [cached-reading-age-seconds]
  local reason age_text=none line
  [ "$GATE_CONSUME" -eq 1 ] || return 0
  reason=$(printf '%s' "$1" | tr -s '\t\r\n' ' ')
  [ -z "${2:-}" ] || age_text=${2}s
  line="started on unverified quota provider=$GATE_PROVIDER account=$GATE_ACCOUNT model=$GATE_MODEL task=${GATE_TASK:-unknown} age=$age_text reason=$reason"
  printf '%s\n' "$line"
  mkdir -p -- "$STATE" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$UNVERIFIED_LOG" 2>/dev/null ||
    printf 'warning: could not append to %s\n' "$UNVERIFIED_LOG" >&2
}

gate_pass_unknown() { # <reason> [cached-reading-age-seconds]
  printf 'quota-intake gate: PASS (quota unknown: %s; starting anyway) account=%s provider=%s model=%s\n' \
    "$1" "$GATE_ACCOUNT" "$GATE_PROVIDER" "$GATE_MODEL"
  if [ "$GATE_CONSUME" -eq 1 ] && [ -n "$GATE_RECORD" ]; then
    ( set -C; : > "$GATE_RECORD.spent" ) 2>/dev/null || true
  fi
  gate_log_unverified "$1" "${2:-}"
  exit 0
}

intake_list_records() { # one path per line, oldest first
  local f
  for f in "$INTAKE_DIR"/quota-*.json; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

usage() { sed -n '2,83p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# jq parses the record in every mode. quota-axi is only the live reader the
# record mode drives, and a host without it simply records failed reads.
command -v jq >/dev/null 2>&1 || die "jq not installed"
[ -n "${HOME:-}" ] || die "HOME must be set"

# The store a harness's gate checks when the caller passed no explicit store:
# exactly the resolution the launching scripts use, kept in one place so the
# record and the gate can never disagree about a default.
intake_default_store() { # <claude|pi|codex>
  local selection root
  case "$1" in
    claude|pi)
      selection=$(fm_worker_account_resolve "$1" "$CONFIG") || return 1
      if [ -n "$selection" ]; then
        root=${selection#*$'\t'}
        root=${root%%$'\t'*}
        printf '%s\n' "${root:-$HOME/.claude}"
        return 0
      fi ;;
  esac
  case "$1" in
    claude) printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    pi)     printf '%s\n' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" ;;
    codex)  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}" ;;
    *)      return 1 ;;
  esac
}

# A launch may pin its store through a symlink onto the store the record read
# (a retired link name still resolving onto the registered store), so store
# coverage compares the resolved real paths: a symlinked store equals its
# target. A path realpath cannot resolve - a missing tool, or a store an
# account does not own - compares as itself, which is the literal comparison.
intake_store_real() { # <path> - stdout: resolved real path, or the input
  realpath -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

# Run as a background job, so `exec` makes the job's pid the bounded runner itself.
quota_axi_full_json() { # <stores> <seconds> - stdout: raw --full --json snapshot
  local stores=$1 seconds=$2 runner=()
  if command -v timeout >/dev/null 2>&1; then
    runner=(timeout -k 1 "$seconds")
  elif command -v python3 >/dev/null 2>&1; then
    runner=(python3 "$SCRIPT_DIR/fm-dispatch-bounded.py" "$(( $(date +%s) + seconds ))")
  fi
  CLAUDE_CONFIG_DIR=$(fm_account_read_store claude "$(printf '%s\n' "$stores" | sed -n 1p)") \
  PI_CODING_AGENT_DIR=$(fm_account_read_store pi "$(printf '%s\n' "$stores" | sed -n 2p)") \
  CODEX_HOME=$(fm_account_read_store codex "$(printf '%s\n' "$stores" | sed -n 3p)") \
    exec "${runner[@]}" quota-axi --full --json </dev/null 2>/dev/null
}

# The part of the deadline reads may use: the rest is what killing a read that
# ignores its stop signal and writing the record need, so the whole run ends in time.
intake_read_seconds() {
  local margin=$(( FM_QUOTA_READ_DEADLINE / 3 ))
  [ "$margin" -le 3 ] || margin=3
  printf '%s\n' "$(( FM_QUOTA_READ_DEADLINE - margin ))"
}

# Wait for the read jobs, killing any still alive at <kill-epoch>. The runner has
# already stopped them by then, so this only acts on a host with neither timeout
# nor python3, or on a runner that itself hung.
intake_settle_reads() { # <kill-epoch> <pid>...
  local kill_at=$1 pid alive
  shift
  while :; do
    alive=
    for pid in "$@"; do
      if kill -0 "$pid" 2>/dev/null; then alive="$alive $pid"; fi
    done
    [ -n "$alive" ] || return 0
    if [ "$(intake_epoch_now)" -ge "$kill_at" ]; then
      for pid in $alive; do kill -KILL "$pid" 2>/dev/null || true; done
      return 0
    fi
    sleep 0.2
  done
}

# epoch helpers: pure bash arithmetic plus one UTC date probe for display only.
intake_epoch_now() { date -u +%s; }
intake_epoch_utc() { # <epoch> <date-format> - GNU then BSD date (format without the +)
  local epoch=$1 fmt=$2
  [ "$epoch" -gt 0 ] || return 1
  date -u -d "@$epoch" "+$fmt" 2>/dev/null || date -u -r "$epoch" "+$fmt" 2>/dev/null
}

# Plans declared in config/accounts.json: the account's own map first, then
# the top-level (personal/default) map, exactly as fm-dispatch-resolve.sh
# resolves plan labels.
intake_plan_map() { # stdout: {"default":{...},"<account>":{...}} or {}
  if fm_account_registry_valid "$CONFIG/accounts.json"; then
    jq -c 'def plans: if type == "object" then . else {} end;
           {default: (.plans | plans), accounts: (.accounts | with_entries(.value = (.value.plans | plans)))}' \
      "$CONFIG/accounts.json"
  else
    printf '{}'
  fi
}

# Notes column sources: config/accounts.json top-level `notes` keyed by
# provider, and config/crew-dispatch.json `model_notes` keyed by provider or
# harness-scoped model string (claude/opus, pi/openai-codex/gpt-6-luna).
# Bare provider keys from both sources join into the provider's Notes string;
# every key containing "/" is a model note, grouped verbatim under the
# provider its harness family names (a leading pi/ segment is skipped), so the
# gate can append the chosen model's own note. A missing or unreadable file
# contributes nothing.
intake_notes_map() { # stdout: {"providers":{...},"models":{"<provider>":{...}}}
  local acct dispatch
  acct=$(jq -c '.notes // {}' "$CONFIG/accounts.json" 2>/dev/null) || acct=''
  dispatch=$(jq -c '.model_notes // {}' "$CONFIG/crew-dispatch.json" 2>/dev/null) || dispatch=''
  case "${acct:-}" in ''|*[![:print:]]*) acct='{}' ;; esac
  case "${dispatch:-}" in ''|*[![:print:]]*) dispatch='{}' ;; esac
  jq -c -n --argjson a "$acct" --argjson d "$dispatch" '
    def txt($v): if ($v | type) == "string" and ($v | length) > 0 then $v else null end;
    ($a | with_entries(select(.value | txt(.) != null)) | map_values(txt(.))) as $a |
    ($d | with_entries(select(.value | txt(.) != null)) | map_values(txt(.))) as $d |
    def family: split("/") | (if .[0] == "pi" then .[1:] else . end) |
      ({"claude": "claude", "codex": "codex", "openai-codex": "codex", "zai": "zai"}[.[0] // ""] // null);
    (($a | keys) + ($d | keys) | map(select(contains("/") | not))
      | reduce .[] as $k ([]; if (. | index($k)) then . else . + [$k] end)) as $prov |
    {providers: (reduce $prov[] as $k ({};
             . + {($k): ([($a[$k] // null), ($d[$k] // null)]
                   | map(select(. != null)) | join(" | "))})),
     models: (reduce (($a + $d) | to_entries[] | select(.key | contains("/"))) as $e ({};
             ($e.key | family) as $f |
             if $f == null then . else .[$f] += {($e.key): $e.value} end))}'
}

intake_build_entry() { # <account> <claude> <pi> <codex> <snapshot-file> <plan-lookup-json> <notes-map-json> [<provider>]
  local account=$1 claude=$2 pi=$3 codex=$4 snap=$5 planarg=$6 notesarg=$7 only=${8:-}
  jq -c -n --arg account "$account" --arg claude "$claude" --arg pi "$pi" --arg codex "$codex" \
    --slurpfile snapshot "$snap" --argjson planarg "$planarg" --argjson notes "$notesarg" --arg only "$only" "$FM_QUOTA_RATE_LIMITED_JQ"'
    ($snapshot[0]) as $s |
    def plan_label($v): if ($v | type) == "string" and ($v | length) > 0 and ($v | length) <= 80 and ($v | test("^[[:print:]]+$")) then $v else null end;
    def used_of($rem; $u):
      if ($rem | type) == "number" then (100 - $rem)
      elif (($u // null) | type) == "number" then $u
      else null end;
    {
      account: $account,
      readStatus: "ok",
      stores: {claude: $claude, pi: $pi, codex: $codex},
      providers: [ $s.providers[]? | select($only == "" or .provider == $only) |
        . as $p |
        ($p | read_rate_limited) as $limited |
        ($p.reusedReading.lastRead // (if $p.reusedReading != null and $limited then "rate_limited" else null end)) as $last |
        ([$p.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models" or .scope == "all_products")] | first) as $wide |
        ($planarg[$p.provider].plan // null) as $declared |
        (plan_label($p.plan)) as $qp |
        {
          provider: $p.provider,
          readStatus: (if $p.reusedReading != null then "cached"
                       elif $limited then "rate_limited"
                       elif (["rate_limited", "stale", "unavailable", "error", "auth_required"] | index($p.state.status // "")) != null then $p.state.status
                       else "ok" end),
          readingAgeSeconds: ($p.reusedReading.ageSeconds // null),
          lastRead: $last,
          state: {status: ($last // (if $limited then "rate_limited" else null end) // $p.state.status // $p.quotaSemantics.status // null),
                  error: ($p.state.error // null), retryAfter: ($p.state.retryAfter // null)},
          plan: (if $declared != null then $declared elif $qp != null then $qp else "unknown" end),
          planSource: (if $declared != null then $planarg[$p.provider].source elif $qp != null then "quota-axi" else "unknown" end),
          quotaAxiPlan: ($qp // "none"),
          spendPriority: ($wide.selection.spendPriority // null),
          runway: ($wide.runway.status // null),
          notes: ($notes.providers[$p.provider] // ""),
          modelNotes: ($notes.models[$p.provider] // {}),
          scopes: [$p.quotaSemantics.effectiveAvailability[]? | {
            scope, status,
            effectivePercentRemaining: (.effectivePercentRemaining // null),
            effectivePercentUsed: (used_of(.effectivePercentRemaining // null; null)),
            spendPriority: (.selection.spendPriority // null),
            runway: (.runway.status // null),
            boundedBy: (.boundedBy // []),
            limitingWindowIds: (.limitingWindowIds // .runway.limitingWindowIds // []),
            unmeasurableWindowIds: (.selection.unmeasurableWindowIds // .runway.unmeasurableWindowIds // [])
          }],
          windows: [$p.windows[]? |
            {id, kind: (.kind // ""),
             percentRemaining: (.percentRemaining // null),
             percentUsed: (used_of(.percentRemaining // null; .percentUsed // null)),
             resetsAt: (.resetsAt // null)}]
        }
      ]
    } | .readStatus = (if any(.providers[]; .readStatus == "rate_limited" or .lastRead == "rate_limited") then "rate_limited" else "ok" end)'
}

# Per-provider declared plans for one account, resolved from the plan map.
intake_plan_lookup() { # <plan-map-json> <account> <provider-ids-json>
  jq -c -n --argjson m "$1" --arg a "$2" --argjson ids "$3" '
    ($m.accounts[$a] // {}) as $own | ($m.default // {}) as $top |
    reduce ($ids[]) as $p ({};
      . + {($p): (if $own[$p] then {plan: $own[$p], source: ("accounts.json:" + $a)}
                  elif $top[$p] then {plan: $top[$p], source: "accounts.json"}
                  else {plan: null, source: null} end)})'
}

intake_print_record() { # <record-json> - full table to stdout
  jq -r '
    def pct($v): if ($v | type) == "number" then "\($v)%" else "unknown" end;
    def used($v): if ($v | type) == "number" then "\($v)%" else "unknown" end;
    def words: gsub("_"; " ");
    "quota-intake recordedAt=\(.recordedAt) record=\(.record)",
    (.accounts[] | . as $a |
      "account=\(.account) status=\(.readStatus | words) claude=\(.stores.claude) pi=\(.stores.pi) codex=\(.stores.codex)",
      (.providers[]? | . as $p | ($p.readStatus) as $ps |
        ($p.spendPriority // "unknown") as $sp |
        ($p.runway // "unknown") as $rw |
        "  provider=\($p.provider) status=\($ps | words)\(if $ps == "cached" then " age=\($p.readingAgeSeconds // "unknown")s lastRead=\(($p.lastRead // "unknown") | words)" else "" end) plan=\($p.plan) (\($p.planSource)) quota-axi=\($p.quotaAxiPlan) spendPriority=\($sp) runway=\($rw) notes=\($p.notes // "")",
        (($p.modelNotes // {}) | to_entries[] | "    model=\(.key) notes=\(.value)"),
        ($p.windows[]? | . as $w | ($w.resetsAt // "unknown") as $rs |
          (if $ps == "cached" then "cached age=\($p.readingAgeSeconds // "unknown")s" elif $ps == "rate_limited" then "rate limited" else "live" end) as $src |
          "    window=\($w.id) used=\(used($w.percentUsed)) resets=\($rs) source=\($src)")),
      (select($a.readStatus == "failed" or $a.readStatus == "unreadable") | ($a.error // "unknown error") as $err |
        "  read \($a.readStatus): \($err)"))
  '
}

cmd_record() {
  # tmp stays a global: the EXIT trap must still see it after this function
  # returns, and set -u would otherwise trip on the lost local.
  tmp=$(mktemp -d) || die "mktemp failed"
  local entries default_stores plan_map account stores key canon_text snap raw entry now ns name file
  local total sc sp sx recent only read_end left read_status last_read read_error i
  local -a canon=()
  local -a accounts=() listed=() listed_stores=() listed_canon=() listed_keys=() read_pids=() read_keys=()
  trap 'rm -rf -- "$tmp"' EXIT

  { sc=$(intake_default_store claude) && sp=$(intake_default_store pi) && sx=$(intake_default_store codex); } ||
    die "the configured worker account pin (config/claude-account or config/pi-account) cannot be resolved"
  default_stores=$sc$'\n'$sp$'\n'$sx
  plan_map=$(intake_plan_map)
  notes_map=$(intake_notes_map)

  # Default store first, then every registered account store when this home's
  # cross-account routing is enabled; identical store triples read once.
  accounts=(default)
  if fm_account_enabled "$CONFIG/accounts.json"; then
    while IFS= read -r account; do
      [ -n "$account" ] || continue
      accounts+=("$account")
    done < <(jq -r '.accounts | keys[]' "$CONFIG/accounts.json" 2>/dev/null | sort)
  fi

  read_end=$(( $(intake_epoch_now) + $(intake_read_seconds) ))
  for account in "${accounts[@]}"; do
    if [ "$account" = default ]; then
      stores=$default_stores
    else
      stores=$(fm_account_stores "$CONFIG/accounts.json" "$account") || {
        printf 'warning: account %s stores could not be resolved; the record will not cover it\n' "$account" >&2
        continue
      }
    fi
    # One read per canonical store triple: a symlinked alias reads once.
    canon_text=$(printf '%s\n' "$stores" | while IFS= read -r one; do
      if [ "$one" = "$FM_ACCOUNT_NO_STORE" ]; then printf '%s\n' "$one"; else fm_account_canonical_store "$one"; fi
    done)
    key=$(printf '%s\n' "$canon_text" | cksum | tr -d ' ')
    listed+=("$account")
    listed_stores+=("$stores")
    listed_canon+=("$canon_text")
    listed_keys+=("$key")
    [ ! -e "$tmp/raw-$key" ] || continue
    : > "$tmp/raw-$key"
    left=$(( read_end - $(intake_epoch_now) ))
    [ "$left" -gt 0 ] || left=1
    quota_axi_full_json "$stores" "$left" > "$tmp/raw-$key" 2>/dev/null &
    read_pids+=("$!")
    read_keys+=("$key")
  done

  # Every read is running; none of them waits on another. Stderr is closed off
  # here because the shell reports a killed job on it whenever it notices one.
  {
    intake_settle_reads "$(( read_end + 2 ))" "${read_pids[@]}"
    for i in "${!read_pids[@]}"; do
      wait "${read_pids[$i]}"
      case $? in
        124|137) : > "$tmp/pending-${read_keys[$i]}" ;;
      esac
    done
  } 2>/dev/null

  recent=$(fm_quota_recent_file "$STATE")
  entries='[]'
  for i in "${!listed[@]}"; do
    account=${listed[$i]}
    stores=${listed_stores[$i]}
    key=${listed_keys[$i]}
    mapfile -t canon <<< "${listed_canon[$i]}"
    snap="$tmp/snap-$key.json"
    raw="$tmp/raw-$key"
    read_status=failed
    last_read=read_failed
    read_error="quota-axi --full --json failed or invalid for this store"
    if [ -e "$tmp/pending-$key" ]; then
      read_status=unreadable
      last_read=unreadable
      read_error="the ${FM_QUOTA_READ_DEADLINE}s quota read deadline expired"
    fi
    if [ ! -f "$snap" ] && [ ! -e "$tmp/judged-$key" ]; then
      : > "$tmp/judged-$key"
      # Judge the report, not the exit status: quota-axi exits 1 with a full
      # report when every provider failed, and that report is what names a
      # signed-out login. Calling it a failed read would start on a bad login.
      if fm_quota_json_valid < "$raw"; then
        fm_quota_recent_save "$recent" "$raw" "${canon[0]}" "${canon[1]}" "${canon[2]}"
        if fm_quota_recent_merge "$recent" "$raw" "${canon[0]}" "${canon[1]}" "${canon[2]}" > "$snap.merged" 2>/dev/null && fm_quota_json_valid < "$snap.merged"; then
          mv -- "$snap.merged" "$snap"
        else
          mv -- "$raw" "$snap"
        fi
      elif fm_quota_recent_merge "$recent" "" "${canon[0]}" "${canon[1]}" "${canon[2]}" "$last_read" > "$snap.merged" 2>/dev/null && fm_quota_json_valid < "$snap.merged"; then
        mv -- "$snap.merged" "$snap"
      fi
      rm -f -- "$snap.merged"
    fi
    if [ ! -f "$snap" ]; then
      sc=$(printf '%s\n' "$stores" | sed -n 1p)
      sp=$(printf '%s\n' "$stores" | sed -n 2p)
      sx=$(printf '%s\n' "$stores" | sed -n 3p)
      entry=$(jq -cn --arg account "$account" --arg status "$read_status" \
          --arg claude "$sc" --arg pi "$sp" --arg codex "$sx" \
          --arg error "$read_error" '{
          account: $account, readStatus: $status,
          stores: {claude: $claude, pi: $pi, codex: $codex}, error: $error, providers: []}')
      entries=$(jq -cn --argjson all "$entries" --argjson one "$entry" '$all + [$one]')
      continue
    fi
    only=
    [ "$account" = default ] || only=$(fm_account_provider "$CONFIG/accounts.json" "$account")
    entry=$(intake_build_entry "$account" \
      "$(printf '%s\n' "$stores" | sed -n 1p)" "$(printf '%s\n' "$stores" | sed -n 2p)" "$(printf '%s\n' "$stores" | sed -n 3p)" \
      "$snap" "$(intake_plan_lookup "$plan_map" "$account" "$(jq -c '[.providers[].provider]' "$snap")")" "$notes_map" "$only")
    entries=$(jq -cn --argjson all "$entries" --argjson one "$entry" '$all + [$one]')
  done

  now=$(intake_epoch_now)
  ns=$(date -u +%N)
  case "$ns" in ''|*[!0-9]*) ns=000000000 ;; esac
  name=$(printf 'quota-%s-%s-%s.json' "$now" "$ns" "$$")
  file=$INTAKE_DIR/$name
  mkdir -p -- "$INTAKE_DIR" || die "could not create $INTAKE_DIR"
  umask 077
  jq -cn --argjson schema "$SCHEMA_VERSION" --arg at "$(intake_epoch_utc "$now" '%Y-%m-%dT%H:%M:%SZ' || printf '%s' "$now")" \
    --argjson epoch "$now" --arg name "$name" --argjson accounts "$entries" \
    '{schemaVersion: $schema, recordedAt: $at, recordedAtEpoch: $epoch, record: $name, accounts: $accounts}' \
    > "$file" || { rm -f -- "$file"; die "could not write the intake record"; }
  chmod 600 "$file"
  total=$(intake_list_records | wc -l)
  if [ "$total" -gt "$KEEP" ]; then
    intake_list_records | head -n $(( total - KEEP )) | while IFS= read -r old; do
      rm -f -- "$old" "$old.spent"
    done
  fi

  intake_print_record < "$file"
}

# Gate -------------------------------------------------------------------------

gate_provider_for_harness() { # <harness> [model] - stdout: provider id; rc 1 unmappable
  local harness=${1:-} model=${2:-} prefix
  case "$harness" in
    claude) printf 'claude\n' ;;
    codex | opencode) printf 'codex\n' ;;
    grok | kimi | cursor | agy) printf '%s\n' "$harness" ;;
    muse) printf 'meta\n' ;;
    omp)
      case "$model" in
        openai-codex/*) printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *) return 1 ;;
      esac
      ;;
    pi | pi-signed)
      prefix=${model%%/*}
      case "$prefix" in
        openai-codex | codex-native) printf 'codex\n' ;;
        zai) printf 'zai\n' ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

cmd_gate() {
  local harness='' model=default account='' claude_store='' pi_store='' codex_store='' consume=0 arg
  while [ $# -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --consume) consume=1 ;;
      --refreshed) GATE_REFRESHED=1 ;;
      --task) [ $# -gt 0 ] || die "--task needs a value"; GATE_TASK=$1; shift ;;
      --harness) [ $# -gt 0 ] || die "--harness needs a value"; harness=$1; shift ;;
      --model) [ $# -gt 0 ] || die "--model needs a value"; model=${1:-default}; shift ;;
      --account) [ $# -gt 0 ] || die "--account needs a value"; account=$1; shift ;;
      --claude-store) [ $# -gt 0 ] || die "--claude-store needs a value"; claude_store=$1; shift ;;
      --pi-store) [ $# -gt 0 ] || die "--pi-store needs a value"; pi_store=$1; shift ;;
      --codex-store) [ $# -gt 0 ] || die "--codex-store needs a value"; codex_store=$1; shift ;;
      *) die "unknown gate argument: $arg" ;;
    esac
  done
  [ -n "$harness" ] || die "gate requires --harness"
  [ -n "$account" ] || account=default

  # Test-suite escape hatch, documented in the header: never a production path.
  if [ "${FM_QUOTA_INTAKE_TEST_BYPASS:-}" = 1 ]; then
    printf 'quota-intake gate: TEST BYPASS (FM_QUOTA_INTAKE_TEST_BYPASS=1); no record was checked\n'
    exit 0
  fi

  local provider record now age covered entry store_field chosen expected recorded spent_msg declared=''
  provider=$(gate_provider_for_harness "$harness" "$model") ||
    refuse "quota intake gate: refusing - no quota provider family can be established for harness '$harness' with model '$model'; declare the provider family in the dispatch profile or dispatch a measurable harness"
  GATE_CONSUME=$consume GATE_PROVIDER=$provider GATE_ACCOUNT=$account GATE_MODEL=$model
  record=$(intake_list_records | tail -n 1)
  [ -n "$record" ] || refresh "quota intake gate: refusing - no intake record exists under $INTAKE_DIR; run bin/fm-quota-intake.sh first and re-check every usage limit" "no intake record could be written"
  spent_msg="quota intake gate: refusing - the newest intake record $(basename -- "$record") was already spent on a launch; every launch needs its own read, so run bin/fm-quota-intake.sh now and re-check every usage limit"
  [ ! -e "$record.spent" ] || refresh "$spent_msg" "the newest intake record was already spent by a parallel launch"
  now=$(intake_epoch_now)
  age=$(jq -r --argjson now "$now" '$now - (.recordedAtEpoch // 0)' "$record" 2>/dev/null)
  case "$age" in
    ''|*[!0-9-]*) refresh "quota intake gate: refusing - the newest record is unreadable; run bin/fm-quota-intake.sh again" "the newest intake record is unreadable" ;;
  esac
  [ "$age" -le "$MAX_AGE" ] ||
    refresh "quota intake gate: refusing - the newest intake record is ${age}s old (max ${MAX_AGE}s); run bin/fm-quota-intake.sh now and re-check every usage limit" "the newest intake record is ${age}s old"

  entry=$(jq -c --arg a "$account" '[.accounts[] | select(.account == $a)] | first // empty' "$record")
  [ -n "$entry" ] || {
    covered=$(jq -r '[.accounts[].account] | join(",")' "$record")
    refresh "quota intake gate: refusing - the record does not cover account '$account' (covered: ${covered:-none}); run bin/fm-quota-intake.sh for that account's stores" "the intake record does not cover account $account"
  }
  GATE_RECORD=$record
  # The read already failed: another read inside the same lockout only re-news
  # it, so this is an unknown quota now rather than a request for a fresh read.
  case "$(jq -r '.readStatus' <<< "$entry")" in
    failed) gate_pass_unknown "the read for account $account failed: $(jq -r '.error // "unknown error"' <<< "$entry")" ;;
    unreadable) gate_pass_unknown "the read for account $account is unreadable: $(jq -r '.error // "unknown error"' <<< "$entry")" ;;
  esac

  case "$harness" in
    claude) store_field=claude ;;
    pi | pi-signed) store_field=pi ;;
    codex) store_field=codex ;;
    *) store_field= ;;
  esac
  if [ -n "$store_field" ]; then
    case "$store_field" in
      claude) chosen=$claude_store ;;
      pi) chosen=$pi_store ;;
      codex) chosen=$codex_store ;;
    esac
    if [ -z "$chosen" ] || [ "$chosen" = default ]; then
      expected=$(intake_default_store "$store_field") ||
        refuse "quota intake gate: refusing - the configured worker account pin for $store_field cannot be resolved; fix it before any launch"
    else
      expected=$chosen
    fi
    recorded=$(jq -r --arg f "$store_field" '.stores[$f]' <<< "$entry")
    [ "$(intake_store_real "$recorded")" = "$(intake_store_real "$expected")" ] ||
      refresh "quota intake gate: refusing - the record's $store_field store $recorded does not cover the chosen store $expected; run bin/fm-quota-intake.sh against the store this launch will use" "the intake record does not cover the $store_field store $expected"
  fi

  [ "$account" = default ] || declared=$(fm_account_provider "$CONFIG/accounts.json" "$account")
  local verdict
  verdict=$(jq -c --arg provider "$provider" --arg model "$model" --arg account "$account" --arg declared "$declared" '
    def bare($m): ($m | split("/") | last);
    ([.providers[] | select(.provider == $provider)] | first // null) as $p |
    (($p.state.status // "") | gsub("_"; " ")) as $read |
    def unknown($why):
      {verdict: "unknown", age: ($p.readingAgeSeconds // null),
       reason: (if (["", "fresh"] | index($read)) != null then $why else "\($read): \($why)" end)};
    if $p == null then
      if $declared != "" and $declared != $provider then
        {verdict: "refuse", reason: ("account \($account) is declared for provider \($declared), not \($provider); dispatch a seat of that provider")}
      else
        {verdict: "unknown", age: null, reason: ("no \($provider) row in the intake record for account \($account)")}
      end
    elif ($p.state.status // "") == "auth_required" then
      {verdict: "refuse",
       reason: ("the \($provider) credential on account \($account) is unusable (\($p.state.error // "auth_required")); sign that store in again or dispatch another account - this is not an unknown quota")}
    else
      [$p.scopes[]? | select(
        .scope == "all_models" or .scope == "all_products" or
        ($model != "" and $model != "default" and
          (.scope == ("model:" + bare($model)) or .scope == ("product:" + bare($model)))))] as $rows |
      ([$rows[] | (.boundedBy // [])[]] | reduce .[] as $x ([]; if (. | index($x)) then . else . + [$x] end)) as $bids |
      (if ($bids | length) == 0
       then [$p.windows[] | select((.kind // "") != "model") | .id] | reduce .[] as $x ([]; if (. | index($x)) then . else . + [$x] end)
       else $bids end) as $ids |
      ([$p.windows[] | select(.id == "five_hour" or .kind == "five_hour" or .kind == "session")] | first // null) as $w5 |
      ([$p.windows[] | select(.id == "seven_day" or .kind == "weekly")] | first // null) as $w7 |
      ([$w5, $w7] | map(select(. != null) | .id)) as $base |
      (($ids + $base) | unique) as $req |
      def win($id): ([$p.windows[] | select(.id == $id)] | first) // null;
      def reset($id): (win($id).resetsAt // null);
      def used($id):
        (win($id) as $w |
         if ($w == null) then null
         elif ($w.percentUsed | type) == "number" then $w.percentUsed
         elif ($w.percentRemaining | type) == "number" then (100 - $w.percentRemaining)
         else null end);
      # An idle 5h window (0% used, no reset because no window is open) cannot
      # be exhausted, so its missing reset does not block the launch.
      def idle5($id):
        ($w5 != null and $id == $w5.id and
         used($id) == 0 and ((win($id).resetsAt // "") | length) == 0);
      # A 5h window with no used percent or no published reset never stops a start.
      def unread5($id):
        ($w5 != null and $id == $w5.id and (idle5($id) | not) and
         (((used($id) // "x") | type) != "number" or ((win($id).resetsAt // "") | length) == 0));
      def only5_unknown($r):
        ($w5 != null and ($r.effectivePercentRemaining | type) == "number" and
         (($r.unmeasurableWindowIds // []) | length) > 0 and
         all(($r.unmeasurableWindowIds // [])[]; . == $w5.id));
      # The windows that set the limit of a row: those it names, else those
      # bounding it, narrowed to the ones with the least room left.
      def tightest($r):
        (if (($r.limitingWindowIds // []) | length) > 0 then $r.limitingWindowIds else ($r.boundedBy // []) end) as $ids |
        ([$ids[] | select(((used(.) // "x") | type) == "number")]) as $read |
        if ($read | length) == 0 then $ids
        else ($read | map(used(.)) | max) as $high | [$read[] | select(used(.) == $high)] end;
      def limit_cannot_hold($r):
        tightest($r) as $t | ($t | length) > 0 and
        all($t[]; idle5(.) or unread5(.) or (. == "five_hour" and win(.) == null));
      [$rows[] | select((.runway // "") == "exhausted_now" and (limit_cannot_hold(.) | not))] as $spent |
      [($req[] | select((idle5(.) | not) and (unread5(.) | not) and (win(.) == null or ((used(.) // "x") | type) != "number" or ((win(.).resetsAt // "") | length) == 0)))] as $unknown_ids |
      (($p.modelNotes // {}) as $mn |
       ($mn[$model] // $mn[($model | split("/") | .[0:2] | join("/"))]
        // ([$mn | to_entries[] | select(.key | endswith("/" + $model)) | .value] | first) // "")) as $mnote |
      # Anything known to be exhausted stops first, however little else is known.
      if ($spent | length) > 0 then
        ($spent | first) as $bad |
        (tightest($bad)) as $lims |
        (if ($lims | length) > 0 then $lims[0] else "" end) as $wname |
        (([$lims[]? | reset(.)] | map(select(. != null)) | first) // "an unknown time") as $rst |
        {verdict: "refuse", scope: $bad.scope,
         reason: ("\($provider) runway is exhausted_now at \($bad.scope)" +
                  (if $wname != "" then " (window \($wname))" else "" end) +
                  " resetting at \($rst)")}
      elif any($req[]; (unread5(.) | not) and (used(.) >= 100 or win(.).percentRemaining == 0)) then
        ([$req[] | select((unread5(.) | not) and (used(.) >= 100 or win(.).percentRemaining == 0))] | first) as $wid |
        (reset($wid) // "an unknown time") as $rst |
        {verdict: "refuse", window: $wid,
         reason: ("window \($wid) is at 100% used (0% remaining) and resets at \($rst); wait for the reset or dispatch another candidate")}
      # Not known to be exhausted, and not measurable: an unknown quota.
      elif ($rows | length) == 0 then
        unknown("no quota evidence rows for provider \($provider) with model \($model)")
      elif $w7 == null then
        unknown("no seven-day window for provider \($provider) on account \($account)")
      elif any($rows[]; .status != "known" and (only5_unknown(.) | not)) then
        ([$rows[] | select(.status != "known" and (only5_unknown(.) | not))] | first) as $bad |
        unknown("quota evidence is unknown at \($bad.scope) for provider \($provider)")
      elif ($req | length) == 0 then
        unknown("no window reset evidence for provider \($provider)")
      elif ($unknown_ids | length) > 0 then
        unknown("windows without a known used percent or reset time: \($unknown_ids | join(", "))")
      elif ($p.plan // "unknown") == "unknown" then
          {verdict: "refuse",
           reason: ("the plan size for provider \($provider) on account \($account) is unknown; declare it in config/accounts.json plans and re-run bin/fm-quota-intake.sh")}
        elif (($p.notes // "") == "" and $mnote == "") then
          {verdict: "refuse",
           reason: ("no notes are recorded for provider \($provider) on account \($account); declare them in config/accounts.json top-level notes or config/crew-dispatch.json model_notes and re-run bin/fm-quota-intake.sh")}
        else
          {verdict: "pass", account: $account, provider: $provider, model: $model,
           plan: $p.plan, planSource: $p.planSource,
           unverified: (if $p.readStatus == "cached" then "reused last good reading, current read: \(($p.lastRead // "unknown") | gsub("_"; " "))"
                        elif $p.readStatus != "ok" then $read else null end),
           readingAge: ($p.readingAgeSeconds // null),
           notes: ($p.notes // ""), modelNote: $mnote,
           spendPriority: ($p.spendPriority // "unknown"), runway: ($p.runway // "unknown"),
           fiveHourPublished: ($w5 != null),
           scopes: [$rows[] | {scope, status, used: (if (.effectivePercentRemaining | type) == "number" then (100 - .effectivePercentRemaining) else null end),
                               spendPriority: (.spendPriority // null), runway: (.runway // null)}],
           windows: [$req[] | {id: ., used: (used(.) // "unreadable, does not block"),
                               resetsAt: (if idle5(.) then "not started (idle window)"
                                          elif unread5(.) then (if used(.) == null then "unreadable, does not block" else "no published reset, does not block" end)
                                          else win(.).resetsAt end),
                               source: (if $p.readStatus == "cached" then "cached age=\($p.readingAgeSeconds // "unknown")s" elif $p.readStatus == "rate_limited" then "rate limited" else "live" end)}]}
      end
    end' <<< "$entry")

  if [ "$(jq -r '.verdict' <<< "$verdict")" = unknown ]; then
    gate_pass_unknown "$(jq -r '.reason' <<< "$verdict")" "$(jq -r '.age // ""' <<< "$verdict")"
  fi
  if [ "$(jq -r '.verdict' <<< "$verdict")" = pass ]; then
    if [ "$consume" -eq 1 ]; then
      ( set -C; : > "$record.spent" ) 2>/dev/null || refresh "$spent_msg" "the newest intake record was already spent by a parallel launch"
    fi
    printf 'quota-intake gate: PASS record=%s age=%ss account=%s provider=%s model=%s plan=%s (%s) spendPriority=%s runway=%s\n' \
      "$(basename -- "$record")" "$age" \
      "$(jq -r '.account' <<< "$verdict")" "$(jq -r '.provider' <<< "$verdict")" \
      "$(jq -r '.model' <<< "$verdict")" "$(jq -r '.plan' <<< "$verdict")" \
      "$(jq -r '.planSource' <<< "$verdict")" "$(jq -r '.spendPriority' <<< "$verdict")" \
      "$(jq -r '.runway' <<< "$verdict")"
    jq -r '
      def pct($v): if ($v | type) == "number" then "\($v)%" elif ($v | type) == "string" then $v else "unknown" end;
      (.scopes[]? | . as $s | ($s.spendPriority // "unknown") as $sp |
        "  scope=\($s.scope) status=\($s.status) used=\(pct($s.used)) spendPriority=\($sp) runway=\($s.runway // "unknown")"),
      (select(.fiveHourPublished == false) | "    window=five_hour used=not published by provider"),
      (.windows[]? | "    window=\(.id) used=\(pct(.used)) resets=\(.resetsAt) source=\(.source)"),
      (select((.notes // "") != "" or (.modelNote // "") != "") |
        "  notes=" + ([.notes, .modelNote] | map(select(. != null and . != "")) | join(" | ")))' <<< "$verdict"
    if [ -n "$(jq -r '.unverified // ""' <<< "$verdict")" ]; then
      gate_log_unverified "$(jq -r '.unverified' <<< "$verdict")" "$(jq -r '.readingAge // ""' <<< "$verdict")"
    fi
    exit 0
  fi
  refuse "quota intake gate: refusing - $(jq -r '.reason' <<< "$verdict")"
}

case "${1:-record}" in
  record) cmd_record ;;
  gate) shift; cmd_gate "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
