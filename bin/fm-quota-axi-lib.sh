# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic, the
# --json snapshot validator, and the provider-row join dispatch consumers use.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns an absent binary into the operator-facing MISSING diagnostic and an
# incompatible installed build into OUTDATED, which keeps an older build from
# reaching a dispatch intake at all.
#
# Snapshot schemas: fm_quota_json_valid accepts quota-axi schema 5 (one row per
# provider, no accountKey) and schema 6 (every row carries accountKey, unique on
# provider + accountKey; quota-axi emits it once any provider expands to more
# than one account). Schema 5 keeps its exact pre-schema-6 rules so an older
# quota-axi keeps working unchanged. FM_QUOTA_ROW_JQ is the one join used to
# bind a candidate to its row under either schema.

FM_QUOTA_AXI_MIN=0.1.51
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

# The eligibility section of .agents/skills/quota-array-dispatch/SKILL.md
# owns the account-matching contract these jq definitions implement.
# Prepend them to a consumer's program:
#   quota_lane($harness; $model)   the candidate's account key, or "" when none
#                                  is identified by the contract.
#   quota_row($snapshot; $provider; $lane)
#                                  the one provider row the candidate binds to,
#                                  or null; schema 5 ignores $lane.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_ROW_JQ='
  def quota_lane($harness; $model):
    if $harness == "codex" then "codex-home"
    elif ($harness == "pi" or $harness == "pi-signed") and (($model // "") | contains("/"))
    then ($model | split("/") | first | if . == "codex-native" then "codex-home" else . end)
    else "" end;
  def quota_row($snapshot; $provider; $lane):
    ([$snapshot.providers[]? | select(.provider == $provider)]) as $rows |
    if $snapshot.schemaVersion == 6 then
      (([$rows[] | select(.accountKey == $lane)] | first) //
       ([$rows[] | select(.accountKey == "default")] | first) // null)
    else ($rows | first) // null
    end;
'

# fm_quota_axi_version_compatible <version-output>
# True when the printed `quota-axi --version` text meets FM_QUOTA_AXI_MIN.
# Callers that already captured a bounded --version pass that text here so they
# do not launch a second, unbounded version probe.
fm_quota_axi_version_compatible() {
  local output=${1-} parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  fm_quota_axi_version_compatible "$output"
}

fm_quota_json_valid() {
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      (.providers | type) == "array" and
      (if .schemaVersion == 5 then
         (([.providers[].provider] | length) == ([.providers[].provider] | unique | length))
       elif .schemaVersion == 6 then
         all(.providers[];
           (.accountKey | type) == "string" and
           (.accountKey | length) > 0 and
           ((.accountKey | test("\\s")) | not)) and
         (([.providers[] | [.provider, .accountKey]] | length) ==
          ([.providers[] | [.provider, .accountKey]] | unique | length))
       else false
       end) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test($provider_re)) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'agy agy' \
    'muse meta'
}

# Reads the whole table before answering: leaving the loop early closes the
# pipe mid-write, and where SIGPIPE is ignored the writer prints a broken-pipe
# error on stderr.
fm_quota_single_provider_for_harness() {
  local harness provider found=''
  while read -r harness provider; do
    [ -z "$found" ] && [ "$harness" = "$1" ] && found=$provider || :
  done < <(fm_quota_single_provider_table)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_quota_provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*)  printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *)               return 1 ;;
      esac
      ;;
    claude)       printf 'claude\n' ;;
    codex)        printf 'codex\n' ;;
    opencode)     printf 'codex\n' ;;
    pi|pi-signed) printf 'pi\n' ;;
    grok)         printf 'grok\n' ;;
    kimi)         printf 'kimi\n' ;;
    cursor)       printf 'cursor\n' ;;
    muse)         printf 'meta\n' ;;
    *)            return 1 ;;
  esac
}

# ---- last good reading (R11) ---------------------------------------------------
# A quota read that is rate limited or otherwise fails must never stop a start.
# Every good provider row a reader sees is remembered per store in one shared
# cache; a later read whose row for that provider is unmeasured for any reason
# other than a credential failure (state auth_required) - or a read that failed
# outright - reuses the remembered row while it is at most
# FM_QUOTA_RECENT_MAX_AGE seconds old (default 86400, the captain's 24 hours). A
# reused row carries reusedReading {ageSeconds, savedAt, lastRead} so every
# consumer states its age and what the current read really returned.
# A reused row that showed exhaustion still excludes, but only until that
# exhaustion's own reset time: once every exhausted window has reset the row is
# no longer reused, whatever its age. Nothing older than the bound is reused.
# A credential failure is never papered over: it stays unmeasured and the
# resolver and the gate report it as an unusable credential.
FM_QUOTA_RECENT_MAX_AGE=${FM_QUOTA_RECENT_MAX_AGE:-86400}
# The captain's deadline on one whole quota read (intake record, resolver read).
FM_QUOTA_READ_DEADLINE=${FM_QUOTA_READ_DEADLINE:-45}
case "$FM_QUOTA_READ_DEADLINE" in ''|*[!0-9]*|0) FM_QUOTA_READ_DEADLINE=45 ;; esac

# fm_quota_recent_file <state-dir>: the private cache path shared by intake and
# the resolver. Rows are kept per provider and per that provider's own canonical
# store (claude rows by the Claude store, codex rows by the Codex store, any
# other provider by the Pi store), so two reads that share one login - the home
# default and the seat that owns the same Claude directory - answer for each other.
fm_quota_recent_file() {
  printf '%s/quota-last-good/shared.json\n' "$1"
}

# The jq key of one provider row: provider, accountKey and its own store.
# shellcheck disable=SC2016  # jq program text
FM_QUOTA_RECENT_KEY_JQ='
  def recent_key($p; $stores):
    ($p.provider) as $pv |
    (if $pv == "claude" then $stores[0] elif $pv == "codex" then $stores[2] else $stores[1] end) as $store |
    "\($pv)|\($p.accountKey // "")|\($store)";
  def reset_passed($now):
    type == "string" and
    ((sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) as $t | $t != null and $t <= $now);
  def exhaustion_expired($now):
    (.windows // []) as $w |
    (([$w[] | select(.percentRemaining == 0 or (.percentUsed // 0) >= 100) | .id] +
      [(.quotaSemantics.effectiveAvailability // [])[] | select((.runway.status // "") == "exhausted_now")
       | (.limitingWindowIds // .runway.limitingWindowIds // [])[]]) | unique) as $ids |
    ($ids | length) > 0 and
    all($ids[]; . as $id | ([$w[] | select(.id == $id) | .resetsAt] | first) | reset_passed($now));'

# fm_quota_recent_save <cache-file> <snapshot-file> <claude> <pi> <codex>:
# remember every measured row of this read under its own store; a row whose own
# store this read does not own ("-") is never remembered.
fm_quota_recent_save() {
  local cache=$1 snap=$2 now tmp prev stores
  stores=$(jq -cn --arg c "$3" --arg p "$4" --arg x "$5" '[$c, $p, $x]')
  now=$(date -u +%s)
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 0
  chmod 700 "$(dirname "$cache")" 2>/dev/null || true
  prev='{}'
  [ -f "$cache" ] && prev=$(jq -c '.rows // {}' "$cache" 2>/dev/null) || prev='{}'
  [ -n "$prev" ] || prev='{}'
  tmp=$(mktemp "$cache.XXXXXX") || return 0
  if jq -c --argjson now "$now" --argjson prev "$prev" --argjson stores "$stores" "$FM_QUOTA_RECENT_KEY_JQ"'
      . as $s |
      {schemaVersion: ($s.schemaVersion // null),
       rows: (reduce ($s.providers // [])[] as $p ($prev;
         if (["known", "partial"] | index($p.quotaSemantics.status // "")) != null
            and ((["rate_limited", "stale", "auth_required"] | index($p.state.status // "")) == null)
            and ($p.reusedReading == null)
            and ((recent_key($p; $stores) | split("|") | .[2]) as $own | $own != "-" and $own != "")
         then . + {(recent_key($p; $stores)): {at: $now, row: $p}}
         else . end))}' "$snap" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp"; mv -f "$tmp" "$cache"
  else
    rm -f "$tmp"
  fi
  return 0
}

# fm_quota_recent_merge <cache-file> <snapshot-file|""> <claude> <pi> <codex>:
# stdout the snapshot with each transiently unmeasured row replaced by its
# recent reading. With no snapshot (the read failed outright) the recent rows of
# these stores alone form the snapshot; rc 1 when nothing usable remains.
fm_quota_recent_merge() {
  local cache=$1 snap=${2:-} now cached stores
  stores=$(jq -cn --arg c "$3" --arg p "$4" --arg x "$5" '[$c, $p, $x]')
  now=$(date -u +%s)
  cached='{"rows":{}}'
  [ -f "$cache" ] && cached=$(jq -c . "$cache" 2>/dev/null) || cached='{"rows":{}}'
  [ -n "$cached" ] || cached='{"rows":{}}'
  if [ -n "$snap" ] && [ -s "$snap" ]; then
    jq -c --argjson now "$now" --argjson max "$FM_QUOTA_RECENT_MAX_AGE" --argjson c "$cached" --argjson stores "$stores" "$FM_QUOTA_RECENT_KEY_JQ"'
      def recent($k; $read): ($c.rows[$k] // null) as $e |
        if $e != null and ($now - $e.at) <= $max and ($now - $e.at) >= 0 and (($e.row | exhaustion_expired($now)) | not)
        then $e.row + {reusedReading: {ageSeconds: ($now - $e.at), savedAt: ($e.at | todate), lastRead: $read}}
        else null end;
      .providers = [(.providers // [])[] | . as $p |
        if (["known", "partial"] | index($p.quotaSemantics.status // "")) != null
           and ((["rate_limited", "stale"] | index($p.state.status // "")) == null) then $p
        elif ($p.state.status // "") == "auth_required" then $p
        else (recent(recent_key($p; $stores); ($p.state.status // "unmeasured")) // $p) end]' "$snap"
  else
    jq -ce --argjson now "$now" --argjson max "$FM_QUOTA_RECENT_MAX_AGE" --argjson stores "$stores" "$FM_QUOTA_RECENT_KEY_JQ"'
      [(.rows // {}) | to_entries[] | select(($now - .value.at) <= $max and ($now - .value.at) >= 0 and ((.value.row | exhaustion_expired($now)) | not)) |
        (.key | split("|")) as $k |
        select(($k[0] == "claude" and $k[2] == $stores[0]) or ($k[0] == "codex" and $k[2] == $stores[2])
               or ($k[0] != "claude" and $k[0] != "codex" and $k[2] == $stores[1])) |
        .value.row + {reusedReading: {ageSeconds: ($now - .value.at), savedAt: (.value.at | todate), lastRead: "read_failed"}}] as $rows |
      if ($rows | length) == 0 then error("no recent reading")
      else {schemaVersion: (.schemaVersion // 5), generatedAt: (now | todate), providers: $rows} end' <<<"$cached" 2>/dev/null
  fi
}
