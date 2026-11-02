#!/usr/bin/env bash
# fm-dispatch-receipt-lib.sh - the dispatch receipt: the record that proves one
# launch's harness, model, effort, and account came out of this home's dispatch
# table (config/crew-dispatch.json), and the gate that refuses a launch without
# one. Sourced by bin/fm-dispatch-resolve.sh, the only script that writes a
# receipt; bin/fm-spawn.sh and bin/fm-control.sh relaunch call that script's
# `gate` subcommand. This header is the single owner of the receipt format and
# of the gate's rules; bin/fm-dispatch-resolve.sh's header owns the commands.
#
# Storage reuses the quota-intake record mechanics (bin/fm-quota-intake.sh):
#   one private (0600) timestamped JSON file per receipt under
#   state/dispatch-receipt/, a freshness window, a `<receipt>.spent` marker
#   created with noclobber when a launch consumes it, and a retention count.
#   Receipts are unsigned exactly like quota-intake records; the gate instead
#   re-derives every binding it can from the brief, the launch, and the current
#   table, so a receipt is only ever as good as what it still matches.
#
# Receipt fields:
#   schemaVersion, receipt (file name), issuedAt, issuedAtEpoch
#   source      jev | degraded (override reserved, disabled in phase 1)
#   status      clear
#   jev         {model, requestId, ruleProbabilities, confidence,
#                candidatePreference, latencyMs, inputTokens}; null for degraded
#   quotaIntakeRecord  intake record issued by this resolver invocation
#   degraded    null, or {reason} when code selected after Jev failed twice
#   task        optional task id; a
#               receipt that names one admits only that task
#   brief       {path, sha256} - the hash covers the brief up to the first
#               relaunch progress note, so the note bin/fm-control.sh relaunch
#               appends never unbinds a task from its own receipt
#   table       {path, sha256} of config/crew-dispatch.json at issue time
#   row         {id, sha256} - id is rule_<n> (1-based position in `rules`) or
#               default; sha256 is of the row's canonical JSON, so any edit to
#               the row makes its outstanding receipts stale
#   profile     {harness, model, effort, account, provider}; an omitted axis is ""
#   candidates  evaluated profiles from the row or strongest-class union:
#               harness, model, effort, account, provider, reasoning_class,
#               catalog, plan, quotaIntakeRecord, spendPriority (a number or
#               the literal "unknown"), eligible, reason
#   rationale   why this candidate (the resolver's note, or the rationale file)
#   override    null; legacy override receipts are refused
#
# The gate (fm_dr_cmd_gate) admits a launch only when:
#   - this home has no routing rows (no rules and no default): there is no
#     table to route from, so nothing is demanded; or
#   - it is the host-local launch of a remote second mate that the parent home's
#     gate already admitted (see "Remote second mates" below); or
#   - the launch keeps the profile already recorded for the task (a relaunch or
#     a secondmate respawn with the same harness, model, effort, and account); or
#   - the newest receipt whose brief hash matches this task's brief is unspent,
#     at most FM_DISPATCH_RECEIPT_MAX_AGE seconds old, names a row that is
#     unchanged in the current table with the receipt's profile among that
#     row's candidates, its source is jev (with request id) or degraded (with
#     reason), and its profile equals the launch field by field.
#   Raw launch commands cannot match table profiles and are refused.
#   Every refusal names the missing or mismatching receipt field and the
#   command that produces a receipt. Exit 0 pass, 3 refusal, 2 usage.
#
# Remote second mates: bin/fm-spawn.sh runs this gate in the PARENT home, against
#   a receipt in the parent home, before it delegates the launch to the remote
#   host, and the launch consumes that receipt. The host-local fm-spawn the
#   remote control plane then runs has no receipt producer of its own, so
#   bin/fm-remote-secondmate-control.sh launch hands it
#   FM_DISPATCH_PARENT_ADMITTED=<id>. The gate honours that only for the launch
#   it describes: the state directory is the remote home's private
#   state/parent-route, the brief is that home's data/charter.md, the home's
#   .fm-secondmate-home marker names the same id, and the launch is not a raw
#   command. A ship, a scout, or a relaunch matches none of that, so the
#   variable does not switch the gate off for them. Every one of those
#   conditions is established on the launching side, though, so a local session
#   can reach the pass-through for a seeded second-mate home, by running the
#   remote control plane's launch verb against it or by setting the variables
#   by hand.
#
# What the gate does and does not prevent: it physically stops a launch whose
#   profile no receipt names, which catches hand-picked profiles. Receipts and
#   state/<id>.meta remain same-user writable; parent admission remains an
#   audit-only pass-through. The seatbelt and audit reconcile ship separately.
#
# FM_DISPATCH_RECEIPT_MAX_AGE can only shorten the freshness window (clamped
# 1..900 seconds, default 900); the test suite reaches the gate the way a home
# does, by producing real receipts.
#
# Historical data/dispatch-overrides.jsonl remains readable by session start.
# No producer or gate accepts overrides until bound-to-words verification ships.
#
# Requires the sourcing script to set CONFIG, STATE, and DATA.

FM_DR_SCHEMA=1
FM_DR_MAX_AGE_CAP=900
FM_DR_KEEP=200
FM_DR_OVERRIDE_RECENT_SECS=604800
FM_DR_OVERRIDE_RECENT_MAX=10
# The heading bin/fm-control.sh record_note appends to a relaunched brief.
FM_DR_RELAUNCH_NOTE_HEADING='## Progress note ('
FM_DR_ERR=

fm_dr_dir() { printf '%s\n' "$STATE/dispatch-receipt"; }
fm_dr_table() { printf '%s\n' "$CONFIG/crew-dispatch.json"; }
fm_dr_override_log() { printf '%s\n' "$DATA/dispatch-overrides.jsonl"; }

fm_dr_die() { printf 'error: %s\n' "$1" >&2; exit 2; }
fm_dr_refuse() { printf 'dispatch receipt gate: refusing - %s\n' "$1"; exit 3; }

fm_dr_max_age() {
  local v=${FM_DISPATCH_RECEIPT_MAX_AGE:-$FM_DR_MAX_AGE_CAP}
  case "$v" in '' | *[!0-9]*) v=$FM_DR_MAX_AGE_CAP ;; esac
  [ "$v" -ge 1 ] || v=1
  [ "$v" -le "$FM_DR_MAX_AGE_CAP" ] || v=$FM_DR_MAX_AGE_CAP
  printf '%s' "$v"
}

fm_dr_sha256() {  # stdin -> 64 hex characters
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum | awk '{ print $1 }')
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 | awk '{ print $1 }')
  else
    return 1
  fi
  case "$out" in '' | *[!0-9a-f]*) return 1 ;; esac
  [ "${#out}" -eq 64 ] || return 1
  printf '%s' "$out"
}

fm_dr_brief_hash() {  # <brief-file>
  [ -f "$1" ] && [ -r "$1" ] || return 1
  awk -v note="$FM_DR_RELAUNCH_NOTE_HEADING" '
    index($0, note) == 1 { exit }
    { lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "$1" | fm_dr_sha256
}

fm_dr_abs_path() {  # <file>
  local dir
  dir=$(cd "$(dirname -- "$1")" 2>/dev/null && pwd -P) || { printf '%s' "$1"; return 0; }
  printf '%s/%s' "$dir" "$(basename -- "$1")"
}

fm_dr_axis() {  # <value>: an omitted axis and the literal default are the same
  case "${1:-}" in default) printf '' ;; *) printf '%s' "${1:-}" ;; esac
}

fm_dr_meta_get() {  # <meta-file> <key>: last value wins, as fm_meta_get reads it
  local line value=''
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1" 2>/dev/null || true
  printf '%s' "$value"
}

fm_dr_profile_json() {  # <harness> <model> <effort> <account> [provider]
  jq -cn --arg h "$1" --arg m "$(fm_dr_axis "$2")" --arg e "$(fm_dr_axis "$3")" --arg a "$4" --arg p "${5:-}" \
    '{harness: $h, model: $m, effort: $e, account: $a, provider: $p}'
}

fm_dr_profile_text() {  # <profile-json>
  jq -r '"--harness \(.harness)"
    + (if .model != "" then " --model \(.model)" else "" end)
    + (if .effort != "" then " --effort \(.effort)" else "" end)
    + (if .account != "" then " --account \(.account)" else "" end)' <<<"$1"
}

# shellcheck disable=SC2016 # jq program text, not shell expansion
FM_DR_ROW_JQ='
  def axis: if . == null or . == "default" then "" else . end;
  def norm: {harness: .harness, model: (.model | axis), effort: (.effort | axis), account: (.account // ""), provider: (.provider // "")};
  def row_entry($id; $sha; $when; $approval; $use):
    {id: $id, sha256: $sha, when: $when, approval: $approval,
     profiles: ((if ($use | type) == "array" then $use else [$use] end) | map(norm))};
'

# The table's rows as [{id, sha256, when, approval, profiles}]. An absent file
# and a file with neither rules nor default both yield []. rc 1 with FM_DR_ERR
# set when the file exists but is unreadable or malformed.
fm_dr_table_rows() {
  local table rows='[]' canon sha n=0 err
  table=$(fm_dr_table)
  FM_DR_ERR=
  if [ ! -e "$table" ] && [ ! -L "$table" ]; then
    printf '[]\n'
    return 0
  fi
  [ -f "$table" ] && [ -r "$table" ] || { FM_DR_ERR="$table is not a readable regular file"; return 1; }
  err=$(jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else null end;
    def bad_profiles($v): profiles($v) as $p
      | $p == null or ($p | length) == 0
        or any($p[]; type != "object" or (.harness | type) != "string" or (.harness | length) == 0
          or (has("model") and (.model | type) != "string")
          or (has("effort") and (.effort | type) != "string")
          or (has("account") and (.account | type) != "string"));
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif any((.rules // [])[]; type != "object") then "each rule must be an object"
    elif any((.rules // [])[]; bad_profiles(.use)) then "each rule needs a use profile with a harness"
    elif has("default") and bad_profiles(.default) then "default needs a profile with a harness"
    else empty end' "$table" 2>/dev/null) || { FM_DR_ERR="$table is not JSON"; return 1; }
  [ -z "$err" ] || { FM_DR_ERR="$table - $err"; return 1; }
  while IFS= read -r canon; do
    [ -n "$canon" ] || continue
    n=$((n + 1))
    sha=$(printf '%s' "$canon" | fm_dr_sha256) || { FM_DR_ERR="no sha256 tool (sha256sum or shasum)"; return 1; }
    rows=$(jq -c --arg id "rule_$n" --arg sha "$sha" --argjson row "$canon" "$FM_DR_ROW_JQ"'
      . + [row_entry($id; $sha; $row.when // ""; $row.approval // null; $row.use)]' <<<"$rows") || return 1
  done < <(jq -cS '(.rules // [])[]' "$table")
  canon=$(jq -cS '.default // empty' "$table")
  if [ -n "$canon" ]; then
    sha=$(printf '%s' "$canon" | fm_dr_sha256) || { FM_DR_ERR="no sha256 tool (sha256sum or shasum)"; return 1; }
    rows=$(jq -c --arg sha "$sha" --argjson use "$canon" "$FM_DR_ROW_JQ"'
      . + [row_entry("default"; $sha; "No listed rule applies to this task."; null; $use)]' <<<"$rows") || return 1
  fi
  printf '%s\n' "$rows"
}
# The launch identity of a profile: provider is evidence, not something a
# launch passes, so membership and equality compare the four launch axes.
# shellcheck disable=SC2016 # jq program text, not shell expansion
FM_DR_KEY_JQ='def key: {harness: (.harness // ""), model: (.model // ""), effort: (.effort // ""), account: (.account // "")};'

fm_dr_list() {  # one receipt path per line, oldest first
  local f dir
  dir=$(fm_dr_dir)
  for f in "$dir"/dispatch-*.json; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

fm_dr_newest_for_brief() {  # <brief-sha256> -> path of the newest receipt binding it
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$(jq -r '.brief.sha256 // ""' "$f" 2>/dev/null)" = "$1" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(fm_dr_list | LC_ALL=C sort -r)
  return 1
}

# fm_dr_write <source> <status> <task> <brief> <row-json|null> <profile-json>
#             <candidates-json> <rationale> <override-json|null>
# Prints the new receipt's file name. Internal: only this library's producers
# call it, each after its own checks.
fm_dr_write() {
  local source=$1 status=$2 task=$3 brief=$4 row=$5 profile=$6 candidates=$7 rationale=$8 override=$9
  local dir now ns name file brief_sha table table_sha='' total old
  case "$source" in jev|degraded) ;; *) printf 'dispatch receipt: source %s disabled\n' "$source" >&2; return 1 ;; esac
  dir=$(fm_dr_dir)
  mkdir -p -- "$dir" || { FM_DR_ERR="could not create $dir"; return 1; }
  brief_sha=$(fm_dr_brief_hash "$brief") || { FM_DR_ERR="could not hash the brief $brief"; return 1; }
  table=$(fm_dr_table)
  if [ -f "$table" ]; then
    table_sha=$(fm_dr_sha256 < "$table") || table_sha=''
  fi
  now=$(date -u +%s)
  ns=$(date -u +%N 2>/dev/null)
  case "$ns" in '' | *[!0-9]*) ns=000000000 ;; esac
  name=$(printf 'dispatch-%s-%s-%s.json' "$now" "$ns" "$$")
  file=$dir/$name
  ( umask 077
    jq -cn --argjson schema "$FM_DR_SCHEMA" --arg name "$name" --argjson epoch "$now" \
      --arg at "$(date -u -d "@$now" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$now" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$now")" \
      --arg source "$source" --arg status "$status" --arg task "$task" \
      --arg brief "$(fm_dr_abs_path "$brief")" --arg brief_sha "$brief_sha" \
      --arg table "$table" --arg table_sha "$table_sha" \
      --argjson row "$row" --argjson profile "$profile" --argjson candidates "$candidates" \
      --arg rationale "$rationale" --argjson override "$override" \
      --argjson jev "${FM_DR_JEV:-null}" --arg degraded_reason "${FM_DR_DEGRADED_REASON:-}" \
      --arg intake "${FM_DR_INTAKE_RECORD:-}" \
      '{schemaVersion: $schema, receipt: $name, issuedAt: $at, issuedAtEpoch: $epoch,
        source: $source, status: $status, task: $task,
        brief: {path: $brief, sha256: $brief_sha},
        table: {path: $table, sha256: $table_sha},
        row: $row, profile: $profile, candidates: $candidates,
        rationale: $rationale, override: $override, jev: $jev,
        quotaIntakeRecord: $intake,
        degraded: (if $source == "degraded" then {reason: $degraded_reason} else null end)}' > "$file"
  ) || { rm -f -- "$file"; FM_DR_ERR="could not write the receipt under $dir"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  total=$(fm_dr_list | wc -l)
  if [ "$total" -gt "$FM_DR_KEEP" ]; then
    fm_dr_list | head -n $(( total - FM_DR_KEEP )) | while IFS= read -r old; do
      rm -f -- "$old" "$old.spent"
    done
  fi
  printf '%s\n' "$name"
}

# The receipt for a `clear` resolution: <brief> <task> <resolver-result-json>.
# The result carries the matched row, the chosen candidate, and every
# candidate's evidence; nothing here re-decides any of it.
fm_dr_write_clear() {
  local brief=$1 task=$2 result=$3 rows row_id row profile candidates intake
  [ "$(fm_dr_brief_hash "$brief")" = "$FM_DR_BRIEF_SHA" ] \
    || { printf 'dispatch receipt: brief changed during resolution; route again\n' >&2; return 1; }
  [ "$(fm_dr_sha256 < "$(fm_dr_table)")" = "$FM_DR_TABLE_SHA" ] \
    || { printf 'dispatch receipt: table changed during resolution; route again\n' >&2; return 1; }
  rows=$(fm_dr_table_rows) || return 1
  row_id=$(jq -r '.row // ""' <<<"$result")
  row=$(jq -c --arg id "$row_id" '[.[] | select(.id == $id)] | first // null | if . == null then null else {id, sha256} end' <<<"$rows")
  [ "$row" != null ] || { FM_DR_ERR="the resolved row '$row_id' is not in $(fm_dr_table)"; return 1; }
  intake=${FM_DR_INTAKE_RECORD:-}
  [ -n "$intake" ] || { printf 'dispatch receipt: quota intake record required\n' >&2; return 1; }
  local source=jev lock counter count day
  if [ -n "${FM_DR_DEGRADED_REASON:-}" ]; then
    source=degraded
    mkdir -p "$(fm_dr_dir)" || return 1
    lock="$(fm_dr_dir)/degraded.lock"
    mkdir "$lock" 2>/dev/null || { printf 'dispatch receipt: degraded counter busy; stop and report\n' >&2; return 1; }
    # Capture the local path now: EXIT runs after this function's locals expire.
    # shellcheck disable=SC2064
    trap "rmdir -- $(printf '%q' "$lock")" EXIT
    day=$(date -u +%Y-%m-%d)
    counter="$(fm_dr_dir)/degraded-$day.count"
    count=0
    [ ! -f "$counter" ] || read -r count < "$counter"
    case "$count" in ''|*[!0-9]*) printf 'dispatch receipt: invalid degraded counter\n' >&2; return 1 ;; esac
    [ "$count" -lt 3 ] || { printf 'dispatch receipt: degraded daily cap 3 reached; stop and report\n' >&2; return 1; }
    (umask 077; printf '%s\n' "$((count + 1))" > "$counter") || return 1
  fi
  profile=$(jq -c '.chosen | {harness: .profile.harness, model: ((.profile.model // "") | if . == "default" then "" else . end),
    effort: ((.profile.effort // "") | if . == "default" then "" else . end), account: (.profile.account // ""), provider: (.provider // "")}' <<<"$result") || return 1
  candidates=$(jq -c --arg intake "${intake:-none}" '[.candidates[] | {
      harness: .profile.harness,
      model: ((.profile.model // "") | if . == "default" then "" else . end),
      effort: ((.profile.effort // "") | if . == "default" then "" else . end),
      account: (.profile.account // ""), provider: (.provider // ""),
      reasoning_class: (.profile.reasoning_class // null),
      catalog: "unknown (the resolver does not read harness catalogs; fm-spawn validates the model at launch)",
      plan: (.plan // "unknown"), quotaIntakeRecord: $intake,
      spendPriority: (if (.spendPriority | type) == "number" then .spendPriority else "unknown" end),
      eligible: ((.eligible // false) and ((.unranked // false) | not)),
      reason: (.reason // "")}]' <<<"$result") || return 1
  fm_dr_write "$source" clear "$task" "$brief" "$row" "$profile" "$candidates" \
    "$(jq -r '.note // "rule matched"' <<<"$result")" null
}

fm_dr_producer_hint() {
  printf '%s' 'produce one with bin/fm-dispatch-resolve.sh <brief> --project <name>; Jev chooses, or code issues a flagged default-row degraded receipt (3/day); self-service choose and override are disabled'
}

fm_dr_cmd_rows() {
  local rows
  rows=$(fm_dr_table_rows) || fm_dr_die "$FM_DR_ERR"
  if [ "$(jq 'length' <<<"$rows")" -eq 0 ]; then
    printf 'dispatch rows: none (%s has no rules and no default)\n' "$(fm_dr_table)"
    return 0
  fi
  jq -r '.[] | "row \(.id)  sha256=\(.sha256[0:12])" + (if .approval then "  approval=\(.approval)" else "" end) + "  when: \(.when | gsub("[\t\r\n]"; " ") | .[0:100])",
    (.profiles[] | "  candidate: --harness \(.harness)"
      + (if .model != "" then " --model \(.model)" else "" end)
      + (if .effort != "" then " --effort \(.effort)" else "" end)
      + (if .account != "" then " --account \(.account)" else "" end))' <<<"$rows"
}

# Recent degraded receipts are visible even if the launch never happened;
# receipt issuance, not process startup, reserves the daily degraded allowance.
fm_dr_cmd_degraded_recent() {
  local files=()
  mapfile -t files < <(fm_dr_list)
  [ "${#files[@]}" -gt 0 ] || return 0
  jq -rs --argjson cutoff "$(( $(date -u +%s) - 86400 ))" '
    map(select(.source == "degraded" and .issuedAtEpoch >= $cutoff)) | .[-10:][] |
    "task=\(.task) source=degraded receipt=\(.receipt) reason=\(.degraded.reason | gsub("[\\t\\r\\n]"; " "))"' "${files[@]}"
}

# overrides: the durable log, newest last. --recent prints only what a session
# start lists: the newest entries from the last week, or nothing at all.
fm_dr_cmd_overrides() {
  local recent=0 log now
  case "${1:-}" in
    --recent) recent=1 ;;
    '') ;;
    *) fm_dr_die "unknown overrides argument: $1" ;;
  esac
  log=$(fm_dr_override_log)
  [ -f "$log" ] || { [ "$recent" -eq 1 ] || printf 'dispatch overrides: none recorded\n'; return 0; }
  now=$(date -u +%s)
  jq -rs --argjson recent "$recent" --argjson now "$now" \
    --argjson window "$FM_DR_OVERRIDE_RECENT_SECS" --argjson cap "$FM_DR_OVERRIDE_RECENT_MAX" '
    def line: "\(.at)  task=\(.task)  --harness \(.profile.harness)"
      + (if .profile.model != "" then " --model \(.profile.model)" else "" end)
      + (if .profile.effort != "" then " --effort \(.profile.effort)" else "" end)
      + (if .profile.account != "" then " --account \(.profile.account)" else "" end)
      + "  captain: \"\(.words | gsub("[\t\r\n]+"; " ") | .[0:300])\"";
    if $recent == 1 then
      [.[] | select((.atEpoch // 0) >= ($now - $window))] as $r |
      if ($r | length) == 0 then empty
      else ($r | .[-$cap:][] | line),
        (if ($r | length) > $cap then "(\(($r | length) - $cap) older override(s) in the last week not shown)" else empty end)
      end
    elif length == 0 then "dispatch overrides: none recorded"
    else .[] | line end' "$log" 2>/dev/null \
    || printf 'dispatch overrides: %s is unreadable; read it by hand\n' "$log"
}

fm_dr_cmd_gate() {
  local brief='' task='' harness='' model='' effort='' account='' raw=0 consume=0 meta=''
  local resolved_model='' resolved_effort='' resolved_set=0 arg
  while [ $# -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --brief | --task | --harness | --model | --effort | --account | --recorded-meta | --resolved-model | --resolved-effort)
        [ $# -gt 0 ] || fm_dr_die "$arg needs a value" ;;
    esac
    case "$arg" in
      --consume) consume=1 ;;
      --raw) raw=1 ;;
      --brief) brief=$1; shift ;;
      --task) task=$1; shift ;;
      --harness) harness=$1; shift ;;
      --model) model=$1; shift ;;
      --effort) effort=$1; shift ;;
      --account) account=$1; shift ;;
      --recorded-meta) meta=$1; shift ;;
      --resolved-model) resolved_model=$1; resolved_set=1; shift ;;
      --resolved-effort) resolved_effort=$1; resolved_set=1; shift ;;
      *) fm_dr_die "unknown gate argument: $arg" ;;
    esac
  done
  [ -n "$harness" ] || fm_dr_die "gate requires --harness"
  local task_id=$task
  [ -n "$task" ] || task='this task'
  model=$(fm_dr_axis "$model")
  effort=$(fm_dr_axis "$effort")
  [ "$resolved_set" -eq 1 ] || { resolved_model=$model; resolved_effort=$effort; }
  resolved_model=$(fm_dr_axis "$resolved_model")
  resolved_effort=$(fm_dr_axis "$resolved_effort")
  command -v jq >/dev/null 2>&1 || fm_dr_refuse "jq is not installed, so the dispatch table cannot be read"

  local rows
  rows=$(fm_dr_table_rows) \
    || fm_dr_refuse "config/crew-dispatch.json is not a readable, well-formed rules file ($FM_DR_ERR); correct it rather than launching around it"
  if [ "$(jq 'length' <<<"$rows")" -eq 0 ]; then
    printf 'dispatch receipt gate: PASS - this home has no routing rows in config/crew-dispatch.json, so there is no table to route from\n'
    return 0
  fi

  # The host-local launch of a remote second mate its parent home already admitted.
  local remote_home=${STATE%/state/parent-route}
  if [ -n "$task_id" ] && [ "${FM_DISPATCH_PARENT_ADMITTED:-}" = "$task_id" ] && [ "$raw" -eq 0 ] \
    && [ "$remote_home" != "$STATE" ] && [ -n "$brief" ] && [ "$brief" -ef "$remote_home/data/charter.md" ] \
    && [ "$(cat "$remote_home/.fm-secondmate-home" 2>/dev/null)" = "$task_id" ]; then
    printf 'dispatch receipt gate: PASS - %s was admitted by the gate in its parent home; this host-local launch of a remote second mate needs no receipt of its own\n' "$task_id"
    return 0
  fi

  # A launch that keeps the task's recorded profile changes no routing decision.
  if [ -n "$meta" ] && [ -f "$meta" ]; then
    local rec_account
    rec_account=$(fm_dr_meta_get "$meta" account)
    case "$rec_account" in ordinary | /*) rec_account='' ;; esac
    if [ "$(fm_dr_meta_get "$meta" harness)" = "$harness" ] \
      && [ "$(fm_dr_axis "$(fm_dr_meta_get "$meta" model)")" = "$resolved_model" ] \
      && [ "$(fm_dr_axis "$(fm_dr_meta_get "$meta" effort)")" = "$resolved_effort" ] \
      && [ "$rec_account" = "$account" ]; then
      printf 'dispatch receipt gate: PASS - %s keeps its recorded profile (harness=%s model=%s effort=%s account=%s); no new receipt is needed\n' \
        "$task" "$harness" "${resolved_model:-default}" "${resolved_effort:-default}" "${account:-home seat}"
      return 0
    fi
  fi

  [ -n "$brief" ] || fm_dr_refuse "no brief was named for $task, so no receipt can bind it"
  [ -f "$brief" ] && [ -r "$brief" ] \
    || fm_dr_refuse "the brief $brief for $task is not readable, so no receipt can bind it"
  local brief_sha hint receipt name age max launch
  brief_sha=$(fm_dr_brief_hash "$brief") || fm_dr_refuse "the brief $brief could not be hashed (no sha256sum or shasum)"
  hint=$(fm_dr_producer_hint)
  launch=$(fm_dr_profile_json "$harness" "$model" "$effort" "$account")
  if ! receipt=$(fm_dr_newest_for_brief "$brief_sha"); then
    local other
    other=$(fm_dr_list | tail -n 1)
    [ -z "$other" ] || other=$(jq -r '.brief.path // "an unreadable receipt"' "$other" 2>/dev/null)
    fm_dr_refuse "no dispatch receipt binds the brief of $task (brief.sha256 ${brief_sha:0:12} for $brief); the newest receipt in this home binds ${other:-nothing, because there is none}. A hand-picked $(fm_dr_profile_text "$launch") is not a routing decision: $hint"
  fi
  name=$(basename -- "$receipt")
  [ ! -e "$receipt.spent" ] \
    || fm_dr_refuse "receipt $name for this brief was already consumed by a launch (marker $name.spent); every launch needs its own receipt: $hint"
  max=$(fm_dr_max_age)
  age=$(jq -r --argjson now "$(date -u +%s)" '$now - (.issuedAtEpoch // 0)' "$receipt" 2>/dev/null)
  case "$age" in
    '' | *[!0-9-]*) fm_dr_refuse "receipt $name is unreadable; $hint" ;;
  esac
  [ "$age" -ge 0 ] && [ "$age" -le "$max" ] \
    || fm_dr_refuse "receipt $name is stale: issuedAt is ${age}s ago (max ${max}s); $hint"

  local source verdict row_id receipt_task
  source=$(jq -r '.source // ""' "$receipt")
  receipt_task=$(jq -r '.task // ""' "$receipt")
  [ -z "$receipt_task" ] || [ -z "$task_id" ] || [ "$receipt_task" = "$task_id" ] \
    || fm_dr_refuse "receipt $name was issued for task '$receipt_task', not $task_id (the task field does not match); $hint"
  if [ "$source" = override ] || [ "$(jq -r '.override.by // ""' "$receipt")" = captain ]; then
    fm_dr_refuse "captain override receipts are disabled until bound-to-words verification exists"
  else
    [ "$raw" -eq 0 ] \
      || fm_dr_refuse "a raw launch command cannot be matched to a profile of the dispatch table; overrides are disabled in phase 1"
    case "$source" in
      jev | degraded) ;;
      *) fm_dr_refuse "receipt $name has no recognised source (source is '${source}'); $hint" ;;
    esac
    if [ "$source" = jev ]; then
      jq -e '.jev.requestId | type == "string" and length > 0' "$receipt" >/dev/null \
        || fm_dr_refuse "Jev receipt has no request id"
    else
      jq -e '.degraded.reason | type == "string" and length > 0' "$receipt" >/dev/null \
        || fm_dr_refuse "degraded receipt has no reason"
    fi
    jq -e '.status == "clear" and (.quotaIntakeRecord | type == "string" and test("^quota-[0-9A-Za-z-]+\\.json$"))' "$receipt" >/dev/null \
      || fm_dr_refuse "receipt $name has no dispatchable status or quota intake binding"
    [ -f "$STATE/quota-intake/$(jq -r .quotaIntakeRecord "$receipt")" ] \
      || fm_dr_refuse "receipt $name names a missing quota intake record"
    row_id=$(jq -r '.row.id // ""' "$receipt")
    verdict=$(jq -r --slurpfile r "$receipt" "$FM_DR_KEY_JQ"'
      ($r[0]) as $rc |
      ([.[] | select(.id == ($rc.row.id // ""))] | first) as $row |
      if $row == null then "gone"
      elif $row.sha256 != ($rc.row.sha256 // "") then "changed"
      elif any($row.profiles[]; key == ($rc.profile | key)) | not then "outside"
      else "member" end' <<<"$rows") || fm_dr_refuse "receipt $name is unreadable; $hint"
    case "$verdict" in
      member) ;;
      gone) fm_dr_refuse "receipt $name names row.id '$row_id', which config/crew-dispatch.json no longer has; route again: $hint" ;;
      changed) fm_dr_refuse "receipt $name names row.id '$row_id' at row.sha256 $(jq -r '(.row.sha256 // "")[0:12]' "$receipt"), but that row has changed in config/crew-dispatch.json since; route again: $hint" ;;
      *) fm_dr_refuse "receipt $name carries profile $(fm_dr_profile_text "$(jq -c '.profile' "$receipt")"), which is not a candidate of row.id '$row_id' in the current config/crew-dispatch.json; a profile outside the matched row is refused: $hint" ;;
    esac
  fi

  local field want got drop
  for field in harness model effort account; do
    want=$(jq -r --arg f "$field" '.profile[$f] // ""' "$receipt")
    got=$(jq -r --arg f "$field" '.[$f] // ""' <<<"$launch")
    [ "$want" = "$got" ] && continue
    case "$field" in
      model | effort) drop="; pass --$field default to drop a carried-over value" ;;
      *) drop='' ;;
    esac
    fm_dr_refuse "the launch of $task does not equal receipt $name: profile.$field is '${want:-default}' on the receipt but the launch passes '${got:-default}'. Launch the receipt's profile ($(fm_dr_profile_text "$(jq -c '.profile' "$receipt")")$drop), or route this profile properly: $hint"
  done

  if [ "$consume" -eq 1 ]; then
    ( set -C; : > "$receipt.spent" ) 2>/dev/null \
      || fm_dr_refuse "receipt $name for this brief was already consumed by a launch (marker $name.spent); every launch needs its own receipt: $hint"
  fi
  printf 'dispatch receipt gate: PASS - receipt %s (%s%s) admits %s for %s%s\n' "$name" "$source" \
    "$(jq -r 'if .override then ", override=captain" elif .row then ", row \(.row.id)" else "" end' "$receipt")" \
    "$(fm_dr_profile_text "$launch")" "$task" "$([ "$consume" -eq 1 ] && printf '; receipt consumed' || printf ' (preview)')"
}
