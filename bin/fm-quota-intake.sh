#!/usr/bin/env bash
# Quota intake: the mandatory pre-spawn usage-limit read every Firstmate
# dispatch must run before launching, relaunching, or moving a worker or
# second mate onto a model or account.
#
# Usage:
#   fm-quota-intake.sh                  (same as: record)
#   fm-quota-intake.sh record
#     Runs quota-axi --full for this home's DEFAULT credential stores and for
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
#     A store read that fails is recorded as readStatus=failed, still printed,
#     and the script exits nonzero. The newest 50 records are kept.
#
#   fm-quota-intake.sh gate --harness <harness> [--model <model>]
#       [--account <id>] [--claude-store <path>] [--pi-store <path>]
#       [--codex-store <path>] [--consume]
#     Refuses (exit 3, nothing else touched) unless the newest record is at
#     most FM_QUOTA_INTAKE_MAX_AGE (default 600) seconds old, has not already
#     been spent on a launch, covers the chosen account entry and store, maps
#     the harness to a provider family present in that entry, and carries the
#     whole table content for that provider: plan size known, the 7d (or
#     weekly) window, the 5h window when the provider publishes one, plus
#     every model-specific window binding the chosen model, each with a USED
#     percent and reset time, and a non-empty Notes entry.
#     Any exhausted_now runway or 100%-used (0% remaining) window is refused
#     naming the window and its reset time, as is any unknown or missing
#     piece. On pass (exit 0) the chosen candidate's full window table with
#     used percents and notes is printed; an unpublished 5h window shows as
#     "not published by provider", never a number. --consume (the launch itself,
#     bin/fm-spawn.sh) atomically marks the record spent on pass, so every
#     launch needs its own fresh intake; without it the gate is a preview
#     that marks nothing. The gate reads only the record; it never re-queries
#     quota-axi, which is exactly what forces the dispatching agent to re-run
#     the intake instead of leaning on stale numbers.
#
# Cached-read exception: when the default store's live personal Claude usage
#   is rate-limited or missing, the Claude statusline cache
#   <claude store>/tmp/sl-quota.txt is used only when it is at most
#   FM_QUOTA_INTAKE_CACHE_MAX_AGE (default 1800) seconds old. The statusline
#   prints percentages USED; they are stored as both used and remaining, and
#   every window taken from it is marked source=cached in the record and
#   table. An unparseable cache line yields no entry and the gate fails
#   closed.
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
#   FM_QUOTA_INTAKE_CACHE_MAX_AGE seconds (1800) - statusline cache freshness.
#   FM_QUOTA_INTAKE_TIMEOUT seconds (180) - one quota-axi read deadline.
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

FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
INTAKE_DIR=$STATE/quota-intake
MAX_AGE=${FM_QUOTA_INTAKE_MAX_AGE:-600}
CACHE_MAX_AGE=${FM_QUOTA_INTAKE_CACHE_MAX_AGE:-1800}
READ_TIMEOUT=${FM_QUOTA_INTAKE_TIMEOUT:-180}
KEEP=${FM_QUOTA_INTAKE_KEEP:-50}
SCHEMA_VERSION=2

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
refuse() { printf '%s\n' "$1"; exit 3; }

intake_list_records() { # one path per line, oldest first
  local f
  for f in "$INTAKE_DIR"/quota-*.json; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

usage() { sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# jq parses the record in every mode; quota-axi is only the live reader the
# record mode drives. The gate is a pure record consumer - demanding the live
# tool there would refuse launches on hosts that hold a fresh record but no
# installed quota-axi, and the cleared-environment remote second-mate launch
# is exactly such a host.
command -v jq >/dev/null 2>&1 || die "jq not installed"
[ -n "${HOME:-}" ] || die "HOME must be set"
[ "${1:-record}" = record ] && { command -v quota-axi >/dev/null 2>&1 || die "quota-axi not installed"; }

# The store a harness's gate checks when the caller passed no explicit store:
# exactly the resolution the launching scripts use, kept in one place so the
# record and the gate can never disagree about a default.
intake_default_store() { # <claude|pi|codex>
  case "$1" in
    claude) printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    pi)     printf '%s\n' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" ;;
    codex)  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}" ;;
    *)      return 1 ;;
  esac
}

quota_axi_full_json() { # stdout: raw --full --json snapshot; rc nonzero on failure
  local stores=$1 runner=()
  if command -v timeout >/dev/null 2>&1; then
    runner=(timeout "$READ_TIMEOUT")
  fi
  CLAUDE_CONFIG_DIR=$(printf '%s\n' "$stores" | sed -n 1p) \
  PI_CODING_AGENT_DIR=$(printf '%s\n' "$stores" | sed -n 2p) \
  CODEX_HOME=$(printf '%s\n' "$stores" | sed -n 3p) \
    "${runner[@]}" quota-axi --full --json </dev/null 2>/dev/null
}

# epoch helpers: pure bash arithmetic plus one UTC date probe for display only.
intake_epoch_now() { date -u +%s; }
intake_epoch_utc() { # <epoch> <date-format> - GNU then BSD date (format without the +)
  local epoch=$1 fmt=$2
  [ "$epoch" -gt 0 ] || return 1
  date -u -d "@$epoch" "+$fmt" 2>/dev/null || date -u -r "$epoch" "+$fmt" 2>/dev/null
}

# Statusline cache: the `cl personal` line prints percentages USED plus the
# 5h reset as a duration and the 7d reset as a weekday clock. Converted to
# REMAINING percents and absolute reset epochs against the cache file's mtime;
# a file older than the cache window is not evidence at all.
intake_cache_line() { # <cache-file> - stdout: <5h_used> <5h_reset_epoch> <7d_used> <7d_reset_epoch>
  local cache=$1 line seg5 seg7 used5 used7 hours mins dur5 wday7 clock_h clock_m
  local base now epoch5 epoch7 target=-1 today delta clock_secs midnight
  local days=(Sun Mon Tue Wed Thu Fri Sat) i
  [ -f "$cache" ] && [ ! -L "$cache" ] || return 1
  line=$(sed -e 's/\x1b\[[0-9;]*m//g' "$cache" 2>/dev/null | grep '^cl personal[[:space:]]' | head -1)
  [ -n "$line" ] || return 1
  seg5=${line%%|*}
  seg7=${line#*|}
  # Both segments must parse, or the cache line is not evidence; the gate then
  # fails closed rather than half-trusting a partially written cache.
  printf '%s\n' "$seg5" | grep -q ' 5h ' || return 1
  printf '%s\n' "$seg7" | grep -q ' 7d ' || return 1
  used5='' ; used7='' ; dur5='' ; wday7=''
  [[ $seg5 =~ ([0-9]{1,3})% ]] && used5=${BASH_REMATCH[1]}
  [[ $seg5 =~ \(([0-9]+)h([[:space:]]+([0-9]+)m)?\) ]] && { hours=${BASH_REMATCH[1]}; mins=${BASH_REMATCH[3]:-0}; dur5=${BASH_REMATCH[0]}; }
  [[ $seg7 =~ ([0-9]{1,3})% ]] && used7=${BASH_REMATCH[1]}
  [[ $seg7 =~ \((Mon|Tue|Wed|Thu|Fri|Sat|Sun)[[:space:]]+([0-9]{1,2}):([0-9]{2})\) ]] && { wday7=${BASH_REMATCH[1]}; clock_h=${BASH_REMATCH[2]}; clock_m=${BASH_REMATCH[3]}; }
  case "${used5:-x}${used7:-x}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${used5:-0}" -le 100 ] && [ "${used7:-0}" -le 100 ] || return 1
  [ -n "$dur5" ] || return 1
  [ -n "$wday7" ] || return 1
  base=$(stat -c %Y "$cache" 2>/dev/null) || base=$(stat -f %m "$cache" 2>/dev/null) || return 1
  case "$base" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date -u +%s)
  [ $(( now - base )) -le "$CACHE_MAX_AGE" ] || return 1
  # 5h: reset = mtime + remaining duration.
  epoch5=$(( base + hours * 3600 + mins * 60 ))
  # 7d: reset = next weekday-clock occurrence at or after the mtime, UTC.
  for i in 0 1 2 3 4 5 6; do
    [ "${days[i]}" = "$wday7" ] && target=$i && break
  done
  [ "$target" -ge 0 ] || return 1
  today=$(( (base / 86400 + 4) % 7 ))
  clock_secs=$(( clock_h * 3600 + clock_m * 60 ))
  midnight=$(( base - base % 86400 ))
  delta=$(( (target - today + 7) % 7 ))
  epoch7=$(( midnight + delta * 86400 + clock_secs ))
  [ "$epoch7" -gt "$base" ] || epoch7=$(( epoch7 + 604800 ))
  printf '%s %s %s %s\n' "$used5" "$epoch5" "$used7" "$epoch7"
}

# The usable-live rule for the cached fallback: the live snapshot's Claude
# provider must expose at least one window with a numeric percent remaining
# AND a reset time, or the store is treated as rate-limited/missing.
intake_claude_live_usable() { # <snapshot-file>
  jq -e '
    [.providers[]? | select(.provider == "claude") |
     (.windows // [])[] |
     select((.percentRemaining | type) == "number" and (.resetsAt | type) == "string" and (.resetsAt | length) > 0)
    ] | length > 0
  ' "$1" >/dev/null 2>&1
}

intake_build_cached_claude() { # <cache-file> <notes-map-json> - stdout: provider JSON, rc 1 when unusable
  local cache=$1 notes=$2 out used5 epoch5 used7 epoch7 rem5 rem7 rem
  out=$(intake_cache_line "$cache") || return 1
  read -r used5 epoch5 used7 epoch7 <<< "$out"
  rem5=$(( 100 - used5 ))
  rem7=$(( 100 - used7 ))
  [ "$rem5" -ge 0 ] || rem5=0
  [ "$rem7" -ge 0 ] || rem7=0
  rem=$rem5
  [ "$rem7" -lt "$rem" ] && rem=$rem7
  jq -cn --arg r5 "$rem5" --arg r7 "$rem7" --arg min "$rem" \
    --arg u5 "$used5" --arg u7 "$used7" --argjson notes "$notes" \
    --arg iso5 "$(intake_epoch_utc "$epoch5" '%Y-%m-%dT%H:%M:%SZ' || true)" \
    --arg iso7 "$(intake_epoch_utc "$epoch7" '%Y-%m-%dT%H:%M:%SZ' || true)" '{
      provider: "claude",
      readStatus: "cached",
      state: {status: "cached", error: "live snapshot rate-limited or missing; statusline cache used", retryAfter: null},
      plan: "unknown", planSource: "unknown", quotaAxiPlan: "none",
      spendPriority: null, runway: null,
      notes: ($notes.providers.claude // ""),
      modelNotes: ($notes.models.claude // {}),
      scopes: [{scope: "all_models", status: "known", effectivePercentRemaining: ($min | tonumber),
                effectivePercentUsed: (100 - ($min | tonumber)),
                spendPriority: null, runway: "unknown",
                boundedBy: ["five_hour", "seven_day"], limitingWindowIds: [], unmeasurableWindowIds: []}],
      windows: [
        {id: "five_hour", kind: "session", percentUsed: ($u5 | tonumber), percentRemaining: ($r5 | tonumber), resetsAt: $iso5},
        {id: "seven_day", kind: "weekly", percentUsed: ($u7 | tonumber), percentRemaining: ($r7 | tonumber), resetsAt: $iso7}
      ]
    }'
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

intake_build_entry() { # <account> <claude> <pi> <codex> <snapshot-file> <plan-lookup-json> <notes-map-json>
  local account=$1 claude=$2 pi=$3 codex=$4 snap=$5 planarg=$6 notesarg=$7
  jq -c -n --arg account "$account" --arg claude "$claude" --arg pi "$pi" --arg codex "$codex" \
    --slurpfile snapshot "$snap" --argjson planarg "$planarg" --argjson notes "$notesarg" '
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
      providers: [ $s.providers[]? |
        . as $p |
        ([$p.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models" or .scope == "all_products")] | first) as $wide |
        ($planarg[$p.provider].plan // null) as $declared |
        (plan_label($p.plan)) as $qp |
        {
          provider: $p.provider,
          readStatus: "ok",
          state: {status: ($p.state.status // $p.quotaSemantics.status // null),
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
    }'
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
    "quota-intake recordedAt=\(.recordedAt) record=\(.record)",
    (.accounts[] | . as $a |
      "account=\(.account) status=\(.readStatus) claude=\(.stores.claude) pi=\(.stores.pi) codex=\(.stores.codex)",
      (.providers[]? | . as $p | ($p.readStatus) as $ps |
        ($p.spendPriority // "unknown") as $sp |
        ($p.runway // "unknown") as $rw |
        "  provider=\($p.provider) status=\($ps) plan=\($p.plan) (\($p.planSource)) quota-axi=\($p.quotaAxiPlan) spendPriority=\($sp) runway=\($rw) notes=\($p.notes // "")",
        (($p.modelNotes // {}) | to_entries[] | "    model=\(.key) notes=\(.value)"),
        ($p.windows[]? | . as $w | ($w.resetsAt // "unknown") as $rs |
          (if $ps == "cached" then "cached" else "live" end) as $src |
          "    window=\($w.id) used=\(used($w.percentUsed)) resets=\($rs) source=\($src)")),
      (select($a.readStatus == "failed") | ($a.error // "unknown error") as $err |
        "  read failed: \($err)"))
  '
}

cmd_record() {
  # tmp stays a global: the EXIT trap must still see it after this function
  # returns, and set -u would otherwise trip on the lost local.
  tmp=$(mktemp -d) || die "mktemp failed"
  local entries default_stores plan_map account stores key snap entry failed=0 now ns name file
  local cache cached_json total sc sp sx
  local -a accounts=()
  trap 'rm -rf -- "$tmp"' EXIT

  default_stores=$(intake_default_store claude)$'\n'"$(intake_default_store pi)"$'\n'"$(intake_default_store codex)"
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

  entries='[]'
  for account in "${accounts[@]}"; do
    if [ "$account" = default ]; then
      stores=$default_stores
    else
      stores=$(fm_account_stores "$CONFIG/accounts.json" "$account") || {
        printf 'warning: account %s stores could not be resolved; the record will not cover it\n' "$account" >&2
        continue
      }
    fi
    key=$(printf '%s\n' "$stores" | cksum | tr -d ' ')
    snap="$tmp/snap-$key.json"
    if [ ! -f "$snap" ]; then
      if quota_axi_full_json "$stores" > "$snap.raw" 2>/dev/null && fm_quota_json_valid < "$snap.raw"; then
        mv -- "$snap.raw" "$snap"
      else
        rm -f -- "$snap.raw"
        snap=""
      fi
    fi
    if [ -z "$snap" ]; then
      sc=$(printf '%s\n' "$stores" | sed -n 1p)
      sp=$(printf '%s\n' "$stores" | sed -n 2p)
      sx=$(printf '%s\n' "$stores" | sed -n 3p)
      entry=$(jq -cn --arg account "$account" \
          --arg claude "$sc" --arg pi "$sp" --arg codex "$sx" \
          --arg error "quota-axi --full --json failed or invalid for this store" '{
          account: $account, readStatus: "failed",
          stores: {claude: $claude, pi: $pi, codex: $codex}, error: $error, providers: []}')
      failed=1
      entries=$(jq -cn --argjson all "$entries" --argjson one "$entry" '$all + [$one]')
      continue
    fi
    entry=$(intake_build_entry "$account" \
      "$(printf '%s\n' "$stores" | sed -n 1p)" "$(printf '%s\n' "$stores" | sed -n 2p)" "$(printf '%s\n' "$stores" | sed -n 3p)" \
      "$snap" "$(intake_plan_lookup "$plan_map" "$account" "$(jq -c '[.providers[].provider]' "$snap")")" "$notes_map")
    # Cached-read exception: only the DEFAULT store's personal Claude line.
    if [ "$account" = default ] && ! intake_claude_live_usable "$snap"; then
      local cache cached_json
      cache="$(printf '%s\n' "$stores" | sed -n 1p)/tmp/sl-quota.txt"
      cached_json=$(intake_build_cached_claude "$cache" "$notes_map") || cached_json=
      if [ -n "$cached_json" ]; then
        entry=$(jq -c --argjson cached "$cached_json" \
          --argjson decl "$(intake_plan_lookup "$plan_map" "$account" '["claude"]')" '
          ([.providers[] | select(.provider == "claude")] | first) as $old |
          .providers = ([.providers[] | select(.provider != "claude")] + [$cached +
            (if $old != null then {plan: $old.plan, planSource: $old.planSource, quotaAxiPlan: $old.quotaAxiPlan}
             elif $decl.claude.plan != null then {plan: $decl.claude.plan, planSource: $decl.claude.source}
             else {} end)])' <<< "$entry")
      else
        entry=$(jq -c '.providers = ([.providers[] | select(.provider != "claude")] +
          [{provider: "claude", readStatus: "failed",
            state: {status: "unknown", error: "live snapshot rate-limited or missing and the statusline cache is absent, stale, or unparseable", retryAfter: null},
            plan: "unknown", planSource: "unknown", quotaAxiPlan: "none",
            notes: "", modelNotes: {},
            spendPriority: null, runway: null, scopes: [], windows: []}])' <<< "$entry")
        failed=1
      fi
    fi
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
  [ "$failed" -eq 0 ] || exit 1
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

  local provider record now age covered entry store_field chosen expected spent_msg
  provider=$(gate_provider_for_harness "$harness" "$model") ||
    refuse "quota intake gate: refusing - no quota provider family can be established for harness '$harness' with model '$model'; declare the provider family in the dispatch profile or dispatch a measurable harness"
  record=$(intake_list_records | tail -n 1)
  [ -n "$record" ] || refuse "quota intake gate: refusing - no intake record exists under $INTAKE_DIR; run bin/fm-quota-intake.sh first and re-check every usage limit"
  spent_msg="quota intake gate: refusing - the newest intake record $(basename -- "$record") was already spent on a launch; every launch needs its own read, so run bin/fm-quota-intake.sh now and re-check every usage limit"
  [ ! -e "$record.spent" ] || refuse "$spent_msg"
  now=$(intake_epoch_now)
  age=$(jq -r --argjson now "$now" '$now - (.recordedAtEpoch // 0)' "$record" 2>/dev/null)
  case "$age" in
    ''|*[!0-9-]*) refuse "quota intake gate: refusing - the newest record is unreadable; run bin/fm-quota-intake.sh again" ;;
  esac
  [ "$age" -le "$MAX_AGE" ] ||
    refuse "quota intake gate: refusing - the newest intake record is ${age}s old (max ${MAX_AGE}s); run bin/fm-quota-intake.sh now and re-check every usage limit"

  entry=$(jq -c --arg a "$account" '[.accounts[] | select(.account == $a)] | first // empty' "$record")
  [ -n "$entry" ] || {
    covered=$(jq -r '[.accounts[].account] | join(",")' "$record")
    refuse "quota intake gate: refusing - the record does not cover account '$account' (covered: ${covered:-none}); run bin/fm-quota-intake.sh for that account's stores"
  }
  [ "$(jq -r '.readStatus' <<< "$entry")" = ok ] ||
    refuse "quota intake gate: refusing - the record's read for account '$account' failed ($(jq -r '.error // "unknown error"' <<< "$entry")); re-run bin/fm-quota-intake.sh"

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
      expected=$(intake_default_store "$store_field")
    else
      expected=$chosen
    fi
    [ "$(jq -r --arg f "$store_field" '.stores[$f]' <<< "$entry")" = "$expected" ] ||
      refuse "quota intake gate: refusing - the record's $store_field store $(jq -r --arg f "$store_field" '.stores[$f]' <<< "$entry") does not cover the chosen store $expected; run bin/fm-quota-intake.sh against the store this launch will use"
  fi

  local verdict
  verdict=$(jq -c --arg provider "$provider" --arg model "$model" --arg account "$account" '
    def bare($m): ($m | split("/") | last);
    ([.providers[] | select(.provider == $provider)] | first // null) as $p |
    if $p == null then
      {verdict: "refuse",
       reason: ("no \($provider) quota evidence in the intake record for account \($account); run bin/fm-quota-intake.sh and re-check every usage limit")}
    elif $p.readStatus == "failed" then
      ($p.state.error // "unknown error") as $err |
      {verdict: "refuse", reason: ("the \($provider) read failed in the intake record: \($err)")}
    else
      [$p.scopes[]? | select(
        .scope == "all_models" or .scope == "all_products" or
        ($model != "" and $model != "default" and
          (.scope == ("model:" + bare($model)) or .scope == ("product:" + bare($model)))))] as $rows |
      ([$rows[] | (.boundedBy // [])[]] | reduce .[] as $x ([]; if (. | index($x)) then . else . + [$x] end)) as $bids |
      (if ($bids | length) == 0
       then [$p.windows[] | select((.kind // "") != "model") | .id] | reduce .[] as $x ([]; if (. | index($x)) then . else . + [$x] end)
       else $bids end) as $ids |
      ([$p.windows[] | select(.id == "five_hour" or .kind == "five_hour")] | first // null) as $w5 |
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
      if ($rows | length) == 0 then
        {verdict: "refuse", reason: ("no quota evidence rows for provider \($provider) with model \($model); dispatch a candidate the intake can measure")}
      elif $w7 == null then
        {verdict: "refuse",
         reason: ("the seven-day usage window (used percent and reset time) is missing for provider \($provider) on account \($account); the intake must read it before any launch; re-run bin/fm-quota-intake.sh")}
      elif any($rows[]; (.runway // "") == "exhausted_now") then
        ([$rows[] | select((.runway // "") == "exhausted_now")] | first) as $bad |
        ($bad.limitingWindowIds // []) as $lims |
        (if ($lims | length) > 0 then $lims[0] else "" end) as $wname |
        (([$lims[]? | reset(.)] | map(select(. != null)) | first) // "an unknown time") as $rst |
        {verdict: "refuse", scope: $bad.scope,
         reason: ("\($provider) runway is exhausted_now at \($bad.scope)" +
                  (if $wname != "" then " (window \($wname))" else "" end) +
                  " resetting at \($rst)")}
      elif any($rows[]; .status != "known") then
        ([$rows[] | select(.status != "known")] | first) as $bad |
        {verdict: "refuse", scope: $bad.scope,
         reason: ("quota evidence is unknown at \($bad.scope) for provider \($provider); wait for the measurement or re-run bin/fm-quota-intake.sh")}
      elif ($req | length) == 0 then
        {verdict: "refuse", reason: ("no window reset evidence for provider \($provider); re-run bin/fm-quota-intake.sh")}
      else
        [($req[] | select(win(.) == null or ((used(.) // "x") | type) != "number" or ((win(.).resetsAt // "") | length) == 0))] as $unknown_ids |
        (if ($unknown_ids | length) > 0 then ($unknown_ids | join(", ")) else "" end) as $miss |
        (($p.modelNotes // {}) as $mn |
         ($mn[$model] // $mn[($model | split("/") | .[0:2] | join("/"))]
          // ([$mn | to_entries[] | select(.key | endswith("/" + $model)) | .value] | first) // "")) as $mnote |
        if ($miss != "") then
          {verdict: "refuse",
           reason: ("windows without a known used percent or reset time: \($miss)")}
        elif any($req[]; used(.) >= 100 or win(.).percentRemaining == 0) then
          ([$req[] | select(used(.) >= 100 or win(.).percentRemaining == 0)] | first) as $wid |
          (reset($wid) // "an unknown time") as $rst |
          {verdict: "refuse", window: $wid,
           reason: ("window \($wid) is at 100% used (0% remaining) and resets at \($rst); wait for the reset or dispatch another candidate")}
        elif ($p.plan // "unknown") == "unknown" then
          {verdict: "refuse",
           reason: ("the plan size for provider \($provider) on account \($account) is unknown; declare it in config/accounts.json plans and re-run bin/fm-quota-intake.sh")}
        elif (($p.notes // "") == "" and $mnote == "") then
          {verdict: "refuse",
           reason: ("no notes are recorded for provider \($provider) on account \($account); declare them in config/accounts.json top-level notes or config/crew-dispatch.json model_notes and re-run bin/fm-quota-intake.sh")}
        else
          {verdict: "pass", account: $account, provider: $provider, model: $model,
           plan: $p.plan, planSource: $p.planSource,
           notes: ($p.notes // ""), modelNote: $mnote,
           spendPriority: ($p.spendPriority // "unknown"), runway: ($p.runway // "unknown"),
           fiveHourPublished: ($w5 != null),
           scopes: [$rows[] | {scope, status, used: (if (.effectivePercentRemaining | type) == "number" then (100 - .effectivePercentRemaining) else null end),
                               spendPriority: (.spendPriority // null), runway: (.runway // null)}],
           windows: [$req[] | {id: ., used: used(.), resetsAt: win(.).resetsAt,
                               source: (if $p.readStatus == "cached" then "cached" else "live" end)}]}
        end
      end
    end' <<< "$entry")

  if [ "$(jq -r '.verdict' <<< "$verdict")" = pass ]; then
    if [ "$consume" -eq 1 ]; then
      ( set -C; : > "$record.spent" ) 2>/dev/null || refuse "$spent_msg"
    fi
    printf 'quota-intake gate: PASS record=%s age=%ss account=%s provider=%s model=%s plan=%s (%s) spendPriority=%s runway=%s\n' \
      "$(basename -- "$record")" "$age" \
      "$(jq -r '.account' <<< "$verdict")" "$(jq -r '.provider' <<< "$verdict")" \
      "$(jq -r '.model' <<< "$verdict")" "$(jq -r '.plan' <<< "$verdict")" \
      "$(jq -r '.planSource' <<< "$verdict")" "$(jq -r '.spendPriority' <<< "$verdict")" \
      "$(jq -r '.runway' <<< "$verdict")"
    jq -r '
      def pct($v): if ($v | type) == "number" then "\($v)%" else "unknown" end;
      (.scopes[]? | . as $s | ($s.spendPriority // "unknown") as $sp |
        "  scope=\($s.scope) status=\($s.status) used=\(pct($s.used)) spendPriority=\($sp) runway=\($s.runway // "unknown")"),
      (select(.fiveHourPublished == false) | "    window=five_hour used=not published by provider"),
      (.windows[]? | "    window=\(.id) used=\(pct(.used)) resets=\(.resetsAt) source=\(.source)"),
      (select((.notes // "") != "" or (.modelNote // "") != "") |
        "  notes=" + ([.notes, .modelNote] | map(select(. != null and . != "")) | join(" | ")))' <<< "$verdict"
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
