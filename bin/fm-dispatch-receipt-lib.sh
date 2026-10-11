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
#   source      resolve | choose | override
#   status      the resolver outcome behind it (clear, or chosen/override)
#   task        task id (required for an override, optional otherwise); a
#               receipt that names one admits only that task
#   brief       {path, sha256} - the hash covers the brief up to the first
#               relaunch progress note, so the note bin/fm-control.sh relaunch
#               appends never unbinds a task from its own receipt
#   table       {path, sha256} of config/crew-dispatch.json at issue time
#   row         {id, sha256} - id is rule_<n> (1-based position in `rules`) or
#               default; sha256 is of the row's canonical JSON, so any edit to
#               the row makes its outstanding receipts stale
#   profile     {harness, model, effort, account, provider}; an omitted axis is ""
#   candidates  one entry per profile in the row: harness, model, effort,
#               account, provider, catalog, plan, quotaIntakeRecord,
#               spendPriority (a number or the literal "unknown"), eligible,
#               reason
#   rationale   why this candidate (the resolver's note, or the rationale file)
#   override    null, or {by: "captain", words, task} for a captain override
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
#     row's candidates, and its profile equals the launch field by field; or
#   - that receipt is a captain override that is present in the durable
#     override log and whose profile equals the launch.
#   A raw launch command is only ever admitted by a captain override, because a
#   command string cannot be matched to a table profile.
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
#   command. A ship, a scout, a local second mate, or a relaunch started from a
#   session matches none of that, so the variable does not switch the gate off.
#
# What the gate does and does not prevent: it physically stops a launch whose
#   profile no receipt names, which is what catches a hand-picked profile. Three
#   paths are audit and deterrence, not physical prevention: `override` accepts
#   any non-empty words file as the captain's words, `choose` takes accounting
#   the caller wrote itself, and receipts and state/<id>.meta are plain files
#   the same user can write by hand. Each leaves a durable record (the override
#   log, the receipt) that the captain can read afterwards.
#
# FM_DISPATCH_RECEIPT_MAX_AGE can only shorten the freshness window (clamped
# 1..900 seconds, default 900); the test suite reaches the gate the way a home
# does, by producing real receipts.
#
# Captain overrides are appended to data/dispatch-overrides.jsonl, one JSON
# object per line, and bin/fm-session-start.sh lists the recent ones.
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
      '{schemaVersion: $schema, receipt: $name, issuedAt: $at, issuedAtEpoch: $epoch,
        source: $source, status: $status, task: $task,
        brief: {path: $brief, sha256: $brief_sha},
        table: {path: $table, sha256: $table_sha},
        row: $row, profile: $profile, candidates: $candidates,
        rationale: $rationale, override: $override}' > "$file"
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

fm_dr_newest_intake_record() {  # name of the newest quota-intake record, or nothing
  local f newest=''
  for f in "$STATE"/quota-intake/quota-*.json; do
    [ -f "$f" ] || continue
    newest=$f
  done
  [ -z "$newest" ] || basename -- "$newest"
}

# The receipt for a `clear` resolution: <brief> <task> <resolver-result-json>.
# The result carries the matched row, the chosen candidate, and every
# candidate's evidence; nothing here re-decides any of it.
fm_dr_write_clear() {
  local brief=$1 task=$2 result=$3 rows row_id row profile candidates intake
  rows=$(fm_dr_table_rows) || return 1
  row_id=$(jq -r '.row // ""' <<<"$result")
  row=$(jq -c --arg id "$row_id" '[.[] | select(.id == $id)] | first // null | if . == null then null else {id, sha256} end' <<<"$rows")
  [ "$row" != null ] || { FM_DR_ERR="the resolved row '$row_id' is not in $(fm_dr_table)"; return 1; }
  intake=$(fm_dr_newest_intake_record)
  profile=$(jq -c '.chosen | {harness: .profile.harness, model: ((.profile.model // "") | if . == "default" then "" else . end),
    effort: ((.profile.effort // "") | if . == "default" then "" else . end), account: (.profile.account // ""), provider: (.provider // "")}' <<<"$result") || return 1
  candidates=$(jq -c --arg intake "${intake:-none}" '[.candidates[] | {
      harness: .profile.harness,
      model: ((.profile.model // "") | if . == "default" then "" else . end),
      effort: ((.profile.effort // "") | if . == "default" then "" else . end),
      account: (.profile.account // ""), provider: (.provider // ""),
      catalog: "unknown (the resolver does not read harness catalogs; fm-spawn validates the model at launch)",
      plan: (.plan // "unknown"), quotaIntakeRecord: $intake,
      spendPriority: (if (.spendPriority | type) == "number" then .spendPriority else "unknown" end),
      eligible: ((.eligible // false) and ((.unranked // false) | not)),
      reason: (.reason // "")}]' <<<"$result") || return 1
  fm_dr_write resolve clear "$task" "$brief" "$row" "$profile" "$candidates" \
    "$(jq -r '.note // "rule matched"' <<<"$result")" null
}

fm_dr_producer_hint() {
  printf '%s' 'produce one with bin/fm-dispatch-resolve.sh <brief> --project <name> (it writes the receipt on status clear), otherwise bin/fm-dispatch-resolve.sh choose <brief> --row <id> --harness <h> [--model <m>] [--effort <e>] [--account <id>] --accounting-file <json> --rationale-file <path> (row ids: bin/fm-dispatch-resolve.sh rows); only the captain'"'"'s explicit instruction for this one task departs from the table: bin/fm-dispatch-resolve.sh override <brief> --task <id> --harness <h> ... --words-file <path>'
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

# choose: firstmate's own judgment on a non-clear outcome, still bound to one
# row of the table and to the per-candidate accounting AGENTS.md section 4
# requires. Refuses a profile outside the named row.
fm_dr_cmd_choose() {
  local brief='' row_id='' harness='' model='' effort='' account='' accounting='' rationale_file='' task='' arg
  while [ $# -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --row | --harness | --model | --effort | --account | --accounting-file | --rationale-file | --task)
        [ $# -gt 0 ] || fm_dr_die "$arg needs a value" ;;
    esac
    case "$arg" in
      --row) row_id=$1; shift ;;
      --harness) harness=$1; shift ;;
      --model) model=$1; shift ;;
      --effort) effort=$1; shift ;;
      --account) account=$1; shift ;;
      --accounting-file) accounting=$1; shift ;;
      --rationale-file) rationale_file=$1; shift ;;
      --task) task=$1; shift ;;
      -*) fm_dr_die "unknown choose argument: $arg" ;;
      *) [ -z "$brief" ] || fm_dr_die "one brief file only"; brief=$arg ;;
    esac
  done
  [ -n "$brief" ] || fm_dr_die "choose requires the brief file"
  [ -f "$brief" ] && [ -r "$brief" ] || fm_dr_die "brief file not readable: $brief"
  [ -n "$row_id" ] || fm_dr_die "choose requires --row <id> (list them with: bin/fm-dispatch-resolve.sh rows)"
  [ -n "$harness" ] || fm_dr_die "choose requires --harness, exactly as the launch will pass it"
  [ -n "$accounting" ] || fm_dr_die "choose requires --accounting-file: a JSON array with one entry per candidate of the row"
  [ -f "$accounting" ] && [ -r "$accounting" ] || fm_dr_die "accounting file not readable: $accounting"
  [ -n "$rationale_file" ] || fm_dr_die "choose requires --rationale-file"
  [ -f "$rationale_file" ] && [ -r "$rationale_file" ] || fm_dr_die "rationale file not readable: $rationale_file"
  local rationale rows row profile verdict candidates missing_intake record
  rationale=$(cat "$rationale_file")
  [ -n "${rationale//[[:space:]]/}" ] || fm_dr_die "the rationale file is empty; state why this candidate"
  rows=$(fm_dr_table_rows) || fm_dr_die "$FM_DR_ERR"
  row=$(jq -c --arg id "$row_id" '[.[] | select(.id == $id)] | first // null' <<<"$rows")
  [ "$row" != null ] || fm_dr_die "row '$row_id' is not in $(fm_dr_table); its rows are: $(jq -r '[.[].id] | join(", ") | if . == "" then "none" else . end' <<<"$rows")"
  profile=$(fm_dr_profile_json "$harness" "$model" "$effort" "$account")
  verdict=$(jq -r --argjson p "$profile" "$FM_DR_KEY_JQ"'
    if any(.profiles[]; key == ($p | key)) then "member" else "outside" end' <<<"$row")
  [ "$verdict" = member ] || fm_dr_die "profile $(fm_dr_profile_text "$profile") is not a candidate of row $row_id; a profile outside the matched row is refused. Its candidates are: $(jq -r '[.profiles[] | "--harness \(.harness)" + (if .model != "" then " --model \(.model)" else "" end) + (if .effort != "" then " --effort \(.effort)" else "" end) + (if .account != "" then " --account \(.account)" else "" end)] | join("; ")' <<<"$row")"
  verdict=$(jq -r --argjson row "$row" --argjson p "$profile" "$FM_DR_KEY_JQ"'
    def axis: if . == null or . == "default" then "" else . end;
    def norm: {harness: (.harness // ""), model: (.model | axis), effort: (.effort | axis), account: (.account // "")};
    if type != "array" then "the accounting file must be a JSON array"
    elif any(.[]; type != "object") then "each accounting entry must be an object"
    else
      (map(norm)) as $got | ($row.profiles | map(key)) as $want |
      if ($want - $got | length) > 0 then
        "accounting omits a candidate of the row: " + ([($want - $got)[] | "\(.harness):\(if .model == "" then "default" else .model end)"] | join(", "))
      elif ($got - $want | length) > 0 then
        "accounting names a profile that is not in the row: " + ([($got - $want)[] | "\(.harness):\(if .model == "" then "default" else .model end)"] | join(", "))
      elif ($got | length) != ($got | unique | length) then "accounting lists a candidate twice"
      elif any(.[]; (.catalog | type) != "string" or (.catalog | length) == 0) then "every accounting entry needs catalog: the catalog evidence for that model"
      elif any(.[]; (.plan | type) != "string" or (.plan | length) == 0) then "every accounting entry needs plan: the account plan, or the literal unknown"
      elif any(.[]; (.quotaIntakeRecord | type) != "string" or (.quotaIntakeRecord | test("^quota-[0-9A-Za-z-]+\\.json$") | not)) then "every accounting entry needs quotaIntakeRecord: the name of the bin/fm-quota-intake.sh record its numbers came from"
      elif any(.[]; (.spendPriority | type) != "number" and .spendPriority != "unknown") then "every accounting entry needs spendPriority: a number or the literal \"unknown\""
      elif any(.[]; (.eligible | type) != "boolean") then "every accounting entry needs eligible: true or false"
      elif any(.[]; (.reason | type) != "string" or (.reason | length) == 0) then "every accounting entry needs reason: why it is eligible or the exclusion reason"
      elif ([.[] | select(norm == ($p | key))] | first | .eligible) != true then "the chosen profile is marked not eligible in the accounting"
      else "ok" end
    end' "$accounting" 2>/dev/null) || fm_dr_die "the accounting file is not JSON: $accounting"
  [ "$verdict" = ok ] || fm_dr_die "$verdict"
  missing_intake=''
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    [ -f "$STATE/quota-intake/$record" ] || missing_intake="${missing_intake:+$missing_intake, }$record"
  done < <(jq -r '[.[].quotaIntakeRecord] | unique[]' "$accounting")
  [ -z "$missing_intake" ] || fm_dr_die "accounting names quota-intake record(s) this home does not hold: $missing_intake; run bin/fm-quota-intake.sh and account from its record"
  candidates=$(jq -c --argjson row "$row" '
    def axis: if . == null or . == "default" then "" else . end;
    [.[] | . as $c | {harness: .harness, model: (.model | axis), effort: (.effort | axis), account: (.account // "")} as $k
      | $k + {provider: (([$row.profiles[] | select(.harness == $k.harness and .model == $k.model and .effort == $k.effort and .account == $k.account) | .provider] | first) // ""),
              catalog: $c.catalog, plan: $c.plan, quotaIntakeRecord: $c.quotaIntakeRecord,
              spendPriority: $c.spendPriority, eligible: $c.eligible, reason: $c.reason}]' "$accounting")
  profile=$(jq -c --argjson cands "$candidates" "$FM_DR_KEY_JQ"'
    . as $p | . + {provider: (([$cands[] | select(key == ($p | key)) | .provider] | first) // "")}' <<<"$profile")
  local name
  name=$(fm_dr_write choose chosen "$task" "$brief" "$(jq -c '{id, sha256}' <<<"$row")" "$profile" "$candidates" "$rationale" null) \
    || fm_dr_die "$FM_DR_ERR"
  printf 'dispatch-resolve:\n  status: chosen\n  row: %s (%s)\n' "$row_id" "$(jq -r '.when | gsub("[\t\r\n]"; " ") | .[0:60]' <<<"$row")"
  [ "$(jq -r '.approval // ""' <<<"$row")" != captain ] \
    || printf '  note: this row declares approval=captain; launch it only with the captain'"'"'s explicit approval\n'
  printf '  receipt: %s (one launch, valid %ss)\n  profile: %s\n' "$name" "$(fm_dr_max_age)" "$(fm_dr_profile_text "$profile")"
}

# override: the captain's explicit per-task instruction, the only way to launch
# a profile the table does not name. Never silent: the exact words go into the
# durable log and the next session-start digest.
fm_dr_cmd_override() {
  local brief='' harness='' model='' effort='' account='' words_file='' task='' arg
  while [ $# -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --harness | --model | --effort | --account | --words-file | --task)
        [ $# -gt 0 ] || fm_dr_die "$arg needs a value" ;;
    esac
    case "$arg" in
      --harness) harness=$1; shift ;;
      --model) model=$1; shift ;;
      --effort) effort=$1; shift ;;
      --account) account=$1; shift ;;
      --words-file) words_file=$1; shift ;;
      --task) task=$1; shift ;;
      -*) fm_dr_die "unknown override argument: $arg" ;;
      *) [ -z "$brief" ] || fm_dr_die "one brief file only"; brief=$arg ;;
    esac
  done
  [ -n "$brief" ] || fm_dr_die "override requires the brief file"
  [ -f "$brief" ] && [ -r "$brief" ] || fm_dr_die "brief file not readable: $brief"
  [ -n "$task" ] || fm_dr_die "override requires --task <id>: an override is for one task"
  case "$task" in *[!A-Za-z0-9._-]*) fm_dr_die "--task must be a task id" ;; esac
  [ -n "$harness" ] || fm_dr_die "override requires --harness, exactly as the launch will pass it"
  [ -n "$words_file" ] || fm_dr_die "override requires --words-file: the captain's exact words for this task"
  [ -f "$words_file" ] && [ -r "$words_file" ] || fm_dr_die "words file not readable: $words_file"
  local words profile override name log entry
  words=$(cat "$words_file")
  [ -n "${words//[[:space:]]/}" ] || fm_dr_die "the captain's words are empty; an override without the captain's exact words is refused"
  profile=$(fm_dr_profile_json "$harness" "$model" "$effort" "$account")
  override=$(jq -cn --arg words "$words" --arg task "$task" '{by: "captain", words: $words, task: $task}')
  log=$(fm_dr_override_log)
  mkdir -p -- "$(dirname -- "$log")" || fm_dr_die "could not create $(dirname -- "$log")"
  name=$(fm_dr_write override override "$task" "$brief" null "$profile" '[]' "captain override" "$override") \
    || fm_dr_die "$FM_DR_ERR"
  entry=$(jq -c '{at: .issuedAt, atEpoch: .issuedAtEpoch, task: .task, brief: .brief, profile: .profile, words: .override.words, receipt: .receipt}' \
    "$(fm_dr_dir)/$name") || fm_dr_die "could not read back receipt $name"
  if ! printf '%s\n' "$entry" >> "$log"; then
    rm -f -- "$(fm_dr_dir)/$name"
    fm_dr_die "could not append to $log; the override was not recorded and no receipt was kept"
  fi
  printf 'dispatch-resolve:\n  status: override\n  override: captain (logged in %s; listed at the next session start)\n' "$log"
  printf '  receipt: %s (one launch, valid %ss)\n  profile: %s\n' "$name" "$(fm_dr_max_age)" "$(fm_dr_profile_text "$profile")"
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
  [ "$age" -le "$max" ] \
    || fm_dr_refuse "receipt $name is stale: issuedAt is ${age}s ago (max ${max}s); $hint"

  local source verdict row_id receipt_task
  source=$(jq -r '.source // ""' "$receipt")
  receipt_task=$(jq -r '.task // ""' "$receipt")
  [ -z "$receipt_task" ] || [ -z "$task_id" ] || [ "$receipt_task" = "$task_id" ] \
    || fm_dr_refuse "receipt $name was issued for task '$receipt_task', not $task_id (the task field does not match); $hint"
  if [ "$(jq -r '.override.by // ""' "$receipt")" = captain ]; then
    local log
    log=$(fm_dr_override_log)
    { [ -f "$log" ] && jq -e -s --slurpfile r "$receipt" '
        any(.[]; .receipt == $r[0].receipt and .words == $r[0].override.words and .task == $r[0].task and .profile == $r[0].profile and (.words | test("\\S")))' \
        "$log" >/dev/null 2>&1; } \
      || fm_dr_refuse "receipt $name is marked override=captain but $log holds no matching entry; record the captain's exact words with bin/fm-dispatch-resolve.sh override <brief> --task <id> --harness <h> [--model <m>] [--effort <e>] [--account <id>] --words-file <path>"
  else
    [ "$raw" -eq 0 ] \
      || fm_dr_refuse "a raw launch command cannot be matched to a profile of the dispatch table; only a captain override admits it: bin/fm-dispatch-resolve.sh override <brief> --task <id> --harness <h> --words-file <path>"
    case "$source" in
      resolve | choose) ;;
      *) fm_dr_refuse "receipt $name has no recognised source (source is '${source}'); $hint" ;;
    esac
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
