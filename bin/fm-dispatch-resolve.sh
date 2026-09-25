#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with Jev via OpenRouter's System One API, opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>]
#
# Opt-in gate: OPENROUTER_API_KEY non-empty in this process environment, else an
#   OPENROUTER_API_KEY= line in $FM_HOME/.env read with fmx_env_get, the same
#   accessor as FMX_PAIRING_TOKEN (bin/fm-env-lib.sh). The environment wins.
#   Absent in both: one "dispatch-resolve: off" line on stderr, nothing on
#   stdout, exit 0, no network call, so firstmate dispatches exactly as today.
#   The key lives in one shell variable and reaches curl as a header read from
#   a file descriptor, never on argv; nothing logs or writes it.
#
# What it does when on with at least one rule: one POST to
#   https://openrouter.ai/api/v1/systemone with the project name and whole brief as
#   state and TWO batched Choice questions: rule matching (every rule's `when`
#   plus a neutral none option) and candidate/effort preference. Jev returns the matched rule, a probability per
#   option, and a confidence. Everything after that is jq: the confidence
#   floor, the rule's declared `approval` and `floor`, each profile's declared
#   `provider` and `floor`, the quota rows from per-store quota-axi --json snapshots,
#   and the spendPriority argmax over the eligible candidates. The model never
#   sees quota, catalogs, approvals, `why`, or credential paths. With no rules, it returns
#   a non-clear result so firstmate keeps using the existing intake.
#   Before any selection, a completeness gate requires every candidate in the
#   choice set to have every applicable quota window - session, weekly, and
#   model-scoped - known with its remaining percent and reset time, or positively
#   established absent for that plan, so a measured weekly-only plan is complete
#   while an unmeasured or rate-limited provider is never selected around.
#   An incomplete gather triggers bounded quota-axi retries with doubling backoff
#   plus the named pool warm-up (zai-window-warm for Z.ai); anything still unknown
#   yields status incomplete, which is non-dispatchable: wait and re-run, never
#   pick by hand or drop the unknown candidate.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: clear | ambiguous | incomplete | escalate | error
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     reason: <why the status is not clear>
#     candidate: <harness>:<model> provider=.. windows=<id>:<pct>%@<reset>,.. [account=..] scope=.. remaining=..% spendPriority=.. runway=.. -> eligible | eligible, unranked: <reason> | not eligible: <reason> | incomplete: <reason>
#     profile: --harness <h> [--model <m>] [--effort <e>]     (status clear only)
#   clear      -> pass the profile line to fm-spawn.sh unless you state a reason to override
#   ambiguous  -> confidence below the floor; decide as today from the probabilities
#                 (window evidence is complete on this outcome, so hand-picking is informed)
#   incomplete -> quota window evidence for at least one candidate is not fully known;
#                 the block names the missing windows per candidate: wait for the
#                 measurement and re-run; never pick by hand or drop the unknown candidate
#   escalate   -> the rule requires captain approval, no candidate is rankable, or a genuine tie
#   error      -> API, network, response, or quota-axi failure; decide as today
#   Every outcome exits 0 so an intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, or missing jq), which is
#   actionable, never selected around.
#
# Environment:
#   OPENROUTER_API_KEY opts in; FM_DISPATCH_ROUTE=direct with TYPESAFE_API_KEY
#   selects the direct typesafe.ai fallback instead.
#   FM_DISPATCH_QUOTA_ATTEMPTS bounds quota-axi gather attempts per incomplete
#   store (default 3, clamped 1..10) and FM_DISPATCH_QUOTA_BACKOFF_MS is the
#   doubling backoff base between attempts (default 1500 ms, clamped 250..30000).
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
DIRECT_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n OPENROUTER_API_KEY_PRIVATE DIRECT_API_KEY_PRIVATE 2>/dev/null || true
unset OPENROUTER_API_KEY TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-account-lib.sh
. "$SCRIPT_DIR/fm-account-lib.sh"

CONFIDENCE_FLOOR=0.6
# Bounded gather for an incomplete choice: attempts and the doubling backoff base.
fm_dispatch_clamp_int() {  # <value> <default> <min> <max>
  local v=$1 d=$2 lo=$3 hi=$4
  case "$v" in '' | *[!0-9]*) v=$d ;; esac
  [ "$v" -ge "$lo" ] || v=$lo
  [ "$v" -le "$hi" ] || v=$hi
  printf '%s' "$v"
}
QUOTA_ATTEMPTS=$(fm_dispatch_clamp_int "${FM_DISPATCH_QUOTA_ATTEMPTS:-}" 3 1 10)
QUOTA_BACKOFF_MS=$(fm_dispatch_clamp_int "${FM_DISPATCH_QUOTA_BACKOFF_MS:-}" 1500 250 30000)
fmx_dispatch_route "$OPENROUTER_API_KEY_PRIVATE" "$DIRECT_API_KEY_PRIVATE" "$FM_HOME/.env"
unset OPENROUTER_API_KEY_PRIVATE DIRECT_API_KEY_PRIVATE
TS_TIMEOUT=5
DEFAULT_WHEN="No listed rule applies to this task."

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
no_rules() {
  printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
  exit 0
}
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEF='' PROJECT='' RULES_PATH="$CONFIG/crew-dispatch.json" RULES=''
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
if [ -z "$TS_KEY" ]; then
  echo "dispatch-resolve: off ($TS_KEY_NAME absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
[ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || no_rules
[ -r "$RULES_PATH" ] || die "rules file not readable: $RULES_PATH"
command -v jq >/dev/null 2>&1 || die "jq required"
RULES=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RULES"' EXIT
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
    elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_bad($f; $need_provider):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or (if $need_provider
        then (provider_id($f.provider) | not)
        else ($f | has("provider"))
        end);
  def profile_bad($p):
    ($p | type) != "object"
    or ($p | has("account") and ((.account | type) != "string" or (.account | test("^[a-z][a-z0-9-]*$") | not)))
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("floor") and floor_bad(.floor; false));
  def duplicate_profiles($items):
    ($items | map([.account // null, .harness, (.model // null), (.effort // null)] | @json)) as $keys
    | ($keys | length) != ($keys | unique | length);
  if type != "object" then "top-level value must be an object"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif any((.rules // [])[]; (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif has("default") and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, and effort profiles"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"

missing_provider=$(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ((.rules // [])[] | profiles(.use)[] | select(has("provider") | not) | "use\t\(.harness)"),
  (profiles(.default // null)[] | select(has("provider") | not) | "default\t\(.harness)")
' "$RULES" | while IFS=$'\t' read -r location harness; do
  if ! fm_quota_single_provider_for_harness "$harness" >/dev/null; then
    printf '%s\t%s\n' "$location" "$harness"
    break
  fi
done)
if [ -n "$missing_provider" ]; then
  IFS=$'\t' read -r location harness <<< "$missing_provider"
  die "malformed rules file: $RULES_PATH - $location profiles whose harness lacks one authoritative provider family require provider: $harness"
fi

# ---- harness -> provider map, from the single owner in fm-quota-axi-lib.sh -----
PMAP='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
  PMAP=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$PMAP")
done < <(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null))
  | map(.harness) | unique | .[]' "$RULES")

RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")

emit_error() {
  local reason=$1
  echo "dispatch-resolve: error ($reason)" >&2
  printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

if [ "$RULE_COUNT" -eq 0 ]; then
  no_rules
fi

RESP_FILE=$(mktemp) || die "mktemp failed"
QUOTA=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA"' EXIT
LAT_MS=null
command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
  REQUEST=$(jq -n --rawfile brief "$BRIEF" --arg project "$PROJECT" --arg model "$TS_MODEL" \
    --arg none_criterion "$DEFAULT_WHEN" --slurpfile rules "$RULES" '
    ($rules[0]) as $cfg |
    ($cfg.rules | to_entries | map({key: ("rule_" + ((.key + 1) | tostring)), value: .value.when}) | from_entries) as $criteria |
    {
      model: $model,
      state: {task: {project: $project, brief: $brief}},
      questions: {
        rule: {
          type: "choice",
          instructions: "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule'"'"'s own matching condition; pick `default` when no rule'"'"'s condition is met, including when a rule'"'"'s own exemption text excludes this task.",
          criteria: ($criteria + {default: $none_criterion})
        },
        profile: {
          type: "choice",
          instructions: "Choose the best candidate and effort for this task from the rule you matched above. These are preferences only; code checks eligibility and quota independently.",
          criteria: ([$cfg.rules | to_entries[] | .key as $i | .value as $rule |
            (if ($rule.use | type) == "array" then $rule.use else [$rule.use] end) | to_entries[] |
            {key: "rule_\($i + 1)_\(.key + 1)", value: "\($rule.when) | \(.value.harness) \(.value.model // "default") effort=\(.value.effort // "default") account=\(.value.account // "home")"}] | from_entries)
        }
      }
    }')
  T0=$(fm_timing_now_ms)
  HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TS_KEY") \
    --data-binary @- 2>/dev/null) || HTTP=000
  T1=$(fm_timing_now_ms)
  LAT_MS=$(( T1 - T0 ))
  [ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"
jq -e --slurpfile rules "$RULES" '
    (($rules[0].rules | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"] | sort) as $choices |
    ([$rules[0].rules | to_entries[] | .key as $i | .value.use | (if type == "array" then . else [.] end) | to_entries[] | "rule_\($i + 1)_\(.key + 1)"] | sort) as $profiles |
    (.answers.profile.choice | type) == "string" and
    (.answers.profile.choice as $preferred | ($profiles | index($preferred)) != null) and
    (.answers.profile.confidence | type) == "number" and
    .answers.profile.confidence >= 0 and .answers.profile.confidence <= 1 and
    (.answers.profile.probabilities | type) == "object" and
    ((.answers.profile.probabilities | keys | sort) == $profiles) and
    all(.answers.profile.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    (.answers.rule.choice | type) == "string" and
    (.answers.rule.confidence | type) == "number" and
    .answers.rule.confidence >= 0 and .answers.rule.confidence <= 1 and
    (.answers.rule.probabilities | type) == "object" and
    ((.answers.rule.probabilities | keys | sort) == $choices) and
    all(.answers.rule.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    ((.answers.rule.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
    ((has("usage") | not) or
      ((.usage | type) == "object" and
       (.usage.input_tokens | type) == "number" and
       (.usage.output_tokens | type) == "number"))' \
  "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a rule Choice answer"

# ---- quota evidence: one snapshot per authorized credential store -------------
command -v quota-axi >/dev/null 2>&1 || emit_error "quota-axi not installed"
gather_home_quota() {
  quota-axi --json > "$QUOTA" 2>/dev/null || emit_error "quota-axi --json failed"
  fm_quota_json_valid < "$QUOTA" || emit_error "quota-axi --json returned an invalid snapshot"
}
gather_home_quota
gather_account_snapshot() {  # <account>: refresh ACCOUNT_QUOTAS[account] from its pinned store
  local account=$1 stores account_quota store_key
  [ -n "$account" ] || return 0
  stores=()
  mapfile -t stores < <(fm_account_stores "$CONFIG/accounts.json" "$account")
  [ "${#stores[@]}" -eq 3 ] || return 0
  store_key=$(printf '%s\n' "${stores[@]}" | jq -Rsc .)
  account_quota=$(mktemp) || emit_error "mktemp failed"
  if ! CODEX_HOME=${stores[2]} PI_CODING_AGENT_DIR=${stores[1]} CLAUDE_CONFIG_DIR=${stores[0]} quota-axi --json > "$account_quota" 2>/dev/null || ! fm_quota_json_valid < "$account_quota"; then
    ACCOUNT_QUOTAS=$(jq -c --arg a "$account" --arg key "$store_key" '. + {($a): {key: $key, failed: true}}' <<<"$ACCOUNT_QUOTAS")
  else
    ACCOUNT_QUOTAS=$(jq -c --arg a "$account" --arg key "$store_key" --slurpfile snapshot "$account_quota" '. + {($a): {key: $key, snapshot: $snapshot[0]}}' <<<"$ACCOUNT_QUOTAS")
  fi
  rm -f "$account_quota"
}
ACCOUNT_QUOTAS='{}'
while IFS= read -r account; do
  [ -n "$account" ] || continue
  stores=()
  mapfile -t stores < <(fm_account_stores "$CONFIG/accounts.json" "$account")
  [ "${#stores[@]}" -eq 3 ] || continue
  # Memoize identical store triples; no candidate gets another account's quota.
  store_key=$(printf '%s\n' "${stores[@]}" | jq -Rsc .)
  previous=$(jq -r --arg key "$store_key" 'to_entries[] | select(.value.key == $key) | .key' <<<"$ACCOUNT_QUOTAS" | head -n 1)
  if [ -n "$previous" ]; then
    ACCOUNT_QUOTAS=$(jq -c --arg a "$account" --arg prev "$previous" '. + {($a): .[$prev]}' <<<"$ACCOUNT_QUOTAS")
    continue
  fi
  gather_account_snapshot "$account"
done < <(jq -r '[((.rules // [])[] | .use | if type == "array" then .[] else . end), (.default // empty | if type == "array" then .[] else . end) | .account // empty] | unique[]' "$RULES")

# ---- resolution: declared gates + quota evidence + argmax, all in jq ----------
fm_dispatch_resolve_json() {  # <quota attempts> <warm-ups run>
  jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" --argjson account_quotas "$ACCOUNT_QUOTAS" --argjson quota_attempts "$1" --argjson warmups "$2" \
    --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" '
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($r.answers.rule) as $a |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def account_quota($c): (if $c.account then $account_quotas[$c.account].snapshot else $q end);
  def prov($p): ([.providers[] | select(.provider == $p)] | first) // null;
  def rows($p): (prov($p).quotaSemantics.effectiveAvailability // []);
  def bare($m): ($m | split("/") | last);
  def provider_of($c): ($c.provider // $pmap[$c.harness] // null);
  def measured($p):
    (prov($p)) as $provider |
    ($provider != null and (["known", "partial"] | index($provider.quotaSemantics.status)) != null);
  def applicable($p; $m):
    (bare($m)) as $bare |
    [rows($p)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )];
  def floor_state($f; $p):
    if $f == null then "none"
    elif prov($p) == null or (measured($p) | not) then "unmeasured"
    else [rows($p)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 then "absent"
        elif any($matches[]; .status != "known") then "unmeasured"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def provider_windows($p): (prov($p).windows // []);
  def window_row($p; $id): ([provider_windows($p)[] | select(.id == $id)] | first) // null;
  def clean_reset($t): ($t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z"));
  def unmeasured_ids($p):
    ([rows($p)[] | (.selection.unmeasurableWindowIds // .runway.unmeasurableWindowIds // [])[]] | unique) as $ids |
    (if ($ids | length) == 0 then [provider_windows($p)[] | .id] | unique else $ids end);
  def applicable_window_ids($p; $m):
    # first-occurrence order keeps session and weekly windows ahead of model windows
    def dedupe: reduce .[] as $x ([]; if (. | index($x)) then . else . + [$x] end);
    (applicable($p; $m)) as $rows |
    ([ $rows[] | (.boundedBy // [])[] ] | dedupe) as $ids |
    (if ($ids | length) == 0
     then [provider_windows($p)[] | select((.kind // "") != "model") | .id] | dedupe
     else $ids end);
  def completeness($p; $c):
    (prov($p).state.error // null) as $state_error |
    (prov($p).state.retryAfter // null) as $retry_after |
    if prov($p) == null then {complete: false, missing: ["*"], reason: "provider \($p) absent from the quota snapshot"}
    elif (measured($p) | not) then
      {complete: false, missing: (unmeasured_ids($p)),
       reason: "provider \($p) unmeasured (\(prov($p).quotaSemantics.status))",
       state_error: $state_error, retry_after: $retry_after}
    else
      (applicable($p; ($c.model // ""))) as $rows |
      if ($rows | length) == 0 then {complete: false, missing: ["*"], reason: "no applicable quota row for provider \($p)", state_error: $state_error, retry_after: $retry_after}
      elif any($rows[]; .status != "known") then
        ([ $rows[] | select(.status != "known") | (.selection.unmeasurableWindowIds // .runway.unmeasurableWindowIds // [.scope])[] ] | unique) as $miss |
        {complete: false, missing: $miss, reason: "unmeasured windows: \($miss | join(", "))",
         state_error: $state_error, retry_after: $retry_after}
      else
        (applicable_window_ids($p; ($c.model // ""))) as $ids |
        if ($ids | length) == 0 then {complete: false, missing: ["*"], reason: "no window reset evidence for provider \($p)"}
        else
          (provider_windows($p)) as $pws |
          ([$ids[] | . as $id | ([$pws[] | select(.id == $id)] | first) as $w |
            if $w == null or ($w.percentRemaining | type) != "number" or ($w.resetsAt | type) != "string"
            then {id: $id, missing: true}
            else {id: $id, pct: $w.percentRemaining, resetsAt: clean_reset($w.resetsAt)}
            end]) as $wev |
          ([$wev[] | select(.missing)] | map(.id)) as $miss |
          if ($miss | length) > 0 then {complete: false, missing: $miss, reason: "windows without known percent or reset: \($miss | join(", "))"}
          else {complete: true, windows: $wev}
          end
        end
      end
    end;
  def evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), spendPriority: (.selection.spendPriority // null)});
  def evaluate($c):
    (provider_of($c)) as $p |
    if $c.account and $account_quotas[$c.account] == null then
      {profile: $c, provider: $p, eligible: false, reason: "cross-account routing disabled or account not registered"}
    elif $c.account and $account_quotas[$c.account].failed then
      {profile: $c, provider: $p, eligible: false, incomplete: true, windows_missing: ["*"], reason: "quota-axi --json failed for account \($c.account)"}
    elif $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    else account_quota($c) |
      (applicable($p; ($c.model // ""))) as $rows |
      (evidence($rows)) as $bounds |
      (floor_state($c.floor; $p)) as $profile_floor_state |
      (completeness($p; $c)) as $gate |
      if any($rows[]; (.runway.status // "") == "exhausted_now") then
        ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([rows($p)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif ($gate.complete | not) then
        {profile: $c, provider: $p, bounds: $bounds, eligible: false, incomplete: true,
         windows_missing: ($gate.missing // []),
         reason: ($gate.reason // "quota window evidence incomplete"),
         state_error: ($gate.state_error // null), retry_after: ($gate.retry_after // null)}
      elif $profile_floor_state == "absent" then
        ([rows($p)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: $c.floor.scope, pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: true, unranked: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      elif any($rows[]; (.selection.spendPriority | type) != "number") then
        ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing or non-numeric at \($bad.scope): not rankable"}
      else
        ($rows | min_by(.selection.spendPriority)) as $limiting |
        {profile: $c, provider: $p, bounds: $bounds, windows: $gate.windows, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendPriority: $limiting.selection.spendPriority, runway: $limiting.runway.status, eligible: true, reason: "ok"}
      end
    end;
  ($a.choice) as $choice |
  (if ($choice | test("^rule_[1-9][0-9]*$"))
   then ($choice | ltrimstr("rule_") | tonumber)
   else null end) as $rule_number |
  (if $choice == "default" then null
   elif $rule_number != null and $rule_number <= (($cfg.rules // []) | length) then $cfg.rules[$rule_number - 1]
   else null end) as $rule |
  (if $rule == null then "none" else ($q | floor_state($rule.floor; $rule.floor.provider)) end) as $rule_floor_state |
  (if $choice != "default" and $rule == null then []
   elif $rule == null then profiles($cfg.default // null)
   else profiles($rule.use)
   end) as $answer_use |
  (if $choice != "default" and $rule == null then {invalid: "rule \($choice) is not in the rules file"}
   elif $rule == null then {source: "default", use: profiles($cfg.default // null), note: "no rule matched"}
   elif ($rule.approval // "") == "captain" then {source: $choice, escalate: "rule requires the captain'"'"'s explicit approval before dispatch"}
   elif $rule_floor_state == "unmeasured" then {source: $choice, rule_floor_incomplete: true, use: profiles($rule.use), note: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unmeasured: gather first"}
   elif $rule_floor_state == "absent" then {source: $choice, escalate: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"}
   elif $rule_floor_state == "below"
     then {source: "default", use: profiles($cfg.default // null), note: "rule \($choice) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default"}
   else {source: $choice, use: profiles($rule.use), note: "rule matched"} end) as $sel |
  (if ((($floor | tonumber) > $a.confidence) or $sel.escalate) then $answer_use else ($sel.use // []) end) as $decision_use |
  ($decision_use | map(evaluate(.))) as $cands |
  ([$cands[] | select(.incomplete)]) as $incomplete |
  {
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    rule: $choice, profile_preference: $r.answers.profile.choice,
    rule_when: (if $rule == null then $none_criterion else $rule.when end | .[0:60]),
    confidence: $a.confidence, probabilities: $a.probabilities
  } as $ev |
  if $sel.invalid then $ev + {status: "error", reason: $sel.invalid}
  elif ($incomplete | length) > 0 or ($sel.rule_floor_incomplete // false) then
    $ev + {
      status: "incomplete",
      reason: ("quota window evidence incomplete: " +
        (([$incomplete[] | "\(.profile.harness):\(.profile.model // "default") missing \((.windows_missing // []) | join(", "))"] +
          (if ($sel.rule_floor_incomplete // false)
           then ["rule floor \($rule.floor.provider)/\($rule.floor.scope) unmeasured"]
           else [] end)) | join("; "))),
      note: "gather first: \($quota_attempts) quota-axi attempt(s) with backoff and named warm-ups; wait for the named measurements and re-run; never pick by hand or drop a candidate",
      candidates: $cands,
      incomplete: (([$incomplete[] | {account: (.profile.account // null), provider: (.provider // null), missing: (.windows_missing // []), retry_after: (.retry_after // null)}]) +
        (if ($sel.rule_floor_incomplete // false)
         then [{account: null, provider: $rule.floor.provider, missing: [$rule.floor.scope], retry_after: (($q | prov($rule.floor.provider).state.retryAfter) // null)}]
         else [] end)),
      quota_attempts: $quota_attempts, warmups: $warmups
    }
  elif $a.confidence < ($floor | tonumber) then
    $ev + {status: "ambiguous", reason: "confidence \($a.confidence) below floor \($floor)", candidates: $cands}
  elif $sel.escalate then
    $ev + {status: "escalate", reason: $sel.escalate, candidates: $cands}
  elif ($sel.use | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    ([$cands[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
    ([$cands[] | select(.unranked)]) as $unranked |
    if ($elig | length) == 0 then $ev + {status: "escalate", reason: "no rankable eligible candidate", note: $sel.note, candidates: $cands}
    else
      ($elig | max_by(.spendPriority)) as $best |
      ([$elig[] | select(.spendPriority == $best.spendPriority)]) as $ties |
      ([$ties[] | . as $candidate | $sel.use | to_entries[] |
        select(.value == $candidate.profile) | select($ev.profile_preference == "\($sel.source)_\(.key + 1)") | $candidate] | first) as $preferred |
      if ($ties | length) > 1 and $preferred == null then $ev + {status: "escalate", reason: "genuine spendPriority tie", note: $sel.note, candidates: $cands}
      else $ev + {status: "clear", note: $sel.note, candidates: $cands, chosen: ($preferred // $best)}
        + (if ($unranked | length) > 0 then
             {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
           else {} end)
      end
    end
  end'
}
RESULT=$(fm_dispatch_resolve_json 1 0) || emit_error "resolution failed"
quota_attempts=1
warmups_run=0
fm_dispatch_epoch_ms_of() {  # <iso8601>: epoch milliseconds, or nothing when unparsable
  local out
  out=$(date -d "$1" +%s%3N 2>/dev/null) || return 1
  case "$out" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}
# Bounded gather loop: an incomplete resolution runs the named warm-up once,
# re-reads only the named stores with doubling backoff, and stops early when
# every missing measurement publishes a retry time beyond this tool's bounded
# wait, so the block names the retry times instead of choosing blind.
while [ "$(jq -r '.status // ""' <<<"$RESULT" 2>/dev/null)" = "incomplete" ] && [ "$quota_attempts" -lt "$QUOTA_ATTEMPTS" ]; do
  if [ "$warmups_run" -eq 0 ] && jq -e 'any(.incomplete[]?; .provider == "zai")' <<<"$RESULT" >/dev/null 2>&1; then
    warmups_run=1
    if command -v zai-window-warm >/dev/null 2>&1; then
      zai-window-warm >/dev/null 2>&1 || true
    fi
  fi
  budget_ms=$(awk -v base="$QUOTA_BACKOFF_MS" -v done_retries="$(( quota_attempts - 1 ))" -v total="$QUOTA_ATTEMPTS" 'BEGIN { s = 0; for (i = done_retries; i < total - 1; i++) s += base * (2 ^ i); printf "%d", s }')
  now_ms=$(fm_timing_now_ms)
  all_late=1
  any_hint=0
  while IFS= read -r retry_after; do
    [ -n "$retry_after" ] || continue
    any_hint=1
    retry_ms=$(fm_dispatch_epoch_ms_of "$retry_after") || { all_late=0; continue; }
    [ "$(( retry_ms - now_ms ))" -gt "$budget_ms" ] || all_late=0
  done < <(jq -r '.incomplete[]? | .retry_after // empty' <<<"$RESULT" | sort -u)
  if [ "$any_hint" -eq 1 ] && [ "$all_late" -eq 1 ]; then
    break
  fi
  sleep "$(awk -v base="$QUOTA_BACKOFF_MS" -v n="$quota_attempts" 'BEGIN { printf "%.3f", (base * (2 ^ (n - 1))) / 1000 }')"
  if jq -e 'any(.incomplete[]?; .account == null)' <<<"$RESULT" >/dev/null 2>&1; then
    gather_home_quota
  fi
  while IFS= read -r account; do
    [ -n "$account" ] || continue
    gather_account_snapshot "$account"
  done < <(jq -r '.incomplete[]? | .account // empty' <<<"$RESULT" | sort -u)
  quota_attempts=$(( quota_attempts + 1 ))
  RESULT=$(fm_dispatch_resolve_json "$quota_attempts" "$warmups_run") || emit_error "resolution failed"
done

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def shell_arg: flat | @sh;
  def winstr($ws): [$ws[] | "\(.id | flat):\(.pct | flat)%@\(.resetsAt | flat)"] | join(",");
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  rule: \(.rule | flat) (\(.rule_when | flat))   confidence: \(.confidence | flat)",
  "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
  "  candidate_preference: \(.profile_preference | flat) (quota gates and spendPriority take precedence)",
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .profile.account then "  account=\(.profile.account | flat)" else "" end)
      + (if .provider then "  provider=\(.provider | flat)" else "" end)
      + (if .incomplete then "  windows_missing=\((.windows_missing // []) | map(flat) | join(","))"
          + (if .state_error or .retry_after
             then " (" + ([.state_error // empty] + (if .retry_after then [("retry after " + (.retry_after | flat))] else [] end) | join("; ")) + ")"
             else "" end)
        elif .windows then "  windows=\(winstr(.windows))" else "" end)
      + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + "  -> " + (if .incomplete then "incomplete: \(.reason | flat): gather first, wait and re-run" elif .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end)
      + (if .chosen.profile.account then " --account \(.chosen.profile.account | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
